package billing

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	appleProduction = "https://api.storekit.itunes.apple.com"
	appleSandbox    = "https://api.storekit-sandbox.itunes.apple.com"
)

// Apple's marker extensions: every certificate Apple signs a StoreKit JWS with carries one (App Store Server library docs, "Verifying
// a signed transaction"): the leaf the receipt-signing one, the intermediate the WWDR one. A chain that ends in Apple's root but lacks them
// is some other Apple certificate (a developer's own, for instance) and is refused.
var (
	oidAppleLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidAppleIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// LoadApplePrivateKey reads the App Store Connect .p8 key (PKCS#8 EC P-256, PEM).
func LoadApplePrivateKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read the App Store Server API key file")
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("the App Store Server API key file is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("the App Store Server API key is not PKCS#8")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("the App Store Server API key is not an EC P-256 key")
	}
	return key, nil
}

// LoadAppleRoots reads the trust anchors transactions must chain to: a PEM file with one or more certificates (Apple Root CA - G3,
// from https://www.apple.com/certificateauthority/), or a single DER certificate (the .cer file as downloaded).
func LoadAppleRoots(path string) (*x509.CertPool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read the Apple root certificate file")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(raw) {
		cert, err := x509.ParseCertificate(raw)
		if err != nil {
			return nil, errors.New("the Apple root certificate file holds no certificate")
		}
		pool.AddCert(cert)
	}
	return pool, nil
}

// Apple verifies purchases with the App Store Server API and the signed data it returns. The client's claim is only a transaction id: what
// the purchase is comes from Apple's response, whose JWS must verify against Apple's root.
type Apple struct {
	BundleID, IssuerID, KeyID string
	Key                       *ecdsa.PrivateKey
	Roots                     *x509.CertPool
	// ProductionURL and SandboxURL default to Apple's hosts; tests point them at httptest servers.
	ProductionURL, SandboxURL string
	AllowSandbox              bool
	HTTP                      *http.Client
	Now                       func() time.Time
}

// NewApple builds a client from the configuration files.
func NewApple(bundleID, issuerID, keyID, keyFile, rootFile string, allowSandbox bool) (*Apple, error) {
	key, err := LoadApplePrivateKey(keyFile)
	if err != nil {
		return nil, err
	}
	roots, err := LoadAppleRoots(rootFile)
	if err != nil {
		return nil, err
	}
	return &Apple{BundleID: bundleID, IssuerID: issuerID, KeyID: keyID, Key: key, Roots: roots, AllowSandbox: allowSandbox,
		HTTP: &http.Client{Timeout: 10 * time.Second}, Now: time.Now}, nil
}

func (a *Apple) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *Apple) bearer() (string, error) {
	now := a.now()
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.KeyID, "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{"iss": a.IssuerID, "iat": now.Unix(), "exp": now.Add(10 * time.Minute).Unix(), "aud": "appstoreconnect-v1", "bid": a.BundleID})
	signing := b64(header) + "." + b64(claims)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.Key, sum[:])
	if err != nil {
		return "", ErrMisconfigured
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + b64(sig), nil
}

// get asks one host; status 404 is reported as notFound so the caller can try the sandbox.
func (a *Apple) get(ctx context.Context, base, path string) (body []byte, notFound bool, err error) {
	token, err := a.bearer()
	if err != nil {
		return nil, false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
	if err != nil {
		return nil, false, ErrMisconfigured
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := a.HTTP.Do(req)
	if err != nil {
		return nil, false, ErrUnavailable
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<18))
	switch {
	case resp.StatusCode == http.StatusOK:
		return raw, false, nil
	case resp.StatusCode == http.StatusNotFound:
		return nil, true, nil
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return nil, false, ErrMisconfigured
	case resp.StatusCode == http.StatusBadRequest:
		return nil, false, ErrInvalid
	}
	return nil, false, ErrUnavailable
}

// TransactionInfo is the decoded signedTransactionInfo.
type TransactionInfo struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	ExpiresDate           int64  `json:"expiresDate"`
	RevocationDate        int64  `json:"revocationDate"`
	AppAccountToken       string `json:"appAccountToken"`
	Environment           string `json:"environment"`
	Type                  string `json:"type"`
}

// RenewalInfo is the decoded signedRenewalInfo.
type RenewalInfo struct {
	AutoRenewStatus        int   `json:"autoRenewStatus"`
	GracePeriodExpiresDate int64 `json:"gracePeriodExpiresDate"`
	IsInBillingRetryPeriod bool  `json:"isInBillingRetryPeriod"`
}

func ms(v int64) time.Time { return time.UnixMilli(v).UTC() }

