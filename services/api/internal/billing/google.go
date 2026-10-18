package billing

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	googleScope    = "https://www.googleapis.com/auth/androidpublisher"
	googleEndpoint = "https://androidpublisher.googleapis.com"
	tokenMargin    = 5 * time.Minute
	// googleGraceCap is how long a Google subscription in its grace period stays Premium when Google does not say when
	// the grace period ends (the length is configured per product in Play Console, 3 to 30 days; every notification
	// re-reads the state, so a purchase that moves to "on hold" loses Premium at once).
	googleGraceCap = 7 * 24 * time.Hour
)

// GoogleAccount is the part of a Google service-account key the client needs; its private key never appears in an error or a log.
type GoogleAccount struct {
	Type         string `json:"type"`
	ClientEmail  string `json:"client_email"`
	PrivateKeyID string `json:"private_key_id"`
	PrivateKey   string `json:"private_key"`
	TokenURI     string `json:"token_uri"`
}

// LoadGoogleAccount reads and validates a service-account JSON file. Errors say what is wrong with the file, never what is in it.
func LoadGoogleAccount(path string) (GoogleAccount, error) {
	var a GoogleAccount
	raw, err := os.ReadFile(path)
	if err != nil {
		return a, errors.New("cannot read the Google Play service account file")
	}
	if json.Unmarshal(raw, &a) != nil {
		return a, errors.New("the Google Play service account file is not valid JSON")
	}
	if a.Type != "service_account" || a.ClientEmail == "" || a.PrivateKey == "" {
		return a, errors.New("the Google Play service account file is not a service account key")
	}
	if a.TokenURI == "" {
		a.TokenURI = "https://oauth2.googleapis.com/token"
	}
	if u, err := url.Parse(a.TokenURI); err != nil || u.Scheme != "https" {
		return a, errors.New("the Google Play service account token_uri must be https")
	}
	if _, err = a.key(); err != nil {
		return a, err
	}
	return a, nil
}

func (a GoogleAccount) key() (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(a.PrivateKey))
	if block == nil {
		return nil, errors.New("the Google Play service account private key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("the Google Play service account private key is not PKCS#8")
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("the Google Play service account private key is not RSA")
	}
	return key, nil
}

// Google verifies purchases with the Google Play Developer API (purchases.products, purchases.subscriptionsv2). The OAuth2 access
// token comes from a signed service-account JWT (RS256) exchanged at the account's token endpoint and cached until shortly before
// it expires, the same way the FCM sender does it.
type Google struct {
	Package string
	Account GoogleAccount
	// Endpoint is the API host; empty means Google's. Tests point it at an httptest server (as they do TokenURI of the account).
	Endpoint string
	HTTP     *http.Client
	Now      func() time.Time
	// AllowTest accepts license-tester purchases.
	AllowTest bool

	mu      sync.Mutex
	key     *rsa.PrivateKey
	token   string
	expires time.Time
}

// NewGoogle validates the account and returns a client with a 10 second per-request timeout.
func NewGoogle(pkg string, a GoogleAccount, allowTest bool) (*Google, error) {
	key, err := a.key()
	if err != nil {
		return nil, err
	}
	if pkg == "" {
		return nil, errors.New("GOOGLE_PLAY_PACKAGE_NAME is required")
	}
	return &Google{Package: pkg, Account: a, HTTP: &http.Client{Timeout: 10 * time.Second}, Now: time.Now, key: key, AllowTest: allowTest}, nil
}

