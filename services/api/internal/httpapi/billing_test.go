package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"hiyall/services/api/internal/billing"
	"hiyall/services/api/internal/billing/billingtest"
	"hiyall/services/api/internal/domain"
)

const (
	rtdnToken  = "rtdn-secret-0123456789-abcdefgh"
	testBundle = "app.hiyall.test"
	adUnit     = "ca-app-pub-1111111111111111/2222222222"
)

type billingHarness struct {
	*socialHarness
	google *billingtest.Google
	apple  *billingtest.Apple
	admob  *billingtest.AdMob
	bs     *BillingService
}

// billingFixture is a harness with a configured BillingService (fake Google Play, App Store and AdMob), plans enforced, and every test
// member an adult.
func billingFixture(t *testing.T) *billingHarness {
	t.Helper()
	h := &billingHarness{socialHarness: newSocialHarness(t)}
	h.google, h.apple, h.admob = billingtest.NewGoogle(t), billingtest.NewApple(t), billingtest.NewAdMob(t)
	// LoadGoogleAccount insists on an https token endpoint; the fake is plain http, so the file is read here.
	raw, err := os.ReadFile(h.google.KeyFile)
	if err != nil {
		t.Fatal(err)
	}
	var account billing.GoogleAccount
	if err = json.Unmarshal(raw, &account); err != nil {
		t.Fatal(err)
	}
	g, err := billing.NewGoogle(testBundle, account, true)
	if err != nil {
		t.Fatal(err)
	}
	g.Endpoint = h.google.URL
	a, err := billing.NewApple(testBundle, "issuer", "KID", h.apple.KeyFile, h.apple.RootFile, true)
	if err != nil {
		t.Fatal(err)
	}
	a.ProductionURL, a.SandboxURL = h.apple.URL, h.apple.URL
	m := billing.NewAdMob([]string{adUnit})
	m.KeysURL = h.admob.URL
	h.bs = &BillingService{Catalog: billing.DefaultCatalog(), Enforced: true, Google: g, Apple: a, RTDNToken: rtdnToken, AdMob: m, CacheTTL: time.Nanosecond}
	h.api.Billing = h.bs
	// The tests open far more first conversations than the per-minute limiter allows; it is not what is tested here.
	h.api.firstChats = newKeyedLimiter(1000, 1000, accountLimiterKeys)
	for _, id := range []string{alice, bob, cara, dev, eli, xan, yui} {
		h.ageAt(id, 30)
	}
	return h
}

type answer struct {
	status int
	data   map[string]any
	err    map[string]any
	raw    string
}

func (a answer) code() string {
	if a.err == nil {
		return ""
	}
	s, _ := a.err["code"].(string)
	return s
}

func (a answer) details() map[string]any {
	d, _ := a.err["details"].(map[string]any)
	return d
}

