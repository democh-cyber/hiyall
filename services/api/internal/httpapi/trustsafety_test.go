package httpapi

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/metrics"
)

// ---- API-8: deletion of an account that signs in with Apple needs the authorization code

func (h *acctHarness) identity(user, subject, provider string, appleLinked bool) {
	h.t.Helper()
	h.exec(`DELETE FROM auth_identities WHERE user_id=$1 AND subject=$2`, user, subject)
	h.exec(`INSERT INTO auth_identities(issuer,subject,user_id,sign_in_provider,apple_linked) VALUES('https://securetoken.google.com/test-project',$1,$2,nullif($3,''),$4)`, subject, user, provider, appleLinked)
}

func TestDeletionOfAnAppleAccountWithoutTheCodeIsRefused(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	apple := &fakeAppleRevoker{}
	h.api.Apple = apple
	h.identity(xan, "apple-uid-x", "apple.com", true)

	got := h.expect(h.schedule(xan, "xan"), 422, "APPLE_CODE_REQUIRED")
	if msg, _ := got.data["message"].(string); got.data != nil && msg != "" && !strings.Contains(strings.ToLower(msg), "apple") {
		t.Fatalf("message does not tell the app to use Apple: %q", msg)
	}
	if h.status(xan) != "active" || len(apple.codes) != 0 {
		t.Fatal("a refused deletion changed the account or called Apple")
	}
	// With the code from a fresh Apple sign-in it goes through and Apple is told.
	h.expect(h.scheduleApple(xan, "xan", "fresh-code"), 200, "")
	if h.status(xan) != "pending_deletion" || len(apple.codes) != 1 {
		t.Fatalf("status %s codes %v", h.status(xan), apple.codes)
	}
}

func TestDeletionRequiresTheCodeWhenAppleIsLinkedToAGoogleSignIn(t *testing.T) {
	h := newAcctHarness(t)
	h.api.Apple = &fakeAppleRevoker{}
	h.identity(eli, "google-uid-e", "google.com", true) // signed in with Google, Apple also linked
	h.expect(h.schedule(eli, "eli"), 422, "APPLE_CODE_REQUIRED")
}

func TestDeletionNeedsNoCodeWithoutApple(t *testing.T) {
	h := newAcctHarness(t)
	h.api.Apple = &fakeAppleRevoker{}
	h.identity(cara, "google-uid-c", "google.com", false)
	h.expect(h.schedule(cara, "cara"), 200, "")
	// An identity not seen since the release has no provider yet: it is not blocked.
	h.identity(yui, "old-uid-y", "", false)
	h.expect(h.schedule(yui, "yui"), 200, "")
}

func TestUnconfiguredAppleNeverBlocksDeletion(t *testing.T) {
	h := newAcctHarness(t)
	h.api.Apple = nil // nothing could be revoked, and the member must still be able to leave
	h.identity(xan, "apple-uid-x2", "apple.com", true)
	h.expect(h.schedule(xan, "xan"), 200, "")
}

func TestRecordSignInProviderWritesOnlyChanges(t *testing.T) {
	h := newAcctHarness(t)
	issuer := "https://securetoken.google.com/test-project"
	h.identity(cara, "uid-rec", "", false)
	read := func() (string, bool) {
		var p *string
		var linked bool
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT sign_in_provider,apple_linked FROM auth_identities WHERE subject='uid-rec'`).Scan(&p, &linked); err != nil {
			t.Fatal(err)
		}
		if p == nil {
			return "", linked
		}
		return *p, linked
	}
	if err := h.db.RecordSignInProvider(h.ctx, issuer, "uid-rec", "apple.com", true); err != nil {
		t.Fatal(err)
	}
	if p, l := read(); p != "apple.com" || !l {
		t.Fatalf("%q %v", p, l)
	}
	has, err := h.db.HasAppleAuthorization(h.ctx, cara)
	if err != nil || !has {
		t.Fatalf("%v %v", has, err)
	}
	if err = h.db.RecordSignInProvider(h.ctx, issuer, "uid-rec", "google.com", false); err != nil {
		t.Fatal(err)
	}
	if has, _ = h.db.HasAppleAuthorization(h.ctx, cara); has {
		t.Fatal("still Apple after the identity says otherwise")
	}
	// An unknown identity is a no-op, not an error.
	if err = h.db.RecordSignInProvider(h.ctx, issuer, "nobody", "apple.com", true); err != nil {
		t.Fatal(err)
	}
}

// ---- API-5: photo processing slots

func TestMediaProcessingSlotsAreBoundedAndAnswer503WhenBusy(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	h.api.SetMediaSlots(2)
	if cap(h.api.mediaSlots) != 2 {
		t.Fatalf("slots %d", cap(h.api.mediaSlots))
	}
	h.api.SetMediaSlots(0)
	if cap(h.api.mediaSlots) != 1 {
		t.Fatal("zero slots must still be one")
	}
	id, _ := h.beginUpload(store, alice, "post", photo(t, 80, 60))
	// Every slot taken for longer than the wait: the app is told to retry, the photo stays pending.
	h.api.mediaSlots <- struct{}{}
	start := time.Now()
	got := h.send(alice, "POST", "/v1/media/"+id+"/complete", nil)
	h.expect(got, 503, "MEDIA_BUSY")
	if waited := time.Since(start); waited < mediaSlotWait-time.Second || waited > mediaSlotWait+3*time.Second {
		t.Fatalf("waited %v for a slot", waited)
	}
	var status string
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM media_assets WHERE media_id=$1`, id).Scan(&status)
	if status != "pending" {
		t.Fatalf("a busy refusal changed the photo to %s", status)
	}
	// A slot frees up: the same upload completes.
	<-h.api.mediaSlots
	h.api.mediaComplete.reset(alice)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 200, "")
}