func (g *Google) now() time.Time {
	if g.Now != nil {
		return g.Now()
	}
	return time.Now()
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func (g *Google) assertion(now time.Time) (string, error) {
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": g.Account.PrivateKeyID})
	claims, _ := json.Marshal(map[string]any{"iss": g.Account.ClientEmail, "scope": googleScope, "aud": g.Account.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
	signing := b64(header) + "." + b64(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, g.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", errors.New("cannot sign the Google Play token request")
	}
	return signing + "." + b64(sig), nil
}

func (g *Google) accessToken(ctx context.Context) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if g.token != "" && now.Add(tokenMargin).Before(g.expires) {
		return g.token, nil
	}
	assertion, err := g.assertion(now)
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.Account.TokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", ErrMisconfigured
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return "", ErrUnavailable
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
		return "", ErrUnavailable
	}
	if resp.StatusCode != http.StatusOK {
		return "", ErrMisconfigured
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if json.Unmarshal(body, &out) != nil || out.AccessToken == "" {
		return "", ErrMisconfigured
	}
	if out.ExpiresIn <= 0 {
		out.ExpiresIn = 3600
	}
	g.token, g.expires = out.AccessToken, now.Add(time.Duration(out.ExpiresIn)*time.Second)
	return g.token, nil
}

func (g *Google) forget(token string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.token == token {
		g.token = ""
	}
}

// call sends one API request and returns the body of a 200. 404, 410 and 400 (the token or product is not one of ours) are
// ErrInvalid; 401 and 403 (our service account lacks the right) ErrMisconfigured; 429 and 5xx and network errors ErrUnavailable.
func (g *Google) call(ctx context.Context, method, path string, body []byte) ([]byte, error) {
	access, err := g.accessToken(ctx)
	if err != nil {
		return nil, err
	}
	endpoint := g.Endpoint
	if endpoint == "" {
		endpoint = googleEndpoint
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint+path, reader)
	if err != nil {
		return nil, ErrMisconfigured
	}
	req.Header.Set("Authorization", "Bearer "+access)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<18))
	switch {
	case resp.StatusCode == http.StatusOK:
		return raw, nil
	case resp.StatusCode == http.StatusUnauthorized:
		g.forget(access)
		return nil, ErrMisconfigured
	case resp.StatusCode == http.StatusForbidden:
		return nil, ErrMisconfigured
	case resp.StatusCode == http.StatusBadRequest || resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		return nil, ErrInvalid
	}
	return nil, ErrUnavailable
}

func (g *Google) base() string {
	return "/androidpublisher/v3/applications/" + url.PathEscape(g.Package)
}

// Product verifies a one-time product (a coin pack) purchase: purchases.products.get.
func (g *Google) Product(ctx context.Context, productID, token string) (Verified, error) {
	raw, err := g.call(ctx, http.MethodGet, g.base()+"/purchases/products/"+url.PathEscape(productID)+"/tokens/"+url.PathEscape(token), nil)
	if err != nil {
		return Verified{}, err
	}
	var p struct {
		PurchaseState               *int   `json:"purchaseState"`
		PurchaseType                *int   `json:"purchaseType"`
		AcknowledgementState        int    `json:"acknowledgementState"`
		ObfuscatedExternalAccountID string `json:"obfuscatedExternalAccountId"`
		ProductID                   string `json:"productId"`
	}
	if json.Unmarshal(raw, &p) != nil || p.PurchaseState == nil {
		return Verified{}, ErrInvalid
	}
	v := Verified{Store: StoreGoogle, StoreProductID: productID, TxKey: token, AccountID: p.ObfuscatedExternalAccountID, Test: p.PurchaseType != nil && *p.PurchaseType == 0,
		NeedsAck: p.AcknowledgementState == 0}
	if p.ProductID != "" && p.ProductID != productID {
		return Verified{}, ErrInvalid
	}
	switch *p.PurchaseState {
	case 0:
		v.State = StateVerified
	case 2:
		v.State = StatePending
	default:
		return Verified{}, ErrInvalid
	}
	if v.Test && !g.AllowTest {
		return Verified{}, ErrInvalid
	}
	return v, nil
}

// Subscription verifies a subscription purchase token: purchases.subscriptionsv2.get. productID, when not empty, must be one of the
// subscription's line items.
func (g *Google) Subscription(ctx context.Context, productID, token string) (Verified, error) {
	raw, err := g.call(ctx, http.MethodGet, g.base()+"/purchases/subscriptionsv2/tokens/"+url.PathEscape(token), nil)
	if err != nil {
		return Verified{}, err
	}
	return g.subscription(raw, productID, token)
}

