package billing

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// ---- catalog

func TestDefaultCatalogIsValidAndFindsProducts(t *testing.T) {
	c := DefaultCatalog()
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	p, ok := c.Product("coins_m")
	if !ok || p.Subscription || p.Coins != 130 || p.StoreID(StoreGoogle) != "coins_m" {
		t.Fatalf("%+v %v", p, ok)
	}
	if s, ok := c.Product("premium_12m"); !ok || !s.Subscription || s.PeriodMonths != 12 {
		t.Fatalf("%+v", s)
	}
	if _, ok := c.Product("coins_free"); ok {
		t.Fatal("an unknown product exists")
	}
	if p, ok := c.ByStoreID(StoreApple, "premium_1m"); !ok || p.ID != "premium_1m" {
		t.Fatal("store id lookup")
	}
}

func TestLoadCatalogFile(t *testing.T) {
	write := func(s string) string {
		p := filepath.Join(t.TempDir(), "c.json")
		_ = os.WriteFile(p, []byte(s), 0o600)
		return p
	}
	c, err := LoadCatalog(write(`{"policy":{"premiumFeatures":["genderFilter"],"freeNewChatsPerDay":5,"chatSlotCoinCost":3},"coinPacks":[{"id":"coins_x","name":"X","coins":10,"appleProductId":"app.x"}],"ads":{"coinsPerAd":2,"dailyCap":3,"sessionMinutes":5}}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.Policy.FreeNewChatsPerDay != 5 || c.Policy.ChatSlotCoinCost != 3 || len(c.Policy.PremiumOnly) != 1 || c.Policy.ProfileDetailDays != 30 || len(c.CoinPacks) != 1 || len(c.Subscriptions) != 3 {
		t.Fatalf("%+v", c)
	}
	if p, _ := c.Product("coins_x"); p.StoreID(StoreApple) != "app.x" || p.StoreID(StoreGoogle) != "coins_x" {
		t.Fatalf("%+v", p)
	}
	for name, bad := range map[string]string{
		"unknown key":      `{"prices":{}}`,
		"unknown feature":  `{"policy":{"premiumFeatures":["telepathy"]}}`,
		"zero coins":       `{"coinPacks":[{"id":"coins_x","name":"X","coins":0}]}`,
		"duplicate":        `{"coinPacks":[{"id":"a_1","name":"X","coins":1},{"id":"a_1","name":"Y","coins":1}]}`,
		"bad period":       `{"subscriptions":[{"id":"p_1","name":"P","periodMonths":0}]}`,
		"ads out of range": `{"ads":{"coinsPerAd":1000,"dailyCap":1,"sessionMinutes":5}}`,
		"not json":         `{`,
	} {
		if _, err := LoadCatalog(write(bad)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := LoadCatalog("/nonexistent/catalog.json"); err == nil || strings.Contains(err.Error(), "/nonexistent") {
		t.Errorf("missing file: %v", err)
	}
}

func TestBenefitsFollowThePolicy(t *testing.T) {
	pol := domain.DefaultPlanPolicy()
	rows := Benefits(domain.Resolve(domain.PlanFree, true, true, pol), domain.Resolve(domain.PlanPremium, true, true, pol))
	by := map[string]Benefit{}
	for _, r := range rows {
		by[r.Key] = r
	}
	if c := by["newChats"]; c.Free.Type != "limit" || c.Free.Value != 3 || c.Premium.Type != "unlimited" {
		t.Fatalf("%+v", c)
	}
	if c := by["genderFilter"]; c.Free.Type != "notIncluded" || c.Premium.Type != "included" {
		t.Fatalf("%+v", c)
	}
	if c := by["profileDetails"]; c.Free.Type != "coins" || c.Free.Value != 1 || c.Free.Days != 30 {
		t.Fatalf("%+v", c)
	}
	pol.PremiumOnly = []domain.Feature{domain.FeatureGenderFilter}
	rows = Benefits(domain.Resolve(domain.PlanFree, true, true, pol), domain.Resolve(domain.PlanPremium, true, true, pol))
	for _, r := range rows {
		if r.Key == "autoTranslate" && r.Free.Type != "included" {
			t.Fatalf("a feature Premium does not reserve is shown as locked: %+v", r)
		}
	}
}

func TestHashIsStoreScopedAndOpaque(t *testing.T) {
	a, b := Hash(StoreGoogle, "tok"), Hash(StoreApple, "tok")
	if a == b || len(a) != 64 || strings.Contains(a, "tok") {
		t.Fatal(a, b)
	}
}

// ---- Google Play

type fakeGoogle struct {
	*httptest.Server
	tokenCalls atomic.Int32
	acks       atomic.Int32
	status     int
	body       string
	lastPath   atomic.Value
}

func newFakeGoogle(t *testing.T) (*fakeGoogle, *Google) {
	t.Helper()
	f := &fakeGoogle{status: 200}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			f.tokenCalls.Add(1)
			if r.FormValue("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || strings.Count(r.FormValue("assertion"), ".") != 2 {
				w.WriteHeader(400)
				return
			}
			_, _ = w.Write([]byte(`{"access_token":"at-1","expires_in":3600}`))
		case strings.HasSuffix(r.URL.Path, ":acknowledge"):
			f.acks.Add(1)
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{}`))
		default:
			if r.Header.Get("Authorization") != "Bearer at-1" {
				w.WriteHeader(401)
				return
			}
			f.lastPath.Store(r.URL.Path)
			w.WriteHeader(f.status)
			_, _ = w.Write([]byte(f.body))
		}
	}))
	t.Cleanup(f.Close)
	_, acc := googleKeyFile(t, f.URL+"/token")
	g, err := NewGoogle("app.hiyall.test", acc, true)
	if err != nil {
		t.Fatal(err)
	}
	g.Endpoint = f.URL
	return f, g
}

