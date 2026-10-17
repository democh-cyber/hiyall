package admin

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Evidence sweep, approval expiry and the operator's Apple list (round-3 audit API-1, API-5, API-6, API-7, round-4
// N-4, N-7, N-12). The API writes a quarantine case first, as 'pending', and the evidence objects second; this sweep,
// which can read the evidence bucket (the API cannot), finishes what a crash or a failed write left behind:
//
//   - a pending case older than an hour whose objects are all present is opened;
//   - a FLAGGED one with an object missing is dropped (the case row, with an audit entry; the upload is marked
//     deleted), but only after EvidenceProbe proved this console reads the bucket the API writes to. A case made for a
//     scanner MATCH is never dropped, whatever the bucket says: it is kept and reported loudly for an operator (a
//     misconfigured console must not be able to erase the record of a match);
//   - hold/ objects older than an hour that no case names are LISTED for an operator (GET
//     /admin/v1/evidence/orphans, answered from the database so every console node says the same, and a warning in
//     the log). They are never deleted by the sweep: someone decides.
//
// When the probe fails the sweep and the hold purge do nothing and say so in the log.

const (
	sweepGrace   = time.Hour
	orphanListed = 500
	sweepActor   = "system:evidence-sweep"
)

// Orphan is an object under hold/ that no case row names.
type Orphan struct {
	Key          string    `json:"key"`
	MediaID      string    `json:"mediaId"`
	LastModified time.Time `json:"lastModified"`
}

// OrphanReport is the result of the last sweep's orphan check (any console node's: it is kept in the database).
type OrphanReport struct {
	CheckedAt *time.Time `json:"checkedAt"`
	Items     []Orphan   `json:"items"`
	// Complete is false when the bucket listing or the case lookup failed, or the list was capped.
	Complete bool `json:"complete"`
}

type sweepState struct {
	mu sync.Mutex
	// alerted are the pending match cases already audited as stuck by this process, so the log line repeats hourly but
	// the audit entry once.
	alerted map[string]bool
}

// EvidenceOrphans returns the orphan list of the last sweep, from the database.
func (s *Service) EvidenceOrphans(ctx context.Context) (OrphanReport, error) {
	stored, err := s.Store.LoadOrphanReport(ctx)
	if err != nil {
		return OrphanReport{Items: []Orphan{}}, err
	}
	r := OrphanReport{CheckedAt: stored.CheckedAt, Complete: stored.Complete, Items: make([]Orphan, len(stored.Items))}
	for i, o := range stored.Items {
		r.Items[i] = Orphan{Key: o.Key, MediaID: o.MediaID, LastModified: o.LastModified}
	}
	return r, nil
}

// ErrEvidenceProbe is returned by the evidence jobs when the console cannot show it reads the bucket the API writes to.
var ErrEvidenceProbe = errors.New("the evidence bucket probe failed")

// EvidenceProbe proves that this console looks at the evidence bucket the API uses: the bucket answers a listing, and the
// marker object the API writes at start (media.EvidenceBucketMarker, holding its EVIDENCE_BUCKET) names the bucket this
// console is configured with (ADMIN_EVIDENCE_BUCKET). Without that, "the objects are missing" could just mean "this is
// the wrong bucket" and a sweep would drop real cases. A console that reads the media bucket (no ADMIN_EVIDENCE_*, a
// development setup) can only check the listing. nil means the evidence jobs may run.
func (s *Service) EvidenceProbe(ctx context.Context) error {
	reader := s.evidenceReader()
	if reader == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if lister, ok := reader.(media.Lister); ok {
		if _, err := lister.List(ctx, media.HoldPrefix, 1); err != nil {
			return fmt.Errorf("%w: the bucket cannot be listed (%s)", ErrEvidenceProbe, media.ErrorCode(err))
		}
	}
	if s.Evidence == nil || s.cfg.EvidenceBucket == "" {
		return nil
	}
	data, err := reader.Get(ctx, media.EvidenceBucketMarker, 512)
	switch {
	case errors.Is(err, media.ErrNotFound):
		return fmt.Errorf("%w: %s is missing, so it is not shown that the API writes to this bucket (start the API: it writes the marker; check ADMIN_EVIDENCE_BUCKET)", ErrEvidenceProbe, media.EvidenceBucketMarker)
	case err != nil:
		return fmt.Errorf("%w: the marker cannot be read (%s)", ErrEvidenceProbe, media.ErrorCode(err))
	}
	if got := strings.TrimSpace(string(data)); got != s.cfg.EvidenceBucket {
		return fmt.Errorf("%w: the API writes evidence to bucket %q but this console reads bucket %q (ADMIN_EVIDENCE_BUCKET)", ErrEvidenceProbe, got, s.cfg.EvidenceBucket)
	}
	return nil
}

