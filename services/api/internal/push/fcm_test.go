package push

import (
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
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeGoogle serves the OAuth2 token endpoint and the FCM send endpoint.
type fakeGoogle struct {
	t        *testing.T
	key      *rsa.PrivateKey
	srv      *httptest.Server
	mu       sync.Mutex
	tokens   int
	sends    []map[string]any
	auths    []string
	expires  int
	respond  func(n int) (status int, header http.Header, body string)
	sendCall int
	claims   map[string]any
}

func newFakeGoogle(t *testing.T) (*fakeGoogle, *FCM) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	g := &fakeGoogle{t: t, key: key, expires: 3600}
	g.srv = httptest.NewServer(http.HandlerFunc(g.serve))
	t.Cleanup(g.srv.Close)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	sa := ServiceAccount{Type: "service_account", ProjectID: "hiyall-test", PrivateKeyID: "kid-1", ClientEmail: "push@hiyall-test.iam.gserviceaccount.com",
		PrivateKey: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), TokenURI: g.srv.URL + "/token"}
	f, err := NewFCM("hiyall-test", sa)
	if err != nil {
		t.Fatal(err)
	}
	f.Endpoint = g.srv.URL
	return g, f
}

func (g *fakeGoogle) serve(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch {
	case r.URL.Path == "/token":
		g.tokens++
		r.ParseForm()
		if r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			g.t.Errorf("grant_type %q", r.Form.Get("grant_type"))
		}
		g.verifyAssertion(r.Form.Get("assertion"))
		fmt.Fprintf(w, `{"access_token":"access-%d","expires_in":%d,"token_type":"Bearer"}`, g.tokens, g.expires)
	case r.URL.Path == "/v1/projects/hiyall-test/messages:send":
		g.sendCall++
		g.auths = append(g.auths, r.Header.Get("Authorization"))
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			g.t.Error(err)
		}
		g.sends = append(g.sends, body)
		status, header, out := http.StatusOK, http.Header{}, `{"name":"projects/hiyall-test/messages/1"}`
		if g.respond != nil {
			status, header, out = g.respond(g.sendCall)
		}
		for k, v := range header {
			w.Header()[k] = v
		}
		w.WriteHeader(status)
		fmt.Fprint(w, out)
	default:
		http.NotFound(w, r)
	}
}

// verifyAssertion checks the RS256 JWT the way Google would.
func (g *fakeGoogle) verifyAssertion(jwt string) {
	g.t.Helper()
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		g.t.Errorf("assertion has %d parts", len(parts))
		return
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&g.key.PublicKey, crypto.SHA256, sum[:], sig); err != nil {
		g.t.Errorf("bad signature: %v", err)
	}
	var header map[string]string
	hb, _ := base64.RawURLEncoding.DecodeString(parts[0])
	json.Unmarshal(hb, &header)
	if header["alg"] != "RS256" || header["typ"] != "JWT" || header["kid"] != "kid-1" {
		g.t.Errorf("header %v", header)
	}
	cb, _ := base64.RawURLEncoding.DecodeString(parts[1])
	json.Unmarshal(cb, &g.claims)
	if g.claims["iss"] != "push@hiyall-test.iam.gserviceaccount.com" || g.claims["scope"] != fcmScope || g.claims["aud"] != g.srv.URL+"/token" {
		g.t.Errorf("claims %v", g.claims)
	}
	if exp, iat := g.claims["exp"].(float64), g.claims["iat"].(float64); exp-iat != 3600 {
		g.t.Errorf("lifetime %v", exp-iat)
	}
}

var target = Target{UserID: "u1", DeviceID: "d1", Provider: "fcm", Token: "fcm-token-abcdef"}
var note = Message{Kind: "chat", Title: "Hiyall", Body: "New message", Data: map[string]string{"kind": "chat", "conversationId": "c1"}, CollapseKey: "chat-c1"}

