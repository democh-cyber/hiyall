package httpapi

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/media"
)

// scriptedScanner answers by the SHA-256 of the uploaded bytes, so each test decides per photo.
type scriptedScanner struct {
	verdicts map[string]media.Verdict
	fail     bool
	seen     int
}

func (s *scriptedScanner) Name() string { return "scripted" }
func (s *scriptedScanner) Scan(_ context.Context, in media.ScanInput) (media.ScanResult, error) {
	s.seen++
	if s.fail {
		return media.ScanResult{}, errors.New("provider down")
	}
	v := s.verdicts[media.SHA256Hex(in.Original)]
	if v == "" {
		v = media.Clean
	}
	return media.ScanResult{Verdict: v, Scanner: "scripted", Signals: map[string]string{"label": "test"}}, nil
}

// beginUpload runs the first half of the client flow and puts the bytes where the signed URL says.
func (h *socialHarness) beginUpload(store *media.Memory, user, purpose string, data []byte) (id, key string) {
	h.t.Helper()
	made := h.expect(h.send(user, "POST", "/v1/media/uploads", map[string]any{"purpose": purpose, "contentType": "image/jpeg", "sizeBytes": len(data)}), 201, "").data
	id = made["mediaId"].(string)
	key = strings.TrimPrefix(made["uploadUrl"].(string), "memory://put/")
	_ = store.Put(h.ctx, key, data, "image/jpeg")
	return id, key
}

func TestScannerCleanPhotoIsReadyAndRecorded(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	scanner := &scriptedScanner{}
	h.api.Scanner = scanner
	id := h.upload(store, alice, "post", photo(t, 80, 60))
	var status, result string
	var scanned *time.Time
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status,scan_result,scanned_at FROM media_assets WHERE media_id=$1`, id).Scan(&status, &result, &scanned); err != nil {
		t.Fatal(err)
	}
	if status != "ready" || result != "clean" || scanned == nil || scanner.seen != 1 {
		t.Fatalf("status %s result %s scanned %v seen %d", status, result, scanned, scanner.seen)
	}
}

func TestScannerMatchQuarantinesSuspendsAndKeepsTheEvidence(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := photo(t, 90, 70)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Match}}
	id, uploadKey := h.beginUpload(store, alice, "post", pic)

	// The member gets the same plain refusal as for a flag, which says nothing about why.
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")

	// Never served: nothing under the display prefix, the upload prefix is emptied, the hold prefix has the bytes.
	original, full := media.HoldKeys(id)
	if store.Has("media/"+id+"/full.jpg") || store.Has("media/"+id+"/thumb.jpg") || store.Has(uploadKey) {
		t.Fatalf("objects left outside the hold: %v", store.Keys())
	}
	if !store.Has(original) || !store.Has(full) {
		t.Fatalf("held objects missing: %v", store.Keys())
	}
	if got, _ := store.Get(h.ctx, original, media.MaxUploadBytes); !bytes.Equal(got, pic) {
		t.Fatal("the held original is not the exact upload")
	}

	var status, scanResult string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status,scan_result FROM media_assets WHERE media_id=$1`, id).Scan(&status, &scanResult); err != nil || status != "quarantined" || scanResult != "match" {
		t.Fatalf("media %s %s %v", status, scanResult, err)
	}
	// The case and its evidence record.
	var sha, result, caseStatus string
	var suspended bool
	var holdDays float64
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT original_sha256,result,status,suspended_user,extract(epoch FROM hold_until-created_at)/86400 FROM content_cases WHERE media_id=$1`, id).Scan(&sha, &result, &caseStatus, &suspended, &holdDays); err != nil {
		t.Fatal(err)
	}
	if sha != media.SHA256Hex(pic) || result != "match" || caseStatus != "open" || !suspended || holdDays < 364.9 || holdDays > 365.1 {
		t.Fatalf("case %s %s %s %v %.1f", sha, result, caseStatus, suspended, holdDays)
	}
	// The uploader is suspended pending review, with a record of who did it.
	var userStatus string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM users WHERE user_id=$1`, alice).Scan(&userStatus)
	var actions int
	h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM moderation_actions WHERE subject_id=$1 AND action_type='suspend' AND actor='system:upload-scanner'`, alice).Scan(&actions)
	if userStatus != "suspended" || actions != 1 {
		t.Fatalf("uploader %s, %d scanner actions", userStatus, actions)
	}
	h.expect(h.call(alice, "GET", "/v1/me/profile"), 401, "UNAUTHENTICATED")

	// The cleanup never deletes held photos, even long after the upload would have expired.
	if _, err := h.db.Pool.Exec(h.ctx, `UPDATE media_assets SET expires_at=now()-interval '5 days' WHERE media_id=$1`, id); err != nil {
		t.Fatal(err)
	}
	keys, _, err := h.db.MediaGarbage(h.ctx, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range keys {
		if strings.Contains(k, id) {
			t.Fatalf("cleanup would delete held key %s", k)
		}
	}
}

func TestScannerFlagQuarantinesWithoutSuspendingAndCannotBeAttached(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := photo(t, 100, 50)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Flagged}}
	id, _ := h.beginUpload(store, alice, "post", pic)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")

	var userStatus, result string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM users WHERE user_id=$1`, alice).Scan(&userStatus)
	h.db.Pool.QueryRow(h.ctx, `SELECT result FROM content_cases WHERE media_id=$1`, id).Scan(&result)
	if userStatus != "active" || result != "flagged" {
		t.Fatalf("uploader %s, case %s", userStatus, result)
	}
	// A quarantined photo is not attachable to a post or an avatar.
	h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "x", "audience": "public", "mediaIds": []string{id}}), 409, "MEDIA_NOT_READY")
	h.expect(h.setAvatar(alice, id), 422, "VALIDATION")
	if len(feedBodies(h, alice, "everyone")) != 0 {
		t.Fatal("a post appeared")
	}
	// Completing again cannot resurrect it.
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 404, "NOT_FOUND")
}

