// Package billingtest is test support: fake Google Play, App Store and AdMob servers and the keys that make
// their answers verifiable. It is imported only by _test.go files and holds no credential of any kind (every key is generated per test).
package billingtest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// ---- Google Play

// Google is a fake token endpoint plus Google Play Developer API. Set Products and Subs to what the API should answer for a purchase token;
// an unknown token is a 404, like Google.
type Google struct {
	*httptest.Server
	mu          sync.Mutex
	Products    map[string]string // token -> purchases.products.get JSON
	Subs        map[string]string // token -> purchases.subscriptionsv2.get JSON
	Down        bool              // answer 503
	Acks        []string          // acknowledged tokens
	KeyFile     string            // the service-account file
	TokenCalls  int
	LastProduct string
}

// NewGoogle starts the fake and writes a service-account key file that points at it.
func NewGoogle(t *testing.T) *Google {
	t.Helper()
	g := &Google{Products: map[string]string{}, Subs: map[string]string{}}
	g.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		defer g.mu.Unlock()
		path := r.URL.Path
		switch {
		case path == "/token":
			g.TokenCalls++
			_, _ = w.Write([]byte(`{"access_token":"fake-access","expires_in":3600}`))
		case g.Down:
			w.WriteHeader(503)
		case strings.HasSuffix(path, ":acknowledge"):
			parts := strings.Split(strings.TrimSuffix(path, ":acknowledge"), "/tokens/")
			g.Acks = append(g.Acks, parts[len(parts)-1])
			_, _ = w.Write([]byte(`{}`))
		case strings.Contains(path, "/purchases/products/"):
			token := path[strings.LastIndex(path, "/tokens/")+len("/tokens/"):]
			g.LastProduct = path
			if body, ok := g.Products[token]; ok {
				_, _ = w.Write([]byte(body))
				return
			}
			w.WriteHeader(404)
		case strings.Contains(path, "/purchases/subscriptionsv2/tokens/"):
			token := path[strings.LastIndex(path, "/tokens/")+len("/tokens/"):]
			if body, ok := g.Subs[token]; ok {
				_, _ = w.Write([]byte(body))
				return
			}
			w.WriteHeader(404)
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(g.Close)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	acc, _ := json.Marshal(map[string]string{"type": "service_account", "client_email": "billing@example.iam.gserviceaccount.com", "private_key_id": "kid",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "token_uri": g.URL + "/token"})
	g.KeyFile = filepath.Join(t.TempDir(), "sa.json")
	if err = os.WriteFile(g.KeyFile, acc, 0o600); err != nil {
		t.Fatal(err)
	}
	return g
}

// Product is a purchases.products.get answer: state 0 purchased, 1 canceled, 2 pending.
func Product(state int, account string) string {
	b, _ := json.Marshal(map[string]any{"purchaseState": state, "acknowledgementState": 0, "obfuscatedExternalAccountId": account})
	return string(b)
}

// Subscription is a purchases.subscriptionsv2.get answer.
func Subscription(state, productID string, expiry time.Time, account string) string {
	b, _ := json.Marshal(map[string]any{"subscriptionState": state, "acknowledgementState": "ACKNOWLEDGEMENT_STATE_PENDING",
		"lineItems":                  []any{map[string]any{"productId": productID, "expiryTime": expiry.UTC().Format(time.RFC3339), "autoRenewingPlan": map[string]any{"autoRenewEnabled": true}}},
		"externalAccountIdentifiers": map[string]string{"obfuscatedExternalAccountId": account}})
	return string(b)
}

// RTDN is a Pub/Sub push body carrying a real-time developer notification.
func RTDN(notification map[string]any) []byte {
	data, _ := json.Marshal(notification)
	b, _ := json.Marshal(map[string]any{"message": map[string]string{"data": base64.StdEncoding.EncodeToString(data), "messageId": "1"}, "subscription": "projects/p/subscriptions/s"})
	return b
}

// ---- Apple

var (
	oidLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Apple is a fake PKI (root, intermediate, leaf with Apple's marker extensions) and a fake App Store Server API.
type Apple struct {
	*httptest.Server
	mu       sync.Mutex
	root     *x509.Certificate
	inter    *x509.Certificate
	leaf     *x509.Certificate
	leafKey  *ecdsa.PrivateKey
	RootFile string // PEM of the root: the APPLE_IAP_ROOT_CERT_FILE
	KeyFile  string // a .p8 key
	Tx       map[string]map[string]any
	Sub      map[string]any
	Down     bool
}

// NewApple starts the fake and writes the root and the .p8 key files.
func NewApple(t *testing.T) *Apple {
	t.Helper()
	a := &Apple{Tx: map[string]map[string]any{}}
	gen := func() *ecdsa.PrivateKey {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return k
	}
	serial := int64(10)
	mk := func(name string, ca bool, key *ecdsa.PrivateKey, parent *x509.Certificate, parentKey *ecdsa.PrivateKey, ext ...pkix.Extension) *x509.Certificate {
		serial++
		tpl := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: name}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(48 * time.Hour),
			IsCA: ca, BasicConstraintsValid: true, ExtraExtensions: ext}
		tpl.KeyUsage = x509.KeyUsageDigitalSignature
		if ca {
			tpl.KeyUsage = x509.KeyUsageCertSign
		}
		signer, signerKey := tpl, key
		if parent != nil {
			signer, signerKey = parent, parentKey
		}
		der, err := x509.CreateCertificate(rand.Reader, tpl, signer, &key.PublicKey, signerKey)
		if err != nil {
			t.Fatal(err)
		}
		c, _ := x509.ParseCertificate(der)
		return c
	}
	rootKey, interKey := gen(), gen()
	a.leafKey = gen()
	a.root = mk("Fake Apple Root", true, rootKey, nil, nil)
	a.inter = mk("Fake Apple WWDR", true, interKey, a.root, rootKey, pkix.Extension{Id: oidIntermediate, Value: []byte{5, 0}})
	a.leaf = mk("Fake Apple Leaf", false, a.leafKey, a.inter, interKey, pkix.Extension{Id: oidLeaf, Value: []byte{5, 0}})
	dir := t.TempDir()
	a.RootFile = filepath.Join(dir, "root.pem")
	if err := os.WriteFile(a.RootFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: a.root.Raw}), 0o600); err != nil {
		t.Fatal(err)
	}
	apiKey := gen()
	der, _ := x509.MarshalPKCS8PrivateKey(apiKey)
	a.KeyFile = filepath.Join(dir, "key.p8")
	if err := os.WriteFile(a.KeyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	a.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		if strings.Count(r.Header.Get("Authorization"), ".") != 2 {
			w.WriteHeader(401)
			return
		}
		if a.Down {
			w.WriteHeader(503)
			return
		}
		switch {
		case strings.HasPrefix(r.URL.Path, "/inApps/v1/transactions/"):
			tx, ok := a.Tx[strings.TrimPrefix(r.URL.Path, "/inApps/v1/transactions/")]
			if !ok {
				w.WriteHeader(404)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"signedTransactionInfo": a.Sign(t, tx)})
		case strings.HasPrefix(r.URL.Path, "/inApps/v1/subscriptions/") && a.Sub != nil:
			_ = json.NewEncoder(w).Encode(a.Sub)
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(a.Close)
	return a
}

