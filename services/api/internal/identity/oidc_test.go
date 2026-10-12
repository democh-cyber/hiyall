package identity

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestVerifiedAccessTokenBoundary(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	var url string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/.well-known/openid-configuration" {
			_ = json.NewEncoder(w).Encode(map[string]any{"issuer": url, "jwks_uri": url + "/keys", "authorization_endpoint": url + "/authorize", "token_endpoint": url + "/token", "id_token_signing_alg_values_supported": []string{"RS256"}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "test", "use": "sig", "alg": "RS256", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
	}))
	defer srv.Close()
	url = srv.URL
	v, err := New(context.Background(), url, "hiyall-api", nil)
	if err != nil {
		t.Fatal(err)
	}
	sign := func(headerType string, override map[string]any) string {
		claims := map[string]any{"iss": url, "sub": "member", "aud": "hiyall-api", "exp": time.Now().Add(time.Minute).Unix(), "iat": time.Now().Unix(), "sid": "device-session"}
		for k, value := range override {
			claims[k] = value
		}
		header, _ := json.Marshal(map[string]string{"alg": "RS256", "kid": "test", "typ": headerType})
		body, _ := json.Marshal(claims)
		raw := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
		digest := sha256.Sum256([]byte(raw))
		sig, e := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
		if e != nil {
			t.Fatal(e)
		}
		return raw + "." + base64.RawURLEncoding.EncodeToString(sig)
	}
	for _, typ := range []string{"at+jwt", "application/at+jwt", "AT+JWT"} {
		if _, sid, err := v.accessClaims(context.Background(), sign(typ, nil)); err != nil || sid != "device-session" {
			t.Fatalf("valid %s access token: %s %v", typ, sid, err)
		}
	}
	cases := []struct {
		name, typ string
		claims    map[string]any
	}{{"ID token", "JWT", nil}, {"wrong audience", "at+jwt", map[string]any{"aud": "different-app"}}, {"wrong issuer", "at+jwt", map[string]any{"iss": "https://wrong.example"}}, {"expired", "at+jwt", map[string]any{"exp": time.Now().Add(-time.Minute).Unix()}}, {"missing sid", "at+jwt", map[string]any{"sid": ""}}}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, _, err := v.accessClaims(context.Background(), sign(c.typ, c.claims)); err == nil {
				t.Fatal("accepted invalid token")
			}
		})
	}
	raw := sign("at+jwt", nil)
	tampered := raw[:len(raw)-12] + "AAAAAAAAAAAA"
	if _, _, err = v.accessClaims(context.Background(), tampered); err == nil {
		t.Fatal("accepted forged signature")
	}
}
