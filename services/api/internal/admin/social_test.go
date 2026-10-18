package admin

import (
	"context"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

func (e *env) noticeBody(extra map[string]any) map[string]any {
	body := map[string]any{"category": "safety", "title": "Staying safe", "body": "Never share your **password**.\n\nRead [our tips](https://hiyall.app/safety).",
		"audience": "all", "locale": "", "pinned": true, "reason": "publishing the safety reminder"}
	for k, v := range extra {
		body[k] = v
	}
	return body
}

func TestNoticesAreAdminOnlyValidatedAndAudited(t *testing.T) {
	e := newEnv(t)
	admin, moderator, viewer := e.session(e.operator(RoleAdmin)), e.session(e.operator(RoleModerator)), e.session(e.operator(RoleViewer))

	// Only an administrator publishes; a viewer and a moderator may not, and nothing is written for them.
	for _, s := range []sess{viewer, moderator} {
		if r := e.post(s, "/admin/v1/notices", e.noticeBody(nil)); r.status != 403 {
			t.Fatalf("a non-administrator published: %d %s", r.status, r.raw)
		}
	}
	// A request without the CSRF token is refused too.
	if r := e.do(request{method: "POST", path: "/admin/v1/notices", body: e.noticeBody(nil), s: &admin, noCSRF: true}); r.status != 403 {
		t.Fatalf("no CSRF token: %d", r.status)
	}
	// Markup that could be anything but the three allowed bits is refused with 422 and nothing stored.
	for name, body := range map[string]map[string]any{
		"html":          e.noticeBody(map[string]any{"body": "hi <script>alert(1)</script>"}),
		"an http link":  e.noticeBody(map[string]any{"body": "see [this](http://example.com)"}),
		"a js link":     e.noticeBody(map[string]any{"body": "see [this](javascript:alert(1))"}),
		"an image":      e.noticeBody(map[string]any{"body": "![x](https://example.com/a.png)"}),
		"open bold":     e.noticeBody(map[string]any{"body": "a **bold"}),
		"no reason":     e.noticeBody(map[string]any{"reason": "short"}),
		"a bad context": e.noticeBody(map[string]any{"category": "ads"}),
		"expired":       e.noticeBody(map[string]any{"expiresAt": time.Now().Add(-time.Hour)}),
		"long title":    e.noticeBody(map[string]any{"title": strings.Repeat("t", 121)}),
		"a bad locale":  e.noticeBody(map[string]any{"locale": "EN us"}),
	} {
		if r := e.post(admin, "/admin/v1/notices", body); r.status != 422 {
			t.Errorf("%s: %d %s", name, r.status, r.raw)
		}
	}
	title := "Notice " + randomName("n")
	r := e.post(admin, "/admin/v1/notices", e.noticeBody(map[string]any{"title": title, "audience": "minors"}))
	if r.status != 201 {
		t.Fatalf("publish: %d %s", r.status, r.raw)
	}
	var n NoticeRecord
	r.data(&n)
	if n.Status != "live" || n.Audience != "minors" || !n.Pinned || n.NoticeID == "" {
		t.Fatalf("notice %+v", n)
	}
	// The audit entry is written with the change.
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='notice_publish' AND target_id=$1 AND reason<>''`, n.NoticeID) != 1 {
		t.Fatal("publish was not audited")
	}
	// Members read it by their age band: the audience is minors.
	minor, adult := e.member(true), e.member(false)
	got := func(user string) int {
		items, err := e.db.ListNotices(e.ctx, user, "", nil, "00000000-0000-0000-0000-000000000000", 50)
		if err != nil {
			t.Fatal(err)
		}
		c := 0
		for _, it := range items {
			if it.NoticeID == n.NoticeID {
				c++
			}
		}
		return c
	}
	if got(minor) != 1 || got(adult) != 0 {
		t.Fatalf("audience: minor sees %d, adult sees %d", got(minor), got(adult))
	}
	// Edit (a reason again), then unpublish.
	if r = e.do(request{method: "PUT", path: "/admin/v1/notices/" + n.NoticeID, body: e.noticeBody(map[string]any{"title": title + " v2", "audience": "all", "reason": "fixing the title"}), s: &admin}); r.status != 200 {
		t.Fatalf("edit: %d %s", r.status, r.raw)
	}
	if got(adult) != 1 {
		t.Fatal("the edit to everyone did not reach adults")
	}
	if r = e.post(admin, "/admin/v1/notices/"+n.NoticeID+"/unpublish", map[string]string{"reason": "it is out of date"}); r.status != 200 {
		t.Fatalf("unpublish: %d %s", r.status, r.raw)
	}
	r.data(&n)
	if n.Status != "unpublished" || got(adult) != 0 || got(minor) != 0 {
		t.Fatalf("after unpublish: %+v", n)
	}
	// An unpublished notice cannot be edited or unpublished again.
	if r = e.do(request{method: "PUT", path: "/admin/v1/notices/" + n.NoticeID, body: e.noticeBody(nil), s: &admin}); r.status != 404 {
		t.Fatalf("edit after unpublish: %d", r.status)
	}
	for _, action := range []string{"notice_publish", "notice_edit", "notice_unpublish"} {
		if e.count(`SELECT count(*) FROM operator_audit WHERE action=$1 AND target_id=$2`, action, n.NoticeID) != 1 {
			t.Errorf("%s not audited exactly once", action)
		}
	}
	// A viewer reads the list.
	if r = e.get(viewer, "/admin/v1/notices?status=unpublished&limit=5"); r.status != 200 || !strings.Contains(string(r.raw), n.NoticeID) {
		t.Fatalf("list: %d %s", r.status, r.raw)
	}
	if r = e.get(viewer, "/admin/v1/notices?status=weird"); r.status != 422 {
		t.Fatalf("bad status: %d", r.status)
	}
}

func TestSupportInboxRolesRepliesAndAudit(t *testing.T) {
	e := newEnv(t)
	admin, moderator, viewer := e.session(e.operator(RoleAdmin)), e.session(e.operator(RoleModerator)), e.session(e.operator(RoleViewer))
	_ = admin
	free := domain.Free()
	user := e.member(true) // minors may write to support
	thread, err := e.db.CreateSupportThread(e.ctx, user, "safety", "Someone is bothering me", free)
	if err != nil {
		t.Fatal(err)
	}
	// One open thread per category.
	if _, err = e.db.CreateSupportThread(e.ctx, user, "safety", "again", free); err != domain.ErrSupportThreadOpen {
		t.Fatalf("second open thread: %v", err)
	}
	// The inbox lists without text; reading the thread is audited first.
	r := e.get(viewer, "/admin/v1/support/threads?waiting=true&limit=50")
	if r.status != 200 || strings.Contains(string(r.raw), "bothering") || !strings.Contains(string(r.raw), thread) {
		t.Fatalf("inbox: %d %s", r.status, r.raw)
	}
	r = e.get(viewer, "/admin/v1/support/threads/"+thread)
	if r.status != 200 || !strings.Contains(string(r.raw), "Someone is bothering me") || !strings.Contains(string(r.raw), `"ageBand":"minor"`) {
		t.Fatalf("thread: %d %s", r.status, r.raw)
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='support_thread_view' AND target_id=$1`, thread) != 1 {
		t.Fatal("the view was not audited")
	}
	// A viewer is read-only.
	for _, path := range []string{"reply", "close", "reopen", "assign"} {
		if r = e.post(viewer, "/admin/v1/support/threads/"+thread+"/"+path, map[string]any{"body": "hello there"}); r.status != 403 {
			t.Errorf("viewer %s: %d", path, r.status)
		}
	}
	// A moderator replies: a staff message, the thread is now waiting for the member, assigned, audited without its text.
	if r = e.post(moderator, "/admin/v1/support/threads/"+thread+"/reply", map[string]any{"body": "We are looking into it."}); r.status != 201 {
		t.Fatalf("reply: %d %s", r.status, r.raw)
	}
	if e.count(`SELECT count(*) FROM support_threads WHERE thread_id=$1 AND last_author='staff' AND assigned_to IS NOT NULL`, thread) != 1 {
		t.Fatal("thread state after the reply")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='support_reply' AND target_id=$1 AND detail::text NOT LIKE '%looking%'`, thread) != 1 {
		t.Fatal("reply not audited, or its text is in the audit log")
	}
	if r = e.post(moderator, "/admin/v1/support/threads/"+thread+"/reply", map[string]any{"body": ""}); r.status != 422 {
		t.Fatalf("empty reply: %d", r.status)
	}
	// The member sees it as unread, and exactly one node claims the push.
	if n, _ := e.db.SupportUnread(e.ctx, user); n != 1 {
		t.Fatalf("unread %d", n)
	}
	users, err := e.db.ClaimSupportPushes(e.ctx, 100)
	if err != nil || !contains(users, user) {
		t.Fatalf("claim: %v %v", users, err)
	}
	if again, _ := e.db.ClaimSupportPushes(e.ctx, 100); contains(again, user) {
		t.Fatal("a staff message was pushed twice")
	}
	// Close, refuse a reply, reopen; reopening beside another open thread of the category is refused.
	if r = e.post(moderator, "/admin/v1/support/threads/"+thread+"/close", map[string]any{}); r.status != 200 {
		t.Fatalf("close: %d %s", r.status, r.raw)
	}
	if r = e.post(moderator, "/admin/v1/support/threads/"+thread+"/reply", map[string]any{"body": "one more thing"}); r.status != 409 || r.code() != "SUPPORT_THREAD_CLOSED" {
		t.Fatalf("reply to a closed thread: %d %s", r.status, r.raw)
	}
	other, err := e.db.CreateSupportThread(e.ctx, user, "safety", "new problem", free)
	if err != nil {
		t.Fatal(err)
	}
	if r = e.post(moderator, "/admin/v1/support/threads/"+thread+"/reopen", map[string]any{}); r.status != 409 || r.code() != "SUPPORT_THREAD_OPEN" {
		t.Fatalf("reopen beside another: %d %s", r.status, r.raw)
	}
	if r = e.post(moderator, "/admin/v1/support/threads/"+other+"/assign", map[string]any{"assignTo": "me"}); r.status != 200 || !strings.Contains(string(r.raw), `"assignedToMe":true`) {
		t.Fatalf("assign: %d %s", r.status, r.raw)
	}
	if r = e.post(moderator, "/admin/v1/support/threads/"+other+"/assign", map[string]any{"assignTo": "someone"}); r.status != 422 {
		t.Fatalf("assign to someone: %d", r.status)
	}
	for _, action := range []string{"support_close", "support_assign"} {
		if e.count(`SELECT count(*) FROM operator_audit WHERE action=$1`, action) == 0 {
			t.Errorf("%s not audited", action)
		}
	}
}

func contains(items []string, v string) bool {
	for _, i := range items {
		if i == v {
			return true
		}
	}
	return false
}

func TestSocialTablesOnTheRestrictedConsoleRole(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	adm := rolePool(t, "hiyall_admin")
	ctx := context.Background()
	op := e.operator(RoleAdmin)
	if _, err := adm.Exec(ctx, `INSERT INTO notices(notice_id,category,title,body,created_by) VALUES(gen_random_uuid(),'news','t','b',$1)`, op.ID); err != nil {
		t.Fatalf("notice insert: %v", err)
	}
	if _, err := adm.Exec(ctx, `UPDATE notices SET pinned=true WHERE false`); err != nil {
		t.Fatalf("notice update: %v", err)
	}
	for _, q := range []string{`DELETE FROM notices`, `DELETE FROM support_threads`, `DELETE FROM support_messages`, `UPDATE support_messages SET body='x'`, `INSERT INTO support_threads(thread_id,user_id,category) VALUES(gen_random_uuid(),gen_random_uuid(),'bug')`,
		`SELECT count(*) FROM notice_seen`, `SELECT count(*) FROM notification_prefs`} {
		if _, err := adm.Exec(ctx, q); !denied(err) {
			t.Errorf("hiyall_admin ran %q: %v", q, err)
		}
	}
	// Support work on the restricted role end to end.
	user := e.member(false)
	thread, err := e.db.CreateSupportThread(e.ctx, user, "bug", "it crashed", domain.Free())
	if err != nil {
		t.Fatal(err)
	}
	e.asRole("hiyall_admin")
	s := e.session(e.operator(RoleModerator))
	if r := e.get(s, "/admin/v1/support/threads/"+thread); r.status != 200 {
		t.Fatalf("read on the console role: %d %s", r.status, r.raw)
	}
	if r := e.post(s, "/admin/v1/support/threads/"+thread+"/reply", map[string]any{"body": "thanks, fixed in the next update"}); r.status != 201 {
		t.Fatalf("reply on the console role: %d %s", r.status, r.raw)
	}
}
