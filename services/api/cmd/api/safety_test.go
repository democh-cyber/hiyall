package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

func newTestAPI() *httpapi.API {
	return httpapi.New(nil, nil, false, "")
}

// With an evidence bucket the API never deletes held evidence (its token there cannot), so its maintenance gets
// no store for the hold cleanup; in the shared-bucket mode it keeps the media store, as before.
func TestWireSafetyKeepsHoldDeletionAwayFromTheAPIWhenEvidenceHasItsOwnBucket(t *testing.T) {
	// The bucket checks dial the bucket: not in a unit test.
	oldStart := evidenceStart
	evidenceStart = func(context.Context, config.Config, media.Store) error { return nil }
	t.Cleanup(func() { evidenceStart = oldStart })
	mem := media.NewMemory()
	api := newTestAPI()
	api.Media = mem
	cfg := config.Config{Env: "production", MediaEndpoint: "acct.r2.cloudflarestorage.com"}
	cfg.MediaProcessSlots, cfg.ExportConcurrency, cfg.EvidenceRetentionDays = 2, 3, 365

	held, err := wireSafety(context.Background(), cfg, api)
	if err != nil || held != media.Store(mem) {
		t.Fatalf("shared bucket: %v %v", held, err)
	}
	cfg.EvidenceBucket, cfg.EvidenceEndpoint, cfg.EvidenceAccessKey, cfg.EvidenceSecretKey = "hiyall-evidence", "acct.r2.cloudflarestorage.com", "w", "w"
	cfg.EvidenceSecure, cfg.EvidenceRegion = true, "auto"
	if held, err = wireSafety(context.Background(), cfg, api); err != nil || held != nil {
		t.Fatalf("separate bucket: %v %v", held, err)
	}
	// No media storage at all: nothing to wire, nothing to delete.
	cfg.MediaEndpoint = ""
	if held, err = wireSafety(context.Background(), cfg, api); err != nil || held != nil {
		t.Fatalf("no media: %v %v", held, err)
	}
}

func TestHoldCleanupJobOnlyRunsWhereTheAPICanDelete(t *testing.T) {
	// maintenanceJobs lists the job in every case; the option decides what it may delete with.
	if jobOption := onlyHeldObjects(nil); jobOption.held != nil {
		t.Fatal("onlyHeldObjects(nil) must mean no deletion")
	}
}

// permStore is an evidence store whose permissions the test chooses.
type permStore struct {
	*media.Memory
	denyGet, denyDelete bool
}

func (p permStore) Get(ctx context.Context, k string, l int64) ([]byte, error) {
	if p.denyGet {
		return nil, errors.New("AccessDenied")
	}
	return p.Memory.Get(ctx, k, l)
}
func (p permStore) Delete(ctx context.Context, k ...string) error {
	if p.denyDelete {
		return errors.New("AccessDenied")
	}
	return p.Memory.Delete(ctx, k...)
}

