package clientip

import (
	"bytes"
	"context"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/metrics"
)

type recorder struct {
	mu      sync.Mutex
	records []slog.Record
}

func (r *recorder) Enabled(context.Context, slog.Level) bool { return true }
func (r *recorder) Handle(_ context.Context, rec slog.Record) error {
	r.mu.Lock()
	r.records = append(r.records, rec)
	r.mu.Unlock()
	return nil
}
func (r *recorder) WithAttrs([]slog.Attr) slog.Handler { return r }
func (r *recorder) WithGroup(string) slog.Handler      { return r }
func (r *recorder) count(msgPrefix string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, rec := range r.records {
		if strings.HasPrefix(rec.Message, msgPrefix) {
			n++
		}
	}
	return n
}

func capture(t *testing.T) *recorder {
	t.Helper()
	rec := &recorder{}
	previous := slog.Default()
	slog.SetDefault(slog.New(rec))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return rec
}

func untrustedCount(t *testing.T) float64 {
	t.Helper()
	var buf bytes.Buffer
	if _, err := metrics.Default.WriteTo(&buf); err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(buf.String(), "\n") {
		if strings.HasPrefix(line, "hiyall_untrusted_forwarding_total ") {
			v, err := strconv.ParseFloat(strings.Fields(line)[1], 64)
			if err != nil {
				t.Fatal(err)
			}
			return v
		}
	}
	return 0
}

// A wrong TRUSTED_PROXY_CIDRS looks like this: the proxy's own address is not trusted but every request
// carries X-Forwarded-For. The server must say so, once a minute, and count every such request.
func TestForwardingFromAnUntrustedPeerWarnsOncePerMinuteAndCounts(t *testing.T) {
	rec := capture(t)
	trusted, _ := ParseCIDRs("10.0.0.0/8")
	r := New(trusted, "")
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	r.diag.now = func() time.Time { return now }
	before := untrustedCount(t)
	for i := 0; i < 5; i++ {
		req := request("172.16.0.9:5555", map[string][]string{"X-Forwarded-For": {"203.0.113.5"}})
		if got := r.ClientIP(req); got != "172.16.0.9" {
			t.Fatalf("the header was believed from an untrusted peer: %q", got)
		}
	}
	if got := untrustedCount(t) - before; got != 5 {
		t.Fatalf("counter rose by %v, want 5", got)
	}
	if n := rec.count("forwarding header from a peer"); n != 1 {
		t.Fatalf("%d warnings within a minute, want 1", n)
	}
	now = now.Add(61 * time.Second)
	r.ClientIP(request("172.16.0.9:5555", map[string][]string{"X-Forwarded-For": {"203.0.113.5"}}))
	if n := rec.count("forwarding header from a peer"); n != 2 {
		t.Fatalf("%d warnings after the minute, want 2", n)
	}
	// The warning names the peer, which is what the operator needs, and never the header's value.
	rec.mu.Lock()
	defer rec.mu.Unlock()
	var line strings.Builder
	rec.records[len(rec.records)-1].Attrs(func(a slog.Attr) bool { line.WriteString(a.Key + "=" + a.Value.String() + " "); return true })
	if !strings.Contains(line.String(), "172.16.0.9") || strings.Contains(line.String(), "203.0.113.5") {
		t.Fatalf("warning attributes: %s", line.String())
	}
}

func TestNoWarningWhenTheProxyIsTrustedOrNothingIsForwarded(t *testing.T) {
	rec := capture(t)
	trusted, _ := ParseCIDRs("10.0.0.0/8")
	r := New(trusted, "Fly-Client-IP")
	before := untrustedCount(t)
	r.ClientIP(request("10.1.2.3:1", map[string][]string{"Fly-Client-IP": {"203.0.113.9"}, "X-Forwarded-For": {"203.0.113.9"}}))
	r.ClientIP(request("198.51.100.7:1", nil)) // a direct client that forwards nothing
	if untrustedCount(t) != before || rec.count("forwarding header from a peer") != 0 {
		t.Fatal("a trusted proxy or a plain direct request raised the warning")
	}
	// A nil and a zero resolver stay silent and safe.
	var nilR *Resolver
	nilR.ClientIP(request("198.51.100.7:1", map[string][]string{"X-Forwarded-For": {"1.1.1.1"}}))
	(&Resolver{}).ClientIP(request("198.51.100.7:1", map[string][]string{"X-Forwarded-For": {"1.1.1.1"}}))
}

// The first request after a start is logged with the peer, so the operator can read the proxy address.
func TestFirstRequestLogsThePeerOnce(t *testing.T) {
	rec := capture(t)
	r := New(nil, "")
	for i := 0; i < 3; i++ {
		r.ClientIP(request("172.16.0.9:5555", map[string][]string{"X-Forwarded-For": {"203.0.113.5"}}))
	}
	if n := rec.count("client address: first request"); n != 1 {
		t.Fatalf("%d first-request lines", n)
	}
}

// DEBUG_LOG_PEER logs the peer and the forwarding headers of the first 20 requests and then stops.
func TestDebugLogPeerStopsAfterTwentyRequests(t *testing.T) {
	rec := capture(t)
	r := New(nil, "Fly-Client-IP").WithDebug(true)
	for i := 0; i < 30; i++ {
		r.ClientIP(request("172.16.0.9:5555", map[string][]string{"X-Forwarded-For": {"203.0.113.5"}, "Authorization": {"Bearer secret"}}))
	}
	if n := rec.count("DEBUG_LOG_PEER"); n != DebugRequests {
		t.Fatalf("%d debug lines, want %d", n, DebugRequests)
	}
	rec.mu.Lock()
	defer rec.mu.Unlock()
	for _, rec := range rec.records {
		rec.Attrs(func(a slog.Attr) bool {
			if strings.Contains(a.Value.String(), "secret") {
				t.Fatalf("a credential header was logged: %s", a)
			}
			return true
		})
	}
	// Off by default.
	off := capture(t)
	New(nil, "").ClientIP(request("172.16.0.9:5555", nil))
	if off.count("DEBUG_LOG_PEER") != 0 {
		t.Fatal("debug logging is on without DEBUG_LOG_PEER")
	}
}
