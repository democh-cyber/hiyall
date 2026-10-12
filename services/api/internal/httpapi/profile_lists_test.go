package httpapi

import (
	"context"
	"fmt"
	"testing"

	"hiyall/services/api/internal/domain"
)

// visit makes visitor open owner's profile, then moves the first visit to ago in the past so the order is known.
func (h *socialHarness) visit(visitor, owner, ago string) {
	h.t.Helper()
	h.expect(h.call(visitor, "GET", "/v1/users/"+owner+"/profile"), 200, "")
	h.exec(`UPDATE profile_visits SET first_visited_at=now()-$3::interval WHERE profile_id=$1 AND visitor_id=$2`, owner, visitor, ago)
}

func (h *socialHarness) visitors(owner string) []string {
	h.t.Helper()
	return ids(h.ok(owner, "GET", "/v1/me/visitors"))
}

func TestVisitorListIsOwnerOnlyNewestFirstAndShapedAsASummary(t *testing.T) {
	h := newSocialHarness(t)
	h.visit(alice, bob, "3 hours")
	h.visit(cara, bob, "2 hours")
	h.visit(eli, bob, "1 hour")
	h.visit(alice, cara, "1 hour")
	same(t, h.visitors(bob), eli, cara, alice)

	rows := items(h.ok(bob, "GET", "/v1/me/visitors"))
	row := rows[0]
	user := row["user"].(map[string]any)
	if user["username"] != "eli" || user["displayName"] != "Eli" || user["avatarUrl"] != nil || row["firstVisitedAt"] == nil || row["following"] != "none" {
		t.Fatalf("visitor row %v", row)
	}
	// The list is the caller's own: alice sees who opened her profile (nobody), never who she opened.
	same(t, h.visitors(alice))
	same(t, h.visitors(cara), alice)
	// There is no route for someone else's visitors, and no way to pass a profile id.
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/visitors"), 404, "NOT_FOUND")
	h.expect(h.call(bob, "GET", "/v1/users/"+bob+"/visitors"), 404, "NOT_FOUND")
	same(t, ids(h.ok(alice, "GET", "/v1/me/visitors?user="+bob+"&profile="+bob)))
	h.expect(h.call(bob, "POST", "/v1/me/visitors"), 404, "NOT_FOUND")
	h.expect(h.call(bob, "DELETE", "/v1/me/visitors"), 404, "NOT_FOUND")
	// Unauthenticated callers get nothing.
	h.expect(h.call("", "GET", "/v1/me/visitors"), 401, "UNAUTHENTICATED")

	// Repeat visits move nothing; the owner's own follow on a visitor shows in the row.
	h.visit(alice, bob, "3 hours")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	rows = items(h.ok(bob, "GET", "/v1/me/visitors"))
	if len(rows) != 3 || rows[2]["following"] != "active" || rows[0]["following"] != "none" {
		t.Fatalf("rows %v", rows)
	}
}

func TestVisitorListLeavesOutBlockedBarredAndInactiveMembers(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(bob, 30)
	h.ageAt(dev, 30)
	for i, who := range []string{alice, cara, eli, xan, yui, dev} {
		h.visit(who, bob, fmt.Sprintf("%d hours", i+1))
	}
	same(t, h.visitors(bob), alice, cara, eli, xan, yui, dev)

	h.ok(bob, "POST", "/v1/users/"+cara+"/block") // the owner blocked them
	h.ok(eli, "POST", "/v1/users/"+bob+"/block")  // they blocked the owner
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, xan)
	same(t, h.visitors(bob), alice, yui, dev)
	h.ageAt(dev, 15) // in the other age band now
	same(t, h.visitors(bob), alice, yui)
	// Lifting a block brings the visit back: nothing was deleted.
	h.ok(bob, "DELETE", "/v1/users/"+cara+"/block")
	same(t, h.visitors(bob), alice, cara, yui)

	// The count keeps every member who ever opened the profile; the list keeps only those who can still be
	// shown, so the two can differ by the excluded members.
	stats, _ := h.statsOf(bob, bob)
	if stats["visitors"] != float64(6) {
		t.Fatalf("stats %v", stats)
	}
	// A visitor who cannot reach the owner cannot read the list either (it is the owner's alone).
	same(t, h.visitors(eli))
}

