package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/store"
)

// chatRoute serves device keys, conversations and the ciphertext relay.
// Nothing here ever receives plaintext; bodies are public keys and ciphertext.
func (a *API) chatRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n, method := len(parts), r.Method
	if n < 2 || parts[0] != "v1" {
		return false
	}
	respond := func(value any, err error) {
		if err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, value)
	}
	body := func() (map[string]json.RawMessage, bool) {
		value, err := decode(w, r)
		if err != nil {
			a.error(w, r, err)
			return nil, false
		}
		return value, true
	}
	limited := func(l *keyedLimiter) bool {
		if l.allow(p.UserID) {
			return false
		}
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
		return true
	}
	if a.chatMediaRoute(w, r, p, parts) {
		return true
	}
	switch {
	case n == 2 && parts[1] == "devices" && method == "POST":
		raw, ok := body()
		if !ok {
			return true
		}
		d, err := domain.ParseDevice(p.UserID, raw)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if limited(a.chatDevices) {
			return true
		}
		if isID(p.SessionID) {
			d.SessionID = p.SessionID
		}
		registered, outcome, err := a.Store.RegisterDeviceOutcome(ctx, d)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if outcome == store.DeviceReturned {
			// A device the relay had removed as idle is back with the keys it always had (CHAT-N1). It is not a new
			// device: no "added" signal and no security push. The account's other devices only look at their list
			// again, which now holds it, so a removal notice they kept can go.
			a.signal(ctx, "device", map[string]string{"deviceId": registered.DeviceID, "change": "returned"}, p.UserID)
		}
		if outcome == store.DeviceCreated {
			// Every device of the account learns at once that one was added, so an unexpected one is noticed.
			a.signal(ctx, "device", map[string]string{"deviceId": registered.DeviceID, "change": "added"}, p.UserID)
			// And a content-free push to the others that are not connected, so a device added with a stolen
			// credential is noticed even when nobody has the app open. Never off: it is a security notice.
			a.wake(push.Notice{Kind: "device", Actor: p.UserID, Recipient: p.UserID, Device: registered.DeviceID})
		}
		a.ok(w, r, registered)
	case n == 3 && parts[1] == "me" && parts[2] == "devices" && method == "GET":
		if limited(a.chatDevices) {
			return true
		}
		items, err := a.Store.MyDevices(ctx, p.UserID)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		// removed: devices of this account that another session took out in the last 30 days, so a device
		// that missed the realtime signal still learns of it (re-audit CHAT-2).
		removed, err := a.Store.RemovedDevices(ctx, p.UserID)
		respond(map[string]any{"items": items, "removed": removed}, err)
	case n == 3 && parts[1] == "devices" && isID(parts[2]) && method == "DELETE":
		if limited(a.chatDevices) {
			return true
		}
		byOther, callerDevice, err := a.Store.RevokeDevice(ctx, p.UserID, parts[2], sessionIDOrEmpty(p.SessionID))
		if err == nil {
			by := "self"
			if byOther {
				by = "other"
			}
			a.signal(ctx, "device", map[string]string{"deviceId": parts[2], "change": "revoked", "by": by}, p.UserID)
			if byOther {
				// A removal by a session that is not the device's own (another phone, or a stolen credential)
				// is a security notice too: content-free, to the account's remaining devices, never
				// silenced by a live socket (an attacker can hold one open) or the chat caps.
				// The device that asked already knows, so it is left out (CHAT-N7); the removed one holds no token.
				a.wake(push.Notice{Kind: "device-revoked", Actor: p.UserID, Recipient: p.UserID, Device: callerDevice})
			}
		}
		respond(map[string]bool{"revoked": true}, err)
	case n == 4 && parts[1] == "devices" && isID(parts[2]) && parts[3] == "keys":
		device := parts[2]
		if (method == "GET" || method == "POST") && limited(a.chatKeys) {
			return true
		}
		if method == "GET" {
			count, fallback, err := a.Store.KeyCount(ctx, p.UserID, device)
			respond(map[string]any{"oneTimeKeyCount": count, "hasFallbackKey": fallback}, err)
			return true
		}
		if method != "POST" {
			return false
		}
		raw, ok := body()
		if !ok {
			return true
		}
		var upload domain.KeyUpload
		data, _ := json.Marshal(raw)
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&upload) != nil || len(upload.OneTimeKeys) > 50 {
			a.failure(w, r, 422, "VALIDATION", "send at most 50 one-time keys and an optional fallback key")
			return true
		}
		count, err := a.Store.UploadKeys(ctx, p.UserID, device, upload)
		respond(map[string]int{"oneTimeKeyCount": count}, err)
	case n == 4 && parts[1] == "devices" && isID(parts[2]) && parts[3] == "inbox" && method == "GET":
		if limited(a.chatInbox) {
			return true
		}
		limit := 50
		if value := r.URL.Query().Get("limit"); value != "" {
			v, err := strconv.Atoi(value)
			if err != nil || v < 1 || v > 100 {
				a.failure(w, r, 422, "VALIDATION", "limit must be 1–100")
				return true
			}
			limit = v
		}
		items, err := a.Store.Inbox(ctx, p.UserID, parts[2], limit)
		respond(map[string]any{"items": items}, err)
	case n == 5 && parts[1] == "devices" && isID(parts[2]) && parts[3] == "inbox" && parts[4] == "ack" && method == "POST":
		if limited(a.chatInbox) {
			return true
		}
		raw, ok := body()
		if !ok {
			return true
		}
		var ids []string
		if len(raw) != 1 || json.Unmarshal(raw["messageIds"], &ids) != nil || len(ids) == 0 || len(ids) > 100 {
			a.failure(w, r, 422, "VALIDATION", "send 1–100 messageIds")
			return true
		}
		for _, id := range ids {
			if !isID(id) {
				a.failure(w, r, 422, "VALIDATION", "messageIds must be ids")
				return true
			}
		}
		count, err := a.Store.Ack(ctx, p.UserID, parts[2], ids)
		respond(map[string]int64{"acknowledged": count}, err)
	case n == 4 && parts[1] == "users" && isID(parts[2]) && parts[3] == "devices" && method == "GET":
		items, err := a.Store.PeerDevices(ctx, p.UserID, parts[2])
		respond(map[string]any{"items": items}, err)
	case n == 6 && parts[1] == "users" && isID(parts[2]) && parts[3] == "devices" && isID(parts[4]) && parts[5] == "claim" && method == "POST":
		if limited(a.graph) {
			return true
		}
		respond(a.Store.ClaimKey(ctx, p.UserID, parts[2], parts[4]))
	case n == 2 && parts[1] == "conversations" && method == "POST":
		raw, ok := body()
		if !ok {
			return true
		}
		var target string
		if len(raw) != 1 || json.Unmarshal(raw["userId"], &target) != nil || !isID(target) {
			a.failure(w, r, 422, "VALIDATION", "userId is required")
			return true
		}
		if limited(a.graph) {
			return true
		}
		// Opening a conversation with someone you have never exchanged a message with is a new contact:
		// a tighter budget on top of the general one. Reopening a conversation that has messages is not.
		exchanged, err := a.Store.HaveExchangedMessages(ctx, p.UserID, target)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if !exchanged && !a.firstChats.allow(p.UserID) {
			w.Header().Set("Retry-After", "60")
			a.failure(w, r, 429, "RATE_LIMITED", "You have started a lot of new conversations. Try again in a minute.")
			return true
		}
		respond(a.Store.OpenConversation(ctx, p.UserID, target, a.entitlementsFor(ctx, p.UserID), a.signer(ctx), a.presence))
	case n == 2 && parts[1] == "conversations" && method == "GET":
		paged(a, w, r, p, "conversations", func(pg page) ([]domain.Conversation, error) {
			return a.Store.ListConversations(ctx, p.UserID, pg.before, pg.id, pg.limit, a.signer(ctx), a.presence)
		}, func(c domain.Conversation) (time.Time, string) {
			return c.SortAt, c.ConversationID
		}, nil)
	case n == 3 && parts[1] == "conversations" && parts[2] == "unread" && method == "GET":
		respond(a.Store.Unread(ctx, p.UserID))
	case n == 4 && parts[1] == "conversations" && isID(parts[2]) && parts[3] == "read" && method == "POST":
		raw, ok := body()
		if !ok {
			return true
		}
		var upTo time.Time
		if len(raw) != 1 || json.Unmarshal(raw["readAt"], &upTo) != nil || upTo.IsZero() {
			a.failure(w, r, 422, "VALIDATION", "readAt is required")
			return true
		}
		peer, readAt, changed, err := a.Store.MarkRead(ctx, p.UserID, parts[2], upTo)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if changed {
			data := map[string]string{"conversationId": parts[2], "userId": p.UserID, "readAt": readAt.Format(time.RFC3339Nano)}
			// Own devices always learn the badge changed; the peer only with receipts on both sides.
			a.signal(ctx, "read", data, p.UserID)
			if shared, err := a.Store.ReadReceiptsShared(ctx, p.UserID, peer); err == nil && shared {
				a.signal(ctx, "read", data, peer)
			}
		}
		a.ok(w, r, map[string]any{"readAt": readAt})
	case n == 4 && parts[1] == "devices" && isID(parts[2]) && parts[3] == "push" && (method == "PUT" || method == "DELETE"):
		provider, token := "", ""
		if method == "PUT" {
			raw, ok := body()
			if !ok {
				return true
			}
			if len(raw) != 2 || json.Unmarshal(raw["provider"], &provider) != nil || json.Unmarshal(raw["token"], &token) != nil ||
				(provider != "fcm" && provider != "apns") || len(token) < 8 || len(token) > 4096 {
				a.failure(w, r, 422, "VALIDATION", "provider (fcm or apns) and token are required")
				return true
			}
		}
		respond(map[string]bool{"registered": token != ""}, a.Store.SetPushToken(ctx, p.UserID, parts[2], provider, token))
	// Push choices: GET /v1/me/notifications, PATCH {chat?, social?}. Enforced when the server decides to push.
	case n == 3 && parts[1] == "me" && parts[2] == "notifications" && method == "GET":
		respond(a.Store.NotificationPrefs(ctx, p.UserID))
	case n == 3 && parts[1] == "me" && parts[2] == "notifications" && method == "PATCH":
		raw, ok := body()
		if !ok {
			return true
		}
		chat, social, err := domain.ParseNotificationPrefs(raw)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if limited(a.graph) {
			return true
		}
		respond(a.Store.SetNotificationPrefs(ctx, p.UserID, chat, social))
	case n == 3 && parts[1] == "conversations" && isID(parts[2]) && method == "GET":
		respond(a.Store.ConversationFor(ctx, p.UserID, parts[2], a.signer(ctx), a.presence))
	case n == 4 && parts[1] == "conversations" && isID(parts[2]) && parts[3] == "messages" && method == "POST":
		raw, ok := body()
		if !ok {
			return true
		}
		m, err := domain.ParseSendMessage(raw)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if limited(a.messages) {
			return true
		}
		// Reactions have their own, stricter budget per conversation on top of the normal one above.
		if m.Aux != "" {
			if d := a.auxMessages.take(p.UserID + ":" + parts[2]); !d.Allowed {
				w.Header().Set("Retry-After", strconv.FormatInt(max(1, int64(math.Ceil(d.RetryAfter.Seconds()))), 10))
				a.failure(w, r, 429, "RATE_LIMITED", "You're reacting a lot. Try again in a moment.")
				return true
			}
		}
		created, peer, quiet, err := a.Store.SendMessage(ctx, p.UserID, parts[2], m, a.entitlementsFor(ctx, p.UserID))
		if err != nil {
			var revoked *store.DevicesRevoked
			if errors.As(err, &revoked) {
				// The send found a dormant device over the backlog cap, or a ghost one that one sender alone had
				// filled, and revoked it (CHAT-N1, N2): the owner's other devices are told, like any removal they
				// did not make, and the sender is answered DEVICES_CHANGED below, which the client retries once.
				for _, d := range revoked.Devices {
					a.signal(ctx, "device", map[string]string{"deviceId": d.DeviceID, "change": "revoked", "by": "other", "reason": d.Reason}, d.UserID)
					// An idle removal is housekeeping, not a security event: it is listed for the owner's other
					// devices (and signalled to those that are connected) but never pushed.
					if d.Reason == store.ReasonIdle {
						continue
					}
					// The sender's own phone, which is mid-send, needs no push about it.
					exclude := ""
					if d.UserID == p.UserID {
						exclude = m.SenderDeviceID
					}
					a.wake(push.Notice{Kind: "device-revoked", Actor: d.UserID, Recipient: d.UserID, Device: exclude})
				}
			}
			a.error(w, r, err)
			return true
		}
		// The sender's other devices also hold envelopes, so both users are signalled.
		a.signal(ctx, "inbox", map[string]string{"conversationId": parts[2]}, peer, p.UserID)
		// quiet is the cheap early answer (and always true for a reaction); the dispatcher re-checks mutes,
		// blocks, bands and the member's choices.
		if !quiet {
			a.wake(push.Notice{Kind: "chat", Actor: p.UserID, Recipient: peer, Conversation: parts[2]})
		}
		a.ok(w, r, map[string]any{"messageId": m.MessageID, "createdAt": created})
	default:
		return false
	}
	return true
}

// sessionIDOrEmpty is the session id when it is a canonical id, otherwise "" (an unknown session).
func sessionIDOrEmpty(id string) string {
	if isID(id) {
		return id
	}
	return ""
}
