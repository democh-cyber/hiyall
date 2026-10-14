package admin

import (
	"bytes"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// contentFixture is a member with a public post that has a photo, a comment, a story and a report about each.
type contentFixture struct {
	author, reporter                  string
	postID, commentID, storyID, photo string
	reports                           map[string]string // target type -> report id
}

func (e *env) exec(query string, args ...any) {
	e.t.Helper()
	if _, err := e.db.Pool.Exec(e.ctx, query, args...); err != nil {
		e.t.Fatalf("%s: %v", query, err)
	}
}

func (e *env) rawReport(reporter, subject, targetType, targetID string) string {
	e.t.Helper()
	id := uuid.NewString()
	e.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity) VALUES($1,$2,$3,$4,$5,'harassment','normal')`, id, reporter, targetType, targetID, subject)
	return id
}

// readyPhoto stores a photo the way the upload pipeline leaves it: ready, with variants.
func (e *env) readyPhoto(owner, purpose string, store *media.Memory, content []byte) string {
	e.t.Helper()
	id := uuid.NewString()
	full := "media/" + id + "/full.jpg"
	e.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,width,height,upload_key,variants,attached,expires_at)
 VALUES($1,$2,$3,'ready','image/jpeg',$4,$4,80,60,'uploads/x',jsonb_build_object('full',$5::text,'thumb',$5::text),true,now()+interval '1 day')`, id, owner, purpose, len(content), full)
	if store != nil {
		_ = store.Put(e.ctx, full, content, "image/jpeg")
	}
	return id
}

func (e *env) contentFixture(objects *media.Memory) contentFixture {
	e.t.Helper()
	f := contentFixture{author: e.member(false), reporter: e.member(false), postID: uuid.NewString(), commentID: uuid.NewString(), storyID: uuid.NewString(), reports: map[string]string{}}
	f.photo = e.readyPhoto(f.author, "post", objects, []byte("\xff\xd8reported-photo-bytes"))
	e.exec(`INSERT INTO posts(post_id,author_id,body,audience) VALUES($1,$2,'the reported post text','public')`, f.postID, f.author)
	e.exec(`INSERT INTO post_media(post_id,position,media_id) VALUES($1,0,$2)`, f.postID, f.photo)
	e.exec(`INSERT INTO comments(comment_id,post_id,author_id,body) VALUES($1,$2,$3,'the reported comment text')`, f.commentID, f.postID, f.author)
	e.exec(`INSERT INTO stories(story_id,author_id,body,audience,expires_at) VALUES($1,$2,'the reported story text','public',now()+interval '1 day')`, f.storyID, f.author)
	f.reports["post"] = e.rawReport(f.reporter, f.author, "post", f.postID)
	f.reports["comment"] = e.rawReport(f.reporter, f.author, "comment", f.commentID)
	f.reports["story"] = e.rawReport(f.reporter, f.author, "story", f.storyID)
	f.reports["user"] = e.rawReport(f.reporter, f.author, "user", f.author)
	f.reports["conversation"] = e.rawReport(f.reporter, f.author, "conversation", uuid.NewString())
	return f
}

type previewReply struct {
	Content struct {
		TargetType, Text, AuthorUsername string
		Media                            []struct{ MediaID string }
	}
	Media []struct {
		MediaID string `json:"mediaId"`
		URL     string `json:"url"`
	}
	MediaAvailable bool
}

func (e *env) auditCount(action, target string) int {
	return e.count(`SELECT count(*) FROM operator_audit WHERE action=$1 AND target_id=$2`, action, target)
}