func TestGoogleServiceAccountFile(t *testing.T) {
	path, _ := googleKeyFile(t, "")
	acc, err := LoadGoogleAccount(path)
	if err != nil || acc.TokenURI != "https://oauth2.googleapis.com/token" {
		t.Fatal(err, acc.TokenURI)
	}
	for name, content := range map[string]string{"missing": "", "not json": "x", "wrong type": `{"type":"user"}`, "http token uri": `{"type":"service_account","client_email":"a","private_key":"b","token_uri":"http://x"}`} {
		p := filepath.Join(t.TempDir(), "f.json")
		if content != "" {
			_ = os.WriteFile(p, []byte(content), 0o600)
		}
		if _, err := LoadGoogleAccount(p); err == nil {
			t.Errorf("%s accepted", name)
		} else if strings.Contains(err.Error(), "PRIVATE") {
			t.Errorf("%s: error leaks the key", name)
		}
	}
}

func TestGoogleProductVerification(t *testing.T) {
	f, g := newFakeGoogle(t)
	ctx := context.Background()
	f.body = `{"purchaseState":0,"acknowledgementState":0,"obfuscatedExternalAccountId":"u-1","productId":"coins_m"}`
	v, err := g.Product(ctx, "coins_m", "tok")
	if err != nil || v.State != StateVerified || v.AccountID != "u-1" || !v.NeedsAck || v.Test {
		t.Fatalf("%+v %v", v, err)
	}
	if f.lastPath.Load() != "/androidpublisher/v3/applications/app.hiyall.test/purchases/products/coins_m/tokens/tok" {
		t.Fatal(f.lastPath.Load())
	}
	// The access token is fetched once and reused.
	_, _ = g.Product(ctx, "coins_m", "tok")
	if f.tokenCalls.Load() != 1 {
		t.Fatalf("token requests: %d", f.tokenCalls.Load())
	}
	f.body = `{"purchaseState":2}`
	if v, err = g.Product(ctx, "coins_m", "tok"); err != nil || v.State != StatePending {
		t.Fatalf("%+v %v", v, err)
	}
	f.body = `{"purchaseState":1}`
	if _, err = g.Product(ctx, "coins_m", "tok"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a canceled purchase: %v", err)
	}
	f.body = `{"purchaseState":0,"productId":"coins_l"}`
	if _, err = g.Product(ctx, "coins_m", "tok"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a purchase of another product: %v", err)
	}
	f.body = `{"purchaseState":0,"purchaseType":0}`
	if v, err = g.Product(ctx, "coins_m", "tok"); err != nil || !v.Test {
		t.Fatalf("a test purchase: %+v %v", v, err)
	}
	g.AllowTest = false
	if _, err = g.Product(ctx, "coins_m", "tok"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("test purchases refused when not allowed: %v", err)
	}
	f.body = `not json`
	if _, err = g.Product(ctx, "coins_m", "tok"); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	for status, want := range map[int]error{404: ErrInvalid, 410: ErrInvalid, 400: ErrInvalid, 403: ErrMisconfigured, 500: ErrUnavailable, 429: ErrUnavailable} {
		f.status = status
		if _, err = g.Product(ctx, "coins_m", "tok"); !errors.Is(err, want) {
			t.Errorf("HTTP %d: %v, want %v", status, err, want)
		}
	}
}

