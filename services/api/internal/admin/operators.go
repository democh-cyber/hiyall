package admin

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Role is a staff permission level. Each includes the one before it.
type Role string

const (
	RoleViewer    Role = "viewer"    // read the queue and cases
	RoleModerator Role = "moderator" // + resolve reports and restore members
	RoleAdmin     Role = "admin"     // + manage operators, read the audit log, see sign-in identities
)

func (r Role) rank() int {
	switch r {
	case RoleViewer:
		return 1
	case RoleModerator:
		return 2
	case RoleAdmin:
		return 3
	}
	return 0
}

// Allows reports whether r satisfies a route that needs min.
func (r Role) Allows(min Role) bool { return r.rank() > 0 && r.rank() >= min.rank() }

// ParseRole accepts exactly the three role names.
func ParseRole(s string) (Role, bool) {
	r := Role(s)
	return r, r.rank() > 0
}

// Operator is a staff account as the console shows it: never a hash or a secret.
type Operator struct {
	ID          string     `json:"operatorId"`
	Email       string     `json:"email"`
	DisplayName string     `json:"displayName"`
	Role        Role       `json:"role"`
	DisabledAt  *time.Time `json:"disabledAt"`
	CreatedAt   time.Time  `json:"createdAt"`
	LastLoginAt *time.Time `json:"lastLoginAt"`
}

var emailPattern = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

// NormalizeEmail lower-cases and trims an address, and reports whether it is plausible.
func NormalizeEmail(s string) (string, bool) {
	s = strings.ToLower(strings.TrimSpace(s))
	return s, len(s) >= 3 && len(s) <= 254 && emailPattern.MatchString(s)
}

// Policy errors, mapped to HTTP statuses by the handlers.
var (
	ErrLastAdmin    = &domain.PolicyError{Status: 409, Code: "LAST_ADMIN", Message: "There must always be at least one active administrator"}
	ErrSelfDisable  = &domain.PolicyError{Status: 409, Code: "SELF_DISABLE", Message: "You cannot disable your own account"}
	ErrNoChange     = &domain.PolicyError{Status: 409, Code: "NO_CHANGE", Message: "The operator is already in that state"}
	ErrBadCreds     = &domain.PolicyError{Status: 401, Code: "SIGN_IN_FAILED", Message: "Sign-in failed"}
	ErrLocked       = &domain.PolicyError{Status: 429, Code: "TOO_MANY_ATTEMPTS", Message: "Too many attempts. Try again later."}
	ErrUnauthorized = &domain.PolicyError{Status: 401, Code: "UNAUTHENTICATED", Message: "Sign in to continue"}
	ErrForbidden    = &domain.PolicyError{Status: 403, Code: "FORBIDDEN", Message: "Your role does not allow this"}
	ErrCSRF         = &domain.PolicyError{Status: 403, Code: "CSRF", Message: "Reload the page and try again"}
	ErrEmailTaken   = &domain.PolicyError{Status: 409, Code: "EMAIL_TAKEN", Message: "An operator with this email already exists"}
	ErrWeakPassword = &domain.ValidationError{Field: "password", Message: "use at least 12 characters"}
	ErrCurrentWrong = &domain.PolicyError{Status: 403, Code: "CURRENT_PASSWORD", Message: "The current password is not right"}
)

const operatorLock = 4917303 // serializes changes to the set of operators (last-admin rule)

// Reason is the mandatory justification of every action. It is trimmed and must be 10 to 1000
// characters of ordinary text.
func Reason(s string) (string, error) {
	s = strings.TrimSpace(s)
	if n := utf8.RuneCountInString(s); n < 10 {
		return "", &domain.ValidationError{Field: "reason", Message: "give a reason of at least 10 characters"}
	} else if n > 1000 {
		return "", &domain.ValidationError{Field: "reason", Message: "keep the reason under 1000 characters"}
	}
	for _, r := range s {
		if r == 0 || (r < 32 && r != '\n' && r != '\t') {
			return "", &domain.ValidationError{Field: "reason", Message: "contains characters that cannot be stored"}
		}
	}
	return s, nil
}

