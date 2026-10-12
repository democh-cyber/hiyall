package httpapi

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
)

// statsOf reads the socialStats of target's profile as viewer; ok is false when the profile has none.
func (h *socialHarness) statsOf(viewer, target string) (map[string]any, bool) {
	h.t.Helper()
	var data map[string]any
	if viewer == target {
		data = h.ok(viewer, "GET", "/v1/me/profile")
	} else {
		data = h.expect(h.send(viewer, "GET", "/v1/users/"+target+"/profile", nil), 200, "").data
	}
	stats, ok := data["socialStats"].(map[string]any)
	return stats, ok
}

func (h *socialHarness) visitRows(profile string) (rows int, counted int64) {
	h.t.Helper()
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT count(*) FROM profile_visits WHERE profile_id=$1),coalesce((SELECT sum(visitors) FROM profile_visit_counts WHERE profile_id=$1),0)`, profile).Scan(&rows, &counted); err != nil {
		h.t.Fatal(err)
	}
	return
}

// Visitors are different members who opened the profile, counted once however often they come back.
func TestVisitorsAreCountedOncePerDistinctVisitor(t *testing.T) {
	h := newSocialHarness(t)
	count := func(viewer, target string) float64 {
		t.Helper()
		stats, ok := h.statsOf(viewer, target)
		if !ok {
			t.Fatalf("no socialStats for %s on %s", viewer, target)
		}
		return stats["visitors"].(float64)
	}
	if got := count(bob, bob); got != 0 {
		t.Fatalf("a new profile has %v visitors", got)
	}
	// The first visit is already in the number the visitor sees; repeats add nothing.
	for i := 0; i < 4; i++ {
		if got := count(alice, bob); got != 1 {
			t.Fatalf("visit %d by alice shows %v", i+1, got)
		}
	}
	if got := count(cara, bob); got != 2 {
		t.Fatalf("a second visitor shows %v", got)
	}
	if got := count(alice, bob); got != 2 {
		t.Fatalf("alice coming back shows %v", got)
	}
	// The owner and every other viewer see the same number, and the owner opening their own profile is not a visit.
	if got := count(bob, bob); got != 2 {
		t.Fatalf("the owner sees %v", got)
	}
	if got := count(dev, bob); got != 3 {
		t.Fatalf("a third visitor sees %v", got)
	}
	for i := 0; i < 3; i++ {
		h.expect(h.call(bob, "GET", "/v1/users/"+bob+"/profile"), 200, "")
	}
	if rows, counted := h.visitRows(bob); rows != 3 || counted != 3 {
		t.Fatalf("%d visit rows and a counter of %d, want 3 and 3", rows, counted)
	}
	var self int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM profile_visits WHERE visitor_id=profile_id`).Scan(&self); err != nil || self != 0 {
		t.Fatalf("%d self visits (%v)", self, err)
	}
	// A repeat visit does not write: neither the pair's row nor a counter row changes (same xmin and position).
	snapshot := func() string {
		var s string
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT coalesce(string_agg(xmin::text||'/'||ctid::text,',' ORDER BY ctid),'') FROM (SELECT xmin,ctid FROM profile_visits UNION ALL SELECT xmin,ctid FROM profile_visit_counts) x`).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	before := snapshot()
	for i := 0; i < 5; i++ {
		count(alice, bob)
		count(cara, bob)
	}
	if after := snapshot(); after != before {
		t.Fatalf("repeat visits wrote rows:\n%s\n%s", before, after)
	}
}

// Visits that were refused, and visits to nothing, are not visits; a locked card is.
func TestRefusedAndMissingProfileViewsAreNotVisits(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	h.ageAt(bob, 30)
	h.expect(h.call(bob, "POST", "/v1/users/"+cara+"/block"), 200, "")
	h.expect(h.call(cara, "GET", "/v1/users/"+bob+"/profile"), 404, "NOT_FOUND") // blocked
	h.expect(h.call(dev, "GET", "/v1/users/"+bob+"/profile"), 404, "NOT_FOUND")  // another age band
	h.expect(h.call(alice, "GET", "/v1/users/019a4000-0000-7000-8000-00000000ffff/profile"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1/users/not-a-uuid/profile"), 404, "NOT_FOUND")
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, yui)
	h.expect(h.call(alice, "GET", "/v1/users/"+yui+"/profile"), 404, "NOT_FOUND") // not active
	h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, eli)
	h.expect(h.call(alice, "GET", "/v1/users/"+eli+"/profile"), 404, "NOT_FOUND") // not onboarded
	var total int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT count(*) FROM profile_visits)+coalesce((SELECT sum(visitors) FROM profile_visit_counts),0)`).Scan(&total); err != nil || total != 0 {
		t.Fatalf("refused views recorded %d (%v)", total, err)
	}
	// A locked card is an opened profile and counts, but shows no counts itself.
	h.policy(bob, "profileAudience", "friends")
	got := h.expect(h.send(alice, "GET", "/v1/users/"+bob+"/profile", nil), 200, "").data
	if got["locked"] != true || got["socialStats"] != nil {
		t.Fatalf("the locked card %v", got)
	}
	if rows, counted := h.visitRows(bob); rows != 1 || counted != 1 {
		t.Fatalf("a locked card visit: %d rows, counter %d", rows, counted)
	}
	// The owner sees it; nobody else is told who.
	if stats, _ := h.statsOf(bob, bob); stats["visitors"] != float64(1) {
		t.Fatalf("owner's stats %v", stats)
	}
}