// Transaction verifies a purchase by id. It tries the production API and, when Apple does not know the id there, the sandbox (a
// TestFlight or App Review purchase), refusing the sandbox unless AllowSandbox. productID is the store product id the caller expects.
func (a *Apple) Transaction(ctx context.Context, transactionID, productID string) (Verified, error) {
	if transactionID == "" || len(transactionID) > 64 || strings.ContainsAny(transactionID, "/?#% ") {
		return Verified{}, ErrInvalid
	}
	hosts := []string{orDefault(a.ProductionURL, appleProduction), orDefault(a.SandboxURL, appleSandbox)}
	for i, base := range hosts {
		raw, notFound, err := a.get(ctx, base, "/inApps/v1/transactions/"+url.PathEscape(transactionID))
		if err != nil {
			return Verified{}, err
		}
		if notFound {
			continue
		}
		var out struct {
			SignedTransactionInfo string `json:"signedTransactionInfo"`
		}
		if json.Unmarshal(raw, &out) != nil {
			return Verified{}, ErrInvalid
		}
		var tx TransactionInfo
		if err = a.VerifyJWS(out.SignedTransactionInfo, &tx); err != nil {
			return Verified{}, ErrInvalid
		}
		sandbox := tx.Environment == "Sandbox" || tx.Environment == "Xcode" || i == 1
		v, err := a.fromTransaction(tx, transactionID, productID, sandbox)
		if err != nil {
			return Verified{}, err
		}
		if v.Subscription != nil && !v.Revoked {
			if err = a.subscriptionStatus(ctx, base, &tx, &v); err != nil {
				return Verified{}, err
			}
		}
		return v, nil
	}
	return Verified{}, ErrInvalid
}

func orDefault(v, d string) string {
	if v != "" {
		return v
	}
	return d
}

func (a *Apple) fromTransaction(tx TransactionInfo, wantID, wantProduct string, sandbox bool) (Verified, error) {
	if tx.BundleID != a.BundleID || (wantID != "" && tx.TransactionID != wantID) || (wantProduct != "" && tx.ProductID != wantProduct) {
		return Verified{}, ErrInvalid
	}
	if sandbox && !a.AllowSandbox {
		return Verified{}, ErrInvalid
	}
	v := Verified{Store: StoreApple, StoreProductID: tx.ProductID, TxKey: tx.TransactionID, State: StateVerified, Test: sandbox,
		AccountID: strings.ToLower(tx.AppAccountToken), Revoked: tx.RevocationDate != 0}
	if tx.Type == "Auto-Renewable Subscription" {
		end := ms(tx.ExpiresDate)
		status := SubActive
		if !end.After(a.now()) {
			status = SubExpired
		}
		if v.Revoked {
			status = SubRevoked
		}
		v.Subscription = &SubState{Status: status, PeriodEnd: end, OriginalKey: tx.OriginalTransactionID}
	}
	return v, nil
}

// subscriptionStatus refines a subscription with Apple's status endpoint (grace period, billing retry, auto-renew).
func (a *Apple) subscriptionStatus(ctx context.Context, base string, tx *TransactionInfo, v *Verified) error {
	raw, notFound, err := a.get(ctx, base, "/inApps/v1/subscriptions/"+url.PathEscape(tx.TransactionID))
	if err != nil {
		return err
	}
	if notFound {
		return nil // keep what the transaction says
	}
	var out struct {
		Data []struct {
			LastTransactions []struct {
				OriginalTransactionID string `json:"originalTransactionId"`
				Status                int    `json:"status"`
				SignedTransactionInfo string `json:"signedTransactionInfo"`
				SignedRenewalInfo     string `json:"signedRenewalInfo"`
			} `json:"lastTransactions"`
		} `json:"data"`
	}
	if json.Unmarshal(raw, &out) != nil {
		return ErrInvalid
	}
	for _, group := range out.Data {
		for _, last := range group.LastTransactions {
			if last.OriginalTransactionID != tx.OriginalTransactionID {
				continue
			}
			var latest TransactionInfo
			var renewal RenewalInfo
			if a.VerifyJWS(last.SignedTransactionInfo, &latest) != nil || latest.BundleID != a.BundleID {
				return ErrInvalid
			}
			if last.SignedRenewalInfo != "" && a.VerifyJWS(last.SignedRenewalInfo, &renewal) != nil {
				return ErrInvalid
			}
			v.Subscription = a.subscriptionFrom(latest, renewal, last.Status)
			return nil
		}
	}
	return nil
}

// subscriptionFrom maps Apple's status (1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked) and renewal info.
func (a *Apple) subscriptionFrom(tx TransactionInfo, renewal RenewalInfo, status int) *SubState {
	s := &SubState{PeriodEnd: ms(tx.ExpiresDate), AutoRenew: renewal.AutoRenewStatus == 1, OriginalKey: tx.OriginalTransactionID}
	switch status {
	case 1:
		s.Status = SubActive
	case 3:
		s.Status = SubOnHold
	case 4:
		s.Status = SubGrace
		until := ms(renewal.GracePeriodExpiresDate)
		if renewal.GracePeriodExpiresDate == 0 {
			until = s.PeriodEnd.Add(16 * 24 * time.Hour) // Apple's longest grace period
		}
		s.GraceUntil = &until
	case 5:
		s.Status = SubRevoked
	default:
		s.Status = SubExpired
	}
	if tx.RevocationDate != 0 {
		s.Status = SubRevoked
	}
	return s
}

