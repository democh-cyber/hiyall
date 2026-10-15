package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"hiyall/services/api/internal/domain"
)

// Two-person control over evidence (audit SAFE-1, LEGAL-2). Clearing a quarantine case, releasing an evidence
// hold and lifting a legal hold each take a proposal by one administrator and an approval by a different one,
// within ApprovalTTL. Both are audited by the console in the transaction that records them, and the database
// refuses an approval by the proposer (evidence_approvals_two_people). Nothing here deletes evidence.

// ApprovalTTL is how long a proposal stays open.
const ApprovalTTL = 24 * time.Hour

// Evidence step kinds.
const (
	StepClear         = "clear"
	StepRelease       = "release"
	StepLegalHoldLift = "legal_hold_lift"
)

var (
	// ErrApprovalRequired is answered by the single-operator routes that used to clear a case or release a hold.
	ErrApprovalRequired = &domain.PolicyError{Status: 409, Code: "APPROVAL_REQUIRED", Message: "This needs two administrators: one proposes it and a different one approves it"}
	// ErrLegalHoldLiftRequiresApproval refuses legalHold:false on a plain resolution.
	ErrLegalHoldLiftRequiresApproval = &domain.PolicyError{Status: 422, Code: "LEGAL_HOLD_APPROVAL_REQUIRED", Message: "A legal hold is lifted only through a proposal that a second administrator approves, with counsel's reference"}
	// ErrSameOperator refuses an approval by the proposer.
	ErrSameOperator = &domain.PolicyError{Status: 403, Code: "SECOND_APPROVER_REQUIRED", Message: "A different administrator has to approve this"}
	// ErrProposalPending is a second open proposal of the same kind for the case.
	ErrProposalPending = &domain.PolicyError{Status: 409, Code: "PROPOSAL_PENDING", Message: "There is already an open proposal of this kind for the case"}
	// ErrProposalDecided is a decision on a proposal that is no longer pending.
	ErrProposalDecided = &domain.PolicyError{Status: 409, Code: "PROPOSAL_DECIDED", Message: "This proposal was already decided, withdrawn or has expired"}
	// ErrProposalExpired is a decision after the 24 hours.
	ErrProposalExpired = &domain.PolicyError{Status: 409, Code: "PROPOSAL_EXPIRED", Message: "This proposal expired. Propose it again"}
	// ErrNotProposer refuses withdrawing someone else's proposal.
	ErrNotProposer = &domain.PolicyError{Status: 403, Code: "NOT_PROPOSER", Message: "Only the administrator who proposed this can withdraw it"}
)

// EvidenceApproval is one proposal and what became of it.
type EvidenceApproval struct {
	ApprovalID       string     `json:"approvalId"`
	CaseID           string     `json:"caseId"`
	Kind             string     `json:"kind"`
	Status           string     `json:"status"`
	ProposedBy       string     `json:"proposedBy"`
	ProposedByEmail  string     `json:"proposedByEmail"`
	ProposedAt       time.Time  `json:"proposedAt"`
	Reason           string     `json:"reason"`
	CounselReference string     `json:"counselReference"`
	ExpiresAt        time.Time  `json:"expiresAt"`
	DecidedBy        string     `json:"decidedBy"`
	DecidedByEmail   string     `json:"decidedByEmail"`
	DecidedAt        *time.Time `json:"decidedAt"`
	DecisionReason   string     `json:"decisionReason"`
}

// ApprovalHook runs in the transaction of a proposal or a decision, where the console writes its audit
// entries. subject is the member the case is about.
type ApprovalHook func(ctx context.Context, tx pgx.Tx, a EvidenceApproval, subject string) error

// effectiveStatus reads a pending proposal past its time as expired, without waiting for a write.
const approvalSQL = `SELECT a.approval_id::text,a.case_id::text,a.kind,
 CASE WHEN a.status='pending' AND a.expires_at<=now() THEN 'expired' ELSE a.status END,
 a.proposed_by::text,po.email,a.proposed_at,a.reason,coalesce(a.counsel_reference,''),a.expires_at,
 coalesce(a.decided_by::text,''),coalesce(dop.email,''),a.decided_at,coalesce(a.decision_reason,'')
 FROM evidence_approvals a JOIN operators po ON po.operator_id=a.proposed_by LEFT JOIN operators dop ON dop.operator_id=a.decided_by `

