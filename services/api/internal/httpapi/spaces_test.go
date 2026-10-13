package httpapi

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func makeSpace(h *socialHarness, user, kind, visibility string, capacity int, parent *string) string {
	h.t.Helper()
	in := map[string]any{"kind": kind, "title": "A little circle", "description": "Talk about books", "rules": "Be kind", "visibility": visibility, "capacity": capacity, "timezone": "Asia/Kolkata"}
	if parent != nil {
		in["parentId"] = *parent
	}
	if kind != "community" {
		in["startsAt"] = time.Now().Add(-time.Minute)
		in["endsAt"] = time.Now().Add(time.Hour)
		in["location"] = "https://example.org/meet"
	}
	return h.expect(h.send(user, "POST", "/v1/spaces", in), 201, "").data["spaceId"].(string)
}
func TestSpacesPrivateAdmissionRolesAndReports(t *testing.T) {
	h := newSocialHarness(t)
	id := makeSpace(h, alice, "community", "private", 3, nil)
	base := "/v1/spaces/" + id
	h.expect(h.call(bob, "GET", base+"/entries"), 403, "SPACE_MEMBER_REQUIRED")
	h.expect(h.send(bob, "PUT", base+"/membership", map[string]string{}), 200, "")
	if got := h.ok(bob, "GET", base)["myState"]; got != "pending" {
		t.Fatalf("state %v", got)
	}
	h.expect(h.call(bob, "GET", base+"/members?state=pending"), 403, "SPACE_MEMBER_REQUIRED")
	h.expect(h.send(cara, "PUT", base+"/members/"+bob, map[string]string{"action": "approve"}), 403, "SPACE_ROLE_REQUIRED")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "approve"}), 200, "")
	entry := h.expect(h.send(bob, "POST", base+"/entries", map[string]string{"body": "My favourite book"}), 201, "").data["entryId"].(string)
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "space_entry", "targetId": entry, "reasonCode": "spam"}), 201, "")
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "space_entry", "targetId": entry, "reasonCode": "spam"}), 404, "NOT_FOUND")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "moderator"}), 200, "")
	h.expect(h.send(bob, "PUT", base+"/members/"+alice, map[string]string{"action": "ban"}), 409, "SPACE_OWNER")
	h.expect(h.send(bob, "PUT", base+"/members/"+cara, map[string]string{"action": "invite"}), 403, "SPACE_ROLE_REQUIRED")
	h.expect(h.send(bob, "PUT", base+"/status", map[string]string{"status": "closed"}), 403, "SPACE_ROLE_REQUIRED")
	h.expect(h.send(alice, "PUT", base+"/status", map[string]string{"status": "closed"}), 200, "")
	h.expect(h.send(bob, "POST", base+"/entries", map[string]string{"body": "late"}), 409, "SPACE_CLOSED")
	h.expect(h.call(alice, "DELETE", base+"/entries/"+entry), 200, "")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "ban"}), 200, "")
	h.expect(h.call(bob, "GET", base), 404, "NOT_FOUND")
	h.expect(h.call(bob, "GET", "/v1/spaces?kind=community"), 200, "")
	if len(items(h.ok(bob, "GET", "/v1/spaces?kind=community"))) != 0 {
		t.Fatal("banned space leaked")
	}
}
func TestSpacesInviteParentMembershipAndMemberAvailability(t *testing.T) {
	h := newSocialHarness(t)
	id := makeSpace(h, alice, "community", "invite", 10, nil)
	base := "/v1/spaces/" + id
	h.expect(h.call(bob, "GET", base), 404, "NOT_FOUND")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "invite"}), 200, "")
	h.expect(h.send(bob, "PUT", base+"/membership", map[string]string{}), 200, "")
	event := makeSpace(h, alice, "event", "private", 10, &id)
	eb := "/v1/spaces/" + event
	h.expect(h.call(cara, "GET", eb), 404, "NOT_FOUND")
	if got := h.ok(bob, "GET", eb)["location"]; got != "" {
		t.Fatal("private location leaked")
	}
	h.expect(h.send(bob, "PUT", eb+"/membership", map[string]string{"rsvp": "interested"}), 200, "")
	h.expect(h.send(alice, "PUT", eb+"/members/"+bob, map[string]string{"action": "approve"}), 200, "")
	if got := h.ok(bob, "GET", eb)["location"]; got == "" {
		t.Fatal("member location missing")
	}
	h.expect(h.call(bob, "DELETE", base+"/membership"), 200, "")
	h.expect(h.call(bob, "GET", eb), 404, "NOT_FOUND")
	// Spaces need only an active, onboarded member: no eligibility row exists for anyone in this test.
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM discovery_eligibility`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("eligibility rows %d (%v)", rows, err)
	}
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "invite"}), 200, "")
	// A member who has not finished onboarding sees no spaces and cannot be invited.
	h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, bob)
	if len(items(h.ok(bob, "GET", "/v1/spaces"))) != 0 {
		t.Fatal("a member who is not onboarded saw spaces")
	}
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "invite"}), 404, "NOT_FOUND")
	h.exec(`UPDATE onboarding SET completed_at=now() WHERE user_id=$1`, bob)
	h.expect(h.call(bob, "GET", "/v1/spaces"), 200, "")
	// A deactivated host's spaces disappear for everyone at once.
	makeSpace(h, alice, "community", "public", 10, nil)
	if len(items(h.ok(cara, "GET", "/v1/spaces"))) != 1 {
		t.Fatal("the host's space is missing")
	}
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, alice)
	if len(items(h.ok(cara, "GET", "/v1/spaces"))) != 0 {
		t.Fatal("a deactivated host's spaces leaked")
	}
}
func TestSpacesCapacityConcurrentJoinsAndMomentExpiry(t *testing.T) {
	h := newSocialHarness(t)
	id := makeSpace(h, alice, "moment", "public", 2, nil)
	base := "/v1/spaces/" + id
	var wg sync.WaitGroup
	results := make(chan int, 3)
	for _, user := range []string{bob, cara, dev} {
		wg.Add(1)
		go func(u string) {
			defer wg.Done()
			results <- h.send(u, "PUT", base+"/membership", map[string]string{}).status
		}(user)
	}
	wg.Wait()
	close(results)
	success := 0
	for code := range results {
		if code == 200 {
			success++
		} else if code != 409 {
			t.Fatalf("join status %d", code)
		}
	}
	if success != 1 {
		t.Fatalf("capacity accepted %d", success)
	}
	var joined string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT user_id::text FROM space_members WHERE space_id=$1 AND role='member' AND state='active'`, id).Scan(&joined); err != nil {
		t.Fatal(err)
	}
	h.expect(h.send(joined, "POST", base+"/entries", map[string]string{"body": "on time"}), 201, "")
	h.exec(`UPDATE spaces SET starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour' WHERE space_id=$1`, id)
	h.expect(h.send(joined, "POST", base+"/entries", map[string]string{"body": "too late"}), 409, "SPACE_CLOSED")
	h.expect(h.call(joined, "GET", base+"/entries"), 200, "")
	h.expect(h.call(joined, "DELETE", base+"/membership"), 200, "")
	if got := h.ok(alice, "GET", base)["memberCount"]; got != float64(1) {
		t.Fatalf("count %v", got)
	}
	h.expect(h.send(bob, "PUT", base+"/membership", map[string]string{}), 409, "SPACE_CLOSED")
}
func TestSpacesPaginationBlocksAndValidation(t *testing.T) {
	h := newSocialHarness(t)
	for i := 0; i < 3; i++ {
		makeSpace(h, alice, "community", "public", 10, nil)
	}
	p := h.ok(bob, "GET", "/v1/spaces?limit=2")
	if len(items(p)) != 2 {
		t.Fatal(p)
	}
	cursor := p["nextCursor"].(string)
	p2 := h.ok(bob, "GET", "/v1/spaces?limit=2&cursor="+cursor)
	if len(items(p2)) != 1 {
		t.Fatal(p2)
	}
	h.expect(h.call(bob, "GET", "/v1/spaces?kind=event&cursor="+cursor), 422, "INVALID_CURSOR")
	h.expect(h.call(alice, "GET", "/v1/spaces?cursor="+cursor), 422, "INVALID_CURSOR")
	h.expect(h.call(bob, "POST", "/v1/users/"+alice+"/block"), 200, "")
	if len(items(h.ok(bob, "GET", "/v1/spaces"))) != 0 {
		t.Fatal("blocked host in browse")
	}
	for _, in := range []map[string]any{{"kind": "event", "title": "x", "visibility": "public", "capacity": 10, "timezone": "Bad/Zone"}, {"kind": "community", "title": "x", "visibility": "public", "capacity": 1}, {"kind": "moment", "title": "x", "visibility": "public", "capacity": 10, "startsAt": time.Now(), "endsAt": time.Now().Add(25 * time.Hour)}} {
		h.expect(h.send(alice, "POST", "/v1/spaces", in), 422, "VALIDATION")
	}
}