// SweepEvidence does one pass: pending cases first, then the orphan listing. It returns how many cases it opened
// or dropped. Without a read credential for the evidence bucket it does nothing.
func (s *Service) SweepEvidence(ctx context.Context) (int64, error) {
	reader := s.evidenceReader()
	if reader == nil {
		return 0, nil
	}
	if err := s.EvidenceProbe(ctx); err != nil {
		slog.Error("evidence sweep skipped: it cannot be shown that this console reads the evidence bucket the API writes to; no case is activated or dropped until it can", "reason", err.Error())
		return 0, err
	}
	cases, err := s.Store.PendingCasesDue(ctx, 50)
	if err != nil {
		return 0, err
	}
	var handled int64
	for _, c := range cases {
		present, known := objectsPresent(ctx, reader, c.OriginalKey, c.FullKey)
		switch {
		case !known:
			continue // the bucket could not be asked: try again next time
		case present:
			if err = s.Store.ActivatePendingCase(ctx, c.CaseID); err != nil {
				return handled, err
			}
			id := c.CaseID
			_ = insertAudit(ctx, s.Pool, AuditEntry{Actor: sweepActor, Action: "pending_case_activated", TargetType: "content_case", TargetID: id,
				Reason: "evidence objects present after an hour", Detail: map[string]any{"mediaId": c.MediaID, "result": c.Result}})
			slog.Warn("pending quarantine case opened by the sweep", "caseId", c.CaseID)
			handled++
		case c.Result != "flagged":
			// A scanner match whose objects are not in the bucket: the record may be the only trace of it. Never dropped
			// here (the database function refuses too); an operator decides.
			s.alertStuckMatch(ctx, c)
		default:
			dropped, derr := s.Store.DropPendingCase(ctx, c.CaseID, sweepActor)
			if derr != nil {
				return handled, derr
			}
			if dropped {
				slog.Warn("pending quarantine case dropped: its evidence objects were never written", "caseId", c.CaseID, "result", c.Result)
				handled++
			}
		}
	}
	s.checkOrphans(ctx, reader)
	return handled, nil
}

// alertStuckMatch reports a pending case made for a scanner match whose evidence objects are missing: loudly in the log
// every run, in the audit log once per process.
func (s *Service) alertStuckMatch(ctx context.Context, c store.PendingCase) {
	slog.Error("ALERT: a pending quarantine case for a scanner MATCH has no evidence objects in the bucket; it is kept for an operator (check the evidence bucket, the API's EVIDENCE_* and the media bucket's upload prefix)", "caseId", c.CaseID, "mediaId", c.MediaID)
	s.sweep.mu.Lock()
	seen := s.sweep.alerted[c.CaseID]
	if s.sweep.alerted == nil {
		s.sweep.alerted = map[string]bool{}
	}
	s.sweep.alerted[c.CaseID] = true
	s.sweep.mu.Unlock()
	if !seen {
		_ = insertAudit(ctx, s.Pool, AuditEntry{Actor: sweepActor, Action: "pending_match_case_stuck", TargetType: "content_case", TargetID: c.CaseID,
			Reason: "a scanner match whose evidence objects are missing is kept, not dropped", Detail: map[string]any{"mediaId": c.MediaID, "userId": c.UserID}})
	}
}

// objectsPresent says whether every non-empty key exists; known is false when the bucket answered with something
// other than found or not found.
func objectsPresent(ctx context.Context, r media.Store, keys ...string) (present, known bool) {
	present = true
	for _, k := range keys {
		if k == "" {
			continue
		}
		if _, err := r.Stat(ctx, k); err != nil {
			if errors.Is(err, media.ErrNotFound) {
				present = false
				continue
			}
			return false, false
		}
	}
	return present, true
}

