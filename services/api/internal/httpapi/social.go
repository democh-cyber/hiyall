package httpapi

import (
	"net/http"
	"strconv"
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

func (a *API) signList(c listCursor) string { return sealCursor(a, "", c) }

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
	var c listCursor
	if !openCursor(a, "", raw, &c) || c.User != p.UserID || c.Kind != kind || c.Exp <= time.Now().Unix() || !isID(c.ID) {
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

// The graph and activity endpoints. Writes that start something between two members (follow, friend request,
// approving a follower) take the per-account graph limit in the route table before the handler runs.

// connections lists one of owner's relationship lists after the audience checks.
func (a *API) connections(w http.ResponseWriter, r *http.Request, p store.Principal, kind, owner string) {
	ctx := r.Context()
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

// userConnections is GET /v1/users/{userId}/friends, /followers and /following; ownConnections is the same
// under /v1/me.
func userConnections(kind string) handlerFunc {
	return func(a *API, w http.ResponseWriter, r *http.Request, p store.Principal) {
		a.connections(w, r, p, kind, r.PathValue("userId"))
	}
}

func ownConnections(kind string) handlerFunc {
	return func(a *API, w http.ResponseWriter, r *http.Request, p store.Principal) {
		a.connections(w, r, p, kind, p.UserID)
	}
}

func (a *API) follow(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, target := r.Context(), r.PathValue("userId")
	state, err := a.Store.Follow(ctx, p.UserID, target, a.entitlementsFor(ctx, p.UserID))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "activity", nil, target)
	kind := "follow"
	if state == "pending" {
		kind = "follow_request"
	}
	a.wakeFrom(kind, p.UserID, target)
	a.ok(w, r, map[string]string{"following": state})
}

func (a *API) unfollow(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, target := r.Context(), r.PathValue("userId")
	if err := a.Store.Unfollow(ctx, p.UserID, target); err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "activity", nil, target)
	a.ok(w, r, map[string]string{"following": "none"})
}

func (a *API) sendFriendRequest(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, target := r.Context(), r.PathValue("userId")
	value, err := a.Store.SendFriendRequest(ctx, p.UserID, target, a.signer(ctx), a.entitlementsFor(ctx, p.UserID))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "activity", nil, target)
	// A request that crossed the other person's own becomes a friendship at once.
	kind := "friend_request"
	if value.Status == "accepted" {
		kind = "friend_accepted"
	}
	a.wakeFrom(kind, p.UserID, target)
	a.ok(w, r, value)
}

func (a *API) unfriend(w http.ResponseWriter, r *http.Request, p store.Principal) {
	if err := a.Store.Unfriend(r.Context(), p.UserID, r.PathValue("userId")); err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]string{"friendship": "none"})
}

// acceptFollowRequest is POST /v1/users/{userId}/follow-requests/accept: the owner approves follower {userId}.
func (a *API) acceptFollowRequest(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, follower := r.Context(), r.PathValue("userId")
	if err := a.Store.RespondFollowRequest(ctx, p.UserID, follower, true); err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "activity", nil, follower, p.UserID)
	a.wakeFrom("follow_accepted", p.UserID, follower)
	a.ok(w, r, map[string]string{"follower": "active"})
}

// Only ever the caller's own: there is no route for another member's visitors.
func (a *API) visitors(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	limitTotal := a.entitlementsFor(ctx, p.UserID).VisitorListLimit
	paged(a, w, r, p, "visitors", func(pg page) ([]domain.Visitor, error) {
		return a.Store.ListVisitors(ctx, p.UserID, pg.before, pg.id, pg.limit, limitTotal, a.signer(ctx))
	}, func(v domain.Visitor) (time.Time, string) { return v.FirstVisitedAt, v.User.UserID }, nil)
}

