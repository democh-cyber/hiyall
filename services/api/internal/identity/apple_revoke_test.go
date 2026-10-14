package identity

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
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fakeApple is Apple's token and revoke endpoints.
type fakeApple struct {
	t         *testing.T
	key       *ecdsa.PrivateKey
	mu        sync.Mutex
	exchanged []string
	revoked   []string
	failRev   bool
	failCode  bool
}

func newFakeApple(t *testing.T) (*fakeApple, *AppleRevoker) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	file := filepath.Join(t.TempDir(), "AuthKey_ABC123.p8")
	if err = os.WriteFile(file, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	f := &fakeApple{t: t, key: key}
	server := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(server.Close)
	r, err := NewAppleRevoker(AppleConfig{TeamID: "TEAM123456", KeyID: "ABC123", ClientID: "app.hiyall.test", PrivateKeyFile: file})
	if err != nil {
		t.Fatal(err)
	}
	r.tokenURL, r.revokeURL = server.URL+"/auth/token", server.URL+"/auth/revoke"
	return f, r
}

// checkSecret verifies the ES256 client secret exactly as Apple would.
func (f *fakeApple) checkSecret(secret string) bool {
	parts := strings.Split(secret, ".")
	if len(parts) != 3 {
		return false
	}
	var header struct{ Alg, Kid string }
	var claims struct {
		Iss, Aud, Sub string
		Iat, Exp      int64
	}
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if json.Unmarshal(h, &header) != nil || json.Unmarshal(c, &claims) != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	ok := ecdsa.Verify(&f.key.PublicKey, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
	return ok && header.Alg == "ES256" && header.Kid == "ABC123" && claims.Iss == "TEAM123456" && claims.Aud == "https://appleid.apple.com" &&
		claims.Sub == "app.hiyall.test" && claims.Exp > claims.Iat && claims.Exp-claims.Iat <= 600
}

func (f *fakeApple) serve(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" || r.Form.Get("client_id") != "app.hiyall.test" || !f.checkSecret(r.Form.Get("client_secret")) {
		http.Error(w, `{"error":"invalid_client"}`, http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.URL.Path {
	case "/auth/token":
		if r.Form.Get("grant_type") != "authorization_code" || f.failCode {
			http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
			return
		}
		f.exchanged = append(f.exchanged, r.Form.Get("code"))
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "at", "refresh_token": "refresh-for-" + r.Form.Get("code"), "expires_in": 3600})
	case "/auth/revoke":
		if r.Form.Get("token_type_hint") != "refresh_token" || f.failRev {
			http.Error(w, `{"error":"server_error"}`, http.StatusInternalServerError)
			return
		}
		f.revoked = append(f.revoked, r.Form.Get("token"))
	default:
		http.NotFound(w, r)
	}
}

func TestAppleCodeIsExchangedAndRevokedWithASignedClientSecret(t *testing.T) {
	f, r := newFakeApple(t)
	queued, err := r.RevokeAuthorizationCode(context.Background(), "code-1")
	if err != nil || queued != nil {
		t.Fatal(queued, err)
	}
	if len(f.exchanged) != 1 || f.exchanged[0] != "code-1" || len(f.revoked) != 1 || f.revoked[0] != "refresh-for-code-1" {
		t.Fatalf("exchanged %v revoked %v", f.exchanged, f.revoked)
	}
}

func TestAppleRevokeFailureQueuesTheSealedTokenAndAnExchangeFailureIsAnError(t *testing.T) {
	f, r := newFakeApple(t)
	f.failRev = true
	queued, err := r.RevokeAuthorizationCode(context.Background(), "code-2")
	if err != nil || queued == nil {
		t.Fatal(queued, err)
	}
	if strings.Contains(string(queued), "refresh-for-code-2") {
		t.Fatal("the queued token is not sealed")
	}
	if token, err := r.Open(queued); err != nil || token != "refresh-for-code-2" {
		t.Fatal(token, err)
	}
	f.failRev, f.failCode = false, true
	if q, err := r.RevokeAuthorizationCode(context.Background(), "code-3"); err == nil || q != nil {
		t.Fatal("an exchange failure was swallowed", q, err)
	}
	if _, err := r.Open([]byte("short")); err == nil {
		t.Fatal("garbage opened")
	}
}

func TestAppleKeyFileIsValidated(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		_ = os.WriteFile(p, []byte(content), 0o600)
		return p
	}
	rsaLike := write("bad.p8", "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n")
	for name, c := range map[string]AppleConfig{
		"missing file": {TeamID: "t", KeyID: "k", ClientID: "c", PrivateKeyFile: filepath.Join(dir, "none")},
		"not pem":      {TeamID: "t", KeyID: "k", ClientID: "c", PrivateKeyFile: write("x", "hello")},
		"not a key":    {TeamID: "t", KeyID: "k", ClientID: "c", PrivateKeyFile: rsaLike},
	} {
		if _, err := NewAppleRevoker(c); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
}

type fakeQueue struct {
	sealed  []byte
	done    bool
	lookups int
}

func (q *fakeQueue) PendingAppleRevocation(context.Context, string, string) ([]byte, error) {
	q.lookups++
	if q.done {
		return nil, nil
	}
	return q.sealed, nil
}
func (q *fakeQueue) DoneAppleRevocation(context.Context, string, string) error {
	q.done = true
	return nil
}

type fakeInner struct{ calls int }

func (i *fakeInner) DeleteIdentity(context.Context, string, string) error { i.calls++; return nil }

func TestPurgeRetriesQueuedRevocationsBeforeDeletingTheIdentity(t *testing.T) {
	f, r := newFakeApple(t)
	queue, inner := &fakeQueue{sealed: r.Seal("queued-token")}, &fakeInner{}
	d := AppleDeleter{Inner: inner, Revoker: r, Queue: queue}
	f.failRev = true
	if err := d.DeleteIdentity(context.Background(), "iss", "sub"); err == nil || inner.calls != 0 {
		t.Fatalf("identity deleted while Apple still holds the token: %v calls=%d", err, inner.calls)
	}
	f.failRev = false
	if err := d.DeleteIdentity(context.Background(), "iss", "sub"); err != nil || inner.calls != 1 || !queue.done || len(f.revoked) != 1 || f.revoked[0] != "queued-token" {
		t.Fatalf("%v calls=%d done=%v revoked=%v", err, inner.calls, queue.done, f.revoked)
	}
	// Nothing queued: the inner deleter runs alone.
	if err := d.DeleteIdentity(context.Background(), "iss", "sub"); err != nil || inner.calls != 2 || len(f.revoked) != 1 {
		t.Fatal(err, inner.calls)
	}
}

func TestPurgeDropsATokenSealedUnderAnotherAppleKey(t *testing.T) {
	_, other := newFakeApple(t)
	_, r := newFakeApple(t)
	queue, inner := &fakeQueue{sealed: other.Seal("old")}, &fakeInner{}
	if err := (AppleDeleter{Inner: inner, Revoker: r, Queue: queue}).DeleteIdentity(context.Background(), "i", "s"); err != nil || inner.calls != 1 || !queue.done {
		t.Fatal(err, inner.calls, queue.done)
	}
}