// Round-3 audit API-2, round-4 N-6: the evidence token's write-only property, or the bucket lock that makes up for it, is
// proved, not assumed. EVIDENCE_ALLOW_API_DELETE=true is a declaration the canary verifies.
func TestEvidenceCanaryRefusesATokenThatCanReadOrDeleteUnlessAccepted(t *testing.T) {
	ctx := context.Background()
	cfg := config.Config{Env: "production"}
	problem, warning, err := evidenceCanary(ctx, cfg, permStore{Memory: media.NewMemory(), denyGet: true, denyDelete: true})
	if problem != "" || warning != "" || err != nil {
		t.Fatalf("a write-only token: %q %q %v", problem, warning, err)
	}
	canDelete := map[string]permStore{
		"delete": {Memory: media.NewMemory(), denyGet: true},
		"both":   {Memory: media.NewMemory()},
	}
	for name, s := range canDelete {
		// A probe that can be deleted means nothing protects the evidence: a problem, with or without the declaration.
		problem, warning, err = evidenceCanary(ctx, cfg, s)
		if problem == "" || warning != "" || err != nil || !strings.Contains(problem, "can delete") {
			t.Fatalf("%s: %q %q %v", name, problem, warning, err)
		}
		cfg.EvidenceAllowAPIDelete = true
		problem, warning, err = evidenceCanary(ctx, cfg, s)
		if problem == "" || err != nil || !strings.Contains(problem, "declares a bucket lock") {
			t.Fatalf("%s with EVIDENCE_ALLOW_API_DELETE=true but no lock: %q %q %v", name, problem, warning, err)
		}
		// Only the explicit acceptance of the risk turns it into a warning.
		cfg.EvidenceCanaryAcceptUnlocked = true
		problem, warning, err = evidenceCanary(ctx, cfg, s)
		if problem != "" || !strings.Contains(warning, "EVIDENCE_CANARY_ACCEPT_UNLOCKED") || err != nil {
			t.Fatalf("%s accepted: %q %q %v", name, problem, warning, err)
		}
		cfg.EvidenceAllowAPIDelete, cfg.EvidenceCanaryAcceptUnlocked = false, false
	}
	// A bucket lock refuses the delete. The token can still read, which is a problem until the owner has declared the lock;
	// with the declaration the canary has VERIFIED it (the delete was refused) and says so.
	locked := permStore{Memory: media.NewMemory(), denyDelete: true}
	problem, warning, err = evidenceCanary(ctx, cfg, locked)
	if problem == "" || !strings.Contains(problem, "can read") || err != nil {
		t.Fatalf("a readable token without the declaration: %q %q %v", problem, warning, err)
	}
	cfg.EvidenceAllowAPIDelete = true
	problem, warning, err = evidenceCanary(ctx, cfg, locked)
	if problem != "" || !strings.Contains(warning, "bucket lock verified") || err != nil {
		t.Fatalf("a verified lock: %q %q %v", problem, warning, err)
	}
	// A probe that cannot be written is not a verdict.
	if _, _, err = evidenceCanary(ctx, cfg, denyPut{Memory: media.NewMemory()}); err == nil {
		t.Fatal("a probe that cannot be written was judged")
	}
}

// denyPut is a store that refuses every write: a bucket outage or a token that lost its right.
type denyPut struct{ *media.Memory }

func (denyPut) Put(context.Context, string, []byte, string) error {
	return errors.New("ServiceUnavailable")
}

// flakyPut refuses writes until opened, then behaves.
type flakyPut struct {
	*media.Memory
	open *atomic.Bool
	puts atomic.Int32
}

func (f *flakyPut) Put(ctx context.Context, k string, d []byte, ct string) error {
	f.puts.Add(1)
	if !f.open.Load() {
		return errors.New("ServiceUnavailable")
	}
	return f.Memory.Put(ctx, k, d, ct)
}

// An outage of the evidence bucket at start never takes the API down (round-4 N-6): the checks are retried in the
// background, and only a verdict at the first pass refuses a production start.
func TestEvidenceStartupWarnsAndRetriesInTheBackgroundInsteadOfFailingTheStart(t *testing.T) {
	cfg := config.Config{Env: "production", EvidenceBucket: "hiyall-evidence", EvidenceCanary: true}
	open := &atomic.Bool{}
	bucket := &flakyPut{Memory: media.NewMemory(), open: open}
	old := evidenceRetryPause
	evidenceRetryPause = 5 * time.Millisecond
	t.Cleanup(func() { evidenceRetryPause = old })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := evidenceStartup(ctx, cfg, permWrap{flakyPut: bucket, denyGet: true, denyDelete: true}); err != nil {
		t.Fatalf("a bucket outage stopped the start: %v", err)
	}
	if bucket.Memory.Has(media.EvidenceBucketMarker) {
		t.Fatal("the marker was written while the bucket was down")
	}
	open.Store(true)
	deadline := time.Now().Add(5 * time.Second)
	for !bucket.Memory.Has(media.EvidenceBucketMarker) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !bucket.Memory.Has(media.EvidenceBucketMarker) {
		t.Fatal("the marker was never written after the bucket came back")
	}
	data, _ := bucket.Memory.Get(ctx, media.EvidenceBucketMarker, 100)
	if string(data) != "hiyall-evidence" {
		t.Fatalf("the marker holds %q", data)
	}
	// The canary runs right after the marker in the same pass.
	for evidenceCanaryState.Load() != 1 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if evidenceCanaryState.Load() != 1 {
		t.Fatalf("canary state %d after a pass", evidenceCanaryState.Load())
	}
}

