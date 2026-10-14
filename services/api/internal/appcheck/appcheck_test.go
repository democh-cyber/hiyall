package appcheck

import (
	"context"
	"crypto"
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
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

const project = "123456789012"

type fixture struct {
	t   *testing.T
	key *rsa.PrivateKey
	srv *httptest.Server
	v   *Verifier
}

// newFixture serves a local JWKS and verifies through the same remote key set path production uses.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, key: key}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "test", "use": "sig", "alg": "RS256", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
	}))
	t.Cleanup(f.srv.Close)
	f.v = NewWithKeys(project, oidc.NewRemoteKeySet(context.Background(), f.srv.URL))
	return f
}

// Token signs a token the way Firebase App Check does; overrides replace claims and nil removes one.
func (f *fixture) Token(override map[string]any) string {
	return f.Sign(map[string]any{"alg": "RS256", "kid": "test", "typ": "JWT"}, override)
}

func (f *fixture) Sign(header, override map[string]any) string {
	f.t.Helper()
	now := time.Now()
	claims := map[string]any{
		"iss": issuerPrefix + project, "aud": []string{"projects/" + project, "projects/hiyall-prod-1"},
		"sub": "1:123456789012:android:abcdef", "iat": now.Add(-time.Minute).Unix(), "exp": now.Add(time.Hour).Unix(),
	}
	for k, v := range override {
		if v == nil {
			delete(claims, k)
		} else {
			claims[k] = v
		}
	}
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

func TestVerifyAcceptsAValidToken(t *testing.T) {
	f := newFixture(t)
	if err := f.v.Verify(context.Background(), f.Token(nil)); err != nil {
		t.Fatalf("valid token: %v", err)
	}
	// A string audience is fine too.
	if err := f.v.Verify(context.Background(), f.Token(map[string]any{"aud": "projects/" + project})); err != nil {
		t.Fatalf("string audience: %v", err)
	}
}

func TestVerifyRefusesWhatIsNotAnAppCheckTokenForThisProject(t *testing.T) {
	f := newFixture(t)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	foreign := &fixture{t: t, key: other}
	for name, token := range map[string]string{
		"empty":                "",
		"garbage":              "not.a.jwt",
		"too long":             strings.Repeat("a", maxTokenLength+1),
		"wrong issuer":         f.Token(map[string]any{"iss": issuerPrefix + "999999999999"}),
		"firebase auth issuer": f.Token(map[string]any{"iss": "https://securetoken.google.com/hiyall-prod-1"}),
		"wrong audience":       f.Token(map[string]any{"aud": []string{"projects/999999999999"}}),
		"project id only":      f.Token(map[string]any{"aud": []string{"projects/hiyall-prod-1"}}),
		"expired":              f.Token(map[string]any{"exp": time.Now().Add(-time.Minute).Unix()}),
		"no subject":           f.Token(map[string]any{"sub": nil}),
		"empty subject":        f.Token(map[string]any{"sub": ""}),
		"another signer":       foreign.Token(nil),
		"alg none":             f.Sign(map[string]any{"alg": "none", "typ": "JWT"}, nil),
		"HS256":                f.Sign(map[string]any{"alg": "HS256", "kid": "test", "typ": "JWT"}, nil),
	} {
		if err := f.v.Verify(context.Background(), token); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: %v, want ErrInvalid", name, err)
		}
	}
	// Tampering with the body breaks the signature.
	parts := strings.Split(f.Token(nil), ".")
	forged := parts[0] + "." + base64.RawURLEncoding.EncodeToString([]byte(`{"iss":"`+issuerPrefix+project+`","aud":["projects/`+project+`"],"sub":"x","exp":4102444800}`)) + "." + parts[2]
	if err := f.v.Verify(context.Background(), forged); !errors.Is(err, ErrInvalid) {
		t.Errorf("forged body: %v", err)
	}
}

func TestUnreachableKeysAreNotAnInvalidToken(t *testing.T) {
	f := newFixture(t)
	token := f.Token(nil)
	f.srv.Close()
	v := NewWithKeys(project, oidc.NewRemoteKeySet(context.Background(), f.srv.URL))
	if err := v.Verify(context.Background(), token); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("keys down: %v, want ErrUnavailable", err)
	}
}

func TestParseModeAndProjectNumber(t *testing.T) {
	for in, want := range map[string]Mode{"": Off, "false": Off, "FALSE": Off, "log": Log, " Log ": Log, "true": Enforce} {
		if got, err := ParseMode(in); err != nil || got != want {
			t.Errorf("ParseMode(%q) = %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"1", "yes", "enforce", "on"} {
		if _, err := ParseMode(bad); err == nil {
			t.Errorf("ParseMode(%q) accepted", bad)
		}
	}
	for in, want := range map[string]bool{"123456789012": true, "hiyall-prod-1": false, "123": false, "": false, "12345678901234567890123": false, "123456 789": false} {
		if ValidProjectNumber(in) != want {
			t.Errorf("ValidProjectNumber(%q) = %v", in, !want)
		}
	}
}
