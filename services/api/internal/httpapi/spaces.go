package httpapi

import (
	"encoding/json"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
	"net/http"
	"time"
)

// Shared spaces. Everything but a read takes the per-account content limit in the route table first.

// spaceRespond answers a space handler; a change that returns the space also wakes its owner and the actor.
func (a *API) spaceRespond(w http.ResponseWriter, r *http.Request, p store.Principal, v any, e error) {
	if e != nil {
		a.error(w, r, e)
		return
	}
	a.ok(w, r, v)
	if r.Method != http.MethodGet {
		if x, ok := v.(domain.Space); ok {
			a.signal(r.Context(), "activity", nil, p.UserID, x.Owner.UserID)
		}
	}
}

func (a *API) spaceBody(w http.ResponseWriter, r *http.Request, v any) bool {
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

func (a *API) listSpaces(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	q := r.URL.Query()
	kind := q.Get("kind")
	if kind == "" {
		kind = "community"
	}
	if kind != "community" && kind != "moment" && kind != "event" {
		a.failure(w, r, 422, "VALIDATION", "Choose a space kind")
		return
	}
	parent := q.Get("parentId")
	if parent != "" && !isID(parent) {
		a.failure(w, r, 422, "VALIDATION", "Use a community id")
		return
	}
	mine := q.Get("mine") == "true"
	paged(a, w, r, p, "spaces:"+kind+":"+parent+":"+q.Get("mine"), func(pg page) ([]domain.Space, error) {
		return a.Store.Spaces(ctx, p.UserID, kind, parent, mine, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, func(s domain.Space) (time.Time, string) { return s.CreatedAt, s.SpaceID }, nil)
}

func (a *API) createSpace(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	data, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	in, e := domain.ParseSpace(data)
	if e != nil {
		a.error(w, r, e)
		return
	}
	if in.Kind != "community" && !a.SpacesEvents {
		a.failure(w, r, 403, "FEATURE_DISABLED", "Events and Moments aren’t available yet.")
		return
	}
	s, e := a.Store.CreateSpace(ctx, p.UserID, in, a.signer(ctx), a.entitlementsFor(ctx, p.UserID))
	if e != nil {
		a.error(w, r, e)
		return
	}
	a.write(w, r, 201, map[string]any{"success": true, "data": s})
}

func (a *API) updateSpace(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	data, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	in, e := domain.ParseSpace(data)
	if e != nil {
		a.error(w, r, e)
		return
	}
	v, err := a.Store.UpdateSpace(ctx, p.UserID, r.PathValue("spaceId"), in, a.signer(ctx))
	a.spaceRespond(w, r, p, v, err)
}

func (a *API) getSpace(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	v, err := a.Store.Space(ctx, p.UserID, r.PathValue("spaceId"), a.signer(ctx))
	a.spaceRespond(w, r, p, v, err)
}

func (a *API) inviteToSpace(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	var in struct {
		Username string `json:"username"`
	}
	if !a.spaceBody(w, r, &in) {
		return
	}
	if !domain.SpaceText(in.Username, 1, 40) {
		a.failure(w, r, 422, "VALIDATION", "Enter a username")
		return
	}
	// target is "" unless someone was really invited (see InviteSpaceUser).
	x, target, e := a.Store.InviteSpaceUser(ctx, p.UserID, r.PathValue("spaceId"), in.Username, a.signer(ctx))
	a.spaceRespond(w, r, p, x, e)
	if e == nil && target != "" {
		a.signal(ctx, "activity", nil, target)
		a.wakeFrom("space_invite", p.UserID, target)
	}
}

// spaceMembership is PUT (join, or answer an invitation) and DELETE (leave) /v1/spaces/{spaceId}/membership.
func (a *API) spaceMembership(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	rsvp := "going"
	if r.Method == http.MethodPut {
		var in struct {
			RSVP string `json:"rsvp"`
		}
		if !a.spaceBody(w, r, &in) {
			return
		}
		if in.RSVP != "" {
			rsvp = in.RSVP
		}
	}
	if rsvp != "going" && rsvp != "interested" {
		a.failure(w, r, 422, "VALIDATION", "Choose going or interested")
		return
	}
	action := "join"
	if r.Method == http.MethodDelete {
		action = "leave"
	}
	x, _, e := a.Store.ChangeSpaceMember(ctx, p.UserID, r.PathValue("spaceId"), p.UserID, action, rsvp, a.signer(ctx))
	a.spaceRespond(w, r, p, x, e)
}

func (a *API) setSpaceStatus(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var in struct {
		Status string `json:"status"`
	}
	if !a.spaceBody(w, r, &in) {
		return
	}
	if in.Status != "open" && in.Status != "closed" && in.Status != "archived" {
		a.failure(w, r, 422, "VALIDATION", "Choose open, closed or archived")
		return
	}
	ctx := r.Context()
	x, e := a.Store.SetSpaceStatus(ctx, p.UserID, r.PathValue("spaceId"), in.Status, a.signer(ctx))
	a.spaceRespond(w, r, p, x, e)
}

func (a *API) spaceMembers(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("spaceId")
	state := r.URL.Query().Get("state")
	if state == "" {
		state = "active"
	}
	if state != "active" && state != "pending" && state != "invited" && state != "banned" {
		a.failure(w, r, 422, "VALIDATION", "Choose a membership state")
		return
	}
	paged(a, w, r, p, "members:"+id+":"+state, func(pg page) ([]domain.SpaceMember, error) {
		return a.Store.SpaceMembers(ctx, p.UserID, id, state, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, func(m domain.SpaceMember) (time.Time, string) { return m.CreatedAt, m.User.UserID }, nil)
}

func (a *API) changeSpaceMember(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id, member := r.Context(), r.PathValue("spaceId"), r.PathValue("userId")
	var in struct {
		Action string `json:"action"`
	}
	if !a.spaceBody(w, r, &in) {
		return
	}
	switch in.Action {
	case "approve", "invite", "remove", "ban", "unban", "admin", "moderator", "member":
		x, changed, e := a.Store.ChangeSpaceMember(ctx, p.UserID, id, member, in.Action, "going", a.signer(ctx))
		a.spaceRespond(w, r, p, x, e)
		// Only a real change is signalled. Space activity is not pushed (docs/api/23-push-notifications.md).
		if e == nil && changed {
			a.signal(ctx, "activity", nil, member)
		}
	default:
		a.failure(w, r, 422, "VALIDATION", "Choose a member action")
	}
}

func (a *API) spaceEntries(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("spaceId")
	paged(a, w, r, p, "entries:"+id, func(pg page) ([]domain.SpaceEntry, error) {
		return a.Store.SpaceEntries(ctx, p.UserID, id, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, func(e domain.SpaceEntry) (time.Time, string) { return e.CreatedAt, e.EntryID }, nil)
}

func (a *API) createSpaceEntry(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var in struct {
		Body string `json:"body"`
	}
	if !a.spaceBody(w, r, &in) {
		return
	}
	ctx := r.Context()
	idem, ok := a.idempotency(w, r, []byte(in.Body))
	if !ok {
		return
	}
	entry, replayed, e := a.Store.CreateSpaceEntryOnce(ctx, p.UserID, r.PathValue("spaceId"), in.Body, a.entitlementsFor(ctx, p.UserID), idem)
	if e != nil {
		a.error(w, r, e)
		return
	}
	markReplay(w, replayed)
	a.write(w, r, 201, map[string]any{"success": true, "data": map[string]string{"entryId": entry}})
}

func (a *API) deleteSpaceEntry(w http.ResponseWriter, r *http.Request, p store.Principal) {
	e := a.Store.DeleteSpaceEntry(r.Context(), p.UserID, r.PathValue("spaceId"), r.PathValue("entryId"))
	a.spaceRespond(w, r, p, map[string]bool{"deleted": e == nil}, e)
}
