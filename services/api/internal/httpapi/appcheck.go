package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"hiyall/services/api/internal/appcheck"
	"hiyall/services/api/internal/metrics"
)

// Firebase App Check (APP_CHECK_ENFORCE, internal/appcheck): the app sends an X-Firebase-AppCheck token on every
// request, proving this is the real, unmodified app and not a script holding a stolen sign-in. Off (default): the
// header is ignored. Log: a token is verified when sent and every request counts in hiyall_app_check_total by result
// (valid, missing, invalid, unavailable), nothing is refused. True: a request without a valid token answers 401
// APP_CHECK_REQUIRED (and 503 APP_CHECK_UNAVAILABLE when Firebase's keys cannot be fetched, which is not the
// member's fault). It runs after the probes, the address limit and the version check and before the sign-in check,
// on every route but development login and the legal documents; the realtime socket is checked too.

// AppCheckVerifier is appcheck.Verifier; tests supply their own.
type AppCheckVerifier interface {
	Verify(ctx context.Context, raw string) error
}

var appCheckResults = metrics.NewCounter("hiyall_app_check_total", "App Check tokens on authenticated requests by result: valid, missing, invalid or unavailable (Firebase's keys could not be fetched). Counted in log and true modes.", "result", "mode")

// appCheckExempt is what needs no token: development login and the legal documents (and the probes, which are
// answered before this runs).
func appCheckExempt(path string) bool {
	switch path {
	case "/healthz", "/readyz", "/health/live", "/health/ready", "/dev/session":
		return true
	}
	return strings.HasPrefix(path, "/v1/legal") || strings.HasPrefix(path, "/legal")
}

// checkAppCheck applies the mode to the request and reports whether it may go on; it has answered when not.
func (a *API) checkAppCheck(w http.ResponseWriter, r *http.Request) bool {
	if a.AppCheck == nil || a.AppCheckMode == appcheck.Off || a.AppCheckMode == "" || appCheckExempt(r.URL.Path) {
		return true
	}
	result := "valid"
	if token := r.Header.Get(appcheck.Header); token == "" {
		result = "missing"
	} else if err := a.AppCheck.Verify(r.Context(), token); errors.Is(err, appcheck.ErrUnavailable) {
		result = "unavailable"
	} else if err != nil {
		result = "invalid"
	}
	appCheckResults.Inc(result, string(a.AppCheckMode))
	switch {
	case result == "valid" || a.AppCheckMode != appcheck.Enforce:
		return true
	case result == "unavailable":
		a.failure(w, r, 503, "APP_CHECK_UNAVAILABLE", "App verification is temporarily unavailable")
	default:
		a.failure(w, r, 401, "APP_CHECK_REQUIRED", "Open the Hiyall app to continue")
	}
	return false
}