func TestFCMSendsAuthenticatedV1Message(t *testing.T) {
	g, f := newFakeGoogle(t)
	if err := f.Send(context.Background(), target, note); err != nil {
		t.Fatal(err)
	}
	if g.tokens != 1 || g.auths[0] != "Bearer access-1" {
		t.Fatalf("tokens %d auth %v", g.tokens, g.auths)
	}
	m := g.sends[0]["message"].(map[string]any)
	if m["token"] != target.Token {
		t.Fatalf("token %v", m["token"])
	}
	if n := m["notification"].(map[string]any); n["title"] != "Hiyall" || n["body"] != "New message" || len(n) != 2 {
		t.Fatalf("notification %v", n)
	}
	if d := m["data"].(map[string]any); d["kind"] != "chat" || d["conversationId"] != "c1" || len(d) != 2 {
		t.Fatalf("data %v", d)
	}
	android := m["android"].(map[string]any)
	if android["collapse_key"] != "chat-c1" || android["priority"] != "HIGH" || android["ttl"] != "14400s" ||
		android["notification"].(map[string]any)["channel_id"] != AndroidChannel {
		t.Fatalf("android %v", android)
	}
	headers := m["apns"].(map[string]any)["headers"].(map[string]any)
	if headers["apns-collapse-id"] != "chat-c1" || headers["apns-push-type"] != "alert" || headers["apns-priority"] != "10" || headers["apns-expiration"] == "" {
		t.Fatalf("apns %v", headers)
	}
	if m["apns"].(map[string]any)["payload"].(map[string]any)["aps"].(map[string]any)["sound"] != "default" {
		t.Fatalf("aps %v", m["apns"])
	}
	// Nothing but the content-free fields goes out.
	raw, _ := json.Marshal(g.sends[0])
	for _, leak := range []string{"user", "u1", "d1", "private", "kid-1"} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("payload contains %q: %s", leak, raw)
		}
	}
}

func TestFCMCachesTheAccessTokenAndRefreshesBeforeExpiry(t *testing.T) {
	g, f := newFakeGoogle(t)
	now := time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)
	f.Now = func() time.Time { return now }
	for range 3 {
		if err := f.Send(context.Background(), target, note); err != nil {
			t.Fatal(err)
		}
	}
	if g.tokens != 1 {
		t.Fatalf("fetched %d tokens for 3 sends", g.tokens)
	}
	now = now.Add(54 * time.Minute) // 6 minutes left: still outside the 5 minute margin
	f.Send(context.Background(), target, note)
	if g.tokens != 1 {
		t.Fatalf("refreshed too early: %d", g.tokens)
	}
	now = now.Add(2 * time.Minute) // 4 minutes left: inside the margin
	f.Send(context.Background(), target, note)
	if g.tokens != 2 || g.auths[len(g.auths)-1] != "Bearer access-2" {
		t.Fatalf("not refreshed: %d %v", g.tokens, g.auths)
	}
}

func TestFCMConcurrentSendsShareOneTokenFetch(t *testing.T) {
	g, f := newFakeGoogle(t)
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if err := f.Send(context.Background(), target, note); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.tokens != 1 {
		t.Fatalf("%d token fetches", g.tokens)
	}
}

func fcmFailure(status int, errorStatus, code, message, field string) func(int) (int, http.Header, string) {
	return func(int) (int, http.Header, string) {
		details := ""
		if code != "" {
			details += fmt.Sprintf(`{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":%q}`, code)
		}
		if field != "" {
			if details != "" {
				details += ","
			}
			details += fmt.Sprintf(`{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":%q,"description":"bad"}]}`, field)
		}
		return status, http.Header{}, fmt.Sprintf(`{"error":{"code":%d,"message":%q,"status":%q,"details":[%s]}}`, status, message, errorStatus, details)
	}
}

