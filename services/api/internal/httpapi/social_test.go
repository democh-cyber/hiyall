package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
)

const (
	cara = "019a4000-0000-7000-8000-0000000000c1"
	dev  = "019a4000-0000-7000-8000-0000000000d1"
	eli  = "019a4000-0000-7000-8000-0000000000e1"
	xan  = "019a4000-0000-7000-8000-0000000000f1"
	yui  = "019a4000-0000-7000-8000-0000000000f2"
)

type socialHarness struct {
	t   *testing.T
	ctx context.Context
	db  *store.Store
	api *API
}

func newSocialHarness(t *testing.T) *socialHarness {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "kairova_test" {
		t.Fatal("integration tests require database named kairova_test")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions,blocks,outbox_events,follows,friendships,notifications,discovery_eligibility CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	api := New(db, func(_ context.Context, token string) (store.Principal, error) {
		var active bool
		if err := db.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE user_id::text=$1 AND status='active')`, token).Scan(&active); err != nil || !active {
			return store.Principal{}, domain.ErrUnauthorized
		}
		return store.Principal{UserID: token, SessionID: token}, nil
	}, false, "")
	h := &socialHarness{t, ctx, db, api}
	for _, u := range [][2]string{{cara, "cara"}, {dev, "dev_k"}, {eli, "eli"}, {xan, "xan"}, {yui, "yui"}} {
		h.user(u[0], u[1])
	}
	return h
}

// user provisions a test account with the product defaults: friends-only profile,
// follow approval and friend requests from everyone.
func (h *socialHarness) user(id, username string) {
	profile, _ := json.Marshal(domain.Profile{Username: username, DisplayName: strings.ToUpper(username[:1]) + username[1:], Timezone: "UTC", Locale: "en", ProfileAudience: "friends", ProfileAccent: "lime", ProfilePattern: "glow", AvatarFrame: "minimal", Headline: "hi from " + username})
	privacy, _ := json.Marshal(domain.DefaultPrivacy())
	h.exec(`INSERT INTO users(user_id) VALUES($1)`, id)
	h.exec(`INSERT INTO profiles(user_id,username,data) VALUES($1,$2,$3)`, id, username, profile)
	h.exec(`INSERT INTO privacy_settings(user_id,data) VALUES($1,$2)`, id, privacy)
}

func (h *socialHarness) exec(sql string, args ...any) {
	h.t.Helper()
	if _, err := h.db.Pool.Exec(h.ctx, sql, args...); err != nil {
		h.t.Fatal(err)
	}
}

// policy overwrites one privacy key directly, keeping test setup independent of versions.
func (h *socialHarness) policy(id, key string, value any) {
	h.t.Helper()
	raw, _ := json.Marshal(value)
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY[$2::text],$3::jsonb) WHERE user_id=$1`, id, key, string(raw))
}

type reply struct {
	status int
	data   map[string]any
	code   string
}

func (h *socialHarness) call(actor, method, path string) reply {
	h.t.Helper()
	return h.send(actor, method, path, nil)
}

func (h *socialHarness) send(actor, method, path string, payload any) reply {
	h.t.Helper()
	raw := []byte{}
	if payload != nil {
		raw, _ = json.Marshal(payload)
	}
	r := httptest.NewRequest(method, path, bytes.NewBuffer(raw))
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = "127.0.0.1:50000"
	r.Header.Set("Authorization", "Bearer "+actor)
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	var body struct {
		Data  map[string]any    `json:"data"`
		Error map[string]string `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		h.t.Fatalf("%s %s: %s", method, path, w.Body.String())
	}
	return reply{w.Code, body.Data, body.Error["code"]}
}

func (h *socialHarness) expect(got reply, status int, code string) reply {
	h.t.Helper()
	if got.status != status || got.code != code {
		h.t.Fatalf("got %d %q, want %d %q (%v)", got.status, got.code, status, code, got.data)
	}
	return got
}

func (h *socialHarness) ok(actor, method, path string) map[string]any {
	h.t.Helper()
	return h.expect(h.call(actor, method, path), 200, "").data
}

func items(data map[string]any) []map[string]any {
	raw, _ := data["items"].([]any)
	result := make([]map[string]any, len(raw))
	for i, v := range raw {
		result[i] = v.(map[string]any)
	}
	return result
}

// ids extracts user ids from connection rows ({user:{userId}}) or actor ids from notifications.
func ids(data map[string]any) []string {
	result := []string{}
	for _, item := range items(data) {
		switch {
		case item["user"] != nil:
			result = append(result, item["user"].(map[string]any)["userId"].(string))
		case item["actors"] != nil:
			result = append(result, item["actors"].([]any)[0].(map[string]any)["userId"].(string)+":"+item["event"].(string))
		case item["sender"] != nil:
			result = append(result, item["sender"].(map[string]any)["userId"].(string)+">"+item["recipient"].(map[string]any)["userId"].(string))
		}
	}
	return result
}

func same(t *testing.T, got []string, want ...string) {
	t.Helper()
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func (h *socialHarness) relationship(viewer, target string) map[string]any {
	h.t.Helper()
	return h.ok(viewer, "GET", "/v1/users/"+target+"/profile")["relationship"].(map[string]any)
}

func (h *socialHarness) stats(id string) domain.SocialStats {
	h.t.Helper()
	p, err := h.db.GetProfile(h.ctx, id)
	if err != nil {
		h.t.Fatal(err)
	}
	return *p.SocialStats
}

func TestFollowPoliciesRequestsAndVisibility(t *testing.T) {
	h := newSocialHarness(t)

	// Approval policy (default): the follow waits for the owner.
	same(t, []string{h.ok(alice, "POST", "/v1/users/"+bob+"/follow")["following"].(string)}, "pending")
	same(t, []string{h.ok(alice, "POST", "/v1/users/"+bob+"/follow")["following"].(string)}, "pending")
	rel := h.relationship(alice, bob)
	if rel["following"] != "pending" || rel["canFollow"] != false {
		t.Fatalf("pending follow not reflected: %v", rel)
	}
	inbox := h.ok(bob, "GET", "/v1/notifications")
	same(t, ids(inbox), alice+":follow.requested")
	if inbox["unreadCount"] != float64(1) {
		t.Fatalf("repeat follow duplicated activity: %v", inbox["unreadCount"])
	}
	same(t, ids(h.ok(bob, "GET", "/v1/me/follow-requests")), alice)

	// Only the owner can approve; everyone else sees nothing to approve.
	h.expect(h.call(cara, "POST", "/v1/users/"+alice+"/follow-requests/accept"), 404, "NOT_FOUND")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow-requests/accept")
	h.expect(h.call(bob, "POST", "/v1/users/"+alice+"/follow-requests/accept"), 404, "NOT_FOUND")
	if h.relationship(alice, bob)["following"] != "active" || h.relationship(bob, alice)["followedBy"] != true {
		t.Fatal("approved follow not active")
	}
	same(t, ids(h.ok(bob, "GET", "/v1/notifications")))
	same(t, ids(h.ok(alice, "GET", "/v1/notifications")), bob+":follow.accepted")
	same(t, ids(h.ok(bob, "GET", "/v1/me/followers")), alice)
	same(t, ids(h.ok(alice, "GET", "/v1/me/following")), bob)
	if s := h.stats(bob); s.Followers != 1 {
		t.Fatalf("followers=%d", s.Followers)
	}

	// A followers-only profile opens for followers and stays locked for others.
	h.policy(bob, "profileAudience", "followers")
	if p := h.ok(alice, "GET", "/v1/users/"+bob+"/profile"); p["locked"] != false || p["bio"] == nil {
		t.Fatalf("follower could not see followers-only profile: %v", p)
	}
	if p := h.ok(cara, "GET", "/v1/users/"+bob+"/profile"); p["locked"] != true || p["headline"] != nil {
		t.Fatalf("non-follower saw followers-only profile: %v", p)
	}
	h.policy(bob, "profileAudience", "private")
	if p := h.ok(alice, "GET", "/v1/users/"+bob+"/profile"); p["locked"] != true {
		t.Fatal("private profile opened for a follower")
	}

	// Open and closed policies.
	h.policy(cara, "followPolicy", "everyone")
	same(t, []string{h.ok(alice, "POST", "/v1/users/"+cara+"/follow")["following"].(string)}, "active")
	same(t, ids(h.ok(cara, "GET", "/v1/notifications")), alice+":follow.started")
	h.policy(dev, "followPolicy", "nobody")
	h.expect(h.call(alice, "POST", "/v1/users/"+dev+"/follow"), 403, "FOLLOW_NOT_ALLOWED")
	if h.relationship(alice, dev)["canFollow"] != false {
		t.Fatal("closed account advertised follow")
	}
	h.expect(h.call(alice, "POST", "/v1/users/"+alice+"/follow"), 422, "VALIDATION")
	h.expect(h.call(alice, "POST", "/v1/users/019a4000-0000-7000-8000-00000000ffff/follow"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/users/not-a-uuid/follow"), 404, "NOT_FOUND")

	// Withdrawing a pending request also withdraws its activity row.
	h.ok(alice, "POST", "/v1/users/"+eli+"/follow")
	h.ok(alice, "DELETE", "/v1/users/"+eli+"/follow")
	same(t, ids(h.ok(eli, "GET", "/v1/notifications")))
	same(t, ids(h.ok(eli, "GET", "/v1/me/follow-requests")))
	h.ok(alice, "DELETE", "/v1/users/"+eli+"/follow")

	// Declining and removing.
	h.ok(cara, "POST", "/v1/users/"+eli+"/follow")
	h.ok(eli, "DELETE", "/v1/me/follow-requests/"+cara)
	h.expect(h.call(eli, "DELETE", "/v1/me/follow-requests/"+cara), 404, "NOT_FOUND")
	if h.relationship(cara, eli)["following"] != "none" {
		t.Fatal("declined follow still pending")
	}
	h.ok(bob, "DELETE", "/v1/me/followers/"+alice)
	if h.relationship(alice, bob)["following"] != "none" {
		t.Fatal("removed follower still following")
	}
}

func TestFriendRequestsLifecycleAndPolicies(t *testing.T) {
	h := newSocialHarness(t)

	request := h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	id := request["requestId"].(string)
	if request["status"] != "pending" {
		t.Fatalf("status %v", request["status"])
	}
	if again := h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests"); again["requestId"] != id {
		t.Fatal("resending created a second request")
	}
	same(t, ids(h.ok(bob, "GET", "/v1/me/friend-requests")), alice+">"+bob)
	same(t, ids(h.ok(alice, "GET", "/v1/me/friend-requests?direction=outgoing")), alice+">"+bob)
	same(t, ids(h.ok(alice, "GET", "/v1/me/friend-requests")))
	h.expect(h.call(alice, "GET", "/v1/me/friend-requests?direction=sideways"), 422, "VALIDATION")
	same(t, ids(h.ok(bob, "GET", "/v1/notifications")), alice+":friend.requested")
	rel := h.relationship(bob, alice)
	if rel["friendship"] != "pending_incoming" || rel["friendRequestId"] != id {
		t.Fatalf("incoming request not reflected: %v", rel)
	}

	// Strangers and the sender cannot answer the request.
	h.expect(h.call(cara, "POST", "/v1/friend-requests/"+id+"/accept"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/friend-requests/"+id+"/accept"), 404, "NOT_FOUND")
	h.expect(h.call(cara, "DELETE", "/v1/friend-requests/"+id), 404, "NOT_FOUND")

	// A decline starts a cooldown for the sender.
	if declined := h.ok(bob, "POST", "/v1/friend-requests/"+id+"/decline"); declined["status"] != "declined" {
		t.Fatal("decline not recorded")
	}
	same(t, ids(h.ok(bob, "GET", "/v1/notifications")))
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/friend-requests"), 429, "REQUEST_COOLDOWN")
	h.expect(h.call(bob, "POST", "/v1/friend-requests/"+id+"/accept"), 404, "NOT_FOUND")

	// Crossing requests become a friendship.
	h.ok(cara, "POST", "/v1/users/"+dev+"/friend-requests")
	if accepted := h.ok(dev, "POST", "/v1/users/"+cara+"/friend-requests"); accepted["status"] != "accepted" {
		t.Fatalf("mutual request not accepted: %v", accepted)
	}
	same(t, ids(h.ok(cara, "GET", "/v1/notifications")), dev+":friend.accepted")
	same(t, ids(h.ok(dev, "GET", "/v1/notifications")))
	same(t, ids(h.ok(cara, "GET", "/v1/me/friends")), dev)
	same(t, ids(h.ok(dev, "GET", "/v1/me/friends")), cara)
	if s := h.stats(cara); s.Friends != 1 {
		t.Fatalf("friends=%d", s.Friends)
	}
	// Friends see a friends-only profile; strangers get the locked card.
	if p := h.ok(cara, "GET", "/v1/users/"+dev+"/profile"); p["locked"] != false || p["headline"] != "hi from dev_k" {
		t.Fatalf("friend could not see friends-only profile: %v", p)
	}
	if p := h.ok(alice, "GET", "/v1/users/"+dev+"/profile"); p["locked"] != true {
		t.Fatal("stranger saw friends-only profile")
	}

	// Cancel is sender-only and removes the recipient's activity row.
	cancel := h.ok(alice, "POST", "/v1/users/"+eli+"/friend-requests")["requestId"].(string)
	h.ok(alice, "DELETE", "/v1/friend-requests/"+cancel)
	same(t, ids(h.ok(eli, "GET", "/v1/notifications")))
	h.expect(h.call(alice, "DELETE", "/v1/friend-requests/"+cancel), 404, "NOT_FOUND")
	h.expect(h.call(eli, "POST", "/v1/friend-requests/"+cancel+"/accept"), 404, "NOT_FOUND")

	// requestsFrom: nobody, followers, and friends of friends.
	h.policy(eli, "requestsFrom", "nobody")
	h.expect(h.call(alice, "POST", "/v1/users/"+eli+"/friend-requests"), 403, "REQUEST_NOT_ALLOWED")
	if h.relationship(alice, eli)["canFriendRequest"] != false {
		t.Fatal("closed account advertised friend requests")
	}
	h.policy(eli, "requestsFrom", "followers")
	h.expect(h.call(alice, "POST", "/v1/users/"+eli+"/friend-requests"), 403, "REQUEST_NOT_ALLOWED")
	h.policy(eli, "followPolicy", "everyone")
	h.ok(alice, "POST", "/v1/users/"+eli+"/follow")
	h.ok(alice, "POST", "/v1/users/"+eli+"/friend-requests")
	h.policy(eli, "requestsFrom", "friends")
	h.expect(h.call(cara, "POST", "/v1/users/"+eli+"/friend-requests"), 403, "REQUEST_NOT_ALLOWED")
	h.policy(dev, "requestsFrom", "everyone")
	h.ok(eli, "POST", "/v1/users/"+dev+"/friend-requests")
	h.ok(dev, "POST", "/v1/users/"+eli+"/friend-requests") // eli and dev are now friends
	if h.relationship(cara, eli)["canFriendRequest"] != true {
		t.Fatal("friend of a friend not allowed")
	}
	h.ok(cara, "POST", "/v1/users/"+eli+"/friend-requests")

	// Unfriending is idempotent.
	h.ok(cara, "DELETE", "/v1/users/"+dev+"/friendship")
	h.ok(cara, "DELETE", "/v1/users/"+dev+"/friendship")
	same(t, ids(h.ok(cara, "GET", "/v1/me/friends")))
	if h.relationship(cara, dev)["friendship"] != "none" {
		t.Fatal("unfriend not reflected")
	}
}

func TestConnectionListsRespectPrivacy(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(bob, "followPolicy", "everyone")
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")

	// The owner always sees their own lists; others need both profile and connections access.
	same(t, ids(h.ok(bob, "GET", "/v1/users/"+bob+"/followers")), cara, alice)
	h.expect(h.call(dev, "GET", "/v1/users/"+bob+"/followers"), 403, "CONNECTIONS_PRIVATE")
	h.policy(bob, "profileAudience", "public")
	h.expect(h.call(dev, "GET", "/v1/users/"+bob+"/followers"), 403, "CONNECTIONS_PRIVATE")
	h.policy(bob, "fieldAudiences", map[string]string{"connections": "followers"})
	h.expect(h.call(dev, "GET", "/v1/users/"+bob+"/followers"), 403, "CONNECTIONS_PRIVATE")
	same(t, ids(h.ok(alice, "GET", "/v1/users/"+bob+"/followers")), cara, alice)
	h.policy(bob, "fieldAudiences", map[string]string{"connections": "everyone"})
	same(t, ids(h.ok(dev, "GET", "/v1/users/"+bob+"/followers")), cara, alice)
	h.expect(h.call(dev, "GET", "/v1/users/"+alice+"/following"), 403, "CONNECTIONS_PRIVATE")
	// Someone the viewer blocked never resurfaces in another person's list.
	h.ok(dev, "POST", "/v1/users/"+cara+"/block")
	same(t, ids(h.ok(dev, "GET", "/v1/users/"+bob+"/followers")), alice)
	// Deactivated accounts drop out of lists.
	h.exec(`UPDATE users SET status='deactivated' WHERE user_id=$1`, alice)
	same(t, ids(h.ok(bob, "GET", "/v1/me/followers")), cara)
}

func TestBlockSeversEverything(t *testing.T) {
	h := newSocialHarness(t)
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow-requests/accept")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	if s := h.stats(alice); s != (domain.SocialStats{Friends: 1, Following: 1, Followers: 0}) {
		t.Fatalf("setup stats %+v", s)
	}

	h.ok(bob, "POST", "/v1/users/"+alice+"/block")
	for _, id := range []string{alice, bob} {
		if s := h.stats(id); s != (domain.SocialStats{}) {
			t.Fatalf("block left relationships for %s: %+v", id, s)
		}
	}
	same(t, ids(h.ok(alice, "GET", "/v1/notifications")))
	same(t, ids(h.ok(bob, "GET", "/v1/notifications")))
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/profile"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/follow"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/friend-requests"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/followers"), 404, "NOT_FOUND")

	// Unblocking restores visibility but not the old relationships.
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/block")
	rel := h.relationship(alice, bob)
	if rel["following"] != "none" || rel["friendship"] != "none" || rel["followedBy"] != false {
		t.Fatalf("unblock restored relationships: %v", rel)
	}
	// A deactivated account can still be unblocked, but not newly blocked.
	h.ok(cara, "POST", "/v1/users/"+dev+"/block")
	h.exec(`UPDATE users SET status='deactivated' WHERE user_id=$1`, dev)
	h.ok(cara, "DELETE", "/v1/users/"+dev+"/block")
	h.expect(h.call(cara, "POST", "/v1/users/"+dev+"/block"), 404, "NOT_FOUND")
}

func TestActivityFeedPagingReadStateAndOwnership(t *testing.T) {
	h := newSocialHarness(t)
	for _, actor := range []string{bob, cara, dev, eli, xan} {
		h.ok(actor, "POST", "/v1/users/"+alice+"/follow")
	}
	first := h.ok(alice, "GET", "/v1/notifications?limit=2")
	if len(items(first)) != 2 || first["hasMore"] != true || first["unreadCount"] != float64(5) {
		t.Fatalf("first page wrong: %v", first)
	}
	row := items(first)[0]
	if row["type"] != "follow" || row["targetType"] != "request" || row["text"] != "requested to follow you" || row["count"] != float64(1) {
		t.Fatalf("contract fields wrong: %v", row)
	}
	seen := map[string]bool{}
	cursor := first["nextCursor"].(string)
	for _, item := range items(first) {
		seen[item["notificationId"].(string)] = true
	}
	for cursor != "" {
		h.expect(h.call(bob, "GET", "/v1/notifications?limit=2&cursor="+cursor), 422, "INVALID_CURSOR")
		h.expect(h.call(alice, "GET", "/v1/me/followers?limit=2&cursor="+cursor), 422, "INVALID_CURSOR")
		next := h.ok(alice, "GET", "/v1/notifications?limit=2&cursor="+cursor)
		for _, item := range items(next) {
			id := item["notificationId"].(string)
			if seen[id] {
				t.Fatal("pagination repeated a row")
			}
			seen[id] = true
		}
		cursor, _ = next["nextCursor"].(string)
	}
	if len(seen) != 5 {
		t.Fatalf("pagination returned %d of 5 rows", len(seen))
	}
	h.expect(h.call(alice, "GET", "/v1/notifications?limit=0"), 422, "VALIDATION")
	h.expect(h.call(alice, "GET", "/v1/notifications?cursor=forged.value"), 422, "INVALID_CURSOR")

	// Read state belongs to the recipient only.
	id := row["notificationId"].(string)
	h.expect(h.call(bob, "POST", "/v1/notifications/"+id+"/read"), 404, "NOT_FOUND")
	h.ok(alice, "POST", "/v1/notifications/"+id+"/read")
	h.ok(alice, "POST", "/v1/notifications/"+id+"/read")
	if c := h.ok(alice, "GET", "/v1/notifications/unread-count")["unreadCount"]; c != float64(4) {
		t.Fatalf("unread=%v", c)
	}
	if unread := h.ok(alice, "GET", "/v1/notifications?unreadOnly=true"); len(items(unread)) != 4 {
		t.Fatal("unreadOnly included a read row")
	}
	if n := h.ok(alice, "POST", "/v1/notifications/read-all")["updated"]; n != float64(4) {
		t.Fatalf("read-all updated %v", n)
	}
	if c := h.ok(alice, "GET", "/v1/notifications/unread-count")["unreadCount"]; c != float64(0) {
		t.Fatalf("unread after read-all=%v", c)
	}

	// Refollowing after unfollow refreshes one row as unread instead of adding another.
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/follow")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	feed := h.ok(alice, "GET", "/v1/notifications")
	if len(items(feed)) != 5 || feed["unreadCount"] != float64(1) {
		t.Fatalf("refollow duplicated or stayed read: %d rows, %v unread", len(items(feed)), feed["unreadCount"])
	}
	// Actors who are deactivated or blocked by the recipient disappear from the feed.
	h.exec(`UPDATE users SET status='deactivated' WHERE user_id=$1`, eli)
	h.ok(alice, "POST", "/v1/users/"+xan+"/block")
	if feed = h.ok(alice, "GET", "/v1/notifications"); len(items(feed)) != 3 {
		t.Fatalf("hidden actors still in feed: %v", ids(feed))
	}
}

func TestConcurrentGraphWritesStayConsistent(t *testing.T) {
	h := newSocialHarness(t)
	// Crossing friend requests from both sides at once must end in one friendship.
	var wg sync.WaitGroup
	statuses := make([]int, 2)
	for i, pair := range [][2]string{{xan, yui}, {yui, xan}} {
		wg.Add(1)
		go func(i int, actor, target string) {
			defer wg.Done()
			statuses[i] = h.call(actor, "POST", "/v1/users/"+target+"/friend-requests").status
		}(i, pair[0], pair[1])
	}
	wg.Wait()
	if statuses[0] != 200 || statuses[1] != 200 {
		t.Fatalf("concurrent requests failed: %v", statuses)
	}
	var rows int
	var status string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*),max(status) FROM friendships`).Scan(&rows, &status); err != nil {
		t.Fatal(err)
	}
	if rows != 1 || status != "accepted" {
		t.Fatalf("got %d rows with status %s", rows, status)
	}
	// Many parallel follows of one account produce one row each and no duplicates.
	h.policy(alice, "followPolicy", "everyone")
	for _, actor := range []string{bob, cara, dev, eli, xan, yui} {
		for i := 0; i < 3; i++ {
			wg.Add(1)
			go func(actor string) {
				defer wg.Done()
				if got := h.call(actor, "POST", "/v1/users/"+alice+"/follow"); got.status != 200 {
					t.Errorf("parallel follow: %d %s", got.status, got.code)
				}
			}(actor)
		}
	}
	wg.Wait()
	if s := h.stats(alice); s.Followers != 6 {
		t.Fatalf("followers=%d", s.Followers)
	}
	if c := h.ok(alice, "GET", "/v1/notifications/unread-count")["unreadCount"]; c != float64(6) {
		t.Fatalf("duplicate activity rows: %v", c)
	}
}

func TestGraphWritesAreRateLimitedPerAccount(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(bob, "followPolicy", "everyone")
	limited := 0
	for i := 0; i < 70; i++ {
		path := "/v1/users/" + bob + "/follow"
		if i%2 == 1 {
			h.ok(alice, "DELETE", path)
			continue
		}
		if got := h.call(alice, "POST", path); got.status == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("follow spam was never limited")
	}
	// Another account is unaffected by alice's budget.
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
}

func TestProfileStorageKeepsOnlyEditableFields(t *testing.T) {
	h := newSocialHarness(t)
	patch := map[string]json.RawMessage{"bio": json.RawMessage(`"fresh"`)}
	if _, err := h.db.UpdateProfile(h.ctx, alice, 1, patch); err != nil {
		t.Fatal(err)
	}
	var leaked []string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT coalesce(array_agg(k),'{}') FROM profiles, jsonb_object_keys(data) k WHERE user_id=$1 AND k IN ('userId','version','createdAt','updatedAt','socialStats')`, alice).Scan(&leaked); err != nil {
		t.Fatal(err)
	}
	if len(leaked) > 0 {
		t.Fatalf("derived fields stored in profile data: %v", leaked)
	}
	if p, _ := h.db.GetProfile(h.ctx, alice); p.Bio != "fresh" || p.Version != "2" {
		t.Fatalf("profile read back wrong: bio=%q version=%s", p.Bio, p.Version)
	}
}
