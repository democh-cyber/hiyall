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

// safetyRoute serves mute, restrict, per-chat mute, the control lists and
// reports. Nothing it stores is visible to the person it is about.
//
//	POST|DELETE /v1/users/{id}/mute           {until?}
//	POST|DELETE /v1/users/{id}/restrict
//	POST|DELETE /v1/conversations/{id}/mute   {until?}
//	GET         /v1/me/blocked|muted|restricted
//	POST        /v1/reports
//	GET         /v1/me/reports
func (a *API) safetyRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n, method := len(parts), r.Method
	if n < 2 || parts[0] != "v1" {
		return false
	}
	// until is optional; a POST with no body mutes indefinitely.
	until := func() (*time.Time, bool) {
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
	switch {
	case n == 4 && parts[1] == "users" && isID(parts[2]) && (parts[3] == "mute" || parts[3] == "restrict") && (method == "POST" || method == "DELETE"):
		on := method == "POST"
		if on && !a.graph.allow(p.UserID) {
			w.Header().Set("Retry-After", "2")
			a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
			return true
		}
		var value *time.Time
		if on && parts[3] == "mute" {
			var ok bool
			if value, ok = until(); !ok {
				return true
			}
		}
		control := map[string]string{"mute": "mute", "restrict": "restrict"}[parts[3]]
		if err := a.Store.SetControl(ctx, p.UserID, parts[2], control, on, value); err != nil {
			a.error(w, r, err)
			return true
		}
		// Own devices refresh the profile and chat list; the target learns nothing.
		a.signal(ctx, "inbox", nil, p.UserID)
		key := map[string]string{"mute": "muted", "restrict": "restricted"}[parts[3]]
		a.ok(w, r, map[string]any{key: on, "until": value})
	case n == 4 && parts[1] == "conversations" && isID(parts[2]) && parts[3] == "mute" && (method == "POST" || method == "DELETE"):
		on := method == "POST"
		var value *time.Time
		if on {
			var ok bool
			if value, ok = until(); !ok {
				return true
			}
		}
		if err := a.Store.SetConversationMute(ctx, p.UserID, parts[2], on, value); err != nil {
			a.error(w, r, err)
			return true
		}
		a.signal(ctx, "inbox", map[string]string{"conversationId": parts[2]}, p.UserID)
		a.ok(w, r, map[string]any{"muted": on, "until": value})
	case n == 3 && parts[1] == "me" && (parts[2] == "blocked" || parts[2] == "muted" || parts[2] == "restricted") && method == "GET":
		kind := parts[2]
		paged(a, w, r, p, kind, func(pg page) ([]domain.Control, error) {
			return a.Store.ListControls(ctx, p.UserID, kind, pg.before, pg.id, pg.limit, a.signer(ctx))
		}, controlKey, nil)
	case n == 3 && parts[1] == "me" && parts[2] == "reports" && method == "GET":
		paged(a, w, r, p, "reports", func(pg page) ([]domain.Report, error) {
			return a.Store.ListReports(ctx, p.UserID, pg.before, pg.id, pg.limit)
		}, reportKey, nil)
	case n == 2 && parts[1] == "reports" && method == "POST":
		raw, err := decode(w, r)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		data, _ := json.Marshal(raw)
		report, err := domain.ParseReport(data)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if !a.reports.allow(p.UserID) {
			w.Header().Set("Retry-After", "60")
			a.failure(w, r, 429, "RATE_LIMITED", "You’ve sent a lot of reports. Try again in a minute.")
			return true
		}
		value, created, err := a.Store.CreateReport(ctx, p.UserID, report)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		blocked := false
		if report.Block {
			if err = a.Store.SetBlock(ctx, p.UserID, value.Subject.UserID, true); err != nil {
				a.error(w, r, err)
				return true
			}
			blocked = true
			a.signal(ctx, "inbox", nil, p.UserID)
		}
		status := http.StatusOK
		if created {
			status = http.StatusCreated
		}
		a.write(w, r, status, map[string]any{"success": true, "data": map[string]any{"report": value, "duplicate": !created, "blocked": blocked}})
	default:
		return false
	}
	return true
}
