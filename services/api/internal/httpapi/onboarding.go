package httpapi

import (
	"errors"
	"log/slog"
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
	case "/v1/me/onboarding/complete", "/v1/me/onboarding/age":
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
//	POST /v1/me/onboarding/age                   {birthDate} -> {allowed:true}; 403 AGE_REQUIREMENT_NOT_MET records the
//	                                             refusal against the sign-in identity, 403 AGE_GATE_COOLDOWN for 7 days after
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
	case n == 4 && parts[1] == "me" && parts[2] == "onboarding" && parts[3] == "age" && r.Method == "POST":
		// The age step sends the date as soon as it is chosen, so a date under the minimum is refused (and
		// recorded) by the server, not just by a disabled button that can be re-picked.
		body, err := decode(w, r)
		if err == nil {
			err = a.ageGate(r, p, func() error {
				_, e := domain.ParseBirthDate(body, time.Now())
				return e
			})
		}
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.ok(w, r, map[string]bool{"allowed": true})
	case n == 4 && parts[1] == "me" && parts[2] == "onboarding" && parts[3] == "complete" && r.Method == "POST":
		body, err := decode(w, r)
		var birth time.Time
		if err == nil {
			// The birth date is checked here and handed to the store, which keeps it privately
			// (member_ages). It is never echoed, logged or put in an event.
			err = a.ageGate(r, p, func() (e error) {
				birth, e = domain.ParseOnboardingCompletion(body, time.Now())
				return e
			})
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

// ageGate runs a date check for an account that has not finished onboarding. An identity refused in the last 7
// days is refused again without looking at the date (AGE_GATE_COOLDOWN); a date under the minimum is refused
// and remembered against the identity. Failing to record it never turns the refusal into a pass.
func (a *API) ageGate(r *http.Request, p store.Principal, check func() error) error {
	ctx := r.Context()
	if !p.Onboarded {
		blocked, err := a.Store.AgeGateBlocked(ctx, p.UserID)
		if err != nil {
			return err
		}
		if blocked {
			return domain.ErrAgeGateCooldown
		}
	}
	err := check()
	if errors.Is(err, domain.ErrAgeRequirement) && !p.Onboarded {
		if e := a.Store.RecordAgeRefusal(ctx, p.UserID); e != nil {
			slog.Warn("age refusal not recorded", "requestId", ctx.Value(requestIDKey{}))
		}
	}
	return err
}

func onboardingBody(state store.Onboarding) map[string]any {
	var completedAt any
	if state.CompletedAt != nil {
		completedAt = state.CompletedAt.UTC()
	}
	return map[string]any{"completed": state.Completed, "completedAt": completedAt, "termsVersion": domain.TermsVersion}
}
