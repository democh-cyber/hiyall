package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Chat list features (docs/api/26-chat-voice-video-and-list.md): pins, deleted ("hidden") chats and the list order.
//
//	PUT  /v1/conversations/{id}/pin       {"pinned": true|false}   409 PIN_LIMIT past ChatPinsMax
//	POST /v1/conversations/{id}/hide      no body; restorable for 30 days
//	POST /v1/conversations/{id}/restore   no body
//	GET  /v1/conversations/hidden         the Deleted chats, and the ids closed for the caller
//	GET  /v1/conversations                unhidden chats, the pinned ones first
//
// All of it is the caller's own state: the peer is never told and never sees any of it.
func (a *API) chatListRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n, method := len(parts), r.Method
	if n < 3 || parts[1] != "conversations" {
		return false
	}
	limited := func(l *keyedLimiter) bool {
		if l.allow(p.UserID) {
			return false
		}
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
		return true
	}
	switch {
	case n == 3 && parts[2] == "hidden" && method == "GET":
		if limited(a.lists) {
			return true
		}
		items, closed, err := a.Store.HiddenConversations(ctx, p.UserID, a.signer(ctx), a.presence)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.ok(w, r, map[string]any{"items": items, "closedIds": closed, "retentionDays": int(domain.HiddenChatRetention / (24 * time.Hour))})
	case n == 4 && isID(parts[2]) && parts[3] == "pin" && method == "PUT":
		raw, err := decode(w, r)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		pinned, ok := onlyBool(raw, "pinned")
		if !ok {
			a.failure(w, r, 422, "VALIDATION", "pinned must be true or false")
			return true
		}
		if limited(a.graph) {
			return true
		}
		at, err := a.Store.SetConversationPin(ctx, p.UserID, parts[2], pinned, a.entitlementsFor(ctx, p.UserID))
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.signal(ctx, "inbox", map[string]string{"conversationId": parts[2]}, p.UserID)
		a.ok(w, r, map[string]any{"pinned": pinned, "pinnedAt": at})
	case n == 4 && isID(parts[2]) && parts[3] == "hide" && method == "POST":
		if limited(a.graph) {
			return true
		}
		at, err := a.Store.HideConversation(ctx, p.UserID, parts[2])
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.signal(ctx, "inbox", map[string]string{"conversationId": parts[2]}, p.UserID)
		a.ok(w, r, map[string]any{"hidden": true, "hiddenAt": at, "restoreUntil": at.Add(domain.HiddenChatRetention)})
	case n == 4 && isID(parts[2]) && parts[3] == "restore" && method == "POST":
		if limited(a.graph) {
			return true
		}
		if err := a.Store.RestoreConversation(ctx, p.UserID, parts[2]); err != nil {
			a.error(w, r, err)
			return true
		}
		a.signal(ctx, "inbox", map[string]string{"conversationId": parts[2]}, p.UserID)
		a.ok(w, r, map[string]bool{"hidden": false})
	default:
		return false
	}
	return true
}

// onlyBool reads a body that is exactly {key: true|false}: no other key, and not null, a string or a number.
func onlyBool(raw map[string]json.RawMessage, key string) (value, ok bool) {
	v, found := raw[key]
	if len(raw) != 1 || !found {
		return false, false
	}
	switch string(bytes.TrimSpace(v)) {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

// listConversations is GET /v1/conversations: the caller's chats that are not deleted, the pinned ones (at most
// ChatPinsMax, most recent first) in front of the first page and the rest newest first. The cursor runs over the
// unpinned chats only, so a pinned chat never shows up again on a later page and the first page may hold up to
// limit plus the pinned ones.
func (a *API) listConversations(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	pg, ok := a.pageOf(w, r, p, "conversations")
	if !ok {
		return
	}
	limit := pg.limit
	pg.limit++
	items, err := a.Store.ListConversations(ctx, p.UserID, pg.before, pg.id, pg.limit, a.signer(ctx), a.presence)
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(items) > limit {
		items = items[:limit]
		last := items[limit-1]
		next = a.signList(listCursor{User: p.UserID, Kind: "conversations", ID: last.ConversationID, Before: last.SortAt, Exp: time.Now().Add(15 * time.Minute).Unix()})
	}
	if pg.before == nil {
		pinned, err := a.Store.PinnedConversations(ctx, p.UserID, a.signer(ctx), a.presence)
		if err != nil {
			a.error(w, r, err)
			return
		}
		items = append(pinned, items...)
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil})
}
