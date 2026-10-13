package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

// opsDB connects to the disposable test database, or skips.
func opsDB(t *testing.T) *store.Store {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	db, err := store.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	var name string
	if err = db.Pool.QueryRow(context.Background(), "SELECT current_database()").Scan(&name); err != nil || !strings.HasPrefix(name, "hiyall_test") {
		t.Fatalf("requires a disposable database named hiyall_test*, got %q", name)
	}
	return db
}

func opsServe(h http.Handler, method, target, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.RemoteAddr = "203.0.113.9:5000"
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func opsEnvelope(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var v map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("not an envelope: %q", rec.Body.String())
	}
	return v
}

func opsScrape(t *testing.T) string {
	t.Helper()
	var sb strings.Builder
	if _, err := metrics.Default.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	return sb.String()
}

func opsUnauthenticated(context.Context, string) (store.Principal, error) {
	return store.Principal{}, domain.ErrUnauthorized
}

func TestLivenessNeedsNoDatabaseAndIgnoresLimitersAndAuth(t *testing.T) {
	a := New(nil, opsUnauthenticated, false, "")
	h := a.Handler()
	// Exhaust both the instance budget and the per-address bucket: probes must still be answered.
	for i := 0; i < 200; i++ {
		a.clients.allow("203.0.113.9")
	}
	for i := 0; i < 5000 && a.budget.Allow(); i++ {
	}
	for _, path := range []string{"/healthz", "/health/live"} {
		rec := opsServe(h, "GET", path, "", "")
		if rec.Code != 200 || opsEnvelope(t, rec)["success"] != true {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
		if rec.Header().Get("X-Request-Id") == "" || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s lost the standard headers", path)
		}
	}
	// Everything else is limited (429 here) while the probes above kept answering.
	if rec := opsServe(h, "GET", "/v1/me/profile", "", ""); rec.Code != 429 {
		t.Fatalf("profile with the budget spent: %d, want 429", rec.Code)
	}
	// Only GET probes: a POST to /healthz is an ordinary opsUnauthenticated request.
	if rec := opsServe(h, "POST", "/healthz", "", ""); rec.Code == 200 {
		t.Fatal("POST answered as a probe")
	}
}

func TestReadinessChecksDatabaseAndMigrations(t *testing.T) {
	// No database: not ready, with the standard error envelope.
	none := New(nil, opsUnauthenticated, false, "")
	rec := opsServe(none.Handler(), "GET", "/readyz", "", "")
	if rec.Code != 503 || opsEnvelope(t, rec)["error"].(map[string]any)["code"] != "NOT_READY" {
		t.Fatalf("no database: %d %s", rec.Code, rec.Body.String())
	}
	db := opsDB(t)
	a := New(db, opsUnauthenticated, false, "")
	h := a.Handler()
	for _, path := range []string{"/readyz", "/health/ready"} {
		a.ready = readyCache{}
		if rec := opsServe(h, "GET", path, "", ""); rec.Code != 200 {
			t.Fatalf("%s with a database: %d %s", path, rec.Code, rec.Body.String())
		}
	}
	// Migrations the binary expects but the database lacks: not ready, and the response does not
	// name them (the log does).
	var applied string
	if err := db.Pool.QueryRow(context.Background(), `SELECT version FROM schema_migrations ORDER BY version LIMIT 1`).Scan(&applied); err != nil {
		t.Fatal(err)
	}
	a.Migrations = []string{applied}
	a.ready = readyCache{}
	if rec := opsServe(h, "GET", "/readyz", "", ""); rec.Code != 200 {
		t.Fatalf("applied migration expected: %d %s", rec.Code, rec.Body.String())
	}
	a.Migrations = []string{applied, "9999_from_the_future.sql"}
	a.ready = readyCache{}
	rec = opsServe(h, "GET", "/readyz", "", "")
	if rec.Code != 503 || strings.Contains(rec.Body.String(), "9999") || !strings.Contains(rec.Body.String(), "behind") {
		t.Fatalf("behind: %d %s", rec.Code, rec.Body.String())
	}
	// Liveness is unaffected by the schema or the database.
	if rec := opsServe(h, "GET", "/healthz", "", ""); rec.Code != 200 {
		t.Fatalf("liveness while not ready: %d", rec.Code)
	}
	// The result is cached for a moment: fixing the schema is seen after the cache expires, not before.
	a.Migrations = []string{applied}
	if rec := opsServe(h, "GET", "/readyz", "", ""); rec.Code != 503 {
		t.Fatal("readiness was not cached")
	}
	a.ready = readyCache{}
	if rec := opsServe(h, "GET", "/readyz", "", ""); rec.Code != 200 {
		t.Fatal("readiness did not recover")
	}
	// A closed pool is not ready.
	closed := opsDB(t)
	b := New(closed, opsUnauthenticated, false, "")
	closed.Pool.Close()
	if rec := opsServe(b.Handler(), "GET", "/readyz", "", ""); rec.Code != 503 {
		t.Fatalf("closed pool: %d", rec.Code)
	}
}

