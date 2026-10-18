package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"hiyall/services/api/internal/domain"
)

// Purchases and subscriptions (migration 0051, docs/api/28-billing.md). A store transaction is granted once: purchases.tx_hash is UNIQUE and
// the coin grant is keyed by it. Nothing here sees a receipt or a token, only their hashes.

// SubInput is a subscription as a store described it.
type SubInput struct {
	OriginalHash string
	Status       string
	PeriodEnd    time.Time
	GraceUntil   *time.Time
	AutoRenew    bool
}

// PurchaseInput is a purchase the store confirmed (or reported pending).
type PurchaseInput struct {
	UserID, Store, TxHash, ProductID, Kind, State string
	Coins                                         int
	Test                                          bool
	Sub                                           *SubInput
}

// PurchaseOutcome says what recording a purchase did.
type PurchaseOutcome struct {
	// State is the purchase's state now: pending, verified, refunded or revoked.
	State            string
	CoinsGranted     int
	AlreadyProcessed bool
	Balance          int64
}

func putSubscription(ctx context.Context, tx pgx.Tx, user, store, product string, in SubInput) error {
	tag, err := tx.Exec(ctx, `INSERT INTO subscriptions(subscription_id,user_id,plan,store,product_id,status,current_period_end,grace_until,auto_renew,original_hash)
 VALUES($1,$2,'premium',$3,$4,$5,$6,$7,$8,$9)
 ON CONFLICT (original_hash) DO UPDATE SET product_id=EXCLUDED.product_id, status=CASE WHEN subscriptions.status='revoked' THEN 'revoked' ELSE EXCLUDED.status END,
  current_period_end=EXCLUDED.current_period_end, grace_until=EXCLUDED.grace_until, auto_renew=EXCLUDED.auto_renew, updated_at=now()
 WHERE subscriptions.user_id=EXCLUDED.user_id`, newID(), user, store, product, in.Status, in.PeriodEnd, in.GraceUntil, in.AutoRenew, in.OriginalHash)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return domain.ErrPurchaseClaimed // the subscription belongs to another member
	}
	return nil
}

// RecordPurchase records a store-confirmed purchase once and grants what it is worth. Repeating it changes nothing (AlreadyProcessed); a purchase
// that belongs to another member is domain.ErrPurchaseClaimed; a purchase that was refunded or revoked stays so (State says it, nothing is granted).
// A pending purchase is kept pending and granted when it is recorded again as verified.
func (s *Store) RecordPurchase(ctx context.Context, in PurchaseInput) (out PurchaseOutcome, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		out = PurchaseOutcome{}
		if err := lockCoins(ctx, tx, in.UserID); err != nil {
			return err
		}
		var owner, state string
		err := tx.QueryRow(ctx, `SELECT user_id::text,state FROM purchases WHERE tx_hash=$1 FOR UPDATE`, in.TxHash).Scan(&owner, &state)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			state = ""
		case err != nil:
			return err
		case owner != in.UserID:
			return domain.ErrPurchaseClaimed
		}
		grant := false
		switch {
		case state == "":
			if _, err = tx.Exec(ctx, `INSERT INTO purchases(purchase_id,user_id,store,tx_hash,product_id,kind,state,coins,test_purchase,verified_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,CASE WHEN $7='verified' THEN now() END)`,
				newID(), in.UserID, in.Store, in.TxHash, in.ProductID, in.Kind, in.State, in.Coins, in.Test); err != nil {
				return err
			}
			out.State, grant = in.State, in.State == "verified"
		case state == "pending" && in.State == "verified":
			if _, err = tx.Exec(ctx, `UPDATE purchases SET state='verified', verified_at=now(), updated_at=now() WHERE tx_hash=$1`, in.TxHash); err != nil {
				return err
			}
			out.State, grant = "verified", true
		default:
			out.State, out.AlreadyProcessed = state, true
		}
		if in.Sub != nil && out.State != "refunded" && out.State != "revoked" {
			if err = putSubscription(ctx, tx, in.UserID, in.Store, in.ProductID, *in.Sub); err != nil {
				return err
			}
		}
		if grant && in.Kind == "coins" && in.Coins > 0 {
			bal, applied, err := applyCoins(ctx, tx, in.UserID, domain.CoinPurchase, "purchase:"+in.TxHash, in.ProductID, in.Coins)
			if err != nil {
				return err
			}
			out.Balance = bal
			if applied {
				out.CoinsGranted = in.Coins
			} else {
				out.AlreadyProcessed = true
			}
			return nil
		}
		out.Balance, err = balanceTx(ctx, tx, in.UserID)
		return err
	})
	if isUniqueViolation(err) {
		// Two members raced to claim the same purchase or subscription; the other one won.
		return PurchaseOutcome{}, domain.ErrPurchaseClaimed
	}
	return
}

