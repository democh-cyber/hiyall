package httpapi

import (
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/media"
)

// purgeWorld is a member (xan) with something in every table that references users, among other members
// (eli, cara, yui, dev) whose own data must survive the purge.
type purgeWorld struct {
	*acctHarness
	mem, chat *media.Memory
	xanMedia  []string // object keys of xan's photos
	eliKeys   []string
	eliMedia  string
	eliPost   string
	space1    string // xan's, with eli as a member: passes to eli
	space2    string // xan's, alone: deleted
	space3    string // eli's, xan a member
	openRep   string // yui against xan, holds an attachment
	heldBlob  string
	peerBlob  string // eli's attachment in a chat with xan
	xanBlob   string
	convoEli  string
	convoYui  string
}

func newPurgeWorld(t *testing.T) *purgeWorld {
	h := newAcctHarness(t)
	w := &purgeWorld{acctHarness: h, mem: media.NewMemory(), chat: media.NewMemory()}
	h.api.Media, h.api.ChatMedia = w.mem, w.chat
	for _, u := range []string{xan, eli, yui, cara} {
		h.policy(u, "commentsFrom", "everyone")
		h.policy(u, "messagesFrom", "everyone")
	}
	h.setAge(xan, 30)

	// Photos: xan's post, story and avatar and one pending upload; eli's own photo must stay.
	postPic := h.upload(w.mem, xan, "post", photo(t, 80, 60))
	storyPic := h.upload(w.mem, xan, "story", photo(t, 80, 60))
	avatar := h.upload(w.mem, xan, "avatar", photo(t, 80, 60))
	h.expect(h.setAvatar(xan, avatar), 200, "")
	h.expect(h.send(xan, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 1000}), 201, "")
	eliPic := h.upload(w.mem, eli, "post", photo(t, 80, 60))
	w.eliMedia = eliPic
	keysOf := func(owner string) []string {
		rows, err := h.db.Pool.Query(h.ctx, `SELECT upload_key,variants FROM media_assets WHERE owner_id=$1`, owner)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var keys []string
		for rows.Next() {
			var upload string
			var variants map[string]string
			if err = rows.Scan(&upload, &variants); err != nil {
				t.Fatal(err)
			}
			keys = append(keys, upload)
			for _, k := range variants {
				keys = append(keys, k)
			}
		}
		return keys
	}
	w.xanMedia, w.eliKeys = keysOf(xan), keysOf(eli)
	var err error

	// Pulse.
	xanPost := h.post(xan, "public", "xan post", postPic)
	w.eliPost = h.post(eli, "public", "eli post")
	h.expect(h.send(yui, "PUT", "/v1/posts/"+w.eliPost+"/reaction", map[string]string{"reaction": "heart"}), 200, "")
	h.expect(h.send(xan, "PUT", "/v1/posts/"+w.eliPost+"/reaction", map[string]string{"reaction": "fire"}), 200, "")
	h.expect(h.send(eli, "PUT", "/v1/posts/"+xanPost+"/reaction", map[string]string{"reaction": "heart"}), 200, "")
	yuiComment := h.expect(h.send(yui, "POST", "/v1/posts/"+w.eliPost+"/comments", map[string]string{"body": "yui says hi"}), 201, "").data["commentId"]
	_ = yuiComment
	xanComment := h.expect(h.send(xan, "POST", "/v1/posts/"+w.eliPost+"/comments", map[string]string{"body": "xan says hi"}), 201, "").data["commentId"].(string)
	h.expect(h.send(eli, "POST", "/v1/posts/"+w.eliPost+"/comments", map[string]any{"body": "eli replies to xan", "parentId": xanComment}), 201, "")
	h.expect(h.send(xan, "POST", "/v1/posts/"+w.eliPost+"/comments", map[string]string{"body": "xan, a leaf"}), 201, "")
	h.expect(h.send(eli, "POST", "/v1/posts/"+xanPost+"/comments", map[string]string{"body": "eli on xan's post"}), 201, "")
	h.expect(h.send(eli, "PUT", "/v1/posts/"+xanPost+"/save", nil), 200, "")
	h.expect(h.send(xan, "PUT", "/v1/posts/"+w.eliPost+"/save", nil), 200, "")
	h.expect(h.send(xan, "POST", "/v1/stories", map[string]any{"mediaId": storyPic, "audience": "public"}), 201, "")
	story := h.expect(h.send(xan, "POST", "/v1/stories", map[string]any{"body": "gm", "audience": "public"}), 201, "").data["storyId"].(string)
	eliStory := h.expect(h.send(eli, "POST", "/v1/stories", map[string]any{"body": "eli gm", "audience": "public"}), 201, "").data["storyId"].(string)
	h.ok(eli, "POST", "/v1/stories/"+story+"/view")
	h.ok(xan, "POST", "/v1/stories/"+eliStory+"/view")

	// People.
	h.ok(eli, "POST", "/v1/users/"+xan+"/follow")
	h.ok(xan, "POST", "/v1/users/"+eli+"/follow")
	h.befriend(xan, yui)
	h.befriend(xan, eli)
	h.ok(cara, "POST", "/v1/users/"+xan+"/block")
	h.ok(xan, "POST", "/v1/users/"+dev+"/block")
	h.ok(xan, "POST", "/v1/users/"+eli+"/mute")
	h.ok(yui, "POST", "/v1/users/"+xan+"/restrict")
	h.visit(eli, xan, "1 hour")
	h.visit(xan, eli, "1 hour")
	h.exec(`INSERT INTO profile_visit_counts(profile_id,slot,visitors) VALUES($1,0,1) ON CONFLICT DO NOTHING`, xan)
	h.north(xan, 0.003)
	h.exec(`INSERT INTO auth_identities(issuer,subject,user_id) VALUES('https://securetoken.google.com/test-project','sub-xan',$1)`, xan)
	h.exec(`INSERT INTO discovery_eligibility(user_id,age_group,confirmed_at,valid_until) VALUES($1,'adult',now(),now()+interval '1 day')`, xan)
	h.exec(`INSERT INTO notification_prefs(user_id,chat,social) VALUES($1,false,true)`, xan)

	// Spaces.
	w.space1 = makeSpace(h.socialHarness, xan, "community", "public", 10, nil)
	w.space2 = makeSpace(h.socialHarness, xan, "community", "public", 10, nil)
	w.space3 = makeSpace(h.socialHarness, eli, "community", "public", 10, nil)
	h.expect(h.send(eli, "PUT", "/v1/spaces/"+w.space1+"/membership", map[string]string{}), 200, "")
	h.expect(h.send(xan, "PUT", "/v1/spaces/"+w.space3+"/membership", map[string]string{}), 200, "")
	h.expect(h.send(xan, "POST", "/v1/spaces/"+w.space1+"/entries", map[string]string{"body": "welcome"}), 201, "")
	h.expect(h.send(xan, "POST", "/v1/spaces/"+w.space3+"/entries", map[string]string{"body": "hello from a member"}), 201, "")

	// Chat: devices and keys, a conversation with eli, one with yui, attachments, ciphertext still in transit.
	dx, de, dy := h.register(xan), h.register(eli), h.register(yui)
	h.exec(`INSERT INTO one_time_keys(device_id,key_id,public_key,signature) VALUES($1,'k1','pk','sig')`, dx.id)
	h.exec(`INSERT INTO fallback_keys(device_id,key_id,public_key,signature) VALUES($1,'f1','pk','sig')`, dx.id)
	h.exec(`INSERT INTO key_claims(claimer_id,device_id,one_time) VALUES($1,$2,true),($3,$4,true)`, xan, de.id, eli, dx.id)
	w.convoEli = h.expect(h.send(xan, "POST", "/v1/conversations", map[string]string{"userId": eli}), 200, "").data["conversationId"].(string)
	w.convoYui = h.expect(h.send(xan, "POST", "/v1/conversations", map[string]string{"userId": yui}), 200, "").data["conversationId"].(string)
	h.expect(h.send(xan, "POST", "/v1/conversations/"+w.convoEli+"/messages", message(dx, de)), 200, "")
	h.expect(h.send(eli, "POST", "/v1/conversations/"+w.convoEli+"/messages", message(de, dx)), 200, "")
	yuiMessage := message(dx, dy)
	h.expect(h.send(xan, "POST", "/v1/conversations/"+w.convoYui+"/messages", yuiMessage), 200, "")
	h.exec(`UPDATE devices SET push_provider='fcm',push_token='token-token-2' WHERE device_id=$1`, dx.id)
	blob := func(uploader, convo, message string) string {
		id := uuid.NewString()
		_ = w.chat.Put(h.ctx, "chat/"+id, []byte("ciphertext"), "application/octet-stream")
		h.exec(`INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,message_id,role,size_bytes,ct_sha256,state,object_key,uploaded_at,expires_at)
 VALUES($1,$2,$3,nullif($4,'')::uuid,'full',100,decode(repeat('ab',32),'hex'),'uploaded',$5,now(),now()+interval '30 days')`, id, uploader, convo, message, "chat/"+id)
		return id
	}
	var xanMsg, eliMsg string
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT message_id::text FROM messages WHERE conversation_id=$1 AND sender_id=$2 LIMIT 1),(SELECT message_id::text FROM messages WHERE conversation_id=$1 AND sender_id=$3 LIMIT 1)`, w.convoEli, xan, eli).Scan(&xanMsg, &eliMsg); err != nil {
		t.Fatal(err)
	}
	w.xanBlob = blob(xan, w.convoEli, xanMsg)
	w.peerBlob = blob(eli, w.convoEli, eliMsg)
	w.heldBlob = blob(xan, w.convoYui, yuiMessage["messageId"].(string))

	// Reports: yui's is open and holds the attachment; xan's about eli was resolved with an action against
	// eli; cara's about xan was resolved with a warning to xan; xan's open one stays too.
	w.openRep = h.expect(h.send(yui, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": xan, "reasonCode": "spam"}), 201, "").data["report"].(map[string]any)["reportId"].(string)
	h.exec(`UPDATE chat_blobs SET held_report_id=$1 WHERE blob_id=$2`, w.openRep, w.heldBlob)
	toEli := h.expect(h.send(xan, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": eli, "reasonCode": "spam", "description": "xan's words"}), 201, "").data["report"].(map[string]any)["reportId"].(string)
	h.expect(h.send(xan, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": cara, "reasonCode": "spam"}), 201, "")
	if err = h.db.ResolveReport(h.ctx, toEli, "op", "warn", "note"); err != nil {
		t.Fatal(err)
	}
	// cara's report is made directly: cara blocked xan, so the API does not take it.
	toXan := uuid.NewString()
	h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity) VALUES($1,$2,'user',$3,$3,'spam','normal')`, toXan, cara, xan)
	if err = h.db.ResolveReport(h.ctx, toXan, "op", "warn", "note"); err != nil {
		t.Fatal(err)
	}
	h.exec(`INSERT INTO outbox_events(event_id,aggregate_type,aggregate_id,aggregate_version,event_type) VALUES(gen_random_uuid(),'user',$1,99,'profile.updated')`, xan)
	return w
}