// Service is the console's domain layer: staff accounts, sessions, the audit log, and the moderation
// actions it delegates to the shared store methods the moderate CLI also uses.
type Service struct {
	Store *store.Store
	Pool  *pgxpool.Pool
	// Media is the console's read-only view of the media bucket; nil when ADMIN_MEDIA_* is not set.
	Media media.Store
	// Evidence is the console's READ-ONLY view of the evidence bucket (ADMIN_EVIDENCE_*), where quarantined
	// originals live apart from the media bucket. Nil: the cases are read from Media (shared bucket).
	Evidence media.Store
	// EvidenceDelete is the separate credential that removes released holds. Only the purge job
	// (PurgeHolds) uses it; no request handler does.
	EvidenceDelete media.Store
	cfg            Config
	keys           keys
	// Now is the clock for one-time codes and signed cursors. Session and lockout expiry use the
	// database clock, so every node agrees on them.
	Now func() time.Time
	// Session lifetimes: absolute, and idle.
	AbsoluteTimeout, IdleTimeout time.Duration
	// Lockout: failures per account and per client address within the window.
	MaxFailures   int
	FailureWindow time.Duration

	slots     chan struct{} // bounds concurrent password hashing (64 MiB each)
	dummyHash string        // checked when the account is unknown, so timing does not tell
	dummyKey  []byte
	passwords PasswordParams
}

// NewService builds the service. It hashes one throwaway password now, which costs one hash.
func NewService(db *store.Store, cfg Config) (*Service, error) {
	k, err := newKeys(cfg.DataKey)
	if err != nil {
		return nil, err
	}
	s := &Service{Store: db, Pool: db.Pool, cfg: cfg, keys: k, Now: time.Now,
		AbsoluteTimeout: 8 * time.Hour, IdleTimeout: 30 * time.Minute, MaxFailures: 5, FailureWindow: 15 * time.Minute,
		slots: make(chan struct{}, 4), passwords: DefaultPasswordParams}
	junk, err := randomToken()
	if err != nil {
		return nil, err
	}
	if s.dummyHash, err = HashPassword(junk, s.passwords); err != nil {
		return nil, err
	}
	s.dummyKey = NewTOTPSecret()
	return s, nil
}

// evidenceReader is where quarantined photos are read: the evidence bucket, else the media bucket.
func (s *Service) evidenceReader() media.Store {
	if s.Evidence != nil {
		return s.Evidence
	}
	return s.Media
}

type queryer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func (s *Service) inTx(ctx context.Context, work func(pgx.Tx) error) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = work(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// hashSlot runs f holding one of the password hashing slots.
func (s *Service) hashSlot(ctx context.Context, f func()) error {
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
		f()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

const operatorColumns = `operator_id::text,email,display_name,role,disabled_at,created_at,last_login_at`

func scanOperator(row pgx.Row) (Operator, error) {
	var o Operator
	return o, row.Scan(&o.ID, &o.Email, &o.DisplayName, &o.Role, &o.DisabledAt, &o.CreatedAt, &o.LastLoginAt)
}

// ListOperators lists every staff account, never their credentials.
func (s *Service) ListOperators(ctx context.Context) ([]Operator, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+operatorColumns+` FROM operators ORDER BY created_at,operator_id`)
	if err != nil {
		return nil, err
	}
	ops, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Operator, error) { return scanOperator(row) })
	if ops == nil && err == nil {
		ops = []Operator{}
	}
	return ops, err
}

