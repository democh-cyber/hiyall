package store

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"kairova/services/api/internal/domain"
)

type Store struct{ Pool *pgxpool.Pool }
type Principal struct{ UserID, SessionID string }
type Session struct {
	SessionID  string     `json:"sessionId"`
	Platform   string     `json:"platform"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastSeenAt time.Time  `json:"lastSeenAt"`
	ExpiresAt  time.Time  `json:"expiresAt"`
	Current    bool       `json:"current"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

func New(ctx context.Context, dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 10
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
	return &Store{pool}, nil
}

func newID() string { return uuid.Must(uuid.NewV7()).String() }
func mapped(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.ErrNotFound
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23505" {
		return domain.ErrUsernameTaken
	}
	return err
}

func provision(ctx context.Context, tx pgx.Tx, id, username, name string) error {
	if _, err := tx.Exec(ctx, `INSERT INTO users(user_id) VALUES($1)`, id); err != nil {
		return err
	}
	profile := domain.Profile{Username: username, DisplayName: name, Timezone: "Asia/Kolkata", Locale: "en", Languages: domain.Languages{{Code: "en"}}, ProfileAudience: "friends", ProfileAccent: "lime", ProfilePattern: "glow", AvatarFrame: "minimal"}
	data, _ := json.Marshal(profile)
	if _, err := tx.Exec(ctx, `INSERT INTO profiles(user_id,username,data) VALUES($1,$2,$3)`, id, username, data); err != nil {
		return err
	}
	privacy, _ := json.Marshal(domain.DefaultPrivacy())
	_, err := tx.Exec(ctx, `INSERT INTO privacy_settings(user_id,data) VALUES($1,$2)`, id, privacy)
	return err
}