func TestScannerFailureFailsClosedAndTheUploadCanBeRetried(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	scanner := &scriptedScanner{fail: true}
	h.api.Scanner = scanner
	id, _ := h.beginUpload(store, alice, "story", photo(t, 60, 60))
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 503, "SCAN_UNAVAILABLE")
	var status string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM media_assets WHERE media_id=$1`, id).Scan(&status)
	if status != "pending" || store.Has("media/"+id+"/full.jpg") {
		t.Fatalf("unscanned photo is %s with objects %v", status, store.Keys())
	}
	scanner.fail = false
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 200, "")
}

func TestPurgeLeavesQuarantinedEvidenceAndStillFinishes(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := photo(t, 110, 80)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Flagged}}
	id, _ := h.beginUpload(store, bob, "post", pic)
	h.expect(h.call(bob, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")

	if _, err := h.db.ScheduleDeletion(h.ctx, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := h.db.Pool.Exec(h.ctx, `UPDATE users SET deletion_due_at=now()-interval '1 minute' WHERE user_id=$1`, bob); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		if _, err := h.db.PurgeDeletedAccounts(h.ctx, nil, 10); err != nil {
			t.Fatal(err)
		}
		keys, _, err := h.db.MediaGarbage(h.ctx, 100)
		if err != nil {
			t.Fatal(err)
		}
		for _, k := range keys {
			if strings.Contains(k, id) {
				t.Fatalf("purge released held key %s", k)
			}
		}
	}
	var status, mediaStatus string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM users WHERE user_id=$1`, bob).Scan(&status)
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM media_assets WHERE media_id=$1`, id).Scan(&mediaStatus)
	original, _ := media.HoldKeys(id)
	if status != "deleted" || mediaStatus != "quarantined" || !store.Has(original) {
		t.Fatalf("account %s, media %s, original held %v", status, mediaStatus, store.Has(original))
	}
}

// evidenceProbe is an evidence store that looks at the database each time an object is written.
type evidenceProbe struct {
	*media.Memory
	onPut func(key string) error
}

func (e *evidenceProbe) Put(ctx context.Context, key string, data []byte, contentType string) error {
	if err := e.onPut(key); err != nil {
		return err
	}
	return e.Memory.Put(ctx, key, data, contentType)
}

// Round-3 audit API-6/7: the case row is written first, as 'pending', and the objects second, so an evidence
// object never exists without a case; a failed write leaves a pending case for the console's sweep, never an
// open case with no photo behind it.
func TestQuarantineWritesTheCaseBeforeTheEvidenceObjects(t *testing.T) {
	h := newSocialHarness(t)
	withMedia(h)
	pic := photo(t, 90, 71)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Flagged}}
	var seen []string
	evidence := &evidenceProbe{Memory: media.NewMemory()}
	evidence.onPut = func(key string) error {
		var status string
		id := strings.Split(key, "/")[1]
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT status FROM content_cases WHERE media_id=$1`, id).Scan(&status); err != nil {
			return errors.New("an evidence object was written before its case: " + err.Error())
		}
		seen = append(seen, status)
		return nil
	}
	h.api.SetEvidence(evidence, 365)
	t.Cleanup(func() { h.api.SetEvidence(nil, 365) })
	store := h.api.Media.(*media.Memory)
	id, _ := h.beginUpload(store, alice, "post", pic)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")
	if len(seen) != 2 || seen[0] != "pending" || seen[1] != "pending" {
		t.Fatalf("case status at each write: %v", seen)
	}
	var status string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM content_cases WHERE media_id=$1`, id).Scan(&status)
	if status != "open" {
		t.Fatalf("the case is %s after both objects were stored", status)
	}
}

func TestAFailedEvidenceWriteLeavesAPendingCaseNotAnOpenOne(t *testing.T) {
	h := newSocialHarness(t)
	withMedia(h)
	pic := photo(t, 90, 72)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Match}}
	evidence := &evidenceProbe{Memory: media.NewMemory(), onPut: func(key string) error {
		if strings.HasSuffix(key, "full.jpg") {
			return errors.New("evidence bucket unavailable")
		}
		return nil
	}}
	h.api.SetEvidence(evidence, 365)
	t.Cleanup(func() { h.api.SetEvidence(nil, 365) })
	store := h.api.Media.(*media.Memory)
	id, _ := h.beginUpload(store, alice, "post", pic)
	got := h.call(alice, "POST", "/v1/media/"+id+"/complete")
	if got.status < 500 {
		t.Fatalf("a failed evidence write was answered as %d", got.status)
	}
	var status string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status FROM content_cases WHERE media_id=$1`, id).Scan(&status); err != nil || status != "pending" {
		t.Fatalf("case %q %v: it must stay pending for the sweep", status, err)
	}
	// A match's suspension does not wait for the evidence copy.
	var userStatus string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM users WHERE user_id=$1`, alice).Scan(&userStatus)
	if userStatus != "suspended" {
		t.Fatalf("uploader %s", userStatus)
	}
	if h.count(`SELECT count(*) FROM content_cases WHERE status='open' AND media_id=$1`, id) != 0 {
		t.Fatal("an open case with no evidence")
	}
}