func scanApproval(row pgx.Row) (EvidenceApproval, error) {
	var a EvidenceApproval
	err := row.Scan(&a.ApprovalID, &a.CaseID, &a.Kind, &a.Status, &a.ProposedBy, &a.ProposedByEmail, &a.ProposedAt, &a.Reason, &a.CounselReference, &a.ExpiresAt,
		&a.DecidedBy, &a.DecidedByEmail, &a.DecidedAt, &a.DecisionReason)
	return a, err
}

// EvidenceApprovals lists proposals, newest first: for one case when caseID is set, else all with the status
// ("" for every status; "pending" excludes proposals past their time).
func (s *Store) EvidenceApprovals(ctx context.Context, caseID, status string, limit int) ([]EvidenceApproval, error) {
	var c, st any
	if caseID != "" {
		c = caseID
	}
	if status != "" {
		st = status
	}
	rows, err := s.Pool.Query(ctx, approvalSQL+` WHERE ($1::uuid IS NULL OR a.case_id=$1)
 AND ($2::text IS NULL OR (CASE WHEN a.status='pending' AND a.expires_at<=now() THEN 'expired' ELSE a.status END)=$2)
 ORDER BY a.proposed_at DESC,a.approval_id DESC LIMIT $3`, c, st, limit)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (EvidenceApproval, error) { return scanApproval(row) })
	if out == nil && err == nil {
		out = []EvidenceApproval{}
	}
	return out, mapped(err)
}

// EvidenceApproval loads one proposal.
func (s *Store) EvidenceApproval(ctx context.Context, id string) (EvidenceApproval, error) {
	a, err := scanApproval(s.Pool.QueryRow(ctx, approvalSQL+` WHERE a.approval_id=$1`, id))
	return a, mapped(err)
}

// ProposeEvidenceStep opens a proposal. It refuses at once what could not be approved: clearing a case that
// is not open, releasing a hold that is released or blocked (including by a legal hold, which has to be lifted
// first), lifting a legal hold that is not set. hook is called with the new proposal.
func (s *Store) ProposeEvidenceStep(ctx context.Context, caseID, kind, operatorID, reason, counselRef string, hook ApprovalHook) (EvidenceApproval, error) {
	var out EvidenceApproval
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var status, user string
		var legal bool
		var released *time.Time
		if err := tx.QueryRow(ctx, `SELECT status,user_id::text,legal_hold,released_at FROM content_cases WHERE case_id=$1 FOR UPDATE`, caseID).Scan(&status, &user, &legal, &released); err != nil {
			return mapped(err)
		}
		switch kind {
		case StepClear:
			if status != "open" {
				return ErrCaseClosed
			}
		case StepRelease:
			if released != nil {
				return ErrHoldReleased
			}
			var blocker *string
			if err := tx.QueryRow(ctx, `SELECT hold_release_blocker($1)`, caseID).Scan(&blocker); err != nil {
				return err
			}
			if blocker != nil {
				return errHoldBlocked(*blocker)
			}
		case StepLegalHoldLift:
			if !legal {
				return ErrCaseClosed
			}
			if strings.TrimSpace(counselRef) == "" {
				return &domain.ValidationError{Field: "counselReference", Message: "name counsel's instruction (a name, date or reference)"}
			}
		default:
			return &domain.ValidationError{Field: "kind", Message: "must be clear, release or legal_hold_lift"}
		}
		// A proposal past its time frees the slot for a new one.
		if _, err := tx.Exec(ctx, `UPDATE evidence_approvals SET status='expired' WHERE case_id=$1 AND kind=$2 AND status='pending' AND expires_at<=now()`, caseID, kind); err != nil {
			return err
		}
		id := newID()
		if _, err := tx.Exec(ctx, `INSERT INTO evidence_approvals(approval_id,case_id,kind,proposed_by,reason,counsel_reference,expires_at)
 VALUES($1,$2,$3,$4,$5,nullif($6,''),now()+make_interval(secs=>$7::double precision))`, id, caseID, kind, operatorID, reason, strings.TrimSpace(counselRef), ApprovalTTL.Seconds()); err != nil {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "23505" {
				return ErrProposalPending
			}
			return mapped(err)
		}
		a, err := scanApproval(tx.QueryRow(ctx, approvalSQL+` WHERE a.approval_id=$1`, id))
		if err != nil {
			return err
		}
		out = a
		if hook != nil {
			return hook(ctx, tx, a, user)
		}
		return nil
	})
	return out, err
}