// ---- SAFE-1 (a): only a strong match suspends

func TestPerceptualOnlyHitIsFlaggedAndNeverSuspends(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := photo(t, 120, 90)
	hash, err := media.PerceptualHash(pic)
	if err != nil {
		t.Fatal(err)
	}
	// The processed copy is what the scanner hashes; list its hash exactly.
	processed, err := media.Process(pic)
	if err != nil {
		t.Fatal(err)
	}
	hash, _ = media.PerceptualHash(processed.Full)
	path := t.TempDir() + "/list.txt"
	entry := "phash:" + hex64(hash) + " known\n"
	if err = writeFile(path, entry); err != nil {
		t.Fatal(err)
	}
	list, err := media.NewHashList(path)
	if err != nil || list.Len() != 1 {
		t.Skipf("the test photo's hash has too little entropy for a list entry (%v, %d entries)", err, list.Len())
	}
	h.api.Scanner = list
	id, _ := h.beginUpload(store, alice, "post", pic)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")
	var result, userStatus string
	var suspended bool
	h.db.Pool.QueryRow(h.ctx, `SELECT result,suspended_user FROM content_cases WHERE media_id=$1`, id).Scan(&result, &suspended)
	h.db.Pool.QueryRow(h.ctx, `SELECT status FROM users WHERE user_id=$1`, alice).Scan(&userStatus)
	if result != "flagged" || suspended || userStatus != "active" {
		t.Fatalf("perceptual-only hit: case %s suspended=%v, uploader %s", result, suspended, userStatus)
	}
	if h.count(`SELECT count(*) FROM moderation_actions WHERE subject_id=$1 AND action_type='suspend'`, alice) != 0 {
		t.Fatal("a suspension was recorded")
	}
}

// ---- SAFE-1 (b), (d), (f): evidence bucket, retention, alerting

type recordingReporter struct {
	mu   sync.Mutex
	reps []ErrorReport
}

func (r *recordingReporter) Report(_ context.Context, rep ErrorReport) {
	r.mu.Lock()
	r.reps = append(r.reps, rep)
	r.mu.Unlock()
}

func TestQuarantinedOriginalsGoToTheEvidenceStoreWithTheConfiguredRetentionAndAlert(t *testing.T) {
	h := newSocialHarness(t)
	mediaStore := withMedia(h)
	evidence := media.NewMemory()
	h.api.SetEvidence(evidence, 730)
	reporter := &recordingReporter{}
	h.api.Reporter = reporter
	pic := photo(t, 90, 70)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Match}}
	before := counterValue(t, "hiyall_quarantine_cases_total", `result="match"`)
	id, uploadKey := h.beginUpload(mediaStore, alice, "post", pic)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")

	original, full := media.HoldKeys(id)
	if !evidence.Has(original) || !evidence.Has(full) {
		t.Fatalf("evidence store has %v", evidence.Keys())
	}
	if mediaStore.Has(original) || mediaStore.Has(full) || mediaStore.Has(uploadKey) {
		t.Fatalf("evidence or the upload left in the media bucket: %v", mediaStore.Keys())
	}
	var holdDays float64
	h.db.Pool.QueryRow(h.ctx, `SELECT extract(epoch FROM hold_until-created_at)/86400 FROM content_cases WHERE media_id=$1`, id).Scan(&holdDays)
	if holdDays < 729.9 || holdDays > 730.1 {
		t.Fatalf("hold %.1f days, want the configured 730", holdDays)
	}
	if after := counterValue(t, "hiyall_quarantine_cases_total", `result="match"`); after != before+1 {
		t.Fatalf("counter %v -> %v", before, after)
	}
	reporter.mu.Lock()
	defer reporter.mu.Unlock()
	if len(reporter.reps) != 1 || !strings.HasPrefix(reporter.reps[0].Route, "quarantine/match") || !strings.Contains(reporter.reps[0].Err.Error(), "new quarantine case") {
		t.Fatalf("reports %+v", reporter.reps)
	}
	if strings.Contains(reporter.reps[0].Err.Error(), media.SHA256Hex(pic)) {
		t.Fatal("the report carries the hash")
	}
}

