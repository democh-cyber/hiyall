package store

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"math/rand/v2"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"hiyall/services/api/internal/domain"
)

type Store struct {
	Pool *pgxpool.Pool
	// AgeBandIsolation keeps minors and adults apart: interaction_barred is true across
	// bands as well as for blocks. It is set on every connection (see New); false restores
	// block-only behaviour. The minor defaults and the coarser minor location do not depend on it.
	AgeBandIsolation bool
	tracer           pgx.QueryTracer
	dsn              string
	maxConns         int32
	timeouts         Timeouts
}

// Timeouts are set on every connection of a pool (see New). A zero value turns that limit off, as in
// PostgreSQL.
type Timeouts struct {
	// Statement cancels one statement that runs longer (statement_timeout).
	Statement time.Duration
	// Lock cancels a statement that waits longer for a lock (lock_timeout).
	Lock time.Duration
	// IdleInTransaction ends a session that sits idle inside an open transaction
	// (idle_in_transaction_session_timeout), so a stuck request cannot hold row locks for ever.
	IdleInTransaction time.Duration
}

// Request-path defaults: a request has a 10 second deadline, so nothing in it may run longer than 5.
var DefaultTimeouts = Timeouts{Statement: 5 * time.Second, Lock: 3 * time.Second, IdleInTransaction: 15 * time.Second}

// MaintenanceTimeouts are for the background jobs and the data export, which run bigger statements
// than a request ever should.
var MaintenanceTimeouts = Timeouts{Statement: 2 * time.Minute, Lock: 10 * time.Second, IdleInTransaction: 2 * time.Minute}

// DefaultMaxConns is the pool size unless WithMaxConns or the DSN's pool_max_conns says otherwise.
const DefaultMaxConns = 20

// Option configures New.
type Option func(*Store)

// WithAgeBandIsolation sets Store.AgeBandIsolation (default true).
func WithAgeBandIsolation(on bool) Option { return func(s *Store) { s.AgeBandIsolation = on } }

// WithMaxConns sets the pool size (default DefaultMaxConns). A pool_max_conns in the DSN wins.
func WithMaxConns(n int32) Option { return func(s *Store) { s.maxConns = n } }

// WithTimeouts replaces DefaultTimeouts for every connection of the pool.
func WithTimeouts(t Timeouts) Option { return func(s *Store) { s.timeouts = t } }

// WithQueryTracer attaches a pgx tracer to every connection of the pool (tests count statements with it).
func WithQueryTracer(t pgx.QueryTracer) Option { return func(s *Store) { s.tracer = t } }

// Principal is the authenticated caller. Onboarded is false until the account has
// completed onboarding; the HTTP layer refuses most routes until then.
type Principal struct {
	UserID, SessionID string
	Onboarded         bool
	// PendingDeletion is true while the account has asked to be deleted and is inside the grace
	// period. Such a member can sign in, but the API serves them only the deletion status, the
	// cancel route and the sign-out routes (see httpapi pendingDeletionAllowed).
	PendingDeletion bool
}
type Session struct {
	SessionID  string     `json:"sessionId"`
	Platform   string     `json:"platform"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastSeenAt time.Time  `json:"lastSeenAt"`
	ExpiresAt  time.Time  `json:"expiresAt"`
	Current    bool       `json:"current"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

func New(ctx context.Context, dsn string, opts ...Option) (*Store, error) {
	s := &Store{AgeBandIsolation: true, dsn: dsn, maxConns: DefaultMaxConns, timeouts: DefaultTimeouts}
	for _, option := range opts {
		option(s)
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	// interaction_barred (migration 0017) reads the isolation switch from the session, so
	// every connection of this pool carries this process's setting.
	isolation := "on"
	if !s.AgeBandIsolation {
		isolation = "off"
	}
	cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		// Every timestamp the API returns is UTC whatever the server's own zone: timestamptz
		// values are scanned in UTC, and the session zone is UTC for anything formatted in SQL.
		conn.TypeMap().RegisterType(&pgtype.Type{Name: "timestamptz", OID: pgtype.TimestamptzOID, Codec: &pgtype.TimestamptzCodec{ScanLocation: time.UTC}})
		// Timeouts in milliseconds: a request that hits one fails fast instead of piling up behind a lock.
		ms := func(d time.Duration) string { return strconv.FormatInt(d.Milliseconds(), 10) }
		_, err := conn.Exec(ctx, `SELECT set_config('hiyall.age_band_isolation',$1,false),set_config('TimeZone','UTC',false),
 set_config('statement_timeout',$2,false),set_config('lock_timeout',$3,false),set_config('idle_in_transaction_session_timeout',$4,false)`,
			isolation, ms(s.timeouts.Statement), ms(s.timeouts.Lock), ms(s.timeouts.IdleInTransaction))
		return err
	}
	cfg.ConnConfig.Tracer = s.tracer
	if !strings.Contains(dsn, "pool_max_conns") {
		cfg.MaxConns = s.maxConns
	}
	cfg.MinConns = 1
	cfg.MaxConnLifetime = 30 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err = pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	s.Pool = pool
	return s, nil
}

// NewMaintenance opens a small second pool for the background jobs, with MaintenanceTimeouts: their
// batches may legitimately run far longer than the request path allows. Close it with Pool.Close.
func (s *Store) NewMaintenance(ctx context.Context) (*Store, error) {
	return New(ctx, s.dsn, WithAgeBandIsolation(s.AgeBandIsolation), WithMaxConns(4), WithTimeouts(MaintenanceTimeouts))
}

func newID() string { return uuid.Must(uuid.NewV7()).String() }

// usernameConstraint is profiles.username's UNIQUE constraint (migration 0001).
const usernameConstraint = "profiles_username_key"

func mapped(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.ErrNotFound
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23505" {
		// Only the username's own constraint means "taken"; any other duplicate is a race on
		// something else, and the caller is told to reload rather than that a name is taken.
		if pe.ConstraintName == usernameConstraint {
			return domain.ErrUsernameTaken
		}
		return domain.ErrConflict
	}
	// Text PostgreSQL cannot store (NUL, invalid byte sequence) is the caller's input.
	if errors.As(err, &pe) && (pe.Code == "22021" || pe.Code == "22P05") {
		return &domain.ValidationError{Field: "body", Message: "contains characters that cannot be stored"}
	}
	// A foreign key violation means an id the caller supplied names nothing.
	if errors.As(err, &pe) && pe.Code == "23503" {
		return domain.ErrNotFound
	}
	return err
}

