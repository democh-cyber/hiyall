package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Daily caps, the Nearby switch and the age gate's refusals (docs/architecture/18-teen-safety.md).

// bumpDaily counts one action of kind for the member on the current UTC day, or refuses with a
// DAILY_LIMIT error (Retry-After: the next UTC midnight) when limit are already counted. It is one atomic
// upsert, so concurrent requests cannot both pass at limit-1; inside a transaction the count commits with
// the thing it counts, and a rolled back request costs nothing. Nothing is refunded by undoing the action.
func bumpDaily(ctx context.Context, q querier, user, kind string, limit int) error {
	if limit <= 0 {
		return domain.DailyLimitError(kind, domain.UntilNextUTCDay(time.Now()))
	}
	var n int
	err := q.QueryRow(ctx, `INSERT INTO member_daily_counts(user_id,kind,day,n) VALUES($1,$2,(now() AT TIME ZONE 'UTC')::date,1)
 ON CONFLICT (user_id,kind,day) DO UPDATE SET n=member_daily_counts.n+1 WHERE member_daily_counts.n<$3 RETURNING n`, user, kind, limit).Scan(&n)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.DailyLimitError(kind, domain.UntilNextUTCDay(time.Now()))
	}
	return err
}

// BumpDaily is bumpDaily for requests that are not part of a creating transaction: search pages, profile
// views and Nearby queries. Every request that reaches it counts.
func (s *Store) BumpDaily(ctx context.Context, user, kind string, limit int) error {
	return bumpDaily(ctx, s.Pool, user, kind, limit)
}

// capDaily takes the member's quota lock for kind and counts one action, inside the creating transaction.
func capDaily(ctx context.Context, tx pgx.Tx, user, kind string, limit int) error {
	if err := lockQuota(ctx, tx, "daily-"+kind, user); err != nil {
		return err
	}
	return bumpDaily(ctx, tx, user, kind, limit)
}

// PurgeDailyCounts deletes counters older than keepDays days, at most batch rows per call.
func (s *Store) PurgeDailyCounts(ctx context.Context, keepDays, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM member_daily_counts WHERE ctid IN (SELECT ctid FROM member_daily_counts WHERE day<(now() AT TIME ZONE 'UTC')::date-$1::int LIMIT $2)`, keepDays, batch)
	return tag.RowsAffected(), err
}

// IsMinor reports whether the member is under AdultAge by their declared birth date (an unknown date
// counts as an adult, as everywhere).
func (s *Store) IsMinor(ctx context.Context, user string) (bool, error) {
	var minor bool
	err := s.Pool.QueryRow(ctx, `SELECT age_band($1)=$2`, user, domain.BandMinor).Scan(&minor)
	return minor, err
}

// NearbyState is the member's Nearby switch and whether a fresh point is stored.
type NearbyState struct {
	Visible   bool
	Sharing   bool
	Minor     bool
	UpdatedAt *time.Time
}

// GetNearby reports the Nearby switch and the location state. It never returns coordinates.
func (s *Store) GetNearby(ctx context.Context, user string) (NearbyState, error) {
	var st NearbyState
	err := s.Pool.QueryRow(ctx, `SELECT coalesce((SELECT visible FROM nearby_prefs WHERE user_id=$1),false),
 (SELECT updated_at FROM user_locations WHERE user_id=$1 AND updated_at>now()-make_interval(hours=>$2::int)),
 age_band($1)=$3
 FROM users WHERE user_id=$1 AND status='active'`, user, domain.LocationFreshHours, domain.BandMinor).Scan(&st.Visible, &st.UpdatedAt, &st.Minor)
	if err != nil {
		return st, mapped(err)
	}
	st.Sharing = st.UpdatedAt != nil
	return st, nil
}

// SetNearbyVisible turns "Show me in Nearby" on or off. Turning it off deletes the member's stored point in
// the same transaction, so they leave everyone's results at once; turning it on stores no location.
func (s *Store) SetNearbyVisible(ctx context.Context, user string, visible bool) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO nearby_prefs(user_id,visible) SELECT user_id,$2 FROM users WHERE user_id=$1 AND status='active'
 ON CONFLICT (user_id) DO UPDATE SET visible=excluded.visible,updated_at=now()`, user, visible)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		if !visible {
			_, err = tx.Exec(ctx, `DELETE FROM user_locations WHERE user_id=$1`, user)
		}
		return err
	})
}

// PurgeAgeRefusals deletes refusals older than keep, at most batch rows per call.
func (s *Store) PurgeAgeRefusals(ctx context.Context, keep time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM age_gate_refusals WHERE ctid IN (SELECT ctid FROM age_gate_refusals WHERE refused_at<now()-$1::interval LIMIT $2)`, keep, batch)
	return tag.RowsAffected(), err
}

// RecordAgeRefusal remembers that the account's identity declared an age under the minimum. The refusal
// is keyed by issuer and subject, so a new account from the same sign-in is refused too. No birth date is
// stored. An account without an identity row (development fixtures) records nothing.
func (s *Store) RecordAgeRefusal(ctx context.Context, user string) error {
	_, err := s.Pool.Exec(ctx, `INSERT INTO age_gate_refusals(issuer,subject) SELECT issuer,subject FROM auth_identities WHERE user_id=$1
 ON CONFLICT (issuer,subject) DO UPDATE SET refused_at=now(),refusals=age_gate_refusals.refusals+1`, user)
	return err
}

// AgeGateBlocked reports whether any identity of the account declared an age under the minimum within the
// cooldown (domain.AgeGateCooldown).
func (s *Store) AgeGateBlocked(ctx context.Context, user string) (bool, error) {
	return ageGateBlocked(ctx, s.Pool, user)
}

func ageGateBlocked(ctx context.Context, q querier, user string) (bool, error) {
	var blocked bool
	err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM auth_identities a JOIN age_gate_refusals r ON r.issuer=a.issuer AND r.subject=a.subject
 WHERE a.user_id=$1 AND r.refused_at>now()-$2::interval)`, user, domain.AgeGateCooldown).Scan(&blocked)
	return blocked, err
}
