package metrics

import (
	"crypto/subtle"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"time"
)

var started = time.Now()

// memStats is read at most once a second however many series a scrape asks for: ReadMemStats briefly
// stops the world.
var memStats struct {
	mu   sync.Mutex
	at   time.Time
	last runtime.MemStats
}

func mem() runtime.MemStats {
	memStats.mu.Lock()
	defer memStats.mu.Unlock()
	if time.Since(memStats.at) > time.Second {
		runtime.ReadMemStats(&memStats.last)
		memStats.at = time.Now()
	}
	return memStats.last
}

// Go runtime series, so a memory or GC problem shows before the OOM kill. GOMEMLIMIT (see
// docs/deployment/10-deploy-guide.md) is what keeps the heap under the machine's memory.
func init() {
	NewGaugeFunc("go_goroutines", "Number of goroutines.", func() float64 { return float64(runtime.NumGoroutine()) })
	NewGaugeFunc("go_memstats_heap_alloc_bytes", "Bytes of allocated heap objects.", func() float64 { return float64(mem().HeapAlloc) })
	NewGaugeFunc("go_memstats_heap_inuse_bytes", "Bytes in in-use heap spans.", func() float64 { return float64(mem().HeapInuse) })
	NewGaugeFunc("go_memstats_heap_objects", "Number of allocated heap objects.", func() float64 { return float64(mem().HeapObjects) })
	NewGaugeFunc("go_memstats_sys_bytes", "Bytes of memory obtained from the OS.", func() float64 { return float64(mem().Sys) })
	NewGaugeFunc("go_memstats_next_gc_bytes", "Heap size at which the next GC cycle starts.", func() float64 { return float64(mem().NextGC) })
	NewGaugeFunc("go_memstats_stack_inuse_bytes", "Bytes in stack spans.", func() float64 { return float64(mem().StackInuse) })
	NewCounterFunc("go_gc_cycles_total", "Completed GC cycles.", func() float64 { return float64(mem().NumGC) })
	NewCounterFunc("go_gc_pause_seconds_total", "Total time the world was stopped by GC.", func() float64 { return float64(mem().PauseTotalNs) / 1e9 })
	NewCounterFunc("go_memstats_alloc_bytes_total", "Bytes allocated over the process lifetime.", func() float64 { return float64(mem().TotalAlloc) })
	NewGaugeFunc("go_gomaxprocs", "GOMAXPROCS.", func() float64 { return float64(runtime.GOMAXPROCS(0)) })
	NewGaugeFunc("hiyall_process_uptime_seconds", "Seconds since the process started.", func() float64 { return time.Since(started).Seconds() })
}

// Handler serves the registry. With a non-empty token the request must carry "Authorization: Bearer <token>"
// (compared in constant time); the metrics listener must still never be exposed on a public address.
func Handler(r *Registry, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodGet && req.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if token != "" {
			got := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
			if !strings.HasPrefix(req.Header.Get("Authorization"), "Bearer ") || subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				w.Header().Set("WWW-Authenticate", `Bearer realm="metrics"`)
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}
		w.Header().Set("Content-Type", ContentType)
		w.Header().Set("Cache-Control", "no-store")
		if req.Method == http.MethodGet {
			_, _ = r.WriteTo(w)
		}
	})
}

// Server returns the separate metrics listener: only /metrics, with timeouts. Serve it with ListenAndServe.
func Server(addr string, r *Registry, token string) *http.Server {
	mux := http.NewServeMux()
	mux.Handle("/metrics", Handler(r, token))
	return &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192}
}