func (s *Service) checkOrphans(ctx context.Context, reader media.Store) {
	lister, ok := reader.(media.Lister)
	if !ok {
		return
	}
	now := time.Now()
	report := store.OrphanReport{CheckedAt: &now, Items: []store.OrphanItem{}, Complete: false}
	objects, err := lister.List(ctx, media.HoldPrefix, 5000)
	if err != nil {
		slog.Warn("evidence orphan check could not list the bucket", "reason", media.ErrorCode(err))
		return
	}
	byMedia := map[string][]media.ObjectInfo{}
	var ids []string
	for _, o := range objects {
		if now.Sub(o.LastModified) < sweepGrace {
			continue
		}
		// hold/<media id>/original and hold/<media id>/full.jpg
		id := path.Base(path.Dir(o.Key))
		if !domain.IsID(id) {
			id = ""
		}
		if _, seen := byMedia[id]; !seen {
			ids = append(ids, id)
		}
		byMedia[id] = append(byMedia[id], o)
	}
	var lookup []string
	for _, id := range ids {
		if id != "" {
			lookup = append(lookup, id)
		}
	}
	known, err := s.Store.KnownCaseMedia(ctx, lookup)
	if err != nil {
		slog.Warn("evidence orphan check could not look up cases", "reason", err.Error())
		return
	}
	for _, id := range ids {
		if id != "" && known[id] {
			continue
		}
		for _, o := range byMedia[id] {
			if len(report.Items) < orphanListed {
				report.Items = append(report.Items, store.OrphanItem{Key: o.Key, MediaID: id, LastModified: o.LastModified})
			}
		}
	}
	report.Complete = len(objects) < 5000
	// A standing orphan is reported in the audit log when the list changes, not every hour: compared with the stored
	// report, which every console node shares.
	previous, _ := s.Store.LoadOrphanReport(ctx)
	changed := orphanFingerprint(previous.Items) != orphanFingerprint(report.Items)
	if err := s.Store.SaveOrphanReport(ctx, report); err != nil {
		slog.Warn("evidence orphan report not stored", "reason", err.Error())
	}
	if len(report.Items) > 0 && changed {
		slog.Warn("evidence objects older than an hour have no case: review them in the console (Evidence orphans)", "count", len(report.Items))
		_ = insertAudit(ctx, s.Pool, AuditEntry{Actor: sweepActor, Action: "evidence_orphans_found", TargetType: "evidence", TargetID: "hold/",
			Reason: "objects under hold/ with no case row", Detail: map[string]any{"count": len(report.Items), "first": report.Items[0].Key}})
	}
}

func orphanFingerprint(items []store.OrphanItem) string {
	keys := make([]string, len(items))
	for i, o := range items {
		keys[i] = o.Key
	}
	return strings.Join(keys, "\n")
}

// ExpireApprovals marks every proposal past its 24 hours as expired.
func (s *Service) ExpireApprovals(ctx context.Context) (int64, error) {
	return s.Store.ExpireEvidenceApprovals(ctx)
}

// SweepJobs are the console timer's jobs that need no delete credential.
func (s *Service) SweepJobs() []maintenance.Job {
	return []maintenance.Job{
		{Name: "evidence sweep", Run: func(ctx context.Context) (int64, error) { return s.SweepEvidence(ctx) }},
		{Name: "approval expiry", Run: func(ctx context.Context) (int64, error) { return s.ExpireApprovals(ctx) }},
		// 'member_informed' Apple records are kept for 90 days, then removed (round-4 N-4).
		{Name: "apple record prune", Run: func(ctx context.Context) (int64, error) {
			return s.Store.PruneAppleRecords(ctx, store.AppleRecordRetentionDays)
		}},
	}
}

// ---- the operator's lists

func (s *Server) routeSafety() {
	s.handle("GET", "/admin/v1/apple-revocations", RoleAdmin, s.listAppleRevocations)
	s.handle("POST", "/admin/v1/apple-revocations/{id}/acknowledge", RoleAdmin, s.acknowledgeAppleRevocation)
	s.handle("GET", "/admin/v1/evidence/orphans", RoleAdmin, s.listEvidenceOrphans)
}

// listAppleRevocations shows the Sign in with Apple records of deleted accounts. Nobody at Hiyall can revoke an
// authorization for a member (Apple's revoke call needs the member's own token), so a record is about telling the
// member: 'member_informed' means the app already told them to remove Hiyall in Apple ID settings (kept 90 days, nothing
// to do), 'manual' means support scheduled the deletion and an operator has to tell the member, then acknowledge it.
// Audited.
func (s *Server) listAppleRevocations(w http.ResponseWriter, r *http.Request, p *Principal) {
	if err := s.audited(r.Context(), p, "apple_revocations_view", "apple_revocation", "", nil); err != nil {
		s.fail(w, r, err)
		return
	}
	items, err := s.svc.Store.ManualAppleRevocations(r.Context(), 200)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"items": items, "memberAction": "Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID"})
}

// acknowledgeAppleRevocation records that an operator dealt with a record (told the member, for a 'manual' one) and
// removes it; apple_revocation_acknowledge writes the audit entry in the same transaction, so a row is never removed
// unrecorded.
func (s *Server) acknowledgeAppleRevocation(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body reasonBody
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	reason, err := Reason(body.Reason)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if _, err = s.svc.Store.AcknowledgeAppleRevocation(safetyCtx(r, p), id, p.Operator.ID, reason); err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"revocationId": id, "acknowledged": true})
}

func (s *Server) listEvidenceOrphans(w http.ResponseWriter, r *http.Request, p *Principal) {
	if err := s.audited(r.Context(), p, "evidence_orphans_view", "evidence", "hold/", nil); err != nil {
		s.fail(w, r, err)
		return
	}
	report, err := s.svc.EvidenceOrphans(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, report)
}