func TestSpacesEditsCannotWidenAudienceAndPreserveRSVP(t *testing.T) {
	h := newSocialHarness(t)
	id := makeSpace(h, alice, "event", "private", 3, nil)
	base := "/v1/spaces/" + id
	h.expect(h.send(bob, "PUT", base+"/membership", map[string]string{"rsvp": "interested"}), 200, "")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "approve"}), 200, "")
	if got := h.ok(bob, "GET", base)["myRsvp"]; got != "interested" {
		t.Fatalf("approval lost RSVP %v", got)
	}
	in := map[string]any{"kind": "event", "title": "Updated meetup", "visibility": "private", "capacity": 3, "timezone": "America/New_York", "startsAt": time.Now().Add(time.Hour), "endsAt": time.Now().Add(2 * time.Hour)}
	h.expect(h.send(bob, "PUT", base, in), 403, "SPACE_ROLE_REQUIRED")
	h.expect(h.send(alice, "PUT", base, in), 200, "")
	in["visibility"] = "public"
	h.expect(h.send(alice, "PUT", base, in), 422, "VALIDATION")
	in["visibility"] = "private"
	in["capacity"] = 1
	h.expect(h.send(alice, "PUT", base, in), 422, "VALIDATION")
	h.expect(h.send(alice, "POST", base+"/invitations", map[string]string{"username": "@niko"}), 200, "")
	h.expect(h.send(bob, "PUT", base+"/members/"+bob, map[string]string{"action": "admin"}), 403, "SPACE_ROLE_REQUIRED")
}

