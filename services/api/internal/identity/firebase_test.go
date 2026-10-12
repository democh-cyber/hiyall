package identity

import (
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

const testProject = "hiyall-test"

type resolution struct {
	issuer, subject, sid string
	expiry               time.Time
}

type firebaseFixture struct {
	t        *testing.T
	key      *rsa.PrivateKey
	verifier *Verifier
	resolved []resolution
	fetches  atomic.Int32
}

// newFirebaseFixture serves a local JWKS and verifies tokens through the same
// remote key set code path production uses. Resolutions are recorded instead of
// touching a database.
func newFirebaseFixture(t *testing.T) *firebaseFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &firebaseFixture{t: t, key: key}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.fetches.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "test", "use": "sig", "alg": "RS256", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
	}))
	t.Cleanup(srv.Close)
	f.verifier = NewFirebaseWithKeys(testProject, oidc.NewRemoteKeySet(context.Background(), srv.URL), nil)
	f.verifier.resolve = func(_ context.Context, issuer, subject, sid string, expiry time.Time) (store.Principal, error) {
		f.resolved = append(f.resolved, resolution{issuer, subject, sid, expiry})
		return store.Principal{UserID: "user-for-" + subject, SessionID: sid}, nil
	}
	return f
}

// claims returns a valid Google sign-in token body; overrides replace claims and a nil value removes one.
func (f *firebaseFixture) claims(override map[string]any) map[string]any {
	now := time.Now()
	claims := map[string]any{
		"iss": FirebaseIssuer(testProject), "aud": testProject, "sub": "firebase-uid-1", "user_id": "firebase-uid-1",
		"iat": now.Add(-time.Minute).Unix(), "exp": now.Add(time.Hour).Unix(), "auth_time": now.Add(-2 * time.Minute).Unix(),
		"email": "member@example.test", "email_verified": true,
		"firebase": map[string]any{"sign_in_provider": "google.com", "identities": map[string]any{"google.com": []string{"1234"}}},
	}
	for k, v := range override {
		if v == nil {
			delete(claims, k)
		} else {
			claims[k] = v
		}
	}
	return claims
}

func (f *firebaseFixture) sign(header map[string]any, claims map[string]any) string {
	f.t.Helper()
	h, _ := json.Marshal(header)
	body, _ := json.Marshal(claims)
	raw := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(raw))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, digest[:])
	if err != nil {
		f.t.Fatal(err)
	}
	return raw + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func (f *firebaseFixture) token(override map[string]any) string {
	return f.sign(map[string]any{"alg": "RS256", "kid": "test", "typ": "JWT"}, f.claims(override))
}

func providerClaims(provider string, verified any) map[string]any {
	return map[string]any{"email_verified": verified, "firebase": map[string]any{"sign_in_provider": provider}}
}

func TestFirebaseTokensAreAcceptedByProvider(t *testing.T) {
	f := newFirebaseFixture(t)
	authTime := time.Now().Add(-time.Hour).Unix()
	for _, tc := range []struct {
		name     string
		override map[string]any
	}{
		{"google", providerClaims("google.com", true)},
		{"google with unverified email", providerClaims("google.com", false)},
		{"apple without any email claim", map[string]any{"email": nil, "email_verified": nil, "firebase": map[string]any{"sign_in_provider": "apple.com"}}},
		{"facebook", providerClaims("facebook.com", false)},
		{"phone", map[string]any{"email": nil, "email_verified": nil, "firebase": map[string]any{"sign_in_provider": "phone"}}},
		{"verified password", providerClaims("password", true)},
		{"subject at the length limit", map[string]any{"sub": strings.Repeat("s", 128)}},
		{"auth_time within the clock skew", map[string]any{"auth_time": time.Now().Add(4 * time.Minute).Unix()}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			override := map[string]any{"auth_time": authTime}
			for k, v := range tc.override {
				override[k] = v
			}
			token, sid, err := f.verifier.firebaseClaims(context.Background(), f.token(override))
			if err != nil {
				t.Fatalf("rejected: %v", err)
			}
			if want := "fb:" + token.Subject + ":"; !strings.HasPrefix(sid, want) {
				t.Fatalf("sid %q", sid)
			}
		})
	}
	_, sid, err := f.verifier.firebaseClaims(context.Background(), f.token(map[string]any{"auth_time": authTime}))
	if err != nil || sid != "fb:firebase-uid-1:"+itoa(authTime) {
		t.Fatalf("sid %q %v", sid, err)
	}
}

func itoa(n int64) string { return big.NewInt(n).String() }

