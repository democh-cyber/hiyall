package httpapi

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// listCursor is bound to the principal and to one list, so it cannot be replayed
// by another account or against another endpoint.
type listCursor struct {
	User   string    `json:"u"`
	Kind   string    `json:"k"`
	ID     string    `json:"i"`
	Before time.Time `json:"b"`
	Exp    int64     `json:"e"`
}

type page struct {
	limit  int
	before *time.Time
	id     string
}

func (a *API) signList(c listCursor) string {
	data, _ := json.Marshal(c)
	mac := hmac.New(sha256.New, a.cursorKey[:])
	mac.Write(data)
	return base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (a *API) pageOf(w http.ResponseWriter, r *http.Request, p store.Principal, kind string) (page, bool) {
	result := page{limit: 20, id: uuid.Nil.String()}
	if value := r.URL.Query().Get("limit"); value != "" {
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 50 {
			a.failure(w, r, 422, "VALIDATION", "limit must be 1–50")
			return result, false
		}
		result.limit = n
	}
	raw := r.URL.Query().Get("cursor")
	if raw == "" {
		return result, true
	}
	parts := strings.Split(raw, ".")
	valid := len(raw) < 2048 && len(parts) == 2
	var c listCursor
	if valid {
		data, e := base64.RawURLEncoding.DecodeString(parts[0])
		sig, e2 := base64.RawURLEncoding.DecodeString(parts[1])
		mac := hmac.New(sha256.New, a.cursorKey[:])
		mac.Write(data)
		valid = e == nil && e2 == nil && hmac.Equal(sig, mac.Sum(nil)) && json.Unmarshal(data, &c) == nil && c.User == p.UserID && c.Kind == kind && c.Exp > time.Now().Unix()
		valid = valid && isID(c.ID)
	}
	if !valid {
		a.failure(w, r, 422, "INVALID_CURSOR", "Reload this list")
		return result, false
	}
	result.before, result.id = &c.Before, c.ID
	return result, true
}

// paged fetches one extra row to decide whether another page exists.
func paged[T any](a *API, w http.ResponseWriter, r *http.Request, p store.Principal, kind string, fetch func(page) ([]T, error), key func(T) (time.Time, string), extra map[string]any) {
	pg, ok := a.pageOf(w, r, p, kind)
	if !ok {
		return
	}
	limit := pg.limit
	pg.limit++
	items, err := fetch(pg)
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(items) > limit {
		items = items[:limit]
		at, id := key(items[limit-1])
		next = a.signList(listCursor{User: p.UserID, Kind: kind, ID: id, Before: at, Exp: time.Now().Add(15 * time.Minute).Unix()})
	}
	body := map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil}
	for k, v := range extra {
		body[k] = v
	}
	a.ok(w, r, body)
}

func connectionKey(c domain.Connection) (time.Time, string) { return c.Since, c.User.UserID }

