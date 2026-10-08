package httpapi

import (
	"sync"
	"testing"
	"time"
)

func adultSpaces(h *socialHarness, users ...string) {
	for _, id := range users {
		h.exec(`INSERT INTO discovery_eligibility(user_id,age_group,confirmed_at,valid_until) VALUES($1,'adult',now()-interval '1 day',now()+interval '1 day') ON CONFLICT(user_id) DO UPDATE SET age_group='adult',valid_until=now()+interval '1 day'`, id)
	}
}
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
	adultSpaces(h, alice, bob, cara, dev)
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
func TestSpacesInviteParentMembershipAndAgeBoundary(t *testing.T) {
	h := newSocialHarness(t)
	adultSpaces(h, alice, bob, cara)
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
	h.exec(`UPDATE discovery_eligibility SET age_group='minor' WHERE user_id=$1`, bob)
	h.expect(h.call(bob, "GET", "/v1/spaces"), 403, "ADULT_SPACE_REQUIRED")
	h.expect(h.send(alice, "PUT", base+"/members/"+bob, map[string]string{"action": "invite"}), 404, "NOT_FOUND")
	h.exec(`UPDATE discovery_eligibility SET valid_until=now()-interval '1 minute' WHERE user_id=$1`, alice)
	if len(items(h.ok(cara, "GET", "/v1/spaces"))) != 0 {
		t.Fatal("expired host's spaces leaked")
	}
}
func TestSpacesCapacityConcurrentJoinsAndMomentExpiry(t *testing.T) {
	h := newSocialHarness(t)
	adultSpaces(h, alice, bob, cara, dev)
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
	adultSpaces(h, alice, bob)
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
	adultSpaces(h, alice, bob)
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
	adultSpaces(h, alice, bob)
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