// Many first visits at once never inflate the counter past the number of rows, and repeats from the same visitor,
// even simultaneous, count once.
func TestConcurrentVisitsKeepTheCounterEqualToTheRows(t *testing.T) {
	h := newSocialHarness(t)
	var visitors []string
	for i := 0; i < 24; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 1500+i)
		h.user(id, fmt.Sprintf("visitor_%d", i))
		visitors = append(visitors, id)
	}
	h.api.clients.reset("127.0.0.1")
	var wg sync.WaitGroup
	statuses := make(chan int, len(visitors)*4)
	for _, v := range visitors {
		for k := 0; k < 4; k++ { // the same visitor four times at once
			wg.Add(1)
			go func(viewer string) {
				defer wg.Done()
				r := httptest.NewRequest("GET", "/v1/users/"+bob+"/profile", nil)
				r.RemoteAddr = "127.0.0.1:50000"
				r.Header.Set("Authorization", "Bearer "+viewer)
				w := httptest.NewRecorder()
				h.api.Handler().ServeHTTP(w, r)
				statuses <- w.Code
			}(v)
		}
	}
	wg.Wait()
	close(statuses)
	for code := range statuses {
		if code != http.StatusOK {
			t.Fatalf("a concurrent view answered %d", code)
		}
	}
	rows, counted := h.visitRows(bob)
	if rows != len(visitors) || counted != int64(len(visitors)) {
		t.Fatalf("%d rows and a counter of %d after %d distinct visitors", rows, counted, len(visitors))
	}
	// The counter is spread over slots, and reading it sums them.
	var slots int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM profile_visit_counts WHERE profile_id=$1 AND visitors>0`, bob).Scan(&slots); err != nil || slots < 2 {
		t.Fatalf("visits landed in %d counter slots (%v)", slots, err)
	}
	if stats, _ := h.statsOf(bob, bob); stats["visitors"] != float64(len(visitors)) {
		t.Fatalf("owner's count %v", stats["visitors"])
	}
	// Run them all again: still one each.
	h.api.clients.reset("127.0.0.1")
	for _, v := range visitors {
		h.expect(h.call(v, "GET", "/v1/users/"+bob+"/profile"), 200, "")
	}
	if rows, counted = h.visitRows(bob); rows != len(visitors) || counted != int64(len(visitors)) {
		t.Fatalf("after repeats: %d rows, counter %d", rows, counted)
	}
}

// Nothing says who visited except the owner's own visitor list (GET /v1/me/visitors): no other endpoint, field
// or list, and no way to ask for someone else's.
func TestNoResponseListsVisitors(t *testing.T) {
	h := newSocialHarness(t)
	for _, v := range []string{alice, cara, dev} {
		h.expect(h.call(v, "GET", "/v1/users/"+bob+"/profile"), 200, "")
	}
	for _, path := range []string{"/v1/me/profile/visitors", "/v1/users/" + bob + "/visitors", "/v1/me/profile-visits", "/v1/users/" + bob + "/profile/visitors", "/v1/me/views"} {
		for _, who := range []string{bob, alice} {
			if got := h.call(who, "GET", path); got.status != 404 {
				t.Fatalf("%s answered %d for %s", path, got.status, who)
			}
		}
	}
	// The one list: the owner's, and a member sees only visits to their own profile.
	same(t, ids(h.ok(bob, "GET", "/v1/me/visitors")), dev, cara, alice)
	same(t, ids(h.ok(alice, "GET", "/v1/me/visitors")))
	// None of the owner's own responses mention a visitor's id, and the profile has no visitors list field.
	for _, path := range []string{"/v1/me/profile", "/v1/me/privacy", "/v1/notifications", "/v1/me/friends", "/v1/me/followers", "/v1/conversations", "/v1/feed", "/v1/stories/tray", "/v1/me/saved", "/v1/users/" + bob + "/profile"} {
		_, _, raw := h.full(bob, "GET", path, "", "")
		for _, visitor := range []string{alice, cara, dev} {
			if strings.Contains(string(raw), visitor) {
				t.Fatalf("%s names visitor %s: %s", path, visitor, raw)
			}
		}
		for _, field := range []string{`"visitorIds"`, `"visitedBy"`, `"viewers"`, `"profileViews"`, `"firstVisitedAt"`, `"visitor_id"`} {
			if strings.Contains(string(raw), field) {
				t.Fatalf("%s has %s: %s", path, field, raw)
			}
		}
	}
}

// stories is how many unexpired stories the viewer may see: the audience, expiry, deletion, blocks and the age
// barrier decide; on your own profile it is all of your active stories.
func TestStoriesCountFollowsWhoMaySeeThem(t *testing.T) {
	h := newSocialHarness(t)
	for _, audience := range []string{"public", "public", "followers", "friends"} {
		h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": "gm " + audience, "background": "pink", "audience": audience}), 201, "")
	}
	expired := h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": "old", "background": "pink", "audience": "public"}), 201, "").data["storyId"].(string)
	h.exec(`UPDATE stories SET expires_at=now()-interval '1 minute' WHERE story_id=$1`, expired)
	gone := h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": "deleted", "background": "pink", "audience": "public"}), 201, "").data["storyId"].(string)
	h.expect(h.call(bob, "DELETE", "/v1/stories/"+gone), 200, "")
	stories := func(viewer string) float64 {
		t.Helper()
		stats, ok := h.statsOf(viewer, bob)
		if !ok {
			t.Fatalf("%s: no socialStats", viewer)
		}
		return stats["stories"].(float64)
	}
	if got := stories(alice); got != 2 { // a stranger: the two public ones
		t.Fatalf("a stranger sees %v stories", got)
	}
	if got := stories(bob); got != 4 { // the owner: every active one, whatever the audience
		t.Fatalf("the owner sees %v stories", got)
	}
	if mine := h.ok(bob, "GET", "/v1/me/profile")["socialStats"].(map[string]any); mine["stories"] != float64(4) {
		t.Fatalf("GET /v1/me/profile %v", mine)
	}
	h.expect(h.call(cara, "POST", "/v1/users/"+bob+"/follow"), 200, "")
	if got := stories(cara); got != 3 { // a follower adds the followers-only one
		t.Fatalf("a follower sees %v stories", got)
	}
	h.exec(`INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'accepted')`, dev, bob)
	if got := stories(dev); got != 4 { // a friend sees all four
		t.Fatalf("a friend sees %v stories", got)
	}
	// Stories that expire stop counting for everyone.
	h.exec(`UPDATE stories SET expires_at=now()-interval '1 hour' WHERE author_id=$1 AND audience='friends'`, bob)
	if got := stories(dev); got != 3 {
		t.Fatalf("after the friends story expired: %v", got)
	}
	if got := stories(bob); got != 3 {
		t.Fatalf("the owner after expiry: %v", got)
	}
	// A member with no stories has 0, never missing.
	if stats, ok := h.statsOf(alice, cara); !ok || stats["stories"] != float64(0) {
		t.Fatalf("no stories: %v %v", stats, ok)
	}
	// Blocked and cross-band viewers cannot open the profile at all, so there is no count for them.
	h.expect(h.call(bob, "POST", "/v1/users/"+eli+"/block"), 200, "")
	h.expect(h.call(eli, "GET", "/v1/users/"+bob+"/profile"), 404, "NOT_FOUND")
	h.ageAt(xan, 15)
	h.expect(h.call(xan, "GET", "/v1/users/"+bob+"/profile"), 404, "NOT_FOUND")
	// If the audience for counts is nobody, the viewer gets no socialStats and the owner still does.
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,counts}','"nobody"') WHERE user_id=$1`, bob)
	if _, ok := h.statsOf(alice, bob); ok {
		t.Fatal("counts shown against audience nobody")
	}
	if stats, ok := h.statsOf(bob, bob); !ok || stats["stories"] != float64(3) {
		t.Fatalf("the owner lost their own counts: %v", stats)
	}
	// The shape is exactly five integers.
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,counts}','"everyone"') WHERE user_id=$1`, bob)
	stats, _ := h.statsOf(alice, bob)
	keys := make([]string, 0, len(stats))
	for k := range stats {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if fmt.Sprint(keys) != "[followers following friends stories visitors]" {
		t.Fatalf("socialStats keys %v", keys)
	}
}

// The stories count on a barrier: a member in the other age band is not found, and own stories stay counted.
func TestStoriesCountAcrossBandsIsNeverShown(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	h.ageAt(eli, 16)
	h.expect(h.send(eli, "POST", "/v1/stories", map[string]any{"body": "hi", "background": "pink", "audience": "public"}), 201, "")
	if stats, ok := h.statsOf(dev, eli); !ok || stats["stories"] != float64(1) {
		t.Fatalf("a minor looking at a minor: %v", stats)
	}
	h.expect(h.call(alice, "GET", "/v1/users/"+eli+"/profile"), 404, "NOT_FOUND")
}