// provision creates the account rows. Fixture accounts are provisioned complete;
// every account created through sign-in starts with an incomplete onboarding row.
func provision(ctx context.Context, tx pgx.Tx, id, username, name string, onboarded bool) error {
	if _, err := tx.Exec(ctx, `INSERT INTO users(user_id) VALUES($1)`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO onboarding(user_id,completed_at,terms_version) VALUES($1,CASE WHEN $2::boolean THEN now() END,CASE WHEN $2::boolean THEN 'fixture' END)`, id, onboarded); err != nil {
		return err
	}
	privacyDefaults := domain.DefaultPrivacy()
	profile := domain.Profile{Username: username, DisplayName: name, Timezone: "Asia/Kolkata", Locale: "en", Languages: domain.Languages{{Code: "en", Level: domain.LanguageLevelDefault}}, PersonalityTags: []string{}, ProfileAudience: privacyDefaults.ProfileAudience, ProfileAccent: "lime", ProfilePattern: "glow", AvatarFrame: "minimal"}
	data, _ := json.Marshal(profile)
	if _, err := tx.Exec(ctx, `INSERT INTO profiles(user_id,username,data) VALUES($1,$2,$3)`, id, username, data); err != nil {
		return err
	}
	privacy, _ := json.Marshal(privacyDefaults)
	_, err := tx.Exec(ctx, `INSERT INTO privacy_settings(user_id,data) VALUES($1,$2)`, id, privacy)
	return err
}

// SamID is the development fixture that is created without a finished profile
// and without onboarding, so the first-run flow can be exercised through /dev/session.
const SamID = "019a4000-0000-7000-8000-0000000000a1"

// KaiID is the development fixture that is a minor (declared age 15 when it was created),
// onboarded, with the minor defaults, so the minor experience can be tried through /dev/session.
const KaiID = "019a4000-0000-7000-8000-0000000000a2"

// Seed is explicitly called only by the development bootstrap. It creates no credentials.
// It is idempotent: existing fixtures are never reset, and Sam's onboarding is never completed.
// Anjali and Niko are adults and Kai is a minor; an existing database gains the missing
// birth dates of Anjali and Niko the first time the API starts after migration 0017.
func (s *Store) Seed(ctx context.Context) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, fixture := range []struct {
		id, username, name string
		onboarded          bool
		birth              time.Time // zero: no birth date is stored (Sam is not onboarded yet)
	}{
		{"019a4000-0000-7000-8000-000000000001", "anjali", "Anjali", true, time.Date(1998, 4, 12, 0, 0, 0, 0, time.UTC)},
		{"019a4000-0000-7000-8000-000000000002", "niko", "Niko", true, time.Date(1996, 9, 30, 0, 0, 0, 0, time.UTC)},
		{SamID, domain.PlaceholderUsername(SamID), domain.PlaceholderDisplayName, false, time.Time{}},
		// Kai is 15 and a half when first created; the date does not move afterwards.
		{KaiID, "kai", "Kai", true, time.Now().UTC().AddDate(-15, -6, 0)},
	} {
		var exists bool
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$1)`, fixture.id).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			if err = provision(ctx, tx, fixture.id, fixture.username, fixture.name, fixture.onboarded); err != nil {
				return err
			}
			if !fixture.birth.IsZero() {
				if err = recordBirth(ctx, tx, fixture.id, fixture.birth, true); err != nil {
					return err
				}
			}
			continue
		}
		// An existing fixture only gains a missing row; a present row is left as it is.
		if _, err = tx.Exec(ctx, `INSERT INTO onboarding(user_id,completed_at,terms_version) VALUES($1,CASE WHEN $2::boolean THEN now() END,CASE WHEN $2::boolean THEN 'fixture' END) ON CONFLICT(user_id) DO NOTHING`, fixture.id, fixture.onboarded); err != nil {
			return err
		}
		if !fixture.birth.IsZero() {
			if err = recordBirth(ctx, tx, fixture.id, fixture.birth, false); err != nil {
				return err
			}
		}
	}
	return tx.Commit(ctx)
}

// Platforms a session can report; anything else is stored as unknown.
func SessionPlatform(value string) string {
	switch value {
	case "android", "ios", "web":
		return value
	}
	return "unknown"
}

func (s *Store) CreateDevSession(ctx context.Context, userID, token, platform string) (Principal, error) {
	hash := sha256.Sum256([]byte(token))
	sid := newID()
	tag, err := s.Pool.Exec(ctx, `INSERT INTO sessions(session_id,user_id,access_token_hash,expires_at,platform) SELECT $1,user_id,$2,now()+interval '30 minutes',$4 FROM users WHERE user_id=$3 AND status IN ('active','pending_deletion')`, sid, hash[:], userID, SessionPlatform(platform))
	if err != nil {
		return Principal{}, err
	}
	if tag.RowsAffected() != 1 {
		return Principal{}, domain.ErrUnauthorized
	}
	return Principal{UserID: userID, SessionID: sid}, nil
}
func (s *Store) VerifyDevSession(ctx context.Context, token string) (Principal, error) {
	hash := sha256.Sum256([]byte(token))
	var p Principal
	// Every request authenticates, so the session row is read, not written;
	// last_seen_at is refreshed at most once a minute.
	var stale bool
	err := s.Pool.QueryRow(ctx, `SELECT s.user_id::text,s.session_id::text,s.last_seen_at<now()-interval '1 minute',o.completed_at IS NOT NULL,u.status='pending_deletion' FROM sessions s JOIN users u ON u.user_id=s.user_id LEFT JOIN onboarding o ON o.user_id=s.user_id
 WHERE s.access_token_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status IN ('active','pending_deletion')`, hash[:]).Scan(&p.UserID, &p.SessionID, &stale, &p.Onboarded, &p.PendingDeletion)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, domain.ErrUnauthorized
	}
	if err == nil && stale {
		_, err = s.Pool.Exec(ctx, `UPDATE sessions SET last_seen_at=now() WHERE session_id=$1 AND last_seen_at<now()-interval '1 minute'`, p.SessionID)
	}
	return p, err
}