func (s *Service) operatorByID(ctx context.Context, q queryer, id string) (Operator, error) {
	o, err := scanOperator(q.QueryRow(ctx, `SELECT `+operatorColumns+` FROM operators WHERE operator_id=$1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return o, domain.ErrNotFound
	}
	return o, err
}

// Enrolment is what operator-add and operator-reset hand the person once: the secret is never shown again.
type Enrolment struct {
	Operator Operator
	TOTPSeed []byte
	OTPAuth  string
	SeedText string
}

func checkPassword(p string) error {
	if utf8.RuneCountInString(p) < MinPasswordLength || len(p) > MaxPasswordLength {
		return ErrWeakPassword
	}
	return nil
}

// CreateOperator adds a staff account (the CLI is the only caller). The password is hashed here and never
// logged; the TOTP seed is returned for one-time display. actor names who ran the command.
func (s *Service) CreateOperator(ctx context.Context, email, displayName string, role Role, password, actor string) (Enrolment, error) {
	var e Enrolment
	email, ok := NormalizeEmail(email)
	if !ok {
		return e, &domain.ValidationError{Field: "email", Message: "not a valid address"}
	}
	displayName = strings.TrimSpace(displayName)
	if n := utf8.RuneCountInString(displayName); n < 1 || n > 80 {
		return e, &domain.ValidationError{Field: "name", Message: "use 1 to 80 characters"}
	}
	if role.rank() == 0 {
		return e, &domain.ValidationError{Field: "role", Message: "must be viewer, moderator or admin"}
	}
	if err := checkPassword(password); err != nil {
		return e, err
	}
	var hash string
	var herr error
	if err := s.hashSlot(ctx, func() { hash, herr = HashPassword(password, s.passwords) }); err != nil || herr != nil {
		return e, errors.Join(err, herr)
	}
	id := uuid.Must(uuid.NewV7()).String()
	seed := NewTOTPSecret()
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO operators(operator_id,email,display_name,role,password_hash,totp_secret) VALUES($1,$2,$3,$4,$5,$6)`,
			id, email, displayName, string(role), hash, s.keys.seal(seed, id)); err != nil {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "23505" {
				return ErrEmailTaken
			}
			return err
		}
		return insertAudit(ctx, tx, AuditEntry{Actor: actor, Action: "operator_create", TargetType: "operator", TargetID: id,
			Detail: map[string]any{"email": email, "role": string(role)}})
	})
	if err != nil {
		return e, err
	}
	e.Operator, err = s.operatorByID(ctx, s.Pool, id)
	e.TOTPSeed, e.SeedText, e.OTPAuth = seed, TOTPSecretText(seed), OTPAuthURI("Hiyall Admin", email, seed)
	return e, err
}

// ResetOperator sets a new password and a new TOTP seed for an existing account and ends its sessions:
// the answer to a lost phone or a suspected leak. CLI only.
func (s *Service) ResetOperator(ctx context.Context, email, password, actor string) (Enrolment, error) {
	var e Enrolment
	email, ok := NormalizeEmail(email)
	if !ok {
		return e, &domain.ValidationError{Field: "email", Message: "not a valid address"}
	}
	if err := checkPassword(password); err != nil {
		return e, err
	}
	var hash string
	var herr error
	if err := s.hashSlot(ctx, func() { hash, herr = HashPassword(password, s.passwords) }); err != nil || herr != nil {
		return e, errors.Join(err, herr)
	}
	seed := NewTOTPSecret()
	var id string
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT operator_id::text FROM operators WHERE email=$1 FOR UPDATE`, email).Scan(&id); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return domain.ErrNotFound
			}
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE operators SET password_hash=$2,totp_secret=$3,totp_last_step=0 WHERE operator_id=$1`, id, hash, s.keys.seal(seed, id)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE operator_sessions SET revoked_at=now() WHERE operator_id=$1 AND revoked_at IS NULL`, id); err != nil {
			return err
		}
		return insertAudit(ctx, tx, AuditEntry{Actor: actor, Action: "operator_reset", TargetType: "operator", TargetID: id, Detail: map[string]any{"email": email}})
	})
	if err != nil {
		return e, err
	}
	e.Operator, err = s.operatorByID(ctx, s.Pool, id)
	e.TOTPSeed, e.SeedText, e.OTPAuth = seed, TOTPSecretText(seed), OTPAuthURI("Hiyall Admin", email, seed)
	return e, err
}

// Actor identifies who is changing operators: a signed-in operator, or the CLI.
type Actor struct {
	Operator *Operator // nil for the CLI
	Label    string    // "cli:<os user>" for the CLI
	IP       string    // truncated
}

func (a Actor) entry(action, targetType, targetID, reason string, detail map[string]any) AuditEntry {
	e := AuditEntry{Action: action, TargetType: targetType, TargetID: targetID, Reason: reason, IP: a.IP, Detail: detail}
	if a.Operator != nil {
		id := a.Operator.ID
		e.OperatorID, e.Actor = &id, a.Operator.Email
	} else {
		e.Actor = a.Label
	}
	return e
}

// activeAdminsExcept counts enabled admins other than id.
func activeAdminsExcept(ctx context.Context, tx pgx.Tx, id string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM operators WHERE role='admin' AND disabled_at IS NULL AND operator_id<>$1`, id).Scan(&n)
	return n, err
}

