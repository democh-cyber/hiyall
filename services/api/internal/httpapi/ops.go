package httpapi

// Operational plumbing for the request path: health, metrics, panic recovery and error reporting.
// Nothing here reads a request body, a header value or a query string into a log line or a metric.

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"hiyall/services/api/internal/buildinfo"
	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/metrics"
)

// ErrorReport describes one failure for an ErrorReporter. It carries identifiers and the route
// pattern only: never the URL, query string, headers or body, because those hold tokens, presigned
// URLs, birth dates and positions.
type ErrorReport struct {
	RequestID string
	Method    string
	// Route is the pattern, such as "/v1/conversations/:id/messages", not the raw path.
	Route string
	// Err is the failure that produced a 500 (nil for a panic).
	Err error
	// Panic is the recovered value (nil unless the handler panicked) and Stack the goroutine stack.
	Panic any
	Stack []byte
}

// ErrorReporter receives every handler panic and every unexpected 500, for an error tracker. The
// default does nothing. Report is called on the request goroutine, so it must return quickly (hand the
// report to the tracker's own async queue) and must not panic; a panic in it is recovered and logged.
//
// To plug Sentry (or any tracker) in without touching the handlers, implement this interface in
// cmd/api (for example a type wrapping sentry.CaptureException that sets tags request_id and route,
// and never attaches the request) and assign it in run(): api.Reporter = sentryReporter{}. Flush the
// SDK after srv.Shutdown. The SDK is deliberately not a dependency yet.
type ErrorReporter interface {
	Report(ctx context.Context, report ErrorReport)
}

// NoopReporter is the default ErrorReporter.
type NoopReporter struct{}

func (NoopReporter) Report(context.Context, ErrorReport) {}

func (a *API) report(ctx context.Context, rep ErrorReport) {
	if a.Reporter == nil {
		return
	}
	defer func() {
		if recover() != nil {
			slog.Error("error reporter panicked", "requestId", rep.RequestID)
		}
	}()
	a.Reporter.Report(ctx, rep)
}

// scrubURLs hides URLs inside an error message: Go's network errors quote the full URL they were
// fetching, and a presigned URL carries its signature in the query.
func scrubURLs(s string) string { return logscrub.URLs(s) }

// panicked answers a recovered handler panic: the standard error envelope with the request id, the
// stack in the log under that id, and the reporter told. The panic value is logged as text, cut short.
func (a *API) panicked(w http.ResponseWriter, r *http.Request, id, route string, value any, answered bool) {
	stack := debug.Stack()
	text := scrubURLs(fmt.Sprint(value))
	if len(text) > 300 {
		text = text[:300] + "…"
	}
	logged := stack
	if len(logged) > 8192 {
		logged = logged[:8192]
	}
	slog.Error("request panic", "requestId", id, "method", r.Method, "route", route, "panic", text, "stack", string(logged))
	httpPanics.Inc(route)
	a.report(r.Context(), ErrorReport{RequestID: id, Method: r.Method, Route: route, Panic: value, Stack: stack})
	if !answered {
		a.failure(w, r, 500, "INTERNAL", "Something went wrong")
	}
}

var (
	httpRequests = metrics.NewCounter("hiyall_http_requests_total", "HTTP requests by method, route pattern and status class.", "method", "route", "status_class")
	httpDuration = metrics.NewHistogram("hiyall_http_request_duration_seconds", "HTTP request latency by route pattern (the realtime socket is excluded).", nil, "route")
	httpInFlight = metrics.NewGauge("hiyall_http_requests_in_flight", "Requests being served now (open realtime sockets included).")
	httpPanics   = metrics.NewCounter("hiyall_http_panics_total", "Handler panics recovered, by route pattern.", "route")
)

// registerMetrics exposes what only the server knows: pool, realtime and build. Safe to call for
// every API built (tests build many); the newest instance wins.
func (a *API) registerMetrics() {
	if a.Store != nil && a.Store.Pool != nil {
		pool := a.Store.Pool
		gauge := func(name, help string, f func() float64) { metrics.NewGaugeFunc(name, help, f) }
		gauge("hiyall_db_pool_conns", "Connections in the pool (acquired + idle + being opened).", func() float64 { return float64(pool.Stat().TotalConns()) })
		gauge("hiyall_db_pool_conns_acquired", "Connections checked out by a query now.", func() float64 { return float64(pool.Stat().AcquiredConns()) })
		gauge("hiyall_db_pool_conns_idle", "Idle connections.", func() float64 { return float64(pool.Stat().IdleConns()) })
		gauge("hiyall_db_pool_conns_max", "Configured pool size.", func() float64 { return float64(pool.Stat().MaxConns()) })
		metrics.NewCounterFunc("hiyall_db_pool_acquires_total", "Connection acquisitions.", func() float64 { return float64(pool.Stat().AcquireCount()) })
		metrics.NewCounterFunc("hiyall_db_pool_empty_acquires_total", "Acquisitions that had to wait because every connection was busy (pool saturation).", func() float64 { return float64(pool.Stat().EmptyAcquireCount()) })
		metrics.NewCounterFunc("hiyall_db_pool_canceled_acquires_total", "Acquisitions abandoned because the request ended while waiting.", func() float64 { return float64(pool.Stat().CanceledAcquireCount()) })
		metrics.NewCounterFunc("hiyall_db_pool_acquire_wait_seconds_total", "Total time spent waiting to acquire a connection.", func() float64 { return pool.Stat().AcquireDuration().Seconds() })
	}
	metrics.NewGaugeFunc("hiyall_realtime_connections", "Open realtime WebSocket connections on this node.", func() float64 {
		if a.RT == nil {
			return 0
		}
		return float64(a.RT.Count())
	})
	if bi, ok := debug.ReadBuildInfo(); ok {
		metrics.NewGauge("hiyall_build_info", "Build information; the value is always 1.", "go_version", "version", "commit").Set(1, bi.GoVersion, buildinfo.Version, buildinfo.Commit)
	}
}