func TestFCMErrorMapping(t *testing.T) {
	type outcome int
	const (
		dead outcome = iota
		retry
		final
		config
	)
	cases := []struct {
		name string
		resp func(int) (int, http.Header, string)
		want outcome
	}{
		{"unregistered", fcmFailure(404, "NOT_FOUND", "UNREGISTERED", "Requested entity was not found.", ""), dead},
		// Our credentials and the token belong to different projects: a configuration error, never a dead token.
		{"sender mismatch", fcmFailure(403, "PERMISSION_DENIED", "SENDER_ID_MISMATCH", "SenderId mismatch", ""), config},
		{"invalid token by field", fcmFailure(400, "INVALID_ARGUMENT", "INVALID_ARGUMENT", "bad request", "message.token"), dead},
		{"invalid token by message", fcmFailure(400, "INVALID_ARGUMENT", "", "The registration token is not a valid FCM registration token", ""), dead},
		{"invalid payload", fcmFailure(400, "INVALID_ARGUMENT", "INVALID_ARGUMENT", "Invalid value at message.data", "message.data"), final},
		// A wrong project id is also a 404; it must not be mistaken for a dead token.
		{"bare not found", fcmFailure(404, "NOT_FOUND", "", "Requested entity was not found.", ""), final},
		{"permission denied", fcmFailure(403, "PERMISSION_DENIED", "", "API not enabled", ""), final},
		{"quota", fcmFailure(429, "RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED", "quota", ""), retry},
		{"internal", fcmFailure(500, "INTERNAL", "INTERNAL", "oops", ""), retry},
		{"unavailable", fcmFailure(503, "UNAVAILABLE", "UNAVAILABLE", "try later", ""), retry},
		{"unauthenticated", fcmFailure(401, "UNAUTHENTICATED", "", "expired", ""), retry},
		{"not json", func(int) (int, http.Header, string) { return 502, http.Header{}, "<html>bad gateway</html>" }, retry},
	}
	for _, c := range cases {
		g, f := newFakeGoogle(t)
		g.respond = c.resp
		err := f.Send(context.Background(), target, note)
		var transient *TransientError
		switch {
		case err == nil:
			t.Fatalf("%s: no error", c.name)
		case c.want == config && (!errors.Is(err, ErrConfig) || errors.Is(err, ErrUnregistered) || errors.As(err, &transient)):
			t.Fatalf("%s: not a config error: %v", c.name, err)
		case c.want == config:
		case c.want == dead && !errors.Is(err, ErrUnregistered), c.want == retry && !errors.As(err, &transient),
			c.want == final && (errors.Is(err, ErrUnregistered) || errors.As(err, &transient)):
			t.Fatalf("%s: wrong class: %v", c.name, err)
		}
		// Neither the token nor the provider's own text reaches the error.
		if strings.Contains(err.Error(), target.Token) || strings.Contains(err.Error(), "registration token is") {
			t.Fatalf("%s: error leaks: %v", c.name, err)
		}
	}
}

func TestFCMRetryAfterAndUnauthorizedRefetch(t *testing.T) {
	g, f := newFakeGoogle(t)
	g.respond = func(n int) (int, http.Header, string) {
		if n == 1 {
			return 429, http.Header{"Retry-After": {"7"}}, `{"error":{"status":"RESOURCE_EXHAUSTED"}}`
		}
		if n == 2 {
			return 401, http.Header{}, `{"error":{"status":"UNAUTHENTICATED"}}`
		}
		return 200, http.Header{}, `{}`
	}
	var transient *TransientError
	if err := f.Send(context.Background(), target, note); !errors.As(err, &transient) || transient.After != 7*time.Second {
		t.Fatalf("Retry-After: %v", err)
	}
	if err := f.Send(context.Background(), target, note); !errors.As(err, &transient) {
		t.Fatalf("401: %v", err)
	}
	// The refused token was dropped, so the retry authenticates again.
	if err := f.Send(context.Background(), target, note); err != nil || g.tokens != 2 || g.auths[2] != "Bearer access-2" {
		t.Fatalf("after 401: %v tokens %d auth %v", err, g.tokens, g.auths)
	}
}

func TestFCMTokenEndpointFailures(t *testing.T) {
	for status, wantTransient := range map[int]bool{400: false, 401: false, 429: true, 500: true, 503: true} {
		_, f := newFakeGoogle(t)
		bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			fmt.Fprint(w, `{"error":"invalid_grant","error_description":"secret detail"}`)
		}))
		defer bad.Close()
		f.Account.TokenURI = bad.URL
		err := f.Send(context.Background(), target, note)
		var transient *TransientError
		if err == nil || errors.As(err, &transient) != wantTransient || strings.Contains(err.Error(), "secret detail") {
			t.Fatalf("token endpoint %d: %v", status, err)
		}
	}
}

