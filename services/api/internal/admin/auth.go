package admin

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Staff authentication, independent of member sign-in.
//
//   - A password (argon2id) and a one-time code (TOTP, mandatory, no bypass) are checked together in one
//     request, so a wrong password and a wrong code are indistinguishable, and so is an unknown account.
//   - Every attempt is recorded before it is checked, under a lock, so concurrent guesses cannot beat the
//     limit of 5 failures per account and per client address per 15 minutes. The records are in the
//     database: the limit survives restarts and applies across nodes. Counting is keyed on the e-mail the
//     caller typed whether or not an account exists.
//   - A code is accepted once: the step that matched is stored and must be newer than the last one used.
//   - A session is a random 256-bit token; only its SHA-256 is stored. It expires 8 hours after sign-in
//     and after 30 idle minutes, and ends when the account is disabled.

const attemptLock = 4917304

// Session is what a successful sign-in returns. Token goes into the cookie only, never the body.
type Session struct {
	Token     string
	CSRF      string
	SessionID string
	Operator  Operator
	ExpiresAt time.Time
}

// Principal is the authenticated caller of one request.
type Principal struct {
	Operator  Operator
	SessionID string
	CSRF      string
	ExpiresAt time.Time
	IP        string // truncated client address
}

func (s *Service) csrfFor(token string) string {
	return base64.RawURLEncoding.EncodeToString(s.keys.mac("csrf", token))
}

// reserveAttempt records an attempt as failed (it is marked successful later) unless the account or the
// address is already over the limit, in which case it returns a 429 with Retry-After.
func (s *Service) reserveAttempt(ctx context.Context, account, ip []byte) (int64, error) {
	var id int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, attemptLock); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM operator_login_attempts WHERE at < now()-interval '2 days'`); err != nil {
			return err
		}
		var byAccount, byIP int
		var oldestAccount, oldestIP *time.Time
		window := s.FailureWindow.Seconds()
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE account_key=$1),count(*) FILTER (WHERE ip_key=$2),
 min(at) FILTER (WHERE account_key=$1),min(at) FILTER (WHERE ip_key=$2)
 FROM operator_login_attempts WHERE NOT succeeded AND at > now()-make_interval(secs=>$3)`, account, ip, window).
			Scan(&byAccount, &byIP, &oldestAccount, &oldestIP); err != nil {
			return err
		}
		if byAccount >= s.MaxFailures || byIP >= s.MaxFailures {
			var oldest *time.Time
			if byAccount >= s.MaxFailures {
				oldest = oldestAccount
			}
			if byIP >= s.MaxFailures && (oldest == nil || (oldestIP != nil && oldestIP.After(*oldest))) {
				oldest = oldestIP
			}
			retry := s.FailureWindow
			if oldest != nil {
				if left := time.Until(oldest.Add(s.FailureWindow)); left > 0 && left < retry {
					retry = left
				}
			}
			return domain.RetryAfter(ErrLocked, retry)
		}
		return tx.QueryRow(ctx, `INSERT INTO operator_login_attempts(account_key,ip_key) VALUES($1,$2) RETURNING attempt_id`, account, ip).Scan(&id)
	})
	return id, err
}

type operatorRecord struct {
	Operator
	passwordHash string
	totpSealed   []byte
	lastStep     int64
}

func (s *Service) operatorRecordByEmail(ctx context.Context, email string) (*operatorRecord, error) {
	var r operatorRecord
	err := s.Pool.QueryRow(ctx, `SELECT `+operatorColumns+`,password_hash,totp_secret,totp_last_step FROM operators WHERE email=$1`, email).
		Scan(&r.ID, &r.Email, &r.DisplayName, &r.Role, &r.DisabledAt, &r.CreatedAt, &r.LastLoginAt, &r.passwordHash, &r.totpSealed, &r.lastStep)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &r, err
}

