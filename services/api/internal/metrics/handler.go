package metrics

import (
	"crypto/subtle"
	"net/http"
	"runtime"
	"strings"
	"time"
)

var started = time.Now()

func init() {
	NewGaugeFunc("go_goroutines", "Number of goroutines.", func() float64 { return float64(runtime.NumGoroutine()) })
	NewGaugeFunc("go_memstats_heap_alloc_bytes", "Bytes of allocated heap objects.", func() float64 {
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		return float64(m.HeapAlloc)
	})
	NewCounterFunc("go_gc_cycles_total", "Completed GC cycles.", func() float64 {
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		return float64(m.NumGC)
	})
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