func TestSpacesRecheckModeratorRoleAfterWaitingForLock(t *testing.T) {
	h := newSocialHarness(t)
	id := makeSpace(h, alice, "community", "public", 10, nil)
	base := "/v1/spaces/" + id
	h.expect(h.send(bob, "PUT", base+"/membership", map[string]string{}), 200, "")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "moderator"}), 200, "")
	entry := h.expect(h.send(alice, "POST", base+"/entries", map[string]string{"body": "Owner context"}), 201, "").data["entryId"].(string)
	tx, e := h.db.Pool.Begin(h.ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(h.ctx)
	if _, e = tx.Exec(h.ctx, `SELECT space_id FROM spaces WHERE space_id=$1 FOR UPDATE`, id); e != nil {
		t.Fatal(e)
	}
	done := make(chan reply, 1)
	go func() { done <- h.call(bob, "DELETE", base+"/entries/"+entry) }()
	deadline := time.Now().Add(3 * time.Second)
	waiting := false
	for time.Now().Before(deadline) {
		if e = h.db.Pool.QueryRow(h.ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'SELECT space_id::text FROM spaces%')`).Scan(&waiting); e != nil {
			t.Fatal(e)
		}
		if waiting {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("moderator mutation did not wait on space lock")
	}
	if _, e = tx.Exec(h.ctx, `UPDATE space_members SET role='member' WHERE space_id=$1 AND user_id=$2`, id, bob); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(h.ctx); e != nil {
		t.Fatal(e)
	}
	select {
	case got := <-done:
		h.expect(got, 404, "NOT_FOUND")
	case <-time.After(3 * time.Second):
		t.Fatal("mutation did not finish")
	}
	if len(items(h.ok(alice, "GET", base+"/entries"))) != 1 {
		t.Fatal("demoted moderator deleted the context")
	}
}

// Usernames are public (anyone can check whether one is taken), so inviting by username answers
// exactly the same for a member the host may not reach (other age band, blocked, not onboarded)
// and for nobody at all as for a real invitation, refusals included, and only invites, notifies
// and signals the reachable member.
func TestSpaceInvitationByUsernameRevealsNothing(t *testing.T) {
	h := newSocialHarness(t)
	_, sender := withRealtime(t, h)
	h.ageAt(cara, 30)
	h.ageAt(xan, 15)
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, dev, cara)
	h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, eli)
	for _, u := range []string{xan, dev, eli, yui} {
		d := h.register(u)
		h.exec(`UPDATE devices SET push_provider='fcm',push_token=$2 WHERE device_id=$1`, d.id, "push-token-"+u)
	}
	space := makeSpace(h, cara, "community", "invite", 10, nil)
	invite := func(space, username string) reply {
		h.api.content.reset(cara)
		return h.send(cara, "POST", "/v1/spaces/"+space+"/invitations", map[string]string{"username": username})
	}
	unreachable := []string{"xan", "dev_k", "eli", "nobody_here"}
	valid := h.expect(invite(space, "yui"), 200, "").data
	for _, name := range append(unreachable, "yui") {
		if got := h.expect(invite(space, name), 200, "").data; fmt.Sprint(got) != fmt.Sprint(valid) {
			t.Fatalf("%s answered %v, a real invitation %v", name, got, valid)
		}
	}
	if got := userIDs(items(h.ok(cara, "GET", "/v1/spaces/"+space+"/members?state=invited"))); fmt.Sprint(got) != fmt.Sprint([]string{yui}) {
		t.Fatalf("invited %v", got)
	}
	var rows, notes int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT count(*) FROM space_members WHERE space_id=$1),(SELECT count(*) FROM notifications WHERE event='space.invited')`, space).Scan(&rows, &notes); err != nil || rows != 2 || notes != 1 {
		t.Fatalf("members %d notifications %d %v", rows, notes, err)
	}
	eventually(t, func() bool { return len(sender.list()) >= 1 })
	time.Sleep(100 * time.Millisecond)
	if got := sender.list(); fmt.Sprint(got) != fmt.Sprint([]string{yui + ":space_invite"}) {
		t.Fatalf("pushes %v", got)
	}
	// The refusals a real invitation can meet come first for everyone alike.
	child := makeSpace(h, cara, "event", "private", 10, &space)
	for _, name := range append(unreachable, "niko") {
		h.expect(invite(child, name), 403, "SPACE_MEMBER_REQUIRED")
	}
	h.expect(h.send(cara, "PUT", "/v1/spaces/"+space+"/status", map[string]string{"status": "closed"}), 200, "")
	for _, name := range append(unreachable, "niko") {
		h.expect(invite(space, name), 409, "SPACE_CLOSED")
	}
}

