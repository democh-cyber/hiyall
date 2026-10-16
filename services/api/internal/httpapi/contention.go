package httpapi

import (
	"errors"
	"net/http"

	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

var dbContention = metrics.NewCounter("hiyall_db_contention_total", "Requests answered 503 because the database asked to retry: lock timeout (55P03), statement timeout or cancel (57014), deadlock (40P01) or serialization failure (40001).", "code")

var statementTimeouts = metrics.NewCounter("hiyall_db_statement_timeouts_total", "Requests whose database statement ran past its timeout (57014), by route pattern. Alert on any: a slow query or a missing index.", "route")

// contended answers a database contention error (store.ContentionCode) with 503 TEMPORARILY_UNAVAILABLE and
// Retry-After: 1, and counts it. It reports whether err was one. These are the database being busy, not a
// server fault, so they are neither logged as errors nor sent to the error tracker.
func (a *API) contended(w http.ResponseWriter, r *http.Request, err error) bool {
	code := store.ContentionCode(err)
	if code == "" {
		return false
	}
	dbContention.Inc(code)
	if code == "57014" {
		// A statement that ran past its timeout is a slow query (or a missing index), not ordinary contention:
		// count it on its own and tell the error tracker, once per request (round-3 audit).
		statementTimeouts.Inc(routePattern(r.URL.Path))
		a.report(r.Context(), ErrorReport{Method: r.Method, Route: routePattern(r.URL.Path), Err: errors.New("database statement timeout (57014) on " + routePattern(r.URL.Path))})
	}
	w.Header().Set("Retry-After", "1")
	a.failure(w, r, 503, "TEMPORARILY_UNAVAILABLE", "Hiyall is busy. Try again in a moment")
	return true
}