// Seed is explicitly called only by the development bootstrap. It creates no credentials.
func (s *Store) Seed(ctx context.Context) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, fixture := range [][3]string{{"019a4000-0000-7000-8000-000000000001", "anjali", "Anjali"}, {"019a4000-0000-7000-8000-000000000002", "niko", "Niko"}} {
		var exists bool
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$1)`, fixture[0]).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			if err = provision(ctx, tx, fixture[0], fixture[1], fixture[2]); err != nil {
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
	tag, err := s.Pool.Exec(ctx, `INSERT INTO sessions(session_id,user_id,access_token_hash,expires_at,platform) SELECT $1,user_id,$2,now()+interval '30 minutes',$4 FROM users WHERE user_id=$3 AND status='active'`, sid, hash[:], userID, SessionPlatform(platform))
	if err != nil {
		return Principal{}, err
	}
	if tag.RowsAffected() != 1 {
		return Principal{}, domain.ErrUnauthorized
	}
	return Principal{userID, sid}, nil
}
func (s *Store) VerifyDevSession(ctx context.Context, token string) (Principal, error) {
	hash := sha256.Sum256([]byte(token))
	var p Principal
	// Every request authenticates, so the session row is read, not written;
	// last_seen_at is refreshed at most once a minute.
	var stale bool
	err := s.Pool.QueryRow(ctx, `SELECT s.user_id::text,s.session_id::text,s.last_seen_at<now()-interval '1 minute' FROM sessions s JOIN users u ON u.user_id=s.user_id
 WHERE s.access_token_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status='active'`, hash[:]).Scan(&p.UserID, &p.SessionID, &stale)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, domain.ErrUnauthorized
	}
	if err == nil && stale {
		_, err = s.Pool.Exec(ctx, `UPDATE sessions SET last_seen_at=now() WHERE session_id=$1 AND last_seen_at<now()-interval '1 minute'`, p.SessionID)
	}
	return p, err
}

// OIDC identity and session registration are transactionally fenced by issuer/sub.
// A revoked sid is never silently recreated by a still-valid token.
func (s *Store) ResolveOIDC(ctx context.Context, issuer, subject, sid string, expiry time.Time) (Principal, error) {
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
		username := "member_" + uuid.MustParse(id).String()[24:]
		// The random UUID suffix is normalized for the username grammar.

		if err = provision(ctx, tx, id, username, "Kairova member"); err != nil {
			return Principal{}, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO auth_identities(issuer,subject,user_id) VALUES($1,$2,$3)`, issuer, subject, id); err != nil {
			return Principal{}, err
		}
	} else if err != nil {
		return Principal{}, err
	}
	var active bool
	if err = tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR UPDATE`, id).Scan(&active); err != nil || !active {
		return Principal{}, domain.ErrUnauthorized
	}
	_, err = tx.Exec(ctx, `INSERT INTO sessions(session_id,user_id,issuer,external_sid,expires_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(issuer,external_sid) DO UPDATE SET last_seen_at=now(),expires_at=greatest(sessions.expires_at,excluded.expires_at) WHERE sessions.revoked_at IS NULL AND sessions.user_id=excluded.user_id`, newID(), id, issuer, sid, expiry)
	if err != nil {
		return Principal{}, err
	}
	var p Principal
	err = tx.QueryRow(ctx, `SELECT user_id::text,session_id::text FROM sessions WHERE issuer=$1 AND external_sid=$2 AND user_id=$3 AND revoked_at IS NULL AND expires_at>now()`, issuer, sid, id).Scan(&p.UserID, &p.SessionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, domain.ErrUnauthorized
	}
	if err != nil {
		return p, err
	}
	return p, tx.Commit(ctx)
}

func scanProfile(row pgx.Row) (domain.Profile, error) {
	var p domain.Profile
	var data []byte
	var version int64
	err := row.Scan(&p.UserID, &p.Username, &data, &version, &p.CreatedAt, &p.UpdatedAt)
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
func (s *Store) GetProfile(ctx context.Context, id string) (domain.Profile, error) {
	return scanProfile(s.Pool.QueryRow(ctx, `SELECT p.user_id::text,p.username,p.data || jsonb_build_object('socialStats',jsonb_build_object('friends',c.friends,'following',c.following,'followers',c.followers)),p.version,p.created_at,p.updated_at FROM profiles p JOIN users u USING(user_id) JOIN profile_social_counts c USING(user_id) WHERE p.user_id=$1 AND u.status='active'`, id))
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

func appendEvent(ctx context.Context, tx pgx.Tx, id, kind string, resourceVersion int64) error {
	var version int64
	if err := tx.QueryRow(ctx, `UPDATE users SET aggregate_version=aggregate_version+1 WHERE user_id=$1 RETURNING aggregate_version`, id).Scan(&version); err != nil {
		return err
	}
	payload := map[string]any{}
	if resourceVersion > 0 {
		payload["resourceVersion"] = resourceVersion
	}
	data, _ := json.Marshal(payload)
	_, err := tx.Exec(ctx, `INSERT INTO outbox_events(event_id,aggregate_type,aggregate_id,aggregate_version,event_type,payload) VALUES($1,'user',$2,$3,$4,$5)`, newID(), id, version, kind, data)
	return err
}

func (s *Store) UpdateProfile(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage) (domain.Profile, error) {
	if err := domain.ValidateProfilePatch(patch); err != nil {
		return domain.Profile{}, err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Profile{}, err
	}
	defer tx.Rollback(ctx)
	var active bool
	if err = tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR UPDATE`, id).Scan(&active); err != nil || !active {
		return domain.Profile{}, domain.ErrNotFound
	}
	p, err := scanProfile(tx.QueryRow(ctx, `SELECT p.user_id::text,p.username,p.data,p.version,p.created_at,p.updated_at FROM profiles p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status='active' FOR UPDATE OF u,p`, id))
	if err != nil {
		return p, err
	}
	current, _ := strconv.ParseInt(p.Version, 10, 64)
	if current != expected {
		return p, domain.ErrConflict
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
	_ = json.Unmarshal(data, &p)
	if _, err = tx.Exec(ctx, `UPDATE profiles SET username=$2,data=$3,version=version+1,updated_at=now() WHERE user_id=$1`, id, p.Username, data); err != nil {
		return p, mapped(err)
	}
	if audience, ok := patch["profileAudience"]; ok {
		if _, err = tx.Exec(ctx, `UPDATE privacy_settings SET data=jsonb_set(data,'{profileAudience}',$2::jsonb),version=version+1,updated_at=now() WHERE user_id=$1`, id, string(audience)); err != nil {
			return p, err
		}
	}
	if err = appendEvent(ctx, tx, id, "profile.updated", current+1); err != nil {
		return p, err
	}
	if err = tx.Commit(ctx); err != nil {
		return p, err
	}
	return s.GetProfile(ctx, id)
}
func (s *Store) UpdatePrivacy(ctx context.Context, id string, expected int64, patch map[string]json.RawMessage) (domain.Privacy, error) {
	if err := domain.ValidatePrivacyPatch(patch); err != nil {
		return domain.Privacy{}, err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Privacy{}, err
	}
	defer tx.Rollback(ctx)
	var active bool
	if err = tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR UPDATE`, id).Scan(&active); err != nil || !active {
		return domain.Privacy{}, domain.ErrNotFound
	}
	var data []byte
	var current int64
	err = tx.QueryRow(ctx, `SELECT p.data,p.version FROM privacy_settings p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status='active' FOR UPDATE OF u,p`, id).Scan(&data, &current)
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
	if err = appendEvent(ctx, tx, id, "privacy.updated", current+1); err != nil {
		return domain.Privacy{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return domain.Privacy{}, err
	}
	return s.GetPrivacy(ctx, id)
}

// VisibleProfile projects target for viewer from one read-only snapshot. Blocked
// and inactive accounts are missing. A profile whose audience excludes the viewer
// is a locked card: identity, style and the relationship needed to ask for access.
func (s *Store) VisibleProfile(ctx context.Context, viewer, target string) (map[string]any, error) {
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var data, policyData []byte
	var username string
	var counts domain.SocialStats
	err = tx.QueryRow(ctx, `SELECT p.data,p.username,q.data,c.friends,c.following,c.followers FROM profiles p JOIN privacy_settings q USING(user_id) JOIN users u USING(user_id) JOIN profile_social_counts c USING(user_id) WHERE p.user_id=$2 AND u.status='active' AND ($1=$2 OR NOT `+blockedBetween+`)`, viewer, target).Scan(&data, &username, &policyData, &counts.Friends, &counts.Following, &counts.Followers)
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
	result := map[string]any{"userId": target, "username": username, "displayName": p.DisplayName, "profileAccent": p.ProfileAccent, "profilePattern": p.ProfilePattern, "avatarFrame": p.AvatarFrame}
	if !self {
		result["relationship"] = rel
		result["locked"] = !rel.Allows(q.ProfileAudience)
		if result["locked"] == true {
			return result, nil
		}
	}
	result["headline"], result["quote"], result["bio"] = p.Headline, p.Quote, p.Bio
	show := func(field string) bool { return self || rel.Allows(q.FieldAudiences[field]) }
	if show("connections") {
		result["socialStats"] = counts
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
	return result, nil
}

// SetBlock severs every relationship between the pair when blocking. Unblocking
// works even after the other account is deactivated, and restores nothing.
func (s *Store) SetBlock(ctx context.Context, actor, target string, blocked bool) error {
	if actor == target {
		return &domain.ValidationError{Field: "userId", Message: "cannot block yourself"}
	}
	return s.inTx(ctx, func(tx pgx.Tx) error {
		// Ordered user locks prevent deadlock on reciprocal blocks.
		rows, err := tx.Query(ctx, `SELECT user_id::text,status FROM users WHERE user_id IN ($1,$2) ORDER BY user_id FOR UPDATE`, actor, target)
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
			if err != nil {
				return err
			}
			return appendEvent(ctx, tx, actor, "block.changed", 0)
		}
		for _, statement := range []string{
			`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING`,
			`UPDATE follows SET state='removed',removed_at=now() WHERE ((follower_id=$1 AND followee_id=$2) OR (follower_id=$2 AND followee_id=$1)) AND state<>'removed'`,
			`UPDATE friendships SET status=CASE WHEN status='accepted' THEN 'removed' ELSE 'cancelled' END,updated_at=now() WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid) AND status IN ('pending','accepted')`,
			`DELETE FROM notifications WHERE (recipient_id=$1 AND actor_id=$2) OR (recipient_id=$2 AND actor_id=$1)`,
			`UPDATE conversations SET status='closed' WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`,
			`DELETE FROM message_envelopes e USING messages m, devices d WHERE e.message_id=m.message_id AND e.recipient_device_id=d.device_id AND e.delivered_at IS NULL AND ((m.sender_id=$1 AND d.user_id=$2) OR (m.sender_id=$2 AND d.user_id=$1))`,
		} {
			if _, err = tx.Exec(ctx, statement, actor, target); err != nil {
				return err
			}
		}
		return appendEvent(ctx, tx, actor, "block.changed", 0)
	})
}
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

// RevokeOtherSessions signs the account out everywhere except this session.
func (s *Store) RevokeOtherSessions(ctx context.Context, p Principal) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND session_id<>$2 AND revoked_at IS NULL AND expires_at>now()`, p.UserID, p.SessionID)
	return tag.RowsAffected(), err
}

// PurgeSessions deletes sessions that expired more than retain ago, at most
// batch rows per call. Revoked sessions still expire, so this covers them.
func (s *Store) PurgeSessions(ctx context.Context, retain time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM sessions WHERE ctid IN (SELECT ctid FROM sessions WHERE expires_at<now()-$1::interval ORDER BY expires_at LIMIT $2)`, retain, batch)
	return tag.RowsAffected(), err
}

func (s *Store) ListSessions(ctx context.Context, p Principal, limit int, before *time.Time, beforeID string) ([]Session, error) {
	// Only live sessions; revoked and expired ones are history, not access.
	rows, err := s.Pool.Query(ctx, `SELECT session_id::text,created_at,last_seen_at,expires_at,platform,revoked_at FROM sessions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>now() AND ($3::timestamptz IS NULL OR (created_at,session_id)<($3,$4::uuid)) ORDER BY created_at DESC,session_id DESC LIMIT $2`, p.UserID, limit, before, beforeID)
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