// sessionTouchInterval is how often a session's last_seen_at is written: at most once a minute.
const sessionTouchInterval = time.Minute

// ResolveOIDC authenticates one token of an identity provider session.
//
// The common case is a session that already exists and is live: one read-only statement (no
// transaction, no row lock, no advisory lock), plus a conditional single-row UPDATE only when last_seen_at
// is older than a minute or the token outlives the session's expiry. Everything else (a first sign-in, a
// session that expired, was revoked, or a Firebase sign-in older than a sign-out-everywhere watermark)
// takes resolveOIDCSlow, which is transactionally fenced by issuer/subject: a revoked sid is never
// silently recreated by a still-valid token.
func (s *Store) ResolveOIDC(ctx context.Context, issuer, subject, sid string, expiry time.Time) (Principal, error) {
	var p Principal
	var status string
	var due bool
	err := s.Pool.QueryRow(ctx, `SELECT s.user_id::text,s.session_id::text,o.completed_at IS NOT NULL,u.status,
 (s.last_seen_at<now()-$5::interval OR s.expires_at<$4)
 FROM auth_identities a JOIN sessions s ON s.issuer=a.issuer AND s.external_sid=$3 AND s.user_id=a.user_id
 JOIN users u ON u.user_id=a.user_id LEFT JOIN onboarding o ON o.user_id=a.user_id
 WHERE a.issuer=$1 AND a.subject=$2 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status IN ('active','pending_deletion')`,
		issuer, subject, sid, expiry, sessionTouchInterval).Scan(&p.UserID, &p.SessionID, &p.Onboarded, &status, &due)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return s.resolveOIDCSlow(ctx, issuer, subject, sid, expiry)
	case err != nil:
		return Principal{}, err
	}
	p.PendingDeletion = status == "pending_deletion"
	if due {
		// Guarded again so that a revocation that landed since the read is never undone, and two requests
		// that both saw a stale row write it once.
		if _, err = s.Pool.Exec(ctx, `UPDATE sessions SET last_seen_at=now(),expires_at=greatest(expires_at,$2) WHERE session_id=$1 AND revoked_at IS NULL AND (last_seen_at<now()-$3::interval OR expires_at<$2)`,
			p.SessionID, expiry, sessionTouchInterval); err != nil {
			return Principal{}, err
		}
	}
	return p, nil
}

