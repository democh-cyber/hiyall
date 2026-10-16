package admin

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Evidence sweep, approval expiry and the operator's Apple revocation list (round-3 audit API-1, API-5, API-6,
// API-7). The API writes a quarantine case first, as 'pending', and the evidence objects second; this sweep, which
// can read the evidence bucket (the API cannot), finishes what a crash or a failed write left behind:
//
//   - a pending case older than an hour whose objects are all present is opened;
//   - one with an object missing is dropped (the case row, with an audit entry; the upload is marked deleted and a
//     suspension a match caused stays);
//   - hold/ objects older than an hour that no case names are LISTED for an operator (GET
//     /admin/v1/evidence/orphans, and a warning in the log). They are never deleted by the sweep: someone decides.

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

// OrphanReport is the result of the last sweep's orphan check.
type OrphanReport struct {
	CheckedAt *time.Time `json:"checkedAt"`
	Items     []Orphan   `json:"items"`
	// Complete is false when the bucket listing or the case lookup failed, or the list was capped.
	Complete bool `json:"complete"`
}

type sweepState struct {
	mu     sync.Mutex
	report OrphanReport
	// lastKey is the sorted key list last written to the audit log, so a standing orphan is reported once, not hourly.
	lastKey string
}

// EvidenceOrphans returns the orphan list of the last sweep.
func (s *Service) EvidenceOrphans() OrphanReport {
	s.sweep.mu.Lock()
	defer s.sweep.mu.Unlock()
	r := s.sweep.report
	if r.Items == nil {
		r.Items = []Orphan{}
	}
	return r
}

// SweepEvidence does one pass: pending cases first, then the orphan listing. It returns how many cases it opened
// or dropped. Without a read credential for the evidence bucket it does nothing.
func (s *Service) SweepEvidence(ctx context.Context) (int64, error) {
	reader := s.evidenceReader()
	if reader == nil {
		return 0, nil
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
	report := OrphanReport{CheckedAt: &now, Items: []Orphan{}, Complete: false}
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
				report.Items = append(report.Items, Orphan{Key: o.Key, MediaID: id, LastModified: o.LastModified})
			}
		}
	}
	report.Complete = len(objects) < 5000
	keys := make([]string, len(report.Items))
	for i, o := range report.Items {
		keys[i] = o.Key
	}
	fingerprint := strings.Join(keys, "\n")
	s.sweep.mu.Lock()
	changed := fingerprint != s.sweep.lastKey
	s.sweep.report, s.sweep.lastKey = report, fingerprint
	s.sweep.mu.Unlock()
	if len(report.Items) > 0 && changed {
		slog.Warn("evidence objects older than an hour have no case: review them in the console (Evidence orphans)", "count", len(report.Items))
		_ = insertAudit(ctx, s.Pool, AuditEntry{Actor: sweepActor, Action: "evidence_orphans_found", TargetType: "evidence", TargetID: "hold/",
			Reason: "objects under hold/ with no case row", Detail: map[string]any{"count": len(report.Items), "first": report.Items[0].Key}})
	}
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
	}
}

// ---- the operator's lists

func (s *Server) routeSafety() {
	s.handle("GET", "/admin/v1/apple-revocations", RoleAdmin, s.listAppleRevocations)
	s.handle("POST", "/admin/v1/apple-revocations/{id}/revoked", RoleAdmin, s.markAppleRevoked)
	s.handle("GET", "/admin/v1/evidence/orphans", RoleAdmin, s.listEvidenceOrphans)
}

// listAppleRevocations shows the Sign in with Apple authorizations of deleted accounts that an operator has to
// revoke by hand in Apple's console (the app could not get a code, or support scheduled the deletion). Audited.
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
	s.ok(w, r, map[string]any{"items": items})
}

// markAppleRevoked records that the operator revoked the authorization in Apple's console and removes the row; the
// audit entry is written in the same transaction, so a row is never removed unrecorded.
func (s *Server) markAppleRevoked(w http.ResponseWriter, r *http.Request, p *Principal) {
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
	err = s.svc.Store.MarkAppleRevoked(r.Context(), id, func(ctx context.Context, tx pgx.Tx, c store.AppleRevocationCase) error {
		opID := p.Operator.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &opID, Actor: p.Operator.Email, Action: "apple_revocation_done", TargetType: "user", TargetID: c.UserID, Reason: reason, IP: p.IP,
			Detail: map[string]any{"revocationId": c.RevocationID, "issuer": c.Issuer, "createdAt": c.CreatedAt}})
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"revocationId": id, "done": true})
}

func (s *Server) listEvidenceOrphans(w http.ResponseWriter, r *http.Request, p *Principal) {
	if err := s.audited(r.Context(), p, "evidence_orphans_view", "evidence", "hold/", nil); err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, s.svc.EvidenceOrphans())
}
