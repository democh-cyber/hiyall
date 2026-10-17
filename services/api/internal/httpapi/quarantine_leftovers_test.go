package httpapi

import (
	"context"
	"errors"
	"testing"

	"hiyall/services/api/internal/media"
)

// Round-4 N-7: a quarantined photo's original must not stay in the upload prefix for ever. The media row's upload key is
// replaced by the evidence key when the case is opened, so an object left behind is named by nothing: a failed delete is
// recorded for the API's cleanup job, and the original of a MATCH whose evidence write failed is kept (it may be the only
// copy) with its key in the case.

// failingDelete is a media store whose deletes can be switched off.
type failingDelete struct {
	*media.Memory
	fail bool
}

func (f *failingDelete) Delete(ctx context.Context, keys ...string) error {
	if f.fail {
		return errors.New("storage unavailable")
	}
	return f.Memory.Delete(ctx, keys...)
}

func TestAQuarantinedUploadThatCannotBeRemovedIsRecordedAndCleanedUpLater(t *testing.T) {
	h := newSocialHarness(t)
	mem := withMedia(h)
	h.exec(`TRUNCATE quarantine_upload_leftovers`)
	failing := &failingDelete{Memory: mem, fail: true}
	h.api.Media = failing
	pic := photo(t, 90, 73)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Flagged}}
	id, uploadKey := h.beginUpload(mem, alice, "post", pic)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")
	if !mem.Has(uploadKey) {
		t.Fatal("the delete was supposed to fail")
	}
	// Recorded, not just logged.
	if h.count(`SELECT count(*) FROM quarantine_upload_leftovers WHERE object_key=$1 AND media_id=$2`, uploadKey, id) != 1 {
		t.Fatal("the leftover upload object was not recorded for cleanup")
	}
	// The cleanup job removes it once storage is back, and forgets it.
	if n, err := h.db.PurgeUploadLeftovers(h.ctx, failing, 10); err == nil || n != 0 {
		t.Fatalf("a failing delete was counted: %d %v", n, err)
	}
	if h.count(`SELECT count(*) FROM quarantine_upload_leftovers`) != 1 {
		t.Fatal("a failed delete forgot the leftover")
	}
	failing.fail = false
	if n, err := h.db.PurgeUploadLeftovers(h.ctx, failing, 10); err != nil || n != 1 {
		t.Fatalf("cleanup: %d %v", n, err)
	}
	if mem.Has(uploadKey) || h.count(`SELECT count(*) FROM quarantine_upload_leftovers`) != 0 {
		t.Fatal("the leftover is still there")
	}
	// The evidence copy is untouched.
	original, _ := media.HoldKeys(id)
	if !mem.Has(original) {
		t.Fatal("the cleanup removed evidence")
	}
}

func TestTheCleanupNeverDeletesUnderTheHoldPrefix(t *testing.T) {
	h := newSocialHarness(t)
	mem := media.NewMemory()
	h.exec(`TRUNCATE quarantine_upload_leftovers`)
	_ = mem.Put(h.ctx, "hold/some-id/original", []byte("evidence"), "image/jpeg")
	if err := h.db.RecordUploadLeftover(h.ctx, "hold/some-id/original", "00000000-0000-0000-0000-000000000001"); err != nil {
		t.Fatal(err)
	}
	if _, err := h.db.PurgeUploadLeftovers(h.ctx, mem, 10); err != nil {
		t.Fatal(err)
	}
	if !mem.Has("hold/some-id/original") {
		t.Fatal("a recorded key under hold/ was deleted")
	}
	if h.count(`SELECT count(*) FROM quarantine_upload_leftovers`) != 0 {
		t.Fatal("the bad record was kept")
	}
}

func TestAFailedEvidenceWriteRecordsAFlaggedUploadsObjectButKeepsAMatchs(t *testing.T) {
	h := newSocialHarness(t)
	mem := withMedia(h)
	h.exec(`TRUNCATE quarantine_upload_leftovers`)
	flaggedPic, matchPic := photo(t, 90, 74), photo(t, 90, 75)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(flaggedPic): media.Flagged, media.SHA256Hex(matchPic): media.Match}}
	evidence := &evidenceProbe{Memory: media.NewMemory(), onPut: func(key string) error {
		return errors.New("evidence bucket unavailable")
	}}
	h.api.SetEvidence(evidence, 365)
	t.Cleanup(func() { h.api.SetEvidence(nil, 365) })

	flaggedID, flaggedKey := h.beginUpload(mem, alice, "post", flaggedPic)
	if got := h.call(alice, "POST", "/v1/media/"+flaggedID+"/complete"); got.status < 500 {
		t.Fatalf("flagged: %d", got.status)
	}
	// The sweep will drop the flagged pending case, and nothing would name the upload object any more: it is recorded.
	if h.count(`SELECT count(*) FROM quarantine_upload_leftovers WHERE object_key=$1`, flaggedKey) != 1 {
		t.Fatal("the flagged photo's upload object was not recorded")
	}
	// A match: the upload object may be the only copy. It is NOT recorded for deletion, and the case says where it is.
	matchID, matchKey := h.beginUpload(mem, bob, "post", matchPic)
	if got := h.call(bob, "POST", "/v1/media/"+matchID+"/complete"); got.status < 500 {
		t.Fatalf("match: %d", got.status)
	}
	if h.count(`SELECT count(*) FROM quarantine_upload_leftovers WHERE object_key=$1`, matchKey) != 0 {
		t.Fatal("the only copy of a match was queued for deletion")
	}
	if !mem.Has(matchKey) {
		t.Fatal("the upload object of a match was removed although the evidence write failed")
	}
	var recorded string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT signals->>'uploadKey' FROM content_cases WHERE media_id=$1`, matchID).Scan(&recorded); err != nil || recorded != matchKey {
		t.Fatalf("the case does not record where the original is: %q (%v)", recorded, err)
	}
}
