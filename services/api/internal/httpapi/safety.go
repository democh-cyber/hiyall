package httpapi

import (
	"encoding/json"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/store"
)

// wakeFrom pushes to recipient about actor's action. Whether that is allowed (mutes,
// restricts, blocks, age band, the member's own choices) is decided by the push
// dispatcher on a worker, not here.
func (a *API) wakeFrom(kind, actor, recipient string) {
	a.wake(push.Notice{Kind: kind, Actor: actor, Recipient: recipient})
}

// isID accepts only canonical ids (domain.IsID); every id from a path, query or body goes through it.
func isID(value string) bool { return domain.IsID(value) }

func controlKey(c domain.Control) (time.Time, string) { return c.Since, c.User.UserID }
func reportKey(r domain.Report) (time.Time, string)   { return r.CreatedAt, r.ReportID }

// Mute, restrict, per-chat mute, the control lists and reports. Nothing stored here is visible to the person
// it is about.
//
//	POST|DELETE /v1/users/{id}/mute           {until?}
//	POST|DELETE /v1/users/{id}/restrict
//	POST|DELETE /v1/conversations/{id}/mute   {until?}
//	GET         /v1/me/blocked|muted|restricted
//	POST        /v1/reports
//	GET         /v1/me/reports

// muteUntil reads the optional {until}; a POST with no body mutes indefinitely.
func (a *API) muteUntil(w http.ResponseWriter, r *http.Request) (*time.Time, bool) {
	if r.ContentLength == 0 {
		return nil, true
	}
	raw, err := decode(w, r)
	if err == nil {
		var value *time.Time
		if value, err = domain.ParseMuteUntil(raw, time.Now()); err == nil {
			return value, true
		}
	}
	a.error(w, r, err)
	return nil, false
}

// setUserControl is POST (on) and DELETE (off) for /v1/users/{userId}/mute and /restrict. Turning one on takes
// the per-account graph limit in the route table.
func setUserControl(control, key string) handlerFunc {
	return func(a *API, w http.ResponseWriter, r *http.Request, p store.Principal) {
		on := r.Method == http.MethodPost
		var value *time.Time
		if on && control == "mute" {
			var ok bool
			if value, ok = a.muteUntil(w, r); !ok {
				return
			}
		}
		if err := a.Store.SetControl(r.Context(), p.UserID, r.PathValue("userId"), control, on, value); err != nil {
			a.error(w, r, err)
			return
		}
		// Own devices refresh the profile and chat list; the target learns nothing.
		a.signal(r.Context(), "inbox", nil, p.UserID)
		a.ok(w, r, map[string]any{key: on, "until": value})
	}
}

func (a *API) setConversationMute(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("conversationId")
	on := r.Method == http.MethodPost
	var value *time.Time
	if on {
		var ok bool
		if value, ok = a.muteUntil(w, r); !ok {
			return
		}
	}
	if err := a.Store.SetConversationMute(ctx, p.UserID, id, on, value); err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "inbox", map[string]string{"conversationId": id}, p.UserID)
	a.ok(w, r, map[string]any{"muted": on, "until": value})
}

// controlList is GET /v1/me/blocked, /muted and /restricted.
func controlList(kind string) handlerFunc {
	return func(a *API, w http.ResponseWriter, r *http.Request, p store.Principal) {
		ctx := r.Context()
		paged(a, w, r, p, kind, func(pg page) ([]domain.Control, error) {
			return a.Store.ListControls(ctx, p.UserID, kind, pg.before, pg.id, pg.limit, a.signer(ctx))
		}, controlKey, nil)
	}
}

func (a *API) myReports(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	paged(a, w, r, p, "reports", func(pg page) ([]domain.Report, error) {
		return a.Store.ListReports(ctx, p.UserID, pg.before, pg.id, pg.limit)
	}, reportKey, nil)
}

func (a *API) createReport(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return
	}
	data, _ := json.Marshal(raw)
	report, err := domain.ParseReport(data)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if !a.reports.allow(p.UserID) {
		w.Header().Set("Retry-After", "60")
		a.failure(w, r, 429, "RATE_LIMITED", "You’ve sent a lot of reports. Try again in a minute.")
		return
	}
	value, created, err := a.Store.CreateReport(ctx, p.UserID, report)
	if err != nil {
		a.error(w, r, err)
		return
	}
	blocked := value.Blocked
	if blocked {
		a.signal(ctx, "inbox", nil, p.UserID)
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	a.write(w, r, status, map[string]any{"success": true, "data": map[string]any{"report": value, "duplicate": !created, "blocked": blocked}})
}
