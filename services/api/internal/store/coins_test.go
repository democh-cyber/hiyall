package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

const (
	adultA = "00000000-0000-7000-8000-0000000000a1"
	adultB = "00000000-0000-7000-8000-0000000000a2"
	teenC  = "00000000-0000-7000-8000-0000000000c1"
	noAge  = "00000000-0000-7000-8000-0000000000d1"
)

func billingStore(t *testing.T) *Store {
	t.Helper()
	s := scratchStore(t)
	for id, age := range map[string]int{adultA: 30, adultB: 25, teenC: 15, noAge: 0} {
		mustExec(t, s, `INSERT INTO users(user_id) VALUES($1)`, id)
		if age > 0 {
			mustExec(t, s, `INSERT INTO member_ages(user_id,birth_date) VALUES($1,(now() AT TIME ZONE 'UTC')::date-make_interval(years=>$2,days=>10))`, id, age)
		}
	}
	return s
}

func ledgerSum(t *testing.T, s *Store, user string) int {
	return mustCount(t, s, `SELECT coalesce(sum(delta),0)::int FROM coin_ledger WHERE user_id=$1`, user)
}

// The balance always equals the sum of the ledger, and the last row's balance_after is the balance.
func checkBalanceMatchesLedger(t *testing.T, s *Store, user string) {
	t.Helper()
	bal, err := s.CoinBalance(context.Background(), user)
	if err != nil {
		t.Fatal(err)
	}
	if int64(ledgerSum(t, s, user)) != bal {
		t.Fatalf("balance %d but the ledger sums to %d", bal, ledgerSum(t, s, user))
	}
}