func TestFirebaseTokensAreRejected(t *testing.T) {
	f := newFirebaseFixture(t)
	now := time.Now()
	cases := []struct {
		name     string
		override map[string]any
	}{
		{"anonymous", map[string]any{"email": nil, "email_verified": nil, "firebase": map[string]any{"sign_in_provider": "anonymous"}}},
		{"custom token", map[string]any{"firebase": map[string]any{"sign_in_provider": "custom"}}},
		{"wrong audience", map[string]any{"aud": "another-project"}},
		{"wrong issuer", map[string]any{"iss": FirebaseIssuer("another-project")}},
		{"issuer without the project", map[string]any{"iss": "https://securetoken.google.com/"}},
		{"expired", map[string]any{"exp": now.Add(-time.Minute).Unix()}},
		{"missing auth_time", map[string]any{"auth_time": nil}},
		{"auth_time as text", map[string]any{"auth_time": "1700000000"}},
		{"auth_time fractional", map[string]any{"auth_time": 1700000000.5}},
		{"auth_time zero", map[string]any{"auth_time": 0}},
		{"auth_time null", map[string]any{"auth_time": json.RawMessage("null")}},
		{"auth_time in the future", map[string]any{"auth_time": now.Add(10 * time.Minute).Unix()}},
		{"iat in the future", map[string]any{"iat": now.Add(10 * time.Minute).Unix()}},
		{"missing firebase claim", map[string]any{"firebase": nil}},
		{"firebase claim not an object", map[string]any{"firebase": "google.com"}},
		{"missing sign_in_provider", map[string]any{"firebase": map[string]any{"identities": map[string]any{}}}},
		{"empty sign_in_provider", map[string]any{"firebase": map[string]any{"sign_in_provider": ""}}},
		{"empty subject", map[string]any{"sub": ""}},
		{"missing subject", map[string]any{"sub": nil}},
		{"subject over the limit", map[string]any{"sub": strings.Repeat("s", 129)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := f.verifier.firebaseClaims(context.Background(), f.token(tc.override))
			if !errors.Is(err, domain.ErrUnauthorized) {
				t.Fatalf("got %v, want ErrUnauthorized", err)
			}
		})
	}
	t.Run("forged signature", func(t *testing.T) {
		raw := f.token(nil)
		if _, _, err := f.verifier.firebaseClaims(context.Background(), raw[:len(raw)-12]+"AAAAAAAAAAAA"); !errors.Is(err, domain.ErrUnauthorized) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("unsigned token", func(t *testing.T) {
		h, _ := json.Marshal(map[string]any{"alg": "none", "typ": "JWT"})
		body, _ := json.Marshal(f.claims(nil))
		raw := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(body) + "."
		if _, _, err := f.verifier.firebaseClaims(context.Background(), raw); !errors.Is(err, domain.ErrUnauthorized) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("symmetric algorithm", func(t *testing.T) {
		h, _ := json.Marshal(map[string]any{"alg": "HS256", "kid": "test", "typ": "JWT"})
		body, _ := json.Marshal(f.claims(nil))
		raw := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(body)
		mac := hmac.New(sha256.New, f.key.N.Bytes())
		mac.Write([]byte(raw))
		raw += "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
		if _, _, err := f.verifier.firebaseClaims(context.Background(), raw); !errors.Is(err, domain.ErrUnauthorized) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("unknown signing key", func(t *testing.T) {
		raw := f.sign(map[string]any{"alg": "RS256", "kid": "rotated-away", "typ": "JWT"}, f.claims(nil))
		if _, _, err := f.verifier.firebaseClaims(context.Background(), raw); !errors.Is(err, domain.ErrUnauthorized) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("not a token", func(t *testing.T) {
		for _, raw := range []string{"", "abc", "a.b.c", "Bearer x"} {
			if _, _, err := f.verifier.firebaseClaims(context.Background(), raw); !errors.Is(err, domain.ErrUnauthorized) {
				t.Fatalf("%q: got %v", raw, err)
			}
		}
	})
}

func TestUnverifiedPasswordEmailIsRefusedBeforeAnyAccountExists(t *testing.T) {
	f := newFirebaseFixture(t)
	for name, override := range map[string]map[string]any{
		"false":   providerClaims("password", false),
		"absent":  {"email_verified": nil, "firebase": map[string]any{"sign_in_provider": "password"}},
		"no mail": {"email": nil, "email_verified": nil, "firebase": map[string]any{"sign_in_provider": "password"}},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := f.verifier.Verify(context.Background(), f.token(override))
			if !errors.Is(err, domain.ErrEmailNotVerified) || errors.Is(err, domain.ErrUnauthorized) {
				t.Fatalf("got %v, want ErrEmailNotVerified", err)
			}
			var policy *domain.PolicyError
			if !errors.As(err, &policy) || policy.Status != 403 || policy.Code != "EMAIL_NOT_VERIFIED" || policy.Message != "Verify your email to continue." {
				t.Fatalf("policy %+v", policy)
			}
		})
	}
	if len(f.resolved) != 0 {
		t.Fatalf("an account was resolved for an unverified email: %+v", f.resolved)
	}
	// A bad token is still just unauthenticated: the email rule never reveals anything for it.
	if _, err := f.verifier.Verify(context.Background(), f.token(map[string]any{"aud": "x", "email_verified": false, "firebase": map[string]any{"sign_in_provider": "password"}})); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("got %v", err)
	}
	// Anonymous wins over the email rule too.
	if _, err := f.verifier.Verify(context.Background(), f.token(providerClaims("anonymous", false))); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("got %v", err)
	}
	if _, err := f.verifier.Verify(context.Background(), f.token(providerClaims("password", true))); err != nil {
		t.Fatal(err)
	}
	if len(f.resolved) != 1 {
		t.Fatalf("resolved %d accounts, want 1", len(f.resolved))
	}
}

func TestFirebaseVerifyResolvesTheSignInSession(t *testing.T) {
	f := newFirebaseFixture(t)
	authTime := time.Now().Add(-30 * time.Minute).Unix()
	exp := time.Now().Add(55 * time.Minute).Unix()
	p, err := f.verifier.Verify(context.Background(), f.token(map[string]any{"auth_time": authTime, "exp": exp}))
	if err != nil {
		t.Fatal(err)
	}
	if len(f.resolved) != 1 {
		t.Fatalf("resolved %d", len(f.resolved))
	}
	got := f.resolved[0]
	if got.issuer != "https://securetoken.google.com/"+testProject || got.subject != "firebase-uid-1" || got.sid != "fb:firebase-uid-1:"+itoa(authTime) || got.expiry.Unix() != exp {
		t.Fatalf("resolution %+v", got)
	}
	if p.UserID != "user-for-firebase-uid-1" {
		t.Fatalf("principal %+v", p)
	}
}

func TestFirebaseSessionIdFollowsTheSignIn(t *testing.T) {
	f := newFirebaseFixture(t)
	authTime := time.Now().Add(-time.Hour).Unix()
	first := f.token(map[string]any{"auth_time": authTime, "iat": time.Now().Add(-50 * time.Minute).Unix(), "exp": time.Now().Add(10 * time.Minute).Unix()})
	refreshed := f.token(map[string]any{"auth_time": authTime, "iat": time.Now().Add(-time.Minute).Unix(), "exp": time.Now().Add(59 * time.Minute).Unix()})
	signedInAgain := f.token(map[string]any{"auth_time": authTime + 1800})
	otherPerson := f.token(map[string]any{"auth_time": authTime, "sub": "firebase-uid-2"})
	sids := map[string]string{}
	for name, raw := range map[string]string{"first": first, "refreshed": refreshed, "again": signedInAgain, "other": otherPerson} {
		_, sid, err := f.verifier.firebaseClaims(context.Background(), raw)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		sids[name] = sid
	}
	if sids["first"] != sids["refreshed"] {
		t.Fatalf("a token refresh changed the session: %q vs %q", sids["first"], sids["refreshed"])
	}
	if sids["again"] == sids["first"] {
		t.Fatal("a new interactive sign-in reused the session")
	}
	if sids["other"] == sids["first"] {
		t.Fatal("two people share a session")
	}
}

func TestFirebaseKeyOutageIsNotASignOut(t *testing.T) {
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "unavailable", http.StatusBadGateway) }))
	defer down.Close()
	f := newFirebaseFixture(t)
	f.verifier = NewFirebaseWithKeys(testProject, oidc.NewRemoteKeySet(context.Background(), down.URL), nil)
	f.verifier.resolve = func(context.Context, string, string, string, time.Time) (store.Principal, error) {
		t.Fatal("resolved without verifying the signature")
		return store.Principal{}, nil
	}
	_, err := f.verifier.Verify(context.Background(), f.token(nil))
	if !errors.Is(err, ErrKeysUnavailable) || errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("got %v, want ErrKeysUnavailable so clients are not signed out", err)
	}
	// A token that is malformed never reaches the key host, so it stays a plain rejection.
	if _, err = f.verifier.Verify(context.Background(), "not-a-token"); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("got %v", err)
	}
}

func TestFirebaseKeysAreCached(t *testing.T) {
	f := newFirebaseFixture(t)
	for i := 0; i < 5; i++ {
		if _, _, err := f.verifier.firebaseClaims(context.Background(), f.token(nil)); err != nil {
			t.Fatal(err)
		}
	}
	if n := f.fetches.Load(); n != 1 {
		t.Fatalf("fetched the key set %d times for 5 tokens", n)
	}
}