// SetDisabled disables or re-enables an account. Disabling ends its sessions in the same transaction.
// Over HTTP an administrator cannot disable themselves or the last active administrator; the CLI
// (guards=false) can, because a stolen administrator device must be shut out even if it was the only one.
func (s *Service) SetDisabled(ctx context.Context, actor Actor, id string, disable bool, reason string, guards bool) (Operator, error) {
	var out Operator
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, operatorLock); err != nil {
			return err
		}
		target, err := s.operatorByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if disable == (target.DisabledAt != nil) {
			return ErrNoChange
		}
		if disable && guards {
			if actor.Operator != nil && actor.Operator.ID == id {
				return ErrSelfDisable
			}
			if target.Role == RoleAdmin {
				if n, err := activeAdminsExcept(ctx, tx, id); err != nil {
					return err
				} else if n == 0 {
					return ErrLastAdmin
				}
			}
		}
		action := "operator_enable"
		if disable {
			action = "operator_disable"
			if _, err = tx.Exec(ctx, `UPDATE operators SET disabled_at=now() WHERE operator_id=$1`, id); err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `UPDATE operator_sessions SET revoked_at=now() WHERE operator_id=$1 AND revoked_at IS NULL`, id); err != nil {
				return err
			}
		} else if _, err = tx.Exec(ctx, `UPDATE operators SET disabled_at=NULL WHERE operator_id=$1`, id); err != nil {
			return err
		}
		if err = insertAudit(ctx, tx, actor.entry(action, "operator", id, reason, map[string]any{"email": target.Email})); err != nil {
			return err
		}
		out, err = s.operatorByID(ctx, tx, id)
		return err
	})
	return out, err
}

// SetRole changes an account's role. The last active administrator cannot be demoted. Sessions stay
// open: the role is read from the database on every request, so the change applies at once.
func (s *Service) SetRole(ctx context.Context, actor Actor, id string, role Role, reason string) (Operator, error) {
	var out Operator
	if role.rank() == 0 {
		return out, &domain.ValidationError{Field: "role", Message: "must be viewer, moderator or admin"}
	}
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, operatorLock); err != nil {
			return err
		}
		target, err := s.operatorByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if target.Role == role {
			return ErrNoChange
		}
		if target.Role == RoleAdmin && target.DisabledAt == nil {
			if n, err := activeAdminsExcept(ctx, tx, id); err != nil {
				return err
			} else if n == 0 {
				return ErrLastAdmin
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE operators SET role=$2 WHERE operator_id=$1`, id, string(role)); err != nil {
			return err
		}
		if err = insertAudit(ctx, tx, actor.entry("operator_role", "operator", id, reason, map[string]any{"email": target.Email, "from": string(target.Role), "to": string(role)})); err != nil {
			return err
		}
		out, err = s.operatorByID(ctx, tx, id)
		return err
	})
	return out, err
}