// statusClass is "2xx" and so on; a handler that wrote nothing answered 200.
func statusClass(status int) string {
	if status == 0 {
		status = 200
	}
	if status < 100 || status > 599 {
		return "other"
	}
	return string(rune('0'+status/100)) + "xx"
}

// methodLabel keeps the method label to a fixed set so a client cannot mint series with odd verbs.
func methodLabel(m string) string {
	switch m {
	case "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD":
		return m
	}
	return "other"
}

var uuidSegment = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// routePattern turns a raw path into a bounded label: identifiers become ":id", anything that is not
// under a known prefix is "other", and a path with an implausible number of segments is "other". The
// shape is derived from the path alone, so it needs no knowledge of the router, and an unknown path
// (scanners probing /wp-login.php) can never create a new series.
func routePattern(path string) string {
	switch path {
	case "/healthz", "/readyz", "/health/live", "/health/ready", "/dev/session", "/v1/realtime":
		return path
	}
	if !strings.HasPrefix(path, "/v1/") {
		return "other"
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) > 8 {
		return "other"
	}
	for i, p := range parts {
		switch {
		case uuidSegment.MatchString(p):
			parts[i] = ":id"
		case len(p) > 32 || !literalSegment(p):
			// Not a word the API routes by: a slug, token or garbage.
			parts[i] = ":x"
		}
	}
	return "/" + strings.Join(parts, "/")
}

// routeSet is the guard that keeps route labels bounded however many paths clients invent. A pattern
// becomes a label only after the API has really served it (a 2xx or 3xx, or a 409, 412, 422 or 428 that a
// handler produced); until then, and for every request that never reached a handler (401, 404, 403, 429),
// the label is "unmatched". So scanners and unauthenticated clients all share one series, and the set
// holds at most maxRoutes patterns.
type routeSet struct {
	mu    sync.Mutex
	known map[string]bool
}

const maxRoutes = 256

func (s *routeSet) label(pattern string, status int) string {
	if pattern == "other" || !strings.HasPrefix(pattern, "/v1/") || pattern == "/v1/realtime" {
		return pattern
	}
	if status == 0 {
		status = 200
	}
	served := status < 400 || status == 409 || status == 412 || status == 422 || status == 428
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.known[pattern] {
		return pattern
	}
	if !served || len(s.known) >= maxRoutes {
		return "unmatched"
	}
	if s.known == nil {
		s.known = map[string]bool{}
	}
	s.known[pattern] = true
	return pattern
}

// literalSegment accepts the lower-case words, digits and hyphens route segments are made of (v1, blob-urls),
// never starting with a digit, so numeric ids are not literals.
func literalSegment(s string) bool {
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// health answers the unauthenticated probes, before CORS-irrelevant concerns, rate limiting and
// authentication. /healthz (alias /health/live) is liveness: the process answers, nothing else is
// touched. /readyz (alias /health/ready) is readiness: the database answers within a second and the
// schema is not behind this binary. It reports whether the request was one of the probes.
func (a *API) health(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet {
		return false
	}
	switch r.URL.Path {
	case "/healthz", "/health/live":
		a.ok(w, r, map[string]string{"status": "ok"})
	case "/readyz", "/health/ready":
		if code, msg := a.readiness(r.Context()); code != "" {
			a.failure(w, r, 503, code, msg)
		} else {
			a.ok(w, r, map[string]string{"status": "ready"})
		}
	default:
		return false
	}
	return true
}

// readiness is cached for two seconds so that probes (and anyone hammering the unauthenticated
// endpoint) cost the database at most one ping and one query per two seconds per node.
type readyCache struct {
	mu        sync.Mutex
	checkedAt time.Time
	code, msg string
}

const readyTTL = 2 * time.Second

func (a *API) readiness(ctx context.Context) (code, msg string) {
	a.ready.mu.Lock()
	defer a.ready.mu.Unlock()
	if !a.ready.checkedAt.IsZero() && time.Since(a.ready.checkedAt) < readyTTL {
		return a.ready.code, a.ready.msg
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	code, msg = "", ""
	if a.Store == nil || a.Store.Pool == nil || a.Store.Pool.Ping(ctx) != nil {
		code, msg = "NOT_READY", "Database unavailable"
	} else if len(a.Migrations) > 0 {
		missing, err := a.Store.MissingMigrations(ctx, a.Migrations)
		switch {
		case err != nil:
			code, msg = "NOT_READY", "Database schema unavailable"
		case len(missing) > 0:
			// Named in the log for the operator, not in the unauthenticated response.
			slog.Warn("not ready: database migrations are behind this release", "missing", missing)
			code, msg = "NOT_READY", "Database schema is behind this release"
		}
	}
	a.ready.checkedAt, a.ready.code, a.ready.msg = time.Now(), code, msg
	return code, msg
}
