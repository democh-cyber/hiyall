package httpapi

import (
	"fmt"
	"testing"

	"hiyall/services/api/internal/store"
)

func (h *socialHarness) n(query string, args ...any) int {
	h.t.Helper()
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, query, args...).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

// Notifications older than 90 days go; younger ones stay.
func TestNotificationRetention(t *testing.T) {
	h := newSocialHarness(t)
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(cara, "POST", "/v1/users/"+alice+"/follow")
	h.exec(`UPDATE notifications SET created_at=now()-interval '91 days' WHERE actor_id=$1`, bob)
	n, err := h.db.PurgeNotifications(h.ctx, store.NotificationRetention)
	if err != nil || n != 1 {
		t.Fatalf("purged %d (%v), want 1", n, err)
	}
	if h.n(`SELECT count(*) FROM notifications WHERE recipient_id=$1`, alice) != 1 {
		t.Fatal("a young notification was removed")
	}
}

// A closed report is deleted 180 days after it closed with its actions, unless it holds evidence; an open one is
// never deleted.
func TestClosedReportRetentionRespectsHolds(t *testing.T) {
	h := newSocialHarness(t)
	report := func(id, status, resolved string) {
		h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status,resolved_at)
 VALUES($1,$2,'user',$3,$3,'spam','normal',$4,CASE WHEN $5='' THEN NULL ELSE now()-$5::interval END)`, id, alice, bob, status, resolved)
	}
	const old, held, open, young = "019a4000-0000-7000-8000-00000000a001", "019a4000-0000-7000-8000-00000000a002", "019a4000-0000-7000-8000-00000000a003", "019a4000-0000-7000-8000-00000000a004"
	report(old, "dismissed", "181 days")
	report(held, "actioned", "181 days")
	report(young, "dismissed", "10 days")
	// (reports_open_once allows one open report per reporter and target; use another reporter)
	h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status) VALUES($1,$2,'user',$3,$3,'spam','normal','open')`, open, cara, bob)
	h.exec(`INSERT INTO moderation_actions(action_id,report_id,actor,subject_id,action_type) VALUES(gen_random_uuid(),$1,'op',$2,'dismiss')`, old, bob)
	conversation := "019a4000-0000-7000-8000-00000000b001"
	low, high := alice, bob
	h.exec(`INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) VALUES($1,$2,$3,$2,'active')`, conversation, low, high)
	h.exec(`INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,role,size_bytes,ct_sha256,state,object_key,held_report_id,expires_at,uploaded_at)
 VALUES(gen_random_uuid(),$1,$2,'full',100,decode(repeat('ab',32),'hex'),'uploaded','chat/x',$3,now()+interval '1 day',now())`, alice, conversation, held)
	n, err := h.db.PurgeClosedReports(h.ctx, store.ReportRetention)
	if err != nil || n != 1 {
		t.Fatalf("purged %d (%v), want 1", n, err)
	}
	if h.n(`SELECT count(*) FROM reports WHERE report_id=$1`, old) != 0 || h.n(`SELECT count(*) FROM moderation_actions WHERE report_id=$1`, old) != 0 {
		t.Fatal("the old closed report and its action should be gone")
	}
	for _, id := range []string{held, open, young} {
		if h.n(`SELECT count(*) FROM reports WHERE report_id=$1`, id) != 1 {
			t.Fatalf("report %s must be kept", id)
		}
	}
}

