package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// onboardingExempt lists what an account that has not finished onboarding may
// reach: its own profile and privacy (to choose a name and username), the
// onboarding endpoints, the username check, and session management. Everything
// else, including /v1/realtime, waits until onboarding is complete.
func onboardingExempt(method, path string) bool {
	switch path {
	case "/v1/me/profile", "/v1/me/privacy":
		return method == "GET" || method == "PATCH"
	case "/v1/me/deletion":
		// Someone who signed up by mistake can delete the account before finishing setup.
		return true
	case "/v1/me/onboarding":
		return method == "GET"
	case "/v1/me/onboarding/complete":
		return method == "POST"
	}
	if strings.HasPrefix(path, "/v1/auth/") {
		return true
	}
	if rest, ok := strings.CutPrefix(path, "/v1/usernames/"); ok && method == "GET" {
		name, tail, found := strings.Cut(rest, "/")
		return found && name != "" && tail == "availability"
	}
	return false
}

// failOnboarding answers 403 ONBOARDING_REQUIRED.
func (a *API) failOnboarding(w http.ResponseWriter, r *http.Request) {
	a.error(w, r, domain.ErrOnboardingRequired)
}

// authFailure answers a failed sign-in check. A policy refusal, such as an
// unverified email, is shown as is; an unknown failure is an outage, not a sign-out.
func (a *API) authFailure(w http.ResponseWriter, r *http.Request, err error) {
	var policy *domain.PolicyError
	switch {
	case errors.Is(err, domain.ErrUnauthorized):
		a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in to continue")
	case errors.As(err, &policy):
		a.failure(w, r, policy.Status, policy.Code, policy.Message)
	default:
		a.failure(w, r, 503, "AUTH_UNAVAILABLE", "Authentication is temporarily unavailable")
	}
}

// onboardingRoute serves the first-run endpoints. They work before and after
// onboarding is complete.
//
//	GET  /v1/me/onboarding                       -> {completed, completedAt, termsVersion}
//	POST /v1/me/onboarding/complete              {birthDate, termsVersion}
//	GET  /v1/usernames/{username}/availability   -> {available}
func (a *API) onboardingRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	n := len(parts)
	if n < 3 || parts[0] != "v1" {
		return false
	}
	ctx := r.Context()
	switch {
	case n == 3 && parts[1] == "me" && parts[2] == "onboarding" && r.Method == "GET":
		state, err := a.Store.GetOnboarding(ctx, p.UserID)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.ok(w, r, onboardingBody(state))
	case n == 4 && parts[1] == "me" && parts[2] == "onboarding" && parts[3] == "complete" && r.Method == "POST":
		body, err := decode(w, r)
		var birth time.Time
		if err == nil {
			// The birth date is checked here and handed to the store, which keeps it privately
			// (member_ages). It is never echoed, logged or put in an event.
			birth, err = domain.ParseOnboardingCompletion(body, time.Now())
		}
		if err != nil {
			a.error(w, r, err)
			return true
		}
		state, err := a.Store.CompleteOnboarding(ctx, p.UserID, birth)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.ok(w, r, onboardingBody(state))
	case n == 4 && parts[1] == "usernames" && parts[3] == "availability" && r.Method == "GET":
		if !a.allowSearch(p.UserID) {
			w.Header().Set("Retry-After", "2")
			a.failure(w, r, 429, "RATE_LIMITED", "Try again shortly")
			return true
		}
		if err := domain.ValidateUsername(parts[2]); err != nil {
			a.error(w, r, err)
			return true
		}
		available, err := a.Store.UsernameAvailable(ctx, p.UserID, parts[2])
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.ok(w, r, map[string]bool{"available": available})
	default:
		return false
	}
	return true
}

func onboardingBody(state store.Onboarding) map[string]any {
	var completedAt any
	if state.CompletedAt != nil {
		completedAt = state.CompletedAt.UTC()
	}
	return map[string]any{"completed": state.Completed, "completedAt": completedAt, "termsVersion": domain.TermsVersion}
}