func isUniqueViolation(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

// PurchaseOwner finds a purchase by its hash: the member, the kind and the state.
func (s *Store) PurchaseOwner(ctx context.Context, txHash string) (user, kind, state, product string, found bool, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT user_id::text,kind,state,product_id FROM purchases WHERE tx_hash=$1`, txHash).Scan(&user, &kind, &state, &product)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", "", "", false, nil
	}
	return user, kind, state, product, err == nil, err
}

// SubscriptionOwner finds a subscription by its original-transaction hash.
func (s *Store) SubscriptionOwner(ctx context.Context, originalHash string) (user, product string, found bool, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT user_id::text,product_id FROM subscriptions WHERE original_hash=$1`, originalHash).Scan(&user, &product)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	return user, product, err == nil, err
}

// UpdateSubscription applies a store notification to a subscription we know. false: no such subscription.
func (s *Store) UpdateSubscription(ctx context.Context, in SubInput) (user string, found bool, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `UPDATE subscriptions SET status=CASE WHEN status='revoked' THEN 'revoked' ELSE $2 END, current_period_end=$3, grace_until=$4, auto_renew=$5, updated_at=now()
 WHERE original_hash=$1 RETURNING user_id::text`, in.OriginalHash, in.Status, in.PeriodEnd, in.GraceUntil, in.AutoRenew).Scan(&user)
		found = err == nil
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	})
	return
}

// RefundPurchase marks a purchase refunded (or revoked) and takes its coins back. It reverses what the balance still holds: coins the member
// already spent cannot be taken (the shortfall is counted in hiyall_coin_refund_shortfall_total and kept in coins_reversed). The subscription
// of a refunded subscription purchase is revoked with it (originalHash, when known). Repeating it changes nothing. found is false for an unknown purchase.
func (s *Store) RefundPurchase(ctx context.Context, txHash, originalHash, state string) (user string, found bool, err error) {
	if state != "refunded" && state != "revoked" {
		return "", false, errors.New("a refund ends in refunded or revoked")
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		user, found = "", false
		if originalHash != "" {
			if _, err := tx.Exec(ctx, `UPDATE subscriptions SET status='revoked', auto_renew=false, updated_at=now() WHERE original_hash=$1 AND status<>'revoked'`, originalHash); err != nil {
				return err
			}
		}
		var kind, cur string
		var coins, reversed int
		err := tx.QueryRow(ctx, `SELECT user_id::text,kind,state,coins,coins_reversed FROM purchases WHERE tx_hash=$1`, txHash).Scan(&user, &kind, &cur, &coins, &reversed)
		if errors.Is(err, pgx.ErrNoRows) {
			if originalHash != "" {
				_ = tx.QueryRow(ctx, `SELECT user_id::text FROM subscriptions WHERE original_hash=$1`, originalHash).Scan(&user)
				found = user != ""
			}
			return nil
		}
		if err != nil {
			return err
		}
		found = true
		if err = lockCoins(ctx, tx, user); err != nil {
			return err
		}
		// Re-read under the lock: a concurrent refund of the same purchase has finished by now.
		if err = tx.QueryRow(ctx, `SELECT state,coins_reversed FROM purchases WHERE tx_hash=$1 FOR UPDATE`, txHash).Scan(&cur, &reversed); err != nil {
			return err
		}
		if cur == "refunded" || cur == "revoked" {
			return nil
		}
		took := 0
		if cur == "verified" && kind == "coins" && coins > 0 {
			bal, err := balanceTx(ctx, tx, user)
			if err != nil {
				return err
			}
			took = int(min(bal, int64(coins)))
			if took > 0 {
				if _, _, err = applyCoins(ctx, tx, user, domain.CoinRefund, "refund:"+txHash, "", -took); err != nil {
					return err
				}
			}
			if took < coins {
				coinRefunds.Add(float64(coins - took))
			}
		}
		_, err = tx.Exec(ctx, `UPDATE purchases SET state=$2, coins_reversed=$3, updated_at=now() WHERE tx_hash=$1`, txHash, state, took)
		return err
	})
	return
}

