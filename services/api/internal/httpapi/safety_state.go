package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"sync"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/metrics"
)

// safetyState is the per-node trust-and-safety wiring that cmd/api sets after New: the evidence store for
// quarantined originals, how long their hold lasts, and the export slots (audit SAFE-1, API-9).
type safetyState struct {
	// evidence is where quarantined originals are copied. Its token is write-only. Nil: the media store
	// (development, or EVIDENCE_ALLOW_SHARED_BUCKET=true in production).
	evidence      media.Store
	retentionDays int
	// nearbyAccounts is how many different accounts one source address may search Nearby for in a day
	// (NEARBY_ACCOUNTS_PER_ADDRESS); 0 means domain.DefaultNearbyAccountsPerAddress.
	nearbyAccounts int

	exportOnce  sync.Once
	exportSlots chan struct{}
	exportN     int
}

// SetEvidence points quarantined originals at a bucket of their own (EVIDENCE_BUCKET) and sets how many days
// a new case's evidence is held (EVIDENCE_RETENTION_DAYS; 0 means store.DefaultEvidenceRetentionDays).
func (a *API) SetEvidence(s media.Store, retentionDays int) {
	a.safe.evidence, a.safe.retentionDays = s, retentionDays
}

// SetNearbyAccountsPerAddress sets the per-address ceiling of distinct accounts that may use Nearby in a day.
func (a *API) SetNearbyAccountsPerAddress(n int) { a.safe.nearbyAccounts = n }

func (a *API) nearbyAccountsPerAddress() int {
	if a.safe.nearbyAccounts > 0 {
		return a.safe.nearbyAccounts
	}
	return domain.DefaultNearbyAccountsPerAddress
}

// SetExportConcurrency sets how many data exports this node builds at once (EXPORT_CONCURRENCY, default 3).
// Call it before serving.
func (a *API) SetExportConcurrency(n int) {
	a.safe.exportOnce.Do(func() {})
	a.safe.exportN = max(1, n)
	a.safe.exportSlots = make(chan struct{}, a.safe.exportN)
}

// defaultExportConcurrency is used until SetExportConcurrency says otherwise.
const defaultExportConcurrency = 3

var exportBusy = metrics.NewCounter("hiyall_export_busy_total", "Data exports refused with 503 because every export slot on the node was taken.")

// acquireExportSlot takes an export slot without waiting. release gives it back.
func (a *API) acquireExportSlot() (release func(), ok bool) {
	a.safe.exportOnce.Do(func() {
		if a.safe.exportSlots == nil {
			a.safe.exportSlots = make(chan struct{}, defaultExportConcurrency)
		}
	})
	slots := a.safe.exportSlots
	select {
	case slots <- struct{}{}:
		return func() { <-slots }, true
	default:
		return nil, false
	}
}

// evidenceStore is where a quarantined original is written.
func (a *API) evidenceStore() media.Store {
	if a.safe.evidence != nil {
		return a.safe.evidence
	}
	return a.Media
}

// quarantineCases counts every new quarantine case by the scanner's verdict. Alert on any increase: each one
// is a photo a person must look at (docs/deployment/10-deploy-guide.md, alerting).
var quarantineCases = metrics.NewCounter("hiyall_quarantine_cases_total", "New quarantine cases opened by the upload scanner, by result (flagged or match).", "result")

// quarantineAlert makes a new case impossible to miss: a counter, a warn line and a report to the error
// tracker (Sentry, when configured). It carries ids only, never the image, a hash or the signals.
func (a *API) quarantineAlert(ctx context.Context, caseID, mediaID, result string) {
	quarantineCases.Inc(result)
	slog.Warn("upload quarantined", "caseId", caseID, "mediaId", mediaID, "result", result)
	a.report(ctx, ErrorReport{Method: "SCAN", Route: "quarantine/" + result, Err: errors.New("new quarantine case " + caseID + " (" + result + "): review it in the admin console")})
}
