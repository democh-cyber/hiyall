package httpapi

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"

	"hiyall/services/api/internal/appcheck"
	"hiyall/services/api/internal/store"
)

const appCheckProject = "123456789012"

// appCheckSigner makes tokens the way Firebase App Check does, signed with a key only this test holds.
type appCheckSigner struct {
	t   *testing.T
	key *rsa.PrivateKey
}

func newAppCheckSigner(t *testing.T) *appCheckSigner {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return &appCheckSigner{t, key}
}

func (s *appCheckSigner) verifier() *appcheck.Verifier {
	return appcheck.NewWithKeys(appCheckProject, &oidc.StaticKeySet{PublicKeys: []crypto.PublicKey{&s.key.PublicKey}})
}

func (s *appCheckSigner) token(project string, expires time.Duration) string {
	header, _ := json.Marshal(map[string]any{"alg": "RS256", "typ": "JWT", "kid": "k"})
	body, _ := json.Marshal(map[string]any{
		"iss": "https://firebaseappcheck.googleapis.com/" + project, "aud": []string{"projects/" + project, "projects/hiyall-test"},
		"sub": "1:" + project + ":android:abc", "iat": time.Now().Add(-time.Minute).Unix(), "exp": time.Now().Add(expires).Unix(),
	})
	raw := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(raw))
	sig, err := rsa.SignPKCS1v15(rand.Reader, s.key, crypto.SHA256, digest[:])
	if err != nil {
		s.t.Fatal(err)
	}
	return raw + "." + base64.RawURLEncoding.EncodeToString(sig)
}

type appCheckDown struct{}

func (appCheckDown) Verify(context.Context, string) error { return appcheck.ErrUnavailable }

func appCheckAPI(mode appcheck.Mode, v AppCheckVerifier) *API {
	a := New(nil, func(context.Context, string) (store.Principal, error) {
		return store.Principal{UserID: "u", SessionID: "s", Onboarded: true}, nil
	}, false, "")
	a.AppCheck, a.AppCheckMode = v, mode
	return a
}