// purgeUntilDone drives the purge as the hourly job does, with the object cleanups between runs, and
// returns how many runs it took.
func (w *purgeWorld) purgeUntilDone(del *fakeDeleter) int {
	w.t.Helper()
	for run := 1; run <= 6; run++ {
		if _, err := w.db.PurgeDeletedAccounts(w.ctx, del, 10); err != nil {
			w.t.Fatal(err)
		}
		w.cleanup()
		if w.status(xan) == "deleted" {
			return run
		}
		// Attachments of the other member count towards their daily quota for two days.
		w.exec(`UPDATE chat_blobs SET created_at=created_at-interval '3 days' WHERE state='deleted'`)
	}
	w.t.Fatalf("not purged after 6 runs, status %s", w.status(xan))
	return 0
}

// cleanup is what the media cleanup and chat blob cleanup jobs do.
func (w *purgeWorld) cleanup() {
	w.t.Helper()
	keys, _, err := w.db.MediaGarbage(w.ctx, 5000)
	if err == nil {
		err = w.mem.Delete(w.ctx, keys...)
	}
	if err == nil {
		_, err = w.db.PurgeChatBlobs(w.ctx, w.chat, 5000)
	}
	if err != nil {
		w.t.Fatal(err)
	}
}

// Every foreign key that points at users, by "table.column". A column is either purged (no row may name the
// member afterwards) or retained, with the condition that tells a legitimately kept row from a leak.
var purgedColumns = []string{
	"profiles.user_id", "privacy_settings.user_id", "sessions.user_id", "blocks.blocker_id", "blocks.blocked_id", "friendships.user_low_id",
	"friendships.user_high_id", "friendships.requested_by", "follows.follower_id", "follows.followee_id", "discovery_eligibility.user_id",
	"notifications.actor_id", "notifications.recipient_id", "conversation_members.user_id", "conversation_members.peer_id",
	"user_controls.actor_id", "user_controls.target_id", "media_assets.owner_id", "posts.author_id", "post_reactions.user_id", "saved_posts.user_id",
	"stories.author_id", "story_views.viewer_id", "spaces.owner_id", "space_members.user_id", "space_entries.author_id", "onboarding.user_id",
	"user_locations.user_id", "member_ages.user_id", "profile_visits.profile_id", "profile_visits.visitor_id", "profile_visit_counts.profile_id",
	"key_claims.claimer_id", "notification_prefs.user_id",
}

