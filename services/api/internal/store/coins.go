package store

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/metrics"
)

// Coins (migration 0051_plans_coins.sql, docs/api/28-billing.md).
//
// Every change of a balance is one ledger row written in the same transaction as the balance update, behind a per-member advisory
// lock (lockCoins), with an idempotency key: the same key a second time changes nothing and reports applied=false. The balance
// never goes below zero: callers are told first (domain.ErrNegativeBalance) and the table's CHECK is the backstop.

var (
	coinSpent   = metrics.NewCounter("hiyall_coin_spend_total", "Coins spent, by ledger reason.", "reason")
	coinGranted = metrics.NewCounter("hiyall_coin_grant_total", "Coins granted or returned, by ledger reason.", "reason")
	coinRefunds = metrics.NewCounter("hiyall_coin_refund_shortfall_total", "Coins a refund could not take back because they were already spent.")
)

func init() {
	for _, r := range []string{domain.CoinSpendChatSlot, domain.CoinSpendProfile} {
		coinSpent.Preset(r)
	}
	for _, r := range []string{domain.CoinPurchase, domain.CoinRewardAd, domain.CoinProfileCompletion, domain.CoinRefundReversal} {
		coinGranted.Preset(r)
	}
}

// lockCoins serialises everything that changes one member's coins. migration 0051's coin_admin_adjust takes the same lock.
func lockCoins(ctx context.Context, tx pgx.Tx, user string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "coins\x1f"+user)
	return err
}

// balanceTx reads the member's balance and locks its row for the rest of the transaction (0 when there is no row yet).
func balanceTx(ctx context.Context, tx pgx.Tx, user string) (int64, error) {
	var b int64
	err := tx.QueryRow(ctx, `SELECT balance FROM coin_balances WHERE user_id=$1 FOR UPDATE`, user).Scan(&b)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return b, err
}