// call sends a signed-in request for a path no route serves, so a request that passes every check answers 404.
func appCheckCall(a *API, path, token string, bearer bool) (int, string) {
	r := httptest.NewRequest("GET", path, nil)
	r.RemoteAddr = "127.0.0.1:50000"
	if bearer {
		r.Header.Set("Authorization", "Bearer member")
	}
	if token != "" {
		r.Header.Set(appcheck.Header, token)
	}
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	var body struct {
		Error map[string]string `json:"error"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	return w.Code, body.Error["code"]
}

func appCheckCounter(t *testing.T, mode, result string) int {
	t.Helper()
	for _, line := range strings.Split(opsScrape(t), "\n") {
		if strings.HasPrefix(line, `hiyall_app_check_total{`) && strings.Contains(line, `mode="`+mode+`"`) && strings.Contains(line, `result="`+result+`"`) {
			var n int
			for _, f := range strings.Fields(line)[1:] {
				_ = json.Unmarshal([]byte(f), &n)
			}
			return n
		}
	}
	return 0
}

func TestAppCheckOffIgnoresTheHeader(t *testing.T) {
	signer := newAppCheckSigner(t)
	for name, a := range map[string]*API{"no verifier": appCheckAPI(appcheck.Off, nil), "mode off": appCheckAPI(appcheck.Off, signer.verifier()), "verifier but empty mode": appCheckAPI("", signer.verifier())} {
		for _, token := range []string{"", "garbage", signer.token(appCheckProject, time.Hour)} {
			if status, code := appCheckCall(a, "/v1/nothing", token, true); status != 404 || code != "NOT_FOUND" {
				t.Errorf("%s with %.10q: %d %s", name, token, status, code)
			}
		}
	}
}

func TestAppCheckLogModeCountsAndNeverRefuses(t *testing.T) {
	signer := newAppCheckSigner(t)
	a := appCheckAPI(appcheck.Log, signer.verifier())
	before := map[string]int{}
	for _, result := range []string{"valid", "missing", "invalid"} {
		before[result] = appCheckCounter(t, "log", result)
	}
	for _, token := range []string{"", "garbage", signer.token("999999999999", time.Hour), signer.token(appCheckProject, -time.Minute), signer.token(appCheckProject, time.Hour)} {
		if status, code := appCheckCall(a, "/v1/nothing", token, true); status != 404 || code != "NOT_FOUND" {
			t.Fatalf("log mode refused %.10q: %d %s", token, status, code)
		}
	}
	if got := appCheckCounter(t, "log", "missing") - before["missing"]; got != 1 {
		t.Errorf("missing counted %d times", got)
	}
	if got := appCheckCounter(t, "log", "invalid") - before["invalid"]; got != 3 {
		t.Errorf("invalid counted %d times (garbage, another project, expired)", got)
	}
	if got := appCheckCounter(t, "log", "valid") - before["valid"]; got != 1 {
		t.Errorf("valid counted %d times", got)
	}
}

func TestAppCheckEnforceRefusesWithoutAValidToken(t *testing.T) {
	signer := newAppCheckSigner(t)
	a := appCheckAPI(appcheck.Enforce, signer.verifier())
	for name, token := range map[string]string{"missing": "", "garbage": "garbage", "another project": signer.token("999999999999", time.Hour), "expired": signer.token(appCheckProject, -time.Minute)} {
		if status, code := appCheckCall(a, "/v1/nothing", token, true); status != 401 || code != "APP_CHECK_REQUIRED" {
			t.Errorf("%s: %d %s", name, status, code)
		}
	}
	if status, code := appCheckCall(a, "/v1/nothing", signer.token(appCheckProject, time.Hour), true); status != 404 || code != "NOT_FOUND" {
		t.Errorf("valid token: %d %s", status, code)
	}
	// The realtime socket is checked too, before it is upgraded.
	if status, code := appCheckCall(a, "/v1/realtime", "", true); status != 401 || code != "APP_CHECK_REQUIRED" {
		t.Errorf("realtime without a token: %d %s", status, code)
	}
	// Signing in is checked first: no credentials is the same 401 it always was.
	if status, code := appCheckCall(a, "/v1/nothing", "", false); status != 401 || code != "UNAUTHENTICATED" {
		t.Errorf("no bearer: %d %s", status, code)
	}
	// Exempt: the probes, the legal documents and development login never need a token.
	if status, _ := appCheckCall(a, "/healthz", "", false); status != 200 {
		t.Errorf("/healthz: %d", status)
	}
	if status, code := appCheckCall(a, "/v1/legal/terms", "", true); status != 404 || code != "NOT_FOUND" {
		t.Errorf("legal documents: %d %s", status, code)
	}
	if !appCheckExempt("/dev/session") || appCheckExempt("/v1/me/profile") || appCheckExempt("/v1/realtime") {
		t.Error("exemptions changed")
	}
	// Firebase's keys being unreachable is not the member's fault: 503, not a sign-out.
	down := appCheckAPI(appcheck.Enforce, appCheckDown{})
	if status, code := appCheckCall(down, "/v1/nothing", "any-token", true); status != 503 || code != "APP_CHECK_UNAVAILABLE" {
		t.Errorf("keys down: %d %s", status, code)
	}
	// The refusal is an ordinary envelope with the standard headers.
	r := httptest.NewRequest("GET", "/v1/nothing", nil)
	r.RemoteAddr = "127.0.0.1:50000"
	r.Header.Set("Authorization", "Bearer member")
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	if w.Header().Get("X-Request-Id") == "" || w.Header().Get("Content-Type") != "application/json; charset=utf-8" || w.Code != http.StatusUnauthorized {
		t.Errorf("envelope: %d %v", w.Code, w.Header())
	}
}