// retainedColumns maps "table.column" to a SQL condition (over the table's own alias t and $1, the member)
// that holds for every row the purge may legitimately leave.
var retainedColumns = map[string]string{
	"reports.reporter_id":           `t.status='open' OR EXISTS(SELECT 1 FROM chat_blobs b WHERE b.held_report_id=t.report_id) OR (t.description IS NULL AND t.evidence IS NULL AND EXISTS(SELECT 1 FROM moderation_actions m WHERE m.report_id=t.report_id AND m.subject_id<>$1))`,
	"reports.subject_id":            `t.status='open' OR EXISTS(SELECT 1 FROM chat_blobs b WHERE b.held_report_id=t.report_id)`,
	"moderation_actions.subject_id": `EXISTS(SELECT 1 FROM reports r WHERE r.report_id=t.report_id AND (r.status='open' OR EXISTS(SELECT 1 FROM chat_blobs b WHERE b.held_report_id=r.report_id)))`,
	"conversations.user_low_id":     `EXISTS(SELECT 1 FROM chat_blobs b WHERE b.conversation_id=t.conversation_id AND b.held_report_id IS NOT NULL)`,
	"conversations.user_high_id":    `EXISTS(SELECT 1 FROM chat_blobs b WHERE b.conversation_id=t.conversation_id AND b.held_report_id IS NOT NULL)`,
	"conversations.created_by":      `EXISTS(SELECT 1 FROM chat_blobs b WHERE b.conversation_id=t.conversation_id AND b.held_report_id IS NOT NULL)`,
	"messages.sender_id":            `EXISTS(SELECT 1 FROM chat_blobs b WHERE b.message_id=t.message_id AND b.held_report_id IS NOT NULL)`,
	"chat_blobs.uploader_id":        `t.held_report_id IS NOT NULL`,
	"devices.user_id":               `t.display_name='' AND t.push_token IS NULL AND t.revoked_at IS NOT NULL AND EXISTS(SELECT 1 FROM messages m WHERE m.sender_device_id=t.device_id)`,
	"comments.author_id":            `t.body='' AND t.deleted_at IS NOT NULL`,
	// The provider identity row is kept for 24 hours after the purge (see store.PurgeDeletedIdentities).
	"auth_identities.user_id": `t.provider_deleted_at IS NOT NULL`,
}

