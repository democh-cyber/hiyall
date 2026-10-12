package httpapi

import (
	"slices"
	"testing"
	"time"
)

// friendsWithChat makes alice and bob friends with one conversation and a
// device each, and returns the conversation path.
func friendsWithChat(h *socialHarness) (string, testDevice, testDevice) {
	h.t.Helper()
	phone, bobPhone := h.register(alice), h.register(bob)
	h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
	return "/v1/conversations/" + id, phone, bobPhone
}

func TestMuteSilencesActivityAndPushWithoutTellingTheTarget(t *testing.T) {
	h := newSocialHarness(t)
	_, sender := withRealtime(t, h)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(bob, "PUT", "/v1/devices/"+bobPhone.id+"/push", map[string]string{"provider": "fcm", "token": "bob-token-123"}), 200, "")
	h.ok(bob, "POST", "/v1/notifications/read-all")
	pushes := len(sender.list())

	h.expect(h.send(bob, "POST", "/v1/users/"+alice+"/mute", map[string]string{"until": time.Now().Add(-time.Hour).Format(time.RFC3339)}), 422, "VALIDATION")
	h.expect(h.call(bob, "POST", "/v1/users/"+bob+"/mute"), 422, "VALIDATION")
	h.expect(h.call(bob, "POST", "/v1/users/019a4000-0000-7000-8000-00000000ffff/mute"), 404, "NOT_FOUND")
	h.ok(bob, "POST", "/v1/users/"+alice+"/mute")

	if rel := h.ok(bob, "GET", "/v1/users/"+alice+"/profile")["relationship"].(map[string]any); rel["muted"] != true {
		t.Fatalf("bob's own view %v", rel)
	}
	if rel := h.ok(alice, "GET", "/v1/users/"+bob+"/profile")["relationship"].(map[string]any); rel["muted"] != false || rel["restricted"] != false {
		t.Fatalf("mute leaked to its target: %v", rel)
	}

	// Alice's activity still lists for Bob but arrives read, and nothing is pushed.
	h.ok(alice, "DELETE", "/v1/users/"+bob+"/follow")
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	if n := h.ok(bob, "GET", "/v1/notifications"); n["unreadCount"] != float64(0) || len(items(n)) == 0 {
		t.Fatalf("muted activity %v", n)
	}
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	time.Sleep(50 * time.Millisecond)
	if got := sender.list(); len(got) != pushes {
		t.Fatalf("pushed while muted: %v", got[pushes:])
	}
	// A muted person's messages still count; only notifications are silenced.
	if u := h.ok(bob, "GET", "/v1/conversations/unread"); u["messages"] != float64(1) {
		t.Fatalf("unread %v", u)
	}

	if list := items(h.ok(bob, "GET", "/v1/me/muted")); len(list) != 1 || list[0]["user"].(map[string]any)["userId"] != alice {
		t.Fatalf("muted list %v", list)
	}
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/mute")
	if list := items(h.ok(bob, "GET", "/v1/me/muted")); len(list) != 0 {
		t.Fatalf("still muted %v", list)
	}
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	eventually(t, func() bool { return slices.Contains(sender.list()[pushes:], bob+":message") })

	// A timed mute lapses on its own.
	h.ok(bob, "POST", "/v1/users/"+alice+"/mute")
	h.exec(`UPDATE user_controls SET until=now()-interval '1 second' WHERE actor_id=$1`, bob)
	if list := items(h.ok(bob, "GET", "/v1/me/muted")); len(list) != 0 {
		t.Fatalf("expired mute listed %v", list)
	}
}

func TestRestrictHidesReceiptsAndKeepsChatsOutOfTheBadge(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.policy(alice, "readReceipts", true)
	h.policy(bob, "readReceipts", true)
	sent := h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "").data
	h.expect(h.send(bob, "POST", path+"/read", map[string]any{"readAt": sent["createdAt"]}), 200, "")
	if c := h.ok(alice, "GET", path); c["peerReadAt"] == nil {
		t.Fatal("receipts should be on before restricting")
	}

	h.ok(bob, "POST", "/v1/users/"+alice+"/restrict")
	for _, viewer := range []string{alice, bob} {
		if c := h.ok(viewer, "GET", path); c["peerReadAt"] != nil {
			t.Fatalf("%s still sees receipts: %v", viewer, c)
		}
	}
	if rel := h.ok(alice, "GET", "/v1/users/"+bob+"/profile")["relationship"].(map[string]any); rel["restricted"] != false {
		t.Fatalf("restriction leaked: %v", rel)
	}
	// Alice can still message; Bob's chat row counts it, the badge does not.
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	if c := h.ok(bob, "GET", path); c["unreadCount"] != float64(1) {
		t.Fatalf("chat row %v", c)
	}
	if u := h.ok(bob, "GET", "/v1/conversations/unread"); u["messages"] != float64(0) {
		t.Fatalf("restricted chat in badge %v", u)
	}
	if list := items(h.ok(bob, "GET", "/v1/me/restricted")); len(list) != 1 {
		t.Fatalf("restricted list %v", list)
	}
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/restrict")
	if c := h.ok(alice, "GET", path); c["peerReadAt"] == nil {
		t.Fatal("receipts did not come back")
	}
}