func (s *Store) resolveOIDCSlow(ctx context.Context, issuer, subject, sid string, expiry time.Time) (Principal, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return Principal{}, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, issuer+"\x1f"+subject); err != nil {
		return Principal{}, err
	}
	var id string
	err = tx.QueryRow(ctx, `SELECT user_id::text FROM auth_identities WHERE issuer=$1 AND subject=$2`, issuer, subject).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		id = newID()
		// The random UUID suffix is normalized for the username grammar. The account is
		// incomplete: it cannot use the app until onboarding is finished.
		if err = provision(ctx, tx, id, domain.PlaceholderUsername(id), domain.PlaceholderDisplayName, false); err != nil {
			return Principal{}, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO auth_identities(issuer,subject,user_id) VALUES($1,$2,$3)`, issuer, subject, id); err != nil {
			return Principal{}, err
		}
	} else if err != nil {
		return Principal{}, err
	}
	// A member who asked to delete their account signs in like anyone else; the API then serves them
	// only the deletion routes (Principal.PendingDeletion). Any other state is refused.
	var status string
	// A database error here (lock timeout, deadlock, connection lost) is the server's, and reaches the caller as
	// such (a 503 the app retries); only a missing or inactive account is a refusal.
	if err = tx.QueryRow(ctx, `SELECT status FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Principal{}, domain.ErrUnauthorized
		}
		return Principal{}, err
	}
	if status != "active" && status != "pending_deletion" {
		return Principal{}, domain.ErrUnauthorized
	}
	// A Firebase sign-in from before "sign out everywhere else" never gets a session row it
	// did not already have, even if this server never saw it (see RevokeOtherSessions).
	if authTime, ok := firebaseAuthTime(issuer, subject, sid); ok {
		var refused bool
		err = tx.QueryRow(ctx, `SELECT coalesce(to_timestamp($3::bigint)<=a.sessions_revoked_before,false) AND NOT EXISTS(SELECT 1 FROM sessions s WHERE s.issuer=$1 AND s.external_sid=$4)
 FROM auth_identities a WHERE a.issuer=$1 AND a.subject=$2`, issuer, subject, authTime, sid).Scan(&refused)
		if err != nil {
			return Principal{}, err
		}
		if refused {
			return Principal{}, domain.ErrUnauthorized
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO sessions(session_id,user_id,issuer,external_sid,expires_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(issuer,external_sid) DO UPDATE SET last_seen_at=now(),expires_at=greatest(sessions.expires_at,excluded.expires_at) WHERE sessions.revoked_at IS NULL AND sessions.user_id=excluded.user_id`, newID(), id, issuer, sid, expiry)
	if err != nil {
		return Principal{}, err
	}
	var p Principal
	err = tx.QueryRow(ctx, `SELECT s.user_id::text,s.session_id::text,o.completed_at IS NOT NULL FROM sessions s LEFT JOIN onboarding o ON o.user_id=s.user_id WHERE s.issuer=$1 AND s.external_sid=$2 AND s.user_id=$3 AND s.revoked_at IS NULL AND s.expires_at>now()`, issuer, sid, id).Scan(&p.UserID, &p.SessionID, &p.Onboarded)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, domain.ErrUnauthorized
	}
	if err != nil {
		return p, err
	}
	p.PendingDeletion = status == "pending_deletion"
	return p, tx.Commit(ctx)
}

// firebaseIssuerPrefix matches identity.FirebaseIssuer; the store cannot import identity.
const firebaseIssuerPrefix = "https://securetoken.google.com/"

// firebaseAuthTime reads auth_time (Unix seconds) from a Firebase session id,
// "fb:<sub>:<auth_time>" (see identity.firebaseClaims). ok is false for any other sid.
func firebaseAuthTime(issuer, subject, sid string) (int64, bool) {
	if !strings.HasPrefix(issuer, firebaseIssuerPrefix) {
		return 0, false
	}
	rest, found := strings.CutPrefix(sid, "fb:"+subject+":")
	if !found || rest == "" || len(rest) > 18 {
		return 0, false
	}
	for _, c := range rest {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	at, err := strconv.ParseInt(rest, 10, 64)
	return at, err == nil
}

// scanProfile reads the six profile columns, then any extra destinations the query appends.
func scanProfile(row pgx.Row, extra ...any) (domain.Profile, error) {
	var p domain.Profile
	var data []byte
	var version int64
	err := row.Scan(append([]any{&p.UserID, &p.Username, &data, &version, &p.CreatedAt, &p.UpdatedAt}, extra...)...)
	if err != nil {
		return p, mapped(err)
	}
	id, username, created, updated := p.UserID, p.Username, p.CreatedAt, p.UpdatedAt
	if err = json.Unmarshal(data, &p); err != nil {
		return p, err
	}
	p.UserID = id
	p.Username = username
	p.CreatedAt = created
	p.UpdatedAt = updated
	p.Version = strconv.FormatInt(version, 10)
	return p, nil
}

// GetProfile is the caller's own profile with signed URLs for their photo (see avatar.go).
func (s *Store) GetProfile(ctx context.Context, id string, sign Signer) (domain.ProfileView, error) {
	var thumb, full *string
	p, err := scanProfile(s.Pool.QueryRow(ctx, `SELECT p.user_id::text,p.username,p.data || jsonb_build_object('socialStats',jsonb_build_object('friends',greatest(coalesce(c.friends,0),0),'following',greatest(coalesce(c.following,0),0),'followers',greatest(coalesce(c.followers,0),0),
 'visitors',`+visitorsSQL("p.user_id")+`,
 'stories',(SELECT count(*) FROM stories st WHERE st.author_id=p.user_id AND st.deleted_at IS NULL AND st.expires_at>now()))),p.version,p.created_at,p.updated_at,`+avatarThumbKey("av")+`,`+avatarFullKey("av")+`
 FROM profiles p JOIN users u USING(user_id) LEFT JOIN social_counters c USING(user_id)`+avatarJoin("av", "p")+`WHERE p.user_id=$1 AND u.status='active'`, id), &thumb, &full)
	if err != nil {
		return domain.ProfileView{}, err
	}
	photos, err := profilePhotos(ctx, s.Pool, id, sign)
	return domain.ProfileView{Profile: p, AvatarURL: avatarURL(sign, thumb), AvatarFullURL: avatarURL(sign, full), Photos: photos}, err
}
func (s *Store) GetPrivacy(ctx context.Context, id string) (domain.Privacy, error) {
	var p domain.Privacy
	var data []byte
	var version int64
	var updated time.Time
	err := s.Pool.QueryRow(ctx, `SELECT p.data,p.version,p.updated_at FROM privacy_settings p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status='active'`, id).Scan(&data, &version, &updated)
	if err != nil {
		return p, mapped(err)
	}
	if p, err = normalizePrivacy(data); err != nil {
		return p, err
	}
	p.Version = strconv.FormatInt(version, 10)
	p.UpdatedAt = updated
	return p, nil
}

// appendEvent does nothing. It staged an outbox event and bumped users.aggregate_version until audit D5
// (migration 0038 dropped the table and the column). Only the chat device calls in chat.go remain; they go
// with this when that file next changes.
func appendEvent(context.Context, pgx.Tx, string, string, int64) error { return nil }

// UpdateProfile applies a validated patch at the expected version and returns the profile as GetProfile does.
// A new avatarMediaId must be the caller's own ready, unattached photo; it is attached in the same
// transaction as the update, and the photo it replaces (or that null clears) is released for deletion.
func (s *Store) UpdateProfile(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage, sign Signer) (domain.ProfileView, error) {
	return s.UpdateProfileFor(ctx, id, expected, patch, domain.Free(), sign)
}

// UpdateProfileFor is UpdateProfile under the member's own limits (languages, interests and personality tags).
func (s *Store) UpdateProfileFor(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage, e domain.Entitlements, sign Signer) (domain.ProfileView, error) {
	if err := s.updateProfileFor(ctx, id, expected, patch, e); err != nil {
		return domain.ProfileView{}, err
	}
	return s.GetProfile(ctx, id, sign)
}

func (s *Store) updateProfile(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage) error {
	return s.updateProfileFor(ctx, id, expected, patch, domain.Free())
}

func (s *Store) updateProfileFor(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage, e domain.Entitlements) error {
	if err := domain.ValidateProfilePatchFor(patch, e); err != nil {
		return err
	}
	// A member under 18 may set a hometown too, a shorter one (it is shown only to their friends).
	if raw, ok := patch["hometown"]; ok && string(raw) != `""` {
		var value string
		_ = json.Unmarshal(raw, &value)
		if minor, err := s.IsMinor(ctx, id); err != nil {
			return err
		} else if minor {
			if err = domain.ValidateHometown(value, true); err != nil {
				return err
			}
		}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var active bool
	// Only "no such account" and "not active" are a 404; a lock timeout, a cancelled statement or a broken
	// connection keeps its class (the central mapping answers 503 for the first three).
	if err = tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&active); err != nil {
		return mapped(err)
	} else if !active {
		return domain.ErrNotFound
	}
	p, err := scanProfile(tx.QueryRow(ctx, `SELECT p.user_id::text,p.username,p.data,p.version,p.created_at,p.updated_at FROM profiles p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status='active' FOR NO KEY UPDATE OF u,p`, id))
	if err != nil {
		return err
	}
	current, _ := strconv.ParseInt(p.Version, 10, 64)
	if current != expected {
		return domain.ErrConflict
	}
	// A different avatar is claimed before anything is written; the one it replaces is released after.
	var released *string
	if raw, ok := patch["avatarMediaId"]; ok {
		var next *string
		_ = json.Unmarshal(raw, &next) // a photo id or null, checked by ValidateProfilePatch
		if (next == nil) != (p.AvatarMediaID == nil) || next != nil && *next != *p.AvatarMediaID {
			if next != nil {
				if err = claimMedia(ctx, tx, id, "avatar", []string{*next}); errors.Is(err, domain.ErrMediaNotReady) {
					return &domain.ValidationError{Field: "avatarMediaId", Message: "upload your photo and finish the upload first"}
				} else if err != nil {
					return err
				}
			}
			if p.AvatarMediaID != nil {
				// A copy: unmarshalling the merged profile below writes through the pointer.
				previous := *p.AvatarMediaID
				released = &previous
			}
			// The profile photo is the first photo of the gallery (profile_photos): a new one takes its place, and
			// clearing it removes it and promotes the next photo, so the two never disagree.
			ids, gerr := galleryIDs(ctx, tx, id)
			if gerr != nil {
				return gerr
			}
			switch {
			case next != nil && len(ids) == 0:
				ids = []string{*next}
			case next != nil:
				ids[0] = *next
			case len(ids) > 0:
				ids = ids[1:]
			}
			if gerr = writeGalleryRows(ctx, tx, id, ids); gerr != nil {
				return gerr
			}
			var first json.RawMessage = []byte("null")
			if len(ids) > 0 {
				first, _ = json.Marshal(ids[0])
			}
			patch["avatarMediaId"] = first
		}
	}
	data, _ := json.Marshal(p)
	var merged map[string]json.RawMessage
	_ = json.Unmarshal(data, &merged)
	for key, value := range patch {
		merged[key] = value
	}
	for _, derived := range []string{"userId", "version", "createdAt", "updatedAt", "socialStats"} {
		delete(merged, derived)
	}
	data, _ = json.Marshal(merged)
	previous := p.Username
	_ = json.Unmarshal(data, &p)
	// Generated handles are never offered, so nobody can claim one as a real name.
	if p.Username != previous && domain.IsPlaceholderUsername(p.Username) {
		return &domain.ValidationError{Field: "username", Message: "this username is reserved"}
	}
	// A rename starts a 30 day cooldown, except the first real name chosen over the generated one. The row is
	// locked above, so two renames cannot both pass.
	renamed := p.Username != previous && !domain.IsPlaceholderUsername(previous)
	if renamed {
		var wait float64
		if err = tx.QueryRow(ctx, `SELECT coalesce(greatest(0,extract(epoch FROM (username_changed_at+$2::interval-now()))),0)::float8 FROM profiles WHERE user_id=$1`, id, domain.UsernameChangeCooldown).Scan(&wait); err != nil {
			return err
		}
		if wait > 0 {
			return domain.RetryAfter(domain.ErrUsernameCooldown, time.Duration(wait*float64(time.Second)))
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE profiles SET username=$2,data=$3,version=version+1,updated_at=now(),username_changed_at=CASE WHEN $4::boolean THEN now() ELSE username_changed_at END WHERE user_id=$1`, id, p.Username, data, renamed); err != nil {
		return mapped(err)
	}
	if released != nil {
		// The objects are removed by the media cleanup (MediaGarbage), not here.
		if _, err = tx.Exec(ctx, `UPDATE media_assets SET status='deleted',deleted_at=now() WHERE media_id=$1 AND owner_id=$2 AND purpose='avatar' AND status<>'deleted'`, *released, id); err != nil {
			return err
		}
	}
	if audience, ok := patch["profileAudience"]; ok {
		if _, err = tx.Exec(ctx, `UPDATE privacy_settings SET data=jsonb_set(data,'{profileAudience}',$2::jsonb),version=version+1,updated_at=now() WHERE user_id=$1`, id, string(audience)); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
func (s *Store) UpdatePrivacy(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage) (domain.Privacy, error) {
	if err := domain.ValidatePrivacyPatch(patch); err != nil {
		return domain.Privacy{}, err
	}
	// A member under 18 cannot loosen presence, location or connections past the minor defaults.
	if minor, err := s.IsMinor(ctx, id); err != nil {
		return domain.Privacy{}, err
	} else if minor {
		if err = domain.ValidateMinorPrivacyPatch(patch); err != nil {
			return domain.Privacy{}, err
		}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Privacy{}, err
	}
	defer tx.Rollback(ctx)
	var active bool
	if err = tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&active); err != nil {
		return domain.Privacy{}, mapped(err)
	} else if !active {
		return domain.Privacy{}, domain.ErrNotFound
	}
	var data []byte
	var current int64
	err = tx.QueryRow(ctx, `SELECT p.data,p.version FROM privacy_settings p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status='active' FOR NO KEY UPDATE OF u,p`, id).Scan(&data, &current)
	if err != nil {
		return domain.Privacy{}, mapped(err)
	}
	if current != expected {
		return domain.Privacy{}, domain.ErrConflict
	}
	var merged map[string]json.RawMessage
	_ = json.Unmarshal(data, &merged)
	for key, value := range patch {
		if key == "fieldAudiences" {
			var old, next map[string]string
			_ = json.Unmarshal(merged[key], &old)
			_ = json.Unmarshal(value, &next)
			for field, audience := range next {
				old[field] = audience
			}
			value, _ = json.Marshal(old)
		}
		merged[key] = value
	}
	data, _ = json.Marshal(merged)
	if _, err = tx.Exec(ctx, `UPDATE privacy_settings SET data=$2,version=version+1,updated_at=now() WHERE user_id=$1`, id, data); err != nil {
		return domain.Privacy{}, err
	}
	if audience, ok := patch["profileAudience"]; ok {
		if _, err = tx.Exec(ctx, `UPDATE profiles SET data=jsonb_set(data,'{profileAudience}',$2::jsonb),version=version+1,updated_at=now() WHERE user_id=$1`, id, string(audience)); err != nil {
			return domain.Privacy{}, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return domain.Privacy{}, err
	}
	return s.GetPrivacy(ctx, id)
}

// VisibleProfile projects target for viewer from one read-only snapshot. Blocked,
// other-age-band (see interaction_barred) and inactive accounts are missing. A profile whose audience excludes the viewer
// is a locked card: identity, style and the relationship needed to ask for access.
// An account that has not finished onboarding is visible only to itself.
// `age` is whole years only, shown to another member under the conditions at the end of the projection.
// Presence follows the target's onlineAudience (see presenceFor): `online` is true when they are online, and
// otherwise `lastSeenAt` is their last activity rounded down to five minutes; both are omitted when the
// audience does not admit the viewer, so hiding looks like offline, and on a locked card. A member always
// sees their own.
// `avatarUrl` is a signed thumbnail of the profile photo (null without one), also on a locked card; `avatarFullUrl`
// is the full-size photo and is null on a locked card (see avatar.go).
func (s *Store) VisibleProfile(ctx context.Context, viewer, target string, online Presence, sign Signer) (map[string]any, error) {
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var data, policyData []byte
	var username string
	var counts domain.SocialStats
	var age, birthMonth, birthDay *int
	var thumb, full *string
	err = tx.QueryRow(ctx, `SELECT p.data,p.username,q.data,greatest(coalesce(c.friends,0),0),greatest(coalesce(c.following,0),0),greatest(coalesce(c.followers,0),0),`+visitorsSQL("p.user_id")+`,
 (SELECT count(*) FROM stories st WHERE st.author_id=p.user_id AND st.deleted_at IS NULL AND st.expires_at>now() AND `+visibleTo("st.author_id", "st.audience")+`),member_age(p.user_id),`+avatarThumbKey("av")+`,`+avatarFullKey("av")+`,
 (SELECT extract(month FROM birth_date)::int FROM member_ages WHERE user_id=p.user_id),(SELECT extract(day FROM birth_date)::int FROM member_ages WHERE user_id=p.user_id) FROM profiles p JOIN privacy_settings q USING(user_id) JOIN users u USING(user_id) LEFT JOIN social_counters c USING(user_id)`+avatarJoin("av", "p")+`WHERE p.user_id=$2 AND u.status='active' AND ($1=$2 OR (NOT `+barredBetween+` AND EXISTS(SELECT 1 FROM onboarding o WHERE o.user_id=p.user_id AND o.completed_at IS NOT NULL)))`, viewer, target).Scan(&data, &username, &policyData, &counts.Friends, &counts.Following, &counts.Followers, &counts.Visitors, &counts.Stories, &age, &thumb, &full, &birthMonth, &birthDay)
	if err != nil {
		return nil, mapped(err)
	}
	var p domain.Profile
	if err = json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	q, err := normalizePrivacy(policyData)
	if err != nil {
		return nil, err
	}
	self := viewer == target
	var rel domain.Relationship
	if !self {
		if rel, err = relationship(ctx, tx, viewer, target, q); err != nil {
			return nil, err
		}
	}
	result := map[string]any{"userId": target, "username": username, "displayName": p.DisplayName, "profileAccent": p.ProfileAccent, "profilePattern": p.ProfilePattern, "avatarFrame": p.AvatarFrame, "avatarUrl": avatarURL(sign, thumb), "avatarFullUrl": (*string)(nil)}
	if !self {
		result["relationship"] = rel
		result["locked"] = !rel.Allows(q.ProfileAudience)
		// A locked card shows who the person is, photo included, but only as a thumbnail.
		if result["locked"] == true {
			return result, nil
		}
	}
	result["avatarFullUrl"] = avatarURL(sign, full)
	result["headline"], result["quote"], result["bio"] = p.Headline, p.Quote, p.Bio
	// Inside this read-only snapshot, like the relationship above.
	found, err := s.presenceFor(ctx, tx, viewer, []presenceTarget{{ID: target, Audience: q.OnlineAudience}}, online)
	if err != nil {
		return nil, err
	}
	setPresence(result, found[target])
	show := func(field string) bool { return self || rel.Allows(q.FieldAudiences[field]) }
	// The counts have their own audience (default everyone); the lists they summarise keep "connections".
	if show("counts") {
		result["socialStats"] = counts
	}
	// Whether the followers and following lists may be opened: the same rule CanSeeConnections applies.
	if !self {
		result["canSeeConnections"] = show("connections")
	}
	if show("interests") {
		result["interests"] = p.Interests
	}
	if show("vibe") {
		result["currentVibe"] = p.CurrentVibe
	}
	if show("pronouns") {
		result["pronouns"] = p.Pronouns
	}
	if show("gender") {
		result["gender"] = p.Gender
	}
	// Whole years only, never the birth date or a band, and only to another member whose view is not
	// the locked card, when the age is known and the member's age audience allows the viewer. The
	// owner's own profile never carries it, and it is omitted rather than null or 0.
	if !self && age != nil && rel.Allows(q.FieldAudiences["age"]) {
		result["age"] = *age
	}
	if show("profession") {
		result["profession"] = p.Profession
	}
	if show("education") {
		result["education"] = p.Education
	}
	if show("timezone") {
		result["timezone"] = p.Timezone
	}
	if show("languages") {
		result["languages"] = p.Languages
	}
	if show("website") && p.WebsiteURL != nil {
		result["websiteUrl"] = *p.WebsiteURL
	}
	if show("location") && p.Country != nil {
		result["country"] = *p.Country
	}
	// Profile v2. A member under 18 (a known age under 18; no birth date is an adult) never shows a birthday or a
	// visitor list, whatever their stored settings say.
	minor := age != nil && *age < domain.AdultAge
	if show("aboutMe") {
		result["aboutMe"] = p.AboutMe
	}
	// A minor's hometown is for confirmed friends only (the same age band is already guaranteed above), whatever
	// audience is stored; an adult's follows their audience.
	if (!minor && show("hometown")) || (minor && (self || (q.FieldAudiences["hometown"] == "friends" && rel.Friends()))) {
		result["hometown"] = p.Hometown
	}
	if show("personality") {
		tags := p.PersonalityTags
		if tags == nil {
			tags = []string{}
		}
		result["personalityTags"] = tags
	}
	// Month and day only, never the year; adults only, and only to the audience the member chose.
	if !self && !minor && q.ShowBirthday && birthMonth != nil && birthDay != nil && rel.Allows(q.FieldAudiences["birthday"]) {
		result["birthday"] = map[string]int{"month": *birthMonth, "day": *birthDay}
	}
	if q.ShowLocalTime || self {
		if lt := domain.LocalTimeFor(p.Timezone, time.Now()); lt != nil {
			result["localTime"] = lt
		}
	}
	if !self && !minor && q.VisitorsVisibleToOthers {
		result["visitorsVisible"] = true
	}
	photos, err := profilePhotos(ctx, tx, target, sign)
	if err != nil {
		return nil, err
	}
	result["photos"] = photos
	return result, nil
}

// SetBlock severs every relationship between the pair when blocking. Unblocking
// works even after the other account is deactivated, and restores nothing.
func (s *Store) SetBlock(ctx context.Context, actor, target string, blocked bool) error {
	if actor == target {
		return &domain.ValidationError{Field: "userId", Message: "cannot block yourself"}
	}
	return s.inTx(ctx, func(tx pgx.Tx) error { return setBlockTx(ctx, tx, actor, target, blocked) })
}

// setBlockTx is SetBlock inside the caller's transaction (CreateReport blocks in the same one).
func setBlockTx(ctx context.Context, tx pgx.Tx, actor, target string, blocked bool) error {
	// Ordered user locks prevent deadlock on reciprocal blocks.
	rows, err := tx.Query(ctx, `SELECT user_id::text,status FROM users WHERE user_id IN ($1,$2) ORDER BY user_id FOR NO KEY UPDATE`, actor, target)
	if err != nil {
		return err
	}
	statuses := map[string]string{}
	for rows.Next() {
		var id, status string
		if err = rows.Scan(&id, &status); err != nil {
			rows.Close()
			return err
		}
		statuses[id] = status
	}
	rows.Close()
	if rows.Err() != nil {
		return rows.Err()
	}
	if statuses[actor] != "active" || statuses[target] == "" || (blocked && statuses[target] != "active") {
		return domain.ErrNotFound
	}
	if !blocked {
		_, err = tx.Exec(ctx, `DELETE FROM blocks WHERE blocker_id=$1 AND blocked_id=$2`, actor, target)
		return err
	}
	for _, statement := range []string{
		`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING`,
		`UPDATE follows SET state='removed',removed_at=now() WHERE ((follower_id=$1 AND followee_id=$2) OR (follower_id=$2 AND followee_id=$1)) AND state<>'removed'`,
		`UPDATE friendships SET status=CASE WHEN status='accepted' THEN 'removed' ELSE 'cancelled' END,updated_at=now() WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid) AND status IN ('pending','accepted')`,
		`DELETE FROM notifications WHERE (recipient_id=$1 AND actor_id=$2) OR (recipient_id=$2 AND actor_id=$1)`,
		`UPDATE conversations SET status='closed' WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`,
		// The pair's encrypted attachments go too (evidence held for a report excepted); the clean-up job removes the objects.
		`UPDATE chat_blobs SET state='deleted',deleted_at=now() WHERE state<>'deleted' AND held_report_id IS NULL AND conversation_id IN (SELECT conversation_id FROM conversations WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid))`,
		`DELETE FROM message_envelopes e USING messages m, devices d WHERE e.message_id=m.message_id AND e.recipient_device_id=d.device_id AND e.delivered_at IS NULL AND ((m.sender_id=$1 AND d.user_id=$2) OR (m.sender_id=$2 AND d.user_id=$1))`,
	} {
		if _, err = tx.Exec(ctx, statement, actor, target); err != nil {
			return err
		}
	}
	return nil
}

// SessionLive reports whether a session still authenticates: not revoked, not expired, and
// the account active. Realtime connections check it at every heartbeat.
func (s *Store) SessionLive(ctx context.Context, sessionID string) (bool, error) {
	var live bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id WHERE s.session_id=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status='active')`, sessionID).Scan(&live)
	return live, err
}

// RevokeSession signs out one of the caller's sessions, expired or not. The row stays as a
// tombstone (see PurgeSessions).
func (s *Store) RevokeSession(ctx context.Context, p Principal, target string) error {
	tag, err := s.Pool.Exec(ctx, `UPDATE sessions SET revoked_at=coalesce(revoked_at,now()) WHERE session_id=$1 AND user_id=$2`, target, p.UserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return nil
}

// RevokeOtherSessions signs the account out everywhere except this session. An identity
// provider's session is revoked whether or not its last token has expired: the device can
// refresh it at any time, so an idle device is still signed in. The identity's watermark
// (auth_identities.sessions_revoked_before) also refuses any Firebase sign-in from before
// now that has no session row yet. A development session that has expired is already dead
// and is not counted.
func (s *Store) RevokeOtherSessions(ctx context.Context, p Principal) (int64, error) {
	var count int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND session_id<>$2 AND revoked_at IS NULL AND (external_sid IS NOT NULL OR expires_at>now())`, p.UserID, p.SessionID)
		if err != nil {
			return err
		}
		count = tag.RowsAffected()
		_, err = tx.Exec(ctx, `UPDATE auth_identities SET sessions_revoked_before=now() WHERE user_id=$1`, p.UserID)
		return err
	})
	return count, err
}

