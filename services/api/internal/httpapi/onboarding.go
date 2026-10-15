package httpapi

import (
	"errors"
	"log/slog"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

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
	case a.contended(w, r, err):
	default:
		a.failure(w, r, 503, "AUTH_UNAVAILABLE", "Authentication is temporarily unavailable")
	}
}

// The first-run endpoints work before and after onboarding is complete (router.go marks them preOnboarding).
//
//	GET  /v1/me/onboarding                       -> {completed, completedAt, termsVersion}
//	POST /v1/me/onboarding/age                   {birthDate} -> {allowed:true}; 403 AGE_REQUIREMENT_NOT_MET records the
//	                                             refusal against the sign-in identity, 403 AGE_GATE_COOLDOWN for 7 days after
//	POST /v1/me/onboarding/complete              {birthDate, termsVersion}
//	GET  /v1/usernames/{username}/availability   -> {available}
func (a *API) getOnboarding(w http.ResponseWriter, r *http.Request, p store.Principal) {
	state, err := a.Store.GetOnboarding(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, onboardingBody(state))
}

// onboardingAge checks a declared date. The age step sends the date as soon as it is chosen, so a date under
// the minimum is refused (and recorded) by the server, not just by a disabled button that can be re-picked.
func (a *API) onboardingAge(w http.ResponseWriter, r *http.Request, p store.Principal) {
	body, err := decode(w, r)
	if err == nil {
		err = a.ageGate(r, p, func() error {
			_, e := domain.ParseBirthDate(body, time.Now())
			return e
		})
	}
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]bool{"allowed": true})
}

func (a *API) onboardingComplete(w http.ResponseWriter, r *http.Request, p store.Principal) {
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
		return
	}
	state, err := a.Store.CompleteOnboarding(r.Context(), p.UserID, birth)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, onboardingBody(state))
}

// usernameAvailability is limited per account like search (the route table takes the token).
func (a *API) usernameAvailability(w http.ResponseWriter, r *http.Request, p store.Principal) {
	name := r.PathValue("username")
	if err := domain.ValidateUsername(name); err != nil {
		a.error(w, r, err)
		return
	}
	available, err := a.Store.UsernameAvailable(r.Context(), p.UserID, name)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]bool{"available": available})
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
