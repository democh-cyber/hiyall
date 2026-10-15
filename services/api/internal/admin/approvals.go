package admin

import (
	"context"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Two-person control over evidence (docs/security/15-admin-console.md, audit SAFE-1 and LEGAL-2).
//
//	POST /admin/v1/content-cases/{id}/proposals   {kind: clear|release|legal_hold_lift, reason, counselReference?}
//	GET  /admin/v1/content-cases/{id}/proposals
//	GET  /admin/v1/approvals?status=pending       every proposal waiting for a second administrator
//	POST /admin/v1/approvals/{id}/approve|reject  {reason}   by a DIFFERENT administrator, within 24 hours
//	POST /admin/v1/approvals/{id}/withdraw        {reason}   by the proposer
//
// Approving applies the step in the same transaction. Every proposal and decision is audited there, with both
// operators' names, so neither can later say the other did it alone. A legal hold is only ever lifted here, with
// counsel's reference.

func (s *Server) approvalHook(p *Principal, action string) store.ApprovalHook {
	return func(ctx context.Context, tx pgx.Tx, a store.EvidenceApproval, subject string) error {
		opID := p.Operator.ID
		detail := map[string]any{"approvalId": a.ApprovalID, "kind": a.Kind, "subjectId": subject, "proposedBy": a.ProposedByEmail, "status": a.Status}
		if a.CounselReference != "" {
			detail["counselReference"] = a.CounselReference
		}
		reason := a.Reason
		if a.DecidedAt != nil {
			reason = a.DecisionReason
			detail["decidedBy"] = a.DecidedByEmail
		}
		if err := insertAudit(ctx, tx, AuditEntry{OperatorID: &opID, Actor: p.Operator.Email, Action: action, TargetType: "content_case", TargetID: a.CaseID, Reason: reason, IP: p.IP, Detail: detail}); err != nil {
			return err
		}
		if action != "evidence_approved" {
			return nil
		}
		// The step itself, under the name it always had, so the audit log reads the same as before and now
		// carries both operators.
		underlying := map[string]string{store.StepClear: "content_case_clear", store.StepRelease: "hold_release", store.StepLegalHoldLift: "legal_hold_lift"}[a.Kind]
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &opID, Actor: p.Operator.Email, Action: underlying, TargetType: "content_case", TargetID: a.CaseID,
			Reason: a.DecisionReason, IP: p.IP, Detail: map[string]any{"subjectId": subject, "approvalId": a.ApprovalID, "proposedBy": a.ProposedByEmail, "approvedBy": a.DecidedByEmail, "proposalReason": a.Reason, "counselReference": a.CounselReference}})
	}
}

func (s *Server) proposeEvidenceStep(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body struct {
		Kind             string `json:"kind"`
		Reason           string `json:"reason"`
		CounselReference string `json:"counselReference"`
	}
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	reason, err := Reason(body.Reason)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	counsel := strings.TrimSpace(body.CounselReference)
	switch {
	case !domain.IsID(id):
		s.fail(w, r, domain.ErrNotFound)
		return
	case body.Kind != store.StepClear && body.Kind != store.StepRelease && body.Kind != store.StepLegalHoldLift:
		s.fail(w, r, &domain.ValidationError{Field: "kind", Message: "must be clear, release or legal_hold_lift"})
		return
	case body.Kind == store.StepLegalHoldLift && (len(counsel) < 3 || len(counsel) > 200):
		s.fail(w, r, &domain.ValidationError{Field: "counselReference", Message: "name counsel's instruction: who, and a date or reference (3 to 200 characters)"})
		return
	case len(counsel) > 200:
		s.fail(w, r, &domain.ValidationError{Field: "counselReference", Message: "at most 200 characters"})
		return
	}
	a, err := s.svc.Store.ProposeEvidenceStep(r.Context(), id, body.Kind, p.Operator.ID, reason, counsel, s.approvalHook(p, "evidence_proposed"))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.write(w, r, http.StatusCreated, map[string]any{"success": true, "data": map[string]any{"approval": a}})
}

func (s *Server) listCaseProposals(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	items, err := s.svc.Store.EvidenceApprovals(r.Context(), id, "", 50)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"items": items, "operatorId": p.Operator.ID})
}

func (s *Server) listApprovals(w http.ResponseWriter, r *http.Request, p *Principal) {
	status := r.URL.Query().Get("status")
	switch status {
	case "", "pending", "approved", "rejected", "expired", "withdrawn":
	default:
		s.fail(w, r, &domain.ValidationError{Field: "status", Message: "must be pending, approved, rejected, expired or withdrawn"})
		return
	}
	items, err := s.svc.Store.EvidenceApprovals(r.Context(), "", status, 50)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"items": items, "operatorId": p.Operator.ID})
}

func (s *Server) decideEvidenceStep(decision, action string) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request, p *Principal) {
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
		a, err := s.svc.Store.DecideEvidenceStep(r.Context(), id, p.Operator.ID, p.Operator.Email, decision, reason, s.approvalHook(p, action))
		if err != nil {
			s.fail(w, r, err)
			return
		}
		s.ok(w, r, map[string]any{"approval": a})
	}
}

func (s *Server) approveEvidenceStep(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.decideEvidenceStep(store.DecisionApprove, "evidence_approved")(w, r, p)
}

func (s *Server) rejectEvidenceStep(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.decideEvidenceStep(store.DecisionReject, "evidence_rejected")(w, r, p)
}

func (s *Server) withdrawEvidenceStep(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.decideEvidenceStep(store.DecisionWithdraw, "evidence_withdrawn")(w, r, p)
}