func TestPurgeCoversEveryTableThatReferencesUsers(t *testing.T) {
	w := newPurgeWorld(t)
	h := w.acctHarness

	// 1. The foreign keys to users are exactly the columns this test knows about. A new table that references
	// users fails here until the purge handles it and it is listed in purgedColumns or retainedColumns.
	rows, err := h.db.Pool.Query(h.ctx, `SELECT kcu.table_name||'.'||kcu.column_name
 FROM information_schema.table_constraints tc
 JOIN information_schema.key_column_usage kcu ON kcu.constraint_name=tc.constraint_name AND kcu.table_schema=tc.table_schema
 JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name=tc.constraint_name AND ccu.table_schema=tc.table_schema
 WHERE tc.constraint_type='FOREIGN KEY' AND ccu.table_name='users' AND tc.table_schema='public'`)
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for rows.Next() {
		var c string
		if err = rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		found[c] = true
	}
	rows.Close()
	known := map[string]bool{}
	for _, c := range purgedColumns {
		known[c] = true
	}
	for c := range retainedColumns {
		if known[c] {
			t.Fatalf("%s is listed twice", c)
		}
		known[c] = true
	}
	var unhandled, stale []string
	for c := range found {
		if !known[c] {
			unhandled = append(unhandled, c)
		}
	}
	for c := range known {
		if !found[c] {
			stale = append(stale, c)
		}
	}
	sort.Strings(unhandled)
	sort.Strings(stale)
	if len(unhandled) > 0 {
		t.Fatalf("tables reference users but the account purge does not handle them: %v. Delete their rows in store.purgeContent (or retain them on purpose) and list the column in purgedColumns or retainedColumns", unhandled)
	}
	if len(stale) > 0 {
		t.Fatalf("purgedColumns/retainedColumns name foreign keys that no longer exist: %v", stale)
	}

	// 2. The world really has rows in every purged table (a fixture that stops populating one would make step 4 vacuous).
	populated := func(column string) int {
		table, col, _ := strings.Cut(column, ".")
		return h.count(fmt.Sprintf(`SELECT count(*) FROM %s WHERE %s=$1`, table, col), xan)
	}
	for _, c := range append(append([]string{}, purgedColumns...), "reports.reporter_id", "reports.subject_id", "moderation_actions.subject_id", "conversations.user_low_id", "conversations.user_high_id",
		"messages.sender_id", "chat_blobs.uploader_id", "devices.user_id", "comments.author_id", "auth_identities.user_id") {
		if populated(c) == 0 {
			t.Fatalf("the test world has no row in %s", c)
		}
	}
	before := map[string]int{}
	for _, q := range []string{"posts", "post_reactions", "comments"} {
		before[q] = h.count(`SELECT count(*) FROM ` + q)
	}
	countersOf := func() (int, int) {
		got := h.ok(yui, "GET", "/v1/posts/"+w.eliPost)
		return int(got["reactionCount"].(float64)), int(got["commentCount"].(float64))
	}
	if r, c := countersOf(); r != 2 || c != 4 {
		t.Fatalf("eli's post counters before: %d reactions, %d comments", r, c)
	}

	// 3. Delete, wait out the grace period, purge.
	h.scheduled(xan, "xan")
	del := &fakeDeleter{}
	if _, err = h.db.PurgeDeletedAccounts(h.ctx, del, 10); err != nil {
		t.Fatal(err)
	}
	if h.status(xan) != "pending_deletion" || len(del.calls) != 0 {
		t.Fatal("the purge started inside the grace period")
	}
	h.expire(xan)
	runs := w.purgeUntilDone(del)
	if runs < 2 {
		t.Fatalf("finished in %d run: the purge cannot finish before the objects were removed", runs)
	}
	if len(del.calls) != 1 || del.calls[0] != "https://securetoken.google.com/test-project|sub-xan" {
		t.Fatalf("identity deletions %v", del.calls)
	}
	if h.count(`SELECT count(*) FROM deleted_users WHERE user_id=$1`, xan) != 1 {
		t.Fatal("no tombstone")
	}

	// 4. Nothing names the member any more, except retained rows that meet their condition.
	for _, c := range purgedColumns {
		if n := populated(c); n != 0 {
			t.Errorf("%s: %d rows still name the deleted member", c, n)
		}
	}
	for c, allowed := range retainedColumns {
		table, col, _ := strings.Cut(c, ".")
		if n := h.count(fmt.Sprintf(`SELECT count(*) FROM %s t WHERE t.%s=$1 AND NOT (%s)`, table, col, allowed), xan); n != 0 {
			t.Errorf("%s: %d rows kept that are not retained on purpose", c, n)
		}
	}

	// The operator queue and the reporter's own list still work for a report about a member who is gone.
	queue, err := h.db.ReportQueue(h.ctx, 50)
	if err != nil {
		t.Fatal(err)
	}
	queued := false
	for _, q := range queue {
		if q.ReportID == w.openRep {
			queued = q.SubjectName == "" && len(q.Blobs) == 1
		}
	}
	if !queued {
		t.Fatalf("the open report is not in the queue with its held evidence: %+v", queue)
	}
	mine := items(h.ok(yui, "GET", "/v1/me/reports"))
	if len(mine) == 0 || mine[0]["subject"].(map[string]any)["username"] != "" {
		t.Fatalf("reporter's list: %v", mine)
	}

	// 5. What is retained is what the retention table says.
	if h.count(`SELECT count(*) FROM reports WHERE report_id=$1 AND status='open'`, w.openRep) != 1 {
		t.Fatal("the open report against the member was dropped")
	}
	if h.count(`SELECT count(*) FROM chat_blobs WHERE blob_id=$1 AND held_report_id=$2 AND state<>'deleted'`, w.heldBlob, w.openRep) != 1 || !w.chat.Has("chat/"+w.heldBlob) {
		t.Fatal("held evidence was not kept")
	}
	if h.count(`SELECT count(*) FROM conversations WHERE conversation_id=$1`, w.convoYui) != 1 || h.count(`SELECT count(*) FROM conversations WHERE conversation_id=$1`, w.convoEli) != 0 {
		t.Fatal("conversation rows: only the one holding evidence stays")
	}
	if h.count(`SELECT count(*) FROM message_envelopes`) != 0 {
		t.Fatal("ciphertext left behind")
	}
	if h.count(`SELECT count(*) FROM reports WHERE reporter_id=$1 AND description IS NOT NULL`, xan) != 0 {
		t.Fatal("the deleted reporter's words are still on a resolved report")
	}
	if h.count(`SELECT count(*) FROM reports WHERE (reporter_id=$1 OR subject_id=$1) AND status<>'open'`, xan) != 1 {
		t.Fatal("exactly the report with an action against someone else stays among the resolved ones")
	}
	for _, key := range w.xanMedia {
		if w.mem.Has(key) {
			t.Fatalf("object %s was not removed", key)
		}
	}
	if !w.chat.Has("chat/"+w.heldBlob) || w.chat.Has("chat/"+w.xanBlob) || w.chat.Has("chat/"+w.peerBlob) {
		t.Fatal("chat objects: only the held one stays")
	}
	if h.count(`SELECT count(*) FROM media_assets WHERE media_id=$1 AND status='ready'`, w.eliMedia) != 1 {
		t.Fatal("another member's photo was touched")
	}
	left := w.mem.Keys()
	if len(left) != 2 {
		t.Fatalf("objects left in the photo bucket: %v, want only eli's two variants", left)
	}
	for _, k := range left {
		if !contains(w.eliKeys, k) {
			t.Fatalf("object %s is not eli's", k)
		}
	}

	// 6. Other members' data is intact and consistent: their counters lost xan's reaction and comments.
	if r, c := countersOf(); r != 1 || c != 2 {
		t.Fatalf("eli's post counters after: %d reactions, %d comments", r, c)
	}
	if h.count(`SELECT count(*) FROM posts WHERE author_id=$1 AND deleted_at IS NULL`, eli) != 1 || h.count(`SELECT count(*) FROM comments WHERE author_id=$1`, eli) != 1 {
		t.Fatal("eli's content changed")
	}
	// xan's comment that eli replied to stays as an empty placeholder; the leaf is gone.
	if h.count(`SELECT count(*) FROM comments WHERE author_id=$1`, xan) != 1 {
		t.Fatal("expected one placeholder comment")
	}
	var owner string
	var members int
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT owner_id::text,member_count FROM spaces WHERE space_id=$1`, w.space1).Scan(&owner, &members); err != nil || owner != eli || members != 1 {
		t.Fatalf("space handed over: owner %s members %d (%v)", owner, members, err)
	}
	if h.count(`SELECT count(*) FROM spaces WHERE space_id=$1`, w.space2) != 0 {
		t.Fatal("a space with nobody else in it should be deleted")
	}
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT member_count FROM spaces WHERE space_id=$1`, w.space3).Scan(&members); err != nil || members != 1 {
		t.Fatalf("eli's space member count %d (%v)", members, err)
	}
	if st := h.stats(eli); st.Followers != 0 || st.Following != 0 || st.Friends != 0 {
		t.Fatalf("eli's counts %+v", st)
	}

	// 7. Signing in with the same token is refused, until the identity row ages out; then it is gone.
	if _, err = h.db.ResolveOIDC(h.ctx, "https://securetoken.google.com/test-project", "sub-xan", "fb:sub-xan:"+fmt.Sprint(time.Now().Unix()), time.Now().Add(time.Hour)); err == nil {
		t.Fatal("a deleted account signed in")
	}
	if n, _ := h.db.PurgeDeletedIdentities(h.ctx, 24*time.Hour, 100); n != 0 {
		t.Fatal("identity row removed too early")
	}
	h.exec(`UPDATE deleted_users SET deleted_at=now()-interval '25 hours'`)
	if n, err := h.db.PurgeDeletedIdentities(h.ctx, 24*time.Hour, 100); err != nil || n != 1 {
		t.Fatalf("identity purge %d %v", n, err)
	}
	if h.count(`SELECT count(*) FROM auth_identities WHERE user_id=$1`, xan) != 0 {
		t.Fatal("identity row left")
	}
	// The row that remains is no personal data: id, status.
	if h.status(xan) != "deleted" {
		t.Fatal("status")
	}
}

