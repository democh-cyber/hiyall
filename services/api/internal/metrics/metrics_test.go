package metrics

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func scrape(t *testing.T, r *Registry) string {
	t.Helper()
	var sb strings.Builder
	if _, err := r.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	return sb.String()
}

func TestExpositionFormat(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("demo_requests_total", "Requests with a \"quote\" and a\nnewline.", "route", "class")
	c.Inc("/v1/x", "2xx")
	c.Add(2, "/v1/x", "2xx")
	c.Inc("/v1/a\"b\\c\nd", "5xx")
	g := r.NewGauge("demo_in_flight", "In flight.")
	g.Inc()
	g.Inc()
	g.Dec()
	r.NewGaugeFunc("demo_pool", "Pool.", func() float64 { return 7 })
	h := r.NewHistogram("demo_seconds", "Latency.", []float64{1, 0.1}, "route")
	h.Observe(0.05, "/a")
	h.Observe(0.5, "/a")
	h.Observe(3, "/a")
	got := scrape(t, r)
	want := `# HELP demo_in_flight In flight.
# TYPE demo_in_flight gauge
demo_in_flight 1
# HELP demo_pool Pool.
# TYPE demo_pool gauge
demo_pool 7
# HELP demo_requests_total Requests with a "quote" and a\nnewline.
# TYPE demo_requests_total counter
demo_requests_total{route="/v1/a\"b\\c\nd",class="5xx"} 1
demo_requests_total{route="/v1/x",class="2xx"} 3
# HELP demo_seconds Latency.
# TYPE demo_seconds histogram
demo_seconds_bucket{route="/a",le="0.1"} 1
demo_seconds_bucket{route="/a",le="1"} 2
demo_seconds_bucket{route="/a",le="+Inf"} 3
demo_seconds_sum{route="/a"} 3.55
demo_seconds_count{route="/a"} 3
`
	if !strings.Contains(got, want) {
		t.Fatalf("exposition mismatch.\n--- got ---\n%s\n--- want (substring) ---\n%s", got, want)
	}
	// Stable order: scraping twice gives the same text.
	if again := scrape(t, r); again != got {
		t.Fatal("exposition is not deterministic")
	}
}

func TestRegistrationIsGetOrCreateButRejectsConflicts(t *testing.T) {
	r := NewRegistry()
	a := r.NewCounter("same_total", "h", "x")
	b := r.NewCounter("same_total", "h", "x")
	a.Inc("1")
	b.Inc("1")
	if !strings.Contains(scrape(t, r), `same_total{x="1"} 2`) {
		t.Fatal("two handles to one metric must share state")
	}
	for name, fn := range map[string]func(){
		"type":   func() { r.NewGauge("same_total", "h", "x") },
		"labels": func() { r.NewCounter("same_total", "h", "y") },
		"name":   func() { r.NewCounter("bad name", "h") },
		"label":  func() { r.NewCounter("fine_total", "h", "le") },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatalf("%s conflict did not panic", name)
				}
			}()
			fn()
		}()
	}
}

func TestCardinalityGuardFoldsIntoOverflow(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("loud_total", "h", "id")
	for i := 0; i < MaxSeries*3; i++ {
		c.Inc(fmt.Sprintf("user-%d", i))
	}
	out := scrape(t, r)
	series := strings.Count(out, "loud_total{")
	if series != MaxSeries+1 {
		t.Fatalf("%d series, want at most %d plus one overflow", series, MaxSeries)
	}
	if !strings.Contains(out, fmt.Sprintf(`loud_total{id="overflow"} %d`, MaxSeries*2)) {
		t.Fatalf("overflow series missing or wrong:\n%s", out)
	}
	if !strings.Contains(out, fmt.Sprintf(`hiyall_metrics_overflow_total{metric="loud_total"} %d`, MaxSeries*2)) {
		t.Fatalf("overflow counter missing:\n%s", out)
	}
	// Existing series keep counting after the limit is hit.
	c.Inc("user-0")
	if !strings.Contains(scrape(t, r), `loud_total{id="user-0"} 2`) {
		t.Fatal("an existing series stopped counting")
	}
}

func TestConcurrentUse(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("par_total", "h", "k")
	h := r.NewHistogram("par_seconds", "h", nil, "k")
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				c.Inc("a")
				h.Observe(0.01, "a")
				if j%100 == 0 {
					scrape(t, r)
				}
			}
		}()
	}
	wg.Wait()
	out := scrape(t, r)
	if !strings.Contains(out, `par_total{k="a"} 8000`) || !strings.Contains(out, `par_seconds_count{k="a"} 8000`) {
		t.Fatalf("lost updates:\n%s", out)
	}
}

func TestHandlerTokenAndMethod(t *testing.T) {
	r := NewRegistry()
	r.NewCounter("t_total", "h").Inc()
	open := Handler(r, "")
	locked := Handler(r, "s3cret-token")
	do := func(h http.Handler, method, auth string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "/metrics", nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	if rec := do(open, "GET", ""); rec.Code != 200 || rec.Header().Get("Content-Type") != ContentType || !strings.Contains(rec.Body.String(), "t_total 1") {
		t.Fatalf("open handler: %d %q", rec.Code, rec.Body.String())
	}
	for _, auth := range []string{"", "Bearer wrong", "s3cret-token", "Basic s3cret-token", "Bearer "} {
		if rec := do(locked, "GET", auth); rec.Code != 401 || strings.Contains(rec.Body.String(), "t_total") {
			t.Fatalf("auth %q got %d", auth, rec.Code)
		}
	}
	if rec := do(locked, "GET", "Bearer s3cret-token"); rec.Code != 200 {
		t.Fatalf("valid token got %d", rec.Code)
	}
	if rec := do(open, "POST", ""); rec.Code != 405 {
		t.Fatalf("POST got %d", rec.Code)
	}
}

func TestDefaultRegistryHasRuntimeSeries(t *testing.T) {
	out := scrape(t, Default)
	for _, name := range []string{"go_goroutines", "go_memstats_heap_alloc_bytes", "hiyall_process_uptime_seconds"} {
		if !strings.Contains(out, "# TYPE "+name+" ") {
			t.Fatalf("%s missing", name)
		}
	}
}

func TestGoRuntimeSeriesAreRegistered(t *testing.T) {
	var sb strings.Builder
	if _, err := Default.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"go_goroutines", "go_memstats_heap_alloc_bytes", "go_memstats_heap_inuse_bytes", "go_memstats_sys_bytes", "go_memstats_next_gc_bytes",
		"go_gc_cycles_total", "go_gc_pause_seconds_total", "go_gomaxprocs", "hiyall_process_uptime_seconds"} {
		if !strings.Contains(sb.String(), "\n"+name+" ") {
			t.Errorf("%s missing from the registry", name)
		}
	}
}

func TestPresetCreatesAZeroSeriesWithoutCounting(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("preset_total", "h", "result")
	c.Preset("flagged")
	u := r.NewCounter("preset_plain_total", "h")
	u.Preset()
	var sb strings.Builder
	if _, err := r.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`preset_total{result="flagged"} 0`, "preset_plain_total 0"} {
		if !strings.Contains(sb.String(), want) {
			t.Errorf("missing %q in:\n%s", want, sb.String())
		}
	}
	c.Inc("flagged")
	sb.Reset()
	_, _ = r.WriteTo(&sb)
	if !strings.Contains(sb.String(), `preset_total{result="flagged"} 1`) {
		t.Errorf("an increment after Preset must count from zero:\n%s", sb.String())
	}
}