func TestContentPreviewShowsReportedItemsToModeratorsOnlyAfterAReasonAndAuditsEverything(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	f := e.contentFixture(objects)
	viewer, mod := e.session(e.operator(RoleViewer)), e.session(e.operator(RoleModerator))
	path := func(kind string) string { return "/admin/v1/reports/" + f.reports[kind] + "/content" }

	// A viewer cannot ask; a moderator needs a written reason, which is stored with the audit entry.
	if r := e.post(viewer, path("post"), map[string]string{"reason": "checking the reported post"}); r.status != 403 {
		t.Fatalf("viewer: %d", r.status)
	}
	if r := e.post(mod, path("post"), map[string]string{"reason": "short"}); r.status != 422 || r.code() != "VALIDATION" {
		t.Fatalf("short reason: %d %s", r.status, r.raw)
	}
	if e.auditCount("report_content_view", f.reports["post"]) != 0 {
		t.Fatal("a refused request was audited as a view")
	}
	r := e.post(mod, path("post"), map[string]string{"reason": "checking the reported post"})
	var got previewReply
	r.data(&got)
	if r.status != 200 || got.Content.Text != "the reported post text" || got.Content.TargetType != "post" || len(got.Media) != 1 || !got.MediaAvailable || got.Media[0].MediaID != f.photo {
		t.Fatalf("preview: %d %s", r.status, r.raw)
	}
	var reason string
	e.db.Pool.QueryRow(e.ctx, `SELECT reason FROM operator_audit WHERE action='report_content_view' AND target_id=$1`, f.reports["post"]).Scan(&reason)
	if reason != "checking the reported post" {
		t.Fatalf("audited reason %q", reason)
	}
	// No object key or storage URL reaches the browser.
	if strings.Contains(string(r.raw), "media/"+f.photo+"/") || strings.Contains(string(r.raw), "memory://") {
		t.Fatalf("a storage key leaked: %s", r.raw)
	}

	// The photo is streamed through the console, and the fetch is audited too.
	img := e.get(mod, got.Media[0].URL)
	if img.status != 200 || img.header.Get("Content-Type") != "image/jpeg" || img.header.Get("Cache-Control") != "no-store" || !bytes.Equal(img.raw, []byte("\xff\xd8reported-photo-bytes")) {
		t.Fatalf("stream: %d %q %q", img.status, img.header.Get("Content-Type"), img.raw)
	}
	if e.auditCount("content_media_fetch", f.photo) != 1 {
		t.Fatal("the photo fetch was not audited")
	}

	// A link is bound to the operator, the photo and a short lifetime.
	other := e.session(e.operator(RoleModerator))
	if r := e.get(other, got.Media[0].URL); r.status != 422 {
		t.Fatalf("someone else's link: %d", r.status)
	}
	u, _ := url.Parse(got.Media[0].URL)
	tampered := u.Query().Get("t")
	tampered = tampered[:len(tampered)-2] + "AA"
	if r := e.get(mod, "/admin/v1/media/"+f.photo+"?t="+url.QueryEscape(tampered)); r.status != 422 {
		t.Fatalf("tampered token: %d", r.status)
	}
	if r := e.get(mod, "/admin/v1/media/"+uuid.NewString()+"?t="+url.QueryEscape(u.Query().Get("t"))); r.status != 422 {
		t.Fatalf("token for another photo: %d", r.status)
	}
	if r := e.get(mod, "/admin/v1/media/"+f.photo); r.status != 422 {
		t.Fatalf("no token: %d", r.status)
	}
	e.clock = e.clock.Add(3 * time.Minute)
	if r := e.get(mod, got.Media[0].URL); r.status != 422 {
		t.Fatalf("expired link: %d", r.status)
	}
	e.clock = e.clock.Add(-3 * time.Minute)

	// Text items, the avatar-less member report, and chats (never previewed).
	for kind, want := range map[string]string{"comment": "the reported comment text", "story": "the reported story text"} {
		var c previewReply
		rr := e.post(mod, path(kind), map[string]string{"reason": "checking the " + kind})
		rr.data(&c)
		if rr.status != 200 || c.Content.Text != want || len(c.Media) != 0 {
			t.Fatalf("%s: %d %s", kind, rr.status, rr.raw)
		}
	}
	if rr := e.post(mod, path("user"), map[string]string{"reason": "checking the member"}); rr.status != 200 {
		t.Fatalf("user: %d %s", rr.status, rr.raw)
	}
	rr := e.post(mod, path("conversation"), map[string]string{"reason": "looking at the chat"})
	if rr.status != 422 || rr.code() != "NO_PREVIEW" {
		t.Fatalf("chat preview: %d %s", rr.status, rr.raw)
	}
	if rr := e.post(mod, "/admin/v1/reports/"+uuid.NewString()+"/content", map[string]string{"reason": "unknown report here"}); rr.status != 404 {
		t.Fatalf("unknown report: %d", rr.status)
	}

	// Photos that are no longer stored are not offered; without a storage token the console shows text only.
	e.svc.Media = nil
	var noMedia previewReply
	rr = e.post(mod, path("post"), map[string]string{"reason": "checking without storage"})
	rr.data(&noMedia)
	if rr.status != 200 || noMedia.MediaAvailable || noMedia.Media[0].URL != "" {
		t.Fatalf("without media: %s", rr.raw)
	}
	if r := e.get(mod, got.Media[0].URL); r.status != 503 || r.code() != "MEDIA_UNAVAILABLE" {
		t.Fatalf("stream without storage: %d", r.status)
	}
}