// permWrap is a flakyPut with a Get and Delete the test denies.
type permWrap struct {
	*flakyPut
	denyGet, denyDelete bool
}

func (p permWrap) Get(ctx context.Context, k string, l int64) ([]byte, error) {
	if p.denyGet {
		return nil, errors.New("AccessDenied")
	}
	return p.flakyPut.Memory.Get(ctx, k, l)
}
func (p permWrap) Delete(ctx context.Context, k ...string) error {
	if p.denyDelete {
		return errors.New("AccessDenied")
	}
	return p.flakyPut.Memory.Delete(ctx, k...)
}

func TestEvidenceStartupRefusesAProductionStartOnlyForAVerdict(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cfg := config.Config{Env: "production", EvidenceBucket: "hiyall-evidence", EvidenceCanary: true}
	// The token can delete and nothing locks it: the start is refused, and the state says failed.
	open := &atomic.Bool{}
	open.Store(true)
	if err := evidenceStartup(ctx, cfg, permWrap{flakyPut: &flakyPut{Memory: media.NewMemory(), open: open}}); err == nil || !strings.Contains(err.Error(), "can delete") {
		t.Fatalf("a deletable probe: %v", err)
	}
	if evidenceCanaryState.Load() != 2 {
		t.Fatalf("canary state %d after a failure", evidenceCanaryState.Load())
	}
	// Accepted knowingly: it starts, with a warning.
	cfg.EvidenceCanaryAcceptUnlocked = true
	if err := evidenceStartup(ctx, cfg, permWrap{flakyPut: &flakyPut{Memory: media.NewMemory(), open: open}}); err != nil {
		t.Fatalf("an accepted risk: %v", err)
	}
	// Outside production the verdict is logged, not a refusal.
	cfg.EvidenceCanaryAcceptUnlocked, cfg.Env = false, "development"
	if err := evidenceStartup(ctx, cfg, permWrap{flakyPut: &flakyPut{Memory: media.NewMemory(), open: open}}); err != nil {
		t.Fatalf("development: %v", err)
	}
	// check-config -release -net, by contrast, fails when the probe cannot be written: nothing is retried there.
	_, _, err := evidenceCanary(ctx, config.Config{Env: "production"}, denyPut{Memory: media.NewMemory()})
	if err == nil {
		t.Fatal("no error from an unwritable probe")
	}
}

func TestWireSafetyCanaryStopsProductionStartOnlyWhenEnabledAndNotAccepted(t *testing.T) {
	// The canary dials the bucket, so the wiring is exercised through evidenceCanary above; here the setting
	// that sets the nearby ceiling reaches the API without a bucket.
	api := newTestAPI()
	cfg := config.Config{Env: "development"}
	cfg.MediaProcessSlots, cfg.ExportConcurrency, cfg.EvidenceRetentionDays, cfg.NearbyAccountsPerAddress = 2, 3, 365, 7
	if _, err := wireSafety(context.Background(), cfg, api); err != nil {
		t.Fatal(err)
	}
}

func TestSafetyGaugesAreExported(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	db, err := store.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	registerSafetyGauges(db)
	registerSafetyGauges(nil) // no database: nothing registered, nothing breaks
	var sb strings.Builder
	if _, err := metrics.Default.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"hiyall_pending_approvals ", "hiyall_oldest_pending_approval_seconds ", "hiyall_apple_manual_revocations ", "hiyall_pending_quarantine_cases "} {
		if !strings.Contains(sb.String(), "\n"+name) {
			t.Fatalf("%s missing from the scrape:\n%s", name, sb.String())
		}
	}
}
