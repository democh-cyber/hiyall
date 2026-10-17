package main

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"sync"
	"sync/atomic"
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
	// The marker names this bucket for the console (media.EvidenceBucketMarker), and the canary proves what the token can
	// do. Neither may take every node down while the bucket is unreachable: only a verdict (the token can delete and
	// nothing locks it) refuses a production start; a write that fails is retried in the background.
	if err := evidenceStart(ctx, cfg, evidence); err != nil {
		return nil, err
	}
	api.SetEvidence(evidence, cfg.EvidenceRetentionDays)
	slog.Info("quarantined originals go to the evidence bucket", "bucket", cfg.EvidenceBucket, "retentionDays", cfg.EvidenceRetentionDays)
	return nil, nil
}

// evidenceStartup is what the API writes to and asks of the evidence bucket at start.
//
//   - The bucket marker (media.EvidenceBucketMarker, the bucket's name): the console reads it before it sweeps or purges,
//     to prove it looks at the bucket this API writes to.
//   - With EVIDENCE_CANARY, the canary (media.EvidenceCanary).
//
// A verdict at the first pass (the token can delete evidence and no bucket lock stopped the probe) refuses a production
// start. A pass that could not write at all (an R2 outage) does not: it warns and retries in the background with a growing
// pause, so an outage of the bucket never takes every node down at once. After the retries a verdict is logged as an
// error and counted in hiyall_evidence_canary_state; it can no longer stop the start.
func evidenceStartup(ctx context.Context, cfg config.Config, evidence media.Store) error {
	settled, verdict := evidencePass(ctx, cfg, evidence, true)
	if verdict != nil {
		return verdict
	}
	if settled {
		return nil
	}
	go func() {
		pause := evidenceRetryPause
		for attempt := 1; attempt <= 12; attempt++ {
			select {
			case <-ctx.Done():
				return
			case <-time.After(pause):
			}
			if done, _ := evidencePass(ctx, cfg, evidence, false); done {
				slog.Info("evidence bucket checks completed after a retry", "attempt", attempt)
				return
			}
			pause = min(pause*2, 10*time.Minute)
		}
		slog.Warn("evidence bucket checks did not complete after 12 retries: run `api check-config -release -net` and check the bucket and the token")
	}()
	return nil
}

// evidenceStart is evidenceStartup; a variable so the tests of wireSafety do not dial a bucket.
var evidenceStart = evidenceStartup

// evidenceRetryPause is the first pause between background attempts (it doubles up to ten minutes).
var evidenceRetryPause = 30 * time.Second

// evidenceCanaryState is 0 until the canary has answered, 1 when it passed (or only warned), 2 when it found the API's token
// can delete evidence with nothing to stop it.
var evidenceCanaryState atomic.Int32

func init() {
	metrics.NewGaugeFunc("hiyall_evidence_canary_state", "Evidence token canary: 0 not run or not answered yet, 1 passed, 2 FAILED (the API's evidence token can delete evidence and no bucket lock stopped the probe).", func() float64 { return float64(evidenceCanaryState.Load()) })
}

// evidencePass is one attempt. settled says nothing is left to retry. verdict is only returned for the first pass of a
// production start (first true); later it is logged.
func evidencePass(ctx context.Context, cfg config.Config, evidence media.Store, first bool) (settled bool, verdict error) {
	settled = true
	mctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err := evidence.Put(mctx, media.EvidenceBucketMarker, []byte(cfg.EvidenceBucket), "text/plain")
	cancel()
	if err != nil {
		// A bucket lock refuses an overwrite, so the marker an earlier start wrote may simply be locked in: that is
		// why it is retried a bounded number of times, not for ever.
		slog.Warn("evidence bucket marker not written: the console cannot confirm it reads this bucket until it exists", "reason", media.ErrorCode(err))
		settled = false
	}
	if !cfg.EvidenceCanary {
		return settled, nil
	}
	problem, warning, cerr := evidenceCanary(ctx, cfg, evidence)
	switch {
	case cerr != nil:
		slog.Warn("evidence token canary could not run; retrying in the background (the API starts anyway)", "reason", cerr.Error())
		return false, nil
	case problem != "":
		evidenceCanaryState.Store(2)
		if first && cfg.Env == "production" {
			return settled, errors.New(problem)
		}
		slog.Error("ALERT: "+problem, "environment", cfg.Env)
	case warning != "":
		evidenceCanaryState.Store(1)
		slog.Warn(warning)
	default:
		evidenceCanaryState.Store(1)
		slog.Info("evidence token canary passed: the API's evidence credential can write but not read or delete")
	}
	return settled, nil
}

