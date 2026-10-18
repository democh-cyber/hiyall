package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Rewarded ads, detailed-profile unlocks, the profile-completion bonus and the billing maintenance job (migration 0051).

// ---- Rewarded ads. A session is started by the app, its nonce travels through AdMob as custom data and comes back in the signed
// server-side-verification callback, which is the only thing that credits coins.

// AdSession is a started rewarded ad.
type AdSession struct {
	Nonce          string
	ExpiresAt      time.Time
	RemainingToday int
}

func adCapError() error {
	return domain.RetryAfter(&domain.PolicyError{Status: 429, Code: "DAILY_LIMIT", Message: "You’ve watched all of today’s rewarded videos. Come back tomorrow."}, domain.UntilNextUTCDay(time.Now()))
}

// adsToday counts the member's rewarded ads of the current UTC day: credited ones and sessions still waiting for their callback.
func adsToday(ctx context.Context, tx pgx.Tx, user string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM ad_reward_sessions WHERE user_id=$1 AND created_at>=(now() AT TIME ZONE 'UTC')::date AT TIME ZONE 'UTC'
 AND (status='credited' OR (status='pending' AND expires_at>now()))`, user).Scan(&n)
	return n, err
}

// StartAdSession opens a rewarded-ad session unless the member has used the day's cap (429 DAILY_LIMIT).
func (s *Store) StartAdSession(ctx context.Context, user string, ttl time.Duration, dailyCap int) (AdSession, error) {
	var out AdSession
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockCoins(ctx, tx, user); err != nil {
			return err
		}
		used, err := adsToday(ctx, tx, user)
		if err != nil {
			return err
		}
		if used >= dailyCap {
			return adCapError()
		}
		out = AdSession{Nonce: newID(), ExpiresAt: time.Now().Add(ttl).UTC(), RemainingToday: dailyCap - used - 1}
		_, err = tx.Exec(ctx, `INSERT INTO ad_reward_sessions(nonce,user_id,expires_at) VALUES($1,$2,$3)`, out.Nonce, user, out.ExpiresAt)
		return err
	})
	return out, err
}

// AdCredit says what a verified callback did.
type AdCredit string

const (
	AdCredited AdCredit = "credited"
	AdReplay   AdCredit = "replay"   // already credited (the same callback again)
	AdRejected AdCredit = "rejected" // the day's cap, an expired or unknown session, a minor, a reused transaction
)

// CreditAdReward credits coins for a verified callback: once per session and per AdMob transaction id (ssvHash), within the day's cap, only
// for a member who is still an adult with a known age. The decision is recorded on the session so the app's poll can report it.
func (s *Store) CreditAdReward(ctx context.Context, user, nonce, ssvHash string, coins, dailyCap int) (result AdCredit, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		result = AdRejected
		if err := lockCoins(ctx, tx, user); err != nil {
			return err
		}
		var status string
		var stored *string
		var expires time.Time
		err := tx.QueryRow(ctx, `SELECT status,ssv_hash,expires_at FROM ad_reward_sessions WHERE nonce=$1 AND user_id=$2 FOR UPDATE`, nonce, user).Scan(&status, &stored, &expires)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if status == "credited" {
			if stored != nil && *stored == ssvHash {
				result = AdReplay
			}
			return nil
		}
		if status != "pending" {
			return nil
		}
		reject := func(reason string) error {
			result = AdRejected
			_, err := tx.Exec(ctx, `UPDATE ad_reward_sessions SET status='rejected', reject_reason=$2 WHERE nonce=$1`, nonce, reason)
			return err
		}
		var age *int
		if err = tx.QueryRow(ctx, `SELECT member_age($1)`, user).Scan(&age); err != nil {
			return err
		}
		if age == nil || *age < domain.AdultAge {
			return reject("not_adult")
		}
		if time.Now().After(expires.Add(time.Minute)) {
			return reject("expired")
		}
		var credited int
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM ad_reward_sessions WHERE user_id=$1 AND status='credited' AND created_at>=(now() AT TIME ZONE 'UTC')::date AT TIME ZONE 'UTC'`, user).Scan(&credited); err != nil {
			return err
		}
		if credited >= dailyCap {
			return reject("cap")
		}
		var seen bool
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM ad_reward_sessions WHERE ssv_hash=$1)`, ssvHash).Scan(&seen); err != nil {
			return err
		}
		if seen {
			return reject("reused")
		}
		if coins > 0 {
			if _, _, err = applyCoins(ctx, tx, user, domain.CoinRewardAd, "ad:"+ssvHash, "", coins); err != nil {
				return err
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE ad_reward_sessions SET status='credited', ssv_hash=$2, coins=$3, credited_at=now() WHERE nonce=$1`, nonce, ssvHash, coins); err != nil {
			return err
		}
		result = AdCredited
		return nil
	})
	return
}