// providerSessionIdle is how long an unrevoked identity-provider session row is kept after
// it was last used. A refreshed token recreates a purged row, except for a Firebase sign-in
// from before a "sign out everywhere else" watermark, so the device that signed the others
// out has to sign in again only after this long without using the app.
const providerSessionIdle = 400 * 24 * time.Hour

// PurgeSessions deletes at most batch session rows that expired more than retain ago:
// development sessions (their token cannot be refreshed), and identity-provider sessions
// that were never revoked and have not been used for providerSessionIdle. A revoked
// identity-provider session is a tombstone and is not purged here: a still-valid refresh token
// keeps minting tokens for the same sid, and only the tombstone stops it recreating the session.
// PurgeRevokedSessionTombstones removes one after 400 days, and only when the identity's "sign out
// everywhere" watermark refuses that sign-in without it.
func (s *Store) PurgeSessions(ctx context.Context, retain time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM sessions WHERE ctid IN (SELECT ctid FROM sessions
 WHERE (external_sid IS NULL OR revoked_at IS NULL) AND expires_at<now()-$1::interval AND (external_sid IS NULL OR last_seen_at<now()-$3::interval)
 ORDER BY expires_at LIMIT $2)`, retain, batch, providerSessionIdle)
	return tag.RowsAffected(), err
}

// sessionListWindow is how recently an identity-provider session must have been used to be listed.
const sessionListWindow = 30 * 24 * time.Hour

func (s *Store) ListSessions(ctx context.Context, p Principal, limit int, before *time.Time, beforeID string) ([]Session, error) {
	// Revoked sessions are history, not access. An identity-provider session whose last token
	// expired is still signed in (the device refreshes it), so it is listed while it was used
	// within sessionListWindow; a development session is listed only until it expires.
	rows, err := s.Pool.Query(ctx, `SELECT session_id::text,created_at,last_seen_at,expires_at,platform,revoked_at FROM sessions WHERE user_id=$1 AND revoked_at IS NULL
 AND (expires_at>now() OR (external_sid IS NOT NULL AND last_seen_at>now()-$5::interval))
 AND ($3::timestamptz IS NULL OR (created_at,session_id)<($3,$4::uuid)) ORDER BY created_at DESC,session_id DESC LIMIT $2`, p.UserID, limit, before, beforeID, sessionListWindow)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Session{}
	for rows.Next() {
		var item Session
		if err = rows.Scan(&item.SessionID, &item.CreatedAt, &item.LastSeenAt, &item.ExpiresAt, &item.Platform, &item.RevokedAt); err != nil {
			return nil, err
		}
		item.Current = item.SessionID == p.SessionID
		result = append(result, item)
	}
	return result, rows.Err()
}

// visitorsSQL is the number of different members who have opened the profile, as a sum of the
// counter's slots (see RecordProfileVisit). It reads at most 8 rows.
func visitorsSQL(profile string) string {
	return `coalesce((SELECT sum(vc.visitors) FROM profile_visit_counts vc WHERE vc.profile_id=` + profile + `),0)::bigint`
}

// RecordProfileVisit records that viewer opened target's profile, once per pair for ever, and reports
// whether this was the first time. A repeat visit only reads: the existence check means no row is
// written and no counter is touched, so a hot profile's repeat views never queue behind each other.
// A first visit inserts the pair and increments one of 8 counter slots in the same statement, and only when
// the insert happened, so the counter never exceeds the number of rows even under concurrent views. Who
// visited is read back only by the owner's own visitor list (ListVisitors). Callers record only after the profile was opened successfully:
// not for oneself, and not when the request was refused as blocked, in another age band or not found.
func (s *Store) RecordProfileVisit(ctx context.Context, viewer, target string) (bool, error) {
	if viewer == target {
		return false, nil
	}
	var inserted bool
	err := s.Pool.QueryRow(ctx, `WITH ins AS (
  INSERT INTO profile_visits(profile_id,visitor_id)
  SELECT $2::uuid,$1::uuid WHERE NOT EXISTS(SELECT 1 FROM profile_visits WHERE profile_id=$2::uuid AND visitor_id=$1::uuid)
  ON CONFLICT DO NOTHING RETURNING 1),
 bump AS (
  INSERT INTO profile_visit_counts(profile_id,slot,visitors) SELECT $2::uuid,$3::smallint,1 FROM ins
  ON CONFLICT (profile_id,slot) DO UPDATE SET visitors=profile_visit_counts.visitors+1 RETURNING 1),
 touch AS (
  UPDATE profile_visits SET last_visited_at=now() WHERE profile_id=$2::uuid AND visitor_id=$1::uuid AND last_visited_at<now()-interval '1 hour' RETURNING 1)
 SELECT EXISTS(SELECT 1 FROM ins)`, viewer, target, rand.IntN(8)).Scan(&inserted)
	return inserted, err
}
