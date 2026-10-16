package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

// wireSafety applies the trust-and-safety settings that are not part of a feature's own setup: the Nearby
// offset key, the photo processing and export slots, and the evidence store for quarantined originals
// (docs/security/16-csam-and-illegal-content.md). It returns the store whose held objects the API's own
// maintenance may delete: nil when evidence has a bucket of its own, because the API's token there cannot
// delete, and the console's purge job (admin purge-holds) does it instead.
func wireSafety(ctx context.Context, cfg config.Config, api *httpapi.API) (heldObjects media.Store, err error) {
	if cfg.NearbyOffsetKey != nil {
		store.SetNearbyOffsetKey(cfg.NearbyOffsetKey)
	} else {
		slog.Warn("NEARBY_OFFSET_KEY is not set: Nearby offsets use a random key that dies with this process (development only)")
	}
	if cfg.NearbyOffsetKeyPrevious != nil {
		slog.Info("NEARBY_OFFSET_KEY_PREVIOUS is set and ignored: offsets are recomputed under the current key, never looked up")
	}
	registerSafetyGauges(api.Store)
	api.SetNearbyAccountsPerAddress(cfg.NearbyAccountsPerAddress)
	api.SetMediaSlots(cfg.MediaProcessSlots)
	api.SetExportConcurrency(cfg.ExportConcurrency)
	if cfg.MediaEndpoint == "" {
		return nil, nil
	}
	if !cfg.EvidenceSeparate() {
		if cfg.Env == "production" {
			slog.Warn("quarantined photos are kept in the media bucket, where this API's token can delete them (EVIDENCE_ALLOW_SHARED_BUCKET=true)")
		}
		api.SetEvidence(nil, cfg.EvidenceRetentionDays)
		return api.Media, nil
	}
	// The API's token for the evidence bucket is write-only: it never reads or deletes, and never creates the bucket.
	evidence, err := media.NewS3(ctx, media.S3Config{Endpoint: cfg.EvidenceEndpoint, AccessKey: cfg.EvidenceAccessKey, SecretKey: cfg.EvidenceSecretKey, Bucket: cfg.EvidenceBucket, Region: cfg.EvidenceRegion, Secure: cfg.EvidenceSecure, NoCreate: true})
	if err != nil {
		return nil, errors.New("evidence storage unavailable; check EVIDENCE_* configuration")
	}
	if cfg.EvidenceCanary {
		problem, warning, cerr := evidenceCanary(ctx, cfg, evidence)
		switch {
		case problem != "" && cfg.Env == "production":
			return nil, errors.New(problem)
		case problem != "":
			slog.Warn(problem)
		case warning != "":
			slog.Warn(warning)
		case cerr == nil:
			slog.Info("evidence token canary passed: the API's evidence credential can write but not read or delete")
		}
		if cerr != nil {
			return nil, cerr
		}
	}
	api.SetEvidence(evidence, cfg.EvidenceRetentionDays)
	slog.Info("quarantined originals go to the evidence bucket", "bucket", cfg.EvidenceBucket, "retentionDays", cfg.EvidenceRetentionDays)
	return nil, nil
}

// evidenceCanary probes the API's evidence credential (media.EvidenceCanary) and judges it. problem is a refusal:
// the token can read or delete evidence and the owner has not accepted that. warning is the accepted case
// (EVIDENCE_ALLOW_API_DELETE=true: R2 tokens cannot be write-only, and a bucket-lock rule on the evidence bucket
// is what protects the objects). err means the probe could not be written at all.
func evidenceCanary(ctx context.Context, cfg config.Config, evidence media.Store) (problem, warning string, err error) {
	probe, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	res, err := media.EvidenceCanary(probe, evidence)
	if err != nil {
		return "", "", err
	}
	if res.WriteOnly() {
		return "", "", nil
	}
	can := []string{}
	if res.CanRead {
		can = append(can, "read")
	}
	if res.CanDelete {
		can = append(can, "delete")
	}
	what := strings.Join(can, " and ")
	if cfg.EvidenceAllowAPIDelete {
		return "", "EVIDENCE_ALLOW_API_DELETE=true: the API's evidence token can " + what + " objects in the evidence bucket (probe " + res.Key + "). This is accepted only with a bucket-lock retention rule on the evidence bucket (docs/deployment/10-deploy-guide.md); verify that the probe object is still there", nil
	}
	return "the API's evidence token can " + what + " objects in the evidence bucket, so a compromised API could destroy evidence. Scope the token to write only, or put a bucket-lock retention rule on the bucket and set EVIDENCE_ALLOW_API_DELETE=true to accept the remaining risk", "", nil
}

// registerSafetyGauges exports the two-person and quarantine queues so an alert can page a person (round-3 audit
// API-5): hiyall_pending_approvals (proposals waiting for a second administrator), the age of the oldest, the
// Sign in with Apple revocations an operator still has to do by hand, and quarantine cases left 'pending'. The
// numbers come from safety_queue_stats, which the API role may run and which returns counts only; they are read
// at scrape time and cached for 15 seconds. A database that cannot answer reports nothing.
func registerSafetyGauges(db *store.Store) {
	if db == nil {
		return
	}
	var mu sync.Mutex
	var cached store.QueueStats
	var at time.Time
	read := func() (store.QueueStats, bool) {
		mu.Lock()
		defer mu.Unlock()
		if time.Since(at) < 15*time.Second {
			return cached, true
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		q, err := db.SafetyQueueStats(ctx)
		if err != nil {
			return cached, false
		}
		cached, at = q, time.Now()
		return q, true
	}
	metrics.NewGaugeFunc("hiyall_pending_approvals", "Two-person proposals (evidence clear, hold release, legal-hold lift, administrator promotion) waiting for a second administrator.", func() float64 {
		q, _ := read()
		return float64(q.PendingApprovals)
	})
	metrics.NewGaugeFunc("hiyall_oldest_pending_approval_seconds", "Age of the oldest proposal still waiting for a second administrator (0 when none).", func() float64 {
		q, _ := read()
		return q.OldestPendingSeconds
	})
	metrics.NewGaugeFunc("hiyall_apple_manual_revocations", "Sign in with Apple authorizations of deleted accounts that an operator still has to revoke by hand.", func() float64 {
		q, _ := read()
		return float64(q.ManualAppleRevokes)
	})
	metrics.NewGaugeFunc("hiyall_pending_quarantine_cases", "Quarantine cases still pending (evidence objects not confirmed); the console sweeps them after an hour.", func() float64 {
		q, _ := read()
		return float64(q.PendingCases)
	})
}