// Sign makes an Apple-style ES256 JWS with the fake chain.
func (a *Apple) Sign(t *testing.T, payload any) string {
	t.Helper()
	header, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": []string{base64.StdEncoding.EncodeToString(a.leaf.Raw), base64.StdEncoding.EncodeToString(a.inter.Raw), base64.StdEncoding.EncodeToString(a.root.Raw)}})
	body, _ := json.Marshal(payload)
	signing := b64(header) + "." + b64(body)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.leafKey, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + b64(sig)
}

// Transaction is a signedTransactionInfo payload.
func Transaction(bundle, id, original, product, kind, account string, expires time.Time) map[string]any {
	tx := map[string]any{"transactionId": id, "originalTransactionId": original, "bundleId": bundle, "productId": product, "environment": "Production", "type": kind, "appAccountToken": account}
	if !expires.IsZero() {
		tx["expiresDate"] = expires.UnixMilli()
	}
	return tx
}

// Notification is an App Store Server Notification V2 body.
func (a *Apple) Notification(t *testing.T, kind, subtype, bundle string, tx map[string]any, status int) []byte {
	t.Helper()
	data := map[string]any{"environment": "Production", "bundleId": bundle, "status": status, "signedTransactionInfo": a.Sign(t, tx), "signedRenewalInfo": a.Sign(t, map[string]any{"autoRenewStatus": 1})}
	b, _ := json.Marshal(map[string]string{"signedPayload": a.Sign(t, map[string]any{"notificationType": kind, "subtype": subtype, "data": data})})
	return b
}

// ---- AdMob

// AdMob serves Google's verifier keys and signs callback queries with the matching private key.
type AdMob struct {
	*httptest.Server
	key *ecdsa.PrivateKey
}

// KeyID is the id of the fake key.
const KeyID = "3335741209"

// NewAdMob starts the fake key server.
func NewAdMob(t *testing.T) *AdMob {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	m := &AdMob{key: key}
	m.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{"keyId": 3335741209, "pem": pemKey, "base64": ""}}})
	}))
	t.Cleanup(m.Close)
	return m
}

// Query is a signed callback query string: signature and key_id come last, like AdMob's.
func (m *AdMob) Query(t *testing.T, adUnit, txID, userID, custom string, at time.Time) string {
	t.Helper()
	signed := "ad_network=5450213213286189855&ad_unit=" + adUnit + "&reward_amount=1&reward_item=coin&timestamp=" + itoa(at.UnixMilli()) + "&transaction_id=" + txID + "&user_id=" + userID + "&custom_data=" + custom
	sum := sha256.Sum256([]byte(signed))
	sig, err := ecdsa.SignASN1(rand.Reader, m.key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return signed + "&signature=" + b64(sig) + "&key_id=" + KeyID
}

func itoa(n int64) string { return big.NewInt(n).String() }
