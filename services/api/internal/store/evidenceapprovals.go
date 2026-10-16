package store

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"hiyall/services/api/internal/domain"
)

// Two-person control over evidence (audit SAFE-1, LEGAL-2, round-3 API-5). Clearing a quarantine case, releasing an
// evidence hold, lifting a legal hold and making an operator an administrator each take a proposal by one
// administrator and an approval by a different one, within ApprovalTTL. Both are audited by the console in the
// transaction that records them. The transitions themselves are SECURITY DEFINER functions (migration 0043:
// evidence_propose, evidence_decide, ...) that the console role alone may execute and that enforce, in SQL,
// proposer <> approver, the legal-hold rules and the counsel reference format: the console role has no UPDATE
// on cases, proposals or operator roles, so none of it can be skipped from Go. Nothing here deletes evidence.

// ApprovalTTL is how long a proposal stays open.
const ApprovalTTL = 24 * time.Hour

// Evidence step kinds.
const (
	StepClear         = "clear"
	StepRelease       = "release"
	StepLegalHoldLift = "legal_hold_lift"
	// StepPromoteAdmin makes an operator an administrator; the proposal names the operator, not a case.
	StepPromoteAdmin = "promote_admin"
)

// CounselReferencePattern is the form of a counsel reference (also enforced in SQL by safety_counsel_ok).
var CounselReferencePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._/-]{5,119}$`)

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

// EvidenceApproval is one proposal and what became of it. CaseID is empty for an admin promotion, which
// names TargetOperator instead.
type EvidenceApproval struct {
	ApprovalID          string     `json:"approvalId"`
	CaseID              string     `json:"caseId"`
	Kind                string     `json:"kind"`
	Status              string     `json:"status"`
	ProposedBy          string     `json:"proposedBy"`
	ProposedByEmail     string     `json:"proposedByEmail"`
	ProposedAt          time.Time  `json:"proposedAt"`
	Reason              string     `json:"reason"`
	CounselReference    string     `json:"counselReference"`
	ExpiresAt           time.Time  `json:"expiresAt"`
	DecidedBy           string     `json:"decidedBy"`
	DecidedByEmail      string     `json:"decidedByEmail"`
	DecidedAt           *time.Time `json:"decidedAt"`
	DecisionReason      string     `json:"decisionReason"`
	TargetOperator      string     `json:"targetOperator"`
	TargetOperatorEmail string     `json:"targetOperatorEmail"`
}

// ApprovalHook runs in the transaction of a proposal or a decision, where the console writes its audit
// entries. subject is the member the case is about (the operator id for an admin promotion).
type ApprovalHook func(ctx context.Context, tx pgx.Tx, a EvidenceApproval, subject string) error

// SafetyErrorCode is the tag a two-person function raised (SQLSTATE HY001, message "hiyall:CODE"), or "".
func SafetyErrorCode(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "HY001" {
		return strings.TrimPrefix(pe.Message, "hiyall:")
	}
	return ""
}

// Errors only the SQL functions can raise.
var (
	ErrNotAdmin       = &domain.PolicyError{Status: 403, Code: "NOT_ADMIN", Message: "Only an active administrator can do this"}
	ErrNoChange       = &domain.PolicyError{Status: 409, Code: "NO_CHANGE", Message: "The operator is already in that state"}
	ErrTargetDisabled = &domain.PolicyError{Status: 409, Code: "TARGET_DISABLED", Message: "A disabled operator cannot be promoted"}
	ErrLastAdminSQL   = &domain.PolicyError{Status: 409, Code: "LAST_ADMIN", Message: "There must always be at least one active administrator"}
)

// MapSafetyError turns what a two-person function raised into the API's error; any other error is returned as is.
func MapSafetyError(err error) error {
	code := SafetyErrorCode(err)
	if code == "" {
		return mapped(err)
	}
	switch code {
	case "NOT_FOUND":
		return domain.ErrNotFound
	case "CASE_STATE":
		return ErrCaseClosed
	case "HOLD_ALREADY_RELEASED":
		return ErrHoldReleased
	case "PROPOSAL_PENDING":
		return ErrProposalPending
	case "PROPOSAL_DECIDED":
		return ErrProposalDecided
	case "SECOND_APPROVER_REQUIRED":
		return ErrSameOperator
	case "NOT_PROPOSER":
		return ErrNotProposer
	case "APPROVAL_REQUIRED":
		return ErrApprovalRequired
	case "NOT_ADMIN":
		return ErrNotAdmin
	case "NO_CHANGE":
		return ErrNoChange
	case "TARGET_DISABLED":
		return ErrTargetDisabled
	case "LAST_ADMIN":
		return ErrLastAdminSQL
	case "COUNSEL_REFERENCE":
		return &domain.ValidationError{Field: "counselReference", Message: "name counsel's instruction: 6 to 120 characters of letters, digits, spaces and . _ / -, starting with a letter or digit"}
	case "VALIDATION_KIND":
		return &domain.ValidationError{Field: "kind", Message: "must be clear, release or legal_hold_lift"}
	case "VALIDATION_REASON":
		return &domain.ValidationError{Field: "reason", Message: "give a reason"}
	case "VALIDATION_DECISION":
		return &domain.ValidationError{Field: "decision", Message: "must be approve, reject or withdraw"}
	case "VALIDATION_ROLE":
		return &domain.ValidationError{Field: "role", Message: "must be viewer, moderator or admin"}
	case "VALIDATION_REFERENCE":
		return &domain.ValidationError{Field: "reportReference", Message: "record the NCMEC report number or the authority's reference (up to 200 characters)"}
	}
	if strings.HasPrefix(code, "HOLD_") {
		return errHoldBlocked(strings.TrimPrefix(code, "HOLD_"))
	}
	return err
}

// effectiveStatus reads a pending proposal past its time as expired, without waiting for a write.
const approvalSQL = `SELECT a.approval_id::text,coalesce(a.case_id::text,''),a.kind,
 CASE WHEN a.status='pending' AND a.expires_at<=now() THEN 'expired' ELSE a.status END,
 a.proposed_by::text,po.email,a.proposed_at,a.reason,coalesce(a.counsel_reference,''),a.expires_at,
 coalesce(a.decided_by::text,''),coalesce(dop.email,''),a.decided_at,coalesce(a.decision_reason,''),
 coalesce(a.target_operator::text,''),coalesce(top.email,'')
 FROM evidence_approvals a JOIN operators po ON po.operator_id=a.proposed_by LEFT JOIN operators dop ON dop.operator_id=a.decided_by LEFT JOIN operators top ON top.operator_id=a.target_operator `

func scanApproval(row pgx.Row) (EvidenceApproval, error) {
	var a EvidenceApproval
	err := row.Scan(&a.ApprovalID, &a.CaseID, &a.Kind, &a.Status, &a.ProposedBy, &a.ProposedByEmail, &a.ProposedAt, &a.Reason, &a.CounselReference, &a.ExpiresAt,
		&a.DecidedBy, &a.DecidedByEmail, &a.DecidedAt, &a.DecisionReason, &a.TargetOperator, &a.TargetOperatorEmail)
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

// ProposeEvidenceStep opens a proposal through evidence_propose, which refuses at once what could not be
// approved: clearing a case that is not open or is under a legal hold, releasing a hold that is released or
// blocked (including by a legal hold, which has to be lifted first), lifting a legal hold that is not set or
// without a counsel reference of the right form. hook is called with the new proposal.
func (s *Store) ProposeEvidenceStep(ctx context.Context, caseID, kind, operatorID, reason, counselRef string, hook ApprovalHook) (EvidenceApproval, error) {
	var out EvidenceApproval
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var user string
		if err := tx.QueryRow(ctx, `SELECT user_id::text FROM content_cases WHERE case_id=$1`, caseID).Scan(&user); err != nil {
			return mapped(err)
		}
		id := newID()
		if _, err := tx.Exec(ctx, `SELECT evidence_propose($1::uuid,$2::uuid,$3,$4::uuid,$5,$6)`, id, caseID, kind, operatorID, reason, strings.TrimSpace(counselRef)); err != nil {
			return MapSafetyError(err)
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

// ProposeAdminPromotion opens a proposal to make the operator an administrator (operator_promotion_propose). A
// different administrator approves it with DecideEvidenceStep. hook receives the operator id as the subject.
func (s *Store) ProposeAdminPromotion(ctx context.Context, targetOperator, operatorID, reason string, hook ApprovalHook) (EvidenceApproval, error) {
	var out EvidenceApproval
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		id := newID()
		if _, err := tx.Exec(ctx, `SELECT operator_promotion_propose($1::uuid,$2::uuid,$3::uuid,$4)`, id, targetOperator, operatorID, reason); err != nil {
			return MapSafetyError(err)
		}
		a, err := scanApproval(tx.QueryRow(ctx, approvalSQL+` WHERE a.approval_id=$1`, id))
		if err != nil {
			return err
		}
		out = a
		if hook != nil {
			return hook(ctx, tx, a, targetOperator)
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

// DecideEvidenceStep approves, rejects or withdraws a proposal through evidence_decide. Approving applies the
// step in the same transaction (clear the case, release the hold, lift the legal hold, promote the operator),
// checking again that it still can be. The approver must not be the proposer (the function, and the table's
// check constraint, refuse it); only the proposer withdraws. A proposal past its 24 hours is marked expired and
// refused with ErrProposalExpired. hook is called with the decided proposal.
func (s *Store) DecideEvidenceStep(ctx context.Context, approvalID, operatorID, decision, reason string, hook ApprovalHook) (EvidenceApproval, error) {
	var out EvidenceApproval
	expired := false
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		expired = false
		var status string
		if err := tx.QueryRow(ctx, `SELECT evidence_decide($1::uuid,$2::uuid,$3,$4)`, approvalID, operatorID, decision, reason).Scan(&status); err != nil {
			return MapSafetyError(err)
		}
		if status == "expired" {
			expired = true
			return nil
		}
		var subject string
		if err := tx.QueryRow(ctx, `SELECT coalesce(c.user_id::text,a.target_operator::text) FROM evidence_approvals a LEFT JOIN content_cases c ON c.case_id=a.case_id WHERE a.approval_id=$1`, approvalID).Scan(&subject); err != nil {
			return err
		}
		a, err := scanApproval(tx.QueryRow(ctx, approvalSQL+` WHERE a.approval_id=$1`, approvalID))
		if err != nil {
			return err
		}
		out = a
		if hook != nil {
			return hook(ctx, tx, a, subject)
		}
		return nil
	})
	if err == nil && expired {
		return out, ErrProposalExpired
	}
	return out, err
}

// ExpireEvidenceApprovals marks every proposal past its time as expired.
func (s *Store) ExpireEvidenceApprovals(ctx context.Context) (int64, error) {
	var n int64
	err := s.Pool.QueryRow(ctx, `SELECT evidence_expire_due()`).Scan(&n)
	return n, mapped(err)
}

// SetOperatorRole changes an operator's role through operator_set_role. A promotion to administrator is refused
// with ErrApprovalRequired while another administrator is active: it goes through ProposeAdminPromotion. tx is
// the caller's transaction, where the audit entry is written. operatorID is the acting administrator (empty when
// no administrator is active: the bootstrap).
func SetOperatorRole(ctx context.Context, tx pgx.Tx, target, role, operatorID string) error {
	var actor any
	if operatorID != "" {
		actor = operatorID
	}
	if _, err := tx.Exec(ctx, `SELECT operator_set_role($1::uuid,$2,$3::uuid)`, target, role, actor); err != nil {
		return MapSafetyError(err)
	}
	return nil
}
