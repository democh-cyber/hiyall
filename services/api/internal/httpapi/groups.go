package httpapi

import (
	"encoding/json"
	"math"
	"net/http"
	"strconv"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/store"
)

// Group chat (docs/api/29-group-chat.md):
//
//	POST /v1/groups                                    create {name?, memberIds}
//	GET  /v1/groups, /hidden, /invites                 the caller's groups, deleted groups, pending invites
//	GET  /v1/groups/{groupId}                          one group
//	PATCH /v1/groups/{groupId}                         owner renames {name, control}
//	POST /v1/groups/{groupId}/members                  owner invites {userIds}
//	POST /v1/groups/{groupId}/accept|decline|leave     answer an invite, leave
//	POST /v1/groups/{groupId}/members/{userId}/remove  owner removes
//
// Messages, blobs, read pointers, mute, pin and hide are the conversation routes (chat.go, chatlist.go).

// groupLimits resolves each member's limits, so an invitee's own group cap is theirs.
func (a *API) groupLimits(r *http.Request) store.GroupEntitlements {
	return func(user string) domain.Entitlements { return a.entitlementsFor(r.Context(), user) }
}

// groupBody reads a group request body (up to the group size limit: a control message carries an envelope per device).
func (a *API) groupBody(w http.ResponseWriter, r *http.Request) (map[string]json.RawMessage, bool) {
	raw, err := decodeLimit(w, r, domain.MaxGroupBody)
	if err != nil {
		a.error(w, r, err)
		return nil, false
	}
	return raw, true
}

// groupNotify tells people their group lists changed (no content).
func (a *API) groupNotify(r *http.Request, group string, users []string, p store.Principal) {
	if len(users) == 0 {
		a.signal(r.Context(), "inbox", map[string]string{"conversationId": group}, p.UserID)
		return
	}
	a.signal(r.Context(), "inbox", map[string]string{"conversationId": group}, append([]string{p.UserID}, users...)...)
}

func (a *API) createGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	raw, ok := a.groupBody(w, r)
	if !ok {
		return
	}
	g, err := domain.ParseNewGroup(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	change, err := a.Store.CreateGroup(r.Context(), p.UserID, g, a.entitlementsFor(r.Context(), p.UserID), a.groupLimits(r), a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.groupNotify(r, change.Group.GroupID, change.Notify, p)
	a.wakeInvited(p, change.Notify)
	a.write(w, r, http.StatusCreated, map[string]any{"success": true, "data": change.Group})
}

func (a *API) listGroups(w http.ResponseWriter, r *http.Request, p store.Principal) {
	items, err := a.Store.ListGroups(r.Context(), p.UserID, a.entitlementsFor(r.Context(), p.UserID), a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"items": items})
}

func (a *API) hiddenGroups(w http.ResponseWriter, r *http.Request, p store.Principal) {
	items, err := a.Store.HiddenGroups(r.Context(), p.UserID, a.entitlementsFor(r.Context(), p.UserID), a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"items": items, "retentionDays": int(domain.HiddenChatRetention.Hours() / 24)})
}

func (a *API) groupInvites(w http.ResponseWriter, r *http.Request, p store.Principal) {
	items, err := a.Store.GroupInvites(r.Context(), p.UserID, a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"items": items})
}

func (a *API) getGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	g, err := a.Store.GetGroup(r.Context(), p.UserID, r.PathValue("groupId"), a.entitlementsFor(r.Context(), p.UserID), a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, g)
}

func (a *API) inviteToGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	raw, ok := a.groupBody(w, r)
	if !ok {
		return
	}
	ids, err := domain.ParseGroupInvites(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	change, err := a.Store.InviteToGroup(r.Context(), p.UserID, r.PathValue("groupId"), ids, a.entitlementsFor(r.Context(), p.UserID), a.groupLimits(r), a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.groupNotify(r, change.Group.GroupID, change.Notify, p)
	a.wakeInvited(p, change.Notify)
	a.ok(w, r, change.Group)
}

// wakeInvited pushes "You have a new group invite" (no group name, no sender) to the people just invited; the
// dispatcher applies mutes, blocks, bands and the member's own choices.
func (a *API) wakeInvited(p store.Principal, users []string) {
	for _, u := range users {
		a.wakeFrom("group_invite", p.UserID, u)
	}
}

func (a *API) acceptGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	raw, ok := a.groupBody(w, r)
	if !ok {
		return
	}
	control, err := domain.ParseGroupControlOnly(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	change, err := a.Store.AcceptGroupInvite(r.Context(), p.UserID, r.PathValue("groupId"), control, a.entitlementsFor(r.Context(), p.UserID), a.signer(r.Context()))
	if err != nil {
		a.groupFailure(w, r, p, control, err)
		return
	}
	a.groupNotify(r, change.Group.GroupID, change.Notify, p)
	a.ok(w, r, change.Group)
}

func (a *API) declineGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	notify, err := a.Store.DeclineGroupInvite(r.Context(), p.UserID, r.PathValue("groupId"))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.groupNotify(r, r.PathValue("groupId"), notify, p)
	a.ok(w, r, map[string]bool{"declined": true})
}