func TestGoogleSubscriptionVerification(t *testing.T) {
	f, g := newFakeGoogle(t)
	ctx := context.Background()
	end := time.Now().Add(30 * 24 * time.Hour).UTC().Format(time.RFC3339)
	sub := func(state string) string {
		return `{"subscriptionState":"` + state + `","lineItems":[{"productId":"premium_1m","expiryTime":"` + end + `","autoRenewingPlan":{"autoRenewEnabled":true}}],"acknowledgementState":"ACKNOWLEDGEMENT_STATE_PENDING","externalAccountIdentifiers":{"obfuscatedExternalAccountId":"u-9"}}`
	}
	cases := map[string]string{"SUBSCRIPTION_STATE_ACTIVE": SubActive, "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": SubGrace, "SUBSCRIPTION_STATE_ON_HOLD": SubOnHold,
		"SUBSCRIPTION_STATE_PAUSED": SubPaused, "SUBSCRIPTION_STATE_EXPIRED": SubExpired, "SUBSCRIPTION_STATE_CANCELED": SubActive}
	for state, want := range cases {
		f.body = sub(state)
		v, err := g.Subscription(ctx, "premium_1m", "ptok")
		if err != nil || v.Subscription.Status != want || v.AccountID != "u-9" || !v.NeedsAck || v.State != StateVerified {
			t.Fatalf("%s: %+v %v", state, v, err)
		}
		if state == "SUBSCRIPTION_STATE_CANCELED" && v.Subscription.AutoRenew {
			t.Fatal("a canceled subscription still renews")
		}
		if state == "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" && v.Subscription.GraceUntil == nil {
			t.Fatal("grace has no end")
		}
	}
	f.body = sub("SUBSCRIPTION_STATE_PENDING")
	if v, err := g.Subscription(ctx, "premium_1m", "ptok"); err != nil || v.State != StatePending {
		t.Fatalf("%+v %v", v, err)
	}
	f.body = sub("SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED")
	if _, err := g.Subscription(ctx, "premium_1m", "ptok"); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	f.body = sub("SUBSCRIPTION_STATE_ACTIVE")
	if _, err := g.Subscription(ctx, "premium_12m", "ptok"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("another product's token: %v", err)
	}
	if err := g.Acknowledge(ctx, true, "premium_1m", "ptok"); err != nil || f.acks.Load() != 1 {
		t.Fatal(err)
	}
}

func TestGoogleTokenEndpointFailures(t *testing.T) {
	f, g := newFakeGoogle(t)
	g.Account.TokenURI = f.URL + "/token-bad"
	if _, err := g.Product(context.Background(), "p", "t"); !errors.Is(err, ErrMisconfigured) {
		t.Fatalf("refused credentials: %v", err)
	}
	g.Account.TokenURI = "http://127.0.0.1:1/token"
	if _, err := g.Product(context.Background(), "p", "t"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("unreachable: %v", err)
	}
}