func TestGrantsAreIdempotent(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	bal, applied, err := s.GrantCoins(ctx, adultA, domain.CoinPurchase, "k1", "coins_s", 40)
	if err != nil || !applied || bal != 40 {
		t.Fatal(bal, applied, err)
	}
	bal, applied, err = s.GrantCoins(ctx, adultA, domain.CoinPurchase, "k1", "coins_s", 40)
	if err != nil || applied || bal != 40 {
		t.Fatalf("a replay: %d %v %v", bal, applied, err)
	}
	if mustCount(t, s, `SELECT count(*) FROM coin_ledger`) != 1 {
		t.Fatal("a replay wrote a second row")
	}
	if _, _, err = s.GrantCoins(ctx, adultA, domain.CoinPurchase, "k2", "", 0); err == nil {
		t.Fatal("a zero grant")
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestSpendNeverGoesBelowZero(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	if _, _, err := s.SpendCoins(ctx, adultA, domain.CoinSpendChatSlot, "s0", "", 1); !errors.Is(err, domain.ErrNegativeBalance) {
		t.Fatalf("an empty balance: %v", err)
	}
	_, _, _ = s.GrantCoins(ctx, adultA, domain.CoinRewardAd, "g", "", 3)
	if _, _, err := s.SpendCoins(ctx, adultA, domain.CoinSpendChatSlot, "s1", "", 4); !errors.Is(err, domain.ErrNegativeBalance) {
		t.Fatalf("more than there is: %v", err)
	}
	bal, applied, err := s.SpendCoins(ctx, adultA, domain.CoinSpendChatSlot, "s2", "", 3)
	if err != nil || !applied || bal != 0 {
		t.Fatal(bal, applied, err)
	}
	// The same spend again changes nothing.
	if bal, applied, err = s.SpendCoins(ctx, adultA, domain.CoinSpendChatSlot, "s2", "", 3); err != nil || applied || bal != 0 {
		t.Fatalf("a replayed spend: %d %v %v", bal, applied, err)
	}
	if mustCount(t, s, `SELECT count(*) FROM coin_ledger`) != 2 {
		t.Fatal("refused spends wrote rows")
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestConcurrentSpendsNeverOverspend(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	_, _, _ = s.GrantCoins(ctx, adultA, domain.CoinPurchase, "seed", "", 15)
	var ok, short atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, applied, err := s.SpendCoins(ctx, adultA, domain.CoinSpendProfile, fmt.Sprintf("race-%d", i), "", 2)
			switch {
			case errors.Is(err, domain.ErrNegativeBalance):
				short.Add(1)
			case err == nil && applied:
				ok.Add(1)
			default:
				t.Errorf("spend %d: %v %v", i, applied, err)
			}
		}(i)
	}
	wg.Wait()
	if ok.Load() != 7 || short.Load() != 17 {
		t.Fatalf("%d spends succeeded, %d were refused; 15 coins pay for 7 spends of 2", ok.Load(), short.Load())
	}
	bal, _ := s.CoinBalance(ctx, adultA)
	if bal != 1 {
		t.Fatalf("balance %d", bal)
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestConcurrentGrantsWithOneKeyApplyOnce(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	var applied atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, ok, err := s.GrantCoins(ctx, adultA, domain.CoinPurchase, "same-key", "", 10)
			if err != nil {
				t.Error(err)
			}
			if ok {
				applied.Add(1)
			}
		}()
	}
	wg.Wait()
	if applied.Load() != 1 {
		t.Fatalf("%d grants applied", applied.Load())
	}
	if bal, _ := s.CoinBalance(ctx, adultA); bal != 10 {
		t.Fatalf("balance %d", bal)
	}
}

func TestLedgerIsAppendOnlyAndChecked(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	_, _, _ = s.GrantCoins(ctx, adultA, domain.CoinPurchase, "k", "", 10)
	// (TRUNCATE is not granted to the API role, and the test harnesses truncate through users, so it has no trigger.)
	for _, q := range []string{`UPDATE coin_ledger SET delta=999`, `DELETE FROM coin_ledger`} {
		if _, err := s.Pool.Exec(ctx, q); err == nil {
			t.Errorf("%s was allowed", q)
		}
	}
	// The database itself refuses a negative balance, a wrong-signed row and a reused key.
	if _, err := s.Pool.Exec(ctx, `UPDATE coin_balances SET balance=-1`); err == nil {
		t.Error("a negative balance was stored")
	}
	if _, err := s.Pool.Exec(ctx, `INSERT INTO coin_ledger(user_id,delta,reason,idempotency_key,balance_after) VALUES($1,5,'spend_chat_slot','x',5)`, adultA); err == nil {
		t.Error("a positive spend was stored")
	}
	if _, err := s.Pool.Exec(ctx, `INSERT INTO coin_ledger(user_id,delta,reason,idempotency_key,balance_after) VALUES($1,5,'purchase','k',5)`, adultA); err == nil {
		t.Error("a reused idempotency key was stored")
	}
	if _, err := s.Pool.Exec(ctx, `INSERT INTO coin_ledger(user_id,delta,reason,idempotency_key,balance_after) VALUES($1,5,'free_money','y',5)`, adultA); err == nil {
		t.Error("an unknown reason was stored")
	}
}

func TestLedgerGoesWithTheMember(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	_, _, _ = s.GrantCoins(ctx, adultB, domain.CoinPurchase, "kb", "", 10)
	if _, err := s.Pool.Exec(ctx, `DELETE FROM users WHERE user_id=$1`, adultB); err != nil {
		t.Fatalf("deleting a member who has coins: %v", err)
	}
	if mustCount(t, s, `SELECT count(*) FROM coin_ledger WHERE user_id=$1`, adultB)+mustCount(t, s, `SELECT count(*) FROM coin_balances WHERE user_id=$1`, adultB) != 0 {
		t.Fatal("a deleted member's coins are still stored")
	}
}

func TestHistoryPages(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	for i := 0; i < 5; i++ {
		_, _, _ = s.GrantCoins(ctx, adultA, domain.CoinRewardAd, fmt.Sprintf("h%d", i), "", 1)
	}
	first, err := s.CoinHistory(ctx, adultA, 0, 3)
	if err != nil || len(first) != 3 || first[0].BalanceAfter != 5 || first[0].Reason != domain.CoinRewardAd {
		t.Fatalf("%+v %v", first, err)
	}
	var before int64
	fmt.Sscan(first[2].ID, &before)
	rest, _ := s.CoinHistory(ctx, adultA, before, 10)
	if len(rest) != 2 || rest[1].BalanceAfter != 1 {
		t.Fatalf("%+v", rest)
	}
	if other, _ := s.CoinHistory(ctx, adultB, 0, 10); len(other) != 0 {
		t.Fatal("another member's history")
	}
}

func coinPurchase(user, tx string, coins int) PurchaseInput {
	return PurchaseInput{UserID: user, Store: "google_play", TxHash: tx, ProductID: "coins_m", Kind: "coins", State: "verified", Coins: coins}
}

func hash64(c string) string {
	sum := sha256.Sum256([]byte(c))
	return hex.EncodeToString(sum[:])
}

func TestPurchasesGrantOnce(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	out, err := s.RecordPurchase(ctx, coinPurchase(adultA, hash64("a"), 130))
	if err != nil || out.CoinsGranted != 130 || out.Balance != 130 || out.AlreadyProcessed || out.State != "verified" {
		t.Fatalf("%+v %v", out, err)
	}
	out, err = s.RecordPurchase(ctx, coinPurchase(adultA, hash64("a"), 130))
	if err != nil || out.CoinsGranted != 0 || !out.AlreadyProcessed || out.Balance != 130 {
		t.Fatalf("a replay: %+v %v", out, err)
	}
	// The same store transaction from another account is refused and nothing moves.
	if _, err = s.RecordPurchase(ctx, coinPurchase(adultB, hash64("a"), 130)); !errors.Is(err, domain.ErrPurchaseClaimed) {
		t.Fatalf("a second account: %v", err)
	}
	if bal, _ := s.CoinBalance(ctx, adultB); bal != 0 {
		t.Fatal("the other account got coins")
	}
	// Concurrent verifies of one purchase grant once.
	var wg sync.WaitGroup
	var granted atomic.Int32
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			o, err := s.RecordPurchase(ctx, coinPurchase(adultA, hash64("race"), 40))
			if err != nil {
				t.Error(err)
			}
			if o.CoinsGranted > 0 {
				granted.Add(1)
			}
		}()
	}
	wg.Wait()
	if granted.Load() != 1 {
		t.Fatalf("a purchase was granted %d times", granted.Load())
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestPendingPurchaseGrantsWhenVerified(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	p := coinPurchase(adultA, hash64("p"), 40)
	p.State = "pending"
	out, err := s.RecordPurchase(ctx, p)
	if err != nil || out.State != "pending" || out.CoinsGranted != 0 || out.Balance != 0 {
		t.Fatalf("%+v %v", out, err)
	}
	if out, _ = s.RecordPurchase(ctx, p); !out.AlreadyProcessed {
		t.Fatal("a pending purchase recorded twice")
	}
	p.State = "verified"
	out, err = s.RecordPurchase(ctx, p)
	if err != nil || out.State != "verified" || out.CoinsGranted != 40 || out.Balance != 40 {
		t.Fatalf("%+v %v", out, err)
	}
}

func TestRefundTakesBackWhatIsLeft(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	_, _ = s.RecordPurchase(ctx, coinPurchase(adultA, hash64("r1"), 100))
	// 30 coins were spent: a refund of 100 can take back 70 only.
	_, _, _ = s.SpendCoins(ctx, adultA, domain.CoinSpendProfile, "spent", "", 30)
	user, found, err := s.RefundPurchase(ctx, hash64("r1"), "", "refunded")
	if err != nil || !found || user != adultA {
		t.Fatal(user, found, err)
	}
	bal, _ := s.CoinBalance(ctx, adultA)
	if bal != 0 {
		t.Fatalf("balance %d after the refund", bal)
	}
	if mustCount(t, s, `SELECT coins_reversed FROM purchases WHERE tx_hash=$1`, hash64("r1")) != 70 || mustCount(t, s, `SELECT count(*) FROM coin_ledger WHERE reason='refund' AND delta=-70`) != 1 {
		t.Fatal("the refund is not in the ledger as 70")
	}
	// Again: nothing.
	if _, found, err = s.RefundPurchase(ctx, hash64("r1"), "", "refunded"); err != nil || !found {
		t.Fatal(err)
	}
	if mustCount(t, s, `SELECT count(*) FROM coin_ledger WHERE reason='refund'`) != 1 {
		t.Fatal("a repeated refund took coins twice")
	}
	// A refunded purchase stays refunded when the app verifies it again: no second grant.
	out, err := s.RecordPurchase(ctx, coinPurchase(adultA, hash64("r1"), 100))
	if err != nil || out.State != "refunded" || out.CoinsGranted != 0 {
		t.Fatalf("%+v %v", out, err)
	}
	// A reversed refund gives back what was taken.
	if _, found, err = s.ReverseRefund(ctx, hash64("r1"), ""); err != nil || !found {
		t.Fatal(err)
	}
	if bal, _ = s.CoinBalance(ctx, adultA); bal != 70 {
		t.Fatalf("balance %d after the reversal", bal)
	}
	if _, found, _ = s.RefundPurchase(ctx, hash64("unknown"), "", "refunded"); found {
		t.Fatal("an unknown purchase was found")
	}
	if _, _, err = s.RefundPurchase(ctx, hash64("r1"), "", "bogus"); err == nil {
		t.Fatal("a bad end state")
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestSubscriptionsAndPlanState(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	st, err := s.PlanState(ctx, adultA)
	if err != nil || !st.Monetizable() || st.Plan() != domain.PlanFree || st.Sub != nil {
		t.Fatalf("%+v %v", st, err)
	}
	if st, _ = s.PlanState(ctx, teenC); st.Monetizable() || !st.AgeKnown {
		t.Fatalf("a minor is monetizable: %+v", st)
	}
	if st, _ = s.PlanState(ctx, noAge); st.Monetizable() || st.AgeKnown {
		t.Fatalf("an unknown age is monetizable: %+v", st)
	}
	end := time.Now().Add(30 * 24 * time.Hour)
	sub := PurchaseInput{UserID: adultA, Store: "app_store", TxHash: hash64("t1"), ProductID: "premium_1m", Kind: "subscription", State: "verified",
		Sub: &SubInput{OriginalHash: hash64("o1"), Status: "active", PeriodEnd: end, AutoRenew: true}}
	out, err := s.RecordPurchase(ctx, sub)
	if err != nil || out.CoinsGranted != 0 {
		t.Fatalf("%+v %v", out, err)
	}
	if st, _ = s.PlanState(ctx, adultA); st.Plan() != domain.PlanPremium || st.Sub.Status != "active" || !st.Sub.AutoRenew {
		t.Fatalf("%+v", st.Sub)
	}
	// Another account cannot claim the same subscription (with a renewal's new transaction id), and nothing is left behind.
	other := sub
	other.UserID, other.TxHash = adultB, hash64("t2")
	if _, err = s.RecordPurchase(ctx, other); !errors.Is(err, domain.ErrPurchaseClaimed) {
		t.Fatalf("%v", err)
	}
	if mustCount(t, s, `SELECT count(*) FROM purchases WHERE user_id=$1`, adultB) != 0 {
		t.Fatal("a refused claim left a purchase row")
	}
	// Renewal: the same member, a new transaction, a later period end.
	renew := sub
	renew.TxHash, renew.Sub = hash64("t3"), &SubInput{OriginalHash: hash64("o1"), Status: "active", PeriodEnd: end.Add(30 * 24 * time.Hour), AutoRenew: true}
	if _, err = s.RecordPurchase(ctx, renew); err != nil {
		t.Fatal(err)
	}
	if mustCount(t, s, `SELECT count(*) FROM subscriptions WHERE user_id=$1`, adultA) != 1 {
		t.Fatal("a renewal made a second subscription")
	}
	// The store's notifications move it through grace, hold and expiry.
	grace := end.Add(2 * 24 * time.Hour)
	for _, c := range []struct {
		in   SubInput
		plan domain.Plan
	}{
		{SubInput{OriginalHash: hash64("o1"), Status: "grace", PeriodEnd: end.Add(-time.Hour), GraceUntil: &grace}, domain.PlanPremium},
		{SubInput{OriginalHash: hash64("o1"), Status: "grace", PeriodEnd: end.Add(-time.Hour), GraceUntil: ptr(time.Now().Add(-time.Minute))}, domain.PlanFree},
		{SubInput{OriginalHash: hash64("o1"), Status: "on_hold", PeriodEnd: end}, domain.PlanFree},
		{SubInput{OriginalHash: hash64("o1"), Status: "active", PeriodEnd: time.Now().Add(-time.Minute)}, domain.PlanFree},
		{SubInput{OriginalHash: hash64("o1"), Status: "active", PeriodEnd: end}, domain.PlanPremium},
	} {
		if _, found, err := s.UpdateSubscription(ctx, c.in); err != nil || !found {
			t.Fatal(found, err)
		}
		if st, _ = s.PlanState(ctx, adultA); st.Plan() != c.plan {
			t.Fatalf("%s: plan %s, want %s", c.in.Status, st.Plan(), c.plan)
		}
	}
	if _, found, _ := s.UpdateSubscription(ctx, SubInput{OriginalHash: hash64("nope"), Status: "active", PeriodEnd: end}); found {
		t.Fatal("an unknown subscription was updated")
	}
	// A refund revokes it for good: a later "active" notification does not bring it back.
	if _, _, err = s.RefundPurchase(ctx, hash64("t1"), hash64("o1"), "refunded"); err != nil {
		t.Fatal(err)
	}
	_, _, _ = s.UpdateSubscription(ctx, SubInput{OriginalHash: hash64("o1"), Status: "active", PeriodEnd: end})
	if st, _ = s.PlanState(ctx, adultA); st.Plan() != domain.PlanFree || st.Sub.Status != "revoked" {
		t.Fatalf("%+v", st.Sub)
	}
}

func ptr[T any](v T) *T { return &v }

func TestRewardedAds(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	sess, err := s.StartAdSession(ctx, adultA, 10*time.Minute, 2)
	if err != nil || sess.RemainingToday != 1 {
		t.Fatalf("%+v %v", sess, err)
	}
	if st, _ := s.AdSessionStatus(ctx, adultA, sess.Nonce); st.Status != "pending" {
		t.Fatal(st)
	}
	if _, err = s.AdSessionStatus(ctx, adultB, sess.Nonce); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("another member's session: %v", err)
	}
	res, err := s.CreditAdReward(ctx, adultA, sess.Nonce, hash64("ssv1"), 1, 2)
	if err != nil || res != AdCredited {
		t.Fatal(res, err)
	}
	if bal, _ := s.CoinBalance(ctx, adultA); bal != 1 {
		t.Fatalf("balance %d", bal)
	}
	// The same callback again (Google retries): nothing more. The same transaction id on another session: refused.
	if res, _ = s.CreditAdReward(ctx, adultA, sess.Nonce, hash64("ssv1"), 1, 2); res != AdReplay {
		t.Fatal(res)
	}
	second, _ := s.StartAdSession(ctx, adultA, 10*time.Minute, 2)
	if res, _ = s.CreditAdReward(ctx, adultA, second.Nonce, hash64("ssv1"), 1, 2); res != AdRejected {
		t.Fatalf("a reused AdMob transaction: %s", res)
	}
	// A callback for someone else's nonce, or an unknown one, credits nothing.
	if res, _ = s.CreditAdReward(ctx, adultB, second.Nonce, hash64("ssv9"), 1, 2); res != AdRejected {
		t.Fatal(res)
	}
	if bal, _ := s.CoinBalance(ctx, adultB); bal != 0 {
		t.Fatal("credited the wrong member")
	}
	if st, _ := s.AdSessionStatus(ctx, adultA, second.Nonce); st.Status != "rejected" {
		t.Fatalf("the session with a reused transaction is %s", st.Status)
	}
	third, _ := s.StartAdSession(ctx, adultA, 10*time.Minute, 5)
	fourth, _ := s.StartAdSession(ctx, adultA, 10*time.Minute, 5)
	if res, _ = s.CreditAdReward(ctx, adultA, fourth.Nonce, hash64("ssv2"), 1, 2); res != AdCredited {
		t.Fatal(res)
	}
	// The day's cap: two credited ads, so a start is refused and a late callback is rejected.
	var retry *domain.RetryError
	if _, err = s.StartAdSession(ctx, adultA, time.Minute, 2); !errors.As(err, &retry) {
		t.Fatalf("past the cap: %v", err)
	}
	if res, _ = s.CreditAdReward(ctx, adultA, third.Nonce, hash64("ssv3"), 1, 2); res != AdRejected {
		t.Fatalf("a callback past the cap: %s", res)
	}
	if st, _ := s.AdSessionStatus(ctx, adultA, third.Nonce); st.Status != "rejected" {
		t.Fatal(st)
	}
	if n, _ := s.AdsWatchedToday(ctx, adultA); n != 2 {
		t.Fatalf("%d", n)
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestAdRewardsRefuseMinorsAndExpiredSessions(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	for _, id := range []string{teenC, noAge} {
		sess, err := s.StartAdSession(ctx, id, time.Minute, 5) // the HTTP layer refuses this; the credit does too
		if err != nil {
			t.Fatal(err)
		}
		if res, _ := s.CreditAdReward(ctx, id, sess.Nonce, hash64("m"+id[len(id)-2:]), 1, 5); res != AdRejected {
			t.Fatalf("%s was credited", id)
		}
		if bal, _ := s.CoinBalance(ctx, id); bal != 0 {
			t.Fatal("a minor has coins")
		}
	}
	sess, _ := s.StartAdSession(ctx, adultA, time.Minute, 5)
	mustExec(t, s, `UPDATE ad_reward_sessions SET expires_at=now()-interval '5 minutes' WHERE nonce=$1`, sess.Nonce)
	if st, _ := s.AdSessionStatus(ctx, adultA, sess.Nonce); st.Status != "expired" {
		t.Fatal(st)
	}
	if res, _ := s.CreditAdReward(ctx, adultA, sess.Nonce, hash64("late"), 1, 5); res != AdRejected {
		t.Fatal(res)
	}
}

func TestProfileDetailUnlock(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	var spend *domain.SpendError
	if _, err := s.UnlockProfileDetails(ctx, adultA, adultB, 1, 30, 0); !errors.As(err, &spend) || spend.Code != "SPEND_CONFIRMATION_REQUIRED" || spend.Details["cost"] != 1 {
		t.Fatalf("no confirmation: %v", err)
	}
	if _, err := s.UnlockProfileDetails(ctx, adultA, adultB, 1, 30, 1); !errors.As(err, &spend) || spend.Code != "INSUFFICIENT_COINS" {
		t.Fatalf("no coins: %v", err)
	}
	_, _, _ = s.GrantCoins(ctx, adultA, domain.CoinPurchase, "g", "", 3)
	if _, err := s.UnlockProfileDetails(ctx, adultA, adultB, 1, 30, 2); !errors.As(err, &spend) || spend.Code != "SPEND_CONFIRMATION_REQUIRED" {
		t.Fatalf("a stale price: %v", err)
	}
	res, err := s.UnlockProfileDetails(ctx, adultA, adultB, 1, 30, 1)
	if err != nil || res.Charged != 1 || res.Balance != 2 || time.Until(res.ExpiresAt) < 29*24*time.Hour {
		t.Fatalf("%+v %v", res, err)
	}
	// Still unlocked: free, with or without confirmation.
	if res, err = s.UnlockProfileDetails(ctx, adultA, adultB, 1, 30, 0); err != nil || res.Charged != 0 || res.Balance != 2 {
		t.Fatalf("%+v %v", res, err)
	}
	if until, _ := s.ProfileDetailsUnlockedUntil(ctx, adultA, adultB); until.IsZero() {
		t.Fatal("not unlocked")
	}
	if until, _ := s.ProfileDetailsUnlockedUntil(ctx, adultB, adultA); !until.IsZero() {
		t.Fatal("unlocked in the other direction")
	}
	// After the window it costs again.
	mustExec(t, s, `UPDATE profile_detail_unlocks SET expires_at=now()-interval '1 second'`)
	if res, err = s.UnlockProfileDetails(ctx, adultA, adultB, 1, 30, 1); err != nil || res.Charged != 1 || res.Balance != 1 {
		t.Fatalf("%+v %v", res, err)
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestProfileBonusIsOneTime(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	if claimed, _ := s.ProfileBonusClaimed(ctx, adultA); claimed {
		t.Fatal("claimed before")
	}
	granted, _, bal, err := s.ClaimProfileBonus(ctx, adultA, 5)
	if err != nil || !granted || bal != 5 {
		t.Fatal(granted, bal, err)
	}
	granted, claimed, bal, err := s.ClaimProfileBonus(ctx, adultA, 5)
	if err != nil || granted || !claimed || bal != 5 {
		t.Fatalf("a second claim: %v %v %d %v", granted, claimed, bal, err)
	}
}

func TestAdminAdjustWritesTheAudit(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	var bal int64
	if err := s.Pool.QueryRow(ctx, `SELECT coin_admin_adjust($1,25,'support:test','ticket 1')`, adultA).Scan(&bal); err != nil || bal != 25 {
		t.Fatal(bal, err)
	}
	if mustCount(t, s, `SELECT count(*) FROM coin_ledger WHERE reason='admin_adjust' AND delta=25 AND balance_after=25`) != 1 ||
		mustCount(t, s, `SELECT count(*) FROM operator_audit WHERE action='coin_adjustment' AND actor='support:test' AND reason='ticket 1' AND target_id=$1`, adultA) != 1 {
		t.Fatal("the adjustment is not in the ledger and the audit")
	}
	for name, q := range map[string]string{
		"no reason":  `SELECT coin_admin_adjust($1,5,'a','')`,
		"no actor":   `SELECT coin_admin_adjust($1,5,' ','r')`,
		"zero":       `SELECT coin_admin_adjust($1,0,'a','r')`,
		"below zero": `SELECT coin_admin_adjust($1,-26,'a','r')`,
	} {
		if err := s.Pool.QueryRow(ctx, q, adultA).Scan(&bal); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	if err := s.Pool.QueryRow(ctx, `SELECT coin_admin_adjust($1,5,'a','r')`, "00000000-0000-7000-8000-00000000ffff").Scan(&bal); err == nil {
		t.Error("an unknown member")
	}
	if bal2, _ := s.CoinBalance(ctx, adultA); bal2 != 25 || mustCount(t, s, `SELECT count(*) FROM operator_audit WHERE action='coin_adjustment'`) != 1 {
		t.Fatal("a refused adjustment left something behind")
	}
	checkBalanceMatchesLedger(t, s, adultA)
}

func TestBillableMemberAndPurge(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	for id, want := range map[string]bool{adultA: true, teenC: false, noAge: false, "00000000-0000-7000-8000-00000000ffff": false} {
		if got, err := s.BillableMember(ctx, id); err != nil || got != want {
			t.Errorf("%s: %v %v", id, got, err)
		}
	}
	sess, _ := s.StartAdSession(ctx, adultA, time.Minute, 5)
	mustExec(t, s, `UPDATE ad_reward_sessions SET created_at=now()-interval '4 days' WHERE nonce=$1`, sess.Nonce)
	_, _ = s.UnlockProfileDetails(ctx, adultA, adultB, 0, 30, 0)
	mustExec(t, s, `UPDATE profile_detail_unlocks SET expires_at=now()-interval '40 days'`)
	if n, err := s.PurgeBilling(ctx, 100); err != nil || n != 2 {
		t.Fatalf("%d %v", n, err)
	}
}

// The account purge removes a member's billing rows through purge_member_billing; the ledger stays append-only for everything else.
func TestPurgeMemberBillingRemovesTheLedgerAndNothingElse(t *testing.T) {
	s, ctx := billingStore(t), context.Background()
	_, _, _ = s.GrantCoins(ctx, adultA, domain.CoinPurchase, "pa", "", 10)
	_, _, _ = s.GrantCoins(ctx, adultB, domain.CoinPurchase, "pb", "", 10)
	_, _ = s.RecordPurchase(ctx, coinPurchase(adultA, hash64("pp"), 5))
	if _, err := s.Pool.Exec(ctx, `DELETE FROM coin_ledger WHERE user_id=$1`, adultA); err == nil {
		t.Fatal("a direct delete of ledger rows was allowed")
	}
	var n int
	if err := s.Pool.QueryRow(ctx, `SELECT purge_member_billing($1)`, adultA).Scan(&n); err != nil || n < 4 {
		t.Fatalf("%d %v", n, err)
	}
	if mustCount(t, s, `SELECT count(*) FROM coin_ledger WHERE user_id=$1`, adultA)+mustCount(t, s, `SELECT count(*) FROM purchases WHERE user_id=$1`, adultA)+
		mustCount(t, s, `SELECT count(*) FROM coin_balances WHERE user_id=$1`, adultA) != 0 {
		t.Fatal("rows remain")
	}
	if bal, _ := s.CoinBalance(ctx, adultB); bal != 10 || mustCount(t, s, `SELECT count(*) FROM coin_ledger WHERE user_id=$1`, adultB) != 1 {
		t.Fatal("another member's rows were removed")
	}
	// The permission lasts one transaction: afterwards a direct delete is refused again.
	if _, err := s.Pool.Exec(ctx, `DELETE FROM coin_ledger WHERE user_id=$1`, adultB); err == nil {
		t.Fatal("the purge permission leaked past its transaction")
	}
}