// VerifyJWS checks an Apple signed JWS (ES256) and decodes its payload into out. The header's x5c chain (leaf, intermediate, root) must
// verify to a configured root, with Apple's marker extensions on the leaf and the intermediate, and the signature must verify with the
// leaf's key.
func (a *Apple) VerifyJWS(token string, out any) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errors.New("not a JWS")
	}
	var header struct {
		Alg string   `json:"alg"`
		X5C []string `json:"x5c"`
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || json.Unmarshal(raw, &header) != nil || header.Alg != "ES256" || len(header.X5C) < 2 || len(header.X5C) > 4 {
		return errors.New("unsupported JWS header")
	}
	certs := make([]*x509.Certificate, len(header.X5C))
	for i, c := range header.X5C {
		der, err := base64.StdEncoding.DecodeString(c)
		if err != nil {
			return errors.New("bad certificate")
		}
		if certs[i], err = x509.ParseCertificate(der); err != nil {
			return errors.New("bad certificate")
		}
	}
	if !hasExtension(certs[0], oidAppleLeaf) || !hasExtension(certs[1], oidAppleIntermediate) {
		return errors.New("not an Apple signing chain")
	}
	// The marker extensions are critical in Apple's certificates and unknown to Go: they were checked above.
	for _, c := range certs {
		c.UnhandledCriticalExtensions = nil
	}
	inter := x509.NewCertPool()
	for _, c := range certs[1:] {
		inter.AddCert(c)
	}
	if _, err = certs[0].Verify(x509.VerifyOptions{Roots: a.Roots, Intermediates: inter, CurrentTime: a.now(), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return errors.New("the signing chain does not reach Apple's root")
	}
	pub, ok := certs[0].PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return errors.New("the signing key is not P-256")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return errors.New("bad signature")
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(pub, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return errors.New("the signature does not verify")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(payload, out) != nil {
		return errors.New("bad payload")
	}
	return nil
}

func hasExtension(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}

// Notification is an App Store Server Notification V2, verified and decoded.
type Notification struct {
	Type, Subtype string
	Environment   string
	BundleID      string
	Status        int
	Transaction   *TransactionInfo
	Renewal       *RenewalInfo
}

// ParseNotification verifies the signedPayload of a notification and decodes it with its nested signed transaction and renewal info.
func (a *Apple) ParseNotification(body []byte) (Notification, error) {
	var env struct {
		SignedPayload string `json:"signedPayload"`
	}
	var n Notification
	if json.Unmarshal(body, &env) != nil || env.SignedPayload == "" {
		return n, errors.New("no signedPayload")
	}
	var p struct {
		NotificationType string `json:"notificationType"`
		Subtype          string `json:"subtype"`
		Data             struct {
			Environment           string `json:"environment"`
			BundleID              string `json:"bundleId"`
			Status                int    `json:"status"`
			SignedTransactionInfo string `json:"signedTransactionInfo"`
			SignedRenewalInfo     string `json:"signedRenewalInfo"`
		} `json:"data"`
	}
	if err := a.VerifyJWS(env.SignedPayload, &p); err != nil {
		return n, err
	}
	n = Notification{Type: p.NotificationType, Subtype: p.Subtype, Environment: p.Data.Environment, BundleID: p.Data.BundleID, Status: p.Data.Status}
	if n.BundleID != a.BundleID {
		return n, errors.New("the notification is for another app")
	}
	if p.Data.SignedTransactionInfo != "" {
		var tx TransactionInfo
		if err := a.VerifyJWS(p.Data.SignedTransactionInfo, &tx); err != nil {
			return n, err
		}
		if tx.BundleID != a.BundleID {
			return n, errors.New("the transaction is for another app")
		}
		n.Transaction = &tx
	}
	if p.Data.SignedRenewalInfo != "" {
		var r RenewalInfo
		if err := a.VerifyJWS(p.Data.SignedRenewalInfo, &r); err != nil {
			return n, err
		}
		n.Renewal = &r
	}
	return n, nil
}

// SubscriptionFromNotification is the subscription state a notification implies.
func (a *Apple) SubscriptionFromNotification(n Notification) *SubState {
	if n.Transaction == nil {
		return nil
	}
	var renewal RenewalInfo
	if n.Renewal != nil {
		renewal = *n.Renewal
	}
	status := n.Status
	if status == 0 {
		status = 1
		if !ms(n.Transaction.ExpiresDate).After(a.now()) {
			status = 2
		}
		switch n.Type {
		case "DID_FAIL_TO_RENEW":
			status = 3
			if n.Subtype == "GRACE_PERIOD" {
				status = 4
			}
		case "EXPIRED", "GRACE_PERIOD_EXPIRED":
			status = 2
		case "REFUND", "REVOKE":
			status = 5
		}
	}
	return a.subscriptionFrom(*n.Transaction, renewal, status)
}