func (a *API) renameGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	raw, ok := a.groupBody(w, r)
	if !ok {
		return
	}
	name, control, err := domain.ParseGroupRename(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	change, err := a.Store.RenameGroup(r.Context(), p.UserID, r.PathValue("groupId"), name, control, a.entitlementsFor(r.Context(), p.UserID), a.signer(r.Context()))
	if err != nil {
		a.groupFailure(w, r, p, control, err)
		return
	}
	a.groupNotify(r, change.Group.GroupID, change.Notify, p)
	a.ok(w, r, change.Group)
}

func (a *API) removeGroupMember(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var control *domain.GroupControl
	if r.ContentLength != 0 {
		raw, ok := a.groupBody(w, r)
		if !ok {
			return
		}
		var err error
		if control, err = domain.ParseGroupControlOnly(raw); err != nil {
			a.error(w, r, err)
			return
		}
	}
	change, err := a.Store.RemoveGroupMember(r.Context(), p.UserID, r.PathValue("groupId"), r.PathValue("userId"), control, a.entitlementsFor(r.Context(), p.UserID), a.signer(r.Context()))
	if err != nil {
		a.groupFailure(w, r, p, control, err)
		return
	}
	a.groupNotify(r, change.Group.GroupID, append(change.Notify, r.PathValue("userId")), p)
	a.ok(w, r, change.Group)
}

func (a *API) leaveGroup(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var owner string
	var control *domain.GroupControl
	if r.ContentLength != 0 {
		raw, ok := a.groupBody(w, r)
		if !ok {
			return
		}
		var err error
		if owner, control, err = domain.ParseGroupLeave(raw); err != nil {
			a.error(w, r, err)
			return
		}
	}
	notify, err := a.Store.LeaveGroup(r.Context(), p.UserID, r.PathValue("groupId"), owner, control, a.entitlementsFor(r.Context(), p.UserID))
	if err != nil {
		a.groupFailure(w, r, p, control, err)
		return
	}
	a.groupNotify(r, r.PathValue("groupId"), notify, p)
	a.ok(w, r, map[string]bool{"left": true})
}

// groupFailure answers a group change that failed, first telling the owners of any dormant devices the change revoked.
func (a *API) groupFailure(w http.ResponseWriter, r *http.Request, p store.Principal, control *domain.GroupControl, err error) {
	device := ""
	if control != nil {
		device = control.SenderDeviceID
	}
	a.signalRevoked(r.Context(), err, p.UserID, device)
	a.error(w, r, err)
}

// sendGroupMessage is POST /v1/conversations/{groupId}/messages for a group.
func (a *API) sendGroupMessage(w http.ResponseWriter, r *http.Request, p store.Principal, id string) {
	ctx := r.Context()
	raw, ok := a.groupBody(w, r)
	if !ok {
		return
	}
	m, err := domain.ParseGroupSendMessage(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if !a.messages.allow(p.UserID) {
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
		return
	}
	// Reactions have their own, stricter budget per group on top of the normal one.
	if m.Aux != "" {
		if d := a.auxMessages.take(p.UserID + ":" + id); !d.Allowed {
			w.Header().Set("Retry-After", strconv.FormatInt(max(1, int64(math.Ceil(d.RetryAfter.Seconds()))), 10))
			a.failure(w, r, 429, "RATE_LIMITED", "You're reacting a lot. Try again in a moment.")
			return
		}
	}
	created, recipients, quiet, err := a.Store.SendGroupMessage(ctx, p.UserID, id, m, a.entitlementsFor(ctx, p.UserID))
	if err != nil {
		a.signalRevoked(ctx, err, p.UserID, m.SenderDeviceID)
		a.error(w, r, err)
		return
	}
	// The sender's other devices also hold envelopes.
	a.signal(ctx, "inbox", map[string]string{"conversationId": id}, append([]string{p.UserID}, recipients...)...)
	if !quiet {
		for _, to := range recipients {
			a.wake(push.Notice{Kind: "chat", Actor: p.UserID, Recipient: to, Conversation: id})
		}
	}
	a.ok(w, r, map[string]any{"messageId": m.MessageID, "createdAt": created})
}