// do sends a request; actor "" sends none (the store and ad callbacks).
func (h *socialHarness) do(actor, method, path string, body any, header map[string]string) answer {
	h.t.Helper()
	var reader io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		reader = bytes.NewReader(b)
	default:
		raw, _ := json.Marshal(b)
		reader = bytes.NewReader(raw)
	}
	r := httptest.NewRequest(method, path, reader)
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = "127.0.0.1:50000"
	if actor != "" {
		r.Header.Set("Authorization", "Bearer "+actor)
	}
	for k, v := range header {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	var env struct {
		Data  map[string]any `json:"data"`
		Error map[string]any `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &env); err != nil {
		h.t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
	}
	return answer{w.Code, env.Data, env.Error, w.Body.String()}
}

func (h *socialHarness) want(a answer, status int, code string) answer {
	h.t.Helper()
	if a.status != status || a.code() != code {
		h.t.Fatalf("got %d %q, want %d %q: %s", a.status, a.code(), status, code, a.raw)
	}
	return a
}

func (h *socialHarness) balance(user string) int64 {
	h.t.Helper()
	b, err := h.db.CoinBalance(h.ctx, user)
	if err != nil {
		h.t.Fatal(err)
	}
	return b
}

func num(v any) int { f, _ := v.(float64); return int(f) }

const verifyPath = "/v1/me/billing/purchases/verify"

func googleCoins(product, token string) map[string]any {
	return map[string]any{"store": "google_play", "productId": product, "purchaseToken": token}
}

// ---- state

func TestBillingStateByMember(t *testing.T) {
	h := billingFixture(t)
	h.ageAt(cara, 15)
	h.setAge(dev, 0)
	adult := h.want(h.do(alice, "GET", "/v1/me/billing", nil, nil), 200, "").data
	elig := adult["eligibility"].(map[string]any)
	if adult["enforced"] != true || adult["locksApply"] != true || elig["monetizable"] != true || elig["shop"] != true || elig["reason"] != nil {
		t.Fatalf("%v", adult)
	}
	cat := adult["catalog"].(map[string]any)
	if len(cat["coinPacks"].([]any)) != 4 || len(cat["subscriptions"].([]any)) != 3 || len(adult["benefits"].([]any)) < 6 {
		t.Fatalf("%v", cat)
	}
	if strings.Contains(h.do(alice, "GET", "/v1/me/billing", nil, nil).raw, "price\"") {
		t.Fatal("the catalog carries a price")
	}
	ent := adult["entitlements"].(map[string]any)
	if num(ent["freeNewChatsPerDay"]) != 3 || num(ent["chatSlotCoinCost"]) != 2 || ent["features"].(map[string]any)["genderFilter"] != false {
		t.Fatalf("%v", ent)
	}
	// A minor and a member whose age is unknown are told nothing about plans.
	for who, reason := range map[string]string{cara: "minor", dev: "age_unknown"} {
		s := h.want(h.do(who, "GET", "/v1/me/billing", nil, nil), 200, "").data
		e := s["eligibility"].(map[string]any)
		if s["locksApply"] != false || e["monetizable"] != false || e["shop"] != false || e["ads"] != false || e["reason"] != reason || num(s["balance"]) != 0 ||
			len(s["catalog"].(map[string]any)["coinPacks"].([]any)) != 0 || len(s["benefits"].([]any)) != 0 || s["ads"].(map[string]any)["enabled"] != false {
			t.Fatalf("%s: %v", reason, s)
		}
		if f := s["entitlements"].(map[string]any)["features"].(map[string]any); f["genderFilter"] != true || f["visitorsList"] != true {
			t.Fatalf("a member who cannot buy has locks: %v", f)
		}
	}
	// Not enforced (the beta): no locks, no shop, everything on, for the adult too.
	h.bs.Enforced = false
	s := h.want(h.do(alice, "GET", "/v1/me/billing", nil, nil), 200, "").data
	if s["locksApply"] != false || s["eligibility"].(map[string]any)["shop"] != false || s["entitlements"].(map[string]any)["features"].(map[string]any)["genderFilter"] != true ||
		s["entitlements"].(map[string]any)["freeNewChatsPerDay"] != nil || s["ads"].(map[string]any)["enabled"] != false {
		t.Fatalf("%v", s)
	}
	// Enforced but no store configured: no shop either.
	h.bs.Enforced, h.bs.Google, h.bs.Apple = true, nil, nil
	if s = h.do(alice, "GET", "/v1/me/billing", nil, nil).data; s["eligibility"].(map[string]any)["shop"] != false {
		t.Fatalf("%v", s)
	}
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "x"), nil), 503, "BILLING_NOT_CONFIGURED")
	h.want(h.do(alice, "POST", verifyPath, map[string]any{"store": "app_store", "productId": "coins_s", "transactionId": "1"}, nil), 503, "BILLING_NOT_CONFIGURED")
}

func TestNilBillingServiceChangesNothing(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(alice, 30)
	e := h.api.entitlementsFor(h.ctx, alice)
	if e.Enforced || !e.Allows(domain.FeatureGenderFilter) || e.PostsPerDay != domain.Free().PostsPerDay {
		t.Fatalf("%+v", e)
	}
	s := h.want(h.do(alice, "GET", "/v1/me/billing", nil, nil), 200, "").data
	if s["enforced"] != false || s["locksApply"] != false || s["eligibility"].(map[string]any)["shop"] != false {
		t.Fatalf("%v", s)
	}
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "x"), nil), 503, "BILLING_NOT_CONFIGURED")
	h.want(h.do("", "POST", googleRTDNPath, []byte(`{}`), nil), 503, "BILLING_NOT_CONFIGURED")
	h.want(h.do("", "POST", appleNotifyPath, []byte(`{}`), nil), 503, "BILLING_NOT_CONFIGURED")
	h.want(h.do("", "GET", admobCallbackPath+"?a=b", nil, nil), 503, "ADS_UNAVAILABLE")
}

// ---- Google Play purchases

func TestGooglePlayCoinPurchase(t *testing.T) {
	h := billingFixture(t)
	h.google.Products["tok-m"] = billingtest.Product(0, alice)
	got := h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_m", "tok-m"), nil), 200, "").data
	if got["state"] != "verified" || got["kind"] != "coins" || num(got["coinsGranted"]) != 130 || num(got["balance"]) != 130 || got["alreadyProcessed"] != false {
		t.Fatalf("%v", got)
	}
	if len(h.google.Acks) != 1 || h.google.Acks[0] != "tok-m" {
		t.Fatalf("acknowledged: %v", h.google.Acks)
	}
	// Repeating it grants nothing; the same token from another account is refused.
	again := h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_m", "tok-m"), nil), 200, "").data
	if again["alreadyProcessed"] != true || num(again["coinsGranted"]) != 0 || num(again["balance"]) != 130 {
		t.Fatalf("%v", again)
	}
	h.google.Products["tok-m"] = billingtest.Product(0, "")
	h.want(h.do(bob, "POST", verifyPath, googleCoins("coins_m", "tok-m"), nil), 409, "PURCHASE_CLAIMED")
	if h.balance(bob) != 0 || h.balance(alice) != 130 {
		t.Fatal("balances moved")
	}
	// A purchase the store made for another account is refused before anything is recorded.
	h.google.Products["tok-other"] = billingtest.Product(0, bob)
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "tok-other"), nil), 409, "PURCHASE_CLAIMED")
	// Not completed, unknown, or the store being down.
	h.google.Products["tok-cancel"] = billingtest.Product(1, "")
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "tok-cancel"), nil), 422, "PURCHASE_INVALID")
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "tok-unknown"), nil), 422, "PURCHASE_INVALID")
	h.google.Down = true
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "tok-down"), nil), 502, "STORE_UNAVAILABLE")
	h.google.Down = false
	// Pending: nothing granted, then granted once when it completes.
	h.google.Products["tok-pend"] = billingtest.Product(2, alice)
	p := h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "tok-pend"), nil), 200, "").data
	if p["state"] != "pending" || num(p["coinsGranted"]) != 0 || num(p["balance"]) != 130 {
		t.Fatalf("%v", p)
	}
	h.google.Products["tok-pend"] = billingtest.Product(0, alice)
	p = h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "tok-pend"), nil), 200, "").data
	if p["state"] != "verified" || num(p["coinsGranted"]) != 40 || num(p["balance"]) != 170 {
		t.Fatalf("%v", p)
	}
	hist := h.want(h.do(alice, "GET", "/v1/me/billing/history", nil, nil), 200, "").data
	if rows := items(hist); len(rows) != 2 || rows[0]["reason"] != "purchase" || num(rows[0]["balanceAfter"]) != 170 || num(rows[0]["delta"]) != 40 {
		t.Fatalf("%v", hist)
	}
}

func TestVerifyValidation(t *testing.T) {
	h := billingFixture(t)
	for name, body := range map[string]any{
		"unknown product":  googleCoins("coins_free", "t"),
		"unknown store":    map[string]any{"store": "paypal", "productId": "coins_s", "purchaseToken": "t"},
		"no token":         map[string]any{"store": "google_play", "productId": "coins_s"},
		"extra key":        map[string]any{"store": "google_play", "productId": "coins_s", "purchaseToken": "t", "coins": 1000},
		"apple with token": map[string]any{"store": "app_store", "productId": "coins_s", "purchaseToken": "t"},
		"long token":       googleCoins("coins_s", strings.Repeat("x", 5000)),
		"newline":          googleCoins("coins_s", "a\nb"),
	} {
		if a := h.do(alice, "POST", verifyPath, body, nil); a.status != 422 {
			t.Errorf("%s: %d %s", name, a.status, a.raw)
		}
	}
	// A coin product that the store says is a subscription (and the other way round) is invalid.
	h.google.Subs["sub"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_1m", time.Now().Add(24*time.Hour), alice)
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "sub"), nil), 422, "PURCHASE_INVALID")
	h.google.Products["prod"] = billingtest.Product(0, alice)
	h.want(h.do(alice, "POST", verifyPath, googleCoins("premium_1m", "prod"), nil), 422, "PURCHASE_INVALID")
	if h.balance(alice) != 0 {
		t.Fatal("a mismatched purchase granted coins")
	}
}

func TestConcurrentVerifiesGrantOnce(t *testing.T) {
	h := billingFixture(t)
	h.google.Products["race"] = billingtest.Product(0, alice)
	var wg sync.WaitGroup
	var granted atomic.Int32
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a := h.do(alice, "POST", verifyPath, googleCoins("coins_s", "race"), nil)
			if a.status == 200 && num(a.data["coinsGranted"]) == 40 {
				granted.Add(1)
			}
		}()
	}
	wg.Wait()
	if granted.Load() != 1 || h.balance(alice) != 40 {
		t.Fatalf("granted %d times, balance %d", granted.Load(), h.balance(alice))
	}
}

// ---- minors

func TestMinorsAndUnknownAgeAreRefusedOnEveryMoneyRoute(t *testing.T) {
	h := billingFixture(t)
	h.ageAt(cara, 17)
	h.setAge(dev, 0)
	h.google.Products["tok"] = billingtest.Product(0, "")
	h.google.Subs["sub"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_1m", time.Now().Add(24*time.Hour), "")
	for _, who := range []string{cara, dev} {
		h.want(h.do(who, "POST", verifyPath, googleCoins("coins_s", "tok"), nil), 403, "AGE_RESTRICTED")
		h.want(h.do(who, "POST", verifyPath, googleCoins("premium_1m", "sub"), nil), 403, "AGE_RESTRICTED")
		h.want(h.do(who, "GET", "/v1/me/billing/history", nil, nil), 403, "AGE_RESTRICTED")
		h.want(h.do(who, "POST", "/v1/me/billing/ads/session", nil, nil), 403, "AGE_RESTRICTED")
		h.want(h.do(who, "POST", "/v1/me/billing/ads/reward", map[string]any{"nonce": alice}, nil), 403, "AGE_RESTRICTED")
		h.want(h.do(who, "POST", "/v1/me/billing/bonuses/profile-completion", nil, nil), 403, "AGE_RESTRICTED")
		h.want(h.do(who, "POST", "/v1/users/"+bob+"/profile-details/unlock", map[string]any{"confirmCost": 1}, nil), 403, "AGE_RESTRICTED")
		if h.balance(who) != 0 {
			t.Fatal("a member who cannot buy has coins")
		}
		// And they are never gated: every entitlement is on, nothing costs coins.
		e := h.api.entitlementsFor(h.ctx, who)
		if e.Enforced || !e.Allows(domain.FeatureGenderFilter) || e.ChatSlotCost(1000) != 0 || e.PostsPerDay != domain.Free().PostsPerDay {
			t.Fatalf("%+v", e)
		}
	}
	// A store notification for a minor does not credit them either.
	h.google.Products["tok2"] = billingtest.Product(0, cara)
	body := billingtest.RTDN(map[string]any{"packageName": testBundle, "oneTimeProductNotification": map[string]any{"notificationType": 1, "purchaseToken": "tok2", "sku": "coins_s"}})
	h.want(h.do("", "POST", googleRTDNPath+"?token="+rtdnToken, body, nil), 200, "")
	if h.balance(cara) != 0 {
		t.Fatal("a notification credited a minor")
	}
}

// ---- subscriptions, Apple, notifications

func appleTx(id, original, product, kind, account string, expires time.Time) map[string]any {
	return billingtest.Transaction(testBundle, id, original, product, kind, account, expires)
}

func TestAppleCoinPurchaseAndRefund(t *testing.T) {
	h := billingFixture(t)
	h.apple.Tx["9001"] = appleTx("9001", "9001", "coins_l", "Consumable", alice, time.Time{})
	body := map[string]any{"store": "app_store", "productId": "coins_l", "transactionId": "9001"}
	got := h.want(h.do(alice, "POST", verifyPath, body, nil), 200, "").data
	if num(got["coinsGranted"]) != 340 || num(got["balance"]) != 340 {
		t.Fatalf("%v", got)
	}
	// Someone else's transaction, an unknown id and a transaction of another app.
	h.want(h.do(bob, "POST", verifyPath, body, nil), 409, "PURCHASE_CLAIMED")
	h.want(h.do(alice, "POST", verifyPath, map[string]any{"store": "app_store", "productId": "coins_l", "transactionId": "1"}, nil), 422, "PURCHASE_INVALID")
	h.apple.Tx["9002"] = billingtest.Transaction("com.other", "9002", "9002", "coins_l", "Consumable", alice, time.Time{})
	h.want(h.do(alice, "POST", verifyPath, map[string]any{"store": "app_store", "productId": "coins_l", "transactionId": "9002"}, nil), 422, "PURCHASE_INVALID")
	h.apple.Down = true
	h.want(h.do(alice, "POST", verifyPath, body, nil), 502, "STORE_UNAVAILABLE")
	h.apple.Down = false
	// 100 coins are spent, then Apple refunds the purchase: the 240 still there are taken back, the ledger says so.
	if _, _, err := h.db.SpendCoins(h.ctx, alice, domain.CoinSpendProfile, "x", "", 100); err != nil {
		t.Fatal(err)
	}
	// A notification that does not verify changes nothing.
	forged := billingtest.NewApple(t)
	h.want(h.do("", "POST", appleNotifyPath, forged.Notification(t, "REFUND", "", testBundle, h.apple.Tx["9001"], 0), nil), 401, "UNAUTHENTICATED")
	h.want(h.do("", "POST", appleNotifyPath, h.apple.Notification(t, "REFUND", "", "com.other", h.apple.Tx["9001"], 0), nil), 401, "UNAUTHENTICATED")
	if h.balance(alice) != 240 {
		t.Fatal("a forged refund moved coins")
	}
	h.want(h.do("", "POST", appleNotifyPath, h.apple.Notification(t, "REFUND", "", testBundle, h.apple.Tx["9001"], 0), nil), 200, "")
	if h.balance(alice) != 0 {
		t.Fatalf("balance %d after the refund", h.balance(alice))
	}
	// The app verifying the refunded purchase again does not grant it again.
	h.want(h.do(alice, "POST", verifyPath, body, nil), 422, "PURCHASE_INVALID")
	h.want(h.do("", "POST", appleNotifyPath, h.apple.Notification(t, "REFUND", "", testBundle, h.apple.Tx["9001"], 0), nil), 200, "")
	if n := h.count(`SELECT count(*) FROM coin_ledger WHERE reason='refund'`); n != 1 {
		t.Fatalf("%d refund rows", n)
	}
	h.want(h.do("", "POST", appleNotifyPath, h.apple.Notification(t, "REFUND_REVERSED", "", testBundle, h.apple.Tx["9001"], 0), nil), 200, "")
	if h.balance(alice) != 240 {
		t.Fatalf("balance %d after the refund was reversed", h.balance(alice))
	}
}

func TestAppleSubscriptionLifecycle(t *testing.T) {
	h := billingFixture(t)
	end := time.Now().Add(30 * 24 * time.Hour)
	tx := appleTx("7001", "7000", "premium_1m", "Auto-Renewable Subscription", alice, end)
	h.apple.Tx["7001"] = tx
	body := map[string]any{"store": "app_store", "productId": "premium_1m", "transactionId": "7001"}
	got := h.want(h.do(alice, "POST", verifyPath, body, nil), 200, "").data
	plan := got["plan"].(map[string]any)
	if got["kind"] != "subscription" || num(got["coinsGranted"]) != 0 || plan["id"] != "premium" || plan["status"] != "active" || plan["store"] != "app_store" {
		t.Fatalf("%v", got)
	}
	e := h.api.entitlementsFor(h.ctx, alice)
	if !e.Enforced || !e.Allows(domain.FeatureGenderFilter) || e.ChatSlotCost(100) != 0 || e.PostsPerDay != domain.EntitlementsFor(domain.PlanPremium).PostsPerDay {
		t.Fatalf("%+v", e)
	}
	// Another account cannot take the subscription.
	h.want(h.do(bob, "POST", verifyPath, body, nil), 409, "PURCHASE_CLAIMED")
	notify := func(kind, sub string, status int) {
		h.want(h.do("", "POST", appleNotifyPath, h.apple.Notification(t, kind, sub, testBundle, tx, status), nil), 200, "")
	}
	notify("DID_FAIL_TO_RENEW", "GRACE_PERIOD", 4)
	if p := h.api.entitlementsFor(h.ctx, alice).Plan; p != domain.PlanPremium {
		t.Fatalf("grace is still Premium: %s", p)
	}
	if s := h.do(alice, "GET", "/v1/me/billing", nil, nil).data["plan"].(map[string]any); s["status"] != "grace" {
		t.Fatalf("%v", s)
	}
	notify("EXPIRED", "VOLUNTARY", 2)
	if p := h.api.entitlementsFor(h.ctx, alice).Plan; p != domain.PlanFree {
		t.Fatalf("expired: %s", p)
	}
	if e = h.api.entitlementsFor(h.ctx, alice); e.Allows(domain.FeatureGenderFilter) {
		t.Fatal("an expired subscription keeps Premium features")
	}
	notify("DID_RENEW", "", 1)
	if p := h.api.entitlementsFor(h.ctx, alice).Plan; p != domain.PlanPremium {
		t.Fatalf("renewed: %s", p)
	}
	notify("REVOKE", "", 5)
	notify("DID_RENEW", "", 1) // a stale notification does not resurrect a revoked subscription
	if p := h.api.entitlementsFor(h.ctx, alice).Plan; p != domain.PlanFree {
		t.Fatalf("revoked: %s", p)
	}
	// A subscription the app never verified, bought with the member's account token, appears from the notification alone.
	tx2 := appleTx("7101", "7100", "premium_3m", "Auto-Renewable Subscription", bob, end)
	h.want(h.do("", "POST", appleNotifyPath, h.apple.Notification(t, "SUBSCRIBED", "INITIAL_BUY", testBundle, tx2, 1), nil), 200, "")
	if p := h.api.entitlementsFor(h.ctx, bob).Plan; p != domain.PlanPremium {
		t.Fatalf("a notification for a purchase the app never verified: %s", p)
	}
}

func TestGoogleSubscriptionAndNotifications(t *testing.T) {
	h := billingFixture(t)
	end := time.Now().Add(30 * 24 * time.Hour)
	h.google.Subs["sub1"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_12m", end, alice)
	got := h.want(h.do(alice, "POST", verifyPath, googleCoins("premium_12m", "sub1"), nil), 200, "").data
	if got["plan"].(map[string]any)["id"] != "premium" {
		t.Fatalf("%v", got)
	}
	rtdn := func(n map[string]any) {
		n["packageName"] = testBundle
		h.want(h.do("", "POST", googleRTDNPath+"?token="+rtdnToken, billingtest.RTDN(n), nil), 200, "")
	}
	subEvent := func(kind int) map[string]any {
		return map[string]any{"subscriptionNotification": map[string]any{"notificationType": kind, "purchaseToken": "sub1", "subscriptionId": "premium_12m"}}
	}
	h.google.Subs["sub1"] = billingtest.Subscription("SUBSCRIPTION_STATE_ON_HOLD", "premium_12m", end, alice)
	rtdn(subEvent(5))
	if h.api.entitlementsFor(h.ctx, alice).Plan != domain.PlanFree {
		t.Fatal("on hold is not Premium")
	}
	h.google.Subs["sub1"] = billingtest.Subscription("SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "premium_12m", end, alice)
	rtdn(subEvent(6))
	if h.api.entitlementsFor(h.ctx, alice).Plan != domain.PlanPremium {
		t.Fatal("grace is Premium")
	}
	h.google.Subs["sub1"] = billingtest.Subscription("SUBSCRIPTION_STATE_EXPIRED", "premium_12m", end, alice)
	rtdn(subEvent(13))
	if h.api.entitlementsFor(h.ctx, alice).Plan != domain.PlanFree {
		t.Fatal("expired")
	}
	// Revoked (a refund) ends it for good.
	h.google.Subs["sub1"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_12m", end, alice)
	rtdn(subEvent(2))
	if h.api.entitlementsFor(h.ctx, alice).Plan != domain.PlanPremium {
		t.Fatal("renewed")
	}
	rtdn(subEvent(12))
	rtdn(subEvent(2))
	if h.api.entitlementsFor(h.ctx, alice).Plan != domain.PlanFree {
		t.Fatal("revoked and then renewed again by a late notification")
	}
	// A subscription the app never verified, bought for a member, is picked up from the notification.
	h.google.Subs["sub2"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_1m", end, bob)
	rtdn(map[string]any{"subscriptionNotification": map[string]any{"notificationType": 4, "purchaseToken": "sub2", "subscriptionId": "premium_1m"}})
	if h.api.entitlementsFor(h.ctx, bob).Plan != domain.PlanPremium {
		t.Fatal("a notification did not record a purchase the app never verified")
	}
	// A subscription with no account id cannot be credited to anyone from a notification alone.
	h.google.Subs["sub3"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_1m", end, "")
	rtdn(map[string]any{"subscriptionNotification": map[string]any{"notificationType": 4, "purchaseToken": "sub3", "subscriptionId": "premium_1m"}})
	if h.count(`SELECT count(*) FROM subscriptions`) != 2 {
		t.Fatal("an unowned subscription was recorded")
	}
}

func TestGoogleOneTimeNotificationsAndVoids(t *testing.T) {
	h := billingFixture(t)
	url := googleRTDNPath + "?token=" + rtdnToken
	send := func(n map[string]any) answer {
		n["packageName"] = testBundle
		return h.do("", "POST", url, billingtest.RTDN(n), nil)
	}
	// The app never got to verify: Google says it was purchased for alice, and it is granted from the notification.
	h.google.Products["lost"] = billingtest.Product(0, alice)
	h.want(send(map[string]any{"oneTimeProductNotification": map[string]any{"notificationType": 1, "purchaseToken": "lost", "sku": "coins_s"}}), 200, "")
	if h.balance(alice) != 40 {
		t.Fatalf("balance %d", h.balance(alice))
	}
	// The same notification again (Pub/Sub delivers at least once) and then the app's own verify: one grant in all.
	h.want(send(map[string]any{"oneTimeProductNotification": map[string]any{"notificationType": 1, "purchaseToken": "lost", "sku": "coins_s"}}), 200, "")
	got := h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", "lost"), nil), 200, "").data
	if got["alreadyProcessed"] != true || h.balance(alice) != 40 {
		t.Fatalf("%v %d", got, h.balance(alice))
	}
	// A pending purchase completes by notification.
	h.google.Products["slow"] = billingtest.Product(2, alice)
	h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_m", "slow"), nil), 200, "")
	h.google.Products["slow"] = billingtest.Product(0, alice)
	h.want(send(map[string]any{"oneTimeProductNotification": map[string]any{"notificationType": 1, "purchaseToken": "slow", "sku": "coins_m"}}), 200, "")
	if h.balance(alice) != 170 {
		t.Fatalf("balance %d", h.balance(alice))
	}
	// A refund (voided purchase) takes the coins back, once.
	void := map[string]any{"voidedPurchaseNotification": map[string]any{"purchaseToken": "slow", "orderId": "GPA.1", "productType": 2, "refundType": 1}}
	h.want(send(void), 200, "")
	h.want(send(void), 200, "")
	if h.balance(alice) != 40 {
		t.Fatalf("balance %d after a void", h.balance(alice))
	}
	// Notifications for another app, test notifications and unknown tokens are acknowledged and ignored.
	h.want(h.do("", "POST", url, billingtest.RTDN(map[string]any{"packageName": "com.other", "voidedPurchaseNotification": map[string]any{"purchaseToken": "lost", "productType": 2}}), nil), 200, "")
	h.want(send(map[string]any{"testNotification": map[string]any{"version": "1.0"}}), 200, "")
	h.want(send(void), 200, "")
	h.want(send(map[string]any{"voidedPurchaseNotification": map[string]any{"purchaseToken": "never-seen", "productType": 2}}), 200, "")
	if h.balance(alice) != 40 {
		t.Fatal("an ignored notification moved coins")
	}
	// The store being down makes Pub/Sub retry.
	h.google.Down = true
	h.google.Products["later"] = billingtest.Product(0, alice)
	h.want(send(map[string]any{"oneTimeProductNotification": map[string]any{"notificationType": 1, "purchaseToken": "later", "sku": "coins_s"}}), 503, "STORE_UNAVAILABLE")
}

func TestGoogleNotificationsNeedTheToken(t *testing.T) {
	h := billingFixture(t)
	body := billingtest.RTDN(map[string]any{"packageName": testBundle, "voidedPurchaseNotification": map[string]any{"purchaseToken": "x", "productType": 2}})
	for _, url := range []string{googleRTDNPath, googleRTDNPath + "?token=", googleRTDNPath + "?token=wrong", googleRTDNPath + "?token=" + rtdnToken + "x", googleRTDNPath + "?token=" + strings.ToUpper(rtdnToken)} {
		h.want(h.do("", "POST", url, body, nil), 401, "UNAUTHENTICATED")
	}
	h.want(h.do("", "POST", googleRTDNPath+"?token="+rtdnToken, []byte(`nonsense`), nil), 422, "VALIDATION")
	// No RTDN token configured: the endpoint is off, it does not accept an empty one.
	h.bs.RTDNToken = ""
	h.want(h.do("", "POST", googleRTDNPath+"?token=", body, nil), 503, "BILLING_NOT_CONFIGURED")
}

// ---- enforcement flag and the features

func TestEnforcementSwitchesTheFeatureGates(t *testing.T) {
	h := billingFixture(t)
	search := func(who string, body map[string]any) answer {
		return h.do(who, "POST", "/v1/discovery/search", body, nil)
	}
	nearbyBody := map[string]any{"radiusKm": 25}
	// Enforced, Free: the gender filter, Nearby filters and the visitors list are Premium.
	a := h.want(search(alice, map[string]any{"gender": "woman"}), 402, "PREMIUM_REQUIRED")
	if a.details()["feature"] != "genderFilter" {
		t.Fatalf("%v", a.err)
	}
	h.want(search(alice, map[string]any{"interests": []string{"music"}}), 200, "")
	h.want(h.do(alice, "GET", "/v1/me/visitors", nil, nil), 402, "PREMIUM_REQUIRED")
	if a = h.do(alice, "POST", "/v1/discover/nearby", map[string]any{"radiusKm": 25, "languages": []string{"en"}}, nil); a.status != 402 || a.details()["feature"] != "nearbyFilter" {
		t.Fatalf("%d %s", a.status, a.raw)
	}
	if a = h.do(alice, "POST", "/v1/discover/nearby", map[string]any{"radiusKm": 25, "gender": "man"}, nil); a.status != 402 || a.details()["feature"] != "genderFilter" {
		t.Fatalf("%d %s", a.status, a.raw)
	}
	if a = h.do(alice, "POST", "/v1/discover/nearby", nearbyBody, nil); a.status == 402 {
		t.Fatalf("plain Nearby is not Premium: %s", a.raw)
	}
	// The same requests for a member under 18 are never a paywall (their own filters are refused for other reasons).
	h.ageAt(cara, 15)
	if a = h.do(cara, "GET", "/v1/me/visitors", nil, nil); a.status == 402 {
		t.Fatalf("a minor met a paywall: %s", a.raw)
	}
	// Premium unlocks all of it.
	h.google.Subs["p"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_1m", time.Now().Add(48*time.Hour), alice)
	h.want(h.do(alice, "POST", verifyPath, googleCoins("premium_1m", "p"), nil), 200, "")
	if a = search(alice, map[string]any{"gender": "woman"}); a.status != 200 {
		t.Fatalf("%d %s", a.status, a.raw)
	}
	h.want(h.do(alice, "GET", "/v1/me/visitors", nil, nil), 200, "")
	if a = h.do(alice, "POST", "/v1/discover/nearby", map[string]any{"radiusKm": 25, "languages": []string{"en"}}, nil); a.status == 402 {
		t.Fatalf("%s", a.raw)
	}
	// The master switch off: everyone is unlocked, Premium or not.
	h.bs.Enforced = false
	if a = search(bob, map[string]any{"gender": "woman"}); a.status != 200 {
		t.Fatalf("%d %s", a.status, a.raw)
	}
	h.want(h.do(bob, "GET", "/v1/me/visitors", nil, nil), 200, "")
	// The policy decides which features are reserved.
	h.bs.Enforced = true
	h.bs.Catalog.Policy.PremiumOnly = []domain.Feature{domain.FeatureGenderFilter}
	h.want(h.do(bob, "GET", "/v1/me/visitors", nil, nil), 200, "")
	h.want(search(bob, map[string]any{"gender": "woman"}), 402, "PREMIUM_REQUIRED")
}

// ---- chat slots

func TestChatSlotsCostCoinsPastTheFreeAllowance(t *testing.T) {
	h := billingFixture(t)
	open := func(from, to string, header map[string]string) answer {
		return h.do(from, "POST", "/v1/conversations", map[string]any{"userId": to}, header)
	}
	for _, peer := range []string{bob, cara, dev} {
		h.want(open(alice, peer, nil), 200, "")
	}
	// Reopening an existing conversation is free and never asks.
	h.want(open(alice, bob, nil), 200, "")
	// The fourth would cost 2 coins: it says so, takes nothing, and creates nothing.
	a := h.want(open(alice, eli, nil), 402, "SPEND_CONFIRMATION_REQUIRED")
	if num(a.details()["cost"]) != 2 || num(a.details()["balance"]) != 0 || a.details()["reason"] != "chat_slot" {
		t.Fatalf("%v", a.err)
	}
	if n := h.count(`SELECT count(*) FROM conversations WHERE created_by=$1`, alice); n != 3 {
		t.Fatalf("%d conversations", n)
	}
	// Confirmed, but no coins.
	a = h.want(open(alice, eli, map[string]string{"Spend-Confirm": "2"}), 402, "INSUFFICIENT_COINS")
	if num(a.details()["cost"]) != 2 {
		t.Fatalf("%v", a.err)
	}
	if _, _, err := h.db.GrantCoins(h.ctx, alice, domain.CoinPurchase, "seed", "", 5); err != nil {
		t.Fatal(err)
	}
	// A confirmation of another price is not a confirmation.
	h.want(open(alice, eli, map[string]string{"Spend-Confirm": "1"}), 402, "SPEND_CONFIRMATION_REQUIRED")
	h.want(open(alice, eli, map[string]string{"Spend-Confirm": "nonsense"}), 402, "SPEND_CONFIRMATION_REQUIRED")
	h.want(open(alice, eli, map[string]string{"Spend-Confirm": "2"}), 200, "")
	if h.balance(alice) != 3 {
		t.Fatalf("balance %d", h.balance(alice))
	}
	if h.count(`SELECT count(*) FROM coin_ledger WHERE reason='spend_chat_slot' AND delta=-2`) != 1 {
		t.Fatal("the spend is not in the ledger")
	}
	// Reopening it again costs nothing; being written to costs the other member nothing; being the one who is opened to is never charged.
	h.want(open(alice, eli, map[string]string{"Spend-Confirm": "2"}), 200, "")
	if h.balance(alice) != 3 {
		t.Fatal("a reopening cost coins")
	}
	h.want(open(xan, alice, nil), 200, "")
	h.want(open(yui, alice, nil), 200, "")
	h.want(open(bob, alice, nil), 200, "")
	if h.balance(alice) != 3 {
		t.Fatal("a conversation someone else started cost coins")
	}
	// A conversation that fails to be created keeps the coins: a blocked member cannot be opened to.
	h.want(h.do(alice, "POST", "/v1/users/"+xan+"/block", nil, nil), 200, "")
	open(alice, xan, map[string]string{"Spend-Confirm": "2"})
	if h.balance(alice) != 3 {
		t.Fatal("a refused conversation cost coins")
	}
	// Premium opens as many as it likes; so does the beta.
	h.google.Subs["p"] = billingtest.Subscription("SUBSCRIPTION_STATE_ACTIVE", "premium_1m", time.Now().Add(48*time.Hour), bob)
	h.want(h.do(bob, "POST", verifyPath, googleCoins("premium_1m", "p"), nil), 200, "")
	for _, peer := range []string{cara, dev, eli, yui} {
		h.want(open(bob, peer, nil), 200, "")
	}
	if h.balance(bob) != 0 {
		t.Fatal("Premium paid for chats")
	}
	h.bs.Enforced = false
	h.want(open(alice, yui, nil), 200, "")
	h.want(open(alice, cara, nil), 200, "")
}

func TestConcurrentChatOpensNeverOverspend(t *testing.T) {
	h := billingFixture(t)
	h.bs.Catalog.Policy.FreeNewChatsPerDay = 1
	if _, _, err := h.db.GrantCoins(h.ctx, alice, domain.CoinPurchase, "seed", "", 4); err != nil {
		t.Fatal(err)
	}
	h.want(h.do(alice, "POST", "/v1/conversations", map[string]any{"userId": bob}, nil), 200, "")
	var wg sync.WaitGroup
	var ok atomic.Int32
	for _, peer := range []string{cara, dev, eli, xan, yui, cara, dev, eli} {
		wg.Add(1)
		go func(peer string) {
			defer wg.Done()
			if a := h.do(alice, "POST", "/v1/conversations", map[string]any{"userId": peer}, map[string]string{"Spend-Confirm": "2"}); a.status == 200 {
				ok.Add(1)
			}
		}(peer)
	}
	wg.Wait()
	bal := h.balance(alice)
	created := h.count(`SELECT count(*) FROM conversations WHERE created_by=$1`, alice) - 1
	if bal < 0 || int64(created*2) != 4-bal || created > 2 {
		t.Fatalf("balance %d, %d paid conversations", bal, created)
	}
}

// ---- detailed profiles

func TestDetailedProfileLockAndUnlock(t *testing.T) {
	h := billingFixture(t)
	h.exec(`UPDATE profiles SET data=data||'{"bio":"I like trains","aboutMe":"more about me","hometown":"Lyon","profession":"driver"}'::jsonb WHERE user_id=$1`, bob)
	profile := func(viewer, target string) map[string]any {
		return h.want(h.do(viewer, "GET", "/v1/users/"+target+"/profile", nil, nil), 200, "").data
	}
	locked := profile(alice, bob)
	for _, k := range detailedProfileKeys {
		if _, ok := locked[k]; ok {
			t.Errorf("%s is in a locked profile", k)
		}
	}
	if locked["detailsLocked"] != true || locked["userId"] != bob {
		t.Fatalf("%v", locked)
	}
	if own := profile(bob, bob); own["bio"] != "I like trains" || own["detailsLocked"] != nil {
		t.Fatalf("your own profile is locked: %v", own)
	}
	unlock := "/v1/users/" + bob + "/profile-details/unlock"
	a := h.want(h.do(alice, "POST", unlock, nil, nil), 402, "SPEND_CONFIRMATION_REQUIRED")
	if num(a.details()["cost"]) != 1 || a.details()["reason"] != "profile_detail" {
		t.Fatalf("%v", a.err)
	}
	h.want(h.do(alice, "POST", unlock, map[string]any{"confirmCost": 1}, nil), 402, "INSUFFICIENT_COINS")
	if _, _, err := h.db.GrantCoins(h.ctx, alice, domain.CoinPurchase, "seed", "", 3); err != nil {
		t.Fatal(err)
	}
	h.want(h.do(alice, "POST", unlock, map[string]any{"confirmCost": 5}, nil), 402, "SPEND_CONFIRMATION_REQUIRED")
	h.want(h.do(alice, "POST", unlock, map[string]any{"confirmCost": "1"}, nil), 422, "VALIDATION")
	h.want(h.do(alice, "POST", unlock, map[string]any{"confirmCost": 1, "extra": 1}, nil), 422, "VALIDATION")
	res := h.want(h.do(alice, "POST", unlock, map[string]any{"confirmCost": 1}, nil), 200, "").data
	if res["unlocked"] != true || num(res["cost"]) != 1 || num(res["balance"]) != 2 || res["expiresAt"] == nil {
		t.Fatalf("%v", res)
	}
	open := profile(alice, bob)
	if open["bio"] != "I like trains" || open["profession"] != "driver" || open["detailsLocked"] != nil {
		t.Fatalf("%v", open)
	}
	// Unlocking again while it runs is free; someone else's unlock does not carry over; the other direction is separate.
	res = h.want(h.do(alice, "POST", unlock, map[string]any{"confirmCost": 1}, nil), 200, "").data
	if num(res["cost"]) != 0 || num(res["balance"]) != 2 {
		t.Fatalf("%v", res)
	}
	if profile(cara, bob)["detailsLocked"] != true {
		t.Fatal("another viewer saw the details")
	}
	// A blocked member's profile cannot be unlocked (and costs nothing).
	h.want(h.do(bob, "POST", "/v1/users/"+alice+"/block", nil, nil), 200, "")
	h.want(h.do(alice, "POST", "/v1/users/"+bob+"/profile-details/unlock", map[string]any{"confirmCost": 1}, nil), 404, "NOT_FOUND")
	h.want(h.do(bob, "POST", "/v1/users/"+alice+"/block", nil, nil), 200, "") // toggles nothing harmful; keep the state simple
	if h.balance(alice) != 2 {
		t.Fatalf("balance %d", h.balance(alice))
	}
	// Premium sees details without paying; the beta shows them to everybody; the policy can leave them free.
	h.bs.Enforced = false
	if profile(cara, bob)["bio"] != "I like trains" {
		t.Fatal("the beta hides details")
	}
	h.bs.Enforced = true
	h.bs.Catalog.Policy.PremiumOnly = []domain.Feature{domain.FeatureGenderFilter}
	if profile(cara, bob)["bio"] != "I like trains" {
		t.Fatal("details are locked although the policy does not reserve them")
	}
	if res = h.want(h.do(cara, "POST", unlock, map[string]any{"confirmCost": 1}, nil), 200, "").data; num(res["cost"]) != 0 {
		t.Fatalf("%v", res)
	}
}

// ---- rewarded ads

func TestRewardedAdsFlow(t *testing.T) {
	h := billingFixture(t)
	h.bs.Enforced = false
	h.want(h.do(alice, "POST", "/v1/me/billing/ads/session", nil, nil), 503, "ADS_UNAVAILABLE")
	h.bs.Enforced = true
	sess := h.want(h.do(alice, "POST", "/v1/me/billing/ads/session", nil, nil), 200, "").data
	nonce := sess["nonce"].(string)
	if sess["userId"] != alice || sess["customData"] != nonce || num(sess["coins"]) != 1 || num(sess["remainingToday"]) != 4 {
		t.Fatalf("%v", sess)
	}
	poll := func(n string) map[string]any {
		return h.want(h.do(alice, "POST", "/v1/me/billing/ads/reward", map[string]any{"nonce": n}, nil), 200, "").data
	}
	if p := poll(nonce); p["status"] != "pending" || num(p["balance"]) != 0 {
		t.Fatalf("%v", p)
	}
	// The app cannot credit itself: only the signed callback does.
	cb := func(q string) answer { return h.do("", "GET", admobCallbackPath+"?"+q, nil, nil) }
	q := h.admob.Query(t, "2222222222", "adtx-1", alice, nonce, time.Now())
	h.want(cb(strings.Replace(q, "user_id="+alice, "user_id="+bob, 1)), 401, "UNAUTHENTICATED")            // altered after signing
	h.want(cb(h.admob.Query(t, "9999999999", "adtx-x", alice, nonce, time.Now())), 401, "UNAUTHENTICATED") // not our ad unit
	h.want(cb("nonsense"), 401, "UNAUTHENTICATED")
	if p := poll(nonce); p["status"] != "pending" || h.balance(alice) != 0 {
		t.Fatal("a refused callback credited coins")
	}
	h.want(cb(q), 200, "")
	if p := poll(nonce); p["status"] != "credited" || num(p["coins"]) != 1 || num(p["balance"]) != 1 {
		t.Fatalf("%v", poll(nonce))
	}
	// Google retries the callback: the same coins, once. A callback with another transaction id for a credited session is not a second reward.
	h.want(cb(q), 200, "")
	h.want(cb(h.admob.Query(t, "2222222222", "adtx-2", alice, nonce, time.Now())), 200, "")
	if h.balance(alice) != 1 {
		t.Fatalf("balance %d", h.balance(alice))
	}
	// Someone else's session, an unknown nonce and a made-up one: nothing, and the poll of another member's nonce is 404.
	other := h.want(h.do(bob, "POST", "/v1/me/billing/ads/session", nil, nil), 200, "").data["nonce"].(string)
	h.want(cb(h.admob.Query(t, "2222222222", "adtx-3", alice, other, time.Now())), 200, "")
	h.want(cb(h.admob.Query(t, "2222222222", "adtx-4", alice, "019a4000-0000-7000-8000-00000000dead", time.Now())), 200, "")
	h.want(cb(h.admob.Query(t, "2222222222", "adtx-5", "not-a-uuid", "not-a-uuid", time.Now())), 200, "")
	h.want(h.do(alice, "POST", "/v1/me/billing/ads/reward", map[string]any{"nonce": other}, nil), 404, "NOT_FOUND")
	h.want(h.do(alice, "POST", "/v1/me/billing/ads/reward", map[string]any{"nonce": "x"}, nil), 422, "VALIDATION")
	if h.balance(alice) != 1 || h.balance(bob) != 0 {
		t.Fatalf("balances %d %d", h.balance(alice), h.balance(bob))
	}
	// The day's cap: five rewarded ads, the sixth is refused with Retry-After.
	for i := 2; i <= 5; i++ {
		s := h.want(h.do(alice, "POST", "/v1/me/billing/ads/session", nil, nil), 200, "").data["nonce"].(string)
		h.want(cb(h.admob.Query(t, "2222222222", fmt.Sprintf("cap-%d", i), alice, s, time.Now())), 200, "")
	}
	if h.balance(alice) != 5 {
		t.Fatalf("balance %d", h.balance(alice))
	}
	h.want(h.do(alice, "POST", "/v1/me/billing/ads/session", nil, nil), 429, "DAILY_LIMIT")
	if st := h.do(alice, "GET", "/v1/me/billing", nil, nil).data["ads"].(map[string]any); st["enabled"] != true || num(st["watchedToday"]) != 5 || num(st["dailyCap"]) != 5 {
		t.Fatalf("%v", st)
	}
	if rows := items(h.do(alice, "GET", "/v1/me/billing/history", nil, nil).data); len(rows) != 5 || rows[0]["reason"] != "reward_ad" {
		t.Fatalf("%v", rows)
	}
}

func TestAdCallbackForAMinorCreditsNothing(t *testing.T) {
	h := billingFixture(t)
	sess := h.want(h.do(alice, "POST", "/v1/me/billing/ads/session", nil, nil), 200, "").data["nonce"].(string)
	h.ageAt(alice, 16) // the member's age changed (or was wrong) between the session and the callback
	h.want(h.do("", "GET", admobCallbackPath+"?"+h.admob.Query(t, "2222222222", "m-1", alice, sess, time.Now()), nil, nil), 200, "")
	if h.balance(alice) != 0 {
		t.Fatal("coins for a minor")
	}
}

// ---- history, bonus, secrets

func TestHistoryPagingAndProfileBonus(t *testing.T) {
	h := billingFixture(t)
	for i := 0; i < 5; i++ {
		if _, _, err := h.db.GrantCoins(h.ctx, alice, domain.CoinRewardAd, fmt.Sprintf("k%d", i), "", 1); err != nil {
			t.Fatal(err)
		}
	}
	page := h.want(h.do(alice, "GET", "/v1/me/billing/history?limit=2", nil, nil), 200, "").data
	if len(items(page)) != 2 || page["hasMore"] != true || page["nextCursor"] == nil {
		t.Fatalf("%v", page)
	}
	next := h.want(h.do(alice, "GET", "/v1/me/billing/history?limit=2&cursor="+page["nextCursor"].(string), nil, nil), 200, "").data
	if rows := items(next); len(rows) != 2 || num(rows[0]["balanceAfter"]) != 3 {
		t.Fatalf("%v", next)
	}
	h.want(h.do(bob, "GET", "/v1/me/billing/history?cursor="+page["nextCursor"].(string), nil, nil), 422, "INVALID_CURSOR")
	h.want(h.do(alice, "GET", "/v1/me/billing/history?limit=99", nil, nil), 422, "VALIDATION")

	bonus := "/v1/me/billing/bonuses/profile-completion"
	if r := h.want(h.do(bob, "POST", bonus, nil, nil), 200, "").data; r["granted"] != false || r["alreadyClaimed"] != nil {
		t.Fatalf("an incomplete profile: %v", r)
	}
	h.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,variants,expires_at)
 VALUES('019a4000-0000-7000-8000-0000000000b1',$1,'avatar','ready','image/jpeg',10,10,'u/b1','{"thumb":"t","full":"f"}',now()+interval '1 day')`, bob)
	h.exec(`UPDATE profiles SET data=data||'{"avatarMediaId":"019a4000-0000-7000-8000-0000000000b1","bio":"hi","interests":["music"],"languages":[{"code":"en","level":"native"}]}'::jsonb WHERE user_id=$1`, bob)
	if st := h.do(bob, "GET", "/v1/me/billing", nil, nil).data["bonuses"].(map[string]any)["profileCompletion"].(map[string]any); num(st["coins"]) != 5 || st["claimed"] != false {
		t.Fatalf("%v", st)
	}
	r := h.want(h.do(bob, "POST", bonus, nil, nil), 200, "").data
	if r["granted"] != true || num(r["coins"]) != 5 || num(r["balance"]) != 5 {
		t.Fatalf("%v", r)
	}
	if r = h.want(h.do(bob, "POST", bonus, nil, nil), 200, "").data; r["granted"] != false || r["alreadyClaimed"] != true || h.balance(bob) != 5 {
		t.Fatalf("%v", r)
	}
}