func TestRoutePatternIsBounded(t *testing.T) {
	id := "019a4000-0000-7000-8000-000000000001"
	for path, want := range map[string]string{
		"/healthz":                                "/healthz",
		"/v1/me/profile":                          "/v1/me/profile",
		"/v1/users/" + id + "/profile":            "/v1/users/:id/profile",
		"/v1/conversations/" + id + "/messages":   "/v1/conversations/:id/messages",
		"/v1/usernames/Some.Body_99/availability": "/v1/usernames/:x/availability",
		"/v1/realtime":                            "/v1/realtime",
		"/wp-login.php":                           "other",
		"/":                                       "other",
		"/v1/a/b/c/d/e/f/g/h/i":                   "other",
		"/v1/" + strings.Repeat("a", 100):         "/v1/:x",
		"/v1/users/" + id + "/profile%0a":         "/v1/users/:id/:x",
	} {
		if got := routePattern(path); got != want {
			t.Errorf("routePattern(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestRouteLabelsCannotBeMintedByClients(t *testing.T) {
	var s routeSet
	// Requests that never reached a handler share one series.
	for i := 0; i < 1000; i++ {
		if got := s.label(fmt.Sprintf("/v1/probe/%d", i), 404); got != "unmatched" {
			t.Fatalf("a 404 minted %q", got)
		}
		if got := s.label(fmt.Sprintf("/v1/probe/%d", i), 401); got != "unmatched" {
			t.Fatalf("a 401 minted %q", got)
		}
	}
	if got := s.label("/v1/me/profile", 200); got != "/v1/me/profile" {
		t.Fatalf("served route label %q", got)
	}
	// Once served, the pattern keeps its label for every status, errors included.
	if got := s.label("/v1/me/profile", 404); got != "/v1/me/profile" {
		t.Fatalf("known route lost its label: %q", got)
	}
	// Even served patterns are capped.
	for i := 0; i < maxRoutes*2; i++ {
		s.label(fmt.Sprintf("/v1/served/%d", i), 200)
	}
	if len(s.known) > maxRoutes {
		t.Fatalf("%d labels", len(s.known))
	}
	if got := s.label("/v1/one-more", 200); got != "unmatched" {
		t.Fatalf("label past the cap: %q", got)
	}
	if got := s.label("other", 404); got != "other" {
		t.Fatal(got)
	}
}

func opsSeriesCount(out, name string) int { return strings.Count(out, "\n"+name+"{") }

func TestMetricsRecordRequestsByPatternWithoutCardinalityBomb(t *testing.T) {
	opsCaptureLogs(t) // 1600 access-log lines are not useful output
	a := New(nil, opsUnauthenticated, false, "")
	h := a.Handler()
	before := opsSeriesCount(opsScrape(t), "hiyall_http_requests_total")
	opsServe(h, "GET", "/healthz", "", "")
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				a.clients.reset("203.0.113.9")
				opsServe(h, "GET", fmt.Sprintf("/v1/users/%s/profile?cursor=%d", uuid.NewString(), j), "", "")
				opsServe(h, "GET", fmt.Sprintf("/scan/%s.php", uuid.NewString()), "", "")
			}
		}()
	}
	wg.Wait()
	out := opsScrape(t)
	after := opsSeriesCount(out, "hiyall_http_requests_total")
	// 1600 distinct ids and paths added at most: healthz 2xx, "other" 4xx, "unmatched" 4xx.
	if after-before > 3 {
		t.Fatalf("request series grew by %d with unique ids and paths; the label is not bounded", after-before)
	}
	for _, want := range []string{
		`hiyall_http_requests_total{method="GET",route="/healthz",status_class="2xx"}`,
		`hiyall_http_requests_total{method="GET",route="unmatched",status_class="4xx"}`,
		`hiyall_http_requests_total{method="GET",route="other",status_class="4xx"}`,
		`hiyall_http_request_duration_seconds_bucket{route="/healthz",le="+Inf"}`,
		"# TYPE hiyall_http_requests_in_flight gauge",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %s in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "cursor=") || strings.Contains(out, ".php") {
		t.Fatal("a raw path or query leaked into a label")
	}
}