func TestConversationMuteLeavesTheBadgeUntilUnmuted(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	h.ok(bob, "POST", path+"/mute")
	if c := h.ok(bob, "GET", path); c["mutedUntil"] == nil || c["unreadCount"] != float64(1) {
		t.Fatalf("muted chat %v", c)
	}
	if c := h.ok(alice, "GET", path); c["mutedUntil"] != nil {
		t.Fatalf("mute leaked to peer %v", c)
	}
	if u := h.ok(bob, "GET", "/v1/conversations/unread"); u["messages"] != float64(0) {
		t.Fatalf("muted chat in badge %v", u)
	}
	h.expect(h.call(cara, "POST", path+"/mute"), 404, "NOT_FOUND")
	h.ok(bob, "DELETE", path+"/mute")
	if u := h.ok(bob, "GET", "/v1/conversations/unread"); u["messages"] != float64(1) {
		t.Fatalf("unmuted badge %v", u)
	}
	until := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
	got := h.expect(h.send(bob, "POST", path+"/mute", map[string]string{"until": until.Format(time.RFC3339)}), 200, "").data
	if got["until"] != until.Format(time.RFC3339) {
		t.Fatalf("until %v", got)
	}
}

func TestReportsTakeOnlyChosenEvidenceAndFeedTheOperatorQueue(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	threat := h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "").data["messageId"].(string)
	convo := path[len("/v1/conversations/"):]
	at := time.Now().UTC().Format(time.RFC3339)

	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": dev, "reasonCode": "nope"}), 422, "VALIDATION")
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": cara, "reasonCode": "spam"}), 422, "VALIDATION")
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": dev, "reasonCode": "spam", "extra": 1}), 422, "VALIDATION")
	// Outsiders can't report into a chat they aren't in.
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "message", "targetId": threat, "reasonCode": "threats"}), 404, "NOT_FOUND")
	evidence := []map[string]any{{"messageId": threat, "text": "the decrypted words", "sentAt": at, "fromMe": true}}
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": convo, "reasonCode": "threats", "evidence": evidence}), 422, "VALIDATION")
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "threats", "evidence": evidence, "disclosureConsent": true}), 422, "VALIDATION")
	foreign := []map[string]any{{"messageId": "019a4000-0000-7000-8000-00000000eeee", "text": "x", "sentAt": at}}
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": convo, "reasonCode": "threats", "evidence": foreign, "disclosureConsent": true}), 422, "VALIDATION")

	made := h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{
		"targetType": "conversation", "targetId": convo, "reasonCode": "threats", "description": "  scared  ",
		"evidence": evidence, "disclosureConsent": true, "block": true,
	}), 201, "").data
	report := made["report"].(map[string]any)
	if made["blocked"] != true || report["status"] != "open" || report["subject"].(map[string]any)["userId"] != bob {
		t.Fatalf("report %v", made)
	}
	// Blocking closed the chat for both.
	h.expect(h.call(bob, "GET", path), 404, "NOT_FOUND")
	again := h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": convo, "reasonCode": "spam"}), 200, "").data
	if again["duplicate"] != true || again["report"].(map[string]any)["reportId"] != report["reportId"] {
		t.Fatalf("repeat report %v", again)
	}
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": dev, "reasonCode": "spam"}), 201, "")

	queue, err := h.db.ReportQueue(h.ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(queue) != 2 || queue[0].Severity != "high" || queue[0].Description != "scared" {
		t.Fatalf("queue %+v", queue)
	}
	// Sender and time come from the relay, not from the reporter's claim.
	if e := queue[0].Evidence; len(e) != 1 || e[0].FromMe || e[0].Text != "the decrypted words" {
		t.Fatalf("evidence %+v", e)
	}
	var stored string
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT evidence::text FROM reports WHERE report_id=$1`, report["reportId"]).Scan(&stored); err != nil || len(stored) == 0 {
		t.Fatal(err)
	}
	if mine := items(h.ok(alice, "GET", "/v1/me/reports")); len(mine) != 1 || mine[0]["reasonCode"] != "threats" {
		t.Fatalf("my reports %v", mine)
	}
	if theirs := items(h.ok(bob, "GET", "/v1/me/reports")); len(theirs) != 0 {
		t.Fatalf("reported person sees reports: %v", theirs)
	}

	if err = h.db.ResolveReport(h.ctx, queue[0].ReportID, "ops@hiyall", "suspend", "credible threat"); err != nil {
		t.Fatal(err)
	}
	h.expect(h.call(bob, "GET", "/v1/me/reports"), 401, "UNAUTHENTICATED")
	if err = h.db.ResolveReport(h.ctx, queue[0].ReportID, "ops@hiyall", "dismiss", ""); err == nil {
		t.Fatal("resolved twice")
	}
	if mine := items(h.ok(alice, "GET", "/v1/me/reports")); mine[0]["status"] != "actioned" || mine[0]["resolvedAt"] == nil {
		t.Fatalf("status %v", mine)
	}
	if err = h.db.RestoreUser(h.ctx, bob, "ops@hiyall", "appeal upheld"); err != nil {
		t.Fatal(err)
	}
	h.ok(bob, "GET", "/v1/me/reports")
	var actions int
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM moderation_actions WHERE subject_id=$1`, bob).Scan(&actions); err != nil || actions != 2 {
		t.Fatalf("audit trail %d %v", actions, err)
	}
}