// AdSessionState is what the app's poll sees.
type AdSessionState struct {
	Status string // pending, credited, rejected, expired
	Coins  int
}

// AdSessionStatus reads one of the member's sessions (domain.ErrNotFound for another member's or an unknown one).
func (s *Store) AdSessionStatus(ctx context.Context, user, nonce string) (AdSessionState, error) {
	var st AdSessionState
	var expires time.Time
	err := s.Pool.QueryRow(ctx, `SELECT status,coins,expires_at FROM ad_reward_sessions WHERE nonce=$1 AND user_id=$2`, nonce, user).Scan(&st.Status, &st.Coins, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, domain.ErrNotFound
	}
	if err == nil && st.Status == "pending" && time.Now().After(expires.Add(time.Minute)) {
		st.Status = "expired"
	}
	return st, err
}

// AdsWatchedToday is how many rewarded ads count against the member's day.
func (s *Store) AdsWatchedToday(ctx context.Context, user string) (int, error) {
	var n int
	err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM ad_reward_sessions WHERE user_id=$1 AND status='credited' AND created_at>=(now() AT TIME ZONE 'UTC')::date AT TIME ZONE 'UTC'`, user).Scan(&n)
	return n, err
}

// ---- Detailed profile unlocks.

// ProfileDetailsUnlockedUntil is when the viewer's unlock of the target's detailed fields ends; the zero time when there is none now.
func (s *Store) ProfileDetailsUnlockedUntil(ctx context.Context, viewer, target string) (time.Time, error) {
	var until time.Time
	err := s.Pool.QueryRow(ctx, `SELECT expires_at FROM profile_detail_unlocks WHERE viewer_id=$1 AND target_id=$2 AND expires_at>now()`, viewer, target).Scan(&until)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, nil
	}
	return until, err
}

// UnlockResult says what unlocking did.
type UnlockResult struct {
	ExpiresAt time.Time
	Charged   int
	Balance   int64
}

// UnlockProfileDetails lets the viewer see the target's detailed fields for days days, for cost coins. Nothing is taken while an unlock is still
// running (the same member and profile within the window). The price must be the one the member confirmed (confirmed == cost), else
// SPEND_CONFIRMATION_REQUIRED; a short balance is INSUFFICIENT_COINS. The coins and the unlock are one transaction.
func (s *Store) UnlockProfileDetails(ctx context.Context, viewer, target string, cost, days, confirmed int) (UnlockResult, error) {
	var out UnlockResult
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		out = UnlockResult{}
		if err := lockCoins(ctx, tx, viewer); err != nil {
			return err
		}
		bal, err := balanceTx(ctx, tx, viewer)
		if err != nil {
			return err
		}
		out.Balance = bal
		var until time.Time
		err = tx.QueryRow(ctx, `SELECT expires_at FROM profile_detail_unlocks WHERE viewer_id=$1 AND target_id=$2 AND expires_at>now()`, viewer, target).Scan(&until)
		if err == nil {
			out.ExpiresAt = until
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if cost > 0 {
			if confirmed != cost {
				return domain.ErrSpendConfirmation(domain.SpendProfileDetail, cost, bal)
			}
			if bal < int64(cost) {
				return domain.ErrInsufficientCoins(domain.SpendProfileDetail, cost, bal)
			}
			if out.Balance, _, err = applyCoins(ctx, tx, viewer, domain.CoinSpendProfile, "detail:"+newID(), target, -cost); err != nil {
				return err
			}
			out.Charged = cost
		}
		out.ExpiresAt = time.Now().Add(time.Duration(days) * 24 * time.Hour).UTC()
		_, err = tx.Exec(ctx, `INSERT INTO profile_detail_unlocks(viewer_id,target_id,expires_at) VALUES($1,$2,$3)
 ON CONFLICT (viewer_id,target_id) DO UPDATE SET unlocked_at=now(), expires_at=EXCLUDED.expires_at`, viewer, target, out.ExpiresAt)
		return err
	})
	return out, err
}

// ---- Profile completion bonus.

// ProfileComplete says whether the member's profile has a photo, a few words about themselves, an interest and a language.
func (s *Store) ProfileComplete(ctx context.Context, user string) (bool, error) {
	var ok bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM profiles p `+avatarJoin("av", "p")+`WHERE p.user_id=$1 AND av.media_id IS NOT NULL
 AND (btrim(coalesce(p.data->>'bio',''))<>'' OR btrim(coalesce(p.data->>'aboutMe',''))<>'')
 AND jsonb_array_length(CASE WHEN jsonb_typeof(p.data->'interests')='array' THEN p.data->'interests' ELSE '[]'::jsonb END)>=1
 AND jsonb_array_length(CASE WHEN jsonb_typeof(p.data->'languages')='array' THEN p.data->'languages' ELSE '[]'::jsonb END)>=1)`, user).Scan(&ok)
	return ok, err
}