func TestFCMNetworkFailureAndTimeoutAreTransient(t *testing.T) {
	g, f := newFakeGoogle(t)
	g.respond = func(int) (int, http.Header, string) {
		time.Sleep(300 * time.Millisecond)
		return 200, http.Header{}, `{}`
	}
	f.HTTP = &http.Client{Timeout: 50 * time.Millisecond}
	var transient *TransientError
	if err := f.Send(context.Background(), target, note); !errors.As(err, &transient) {
		t.Fatalf("timeout: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f.HTTP = &http.Client{Timeout: time.Second}
	if err := f.Send(ctx, target, note); err == nil {
		t.Fatal("canceled context sent")
	}
	g.srv.Close()
	if err := f.Send(context.Background(), target, note); !errors.As(err, &transient) {
		t.Fatalf("connection refused: %v", err)
	}
}

func TestFCMAPNSProviderIsAcceptedButNotImplemented(t *testing.T) {
	g, f := newFakeGoogle(t)
	err := f.Send(context.Background(), Target{Provider: "apns", Token: "apns-token-123"}, note)
	var transient *TransientError
	if err == nil || errors.Is(err, ErrUnregistered) || errors.As(err, &transient) || g.sendCall != 0 {
		t.Fatalf("apns: %v (%d requests)", err, g.sendCall)
	}
}

func TestDispatcherForgetsATokenFCMReportsUnregistered(t *testing.T) {
	g, f := newFakeGoogle(t)
	g.respond = fcmFailure(404, "NOT_FOUND", "UNREGISTERED", "gone", "")
	var forgot []Target
	d := NewDispatcher(Config{Sender: f, Backoff: func(int) time.Duration { return 0 },
		Targets: func(context.Context, []string) ([]Target, error) { return []Target{target}, nil },
		Check:   func(context.Context, Notice, string) (Eligibility, error) { return Eligibility{OK: true}, nil },
		Forget:  func(_ context.Context, tg Target) error { forgot = append(forgot, tg); return nil }})
	d.process(context.Background(), Notice{Kind: "chat", Actor: "a", Recipient: "u1", Conversation: "c1"})
	if len(forgot) != 1 || forgot[0] != target || g.sendCall != 1 {
		t.Fatalf("forgot %v after %d requests", forgot, g.sendCall)
	}
}

func TestDispatcherRetriesFCMOutagesThenDelivers(t *testing.T) {
	g, f := newFakeGoogle(t)
	g.respond = func(n int) (int, http.Header, string) {
		if n < 3 {
			return 503, http.Header{}, `{"error":{"status":"UNAVAILABLE"}}`
		}
		return 200, http.Header{}, `{}`
	}
	d := NewDispatcher(Config{Sender: f, Backoff: func(int) time.Duration { return time.Millisecond },
		Targets: func(context.Context, []string) ([]Target, error) { return []Target{target}, nil },
		Check:   func(context.Context, Notice, string) (Eligibility, error) { return Eligibility{OK: true}, nil }})
	d.process(context.Background(), Notice{Kind: "chat", Actor: "a", Recipient: "u1", Conversation: "c1"})
	if s := d.Stats(); s.Sent != 1 || s.Retried != 2 || g.sendCall != 3 {
		t.Fatalf("stats %+v requests %d", s, g.sendCall)
	}
}

func TestLoadServiceAccount(t *testing.T) {
	dir := t.TempDir()
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	write := func(name string, v any) string {
		raw, _ := json.Marshal(v)
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, raw, 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	good := map[string]string{"type": "service_account", "project_id": "hiyall-prod-1", "private_key_id": "k", "private_key": pemKey, "client_email": "x@y.iam.gserviceaccount.com"}
	sa, err := LoadServiceAccount(write("good.json", good))
	if err != nil || sa.TokenURI != "https://oauth2.googleapis.com/token" || sa.ProjectID != "hiyall-prod-1" {
		t.Fatalf("good: %+v %v", sa, err)
	}
	if f, err := NewFCM("", sa); err != nil || f.ProjectID != "hiyall-prod-1" {
		t.Fatalf("project from the file: %v", err)
	}
	if _, err := NewFCM("", ServiceAccount{PrivateKey: pemKey}); err == nil {
		t.Fatal("no project id accepted")
	}
	mutate := func(k, v string) map[string]string {
		m := map[string]string{}
		for a, b := range good {
			m[a] = b
		}
		m[k] = v
		return m
	}
	bad := map[string]string{
		"missing":    filepath.Join(dir, "nope.json"),
		"not json":   func() string { p := filepath.Join(dir, "x.json"); os.WriteFile(p, []byte("{"+pemKey), 0o600); return p }(),
		"wrong type": write("t.json", mutate("type", "authorized_user")),
		"no key":     write("k.json", mutate("private_key", "")),
		"not pem":    write("p.json", mutate("private_key", "not a key")),
		"http token": write("u.json", mutate("token_uri", "http://evil.example/token")),
	}
	for name, path := range bad {
		_, err := LoadServiceAccount(path)
		if err == nil {
			t.Fatalf("%s accepted", name)
		}
		if strings.Contains(err.Error(), "BEGIN") || strings.Contains(err.Error(), url.PathEscape(pemKey[:20])) || strings.Contains(err.Error(), dir) {
			t.Fatalf("%s: error leaks file content or path: %v", name, err)
		}
	}
}