// socialRoute serves the graph and activity endpoints; it reports whether it handled the path.
func (a *API) socialRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n := len(parts)
	if n < 2 || parts[0] != "v1" {
		return false
	}
	write := func() bool {
		if a.graph.allow(p.UserID) {
			return true
		}
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
		return false
	}
	connections := func(kind, owner string) {
		allowed := a.Store.CanSeeConnections
		if kind == "friends" {
			allowed = a.Store.CanSeeFriends
		}
		if err := allowed(ctx, p.UserID, owner); err != nil {
			a.error(w, r, err)
			return
		}
		paged(a, w, r, p, kind+":"+owner, func(pg page) ([]domain.Connection, error) {
			return a.Store.ListConnections(ctx, kind, p.UserID, owner, pg.before, pg.id, pg.limit, a.signer(ctx))
		}, connectionKey, nil)
	}
	method := r.Method
	switch {
	// /v1/users/{id}/follow | friend-requests | friendship | friends | followers | following
	case n == 4 && parts[1] == "users" && isID(parts[2]):
		target := parts[2]
		switch {
		case parts[3] == "follow" && method == "POST":
			if !write() {
				return true
			}
			state, err := a.Store.Follow(ctx, p.UserID, target)
			if err != nil {
				a.error(w, r, err)
				return true
			}
			a.signal(ctx, "activity", nil, target)
			kind := "follow"
			if state == "pending" {
				kind = "follow_request"
			}
			a.wakeFrom(kind, p.UserID, target)
			a.ok(w, r, map[string]string{"following": state})
		case parts[3] == "follow" && method == "DELETE":
			if err := a.Store.Unfollow(ctx, p.UserID, target); err != nil {
				a.error(w, r, err)
				return true
			}
			a.signal(ctx, "activity", nil, target)
			a.ok(w, r, map[string]string{"following": "none"})
		case parts[3] == "friend-requests" && method == "POST":
			if !write() {
				return true
			}
			value, err := a.Store.SendFriendRequest(ctx, p.UserID, target, a.signer(ctx))
			if err != nil {
				a.error(w, r, err)
				return true
			}
			a.signal(ctx, "activity", nil, target)
			// A request that crossed the other person's own becomes a friendship at once.
			kind := "friend_request"
			if value.Status == "accepted" {
				kind = "friend_accepted"
			}
			a.wakeFrom(kind, p.UserID, target)
			a.ok(w, r, value)
		case parts[3] == "friendship" && method == "DELETE":
			if err := a.Store.Unfriend(ctx, p.UserID, target); err != nil {
				a.error(w, r, err)
				return true
			}
			a.ok(w, r, map[string]string{"friendship": "none"})
		case (parts[3] == "friends" || parts[3] == "followers" || parts[3] == "following") && method == "GET":
			connections(parts[3], target)
		default:
			return false
		}
		return true
	// /v1/users/{id}/follow-requests/accept: the owner approves follower {id}.
	case n == 5 && parts[1] == "users" && isID(parts[2]) && parts[3] == "follow-requests" && parts[4] == "accept" && method == "POST":
		if !write() {
			return true
		}
		if err := a.Store.RespondFollowRequest(ctx, p.UserID, parts[2], true); err != nil {
			a.error(w, r, err)
			return true
		}
		a.signal(ctx, "activity", nil, parts[2], p.UserID)
		a.wakeFrom("follow_accepted", p.UserID, parts[2])
		a.ok(w, r, map[string]string{"follower": "active"})
		return true
	case n == 3 && parts[1] == "me" && method == "GET":
		switch parts[2] {
		case "friends", "followers", "following":
			connections(parts[2], p.UserID)
		case "visitors":
			// Only ever the caller's own: there is no route for another member's visitors.
			if !a.lists.allow(p.UserID) {
				w.Header().Set("Retry-After", "1")
				a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
				return true
			}
			limitTotal := a.entitlementsFor(ctx, p.UserID).VisitorListLimit
			paged(a, w, r, p, "visitors", func(pg page) ([]domain.Visitor, error) {
				return a.Store.ListVisitors(ctx, p.UserID, pg.before, pg.id, pg.limit, limitTotal, a.signer(ctx))
			}, func(v domain.Visitor) (time.Time, string) { return v.FirstVisitedAt, v.User.UserID }, nil)
		case "follow-requests":
			paged(a, w, r, p, "follow_requests", func(pg page) ([]domain.Connection, error) {
				return a.Store.ListConnections(ctx, "follow_requests", p.UserID, p.UserID, pg.before, pg.id, pg.limit, a.signer(ctx))
			}, connectionKey, nil)
		case "friend-requests":
			direction := r.URL.Query().Get("direction")
			if direction == "" {
				direction = "incoming"
			}
			if direction != "incoming" && direction != "outgoing" {
				a.failure(w, r, 422, "VALIDATION", "direction must be incoming or outgoing")
				return true
			}
			paged(a, w, r, p, "friend_requests:"+direction, func(pg page) ([]domain.FriendRequest, error) {
				return a.Store.ListFriendRequests(ctx, p.UserID, direction == "incoming", pg.before, pg.id, pg.limit, a.signer(ctx))
			}, func(f domain.FriendRequest) (time.Time, string) { return f.CreatedAt, f.RequestID }, nil)
		default:
			return false
		}
		return true
	// /v1/me/follow-requests/{id} declines; /v1/me/followers/{id} removes a follower.
	case n == 4 && parts[1] == "me" && isID(parts[3]) && method == "DELETE" && (parts[2] == "follow-requests" || parts[2] == "followers"):
		var err error
		if parts[2] == "follow-requests" {
			err = a.Store.RespondFollowRequest(ctx, p.UserID, parts[3], false)
		} else {
			err = a.Store.RemoveFollower(ctx, p.UserID, parts[3])
		}
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.signal(ctx, "activity", nil, parts[3], p.UserID)
		a.ok(w, r, map[string]bool{"removed": true})
		return true
	case parts[1] == "friend-requests" && n >= 3 && isID(parts[2]):
		id := parts[2]
		switch {
		case n == 4 && (parts[3] == "accept" || parts[3] == "decline") && method == "POST":
			value, err := a.Store.RespondFriendRequest(ctx, p.UserID, id, parts[3] == "accept", a.signer(ctx))
			if err != nil {
				a.error(w, r, err)
				return true
			}
			a.signal(ctx, "activity", nil, value.Sender.UserID, value.Recipient.UserID)
			if parts[3] == "accept" {
				a.wakeFrom("friend_accepted", p.UserID, value.Sender.UserID)
			}
			a.ok(w, r, value)
		case n == 3 && method == "DELETE":
			if err := a.Store.CancelFriendRequest(ctx, p.UserID, id); err != nil {
				a.error(w, r, err)
				return true
			}
			a.ok(w, r, map[string]bool{"cancelled": true})
		default:
			return false
		}
		return true
	case parts[1] == "notifications":
		switch {
		case n == 2 && method == "GET":
			unreadOnly := r.URL.Query().Get("unreadOnly") == "true"
			unread, err := a.Store.UnreadNotifications(ctx, p.UserID)
			if err != nil {
				a.error(w, r, err)
				return true
			}
			kind := "notifications"
			if unreadOnly {
				kind = "notifications:unread"
			}
			paged(a, w, r, p, kind, func(pg page) ([]domain.Notification, error) {
				return a.Store.ListNotifications(ctx, p.UserID, unreadOnly, pg.before, pg.id, pg.limit, a.signer(ctx))
			}, func(n domain.Notification) (time.Time, string) { return n.CreatedAt, n.NotificationID }, map[string]any{"unreadCount": unread})
		case n == 3 && parts[2] == "unread-count" && method == "GET":
			unread, err := a.Store.UnreadNotifications(ctx, p.UserID)
			if err != nil {
				a.error(w, r, err)
				return true
			}
			a.ok(w, r, map[string]int{"unreadCount": unread})
		case n == 3 && parts[2] == "read-all" && method == "POST":
			count, err := a.Store.MarkAllNotificationsRead(ctx, p.UserID)
			if err != nil {
				a.error(w, r, err)
				return true
			}
			a.ok(w, r, map[string]int64{"updated": count})
		case n == 4 && isID(parts[2]) && parts[3] == "read" && method == "POST":
			if err := a.Store.MarkNotificationRead(ctx, p.UserID, parts[2]); err != nil {
				a.error(w, r, err)
				return true
			}
			a.ok(w, r, map[string]bool{"read": true})
		default:
			return false
		}
		return true
	}
	return false
}