func (g *Google) subscription(raw []byte, productID, token string) (Verified, error) {
	var p struct {
		SubscriptionState string `json:"subscriptionState"`
		LineItems         []struct {
			ProductID        string `json:"productId"`
			ExpiryTime       string `json:"expiryTime"`
			AutoRenewingPlan *struct {
				AutoRenewEnabled bool `json:"autoRenewEnabled"`
			} `json:"autoRenewingPlan"`
		} `json:"lineItems"`
		TestPurchase         *struct{} `json:"testPurchase"`
		AcknowledgementState string    `json:"acknowledgementState"`
		External             struct {
			Account string `json:"obfuscatedExternalAccountId"`
		} `json:"externalAccountIdentifiers"`
	}
	if json.Unmarshal(raw, &p) != nil || len(p.LineItems) == 0 {
		return Verified{}, ErrInvalid
	}
	var end time.Time
	var product string
	var renew bool
	for _, li := range p.LineItems {
		t, err := time.Parse(time.RFC3339, li.ExpiryTime)
		if err != nil {
			return Verified{}, ErrInvalid
		}
		if productID != "" && li.ProductID != productID {
			continue
		}
		if t.After(end) {
			end, product = t, li.ProductID
			renew = li.AutoRenewingPlan != nil && li.AutoRenewingPlan.AutoRenewEnabled
		}
	}
	if product == "" {
		return Verified{}, ErrInvalid
	}
	v := Verified{Store: StoreGoogle, StoreProductID: product, TxKey: token, AccountID: p.External.Account, Test: p.TestPurchase != nil,
		NeedsAck: p.AcknowledgementState == "ACKNOWLEDGEMENT_STATE_PENDING"}
	sub := &SubState{PeriodEnd: end, AutoRenew: renew, OriginalKey: token}
	switch p.SubscriptionState {
	case "SUBSCRIPTION_STATE_ACTIVE":
		sub.Status = SubActive
	case "SUBSCRIPTION_STATE_CANCELED":
		sub.Status, sub.AutoRenew = SubActive, false
	case "SUBSCRIPTION_STATE_IN_GRACE_PERIOD":
		sub.Status = SubGrace
		until := end.Add(googleGraceCap)
		sub.GraceUntil = &until
	case "SUBSCRIPTION_STATE_ON_HOLD":
		sub.Status = SubOnHold
	case "SUBSCRIPTION_STATE_PAUSED":
		sub.Status = SubPaused
	case "SUBSCRIPTION_STATE_EXPIRED":
		sub.Status = SubExpired
	case "SUBSCRIPTION_STATE_PENDING":
		v.State = StatePending
		sub.Status = SubExpired
	default:
		return Verified{}, ErrInvalid
	}
	if v.State == "" {
		v.State = StateVerified
	}
	v.Subscription = sub
	if v.Test && !g.AllowTest {
		return Verified{}, ErrInvalid
	}
	return v, nil
}

// Acknowledge tells Google the purchase was delivered (an unacknowledged purchase is refunded after three days). subscription says
// which kind. Failure is returned for the caller to log without the token; the grant stands.
func (g *Google) Acknowledge(ctx context.Context, subscription bool, productID, token string) error {
	kind := "products"
	if subscription {
		kind = "subscriptions"
	}
	_, err := g.call(ctx, http.MethodPost, g.base()+"/purchases/"+kind+"/"+url.PathEscape(productID)+"/tokens/"+url.PathEscape(token)+":acknowledge", []byte("{}"))
	return err
}

// RTDN is a Google Play real-time developer notification (the decoded Pub/Sub message data).
type RTDN struct {
	PackageName    string `json:"packageName"`
	OneTimeProduct *struct {
		NotificationType int    `json:"notificationType"`
		PurchaseToken    string `json:"purchaseToken"`
		SKU              string `json:"sku"`
	} `json:"oneTimeProductNotification"`
	Subscription *struct {
		NotificationType int    `json:"notificationType"`
		PurchaseToken    string `json:"purchaseToken"`
		SubscriptionID   string `json:"subscriptionId"`
	} `json:"subscriptionNotification"`
	Voided *struct {
		PurchaseToken string `json:"purchaseToken"`
		OrderID       string `json:"orderId"`
		ProductType   int    `json:"productType"` // 1 subscription, 2 one-time
		RefundType    int    `json:"refundType"`
	} `json:"voidedPurchaseNotification"`
	Test *struct{} `json:"testNotification"`
}

// ParseRTDN reads a Pub/Sub push envelope ({"message": {"data": base64}}) into the notification.
func ParseRTDN(body []byte) (RTDN, error) {
	var env struct {
		Message struct {
			Data string `json:"data"`
		} `json:"message"`
	}
	var n RTDN
	if json.Unmarshal(body, &env) != nil || env.Message.Data == "" {
		return n, errors.New("not a Pub/Sub push")
	}
	data, err := base64.StdEncoding.DecodeString(env.Message.Data)
	if err != nil {
		if data, err = base64.URLEncoding.DecodeString(env.Message.Data); err != nil {
			return n, errors.New("the message data is not base64")
		}
	}
	if json.Unmarshal(data, &n) != nil {
		return n, errors.New("the message data is not a notification")
	}
	return n, nil
}
