package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/metrics"
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
//	POST   /v1/me/deletion   {confirmUsername[, appleAuthorizationCode | appleCodeUnavailable:true]}    403 REAUTH_REQUIRED when the sign-in is older than 5 minutes
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
	var req domain.DeletionRequest
	if err == nil {
		req, err = domain.ParseDeletionBody(body)
	}
	if err != nil {
		a.error(w, r, err)
		return
	}
	confirm, appleCode := req.Confirm, req.AppleCode
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
	manualApple := false
	if appleCode != "" {
		if err = a.revokeApple(ctx, p.UserID, appleCode); err != nil {
			a.error(w, r, err)
			return
		}
	} else if req.AppleCodeUnavailable {
		// The app re-authenticated and could not get a code (the member signed in with Google again, or the web
		// has none). The member must still be able to leave, so the deletion goes ahead and the Apple
		// authorization is queued for an operator to revoke by hand (apple_revocations, status 'manual'; the
		// console lists it). Only an account that holds an Apple authorization gets a row.
		has, herr := a.Store.HasAppleAuthorization(ctx, p.UserID)
		if herr != nil {
			a.error(w, r, herr)
			return
		}
		manualApple = has
	} else if a.Apple != nil {
		// The server knows how the account signs in: with Apple (or Apple linked), deleting without the code
		// would leave the Apple authorization alive (App Store guideline 5.1.1(v)), so it is refused rather
		// than left to the app (audit API-8). The app re-authenticates with Apple and retries with the code.
		has, herr := a.Store.HasAppleAuthorization(ctx, p.UserID)
		if herr != nil {
			a.error(w, r, herr)
			return
		}
		if has {
			a.error(w, r, ErrAppleCodeRequired)
			return
		}
	}
	var state store.DeletionState
	if manualApple {
		state, err = a.Store.ScheduleDeletionManualApple(ctx, p.UserID)
		if err == nil {
			appleManualRevocations.Inc()
			slog.Warn("account deletion scheduled without Apple revocation: queued for an operator", "userId", p.UserID)
		}
	} else {
		state, err = a.Store.ScheduleDeletion(ctx, p.UserID)
	}
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
	// werr is the first error writing to the client: the client went away (or its connection broke), which
	// is not the server's failure and does not give the daily export back.
	werr error
}

func (l *lazyResponse) Write(p []byte) (int, error) {
	if !l.started {
		l.started = true
		l.start()
	}
	n, err := l.w.Write(p)
	if err != nil && l.werr == nil {
		l.werr = err
	}
	return n, err
}

// export streams the member's data as a JSON attachment. The claim on the day's one export is taken first
// and handed back if the document could not be finished, so a failure never costs the member their slot.
func (a *API) export(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	// An export holds a pooled database connection for as long as it streams (up to two minutes), so a node
	// builds only EXPORT_CONCURRENCY of them at once; a member who finds every slot taken is told to retry and
	// keeps their daily export, because the slot is taken before the claim (audit API-9).
	release, ok := a.acquireExportSlot()
	if !ok {
		exportBusy.Inc()
		w.Header().Set("Retry-After", "30")
		a.failure(w, r, 503, "EXPORT_BUSY", "Lots of people are exporting their data right now. Try again in a minute; this did not use up today’s export.")
		return
	}
	defer release()
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
	if out.werr != nil {
		// The client went away mid-download. The work was done and the slot was used, so the claim stays:
		// otherwise starting and abandoning exports would be a free way to hold database connections.
		slog.Info("export abandoned by the client", "requestId", ctx.Value(requestIDKey{}))
		return
	}
	a.Store.ReleaseExport(ctx, p.UserID, previous)
	if !out.started {
		a.error(w, r, err)
		return
	}
	slog.Error("export incomplete", "requestId", ctx.Value(requestIDKey{}), "reason", scrubURLs(err.Error()))
}

// appleManualRevocations counts deletions scheduled with appleCodeUnavailable for an account that holds an Apple
// authorization: each is a row an operator must revoke by hand in the console (Apple revocations).
var appleManualRevocations = metrics.NewCounter("hiyall_apple_manual_revocations_total", "Account deletions scheduled without a Sign in with Apple code; queued for an operator.")

// ErrAppleCodeRequired is 422 APPLE_CODE_REQUIRED: this account signs in with Apple, so deleting it needs the
// one-time authorization code from a fresh Sign in with Apple.
var ErrAppleCodeRequired = &domain.PolicyError{Status: 422, Code: "APPLE_CODE_REQUIRED", Message: "To delete this account, confirm with Apple first. Sign in with Apple again, then retry the deletion."}

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