func (a *API) followRequests(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	paged(a, w, r, p, "follow_requests", func(pg page) ([]domain.Connection, error) {
		return a.Store.ListConnections(ctx, "follow_requests", p.UserID, p.UserID, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, connectionKey, nil)
}

func (a *API) friendRequests(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	direction := r.URL.Query().Get("direction")
	if direction == "" {
		direction = "incoming"
	}
	if direction != "incoming" && direction != "outgoing" {
		a.failure(w, r, 422, "VALIDATION", "direction must be incoming or outgoing")
		return
	}
	paged(a, w, r, p, "friend_requests:"+direction, func(pg page) ([]domain.FriendRequest, error) {
		return a.Store.ListFriendRequests(ctx, p.UserID, direction == "incoming", pg.before, pg.id, pg.limit, a.signer(ctx))
	}, func(f domain.FriendRequest) (time.Time, string) { return f.CreatedAt, f.RequestID }, nil)
}

// declineFollowRequest is DELETE /v1/me/follow-requests/{userId}.
func (a *API) declineFollowRequest(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, follower := r.Context(), r.PathValue("userId")
	if err := a.Store.RespondFollowRequest(ctx, p.UserID, follower, false); err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "activity", nil, follower, p.UserID)
	a.ok(w, r, map[string]bool{"removed": true})
}

// removeFollower is DELETE /v1/me/followers/{userId}.
func (a *API) removeFollower(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, follower := r.Context(), r.PathValue("userId")
	if err := a.Store.RemoveFollower(ctx, p.UserID, follower); err != nil {
		a.error(w, r, err)
		return
	}
	a.signal(ctx, "activity", nil, follower, p.UserID)
	a.ok(w, r, map[string]bool{"removed": true})
}

// respondFriendRequest is POST /v1/friend-requests/{requestId}/accept and /decline.
func respondFriendRequest(accept bool) handlerFunc {
	return func(a *API, w http.ResponseWriter, r *http.Request, p store.Principal) {
		ctx := r.Context()
		value, err := a.Store.RespondFriendRequest(ctx, p.UserID, r.PathValue("requestId"), accept, a.signer(ctx))
		if err != nil {
			a.error(w, r, err)
			return
		}
		a.signal(ctx, "activity", nil, value.Sender.UserID, value.Recipient.UserID)
		if accept {
			a.wakeFrom("friend_accepted", p.UserID, value.Sender.UserID)
		}
		a.ok(w, r, value)
	}
}

func (a *API) cancelFriendRequest(w http.ResponseWriter, r *http.Request, p store.Principal) {
	if err := a.Store.CancelFriendRequest(r.Context(), p.UserID, r.PathValue("requestId")); err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]bool{"cancelled": true})
}

func (a *API) notifications(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	unreadOnly := r.URL.Query().Get("unreadOnly") == "true"
	unread, more, err := a.Store.UnreadBadge(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	kind := "notifications"
	if unreadOnly {
		kind = "notifications:unread"
	}
	paged(a, w, r, p, kind, func(pg page) ([]domain.Notification, error) {
		return a.Store.ListNotifications(ctx, p.UserID, unreadOnly, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, func(n domain.Notification) (time.Time, string) { return n.CreatedAt, n.NotificationID }, map[string]any{"unreadCount": unread, "unreadMore": more})
}

func (a *API) unreadCount(w http.ResponseWriter, r *http.Request, p store.Principal) {
	unread, more, err := a.Store.UnreadBadge(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	// unreadCount stops at 99; unreadMore tells the app to show "99+".
	a.ok(w, r, map[string]any{"unreadCount": unread, "unreadMore": more})
}

func (a *API) readAllNotifications(w http.ResponseWriter, r *http.Request, p store.Principal) {
	count, err := a.Store.MarkAllNotificationsRead(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]int64{"updated": count})
}

func (a *API) readNotification(w http.ResponseWriter, r *http.Request, p store.Principal) {
	if err := a.Store.MarkNotificationRead(r.Context(), p.UserID, r.PathValue("notificationId")); err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]bool{"read": true})
}
