package httpapi

import (
	"net/http"

	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

var dbContention = metrics.NewCounter("hiyall_db_contention_total", "Requests answered 503 because the database asked to retry: lock timeout (55P03), statement timeout or cancel (57014), deadlock (40P01) or serialization failure (40001).", "code")

// contended answers a database contention error (store.ContentionCode) with 503 TEMPORARILY_UNAVAILABLE and
// Retry-After: 1, and counts it. It reports whether err was one. These are the database being busy, not a
// server fault, so they are neither logged as errors nor sent to the error tracker.
func (a *API) contended(w http.ResponseWriter, r *http.Request, err error) bool {
	code := store.ContentionCode(err)
	if code == "" {
		return false
	}
	dbContention.Inc(code)
	w.Header().Set("Retry-After", "1")
	a.failure(w, r, 503, "TEMPORARILY_UNAVAILABLE", "Hiyall is busy. Try again in a moment")
	return true
}
