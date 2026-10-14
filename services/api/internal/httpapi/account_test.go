package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// acctHarness is the social harness with a verifier that behaves like the Firebase one for what account
// deletion cares about: a token is a user id, every sign-in is a session row with an auth_time in its
// session id, a revoked session is refused, and a member who asked to delete their account still
// authenticates (as PendingDeletion). It accepts any database named hiyall_test*.
type acctHarness struct {
	*socialHarness
	mu   sync.Mutex
	sids map[string]string
	n    int
}

func newAcctHarness(t *testing.T) *acctHarness {
	t.Helper()
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
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || !strings.HasPrefix(name, "hiyall_test") || name == "hiyall" {
		t.Fatal("integration tests require a database named hiyall_test*")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions,blocks,follows,friendships,notifications,discovery_eligibility,deleted_users CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	h := &acctHarness{sids: map[string]string{}}
	h.socialHarness = &socialHarness{t, ctx, db, New(db, h.verify, false, "")}
	for _, u := range [][2]string{{cara, "cara"}, {dev, "dev_k"}, {eli, "eli"}, {xan, "xan"}, {yui, "yui"}} {
		h.user(u[0], u[1])
	}
	return h
}

// signIn starts a session whose interactive sign-in was authAgo ago and makes it the member's current one.
func (h *acctHarness) signIn(user string, authAgo time.Duration) string {
	h.t.Helper()
	h.mu.Lock()
	h.n++
	n := h.n
	h.mu.Unlock()
	sid := uuid.NewString()
	h.exec(`INSERT INTO sessions(session_id,user_id,issuer,external_sid,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 hour')`,
		sid, user, "https://securetoken.google.com/test-project", fmt.Sprintf("fb:%s#%d:%d", user, n, time.Now().Add(-authAgo).Unix()))
	h.mu.Lock()
	h.sids[user] = sid
	h.mu.Unlock()
	return sid
}

func (h *acctHarness) verify(ctx context.Context, token string) (store.Principal, error) {
	h.mu.Lock()
	sid := h.sids[token]
	h.mu.Unlock()
	if sid == "" {
		sid = h.signIn(token, 0)
	}
	var p store.Principal
	err := h.db.Pool.QueryRow(ctx, `SELECT u.user_id::text,s.session_id::text,o.completed_at IS NOT NULL,u.status='pending_deletion'
 FROM sessions s JOIN users u ON u.user_id=s.user_id LEFT JOIN onboarding o ON o.user_id=u.user_id
 WHERE s.session_id=$1 AND s.user_id::text=$2 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status IN ('active','pending_deletion')`, sid, token).Scan(&p.UserID, &p.SessionID, &p.Onboarded, &p.PendingDeletion)
	if err != nil {
		return store.Principal{}, domain.ErrUnauthorized
	}
	return p, nil
}

func (h *acctHarness) schedule(user, confirm string) reply {
	h.t.Helper()
	return h.send(user, "POST", "/v1/me/deletion", map[string]string{"confirmUsername": confirm})
}

// scheduled asks for deletion and signs the member in again, as the app does to show the pending screen.
func (h *acctHarness) scheduled(user, username string) {
	h.t.Helper()
	h.expect(h.schedule(user, username), 200, "")
	h.signIn(user, 0)
}

func (h *acctHarness) expire(user string) {
	h.t.Helper()
	h.exec(`UPDATE users SET deletion_due_at=now()-interval '1 minute',deletion_scheduled_at=now()-interval '30 days 1 minute' WHERE user_id=$1 AND status='pending_deletion'`, user)
}

func (h *acctHarness) status(user string) string {
	h.t.Helper()
	var s string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status FROM users WHERE user_id=$1`, user).Scan(&s); err != nil {
		h.t.Fatal(err)
	}
	return s
}

func (h *acctHarness) count(query string, args ...any) int {
	h.t.Helper()
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, query, args...).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

func (h *acctHarness) searchIDs(viewer string) []string {
	h.t.Helper()
	h.api.search.reset(viewer)
	h.api.clients.reset("127.0.0.1")
	var out []string
	for _, item := range items(h.expect(h.send(viewer, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data) {
		out = append(out, item["userId"].(string))
	}
	return out
}

func contains(list []string, value string) bool {
	for _, v := range list {
		if v == value {
			return true
		}
	}
	return false
}

// fakeDeleter records the identity deletions an account purge asks for and can be made to fail.
type fakeDeleter struct {
	mu    sync.Mutex
	calls []string
	fail  bool
}

func (f *fakeDeleter) DeleteIdentity(_ context.Context, issuer, subject string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return errors.New("provider down")
	}
	f.calls = append(f.calls, issuer+"|"+subject)
	return nil
}

func TestDeletionStateMachineAndImmediateInvisibility(t *testing.T) {
	h := newAcctHarness(t)
	h.ok(eli, "POST", "/v1/users/"+xan+"/follow")
	h.ok(xan, "POST", "/v1/users/"+eli+"/follow")
	h.post(xan, "public", "from xan")
	h.north(xan, 0.005)
	h.north(eli, 0)
	d := h.register(xan)
	h.exec(`UPDATE devices SET push_provider='fcm',push_token='token-token-1' WHERE device_id=$1`, d.id)
	h.visit(eli, xan, "1 hour")

	visible := func() (search, feed, nearby, followers bool, counts [2]int64) {
		nearbyIDs, _ := h.nearbyOK(eli, map[string]any{})
		stats := h.stats(eli)
		return contains(h.searchIDs(eli), xan), contains(feedBodies(h.socialHarness, eli, "everyone"), "from xan"), contains(nearbyIDs, xan),
			contains(ids(h.ok(eli, "GET", "/v1/me/followers")), xan), [2]int64{int64(stats.Followers), int64(stats.Following)}
	}
	s, f, n, fo, counts := visible()
	if !s || !f || !n || !fo || counts != [2]int64{1, 1} {
		t.Fatalf("setup: search %v feed %v nearby %v followers %v counts %v", s, f, n, fo, counts)
	}

	// The request is validated before anything changes.
	h.expect(h.schedule(xan, "someone_else"), 422, "VALIDATION")
	h.expect(h.send(xan, "POST", "/v1/me/deletion", map[string]string{}), 422, "VALIDATION")
	h.expect(h.send(xan, "POST", "/v1/me/deletion", map[string]string{"confirmUsername": "xan", "extra": "x"}), 422, "VALIDATION")
	if h.status(xan) != "active" {
		t.Fatal("a refused request changed the account")
	}
	if got := h.ok(xan, "GET", "/v1/me/deletion"); got["pending"] != false || got["dueAt"] != nil {
		t.Fatalf("status before: %v", got)
	}

	// The username matches without case or a leading @.
	sid := h.sids[xan]
	got := h.expect(h.schedule(xan, " @XAN "), 200, "").data
	if got["pending"] != true || got["canCancel"] != true {
		t.Fatalf("schedule: %v", got)
	}
	due, _ := time.Parse(time.RFC3339Nano, got["dueAt"].(string))
	if d := time.Until(due); d < 29*24*time.Hour+23*time.Hour || d > 30*24*time.Hour+time.Minute {
		t.Fatalf("due in %v, want 30 days", d)
	}
	if h.status(xan) != "pending_deletion" {
		t.Fatalf("status %s", h.status(xan))
	}
	// Every session is revoked and no socket can stay (a socket checks SessionLive at each heartbeat),
	// push tokens are gone.
	if h.count(`SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, xan) != 0 {
		t.Fatal("a session survived")
	}
	if live, _ := h.db.SessionLive(h.ctx, sid); live {
		t.Fatal("the session still counts as live")
	}
	if h.count(`SELECT count(*) FROM devices WHERE user_id=$1 AND push_token IS NOT NULL`, xan) != 0 {
		t.Fatal("push token kept")
	}
	h.expect(h.call(xan, "GET", "/v1/me/profile"), 401, "UNAUTHENTICATED")

	// Gone from every surface other members use, and from their counts, at once.
	s, f, n, fo, counts = visible()
	if s || f || n || fo || counts != [2]int64{0, 0} {
		t.Fatalf("still visible: search %v feed %v nearby %v followers %v counts %v", s, f, n, fo, counts)
	}
	h.expect(h.call(eli, "GET", "/v1/users/"+xan+"/profile"), 404, "NOT_FOUND")
	h.expect(h.send(eli, "POST", "/v1/conversations", map[string]string{"userId": xan}), 404, "NOT_FOUND")

	// The member can sign in again, and sees when it ends.
	h.signIn(xan, 0)
	st := h.ok(xan, "GET", "/v1/me/deletion")
	if st["pending"] != true || st["canCancel"] != true || st["dueAt"] == nil || st["scheduledAt"] == nil {
		t.Fatalf("pending status %v", st)
	}
	// Cancelling restores everything, and the counts return.
	if got := h.ok(xan, "DELETE", "/v1/me/deletion"); got["pending"] != false {
		t.Fatalf("cancel: %v", got)
	}
	if h.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='active' AND deletion_due_at IS NULL AND deletion_scheduled_at IS NULL`, xan) != 1 {
		t.Fatal("cancel left deletion columns set")
	}
	s, f, n, fo, counts = visible()
	if !s || !f || !n || !fo || counts != [2]int64{1, 1} {
		t.Fatalf("after cancel: search %v feed %v nearby %v followers %v counts %v", s, f, n, fo, counts)
	}
	h.expect(h.call(xan, "GET", "/v1/me/profile"), 200, "")
	// Nothing is scheduled any more.
	h.expect(h.call(xan, "DELETE", "/v1/me/deletion"), 404, "NOT_FOUND")

	// After the 30 days the member can no longer cancel, even before the purge has run.
	h.scheduled(xan, "xan")
	h.expire(xan)
	h.expect(h.call(xan, "DELETE", "/v1/me/deletion"), 409, "DELETION_WINDOW_CLOSED")
	if st := h.ok(xan, "GET", "/v1/me/deletion"); st["pending"] != true || st["canCancel"] != false {
		t.Fatalf("status after the window: %v", st)
	}
	if h.status(xan) != "pending_deletion" {
		t.Fatal("a refused cancel changed the account")
	}
}

func TestDeletionNeedsARecentSignIn(t *testing.T) {
	h := newAcctHarness(t)
	h.signIn(xan, 10*time.Minute)
	h.expect(h.schedule(xan, "xan"), 403, "REAUTH_REQUIRED")
	if h.status(xan) != "active" || h.count(`SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, xan) != 1 {
		t.Fatal("a refused request changed the account")
	}
	h.signIn(xan, 4*time.Minute)
	h.expect(h.schedule(xan, "xan"), 200, "")
	// A session the server cannot date is refused outside development authentication.
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour')`, cara)
	var sid string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT session_id::text FROM sessions WHERE user_id=$1`, cara).Scan(&sid); err != nil {
		t.Fatal(err)
	}
	h.sids[cara] = sid
	h.expect(h.schedule(cara, "cara"), 403, "REAUTH_REQUIRED")
}

func TestDeletionInDevelopmentAuthentication(t *testing.T) {
	h := newAcctHarness(t)
	api := New(h.db, h.db.VerifyDevSession, true, "")
	call := func(method, path, token, body string) (int, map[string]any) {
		r := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		r.RemoteAddr = "127.0.0.1:44001"
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		api.Handler().ServeHTTP(w, r)
		var v map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &v)
		return w.Code, v
	}
	login := func() string {
		status, v := call("POST", "/dev/session", "", `{"userId":"`+alice+`"}`)
		if status != 200 {
			t.Fatalf("dev session %d", status)
		}
		return v["data"].(map[string]any)["accessToken"].(string)
	}
	token := login()
	// No Firebase auth_time exists for a development session, which is allowed to delete.
	if status, _ := call("POST", "/v1/me/deletion", token, `{"confirmUsername":"anjali"}`); status != 200 {
		t.Fatalf("schedule %d", status)
	}
	if status, _ := call("GET", "/v1/me/profile", token, ""); status != 401 {
		t.Fatalf("old session %d", status)
	}
	token = login() // a pending member can still get a development session
	if status, _ := call("GET", "/v1/me/profile", token, ""); status != 401 {
		t.Fatalf("pending profile %d", status)
	}
	if status, v := call("GET", "/v1/me/deletion", token, ""); status != 200 || v["data"].(map[string]any)["pending"] != true {
		t.Fatalf("status %d %v", status, v)
	}
	if status, _ := call("DELETE", "/v1/me/deletion", token, ""); status != 200 {
		t.Fatalf("cancel %d", status)
	}
	if status, _ := call("GET", "/v1/me/profile", token, ""); status != 200 {
		t.Fatalf("after cancel %d", status)
	}
}

func TestPendingMemberReachesOnlyDeletionRoutes(t *testing.T) {
	h := newAcctHarness(t)
	h.scheduled(xan, "xan")
	for _, route := range [][2]string{
		{"GET", "/v1/me/profile"}, {"GET", "/v1/me/privacy"}, {"GET", "/v1/feed"}, {"GET", "/v1/me/followers"}, {"GET", "/v1/me/visitors"},
		{"GET", "/v1/conversations"}, {"GET", "/v1/me/export"}, {"GET", "/v1/auth/sessions"}, {"POST", "/v1/posts"}, {"POST", "/v1/discovery/search"},
		{"POST", "/v1/me/deletion"}, {"GET", "/v1/me/onboarding"}, {"GET", "/v1/users/" + eli + "/profile"}, {"POST", "/v1/users/" + eli + "/follow"},
		{"POST", "/v1/reports"}, {"PUT", "/v1/me/location"}, {"POST", "/v1/devices"}, {"GET", "/v1/me/blocked"},
	} {
		got := h.send(xan, route[0], route[1], map[string]string{"confirmUsername": "xan"})
		h.expect(got, 401, "UNAUTHENTICATED")
	}
	if h.count(`SELECT count(*) FROM users WHERE user_id=$1 AND last_export_at IS NOT NULL`, xan) != 0 {
		t.Fatal("a pending member exported")
	}
	h.ok(xan, "GET", "/v1/me/deletion")
	h.ok(xan, "POST", "/v1/auth/logout")
	h.expect(h.call(xan, "GET", "/v1/me/deletion"), 401, "UNAUTHENTICATED")
	if h.status(xan) != "pending_deletion" {
		t.Fatal("signing out changed the account")
	}
	// A member who has not finished onboarding can still ask to be deleted.
	h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, yui)
	h.expect(h.call(yui, "GET", "/v1/feed"), 403, "ONBOARDING_REQUIRED")
	h.expect(h.schedule(yui, "yui"), 200, "")
}

func TestDeletionDoesNotChangeBlockOrAgeBandRules(t *testing.T) {
	h := newAcctHarness(t)
	h.ok(cara, "POST", "/v1/users/"+eli+"/block")
	h.setAge(dev, 15) // dev_k becomes a minor
	reach := func() string {
		return fmt.Sprint(h.call(xan, "GET", "/v1/users/"+dev+"/profile").status, h.call(xan, "GET", "/v1/users/"+eli+"/profile").status,
			h.call(eli, "GET", "/v1/users/"+dev+"/profile").status, h.send(xan, "POST", "/v1/conversations", map[string]string{"userId": dev}).status,
			h.searchIDs(xan), h.searchIDs(dev))
	}
	before := reach()
	h.scheduled(xan, "xan")
	h.ok(xan, "DELETE", "/v1/me/deletion")
	if after := reach(); after != before {
		t.Fatalf("age band reach changed: %v -> %v", before, after)
	}
	h.expect(h.call(eli, "GET", "/v1/users/"+cara+"/profile"), 404, "NOT_FOUND")
	h.expect(h.call(cara, "GET", "/v1/users/"+eli+"/profile"), 404, "NOT_FOUND")
	same(t, ids(h.ok(cara, "GET", "/v1/me/blocked")), eli)
}

func TestPendingMemberSignsInAgainThroughTheIdentityProvider(t *testing.T) {
	h := newAcctHarness(t)
	issuer := "https://securetoken.google.com/test-project"
	h.exec(`INSERT INTO auth_identities(issuer,subject,user_id) VALUES($1,'sub-x',$2)`, issuer, xan)
	expiry := time.Now().Add(time.Hour)
	old := fmt.Sprintf("fb:sub-x:%d", time.Now().Add(-time.Hour).Unix())
	if p, err := h.db.ResolveOIDC(h.ctx, issuer, "sub-x", old, expiry); err != nil || p.UserID != xan || p.PendingDeletion {
		t.Fatalf("sign-in: %+v %v", p, err)
	}
	if _, err := h.db.ScheduleDeletion(h.ctx, xan); err != nil {
		t.Fatal(err)
	}
	// The sign-in that existed before is dead, and so is any other from before the request that the
	// server had not seen (the identity's watermark).
	if _, err := h.db.ResolveOIDC(h.ctx, issuer, "sub-x", old, expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("old session: %v", err)
	}
	unseen := fmt.Sprintf("fb:sub-x:%d", time.Now().Add(-30*time.Minute).Unix())
	if _, err := h.db.ResolveOIDC(h.ctx, issuer, "sub-x", unseen, expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("unseen old sign-in: %v", err)
	}
	// A new sign-in works and is marked pending, so the API serves it only the deletion routes.
	fresh := fmt.Sprintf("fb:sub-x:%d", time.Now().Add(5*time.Second).Unix())
	p, err := h.db.ResolveOIDC(h.ctx, issuer, "sub-x", fresh, expiry)
	if err != nil || !p.PendingDeletion {
		t.Fatalf("pending sign-in: %+v %v", p, err)
	}
	at, known, err := h.db.SessionAuthTime(h.ctx, p.SessionID)
	if err != nil || !known || time.Until(at) < 3*time.Second {
		t.Fatalf("auth time %v %v %v", at, known, err)
	}
	if _, err = h.db.CancelDeletion(h.ctx, xan); err != nil {
		t.Fatal(err)
	}
	if p, err = h.db.ResolveOIDC(h.ctx, issuer, "sub-x", fresh, expiry); err != nil || p.PendingDeletion {
		t.Fatalf("after cancel: %+v %v", p, err)
	}
	// A purged account never signs in again.
	h.exec(`UPDATE users SET status='deleted' WHERE user_id=$1`, xan)
	if _, err = h.db.ResolveOIDC(h.ctx, issuer, "sub-x", fresh, expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("deleted: %v", err)
	}
}
