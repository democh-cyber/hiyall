package main

import (
	"context"
	"testing"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/media"
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