type captureLog struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (c *captureLog) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(p)
}

func (c *captureLog) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

// No receipt, purchase token or store id reaches a log line, an error body or the database.
func TestNoReceiptOrTokenIsLoggedOrStored(t *testing.T) {
	h := billingFixture(t)
	var logs captureLog
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(previous)
	const secret = "SECRET-PURCHASE-TOKEN-0123456789"
	const appleSecret = "88889999"
	h.google.Products[secret] = billingtest.Product(0, alice)
	var bodies []string
	bodies = append(bodies, h.want(h.do(alice, "POST", verifyPath, googleCoins("coins_s", secret), nil), 200, "").raw)
	bodies = append(bodies, h.do(alice, "POST", verifyPath, googleCoins("coins_s", secret+"-unknown"), nil).raw)
	h.google.Down = true
	bodies = append(bodies, h.do(alice, "POST", verifyPath, googleCoins("coins_s", secret+"-down"), nil).raw)
	h.google.Down = false
	h.apple.Tx[appleSecret] = appleTx(appleSecret, appleSecret, "coins_s", "Consumable", alice, time.Time{})
	bodies = append(bodies, h.want(h.do(alice, "POST", verifyPath, map[string]any{"store": "app_store", "productId": "coins_s", "transactionId": appleSecret}, nil), 200, "").raw)
	h.do("", "POST", googleRTDNPath+"?token="+rtdnToken, billingtest.RTDN(map[string]any{"packageName": testBundle, "voidedPurchaseNotification": map[string]any{"purchaseToken": secret, "productType": 2}}), nil)
	for _, text := range append(bodies, logs.String()) {
		if strings.Contains(text, secret) || strings.Contains(text, appleSecret) || strings.Contains(text, rtdnToken) {
			t.Fatalf("a token or id leaked: %.300s", text)
		}
	}
	var dump string
	rows, err := h.db.Pool.Query(h.ctx, `SELECT row_to_json(p)::text FROM purchases p UNION ALL SELECT row_to_json(s)::text FROM subscriptions s UNION ALL SELECT row_to_json(l)::text FROM coin_ledger l`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		dump += s
	}
	rows.Close()
	if strings.Contains(dump, secret) || strings.Contains(dump, appleSecret) || dump == "" {
		t.Fatalf("a token or id is stored: %.200s", dump)
	}
}

// The callbacks are reachable without a member token, and nothing else of the billing API is.
func TestWebhooksAreTheOnlyRoutesWithoutAToken(t *testing.T) {
	h := billingFixture(t)
	for _, c := range [][2]string{{"GET", "/v1/me/billing"}, {"POST", verifyPath}, {"GET", "/v1/me/billing/history"}, {"POST", "/v1/me/billing/ads/session"}, {"POST", "/v1/me/billing/ads/reward"}, {"GET", "/v1/billing/google/rtdn"}, {"GET", "/v1/billing/apple/notifications"}, {"POST", admobCallbackPath}} {
		h.want(h.do("", c[0], c[1], nil, nil), 401, "UNAUTHENTICATED")
	}
	if h.api.Handler() == nil {
		t.Fatal()
	}
	_ = http.StatusOK
}