// applyCoins changes the balance by delta and appends the ledger row, inside a transaction that holds lockCoins. A key that is already
// in the ledger changes nothing (applied false, the current balance). A delta that would take the balance below zero is
// domain.ErrNegativeBalance and writes nothing.
func applyCoins(ctx context.Context, tx pgx.Tx, user, reason, key, ref string, delta int) (balance int64, applied bool, err error) {
	var seen bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM coin_ledger WHERE idempotency_key=$1)`, key).Scan(&seen); err != nil {
		return 0, false, err
	}
	if balance, err = balanceTx(ctx, tx, user); err != nil || seen {
		return balance, false, err
	}
	if balance+int64(delta) < 0 {
		return balance, false, domain.ErrNegativeBalance
	}
	balance += int64(delta)
	if _, err = tx.Exec(ctx, `INSERT INTO coin_balances(user_id,balance) VALUES($1,$2) ON CONFLICT (user_id) DO UPDATE SET balance=EXCLUDED.balance, updated_at=now()`, user, balance); err != nil {
		return 0, false, err
	}
	var refArg *string
	if ref != "" {
		refArg = &ref
	}
	if _, err = tx.Exec(ctx, `INSERT INTO coin_ledger(user_id,delta,reason,idempotency_key,ref,balance_after) VALUES($1,$2,$3,$4,$5,$6)`, user, delta, reason, key, refArg, balance); err != nil {
		return 0, false, err
	}
	if delta > 0 {
		coinGranted.Add(float64(delta), reason)
	} else if reason == domain.CoinSpendChatSlot || reason == domain.CoinSpendProfile {
		coinSpent.Add(float64(-delta), reason)
	}
	return balance, true, nil
}

// CoinBalance is the member's coins.
func (s *Store) CoinBalance(ctx context.Context, user string) (int64, error) {
	var b int64
	err := s.Pool.QueryRow(ctx, `SELECT coalesce((SELECT balance FROM coin_balances WHERE user_id=$1),0)`, user).Scan(&b)
	return b, err
}

// GrantCoins adds coins once per key. applied is false when the key was already used.
func (s *Store) GrantCoins(ctx context.Context, user, reason, key, ref string, coins int) (balance int64, applied bool, err error) {
	if coins <= 0 {
		return 0, false, errors.New("a grant is a positive number of coins")
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockCoins(ctx, tx, user); err != nil {
			return err
		}
		balance, applied, err = applyCoins(ctx, tx, user, reason, key, ref, coins)
		return err
	})
	return
}

// SpendCoins takes cost coins once per key. domain.ErrNegativeBalance when the balance is short.
func (s *Store) SpendCoins(ctx context.Context, user, reason, key, ref string, cost int) (balance int64, applied bool, err error) {
	if cost <= 0 {
		return 0, false, errors.New("a spend is a positive number of coins")
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockCoins(ctx, tx, user); err != nil {
			return err
		}
		balance, applied, err = applyCoins(ctx, tx, user, reason, key, ref, -cost)
		return err
	})
	return
}

// CoinEntry is one row of a member's usage history.
type CoinEntry struct {
	ID           string    `json:"id"`
	Reason       string    `json:"reason"`
	Delta        int       `json:"delta"`
	BalanceAfter int64     `json:"balanceAfter"`
	CreatedAt    time.Time `json:"createdAt"`
}

// CoinHistory lists the member's ledger newest first, before the entry id beforeID (0: from the newest).
func (s *Store) CoinHistory(ctx context.Context, user string, beforeID int64, limit int) ([]CoinEntry, error) {
	rows, err := s.Pool.Query(ctx, `SELECT entry_id,reason,delta,balance_after,created_at FROM coin_ledger WHERE user_id=$1 AND ($2::bigint=0 OR entry_id<$2) ORDER BY entry_id DESC LIMIT $3`, user, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []CoinEntry{}
	for rows.Next() {
		var e CoinEntry
		var id int64
		if err = rows.Scan(&id, &e.Reason, &e.Delta, &e.BalanceAfter, &e.CreatedAt); err != nil {
			return nil, err
		}
		e.ID = strconv.FormatInt(id, 10)
		items = append(items, e)
	}
	return items, rows.Err()
}

// ctxKey carries a member's confirmation of a spend through the call that may need it (the chat open path).
type spendConsentKey struct{}

// WithSpendConsent records that the member confirmed paying cost coins for the request. A request that needs a different amount
// (the price changed) is not covered.
func WithSpendConsent(ctx context.Context, cost int) context.Context {
	return context.WithValue(ctx, spendConsentKey{}, cost)
}

func spendConsent(ctx context.Context) (int, bool) {
	c, ok := ctx.Value(spendConsentKey{}).(int)
	return c, ok
}

// chargeChatSlot is the coin side of starting a conversation, called inside OpenConversation's transaction after the member's quota
// lock, for a conversation that does not exist yet. Free (nothing happens) unless the entitlements are enforced, carry a free allowance and
// the member has started that many conversations in the last 24 hours: then the next one costs ChatSlotCoinCost. Without the member's
// confirmation of exactly that price nothing is taken (SPEND_CONFIRMATION_REQUIRED); with it the coins are taken in this transaction,
// so a conversation that fails to be created costs nothing.
func chargeChatSlot(ctx context.Context, tx pgx.Tx, user string, e domain.Entitlements, newID string) error {
	if !e.Enforced || e.FreeNewChatsPerDay <= 0 {
		return nil
	}
	var started int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM conversations WHERE created_by=$1 AND created_at>now()-interval '24 hours'`, user).Scan(&started); err != nil {
		return err
	}
	cost := e.ChatSlotCost(started)
	if cost <= 0 {
		return nil
	}
	if err := lockCoins(ctx, tx, user); err != nil {
		return err
	}
	balance, err := balanceTx(ctx, tx, user)
	if err != nil {
		return err
	}
	if got, ok := spendConsent(ctx); !ok || got != cost {
		return domain.ErrSpendConfirmation(domain.SpendChatSlot, cost, balance)
	}
	if balance < int64(cost) {
		return domain.ErrInsufficientCoins(domain.SpendChatSlot, cost, balance)
	}
	_, _, err = applyCoins(ctx, tx, user, domain.CoinSpendChatSlot, "chat:"+newID, "", -cost)
	return err
}
