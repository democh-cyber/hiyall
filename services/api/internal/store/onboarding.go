package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Onboarding is the account's first-run state. Only whether and when it was
// completed is exposed. The declared birth date is kept privately in member_ages and
// is never part of this state or any response.
type Onboarding struct {
	Completed   bool
	CompletedAt *time.Time
}

func (s *Store) GetOnboarding(ctx context.Context, userID string) (Onboarding, error) {
	var completedAt *time.Time
	err := s.Pool.QueryRow(ctx, `SELECT o.completed_at FROM users u LEFT JOIN onboarding o ON o.user_id=u.user_id WHERE u.user_id=$1 AND u.status='active'`, userID).Scan(&completedAt)
	if err != nil {
		return Onboarding{}, mapped(err)
	}
	return Onboarding{completedAt != nil, completedAt}, nil
}

// CompleteOnboarding records the minimum-age declaration and terms acceptance. The caller
// has already validated the request (the declared age is at least MinimumAge).
// The timestamps and terms version go to onboarding and the birth date to member_ages,
// where the first stored value is final: a later attempt cannot move the member to
// another age band. When the stored date puts the member under AdultAge, the stricter
// minor defaults are applied once, in the same transaction.
// It is idempotent: an account that is already complete is returned unchanged and the
// birth date sent again is ignored. A profile that still carries its
// generated username or name is refused with ErrProfileIncomplete.
func (s *Store) CompleteOnboarding(ctx context.Context, userID string, birth time.Time) (Onboarding, error) {
	var result Onboarding
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var active bool
		if err := tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, userID).Scan(&active); err != nil {
			return mapped(err)
		} else if !active {
			return domain.ErrNotFound
		}
		var completedAt *time.Time
		err := tx.QueryRow(ctx, `SELECT completed_at FROM onboarding WHERE user_id=$1 FOR UPDATE`, userID).Scan(&completedAt)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if completedAt != nil {
			result = Onboarding{true, completedAt}
			return nil
		}
		if blocked, e := ageGateBlocked(ctx, tx, userID); e != nil {
			return e
		} else if blocked {
			return domain.ErrAgeGateCooldown
		}
		var username, name string
		if err = tx.QueryRow(ctx, `SELECT username,coalesce(data->>'displayName','') FROM profiles WHERE user_id=$1`, userID).Scan(&username, &name); err != nil {
			return mapped(err)
		}
		if domain.ProfileIsPlaceholder(username, name) {
			return domain.ErrProfileIncomplete
		}
		if err = tx.QueryRow(ctx, `INSERT INTO onboarding(user_id,age_declared_at,terms_version,terms_accepted_at,completed_at) VALUES($1,now(),$2,now(),now())
 ON CONFLICT(user_id) DO UPDATE SET age_declared_at=excluded.age_declared_at,terms_version=excluded.terms_version,terms_accepted_at=excluded.terms_accepted_at,completed_at=excluded.completed_at
 RETURNING completed_at`, userID, domain.TermsVersion).Scan(&completedAt); err != nil {
			return err
		}
		result = Onboarding{true, completedAt}
		if err = recordBirth(ctx, tx, userID, birth, true); err != nil {
			return err
		}
		return nil
	})
	return result, err
}

// recordBirth stores a declared birth date unless one is already stored (the first value is
// final) and, when the stored date makes the member a minor and applyDefaults is set,
// applies the minor defaults. The date appears in no event, log or result.
func recordBirth(ctx context.Context, tx pgx.Tx, userID string, birth time.Time, applyDefaults bool) error {
	if _, err := tx.Exec(ctx, `INSERT INTO member_ages(user_id,birth_date) VALUES($1,$2::date) ON CONFLICT (user_id) DO NOTHING`, userID, birth.Format(time.DateOnly)); err != nil {
		return err
	}
	var minor bool
	if err := tx.QueryRow(ctx, `SELECT age_band($1)=$2`, userID, domain.BandMinor).Scan(&minor); err != nil {
		return err
	}
	if !minor || !applyDefaults {
		return nil
	}
	// The minor defaults: presence, the country and connections audiences (as before) and, from profile v2, a hidden
	// about-me, hometown and birthday, and local time, distance, visitor list and birthday all off.
	_, err := tx.Exec(ctx, `UPDATE privacy_settings SET data=jsonb_set(jsonb_set(data,'{onlineAudience}',to_jsonb($2::text)),'{fieldAudiences}',coalesce(data->'fieldAudiences','{}'::jsonb)||jsonb_build_object('location',$3::text,'connections',$4::text,'aboutMe',$5::text,'hometown',$6::text,'birthday',$7::text))
 ||'{"showLocalTime":false,"showDistance":false,"visitorsVisibleToOthers":false,"showBirthday":false}'::jsonb,version=version+1,updated_at=now() WHERE user_id=$1`,
		userID, domain.MinorOnlineAudience, domain.MinorLocationFieldAudience, domain.MinorConnectionsAudience, domain.MinorAboutMeAudience, domain.MinorHometownAudience, domain.MinorBirthdayAudience)
	return err
}

// UsernameAvailable reports whether userID may take username: it is free, or it
// is already the caller's own. Generated placeholder handles are never available.
func (s *Store) UsernameAvailable(ctx context.Context, userID, username string) (bool, error) {
	if domain.IsPlaceholderUsername(username) {
		return false, nil
	}
	var taken bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM profiles WHERE username=$1 AND user_id<>$2)`, username, userID).Scan(&taken)
	return !taken, err
}