func TestParseRTDN(t *testing.T) {
	data := base64.StdEncoding.EncodeToString([]byte(`{"packageName":"app.hiyall.test","voidedPurchaseNotification":{"purchaseToken":"tk","orderId":"GPA.1","productType":2,"refundType":1}}`))
	n, err := ParseRTDN([]byte(`{"message":{"data":"` + data + `","messageId":"1"},"subscription":"projects/x/subscriptions/y"}`))
	if err != nil || n.Voided == nil || n.Voided.PurchaseToken != "tk" || n.PackageName != "app.hiyall.test" {
		t.Fatalf("%+v %v", n, err)
	}
	for _, bad := range []string{`{}`, `{"message":{"data":"!!"}}`, `{"message":{"data":"` + base64.StdEncoding.EncodeToString([]byte("x")) + `"}}`, `nope`} {
		if _, err := ParseRTDN([]byte(bad)); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

// ---- Apple

func txInfo(c map[string]any) map[string]any {
	base := map[string]any{"transactionId": "1000", "originalTransactionId": "1000", "bundleId": "app.hiyall.test", "productId": "coins_m", "environment": "Production", "type": "Consumable"}
	for k, v := range c {
		base[k] = v
	}
	return base
}

func TestAppleVerifyJWSChain(t *testing.T) {
	chain := newAppleChain(t, true)
	a := appleClient(t, chain, "", "", true)
	var out map[string]any
	if err := a.VerifyJWS(chain.sign(t, txInfo(nil)), &out); err != nil || out["productId"] != "coins_m" {
		t.Fatal(err, out)
	}
	good := chain.sign(t, txInfo(nil))
	parts := strings.Split(good, ".")
	tampered := parts[0] + "." + b64([]byte(`{"productId":"coins_xl"}`)) + "." + parts[2]
	other := newAppleChain(t, true)
	noMarkers := newAppleChain(t, false)
	rsaHeader := b64([]byte(`{"alg":"RS256","x5c":["a","b"]}`)) + ".e30.AAAA"
	cases := map[string]string{"tampered payload": tampered, "another root": other.sign(t, txInfo(nil)), "no Apple extensions": noMarkers.sign(t, txInfo(nil)),
		"wrong alg": rsaHeader, "not a jws": "abc", "empty": "", "short signature": parts[0] + "." + parts[1] + "." + b64([]byte("x"))}
	for name, token := range cases {
		if err := a.VerifyJWS(token, &out); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	// An expired chain is refused.
	a.Now = func() time.Time { return time.Now().Add(72 * time.Hour) }
	if err := a.VerifyJWS(good, &out); err == nil {
		t.Error("an expired chain was accepted")
	}
}

type fakeApple struct {
	*httptest.Server
	chain   *appleChain
	t       *testing.T
	tx      map[string]map[string]any // transaction id -> payload
	sub     map[string]any            // subscriptions response data
	status  int
	authsOK atomic.Int32
}

func newFakeApple(t *testing.T, chain *appleChain) *fakeApple {
	f := &fakeApple{chain: chain, t: t, tx: map[string]map[string]any{}, status: 200}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || strings.Count(r.Header.Get("Authorization"), ".") != 2 {
			w.WriteHeader(401)
			return
		}
		f.authsOK.Add(1)
		if f.status != 200 {
			w.WriteHeader(f.status)
			return
		}
		switch {
		case strings.HasPrefix(r.URL.Path, "/inApps/v1/transactions/"):
			tx, ok := f.tx[strings.TrimPrefix(r.URL.Path, "/inApps/v1/transactions/")]
			if !ok {
				w.WriteHeader(404)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"signedTransactionInfo": chain.sign(t, tx)})
		case strings.HasPrefix(r.URL.Path, "/inApps/v1/subscriptions/"):
			if f.sub == nil {
				w.WriteHeader(404)
				return
			}
			_ = json.NewEncoder(w).Encode(f.sub)
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(f.Close)
	return f
}

func TestAppleConsumableVerification(t *testing.T) {
	chain := newAppleChain(t, true)
	prod, sandbox := newFakeApple(t, chain), newFakeApple(t, chain)
	a := appleClient(t, chain, prod.URL, sandbox.URL, true)
	ctx := context.Background()
	prod.tx["1000"] = txInfo(map[string]any{"appAccountToken": "AAAA-BBBB"})
	v, err := a.Transaction(ctx, "1000", "coins_m")
	if err != nil || v.State != StateVerified || v.TxKey != "1000" || v.AccountID != "aaaa-bbbb" || v.Test || v.Subscription != nil {
		t.Fatalf("%+v %v", v, err)
	}
	// A sandbox purchase is found on the second host and flagged as a test.
	sandbox.tx["2000"] = txInfo(map[string]any{"transactionId": "2000", "environment": "Sandbox"})
	if v, err = a.Transaction(ctx, "2000", "coins_m"); err != nil || !v.Test {
		t.Fatalf("%+v %v", v, err)
	}
	a.AllowSandbox = false
	if _, err = a.Transaction(ctx, "2000", "coins_m"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("sandbox refused when not allowed: %v", err)
	}
	a.AllowSandbox = true
	// Unknown id, other product, other app, other transaction id inside the signed data, revoked.
	if _, err = a.Transaction(ctx, "9999", "coins_m"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("unknown: %v", err)
	}
	if _, err = a.Transaction(ctx, "1000", "coins_l"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("other product: %v", err)
	}
	prod.tx["3000"] = txInfo(map[string]any{"transactionId": "3000", "bundleId": "com.other.app"})
	if _, err = a.Transaction(ctx, "3000", "coins_m"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("other app: %v", err)
	}
	prod.tx["4000"] = txInfo(map[string]any{"transactionId": "5555"})
	if _, err = a.Transaction(ctx, "4000", "coins_m"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a signed transaction for another id: %v", err)
	}
	prod.tx["6000"] = txInfo(map[string]any{"transactionId": "6000", "revocationDate": 1700000000000})
	if v, err = a.Transaction(ctx, "6000", "coins_m"); err != nil || !v.Revoked {
		t.Fatalf("%+v %v", v, err)
	}
	for _, bad := range []string{"", strings.Repeat("1", 65), "1/../2", "1?x"} {
		if _, err = a.Transaction(ctx, bad, ""); !errors.Is(err, ErrInvalid) {
			t.Errorf("%q: %v", bad, err)
		}
	}
	prod.status = 401
	if _, err = a.Transaction(ctx, "1000", "coins_m"); !errors.Is(err, ErrMisconfigured) {
		t.Fatalf("refused credentials: %v", err)
	}
	prod.status = 503
	if _, err = a.Transaction(ctx, "1000", "coins_m"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("down: %v", err)
	}
}

func TestAppleSubscriptionStatus(t *testing.T) {
	chain := newAppleChain(t, true)
	prod := newFakeApple(t, chain)
	a := appleClient(t, chain, prod.URL, prod.URL, true)
	end := time.Now().Add(20 * 24 * time.Hour).UnixMilli()
	tx := txInfo(map[string]any{"transactionId": "77", "originalTransactionId": "70", "productId": "premium_1m", "type": "Auto-Renewable Subscription", "expiresDate": end})
	prod.tx["77"] = tx
	status := func(code int, renewal map[string]any) {
		prod.sub = map[string]any{"data": []any{map[string]any{"lastTransactions": []any{map[string]any{"originalTransactionId": "70", "status": code,
			"signedTransactionInfo": chain.sign(t, tx), "signedRenewalInfo": chain.sign(t, renewal)}}}}}
	}
	for code, want := range map[int]string{1: SubActive, 2: SubExpired, 3: SubOnHold, 4: SubGrace, 5: SubRevoked} {
		status(code, map[string]any{"autoRenewStatus": 1, "gracePeriodExpiresDate": end + 1000})
		v, err := a.Transaction(context.Background(), "77", "premium_1m")
		if err != nil || v.Subscription.Status != want || v.Subscription.OriginalKey != "70" {
			t.Fatalf("status %d: %+v %v", code, v.Subscription, err)
		}
		if code == 1 && !v.Subscription.AutoRenew {
			t.Fatal("auto renew lost")
		}
		if code == 4 && (v.Subscription.GraceUntil == nil || v.Subscription.GraceUntil.UnixMilli() != end+1000) {
			t.Fatal("grace end lost")
		}
	}
	// Without a status endpoint the transaction itself decides.
	prod.sub = nil
	v, err := a.Transaction(context.Background(), "77", "premium_1m")
	if err != nil || v.Subscription.Status != SubActive {
		t.Fatalf("%+v %v", v.Subscription, err)
	}
	// A subscription whose period ended is expired.
	tx["expiresDate"] = time.Now().Add(-time.Hour).UnixMilli()
	prod.tx["77"] = tx
	if v, err = a.Transaction(context.Background(), "77", "premium_1m"); err != nil || v.Subscription.Status != SubExpired {
		t.Fatalf("%+v %v", v.Subscription, err)
	}
}

func TestAppleNotificationParsing(t *testing.T) {
	chain := newAppleChain(t, true)
	a := appleClient(t, chain, "", "", true)
	payload := func(bundle string) []byte {
		body := map[string]any{"notificationType": "REFUND", "subtype": "", "data": map[string]any{"environment": "Production", "bundleId": bundle,
			"signedTransactionInfo": chain.sign(t, txInfo(nil)), "signedRenewalInfo": chain.sign(t, map[string]any{"autoRenewStatus": 0})}}
		raw, _ := json.Marshal(map[string]string{"signedPayload": chain.sign(t, body)})
		return raw
	}
	n, err := a.ParseNotification(payload("app.hiyall.test"))
	if err != nil || n.Type != "REFUND" || n.Transaction == nil || n.Transaction.TransactionID != "1000" || n.Renewal == nil {
		t.Fatalf("%+v %v", n, err)
	}
	if _, err = a.ParseNotification(payload("com.other.app")); err == nil {
		t.Error("a notification for another app was accepted")
	}
	forged := newAppleChain(t, true)
	raw, _ := json.Marshal(map[string]string{"signedPayload": forged.sign(t, map[string]any{"notificationType": "REFUND"})})
	if _, err = a.ParseNotification(raw); err == nil {
		t.Error("a notification signed by another root was accepted")
	}
	if _, err = a.ParseNotification([]byte(`{}`)); err == nil {
		t.Error("no payload accepted")
	}
	sub := a.SubscriptionFromNotification(Notification{Type: "DID_FAIL_TO_RENEW", Subtype: "GRACE_PERIOD", Transaction: &TransactionInfo{ExpiresDate: time.Now().Add(time.Hour).UnixMilli(), OriginalTransactionID: "70"}})
	if sub.Status != SubGrace || sub.GraceUntil == nil {
		t.Fatalf("%+v", sub)
	}
	if sub = a.SubscriptionFromNotification(Notification{Type: "REVOKE", Transaction: &TransactionInfo{ExpiresDate: time.Now().Add(time.Hour).UnixMilli()}}); sub.Status != SubRevoked {
		t.Fatalf("%+v", sub)
	}
	if sub = a.SubscriptionFromNotification(Notification{Type: "EXPIRED", Transaction: &TransactionInfo{ExpiresDate: time.Now().Add(time.Hour).UnixMilli()}}); sub.Status != SubExpired {
		t.Fatalf("%+v", sub)
	}
}

func TestApplePrivateKeyAndRootFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		_ = os.WriteFile(p, []byte(content), 0o600)
		return p
	}
	if _, err := LoadApplePrivateKey(write("a", "not pem")); err == nil {
		t.Error("garbage key accepted")
	}
	k, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	if _, err := LoadApplePrivateKey(write("b", string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})))); err == nil {
		t.Error("a P-384 key accepted")
	}
	if _, err := LoadAppleRoots(write("c", "nothing")); err == nil {
		t.Error("an empty root file accepted")
	}
	chain := newAppleChain(t, true)
	if _, err := LoadAppleRoots(write("d.cer", string(chain.root.Raw))); err != nil {
		t.Errorf("a DER certificate: %v", err)
	}
	if _, err := LoadAppleRoots(write("e.pem", string(chain.rootPEM))); err != nil {
		t.Errorf("a PEM certificate: %v", err)
	}
}