func TestReportsAreRateLimitedPerAccount(t *testing.T) {
	h := newSocialHarness(t)
	targets := []string{alice, bob, dev, eli, xan, yui}
	limited := false
	for i := 0; i < 12 && !limited; i++ {
		got := h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": targets[i%len(targets)], "reasonCode": "spam"})
		limited = got.status == 429
	}
	if !limited {
		t.Fatal("reports were not rate limited")
	}
}

// Mute and restrict reach only members whose profile the caller could open: another age band or
// an unfinished account is 404. A report against them is accepted but names nobody, in the answer
// and in the caller's list, and the mute and restrict lists leave them out; the blocked list does not.
func TestSafetyControlsAndReportsDoNotNameBarredMembers(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(cara, 30)
	h.ageAt(xan, 15)
	h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, eli)
	for _, target := range []string{xan, eli} {
		for _, control := range []string{"mute", "restrict"} {
			h.api.graph.reset(cara)
			h.expect(h.call(cara, "POST", "/v1/users/"+target+"/"+control), 404, "NOT_FOUND")
			h.expect(h.call(cara, "DELETE", "/v1/users/"+target+"/"+control), 200, "")
		}
		report := h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": target, "reasonCode": "spam"}), 201, "").data["report"].(map[string]any)
		if subject := report["subject"].(map[string]any); subject["userId"] != target || subject["username"] != "" || subject["displayName"] != "" {
			t.Fatalf("report names a barred member: %v", subject)
		}
	}
	for _, r := range items(h.ok(cara, "GET", "/v1/me/reports")) {
		if subject := r["subject"].(map[string]any); subject["username"] != "" || subject["displayName"] != "" {
			t.Fatalf("my reports name a barred member: %v", subject)
		}
	}
	// A reachable member is named, and stays listed until they move out of reach.
	h.ageAt(dev, 31)
	h.ok(cara, "POST", "/v1/users/"+dev+"/mute")
	h.ok(cara, "POST", "/v1/users/"+dev+"/restrict")
	h.ok(cara, "POST", "/v1/users/"+dev+"/block")
	report := h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": dev, "reasonCode": "spam"}), 201, "").data["report"].(map[string]any)
	if report["subject"].(map[string]any)["username"] != "dev_k" {
		t.Fatalf("reachable subject not named: %v", report)
	}
	for _, list := range []string{"muted", "restricted", "blocked"} {
		if got := ids(h.ok(cara, "GET", "/v1/me/"+list)); !slices.Contains(got, dev) {
			t.Fatalf("%s %v", list, got)
		}
	}
	h.ageAt(dev, 16)
	for _, list := range []string{"muted", "restricted"} {
		if got := ids(h.ok(cara, "GET", "/v1/me/"+list)); slices.Contains(got, dev) {
			t.Fatalf("%s lists a member in the other band: %v", list, got)
		}
	}
	if got := ids(h.ok(cara, "GET", "/v1/me/blocked")); !slices.Contains(got, dev) {
		t.Fatalf("blocked list lost a block: %v", got)
	}
}