// pendingQuarantine creates the case an upload scan would: a pending upload that was matched or flagged.
func (e *env) pendingQuarantine(owner, result string, objects *media.Memory) (caseID, mediaID string, original []byte) {
	e.t.Helper()
	mediaID = uuid.NewString()
	original = []byte("\xff\xd8quarantined-bytes")
	e.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,expires_at)
 VALUES($1,$2,'post','pending','image/jpeg',100,100,'uploads/x',now()+interval '1 hour')`, mediaID, owner)
	originalKey, fullKey := media.HoldKeys(mediaID)
	_ = objects.Put(e.ctx, originalKey, original, "image/jpeg")
	_ = objects.Put(e.ctx, fullKey, []byte("\xff\xd8held-processed-copy"), "image/jpeg")
	caseID, err := e.db.QuarantineMedia(e.ctx, store.Quarantine{MediaID: mediaID, Owner: owner, Purpose: "post", Result: result, Scanner: "hashlist",
		Signals: map[string]string{"label": "list-1"}, OriginalSHA256: media.SHA256Hex(original), OriginalBytes: int64(len(original)), ContentType: "image/jpeg", OriginalKey: originalKey, FullKey: fullKey})
	if err != nil {
		e.t.Fatal(err)
	}
	return caseID, mediaID, original
}

func TestQuarantinedUploadsAreVisibleToAdministratorsOnlyBlurredFirstAndEveryStepIsAudited(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	uploader := e.member(true)
	caseID, mediaID, _ := e.pendingQuarantine(uploader, "match", objects)
	viewer, mod, adm := e.session(e.operator(RoleViewer)), e.session(e.operator(RoleModerator)), e.session(e.operator(RoleAdmin))
	base := "/admin/v1/content-cases/" + caseID

	// The uploader is suspended and the case is in the list for moderators, who can read it but never the image.
	if got := e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='suspended'`, uploader); got != 1 {
		t.Fatal("the uploader was not suspended")
	}
	if r := e.get(viewer, "/admin/v1/content-cases"); r.status != 403 {
		t.Fatalf("viewer list: %d", r.status)
	}
	var list struct {
		Items []struct{ CaseID, Result, AgeBand, Status string }
	}
	r := e.get(mod, "/admin/v1/content-cases?status=open&limit=50")
	r.data(&list)
	found := false
	for _, it := range list.Items {
		if it.CaseID == caseID {
			found = it.Result == "match" && it.AgeBand == "minor" && it.Status == "open"
		}
	}
	if r.status != 200 || !found {
		t.Fatalf("list: %d %s", r.status, r.raw)
	}
	var detail struct {
		Case struct {
			OriginalSha256, Scanner, Status string
			SuspendedUser, LegalHold        bool
			Signals                         map[string]string
		}
		MediaAvailable bool
	}
	r = e.get(mod, base)
	r.data(&detail)
	if r.status != 200 || detail.Case.OriginalSha256 == "" || detail.Case.Signals["label"] != "list-1" || !detail.Case.SuspendedUser || e.auditCount("content_case_view", caseID) != 1 {
		t.Fatalf("detail: %d %s", r.status, r.raw)
	}
	if strings.Contains(string(r.raw), "hold/") {
		t.Fatalf("an object key reached the console UI: %s", r.raw)
	}
	for _, path := range []string{"/view", "/reveal", "/resolve"} {
		if rr := e.post(mod, base+path, map[string]string{"reason": "moderators may not do this"}); rr.status != 403 {
			t.Fatalf("moderator %s: %d", path, rr.status)
		}
	}

	// Administrators: a reason first, then a blurred view, then the explicit reveal.
	if rr := e.post(adm, base+"/view", map[string]string{"reason": "too short"}); rr.status != 422 {
		t.Fatalf("short reason: %d", rr.status)
	}
	var view struct {
		URL     string
		Blurred bool
	}
	rr := e.post(adm, base+"/view", map[string]string{"reason": "reviewing the scanner match"})
	rr.data(&view)
	if rr.status != 200 || !view.Blurred || !strings.HasPrefix(view.URL, "/admin/v1/media/"+mediaID+"?t=") || e.auditCount("quarantine_media_view", caseID) != 1 {
		t.Fatalf("view: %d %s", rr.status, rr.raw)
	}
	img := e.get(adm, view.URL)
	if img.status != 200 || !bytes.Equal(img.raw, []byte("\xff\xd8held-processed-copy")) || e.auditCount("quarantine_media_fetch", mediaID) != 1 {
		t.Fatalf("stream: %d %q", img.status, img.raw)
	}
	// A link issued for a case is useless to a moderator (it is bound to the administrator).
	if rr := e.get(mod, view.URL); rr.status != 422 {
		t.Fatalf("moderator with the admin's link: %d", rr.status)
	}
	if e.auditCount("quarantine_media_reveal", caseID) != 0 {
		t.Fatal("a reveal was recorded before it happened")
	}
	if rr := e.post(adm, base+"/reveal", map[string]string{"reason": "reviewing the scanner match"}); rr.status != 200 || e.auditCount("quarantine_media_reveal", caseID) != 1 {
		t.Fatalf("reveal: %d", rr.status)
	}

	// Resolution: confirm, then report with a reference; each audited in the same transaction.
	if rr := e.post(adm, base+"/resolve", map[string]any{"action": "reported", "reason": "reported to the authority"}); rr.status != 422 {
		t.Fatalf("reported without a reference: %d", rr.status)
	}
	if rr := e.post(adm, base+"/resolve", map[string]any{"action": "bogus", "reason": "not a valid action"}); rr.status != 422 {
		t.Fatalf("bad action: %d", rr.status)
	}
	if rr := e.post(adm, base+"/resolve", map[string]any{"action": "confirm", "reason": "confirmed by second review"}); rr.status != 200 {
		t.Fatalf("confirm: %d %s", rr.status, rr.raw)
	}
	if rr := e.post(adm, base+"/resolve", map[string]any{"action": "clear", "reason": "cannot clear a confirmed case"}); rr.status != 409 || rr.code() != "CASE_STATE" {
		t.Fatalf("clear after confirm: %d %s", rr.status, rr.raw)
	}
	if rr := e.post(adm, base+"/resolve", map[string]any{"action": "reported", "reason": "reported to the authority", "reportReference": "NCMEC-123456"}); rr.status != 200 {
		t.Fatalf("reported: %d %s", rr.status, rr.raw)
	}
	var status, ref string
	var hold bool
	e.db.Pool.QueryRow(e.ctx, `SELECT status,report_reference,legal_hold FROM content_cases WHERE case_id=$1`, caseID).Scan(&status, &ref, &hold)
	if status != "reported" || ref != "NCMEC-123456" || !hold {
		t.Fatalf("case %s %s hold=%v (a reported case is held as evidence)", status, ref, hold)
	}
	for _, action := range []string{"content_case_confirm", "content_case_reported"} {
		if e.auditCount(action, caseID) != 1 {
			t.Fatalf("%s not audited", action)
		}
	}
	// The hold survives: the case row and the held objects are untouched by resolving.
	originalKey, _ := media.HoldKeys(mediaID)
	if !objects.Has(originalKey) {
		t.Fatal("resolving deleted the evidence")
	}
	// Unknown ids are plain 404s.
	if rr := e.get(adm, "/admin/v1/content-cases/"+uuid.NewString()); rr.status != 404 {
		t.Fatalf("unknown case: %d", rr.status)
	}
	// A flagged case does not suspend, and a cleared one closes.
	other := e.member(false)
	flagged, _, _ := e.pendingQuarantine(other, "flagged", objects)
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='active'`, other) != 1 {
		t.Fatal("a flag suspended the uploader")
	}
	if rr := e.post(adm, "/admin/v1/content-cases/"+flagged+"/resolve", map[string]any{"action": "clear", "reason": "a false positive, looked at it"}); rr.status != 200 {
		t.Fatalf("clear: %d %s", rr.status, rr.raw)
	}
}
