package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Own profile and privacy, sessions and blocks: the handlers behind the first rows of the route table (router.go).

func (a *API) getProfile(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	value, err := a.Store.GetProfile(ctx, p.UserID, a.signer(ctx))
	if err != nil {
		a.error(w, r, err)
		return
	}
	w.Header().Set("ETag", strconv.Quote(value.Version))
	a.ok(w, r, value)
}

func (a *API) getPrivacy(w http.ResponseWriter, r *http.Request, p store.Principal) {
	value, err := a.Store.GetPrivacy(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	w.Header().Set("ETag", strconv.Quote(value.Version))
	a.ok(w, r, value)
}

// settingsPatch reads what both PATCH routes need: the quoted If-Match version (428 without one) and the JSON
// object. The per-account edit limit has already been taken by the route table, before the body is read.
func (a *API) settingsPatch(w http.ResponseWriter, r *http.Request) (int64, map[string]json.RawMessage, bool) {
	v, ok := version(w, r)
	if !ok {
		a.failure(w, r, 428, "PRECONDITION_REQUIRED", "A quoted If-Match version is required")
		return 0, nil, false
	}
	body, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return 0, nil, false
	}
	return v, body, true
}

func (a *API) patchProfile(w http.ResponseWriter, r *http.Request, p store.Principal) {
	v, body, ok := a.settingsPatch(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	value, err := a.Store.UpdateProfileFor(ctx, p.UserID, v, body, a.entitlementsFor(ctx, p.UserID), a.signer(ctx))
	if err != nil {
		a.error(w, r, err)
		return
	}
	w.Header().Set("ETag", strconv.Quote(value.Version))
	a.ok(w, r, value)
}

func (a *API) patchPrivacy(w http.ResponseWriter, r *http.Request, p store.Principal) {
	v, body, ok := a.settingsPatch(w, r)
	if !ok {
		return
	}
	value, err := a.Store.UpdatePrivacy(r.Context(), p.UserID, v, body)
	if err != nil {
		a.error(w, r, err)
		return
	}
	w.Header().Set("ETag", strconv.Quote(value.Version))
	a.ok(w, r, value)
}

func (a *API) logout(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	if err := a.Store.RevokeSession(ctx, p, p.SessionID); err != nil {
		a.error(w, r, err)
		return
	}
	a.endSessions(ctx, p.UserID, p.SessionID, "")
	a.ok(w, r, map[string]bool{"revoked": true})
}

func (a *API) revokeOtherSessions(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	count, err := a.Store.RevokeOtherSessions(ctx, p)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.endSessions(ctx, p.UserID, "", p.SessionID)
	a.ok(w, r, map[string]int64{"revoked": count})
}

func (a *API) revokeSession(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("sessionId")
	if err := a.Store.RevokeSession(ctx, p, id); err != nil {
		a.error(w, r, err)
		return
	}
	a.endSessions(ctx, p.UserID, id, "")
	a.ok(w, r, map[string]bool{"revoked": true})
}

// viewProfile is GET /v1/users/{userId}/profile.
func (a *API) viewProfile(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, target := r.Context(), r.PathValue("userId")
	if !a.profileViewAllowed(w, r, p, target) {
		return
	}
	value, err := a.Store.VisibleProfile(ctx, p.UserID, target, a.presence, a.signer(ctx))
	if err != nil {
		a.error(w, r, err)
		return
	}
	// Detailed fields are a Premium feature (or a coin unlock) while plans are enforced (billing.go).
	if err = a.gateProfileDetails(ctx, p.UserID, target, value); err != nil {
		a.error(w, r, err)
		return
	}
	// The profile opened, so this is a visit (a locked card counts; one's own profile, and a request
	// refused above as blocked, in the other age band or not found, do not). A first visit shows up in
	// this response's count too. Failing to record it never fails the request.
	if !a.visitWrites.allow(p.UserID + ">" + target) {
		// This viewer's visit to this profile was already written within the hour.
	} else if first, err := a.Store.RecordProfileVisit(ctx, p.UserID, target); err != nil {
		slog.Warn("profile visit not recorded", "requestId", ctx.Value(requestIDKey{}))
	} else if first {
		a.visitNotice(ctx, p.UserID, target)
		if stats, ok := value["socialStats"].(domain.SocialStats); ok {
			stats.Visitors++
			value["socialStats"] = stats
		}
	}
	a.ok(w, r, value)
}

// setBlock is POST (block) and DELETE (unblock) /v1/users/{userId}/block.
func (a *API) setBlock(w http.ResponseWriter, r *http.Request, p store.Principal) {
	on := r.Method == http.MethodPost
	if err := a.Store.SetBlock(r.Context(), p.UserID, r.PathValue("userId"), on); err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]bool{"blocked": on})
}