// Login checks email, password and one-time code together and opens a session. Every failure is
// ErrBadCreds (401) except a lockout (429); nothing says which part was wrong or whether the account exists.
func (s *Service) Login(ctx context.Context, email, password, code, ip string) (Session, error) {
	var out Session
	norm, _ := NormalizeEmail(email) // an invalid address is just a failure that still costs the same work
	if len(norm) > 254 {
		norm = norm[:254]
	}
	if len(password) > MaxPasswordLength {
		password = password[:MaxPasswordLength]
	}
	account, ipKey := s.keys.mac("account", norm), s.keys.mac("ip", ip)
	attempt, err := s.reserveAttempt(ctx, account, ipKey)
	if err != nil {
		return out, err
	}
	rec, err := s.operatorRecordByEmail(ctx, norm)
	if err != nil {
		return out, err
	}
	hash, secret, step0 := s.dummyHash, s.dummyKey, int64(0)
	if rec != nil {
		hash, step0 = rec.passwordHash, rec.lastStep
		if open, e := s.keys.open(rec.totpSealed, rec.ID); e == nil {
			secret = open
		} else {
			rec = nil // a secret that cannot be opened (wrong ADMIN_DATA_KEY) never signs anyone in
		}
	}
	var passwordOK bool
	if err = s.hashSlot(ctx, func() { passwordOK, _ = VerifyPassword(password, hash) }); err != nil {
		return out, err
	}
	step, codeOK := VerifyTOTP(secret, code, s.Now())
	if rec == nil || rec.DisabledAt != nil || !passwordOK || !codeOK || step <= step0 {
		return out, ErrBadCreds
	}
	token, err := randomToken()
	if err != nil {
		return out, err
	}
	out = Session{Token: token, CSRF: s.csrfFor(token), SessionID: uuid.Must(uuid.NewV7()).String(), Operator: rec.Operator}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		// Consuming the step is the replay check: two requests with the same code race here, one wins.
		tag, err := tx.Exec(ctx, `UPDATE operators SET totp_last_step=$2,last_login_at=now() WHERE operator_id=$1 AND totp_last_step<$2 AND disabled_at IS NULL`, rec.ID, step)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrBadCreds
		}
		if err = tx.QueryRow(ctx, `INSERT INTO operator_sessions(session_id,operator_id,token_hash,expires_at,ip) VALUES($1,$2,$3,now()+make_interval(secs=>$4),$5) RETURNING expires_at`,
			out.SessionID, rec.ID, tokenHash(token), s.AbsoluteTimeout.Seconds(), TruncateIP(ip)).Scan(&out.ExpiresAt); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE operator_login_attempts SET succeeded=true WHERE attempt_id=$1`, attempt); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `DELETE FROM operator_sessions WHERE expires_at < now()-interval '7 days' OR revoked_at < now()-interval '7 days'`); err != nil {
			return err
		}
		id := rec.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &id, Actor: rec.Email, Action: "login", TargetType: "session", TargetID: out.SessionID, IP: TruncateIP(ip)})
	})
	if err != nil {
		return Session{}, err
	}
	out.Operator.LastLoginAt = nil
	return out, nil
}

// Authenticate resolves a session token. The operator's role and disabled state come from the database
// on every call, so disabling an account or changing its role applies to open sessions at once.
func (s *Service) Authenticate(ctx context.Context, token string) (*Principal, error) {
	if token == "" || len(token) > 128 {
		return nil, ErrUnauthorized
	}
	var p Principal
	err := s.Pool.QueryRow(ctx, `SELECT s.session_id::text,s.expires_at,o.operator_id::text,o.email,o.display_name,o.role,o.created_at,o.last_login_at
 FROM operator_sessions s JOIN operators o ON o.operator_id=s.operator_id
 WHERE s.token_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND s.last_seen_at>now()-make_interval(secs=>$2) AND o.disabled_at IS NULL`,
		tokenHash(token), s.IdleTimeout.Seconds()).
		Scan(&p.SessionID, &p.ExpiresAt, &p.Operator.ID, &p.Operator.Email, &p.Operator.DisplayName, &p.Operator.Role, &p.Operator.CreatedAt, &p.Operator.LastLoginAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	// Idle time is measured from the last request; write at most every 15 seconds.
	if _, err = s.Pool.Exec(ctx, `UPDATE operator_sessions SET last_seen_at=now() WHERE session_id=$1 AND last_seen_at<now()-interval '15 seconds'`, p.SessionID); err != nil {
		return nil, err
	}
	p.CSRF = s.csrfFor(token)
	return &p, nil
}

// Logout ends the session and records it.
func (s *Service) Logout(ctx context.Context, p *Principal) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE operator_sessions SET revoked_at=now() WHERE session_id=$1 AND revoked_at IS NULL`, p.SessionID); err != nil {
			return err
		}
		id := p.Operator.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &id, Actor: p.Operator.Email, Action: "logout", TargetType: "session", TargetID: p.SessionID, IP: p.IP})
	})
}

// ChangePassword sets a new password for the signed-in operator after checking the current one, and
// ends their other sessions. Wrong guesses count against the same lockout as sign-in.
func (s *Service) ChangePassword(ctx context.Context, p *Principal, current, next, ip string) error {
	if err := checkPassword(next); err != nil {
		return err
	}
	if len(current) > MaxPasswordLength {
		current = current[:MaxPasswordLength]
	}
	attempt, err := s.reserveAttempt(ctx, s.keys.mac("account", p.Operator.Email), s.keys.mac("ip", ip))
	if err != nil {
		return err
	}
	var hash string
	if err = s.Pool.QueryRow(ctx, `SELECT password_hash FROM operators WHERE operator_id=$1`, p.Operator.ID).Scan(&hash); err != nil {
		return err
	}
	var ok bool
	if err = s.hashSlot(ctx, func() { ok, _ = VerifyPassword(current, hash) }); err != nil {
		return err
	}
	if !ok {
		return ErrCurrentWrong
	}
	var fresh string
	var herr error
	if err = s.hashSlot(ctx, func() { fresh, herr = HashPassword(next, s.passwords) }); err != nil || herr != nil {
		return errors.Join(err, herr)
	}
	return s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE operators SET password_hash=$2 WHERE operator_id=$1`, p.Operator.ID, fresh); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE operator_sessions SET revoked_at=now() WHERE operator_id=$1 AND session_id<>$2 AND revoked_at IS NULL`, p.Operator.ID, p.SessionID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE operator_login_attempts SET succeeded=true WHERE attempt_id=$1`, attempt); err != nil {
			return err
		}
		id := p.Operator.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &id, Actor: p.Operator.Email, Action: "password_change", TargetType: "operator", TargetID: id, IP: p.IP})
	})
}