func TestVisitorListPagesWithSignedCursorsBoundToTheOwner(t *testing.T) {
	h := newSocialHarness(t)
	order := []string{alice, cara, eli, xan, yui}
	for i, who := range order {
		h.visit(who, bob, fmt.Sprintf("%d hours", i+1))
	}
	first := h.ok(bob, "GET", "/v1/me/visitors?limit=2")
	same(t, ids(first), alice, cara)
	cursor, _ := first["nextCursor"].(string)
	if cursor == "" || first["hasMore"] != true {
		t.Fatalf("first page %v", first)
	}
	second := h.ok(bob, "GET", "/v1/me/visitors?limit=2&cursor="+cursor)
	same(t, ids(second), eli, xan)
	last := h.ok(bob, "GET", "/v1/me/visitors?limit=2&cursor="+second["nextCursor"].(string))
	same(t, ids(last), yui)
	if last["nextCursor"] != nil || last["hasMore"] != false {
		t.Fatalf("last page %v", last)
	}
	// A cursor works for its member and its list only; garbage and bad limits are refused.
	h.expect(h.call(cara, "GET", "/v1/me/visitors?cursor="+cursor), 422, "INVALID_CURSOR")
	h.expect(h.call(bob, "GET", "/v1/me/visitors?cursor="+cursor+"x"), 422, "INVALID_CURSOR")
	h.expect(h.call(bob, "GET", "/v1/me/followers?cursor="+cursor), 422, "INVALID_CURSOR")
	h.expect(h.call(bob, "GET", "/v1/me/visitors?limit=51"), 422, "VALIDATION")
	h.expect(h.call(bob, "GET", "/v1/me/visitors?limit=0"), 422, "VALIDATION")
}

func TestVisitorListLimitComesFromTheEntitlementsResolver(t *testing.T) {
	if got := domain.Free().VisitorListLimit; got != 200 {
		t.Fatalf("the Free visitor list limit is %d", got)
	}
	h := newSocialHarness(t)
	small := domain.Free()
	small.VisitorListLimit = 3
	var asked []string
	h.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		asked = append(asked, user)
		if user == bob {
			return small
		}
		return domain.Free()
	}
	for i, who := range []string{alice, cara, eli, xan, yui} {
		h.visit(who, bob, fmt.Sprintf("%d hours", i+1))
		h.visit(who, alice, fmt.Sprintf("%d hours", i+1))
	}
	// Only the three most recent visitors, however the pages are cut.
	same(t, h.visitors(bob), alice, cara, eli)
	page := h.ok(bob, "GET", "/v1/me/visitors?limit=2")
	same(t, ids(page), alice, cara)
	page = h.ok(bob, "GET", "/v1/me/visitors?limit=2&cursor="+page["nextCursor"].(string))
	same(t, ids(page), eli)
	if page["nextCursor"] != nil {
		t.Fatalf("a page past the limit %v", page)
	}
	// The cap counts members who can be shown: excluded ones do not use it up.
	h.ok(bob, "POST", "/v1/users/"+cara+"/block")
	same(t, h.visitors(bob), alice, eli, xan)
	// Another member is on Free and is not limited by bob's tier; the stat is never limited.
	same(t, h.visitors(alice), cara, eli, xan, yui)
	if stats, _ := h.statsOf(bob, bob); stats["visitors"] != float64(5) {
		t.Fatalf("stats %v", stats)
	}
	if len(asked) == 0 {
		t.Fatal("the resolver was not asked")
	}
}

func TestVisitorListIsRateLimitedPerMember(t *testing.T) {
	h := newSocialHarness(t)
	h.visit(alice, bob, "1 hour")
	for i := 0; i < 30; i++ {
		h.expect(h.call(bob, "GET", "/v1/me/visitors"), 200, "")
	}
	h.expect(h.call(bob, "GET", "/v1/me/visitors"), 429, "RATE_LIMITED")
	// Per member: another account is not slowed down.
	h.expect(h.call(alice, "GET", "/v1/me/visitors"), 200, "")
}