func TestPurgeIsIdempotentResumableAndNeverTouchesLiveAccounts(t *testing.T) {
	w := newPurgeWorld(t)
	h := w.acctHarness

	// An active member and one who cancelled are never purged, however many times the job runs.
	h.scheduled(eli, "eli")
	h.ok(eli, "DELETE", "/v1/me/deletion")
	h.scheduled(cara, "cara")
	h.expire(cara)
	h.exec(`UPDATE users SET status='active',deletion_due_at=NULL,deletion_scheduled_at=NULL WHERE user_id=$1`, cara) // cancelled on the last day
	del := &fakeDeleter{}
	for range 3 {
		if _, err := h.db.PurgeDeletedAccounts(h.ctx, del, 10); err != nil {
			t.Fatal(err)
		}
	}
	if len(del.calls) != 0 || h.count(`SELECT count(*) FROM profiles WHERE user_id IN ($1,$2,$3)`, eli, cara, yui) != 3 {
		t.Fatal("a live account was purged")
	}

	h.scheduled(xan, "xan")
	// Inside the grace period: untouched.
	if _, err := h.db.PurgeDeletedAccounts(h.ctx, del, 10); err != nil || h.count(`SELECT count(*) FROM posts WHERE author_id=$1`, xan) == 0 {
		t.Fatalf("purged early (%v)", err)
	}
	h.expire(xan)

	// The identity provider is down: content is gone, the account is still 'deleting', the next run retries.
	del.fail = true
	if _, err := h.db.PurgeDeletedAccounts(h.ctx, del, 10); err == nil {
		t.Fatal("a provider failure was swallowed")
	}
	if h.status(xan) != "deleting" || h.count(`SELECT count(*) FROM profiles WHERE user_id=$1`, xan) != 0 || h.count(`SELECT count(*) FROM posts WHERE author_id=$1`, xan) != 0 {
		t.Fatal("content should already be purged while the identity step waits")
	}
	if h.count(`SELECT count(*) FROM auth_identities WHERE user_id=$1 AND provider_deleted_at IS NULL`, xan) != 1 {
		t.Fatal("the identity must stay marked as not yet deleted")
	}
	// A sign-in in this state is refused (nothing to resume into), and a cancel is impossible.
	h.expect(h.call(xan, "GET", "/v1/me/deletion"), 401, "UNAUTHENTICATED")

	// Simulated crash halfway through a content purge: a transaction that deleted some rows and rolled
	// back leaves the same state as no run at all; running the job again completes everything.
	del.fail = false
	runs := w.purgeUntilDone(del)
	if len(del.calls) != 1 {
		t.Fatalf("provider called %d times", len(del.calls))
	}
	// Running it again does nothing, and nothing errors.
	for range 2 {
		if n, err := h.db.PurgeDeletedAccounts(h.ctx, del, 10); err != nil || n != 0 {
			t.Fatalf("purge of a finished account: %d %v", n, err)
		}
	}
	if len(del.calls) != 1 || runs < 2 {
		t.Fatalf("calls %v runs %d", del.calls, runs)
	}
	// Other members are still whole.
	if h.count(`SELECT count(*) FROM profiles WHERE user_id IN ($1,$2,$3)`, eli, cara, yui) != 3 {
		t.Fatal("another member lost their profile")
	}
}