// ProfileBonusClaimed says whether the one-time completion bonus was already given.
func (s *Store) ProfileBonusClaimed(ctx context.Context, user string) (bool, error) {
	var ok bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM coin_ledger WHERE idempotency_key=$1)`, "profile_completion:"+user).Scan(&ok)
	return ok, err
}

// ClaimProfileBonus grants the bonus once per member. granted false with claimed true: it was given before.
func (s *Store) ClaimProfileBonus(ctx context.Context, user string, coins int) (granted, claimed bool, balance int64, err error) {
	balance, applied, err := s.GrantCoins(ctx, user, domain.CoinProfileCompletion, "profile_completion:"+user, "", coins)
	return applied, !applied, balance, err
}

// PurgeBilling removes what billing no longer needs: ad sessions after three days (the callback accepts nothing older than a day), and
// detailed-profile unlocks a month after they ran out. Ledger, purchases and subscriptions stay.
func (s *Store) PurgeBilling(ctx context.Context, batch int) (int64, error) {
	var total int64
	for _, q := range []string{
		`DELETE FROM ad_reward_sessions WHERE nonce IN (SELECT nonce FROM ad_reward_sessions WHERE created_at<now()-interval '3 days' LIMIT $1)`,
		`DELETE FROM profile_detail_unlocks WHERE ctid IN (SELECT ctid FROM profile_detail_unlocks WHERE expires_at<now()-interval '30 days' LIMIT $1)`,
	} {
		tag, err := s.Pool.Exec(ctx, q, batch)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// BillableMember says whether id is a member who may be credited from a store notification: an existing account that is an adult with a
// known age.
func (s *Store) BillableMember(ctx context.Context, id string) (bool, error) {
	var ok bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$1 AND status IN ('active','pending_deletion')) AND coalesce(member_age($1)>=$2,false)`, id, domain.AdultAge).Scan(&ok)
	return ok, err
}