// ReverseRefund undoes a refund the store took back (Apple REFUND_REVERSED): the purchase is verified again and the coins that were
// taken are returned.
func (s *Store) ReverseRefund(ctx context.Context, txHash, originalHash string) (user string, found bool, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		user, found = "", false
		var cur string
		var reversed int
		err := tx.QueryRow(ctx, `SELECT user_id::text,state,coins_reversed FROM purchases WHERE tx_hash=$1`, txHash).Scan(&user, &cur, &reversed)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		found = true
		if err = lockCoins(ctx, tx, user); err != nil {
			return err
		}
		if err = tx.QueryRow(ctx, `SELECT state,coins_reversed FROM purchases WHERE tx_hash=$1 FOR UPDATE`, txHash).Scan(&cur, &reversed); err != nil {
			return err
		}
		if cur != "refunded" && cur != "revoked" {
			return nil
		}
		if reversed > 0 {
			if _, _, err = applyCoins(ctx, tx, user, domain.CoinRefundReversal, "refund_reversal:"+txHash, "", reversed); err != nil {
				return err
			}
		}
		if originalHash != "" {
			if _, err = tx.Exec(ctx, `UPDATE subscriptions SET status='expired', updated_at=now() WHERE original_hash=$1 AND status='revoked'`, originalHash); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `UPDATE purchases SET state='verified', coins_reversed=0, updated_at=now() WHERE tx_hash=$1`, txHash)
		return err
	})
	return
}

// SubscriptionRow is a subscription for the API.
type SubscriptionRow struct {
	Store, ProductID, Status string
	PeriodEnd                time.Time
	GraceUntil               *time.Time
	AutoRenew                bool
	Entitled                 bool
}

// PlanState is what the plan resolver needs about a member.
type PlanState struct {
	// AgeKnown and Adult: Monetizable is both. A member under 18, or with no stored birth date, is never gated or charged.
	AgeKnown, Adult bool
	Sub             *SubscriptionRow
}

// Monetizable says whether the member may buy anything: an adult whose age is known.
func (p PlanState) Monetizable() bool { return p.AgeKnown && p.Adult }

// Plan is the plan the member's subscription gives right now.
func (p PlanState) Plan() domain.Plan {
	if p.Sub != nil && p.Sub.Entitled {
		return domain.PlanPremium
	}
	return domain.PlanFree
}

// PlanState reads the member's age band and their best subscription in one query.
func (s *Store) PlanState(ctx context.Context, user string) (PlanState, error) {
	var st PlanState
	var age *int
	if err := s.Pool.QueryRow(ctx, `SELECT member_age($1)`, user).Scan(&age); err != nil {
		return st, err
	}
	if age != nil {
		st.AgeKnown, st.Adult = true, *age >= domain.AdultAge
	}
	var sub SubscriptionRow
	err := s.Pool.QueryRow(ctx, `SELECT store,product_id,status,current_period_end,grace_until,auto_renew,
 (status='active' AND current_period_end>now()) OR (status='grace' AND coalesce(grace_until,current_period_end)>now())
 FROM subscriptions WHERE user_id=$1
 ORDER BY ((status='active' AND current_period_end>now()) OR (status='grace' AND coalesce(grace_until,current_period_end)>now())) DESC, current_period_end DESC LIMIT 1`, user).
		Scan(&sub.Store, &sub.ProductID, &sub.Status, &sub.PeriodEnd, &sub.GraceUntil, &sub.AutoRenew, &sub.Entitled)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
	case err != nil:
		return st, err
	default:
		st.Sub = &sub
	}
	return st, nil
}