// A purge that is interrupted after its first statements (the process dies, the connection drops) rolls
// back as a whole, and the next run does everything again.
func TestPurgeContentRollsBackAsOne(t *testing.T) {
	w := newPurgeWorld(t)
	h := w.acctHarness
	h.scheduled(xan, "xan")
	h.expire(xan)
	// A trigger makes the last statement of the content purge fail once.
	h.exec(`CREATE OR REPLACE FUNCTION fail_purge() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated crash'; END $$`)
	h.exec(`CREATE TRIGGER fail_purge BEFORE DELETE ON member_ages FOR EACH ROW EXECUTE FUNCTION fail_purge()`)
	defer h.exec(`DROP TRIGGER IF EXISTS fail_purge ON member_ages`)
	if _, err := h.db.PurgeDeletedAccounts(h.ctx, &fakeDeleter{}, 10); err == nil {
		t.Fatal("expected the simulated crash")
	}
	if h.status(xan) != "pending_deletion" || h.count(`SELECT count(*) FROM posts WHERE author_id=$1`, xan) == 0 || h.count(`SELECT count(*) FROM sessions WHERE user_id=$1`, xan) == 0 {
		t.Fatal("a failed content purge left a partial result")
	}
	h.exec(`DROP TRIGGER fail_purge ON member_ages`)
	w.purgeUntilDone(&fakeDeleter{})
}