// Decisions on a proposal.
const (
	DecisionApprove  = "approve"
	DecisionReject   = "reject"
	DecisionWithdraw = "withdraw"
)

// DecideEvidenceStep approves, rejects or withdraws a proposal. Approving applies the step in the same
// transaction (clear the case, release the hold, lift the legal hold), checking again that it still can be.
// The approver must not be the proposer; only the proposer withdraws. A proposal past its 24 hours is marked
// expired and refused with ErrProposalExpired. hook is called with the decided proposal.
func (s *Store) DecideEvidenceStep(ctx context.Context, approvalID, operatorID, operatorEmail, decision, reason string, hook ApprovalHook) (EvidenceApproval, error) {
	var out EvidenceApproval
	expired := false
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		expired = false
		var caseID, kind, status, proposer, note string
		var counsel *string
		var open bool
		if err := tx.QueryRow(ctx, `SELECT case_id::text,kind,status,proposed_by::text,reason,counsel_reference,expires_at>now() FROM evidence_approvals WHERE approval_id=$1 FOR UPDATE`, approvalID).
			Scan(&caseID, &kind, &status, &proposer, &note, &counsel, &open); err != nil {
			return mapped(err)
		}
		if status != "pending" {
			return ErrProposalDecided
		}
		if !open {
			expired = true
			_, err := tx.Exec(ctx, `UPDATE evidence_approvals SET status='expired' WHERE approval_id=$1`, approvalID)
			return err
		}
		switch decision {
		case DecisionApprove, DecisionReject:
			if operatorID == proposer {
				return ErrSameOperator
			}
		case DecisionWithdraw:
			if operatorID != proposer {
				return ErrNotProposer
			}
		default:
			return &domain.ValidationError{Field: "decision", Message: "must be approve, reject or withdraw"}
		}
		var user, caseStatus string
		var legal bool
		var released *time.Time
		if err := tx.QueryRow(ctx, `SELECT user_id::text,status,legal_hold,released_at FROM content_cases WHERE case_id=$1 FOR UPDATE`, caseID).Scan(&user, &caseStatus, &legal, &released); err != nil {
			return mapped(err)
		}
		next := map[string]string{DecisionApprove: "approved", DecisionReject: "rejected", DecisionWithdraw: "withdrawn"}[decision]
		if decision == DecisionApprove {
			switch kind {
			case StepClear:
				if caseStatus != "open" {
					return ErrCaseClosed
				}
				if _, err := tx.Exec(ctx, `UPDATE content_cases SET status='cleared',reviewed_by=$2,reviewed_at=now(),resolution_note=$3 WHERE case_id=$1`,
					caseID, operatorEmail, "approved: "+reason+" | proposed: "+note); err != nil {
					return err
				}
			case StepRelease:
				if released != nil {
					return ErrHoldReleased
				}
				var blocker *string
				if err := tx.QueryRow(ctx, `SELECT hold_release_blocker($1)`, caseID).Scan(&blocker); err != nil {
					return err
				}
				if blocker != nil {
					return errHoldBlocked(*blocker)
				}
				if _, err := tx.Exec(ctx, `UPDATE content_cases SET released_at=now(),released_by=$2,release_reason=$3 WHERE case_id=$1`,
					caseID, operatorEmail, "approved: "+reason+" | proposed: "+note); err != nil {
					return err
				}
			case StepLegalHoldLift:
				if !legal {
					return ErrCaseClosed
				}
				if _, err := tx.Exec(ctx, `UPDATE content_cases SET legal_hold=false WHERE case_id=$1`, caseID); err != nil {
					return err
				}
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE evidence_approvals SET status=$2,decided_by=$3,decided_at=now(),decision_reason=$4 WHERE approval_id=$1`, approvalID, next, operatorID, reason); err != nil {
			return mapped(err)
		}
		a, err := scanApproval(tx.QueryRow(ctx, approvalSQL+` WHERE a.approval_id=$1`, approvalID))
		if err != nil {
			return err
		}
		out = a
		if hook != nil {
			return hook(ctx, tx, a, user)
		}
		return nil
	})
	if err == nil && expired {
		return out, ErrProposalExpired
	}
	return out, err
}