func TestConnectionRowsCarryTheViewersFollowStateAndProfilesSayWhetherListsOpen(t *testing.T) {
	h := newSocialHarness(t)
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	h.ok(bob, "POST", "/v1/users/"+cara+"/follow")
	rows := items(h.ok(bob, "GET", "/v1/me/followers"))
	if len(rows) != 2 || rows[0]["following"] != "active" || rows[1]["following"] != "none" {
		t.Fatalf("followers as bob %v", rows)
	}
	h.policy2(bob, "connections", "everyone")
	// On someone else's list the state is the viewer's own, not the list owner's.
	for _, row := range items(h.ok(eli, "GET", "/v1/users/"+bob+"/followers")) {
		if row["following"] != "none" {
			t.Fatalf("row as eli %v", row)
		}
	}
	// The profile says whether the viewer may open the lists, so the app never offers a dead end.
	h.policy(bob, "followPolicy", "everyone")
	if got := h.ok(eli, "GET", "/v1/users/"+bob+"/profile")["canSeeConnections"]; got != true {
		t.Fatalf("connections open to everyone: %v", got)
	}
	h.policy2(bob, "connections", "nobody")
	if got := h.ok(eli, "GET", "/v1/users/"+bob+"/profile")["canSeeConnections"]; got != false {
		t.Fatalf("connections closed: %v", got)
	}
	h.expect(h.call(eli, "GET", "/v1/users/"+bob+"/followers"), 403, "CONNECTIONS_PRIVATE")
	if _, has := h.ok(bob, "GET", "/v1/me/profile")["canSeeConnections"]; has {
		t.Fatal("the owner's own profile carries the flag")
	}
}