// Soft-deleted posts, comments and space entries are blanked after a day and deleted after 30; an open report
// keeps them whole, and a comment others replied to stays until its replies are gone.
func TestDeletedContentIsBlankedThenRemoved(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(alice, "commentsFrom", "everyone")
	gone, kept, reported := h.post(alice, "public", "to delete"), h.post(alice, "public", "stays"), h.post(alice, "public", "reported")
	h.expect(h.send(bob, "PUT", "/v1/posts/"+gone+"/reaction", map[string]string{"reaction": "heart"}), 200, "")
	parent := h.expect(h.send(bob, "POST", "/v1/posts/"+kept+"/comments", map[string]any{"body": "parent"}), 201, "").data["commentId"].(string)
	h.expect(h.send(cara, "POST", "/v1/posts/"+kept+"/comments", map[string]any{"body": "reply", "parentId": parent}), 201, "")
	h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity) VALUES(gen_random_uuid(),$1,'post',$2,$3,'spam','normal')`, bob, reported, alice)
	h.exec(`UPDATE posts SET deleted_at=now()-interval '2 days' WHERE post_id IN ($1,$2)`, gone, reported)
	h.exec(`UPDATE comments SET deleted_at=now()-interval '2 days' WHERE comment_id=$1`, parent)

	if n, err := h.db.BlankDeletedContent(h.ctx, store.DeletedContentBlankAfter); err != nil || n != 2 {
		t.Fatalf("blanked %d (%v), want the deleted post and comment", n, err)
	}
	if h.n(`SELECT count(*) FROM posts WHERE post_id=$1 AND body=''`, gone) != 1 || h.n(`SELECT count(*) FROM posts WHERE post_id=$1 AND body='reported'`, reported) != 1 {
		t.Fatal("the deleted post must be blank and the reported one untouched")
	}
	// Nothing is old enough to delete yet.
	if n, err := h.db.PurgeDeletedContent(h.ctx, store.DeletedContentRetention); err != nil || n != 0 {
		t.Fatalf("purged %d early (%v)", n, err)
	}
	h.exec(`UPDATE posts SET deleted_at=now()-interval '31 days' WHERE post_id IN ($1,$2)`, gone, reported)
	h.exec(`UPDATE comments SET deleted_at=now()-interval '31 days' WHERE comment_id=$1`, parent)
	if _, err := h.db.PurgeDeletedContent(h.ctx, store.DeletedContentRetention); err != nil {
		t.Fatal(err)
	}
	if h.n(`SELECT count(*) FROM posts WHERE post_id=$1`, gone) != 0 || h.n(`SELECT count(*)+(SELECT count(*) FROM post_reactions WHERE post_id=$1)+(SELECT count(*) FROM post_counters WHERE post_id=$1) FROM posts WHERE post_id=$1`, gone) != 0 {
		t.Fatal("the deleted post and what hangs on it should be gone")
	}
	if h.n(`SELECT count(*) FROM posts WHERE post_id=$1`, reported) != 1 {
		t.Fatal("a post under an open report must be kept")
	}
	if h.n(`SELECT count(*) FROM comments WHERE comment_id=$1`, parent) != 1 {
		t.Fatal("a comment that has a reply must stay")
	}
	h.exec(`UPDATE comments SET deleted_at=now()-interval '31 days' WHERE parent_id=$1`, parent)
	if _, err := h.db.PurgeDeletedContent(h.ctx, store.DeletedContentRetention); err != nil {
		t.Fatal(err)
	}
	if h.n(`SELECT count(*) FROM comments WHERE post_id=$1`, kept) != 0 {
		t.Fatal("the thread should go leaf first once both are old")
	}
}

// Message metadata older than 180 days goes when nothing needs it; the latest real message of each member stays
// (the reply rule reads it), and so do messages named as evidence, with attachments or still undelivered.
func TestMessageMetadataRetention(t *testing.T) {
	h := newSocialHarness(t)
	conversation := "019a4000-0000-7000-8000-00000000b002"
	h.exec(`INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) VALUES($1,$2,$3,$2,'active')`, conversation, alice, bob)
	device := func(user string) string {
		id := fmt.Sprintf("019a4000-0000-7000-8000-00000000c%03d", len(user)%7+int(user[len(user)-1]%10))
		h.exec(`INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform) VALUES($1::uuid,$2::uuid,$1::text,'s','g','ios') ON CONFLICT DO NOTHING`, id, user)
		return id
	}
	da, db := device(alice), device(bob)
	msg := func(n int, sender, deviceID string, ageDays int, aux bool) string {
		id := fmt.Sprintf("019a4000-0000-7000-8000-00000000d%03d", n)
		h.exec(`INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at,aux) VALUES($1,$2,$3,$4,now()-make_interval(days=>$5),$6)`, id, conversation, sender, deviceID, ageDays, aux)
		return id
	}
	oldA1 := msg(1, alice, da, 400, false) // replaced by newer messages of alice: goes
	oldA2 := msg(2, alice, da, 300, false) // so does this one
	oldReact := msg(3, bob, db, 300, true) // a reaction: goes
	oldB := msg(4, bob, db, 290, false)    // bob's latest real message: stays
	evidence := msg(5, alice, da, 250, false)
	_ = msg(6, alice, da, 240, false)
	pending := msg(7, alice, da, 250, false)
	blob := msg(8, alice, da, 250, false)
	young := msg(9, alice, da, 5, false) // alice's latest real message
	h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status,evidence,disclosure_consent)
 VALUES(gen_random_uuid(),$1,'conversation',$2,$3,'spam','normal','open',jsonb_build_array(jsonb_build_object('messageId',$4::text)),true)`, bob, conversation, alice, evidence)
	h.exec(`INSERT INTO message_envelopes(message_id,recipient_device_id,envelope_type,ciphertext) VALUES($1,$2,0,'x')`, pending, db)
	h.exec(`INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,message_id,role,size_bytes,ct_sha256,state,object_key,uploaded_at,expires_at)
 VALUES(gen_random_uuid(),$1,$2,$3,'full',100,decode(repeat('ab',32),'hex'),'uploaded','chat/y',now(),now()+interval '1 day')`, alice, conversation, blob)
	// The job resumes after the last message an earlier run examined (reconcile_state). This test backdates its
	// messages behind that cursor, which real messages never are, so it starts a pass from the beginning.
	h.exec(`DELETE FROM reconcile_state WHERE job='message_metadata_purge'`)
	if _, err := h.db.PurgeMessageMetadata(h.ctx, store.MessageMetadataRetention); err != nil {
		t.Fatal(err)
	}
	left := map[string]bool{}
	for _, id := range []string{oldA1, oldA2, oldReact, oldB, evidence, pending, blob, young} {
		left[id] = h.n(`SELECT count(*) FROM messages WHERE message_id=$1`, id) == 1
	}
	for id, want := range map[string]bool{oldA1: false, oldA2: false, oldReact: false, oldB: true, evidence: true, pending: true, blob: true, young: true} {
		// the evidence message is older than 180 days and a newer message of alice exists, so it is kept only
		// because a report names it; likewise the undelivered one and the one with an attachment.
		if left[id] != want {
			t.Errorf("message %s kept=%v want %v", id, left[id], want)
		}
	}
}

