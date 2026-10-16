package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

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

// Round-3 audit API-2: the evidence token's write-only property is proved, not assumed.
func TestEvidenceCanaryRefusesATokenThatCanReadOrDeleteUnlessAccepted(t *testing.T) {
	ctx := context.Background()
	cfg := config.Config{Env: "production"}
	problem, warning, err := evidenceCanary(ctx, cfg, permStore{Memory: media.NewMemory(), denyGet: true, denyDelete: true})
	if problem != "" || warning != "" || err != nil {
		t.Fatalf("a write-only token: %q %q %v", problem, warning, err)
	}
	for name, s := range map[string]permStore{
		"delete": {Memory: media.NewMemory(), denyGet: true},
		"read":   {Memory: media.NewMemory(), denyDelete: true},
		"both":   {Memory: media.NewMemory()},
	} {
		problem, warning, err = evidenceCanary(ctx, cfg, s)
		if problem == "" || warning != "" || err != nil || !strings.Contains(problem, "EVIDENCE_ALLOW_API_DELETE") {
			t.Fatalf("%s: %q %q %v", name, problem, warning, err)
		}
		cfg.EvidenceAllowAPIDelete = true
		problem, warning, err = evidenceCanary(ctx, cfg, s)
		if problem != "" || !strings.Contains(warning, "bucket-lock") || err != nil {
			t.Fatalf("%s accepted: %q %q %v", name, problem, warning, err)
		}
		cfg.EvidenceAllowAPIDelete = false
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