type opsRecordingReporter struct {
	mu      sync.Mutex
	reports []ErrorReport
}

func (r *opsRecordingReporter) Report(_ context.Context, rep ErrorReport) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.reports = append(r.reports, rep)
}

type opsPanickingReporter struct{}

func (opsPanickingReporter) Report(context.Context, ErrorReport) { panic("reporter bug") }

// A nil Store makes every database handler panic, which is exactly what recovery has to survive.
func opsPanicAPI() *API {
	return New(nil, func(context.Context, string) (store.Principal, error) {
		return store.Principal{UserID: "019a4000-0000-7000-8000-000000000001", SessionID: "s", Onboarded: true}, nil
	}, false, "")
}

func opsCaptureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &logs
}

func TestPanicBecomesEnvelopeWithRequestIDAndStackWithoutSecrets(t *testing.T) {
	logs := opsCaptureLogs(t)
	a := opsPanicAPI()
	reporter := &opsRecordingReporter{}
	a.Reporter = reporter
	h := a.Handler()
	rec := opsServe(h, "GET", "/v1/me/profile?X-Amz-Signature=SIGSECRET", "BEARERSECRET", `{"bio":"BODYSECRET"}`)
	if rec.Code != 500 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	env := opsEnvelope(t, rec)
	id := rec.Header().Get("X-Request-Id")
	if env["success"] != false || env["error"].(map[string]any)["code"] != "INTERNAL" || env["meta"].(map[string]any)["requestId"] != id || id == "" {
		t.Fatalf("not the standard envelope with the request id: %s (header %q)", rec.Body.String(), id)
	}
	out := logs.String()
	if !strings.Contains(out, "request panic") || !strings.Contains(out, "requestId="+id) || !strings.Contains(out, "stack=") || !strings.Contains(out, "goroutine") {
		t.Fatalf("panic not logged with request id and stack:\n%s", out)
	}
	for _, secret := range []string{"SIGSECRET", "BEARERSECRET", "BODYSECRET"} {
		if strings.Contains(out, secret) || strings.Contains(rec.Body.String(), secret) {
			t.Fatalf("%s leaked", secret)
		}
	}
	if len(reporter.reports) != 1 || reporter.reports[0].Panic == nil || reporter.reports[0].RequestID != id || reporter.reports[0].Route != "/v1/me/profile" || len(reporter.reports[0].Stack) == 0 {
		t.Fatalf("reporter not told: %+v", reporter.reports)
	}
	if !strings.Contains(opsScrape(t), `hiyall_http_panics_total{route="/v1/me/profile"}`) || !strings.Contains(opsScrape(t), `status_class="5xx"`) {
		t.Fatal("panic not counted")
	}
	// The server keeps serving, and a broken reporter cannot take a request down.
	a.Reporter = opsPanickingReporter{}
	if rec := opsServe(h, "GET", "/healthz", "", ""); rec.Code != 200 {
		t.Fatalf("server did not survive: %d", rec.Code)
	}
	if rec := opsServe(h, "GET", "/v1/me/profile", "t", ""); rec.Code != 500 || opsEnvelope(t, rec)["error"].(map[string]any)["code"] != "INTERNAL" {
		t.Fatalf("a panicking reporter broke the response: %d %s", rec.Code, rec.Body.String())
	}
}