// Finished photo rows go 30 days after, unless something still points at them.
func TestMediaTombstoneRetention(t *testing.T) {
	h := newSocialHarness(t)
	row := func(id string, days int) {
		h.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,expires_at,deleted_at,variants)
 VALUES($1::uuid,$2,'post','deleted','image/jpeg',10,10,'uploads/'||$1::text,now(),now()-make_interval(days=>$3),NULL)`, id, alice, days)
	}
	const old, young, linked = "019a4000-0000-7000-8000-00000000e001", "019a4000-0000-7000-8000-00000000e002", "019a4000-0000-7000-8000-00000000e003"
	row(old, 40)
	row(young, 5)
	row(linked, 40)
	post := h.post(alice, "public", "p")
	h.exec(`INSERT INTO post_media(post_id,position,media_id) VALUES($1,0,$2)`, post, linked)
	n, err := h.db.PurgeMediaTombstones(h.ctx, store.MediaTombstoneRetention)
	if err != nil || n != 1 {
		t.Fatalf("purged %d (%v), want 1", n, err)
	}
	if h.n(`SELECT count(*) FROM media_assets WHERE media_id=$1`, old) != 0 || h.n(`SELECT count(*) FROM media_assets WHERE media_id IN ($1,$2)`, young, linked) != 2 {
		t.Fatal("wrong tombstones removed")
	}
}

// The counters that are kept at write time are recomputed from the rows, and a drifted one is repaired.
func TestReconcileRepairsDriftedCounters(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`DELETE FROM reconcile_state`)
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(cara, "POST", "/v1/users/"+alice+"/follow")
	post := h.post(alice, "public", "hello")
	h.expect(h.send(bob, "PUT", "/v1/posts/"+post+"/reaction", map[string]string{"reaction": "heart"}), 200, "")
	space := h.expect(h.send(alice, "POST", "/v1/spaces", map[string]any{"kind": "community", "title": "Club", "visibility": "public", "capacity": 10}), 201, "").data["spaceId"].(string)
	h.exec(`UPDATE social_counters SET followers=40,friends=7 WHERE user_id=$1`, alice)
	h.exec(`INSERT INTO post_counters(post_id,slot,reactions,comments) VALUES($1,3,50,9) ON CONFLICT (post_id,slot) DO UPDATE SET reactions=50`, post)
	h.exec(`UPDATE spaces SET member_count=9 WHERE space_id=$1`, space)

	run := func() (int64, int64, int64) {
		a, err := h.db.ReconcileSocialCounters(h.ctx, 0)
		if err != nil {
			t.Fatal(err)
		}
		b, err := h.db.ReconcilePostCounters(h.ctx, 0)
		if err != nil {
			t.Fatal(err)
		}
		c, err := h.db.ReconcileSpaceMemberCounts(h.ctx, 0)
		if err != nil {
			t.Fatal(err)
		}
		return a, b, c
	}
	if a, b, c := run(); a != 1 || b != 1 || c != 1 {
		t.Fatalf("repaired %d social, %d post, %d space counters, want one of each", a, b, c)
	}
	if stats, _ := h.statsOf(alice, alice); stats["followers"] != float64(2) || stats["friends"] != float64(0) {
		t.Fatalf("stats after reconcile %v", stats)
	}
	if got := h.ok(alice, "GET", "/v1/posts/"+post); got["reactionCount"] != float64(1) {
		t.Fatalf("post counters after reconcile %v", got)
	}
	if h.n(`SELECT member_count FROM spaces WHERE space_id=$1`, space) != 1 {
		t.Fatal("the space member count was not repaired")
	}
	if a, b, c := run(); a != 0 || b != 0 || c != 0 {
		t.Fatalf("a second pass repaired %d %d %d", a, b, c)
	}
	// With a week between passes, a finished pass does nothing until the week is over.
	h.exec(`UPDATE social_counters SET followers=40 WHERE user_id=$1`, alice)
	if n, err := h.db.ReconcileSocialCounters(h.ctx, store.ReconcileEvery); err != nil || n != 0 {
		t.Fatalf("a pass inside the week repaired %d (%v)", n, err)
	}
	h.exec(`UPDATE reconcile_state SET finished_at=now()-interval '8 days'`)
	if n, err := h.db.ReconcileSocialCounters(h.ctx, store.ReconcileEvery); err != nil || n != 1 {
		t.Fatalf("the next weekly pass repaired %d (%v)", n, err)
	}
}

// The unread badge and a story's view count stop at 99 and say there are more.
func TestBadgeAndViewCountsAreCapped(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`INSERT INTO users(user_id) SELECT gen_random_uuid() FROM generate_series(1,130)`)
	h.exec(`INSERT INTO notifications(notification_id,recipient_id,actor_id,event,target_id)
 SELECT gen_random_uuid(),$1,u.user_id,'follow.started',u.user_id FROM users u WHERE u.user_id<>$1 LIMIT 120`, alice)
	// Actors need profiles and active accounts to be listed.
	h.exec(`INSERT INTO profiles(user_id,username,data) SELECT n.actor_id,'u'||substr(n.actor_id::text,1,8),'{}' FROM notifications n WHERE n.recipient_id=$1 AND NOT EXISTS(SELECT 1 FROM profiles p WHERE p.user_id=n.actor_id)`, alice)
	count, more, err := h.db.UnreadBadge(h.ctx, alice)
	if err != nil || count != 99 || !more {
		t.Fatalf("badge %d more=%v (%v), want 99 and more", count, more, err)
	}
	got := h.ok(alice, "GET", "/v1/notifications/unread-count")
	if got["unreadCount"] != float64(99) || got["unreadMore"] != true {
		t.Fatalf("unread-count %v", got)
	}
	h.exec(`UPDATE notifications SET read_at=now() WHERE ctid IN (SELECT ctid FROM notifications WHERE recipient_id=$1 LIMIT 80)`, alice)
	got = h.ok(alice, "GET", "/v1/notifications/unread-count")
	// (some of the 120 actors are fixtures the viewer cannot see, so the exact number varies a little)
	if c, _ := got["unreadCount"].(float64); c < 30 || c > 40 || got["unreadMore"] != false {
		t.Fatalf("unread-count %v", got)
	}

	story := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "hi", "audience": "public"}), 201, "").data["storyId"].(string)
	h.exec(`INSERT INTO story_views(story_id,viewer_id) SELECT $1,u.user_id FROM users u WHERE u.user_id<>$2 AND u.status='active' LIMIT 120`, story, alice)
	tray := items(h.ok(alice, "GET", "/v1/stories/tray"))[0]
	first := tray["stories"].([]any)[0].(map[string]any)
	if first["viewCount"] != float64(99) || first["viewCountMore"] != true {
		t.Fatalf("my story %v", first)
	}
}