// policy2 sets one field audience.
func (h *socialHarness) policy2(id, field, audience string) {
	h.t.Helper()
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],to_jsonb($3::text)) WHERE user_id=$1`, id, field, audience)
}

func TestMyStoriesListsOnlyTheCallersActiveStoriesWithViewCounts(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	h.policy(alice, "followPolicy", "everyone")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(cara, "POST", "/v1/users/"+alice+"/follow")
	older := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "gm", "background": "pink", "audience": "followers"}), 201, "").data["storyId"].(string)
	pic := h.upload(store, alice, "story", photo(t, 40, 80))
	newer := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"mediaId": pic, "audience": "public"}), 201, "").data["storyId"].(string)
	h.exec(`UPDATE stories SET created_at=now()-interval '1 hour' WHERE story_id=$1`, older)
	h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": "bob", "audience": "public"}), 201, "")
	h.ok(bob, "POST", "/v1/stories/"+older+"/view")
	h.ok(cara, "POST", "/v1/stories/"+older+"/view")

	rows := items(h.ok(alice, "GET", "/v1/me/stories"))
	if len(rows) != 2 || rows[0]["storyId"] != newer || rows[1]["storyId"] != older {
		t.Fatalf("alice's stories %v", rows)
	}
	if rows[0]["viewCount"] != float64(0) || rows[1]["viewCount"] != float64(2) || rows[1]["background"] != "pink" || rows[1]["audience"] != "followers" || rows[1]["expiresAt"] == nil || rows[1]["media"] != nil {
		t.Fatalf("alice's story fields %v", rows)
	}
	if media, _ := rows[0]["media"].(map[string]any); media == nil || media["url"] == "" {
		t.Fatalf("photo story %v", rows[0])
	}
	// Each member sees only their own; nothing takes another member's id.
	same(t, []string{fmt.Sprint(len(items(h.ok(bob, "GET", "/v1/me/stories"))))}, "1")
	same(t, []string{fmt.Sprint(len(items(h.ok(eli, "GET", "/v1/me/stories"))))}, "0")
	h.expect(h.call("", "GET", "/v1/me/stories"), 401, "UNAUTHENTICATED")

	// Deleted and expired stories are not active; deleting twice, or someone else's story, is a 404.
	h.expect(h.call(bob, "DELETE", "/v1/stories/"+older), 404, "NOT_FOUND")
	h.ok(alice, "DELETE", "/v1/stories/"+older)
	h.expect(h.call(alice, "DELETE", "/v1/stories/"+older), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1/stories/"+older+"/viewers"), 404, "NOT_FOUND")
	same(t, []string{fmt.Sprint(len(items(h.ok(alice, "GET", "/v1/me/stories"))))}, "1")
	h.exec(`UPDATE stories SET expires_at=now()-interval '1 minute' WHERE story_id=$1`, newer)
	same(t, []string{fmt.Sprint(len(items(h.ok(alice, "GET", "/v1/me/stories"))))}, "0")
	if got := items(h.ok(bob, "GET", "/v1/stories/tray")); len(got) != 1 {
		t.Fatalf("bob's tray %v", got)
	}
}

func TestMyStoriesPageAndCountOnlyViewersWhoCanBeShown(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(alice, 30)
	for _, who := range []string{bob, cara, eli, xan, dev} {
		h.ageAt(who, 30)
	}
	h.addStories(alice, 5, "1 hour", false)
	first := h.ok(alice, "GET", "/v1/me/stories?limit=2")
	rows := items(first)
	if len(rows) != 2 || first["nextCursor"] == nil {
		t.Fatalf("first page %v", first)
	}
	second := h.ok(alice, "GET", "/v1/me/stories?limit=2&cursor="+first["nextCursor"].(string))
	third := h.ok(alice, "GET", "/v1/me/stories?limit=2&cursor="+second["nextCursor"].(string))
	seen := map[any]bool{}
	for _, page := range []map[string]any{first, second, third} {
		for _, row := range items(page) {
			seen[row["storyId"]] = true
		}
	}
	if len(seen) != 5 || third["nextCursor"] != nil || len(items(third)) != 1 {
		t.Fatalf("pages cover %d stories, last %v", len(seen), third)
	}
	h.expect(h.call(bob, "GET", "/v1/me/stories?cursor="+first["nextCursor"].(string)), 422, "INVALID_CURSOR")

	story := rows[0]["storyId"].(string)
	for _, who := range []string{bob, cara, eli, xan, dev} {
		h.exec(`INSERT INTO story_views(story_id,viewer_id) VALUES($1,$2)`, story, who)
	}
	count := func() float64 {
		for _, row := range items(h.ok(alice, "GET", "/v1/me/stories?limit=50")) {
			if row["storyId"] == story {
				return row["viewCount"].(float64)
			}
		}
		t.Fatal("story missing")
		return 0
	}
	if got := count(); got != 5 {
		t.Fatalf("count %v", got)
	}
	h.ok(alice, "POST", "/v1/users/"+bob+"/block")
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, cara)
	h.ageAt(dev, 15)
	// The count is the length of the viewers list, so the two screens agree.
	viewers := h.ok(alice, "GET", "/v1/stories/"+story+"/viewers")
	same(t, ids(viewers), xan, eli)
	if got := count(); got != 2 {
		t.Fatalf("count %v", got)
	}
	trayOwn := items(h.ok(alice, "GET", "/v1/stories/tray"))[0]["stories"].([]any)
	for _, s := range trayOwn {
		if m := s.(map[string]any); m["storyId"] == story && m["viewCount"] != float64(2) {
			t.Fatalf("tray count %v", m)
		}
	}
}

func TestStoryListsAndViewersAreRateLimited(t *testing.T) {
	h := newSocialHarness(t)
	for i := 0; i < 30; i++ {
		h.expect(h.call(alice, "GET", "/v1/me/stories"), 200, "")
	}
	h.expect(h.call(alice, "GET", "/v1/me/stories"), 429, "RATE_LIMITED")
	h.expect(h.call(bob, "GET", "/v1/me/stories"), 200, "")
}

// Another member's stories on their profile are exactly the ones the Stories count says the viewer may watch.
func TestUserStoriesAreThoseTheViewerMayWatch(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(bob, 30)
	for _, who := range []string{alice, cara, dev, eli} {
		h.ageAt(who, 30)
	}
	story := func(audience, body string) string {
		return h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": body, "background": "lime", "audience": audience}), 201, "").data["storyId"].(string)
	}
	pub := story("public", "pub")
	fol := story("followers", "fol")
	fri := story("friends", "fri")
	gone := story("public", "gone")
	h.ok(bob, "DELETE", "/v1/stories/"+gone)
	old := story("public", "old")
	h.exec(`UPDATE stories SET expires_at=now()-interval '1 minute' WHERE story_id=$1`, old)
	h.exec(`UPDATE stories SET created_at=now()-interval '3 hours' WHERE story_id=$1`, pub)
	h.exec(`UPDATE stories SET created_at=now()-interval '2 hours' WHERE story_id=$1`, fol)
	h.exec(`UPDATE stories SET created_at=now()-interval '1 hour' WHERE story_id=$1`, fri)
	listed := func(viewer string) []string {
		t.Helper()
		out := []string{}
		for _, row := range items(h.ok(viewer, "GET", "/v1/users/"+bob+"/stories")) {
			out = append(out, row["body"].(string))
		}
		return out
	}
	count := func(viewer string) float64 {
		stats, _ := h.statsOf(viewer, bob)
		return stats["stories"].(float64)
	}
	// A stranger: the public one only. A follower adds the followers one. A friend all three, newest first.
	same(t, listed(alice), "pub")
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	same(t, listed(cara), "fol", "pub")
	h.exec(`INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'accepted')`, eli, bob)
	same(t, listed(eli), "fri", "fol", "pub")
	for _, who := range []string{alice, cara, eli} {
		if got, want := count(who), float64(len(listed(who))); got != want {
			t.Fatalf("%s: count %v, list %v", who, got, want)
		}
	}
	// The owner sees their own; nobody else's id is ever accepted for someone who does not exist.
	same(t, listed(bob), "fri", "fol", "pub")
	h.expect(h.call(alice, "GET", "/v1/users/019a4000-0000-7000-8000-00000000ffff/stories"), 200, "")
	h.expect(h.call(alice, "GET", "/v1/users/not-a-uuid/stories"), 404, "NOT_FOUND")
	// Seen state is the viewer's own, and a view in the list is the viewer's own view.
	h.ok(alice, "POST", "/v1/stories/"+pub+"/view")
	rows := items(h.ok(alice, "GET", "/v1/users/"+bob+"/stories"))
	if len(rows) != 1 || rows[0]["seen"] != true || rows[0]["viewCount"] != nil {
		t.Fatalf("rows %v", rows)
	}
	if got := items(h.ok(cara, "GET", "/v1/users/"+bob+"/stories")); got[1]["seen"] != false {
		t.Fatalf("cara's seen %v", got)
	}
	// Pages are cut by the signed cursor, bound to the viewer and to this author.
	page := h.ok(eli, "GET", "/v1/users/"+bob+"/stories?limit=2")
	if len(items(page)) != 2 || page["nextCursor"] == nil {
		t.Fatalf("page %v", page)
	}
	rest := h.ok(eli, "GET", "/v1/users/"+bob+"/stories?limit=2&cursor="+page["nextCursor"].(string))
	if len(items(rest)) != 1 || rest["nextCursor"] != nil {
		t.Fatalf("rest %v", rest)
	}
	h.expect(h.call(cara, "GET", "/v1/users/"+bob+"/stories?cursor="+page["nextCursor"].(string)), 422, "INVALID_CURSOR")
	h.expect(h.call(eli, "GET", "/v1/users/"+cara+"/stories?cursor="+page["nextCursor"].(string)), 422, "INVALID_CURSOR")
	// Blocked either way, another age band and a suspended author show nothing.
	h.ok(bob, "POST", "/v1/users/"+eli+"/block")
	same(t, listed(eli))
	h.ok(bob, "DELETE", "/v1/users/"+eli+"/block")
	h.ageAt(dev, 15)
	same(t, listed(dev))
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, bob)
	same(t, listed(cara))
}