func TestAccessLogOmitsQueryStringsTokensAndBodies(t *testing.T) {
	logs := opsCaptureLogs(t)
	a := opsPanicAPI()
	h := a.Handler()
	blob, convo := uuid.NewString(), uuid.NewString()
	presigned := "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIASECRETKEY%2F20260101&X-Amz-Signature=deadbeefSIGNATURE&token=QUERYTOKEN"
	for _, c := range []struct{ method, target, token, body string }{
		{"GET", "/v1/conversations/" + convo + "/blobs/" + blob + "/url" + presigned, "BEARERSECRET", ""},
		{"POST", "/v1/conversations/" + convo + "/messages" + presigned, "BEARERSECRET", `{"ciphertext":"MESSAGEBODYSECRET"}`},
		{"GET", "/v1/unknown" + presigned, "BEARERSECRET", ""},
		{"GET", "/v1/me/profile" + presigned, "", ""},
	} {
		opsServe(h, c.method, c.target, c.token, c.body)
	}
	out := logs.String()
	if !strings.Contains(out, "request completed") || !strings.Contains(out, "route=") || !strings.Contains(out, "method=") {
		t.Fatalf("no access log:\n%s", out)
	}
	for _, secret := range []string{"X-Amz", "AKIASECRETKEY", "deadbeefSIGNATURE", "QUERYTOKEN", "BEARERSECRET", "MESSAGEBODYSECRET", "Authorization", "Bearer"} {
		if strings.Contains(out, secret) {
			t.Fatalf("%q reached the logs:\n%s", secret, out)
		}
	}
	// Identifiers stay out of the route label too: the access log names the pattern.
	if strings.Contains(out, blob) {
		t.Fatalf("a blob id reached the access log's route:\n%s", out)
	}
}

func TestSharedRateLimitsAreOneBudgetAcrossNodes(t *testing.T) {
	db := opsDB(t)
	node1, node2 := New(db, opsUnauthenticated, false, ""), New(db, opsUnauthenticated, false, "")
	node1.UseSharedRateLimits(db.Pool)
	node2.UseSharedRateLimits(db.Pool)
	user := uuid.NewString()
	t.Cleanup(func() {
		_, _ = db.Pool.Exec(context.Background(), `DELETE FROM rate_limits WHERE bucket LIKE '%' || $1`, user)
	})
	// firstChats: a burst of 10, then one a minute. Alternating nodes still gets exactly 10.
	allowed := 0
	for i := 0; i < 30; i++ {
		n := node1
		if i%2 == 1 {
			n = node2
		}
		if n.firstChats.allow(user) {
			allowed++
		}
	}
	if allowed != 10 {
		t.Fatalf("%d first chats allowed across two nodes, want the burst of 10", allowed)
	}
	// Per node (memory), the same traffic would have allowed 20.
	m1, m2 := New(db, opsUnauthenticated, false, ""), New(db, opsUnauthenticated, false, "")
	memory := 0
	for i := 0; i < 30; i++ {
		n := m1
		if i%2 == 1 {
			n = m2
		}
		if n.firstChats.allow(user) {
			memory++
		}
	}
	if memory != 20 {
		t.Fatalf("memory backend allowed %d, want 20 (10 per node)", memory)
	}
	// The per-address flood guard stays in memory whatever the backend.
	if _, shared := node1.clients.backend.(interface{ Len() int }); !shared {
		t.Fatal("the address limiter moved to the database")
	}
	// Every named limiter got a name (it is the metrics label and the bucket prefix).
	for name, l := range node1.limiters() {
		if l == nil || l.name != name {
			t.Fatalf("limiter %q is nil or unnamed (%v)", name, l)
		}
	}
}

func TestScrubURLsHidesPresignedQueries(t *testing.T) {
	got := scrubURLs(`Get "https://bucket.example.com/chat/abc?X-Amz-Signature=SECRET&X-Amz-Credential=KEY": dial tcp: timeout`)
	if strings.Contains(got, "SECRET") || strings.Contains(got, "bucket.example.com") || !strings.Contains(got, "dial tcp: timeout") {
		t.Fatalf("scrubbed to %q", got)
	}
}