func TestDefaultRetentionIsAYearAndSharedBucketStillWorks(t *testing.T) {
	h := newSocialHarness(t)
	mediaStore := withMedia(h)
	pic := photo(t, 95, 75)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(pic): media.Flagged}}
	id, _ := h.beginUpload(mediaStore, bob, "post", pic)
	h.expect(h.call(bob, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")
	original, _ := media.HoldKeys(id)
	if !mediaStore.Has(original) {
		t.Fatal("without an evidence store the original sits under hold/ in the media bucket")
	}
	var holdDays float64
	h.db.Pool.QueryRow(h.ctx, `SELECT extract(epoch FROM hold_until-created_at)/86400 FROM content_cases WHERE media_id=$1`, id).Scan(&holdDays)
	if holdDays < 364.9 || holdDays > 365.1 {
		t.Fatalf("default hold %.1f days", holdDays)
	}
}

func hex64(n uint64) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 16)
	for i := 15; i >= 0; i-- {
		out[i] = digits[n&15]
		n >>= 4
	}
	return string(out)
}

func writeFile(path, text string) error { return os.WriteFile(path, []byte(text), 0o600) }

// counterValue reads one sample of a counter from the default registry.
func counterValue(t *testing.T, name, labels string) float64 {
	t.Helper()
	var buf bytes.Buffer
	if _, err := metrics.Default.WriteTo(&buf); err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(buf.String(), "\n") {
		if strings.HasPrefix(line, name+"{") && strings.Contains(line, labels) {
			v, err := strconv.ParseFloat(strings.Fields(line)[len(strings.Fields(line))-1], 64)
			if err != nil {
				t.Fatal(err)
			}
			return v
		}
	}
	return 0
}

// ---- API-9: export slots

func TestExportIsRefusedWhenEverySlotIsTakenAndKeepsTheDailyClaim(t *testing.T) {
	h := newAcctHarness(t)
	h.api.SetExportConcurrency(2)
	h.api.clients.reset("127.0.0.1")
	// Two exports in progress on this node.
	r1, ok1 := h.api.acquireExportSlot()
	r2, ok2 := h.api.acquireExportSlot()
	if !ok1 || !ok2 {
		t.Fatal("slots not available")
	}
	before := counterValue(t, "hiyall_export_busy_total", "")
	h.api.clients.reset("127.0.0.1")
	status, header, body := h.full(cara, "GET", "/v1/me/export", "", "")
	if status != 503 || !strings.Contains(string(body), "EXPORT_BUSY") || len(header["Retry-After"]) != 1 {
		t.Fatalf("%d %v %s", status, header, body)
	}
	if h.count(`SELECT count(*) FROM users WHERE user_id=$1 AND last_export_at IS NOT NULL`, cara) != 0 {
		t.Fatal("a refused export used the daily claim")
	}
	// A slot frees: the same member can export now, then is limited to one a day as before.
	r1()
	if status, _, _, _ = h.exportDoc(cara); status != 200 {
		t.Fatalf("export after a slot freed: %d", status)
	}
	if status, _, _, _ = h.exportDoc(cara); status != 429 {
		t.Fatalf("second export in a day: %d", status)
	}
	r2()
	// Slots are given back after every export, so the next member is served.
	if _, ok := h.api.acquireExportSlot(); !ok {
		t.Fatal("a finished export kept its slot")
	}
	_ = before
}

// brokenConn is a connection that breaks after n bytes.
type brokenConn struct {
	header http.Header
	left   int
	status int
}

func (f *brokenConn) Header() http.Header    { return f.header }
func (f *brokenConn) WriteHeader(status int) { f.status = status }
func (f *brokenConn) Write(p []byte) (int, error) {
	if f.left <= 0 {
		return 0, errors.New("broken pipe")
	}
	if len(p) > f.left {
		n := f.left
		f.left = 0
		return n, errors.New("broken pipe")
	}
	f.left -= len(p)
	return len(p), nil
}

func TestClientAbortDoesNotRefundTheDailyExport(t *testing.T) {
	h := newAcctHarness(t)
	h.api.clients.reset("127.0.0.1")
	req := httptest.NewRequest("GET", "/v1/me/export", nil)
	req.RemoteAddr = "127.0.0.1:50000"
	req.Header.Set("Authorization", "Bearer "+cara)
	// The connection dies after 200 bytes, in the middle of the document.
	h.api.Handler().ServeHTTP(&brokenConn{header: http.Header{}, left: 200}, req)
	if h.count(`SELECT count(*) FROM users WHERE user_id=$1 AND last_export_at IS NOT NULL`, cara) != 1 {
		t.Fatal("an abandoned export gave the claim back: abandoning exports would be free")
	}
	if status, _, _, _ := h.exportDoc(cara); status != 429 {
		t.Fatalf("a second export right after an abort: %d", status)
	}
	// The slot is free again either way.
	if _, ok := h.api.acquireExportSlot(); !ok {
		t.Fatal("an aborted export kept its slot")
	}
}