// ---- AdMob

type fakeAdMob struct {
	*httptest.Server
	key     *ecdsa.PrivateKey
	fetches atomic.Int32
}

func newFakeAdMob(t *testing.T) (*fakeAdMob, *AdMob) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	f := &fakeAdMob{key: key}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.fetches.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{"keyId": 3335741209, "pem": pemKey, "base64": ""}}})
	}))
	t.Cleanup(f.Close)
	m := NewAdMob([]string{"ca-app-pub-1111111111111111/2222222222"})
	m.KeysURL = f.URL
	return f, m
}

// query builds a signed callback query string the way AdMob does: signature and key_id are the last two parameters.
func (f *fakeAdMob) query(t *testing.T, params url.Values, keyID string) string {
	signed := "ad_network=5450213213286189855&ad_unit=" + params.Get("ad_unit") + "&reward_amount=1&reward_item=coin&timestamp=" + params.Get("timestamp") +
		"&transaction_id=" + params.Get("transaction_id") + "&user_id=" + params.Get("user_id") + "&custom_data=" + params.Get("custom_data")
	sum := sha256.Sum256([]byte(signed))
	sig, err := ecdsa.SignASN1(rand.Reader, f.key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return signed + "&signature=" + base64.RawURLEncoding.EncodeToString(sig) + "&key_id=" + keyID
}

func adParams(ts time.Time) url.Values {
	return url.Values{"ad_unit": {"2222222222"}, "timestamp": {strconv.FormatInt(ts.UnixMilli(), 10)}, "transaction_id": {"tx-abc"}, "user_id": {"019a4000-0000-7000-8000-000000000001"}, "custom_data": {"019a4000-0000-7000-8000-0000000000a1"}}
}

func TestAdMobSignatureVerification(t *testing.T) {
	f, m := newFakeAdMob(t)
	ctx := context.Background()
	q := f.query(t, adParams(time.Now()), "3335741209")
	r, err := m.Verify(ctx, q)
	if err != nil || r.UserID != "019a4000-0000-7000-8000-000000000001" || r.CustomData != "019a4000-0000-7000-8000-0000000000a1" || r.TransactionID != "tx-abc" {
		t.Fatalf("%+v %v", r, err)
	}
	// Keys are cached.
	if _, err = m.Verify(ctx, q); err != nil || f.fetches.Load() != 1 {
		t.Fatalf("fetches %d %v", f.fetches.Load(), err)
	}
	bad := map[string]string{
		"changed user":      strings.Replace(q, "user_id=019a4000-0000-7000-8000-000000000001", "user_id=019a4000-0000-7000-8000-000000000002", 1),
		"changed ad unit":   strings.Replace(q, "ad_unit=2222222222", "ad_unit=3333333333", 1),
		"no signature":      strings.Split(q, "&signature=")[0],
		"garbage signature": strings.Split(q, "&signature=")[0] + "&signature=AAAA&key_id=3335741209",
		"unknown key id":    strings.Replace(q, "key_id=3335741209", "key_id=1", 1),
		"no key id":         strings.Split(q, "&key_id=")[0],
		"empty":             "",
	}
	for name, qq := range bad {
		if _, err := m.Verify(ctx, qq); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	// A correctly signed callback for an ad unit that is not ours, or an old or future one, is refused too.
	other := adParams(time.Now())
	other.Set("ad_unit", "9999999999")
	if _, err = m.Verify(ctx, f.query(t, other, "3335741209")); !errors.Is(err, ErrInvalid) {
		t.Errorf("other unit: %v", err)
	}
	if _, err = m.Verify(ctx, f.query(t, adParams(time.Now().Add(-48*time.Hour)), "3335741209")); !errors.Is(err, ErrInvalid) {
		t.Errorf("old: %v", err)
	}
	if _, err = m.Verify(ctx, f.query(t, adParams(time.Now().Add(3*time.Hour)), "3335741209")); !errors.Is(err, ErrInvalid) {
		t.Errorf("future: %v", err)
	}
	noCustom := adParams(time.Now())
	noCustom.Set("custom_data", "")
	if _, err = m.Verify(ctx, f.query(t, noCustom, "3335741209")); !errors.Is(err, ErrInvalid) {
		t.Errorf("no custom data: %v", err)
	}
}

func TestAdMobKeyFetchFailureAndRefetchLimit(t *testing.T) {
	f, m := newFakeAdMob(t)
	f.Close()
	if _, err := m.Verify(context.Background(), f.query(t, adParams(time.Now()), "3335741209")); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("keys unreachable: %v", err)
	}
	f2, m2 := newFakeAdMob(t)
	for i := 0; i < 5; i++ {
		_, _ = m2.Verify(context.Background(), f2.query(t, adParams(time.Now()), "42"))
	}
	if f2.fetches.Load() != 1 {
		t.Fatalf("unknown key ids refetched the key list %d times", f2.fetches.Load())
	}
}
