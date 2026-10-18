package httpapi

import (
	"os"
	"testing"
	"time"

	"hiyall/services/api/internal/dbtest"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/ratelimit"
	"hiyall/services/api/internal/store"
)

// Production runs the API as the least-privilege role hiyall_api (database/roles). Everything below runs with a
// connection that did SET ROLE hiyall_api, so a table, view or column the role lacks fails here, as it did in
// production when only the grants were wrong (the weekly counter reconcile read a view, the media tombstone purge
// read content_cases). The world and the aged rows are built as the test user; the requests, the jobs and the
// account purge run as the role. Any "permission denied" the database raised fails the test, including one a
// handler swallowed (the tracer sees every statement).
func TestRequestsAndJobsRunOnTheRestrictedAPIRole(t *testing.T) {
	w := newPurgeWorld(t)
	h := w.acctHarness
	su := h.db
	dbtest.ApplyRoles(t, h.ctx, su.Pool)
	denials := &dbtest.Denials{}
	rdb, err := store.New(h.ctx, dbtest.RoleDSN(t, os.Getenv("TEST_DATABASE_URL"), "hiyall_api"), store.WithQueryTracer(denials))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rdb.Pool.Close)
	var who string
	if err = rdb.Pool.QueryRow(h.ctx, `SELECT current_user`).Scan(&who); err != nil || who != "hiyall_api" {
		t.Fatalf("connected as %q (%v), want hiyall_api", who, err)
	}
	if problems, err := rdb.RoleProblems(h.ctx); err != nil || len(problems) != 0 {
		t.Fatalf("hiyall_api role problems: %v %v", problems, err)
	}
	if problems, err := rdb.GrantProblems(h.ctx, ""); err != nil || len(problems) != 0 {
		t.Fatalf("hiyall_api grant problems: %v %v", problems, err)
	}
	// From here the API and the harness's own queries use the role; operator-level fixtures go through su.
	h.db, h.api.Store = rdb, rdb
	t.Cleanup(func() { h.db, h.api.Store = su, su })
	t.Cleanup(func() { denials.Check(t) })

	fine := func(r reply, what string) reply {
		t.Helper()
		if r.status >= 500 {
			t.Fatalf("%s: %d %s %v (denied: %v)", what, r.status, r.code, r.data, denials.Got())
		}
		return r
	}

	// ---- Sign-in session resolution (first sign-in, repeat, the fast path), without the Firebase verifier.
	exp := time.Now().Add(time.Hour)
	first, err := rdb.ResolveOIDC(h.ctx, "https://securetoken.google.com/test-project", "sub-role-test", "fb:sub-role-test:1", exp)
	if err != nil || first.UserID == "" {
		t.Fatalf("first sign-in: %+v %v", first, err)
	}
	if again, err := rdb.ResolveOIDC(h.ctx, "https://securetoken.google.com/test-project", "sub-role-test", "fb:sub-role-test:1", exp.Add(time.Hour)); err != nil || again.SessionID != first.SessionID {
		t.Fatalf("repeat sign-in: %+v %v", again, err)
	}
	if _, err = rdb.RevokeOtherSessions(h.ctx, first); err != nil {
		t.Fatalf("revoke others: %v", err)
	}

	// ---- Profile, privacy, people.
	fine(h.send(eli, "GET", "/v1/me/profile", nil), "own profile")
	fine(h.send(eli, "GET", "/v1/users/"+xan+"/profile", nil), "view profile (writes a visit)")
	fine(h.send(eli, "GET", "/v1/me/privacy", nil), "privacy")
	h.api.search.reset(eli)
	fine(h.send(eli, "POST", "/v1/discovery/search", map[string]any{}), "search")
	fine(h.send(eli, "GET", "/v1/me/visitors", nil), "visitors")
	fine(h.send(eli, "GET", "/v1/me/followers", nil), "followers")
	fine(h.send(eli, "GET", "/v1/me/friends", nil), "friends")

	// ---- Follow, unfollow, friend request and its answer, block.
	fine(h.send(cara, "POST", "/v1/users/"+yui+"/follow", nil), "follow")
	fine(h.send(cara, "DELETE", "/v1/users/"+yui+"/follow", nil), "unfollow")
	fine(h.send(dev, "POST", "/v1/users/"+cara+"/friend-requests", nil), "friend request")
	for _, id := range ids(h.ok(cara, "GET", "/v1/me/friend-requests")) {
		fine(h.send(cara, "POST", "/v1/friend-requests/"+id+"/accept", nil), "accept friend request")
	}
	fine(h.send(dev, "DELETE", "/v1/users/"+cara+"/friendship", nil), "unfriend")
	fine(h.send(dev, "POST", "/v1/users/"+yui+"/block", nil), "block")
	fine(h.send(dev, "DELETE", "/v1/users/"+yui+"/block", nil), "unblock")
	fine(h.send(cara, "GET", "/v1/notifications", nil), "notifications")
	fine(h.send(cara, "GET", "/v1/notifications/unread-count", nil), "unread count")
	fine(h.send(cara, "POST", "/v1/notifications/read-all", nil), "read all")

	// ---- Posts, reactions, comments, saves, feed, stories.
	post := h.post(eli, "public", "written on the restricted role")
	fine(h.send(yui, "PUT", "/v1/posts/"+post+"/reaction", map[string]string{"reaction": "heart"}), "react")
	comment := fine(h.send(yui, "POST", "/v1/posts/"+post+"/comments", map[string]string{"body": "a comment"}), "comment").data["commentId"]
	fine(h.send(yui, "PUT", "/v1/posts/"+post+"/save", nil), "save")
	fine(h.send(yui, "GET", "/v1/posts/"+post+"/comments", nil), "comments")
	fine(h.send(yui, "GET", "/v1/feed?mode=latest", nil), "feed")
	fine(h.send(eli, "POST", "/v1/stories", map[string]any{"body": "gm", "audience": "public"}), "story")
	if id, ok := comment.(string); ok {
		fine(h.send(yui, "DELETE", "/v1/comments/"+id, nil), "delete comment")
	}
	gone := h.post(eli, "public", "to be deleted")
	fine(h.send(eli, "DELETE", "/v1/posts/"+gone, nil), "delete post")

	// ---- Nearby.
	fine(h.send(eli, "PUT", "/v1/me/nearby", nil), "nearby on")
	h.api.locations.reset(eli)
	fine(h.send(eli, "PUT", "/v1/me/location", putLocation(12.97, 77.59)), "location")
	h.api.search.reset(eli)
	fine(h.send(eli, "POST", "/v1/discover/nearby", map[string]any{}), "nearby")

	// ---- Chat: register devices, open a conversation, send, list, read.
	dc, dy := h.register(cara), h.register(yui)
	convo := fine(h.send(cara, "POST", "/v1/conversations", map[string]string{"userId": yui}), "open conversation").data["conversationId"]
	if id, ok := convo.(string); ok {
		fine(h.send(cara, "POST", "/v1/conversations/"+id+"/messages", message(dc, dy)), "send message")
		fine(h.send(yui, "GET", "/v1/conversations/"+id, nil), "conversation")
		fine(h.send(yui, "POST", "/v1/conversations/"+id+"/read", map[string]any{}), "read")
	}
	fine(h.send(yui, "GET", "/v1/conversations", nil), "conversations")
	fine(h.send(yui, "GET", "/v1/conversations/unread", nil), "unread")

	// ---- Reports, sessions, export, deletion status.
	fine(h.send(eli, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": dev, "reasonCode": "spam"}), "report")
	fine(h.send(eli, "GET", "/v1/auth/sessions", nil), "sessions")
	fine(h.send(eli, "GET", "/v1/me/deletion", nil), "deletion status")

	// ---- A scanner match opens a content case (INSERT only) and suspends the uploader.
	pic := photo(t, 90, 70)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Match}}
	id, _ := h.beginUpload(w.mem, dev, "post", pic)
	h.expect(h.call(dev, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")
	h.api.Scanner = nil

	// ---- Jobs. Zero retention so every row the world made is due; each job twice, the second finds nothing.
	// Released evidence hold, released and overdue as the console would leave it (operator-level fixture).
	if _, err = su.Pool.Exec(h.ctx, `UPDATE content_cases SET released_at=now(),released_by='op',release_reason='test',hold_until=now()-interval '1 day',status='cleared' WHERE media_id=$1`, id); err != nil {
		t.Fatal(err)
	}
	h.exec(`UPDATE notifications SET created_at=now()-interval '200 days'`)
	h.exec(`UPDATE posts SET deleted_at=now()-interval '40 days' WHERE post_id=$1`, gone)
	h.exec(`UPDATE reports SET status='dismissed',resolved_at=now()-interval '200 days' WHERE report_id=$1`, w.openRep)
	h.exec(`UPDATE media_assets SET status='deleted',variants=NULL,deleted_at=now()-interval '40 days' WHERE owner_id=$1 AND status='pending'`, xan)
	ctx := h.ctx
	type run struct {
		name string
		fn   func() (int64, error)
	}
	jobs := []run{
		{"notifications", func() (int64, error) { return rdb.PurgeNotifications(ctx, 0) }},
		{"closed reports", func() (int64, error) { return rdb.PurgeClosedReports(ctx, 0) }},
		{"blank deleted", func() (int64, error) { return rdb.BlankDeletedContent(ctx, 0) }},
		{"deleted content", func() (int64, error) { return rdb.PurgeDeletedContent(ctx, 0) }},
		{"message metadata", func() (int64, error) { return rdb.PurgeMessageMetadata(ctx, 0) }},
		{"media tombstones", func() (int64, error) { return rdb.PurgeMediaTombstones(ctx, 0) }},
		{"social reconcile", func() (int64, error) { return rdb.ReconcileSocialCounters(ctx, 0) }},
		{"post reconcile", func() (int64, error) { return rdb.ReconcilePostCounters(ctx, 0) }},
		{"space reconcile", func() (int64, error) { return rdb.ReconcileSpaceMemberCounts(ctx, 0) }},
		{"envelopes", func() (int64, error) { return rdb.ExpireEnvelopes(ctx, 0, 0, 5000) }},
		{"stale devices", func() (int64, error) { return rdb.RevokeStaleDevices(ctx, store.StaleDeviceAfter, 500) }},
		{"backlogged devices", func() (int64, error) {
			return rdb.RevokeBackloggedDevices(ctx, domain.Free().ChatBacklogPerDevice, store.BackloggedDeviceIdle, 500)
		}},
		{"sessions", func() (int64, error) { return rdb.PurgeSessions(ctx, 0, 5000) }},
		{"key claims", func() (int64, error) { return rdb.PurgeKeyClaims(ctx, 5000) }},
		{"stories", func() (int64, error) { return rdb.PurgeStories(ctx, 5000) }},
		{"locations", func() (int64, error) { return rdb.PurgeLocations(ctx, 0, 5000) }},
		{"daily counts", func() (int64, error) { return rdb.PurgeDailyCounts(ctx, 0, 5000) }},
		{"age refusals", func() (int64, error) { return rdb.PurgeAgeRefusals(ctx, 0, 5000) }},
		{"idempotency keys", func() (int64, error) { return rdb.PurgeIdempotencyKeys(ctx, 0, 5000) }},
		{"media cleanup", func() (int64, error) { return rdb.PurgeMedia(ctx, w.mem, 5000) }},
		{"released holds", func() (int64, error) { return rdb.PurgeReleasedHolds(ctx, w.mem, 50) }},
		{"chat blobs", func() (int64, error) { return rdb.PurgeChatBlobs(ctx, w.chat, 5000) }},
		{"chat blob tombstones", func() (int64, error) { return rdb.PurgeChatBlobTombstones(ctx, 5000) }},
		{"hidden chat close", func() (int64, error) { return rdb.CloseExpiredHiddenChats(ctx, domain.HiddenChatRetention, 5000) }},
		{"group invite expiry", func() (int64, error) { return rdb.ExpireGroupInvites(ctx, 1000) }},
		{"group event purge", func() (int64, error) { return rdb.PurgeGroupEvents(ctx, 5000) }},
		{"deleted identities", func() (int64, error) { return rdb.PurgeDeletedIdentities(ctx, 0, 5000) }},
		{"rate limits", func() (int64, error) { return ratelimit.Purge(ctx, rdb.Pool, 5000) }},
	}
	for pass := 0; pass < 2; pass++ {
		for _, j := range jobs {
			if _, err := j.fn(); err != nil {
				t.Errorf("job %q (pass %d): %v", j.name, pass+1, err)
			}
		}
	}

	// ---- The account purge, end to end, as the role.
	h.scheduled(xan, "xan")
	h.expire(xan)
	del := &fakeDeleter{}
	w.purgeUntilDone(del)
	if h.status(xan) != "deleted" {
		t.Fatalf("xan is %s after the purge", h.status(xan))
	}
	// Every statement the purge, the jobs and the requests ran was allowed; the deferred Check lists any that were not.
}
