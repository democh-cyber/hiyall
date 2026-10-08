package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
)

// chatRoute serves device keys, conversations and the ciphertext relay.
// Nothing here ever receives plaintext; bodies are public keys and ciphertext.
func (a *API) chatRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n, method := len(parts), r.Method
	if n < 2 || parts[0] != "v1" {
		return false
	}
	isID := func(value string) bool { _, err := uuid.Parse(value); return err == nil }
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
		respond(a.Store.RegisterDevice(ctx, d))
	case n == 3 && parts[1] == "me" && parts[2] == "devices" && method == "GET":
		items, err := a.Store.MyDevices(ctx, p.UserID)
		respond(map[string]any{"items": items}, err)
	case n == 3 && parts[1] == "devices" && isID(parts[2]) && method == "DELETE":
		respond(map[string]bool{"revoked": true}, a.Store.RevokeDevice(ctx, p.UserID, parts[2]))
	case n == 4 && parts[1] == "devices" && isID(parts[2]) && parts[3] == "keys":
		device := parts[2]
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
		raw, ok := body()
		if !ok {
			return true
		}
		var ids []string
		if len(raw) != 1 || json.Unmarshal(raw["messageIds"], &ids) != nil || len(ids) == 0 || len(ids) > 100 {
			a.failure(w, r, 422, "VALIDATION", "send 1–100 messageIds")
			return true
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
		respond(a.Store.OpenConversation(ctx, p.UserID, target))
	case n == 2 && parts[1] == "conversations" && method == "GET":
		paged(a, w, r, p, "conversations", func(pg page) ([]domain.Conversation, error) {
			return a.Store.ListConversations(ctx, p.UserID, pg.before, pg.id, pg.limit)
		}, func(c domain.Conversation) (time.Time, string) {
			if c.LastMessageAt != nil {
				return *c.LastMessageAt, c.ConversationID
			}
			return c.CreatedAt, c.ConversationID
		}, nil)
	case n == 3 && parts[1] == "conversations" && isID(parts[2]) && method == "GET":
		respond(a.Store.Conversation(ctx, p.UserID, parts[2]))
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
		created, err := a.Store.SendMessage(ctx, p.UserID, parts[2], m)
		respond(map[string]any{"messageId": m.MessageID, "createdAt": created}, err)
	default:
		return false
	}
	return true
}