// Moderators act only on people in the space (or, to ban, someone they may reach): anything
// else is 404, never a 500 or a silent success, and only a real change signals anyone (moderation is never pushed).
func TestSpaceModerationNeedsAMembership(t *testing.T) {
	h := newSocialHarness(t)
	_, sender := withRealtime(t, h)
	h.ageAt(cara, 30)
	h.ageAt(xan, 15)
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, dev, cara)
	space := makeSpace(h, cara, "community", "public", 10, nil)
	member := func(actor, target, action string) reply {
		h.api.content.reset(actor)
		return h.send(actor, "PUT", "/v1/spaces/"+space+"/members/"+target, map[string]string{"action": action})
	}
	for _, target := range []string{xan, dev, "019a4000-0000-7000-8000-00000000beef"} {
		h.expect(member(cara, target, "remove"), 404, "NOT_FOUND")
		h.expect(member(cara, target, "ban"), 404, "NOT_FOUND")
		h.expect(member(cara, target, "approve"), 404, "NOT_FOUND")
		// A role can only be given to an active member; for the owner that is 404, not a role error.
		for _, role := range []string{"member", "moderator", "admin"} {
			h.expect(member(cara, target, role), 404, "NOT_FOUND")
		}
	}
	for _, role := range []string{"member", "moderator", "admin"} {
		h.expect(member(cara, eli, role), 404, "NOT_FOUND")
	}
	// A reachable stranger can be banned pre-emptively, and unbanned once.
	h.expect(member(cara, eli, "remove"), 404, "NOT_FOUND")
	h.expect(member(cara, eli, "ban"), 200, "")
	h.expect(member(cara, eli, "unban"), 200, "")
	h.expect(member(cara, eli, "unban"), 404, "NOT_FOUND")

	d := h.register(yui)
	h.exec(`UPDATE devices SET push_provider='fcm',push_token='push-token-yui' WHERE device_id=$1`, d.id)
	h.api.content.reset(yui)
	h.expect(h.send(yui, "PUT", "/v1/spaces/"+space+"/membership", map[string]string{}), 200, "")
	pushes := func() int { time.Sleep(100 * time.Millisecond); return len(sender.list()) }
	// Setting the role a member already has changes nothing and wakes nobody.
	h.expect(member(cara, yui, "member"), 200, "")
	if n := pushes(); n != 0 {
		t.Fatalf("no-op woke the member: %v", sender.list())
	}
	// Moderation is signalled to the member's open apps but never pushed.
	h.expect(member(cara, yui, "moderator"), 200, "")
	h.ok(yui, "POST", "/v1/users/"+cara+"/mute")
	h.expect(member(cara, yui, "member"), 200, "")
	h.expect(member(cara, yui, "remove"), 200, "")
	h.expect(member(cara, yui, "remove"), 404, "NOT_FOUND")
	if n := pushes(); n != 0 {
		t.Fatalf("moderation woke the member: %v", sender.list())
	}
	// A moderator cannot reach someone who blocked them even when the owner can.
	h.expect(h.send(yui, "PUT", "/v1/spaces/"+space+"/membership", map[string]string{}), 200, "")
	h.expect(member(cara, yui, "admin"), 200, "")
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, bob, yui)
	h.expect(member(yui, bob, "ban"), 404, "NOT_FOUND")
	h.expect(member(yui, bob, "invite"), 404, "NOT_FOUND")
	h.api.content.reset(yui)
	before := h.expect(h.send(yui, "POST", "/v1/spaces/"+space+"/invitations", map[string]string{"username": "niko"}), 200, "").data
	if got := userIDs(items(h.ok(cara, "GET", "/v1/spaces/"+space+"/members?state=invited"))); len(got) != 0 || before["memberCount"] != float64(2) {
		t.Fatalf("invited past a block: %v %v", got, before)
	}
}
