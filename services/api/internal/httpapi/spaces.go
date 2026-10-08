package httpapi

import (
	"encoding/json"
	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
	"net/http"
	"time"
)

func (a *API) spacesRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	n := len(parts)
	if n < 2 || parts[0] != "v1" || parts[1] != "spaces" {
		return false
	}
	ctx := r.Context()
	eligible, err := a.Store.EligibleAdult(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return true
	}
	if !eligible {
		a.failure(w, r, 403, "ADULT_SPACE_REQUIRED", "Shared spaces are available to verified adults")
		return true
	}
	if r.Method != "GET" && !a.content.allow(p.UserID) {
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down and try again")
		return true
	}
	respond := func(v any, e error) {
		if e != nil {
			a.error(w, r, e)
		} else {
			a.ok(w, r, v)
			if r.Method != "GET" {
				if x, ok := v.(domain.Space); ok {
					a.signal(ctx, "activity", nil, p.UserID, x.Owner.UserID)
				}
			}
		}
	}
	body := func(v any) bool {
		raw, e := decode(w, r)
		if e != nil {
			a.error(w, r, e)
			return false
		}
		data, _ := json.Marshal(raw)
		if strictDecode(data, v) != nil {
			a.failure(w, r, 422, "VALIDATION", "Check the request fields")
			return false
		}
		return true
	}
	if n == 2 {
		switch r.Method {
		case "GET":
			q := r.URL.Query()
			kind := q.Get("kind")
			if kind == "" {
				kind = "community"
			}
			if kind != "community" && kind != "moment" && kind != "event" {
				a.failure(w, r, 422, "VALIDATION", "Choose a space kind")
				return true
			}
			parent := q.Get("parentId")
			if parent != "" && !isID(parent) {
				a.failure(w, r, 422, "VALIDATION", "Use a community id")
				return true
			}
			mine := q.Get("mine") == "true"
			paged(a, w, r, p, "spaces:"+kind+":"+parent+":"+q.Get("mine"), func(pg page) ([]domain.Space, error) {
				return a.Store.Spaces(ctx, p.UserID, kind, parent, mine, pg.before, pg.id, pg.limit)
			}, func(s domain.Space) (time.Time, string) { return s.CreatedAt, s.SpaceID }, nil)
		case "POST":
			raw, e := decode(w, r)
			if e != nil {
				a.error(w, r, e)
				return true
			}
			data, _ := json.Marshal(raw)
			in, e := domain.ParseSpace(data)
			if e != nil {
				a.error(w, r, e)
				return true
			}
			s, e := a.Store.CreateSpace(ctx, p.UserID, in)
			if e != nil {
				a.error(w, r, e)
			} else {
				a.write(w, r, 201, map[string]any{"success": true, "data": s})
			}
		default:
			a.failure(w, r, 405, "METHOD_NOT_ALLOWED", "Method unavailable")
		}
		return true
	}
	if !isID(parts[2]) {
		a.failure(w, r, 404, "NOT_FOUND", "Space unavailable")
		return true
	}
	id := parts[2]
	switch {
	case n == 3 && r.Method == "PUT":
		raw, e := decode(w, r)
		if e != nil {
			a.error(w, r, e)
			return true
		}
		data, _ := json.Marshal(raw)
		in, e := domain.ParseSpace(data)
		if e != nil {
			a.error(w, r, e)
			return true
		}
		respond(a.Store.UpdateSpace(ctx, p.UserID, id, in))
	case n == 3 && r.Method == "GET":
		respond(a.Store.Space(ctx, p.UserID, id))
	case n == 4 && parts[3] == "invitations" && r.Method == "POST":
		var in struct {
			Username string `json:"username"`
		}
		if !body(&in) {
			return true
		}
		if !domain.SpaceText(in.Username, 1, 40) {
			a.failure(w, r, 422, "VALIDATION", "Enter a username")
			return true
		}
		x, target, e := a.Store.InviteSpaceUser(ctx, p.UserID, id, in.Username)
		respond(x, e)
		if e == nil {
			a.signal(ctx, "activity", nil, target)
			a.wake("activity", target)
		}
	case n == 4 && parts[3] == "membership" && (r.Method == "PUT" || r.Method == "DELETE"):
		rsvp := "going"
		if r.Method == "PUT" {
			var in struct {
				RSVP string `json:"rsvp"`
			}
			if !body(&in) {
				return true
			}
			if in.RSVP != "" {
				rsvp = in.RSVP
			}
		}
		if rsvp != "going" && rsvp != "interested" {
			a.failure(w, r, 422, "VALIDATION", "Choose going or interested")
			return true
		}
		action := "join"
		if r.Method == "DELETE" {
			action = "leave"
		}
		respond(a.Store.ChangeSpaceMember(ctx, p.UserID, id, p.UserID, action, rsvp))
	case n == 4 && parts[3] == "status" && r.Method == "PUT":
		var in struct {
			Status string `json:"status"`
		}
		if !body(&in) {
			return true
		}
		if in.Status != "open" && in.Status != "closed" && in.Status != "archived" {
			a.failure(w, r, 422, "VALIDATION", "Choose open, closed or archived")
			return true
		}
		respond(a.Store.SetSpaceStatus(ctx, p.UserID, id, in.Status))
	case n == 4 && parts[3] == "members" && r.Method == "GET":
		state := r.URL.Query().Get("state")
		if state == "" {
			state = "active"
		}
		if state != "active" && state != "pending" && state != "invited" && state != "banned" {
			a.failure(w, r, 422, "VALIDATION", "Choose a membership state")
			return true
		}
		paged(a, w, r, p, "members:"+id+":"+state, func(pg page) ([]domain.SpaceMember, error) {
			return a.Store.SpaceMembers(ctx, p.UserID, id, state, pg.before, pg.id, pg.limit)
		}, func(m domain.SpaceMember) (time.Time, string) { return m.CreatedAt, m.User.UserID }, nil)
	case n == 5 && parts[3] == "members" && isID(parts[4]) && r.Method == "PUT":
		var in struct {
			Action string `json:"action"`
		}
		if !body(&in) {
			return true
		}
		switch in.Action {
		case "approve", "invite", "remove", "ban", "unban", "admin", "moderator", "member":
			x, e := a.Store.ChangeSpaceMember(ctx, p.UserID, id, parts[4], in.Action, "going")
			respond(x, e)
			if e == nil {
				a.signal(ctx, "activity", nil, parts[4])
				a.wake("activity", parts[4])
			}
		default:
			a.failure(w, r, 422, "VALIDATION", "Choose a member action")
		}
	case n == 4 && parts[3] == "entries" && r.Method == "GET":
		paged(a, w, r, p, "entries:"+id, func(pg page) ([]domain.SpaceEntry, error) {
			return a.Store.SpaceEntries(ctx, p.UserID, id, pg.before, pg.id, pg.limit)
		}, func(e domain.SpaceEntry) (time.Time, string) { return e.CreatedAt, e.EntryID }, nil)
	case n == 4 && parts[3] == "entries" && r.Method == "POST":
		var in struct {
			Body string `json:"body"`
		}
		if !body(&in) {
			return true
		}
		entry, e := a.Store.CreateSpaceEntry(ctx, p.UserID, id, in.Body)
		if e != nil {
			a.error(w, r, e)
		} else {
			a.write(w, r, 201, map[string]any{"success": true, "data": map[string]string{"entryId": entry}})
		}
	case n == 5 && parts[3] == "entries" && isID(parts[4]) && r.Method == "DELETE":
		e := a.Store.DeleteSpaceEntry(ctx, p.UserID, id, parts[4])
		respond(map[string]bool{"deleted": e == nil}, e)
	default:
		a.failure(w, r, 404, "NOT_FOUND", "Endpoint unavailable")
	}
	return true
}
