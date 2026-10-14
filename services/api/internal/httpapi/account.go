package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// recentlyAuthenticated is whether the session's interactive sign-in (Firebase auth_time) is within
// domain.ReauthWindow. A session without one is trusted only in development authentication.
func (a *API) recentlyAuthenticated(ctx context.Context, p store.Principal) (bool, error) {
	at, known, err := a.Store.SessionAuthTime(ctx, p.SessionID)
	if err != nil {
		return false, err
	}
	if !known {
		return a.DevAuth, nil
	}
	return time.Since(at) <= domain.ReauthWindow, nil
}

// Account deletion and the data export (docs/api/22-account-deletion-and-export.md).
//
//	GET    /v1/me/deletion   -> {pending, scheduledAt, dueAt, canCancel}   (also for a member in the grace period)
//	POST   /v1/me/deletion   {confirmUsername}    403 REAUTH_REQUIRED when the sign-in is older than 5 minutes
//	DELETE /v1/me/deletion   cancels during the grace period (409 DELETION_WINDOW_CLOSED after it, 404 when none is scheduled)
//	GET    /v1/me/export     a JSON download, once per 24 hours (429 RATE_LIMITED with Retry-After)
func (a *API) deletionStatus(w http.ResponseWriter, r *http.Request, p store.Principal) {
	state, err := a.Store.DeletionStatus(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, state)
}

func (a *API) cancelDeletion(w http.ResponseWriter, r *http.Request, p store.Principal) {
	state, err := a.Store.CancelDeletion(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, state)
}

func (a *API) scheduleDeletion(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	body, err := decode(w, r)
	var confirm, appleCode string
	if err == nil {
		confirm, appleCode, err = domain.ParseDeletion(body)
	}
	if err != nil {
		a.error(w, r, err)
		return
	}
	username, err := a.Store.Username(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if confirm != username {
		a.error(w, r, &domain.ValidationError{Field: "confirmUsername", Message: "that is not your username"})
		return
	}
	recent, err := a.recentlyAuthenticated(ctx, p)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if !recent {
		a.error(w, r, domain.ErrReauthRequired)
		return
	}
	// Sign in with Apple: the app re-authenticated with Apple and sent the one-time authorization code. It
	// is exchanged and revoked before the deletion is scheduled, so a failure leaves the account as it was
	// and the member can try again (App Store guideline 5.1.1(v)).
	if appleCode != "" {
		if err = a.revokeApple(ctx, p.UserID, appleCode); err != nil {
			a.error(w, r, err)
			return
		}
	}
	state, err := a.Store.ScheduleDeletion(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	// The database already refuses every session; this ends the sockets this node holds now (the other
	// nodes were told through the bus, and every socket checks its session at each heartbeat anyway).
	a.endSessions(ctx, p.UserID, "", "")
	a.ok(w, r, state)
}

// lazyResponse sends the download headers only when the first byte of the document is written, so a failure
// before that can still be answered as an ordinary error.
type lazyResponse struct {
	w       http.ResponseWriter
	start   func()
	started bool
}

func (l *lazyResponse) Write(p []byte) (int, error) {
	if !l.started {
		l.started = true
		l.start()
	}
	return l.w.Write(p)
}

// export streams the member's data as a JSON attachment. The claim on the day's one export is taken first
// and handed back if the document could not be finished, so a failure never costs the member their slot.
func (a *API) export(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	previous, err := a.Store.ClaimExport(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	// A large export outlives the 10 second request deadline and the server's write timeout; it is still
	// bounded, and it stops when the client goes away (the write fails).
	exportCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer cancel()
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(2 * time.Minute))
	out := &lazyResponse{w: w, start: func() {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="hiyall-data-`+time.Now().UTC().Format("2006-01-02")+`.json"`)
		w.WriteHeader(http.StatusOK)
	}}
	sign := func(key string) string {
		if a.Media == nil || key == "" {
			return ""
		}
		link, err := a.Media.PresignGet(exportCtx, key, domain.ExportURLLifetime)
		if err != nil {
			return ""
		}
		return link
	}
	complete, err := a.Store.ExportAccount(exportCtx, p.UserID, out, store.ExportOptions{Sign: sign})
	if complete {
		return
	}
	a.Store.ReleaseExport(ctx, p.UserID, previous)
	if !out.started {
		a.error(w, r, err)
		return
	}
	slog.Error("export incomplete", "requestId", ctx.Value(requestIDKey{}), "reason", scrubURLs(err.Error()))
}

// AppleRevoker revokes a member's Sign in with Apple authorization at deletion time (identity.AppleRevoker).
// RevokeAuthorizationCode returns a sealed refresh token to queue when Apple accepted the code but the
// revoke did not complete.
type AppleRevoker interface {
	RevokeAuthorizationCode(ctx context.Context, code string) (queued []byte, err error)
}

func (a *API) revokeApple(ctx context.Context, user, code string) error {
	if a.Apple == nil {
		slog.Warn("Sign in with Apple authorization not revoked: APPLE_* is not configured")
		return nil
	}
	queued, err := a.Apple.RevokeAuthorizationCode(ctx, code)
	if err != nil {
		slog.Error("Sign in with Apple authorization not revoked", "reason", err.Error())
		return &domain.PolicyError{Status: 503, Code: "APPLE_REVOKE_FAILED", Message: "We couldn’t reach Apple to disconnect Sign in with Apple. Try again in a moment."}
	}
	if queued != nil {
		return a.Store.QueueAppleRevocation(ctx, user, queued)
	}
	return nil
}