// evidenceCanary probes the API's evidence credential (media.EvidenceCanary) and judges it. problem is a refusal; warning
// an accepted state; err means the probe could not be written at all (the bucket or the token is down: not a verdict).
//
//   - The probe can be DELETED by the API's credential: nothing protects the evidence from a compromised API. It is a
//     problem whatever EVIDENCE_ALLOW_API_DELETE says (that variable declares a bucket lock, and the lock is not there),
//     unless EVIDENCE_CANARY_ACCEPT_UNLOCKED=true, the explicit acceptance of the risk (then a warning).
//   - The delete was refused but the probe can be READ: a compromised API could read evidence. A problem unless
//     EVIDENCE_ALLOW_API_DELETE=true, the owner's statement that the token is the bucket-lock kind of read and write.
//   - The delete was refused and EVIDENCE_ALLOW_API_DELETE=true: the lock is verified (a warning that says so).
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
	if res.CanDelete {
		if cfg.EvidenceCanaryAcceptUnlocked {
			return "", "EVIDENCE_CANARY_ACCEPT_UNLOCKED=true: the API's evidence token CAN delete objects in the evidence bucket and nothing stops it (probe " + res.Key + " was deleted). Accepted knowingly; put a bucket-lock retention rule on the evidence bucket (docs/deployment/10-deploy-guide.md)", nil
		}
		declared := ""
		if cfg.EvidenceAllowAPIDelete {
			declared = " EVIDENCE_ALLOW_API_DELETE=true declares a bucket lock, but the probe object could be deleted: the lock does not exist, or its rule does not cover canary/."
		}
		return "the API's evidence token can delete objects in the evidence bucket and nothing stopped the probe, so a compromised API could destroy evidence." + declared +
			" Scope the token to write only, or put a bucket-lock retention rule on the whole bucket (including canary/); EVIDENCE_CANARY_ACCEPT_UNLOCKED=true accepts the risk knowingly", "", nil
	}
	// Delete refused. Reading is still a risk the owner has to have accepted.
	if cfg.EvidenceAllowAPIDelete {
		return "", "bucket lock verified: the API's evidence token cannot delete the probe object (" + res.Key + "); it CAN read objects in the evidence bucket, which R2 tokens cannot avoid. The probe is kept by the lock", nil
	}
	return "the API's evidence token can read objects in the evidence bucket, so a compromised API could read evidence. Scope the token to write only, or set EVIDENCE_ALLOW_API_DELETE=true to declare a bucket-lock retention rule (the canary verified that a delete is refused)", "", nil
}

// registerSafetyGauges exports the two-person and quarantine queues so an alert can page a person (round-3 audit
// API-5): hiyall_pending_approvals (proposals waiting for a second administrator), the age of the oldest, the
// Sign in with Apple revocations an operator still has to do by hand, and quarantine cases left 'pending'. The
// numbers come from safety_queue_stats, which the API role may run and which returns counts only; they are read
// at scrape time and cached for 15 seconds. A database that cannot answer (an error, a missing EXECUTE grant)
// reports NaN, never the last value or a zero: a zero would read as "queue empty" to an alert that is the only
// thing watching for a stuck approval (round-4 audit N1). The alert rules treat NaN as an unanswered question.
func registerSafetyGauges(db *store.Store) {
	if db == nil {
		return
	}
	var mu sync.Mutex
	var cached store.QueueStats
	var cachedOK bool
	var at time.Time
	// The answer, or its failure, is kept for 15 seconds, so the four gauges of one scrape cost one query.
	read := func() (store.QueueStats, bool) {
		mu.Lock()
		defer mu.Unlock()
		if !at.IsZero() && time.Since(at) < 15*time.Second {
			return cached, cachedOK
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		q, err := db.SafetyQueueStats(ctx)
		cached, cachedOK, at = q, err == nil, time.Now()
		return cached, cachedOK
	}
	value := func(pick func(store.QueueStats) float64) func() float64 {
		return func() float64 {
			q, ok := read()
			if !ok {
				return math.NaN()
			}
			return pick(q)
		}
	}
	metrics.NewGaugeFunc("hiyall_pending_approvals", "Two-person proposals (evidence clear, hold release, legal-hold lift, administrator promotion) waiting for a second administrator.", value(func(q store.QueueStats) float64 { return float64(q.PendingApprovals) }))
	metrics.NewGaugeFunc("hiyall_oldest_pending_approval_seconds", "Age of the oldest proposal still waiting for a second administrator (0 when none).", value(func(q store.QueueStats) float64 { return q.OldestPendingSeconds }))
	metrics.NewGaugeFunc("hiyall_apple_manual_revocations", "Support-scheduled deletions of members with Sign in with Apple whose member an operator still has to tell to remove Hiyall in Apple ID settings (nobody at Hiyall can revoke it for them).", value(func(q store.QueueStats) float64 { return float64(q.ManualAppleRevokes) }))
	metrics.NewGaugeFunc("hiyall_pending_quarantine_cases", "Quarantine cases still pending (evidence objects not confirmed); the console sweeps them after an hour.", value(func(q store.QueueStats) float64 { return float64(q.PendingCases) }))
}
