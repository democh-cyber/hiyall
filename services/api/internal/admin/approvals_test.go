package admin

import (
	"strings"
	"testing"

	"hiyall/services/api/internal/media"
)

// twoAdmins are two different administrators with open sessions.
func (e *env) twoAdmins() (first, second sess) {
	return e.session(e.operator(RoleAdmin)), e.session(e.operator(RoleAdmin))
}

type approvalReply struct {
	Approval struct {
		ApprovalID, Kind, Status, ProposedByEmail, DecidedByEmail, CounselReference string
	}
}

func (e *env) propose(s sess, caseID, kind, reason, counsel string) (reply, approvalReply) {
	e.t.Helper()
	body := map[string]string{"kind": kind, "reason": reason}
	if counsel != "" {
		body["counselReference"] = counsel
	}
	r := e.post(s, "/admin/v1/content-cases/"+caseID+"/proposals", body)
	var out approvalReply
	r.data(&out)
	return r, out
}

func (e *env) decide(s sess, approvalID, decision, reason string) reply {
	e.t.Helper()
	return e.post(s, "/admin/v1/approvals/"+approvalID+"/"+decision, map[string]string{"reason": reason})
}

// clearWithTwoAdmins clears an open case the way the console requires.
func (e *env) clearWithTwoAdmins(caseID, reason string) {
	e.t.Helper()
	a, b := e.twoAdmins()
	r, ap := e.propose(a, caseID, "clear", reason, "")
	if r.status != 201 {
		e.t.Fatalf("propose clear: %d %s", r.status, r.raw)
	}
	if r = e.decide(b, ap.Approval.ApprovalID, "approve", "second look agrees: "+reason); r.status != 200 {
		e.t.Fatalf("approve clear: %d %s", r.status, r.raw)
	}
}

func (e *env) caseState(caseID string) (status string, legal bool, released bool) {
	e.t.Helper()
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT status,legal_hold,released_at IS NOT NULL FROM content_cases WHERE case_id=$1`, caseID).Scan(&status, &legal, &released); err != nil {
		e.t.Fatal(err)
	}
	return
}

// Clearing a case: one administrator proposes, a different one approves, within 24 hours; both are audited.
func TestClearingACaseNeedsTwoAdministrators(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	caseID, _, _ := e.pendingQuarantine(e.member(false), "match", objects)
	one, two := e.twoAdmins()
	mod := e.session(e.operator(RoleModerator))
	const why = "the hash list entry was wrong"

	// A plain resolution can no longer clear, whatever the case looks like.
	if r := e.post(one, "/admin/v1/content-cases/"+caseID+"/resolve", map[string]any{"action": "clear", "reason": why}); r.status != 409 || r.code() != "APPROVAL_REQUIRED" {
		t.Fatalf("direct clear: %d %s", r.status, r.raw)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatalf("a refused clear changed the case to %s", st)
	}
	// Moderators cannot propose, approve or list the queue.
	if r, _ := e.propose(mod, caseID, "clear", why, ""); r.status != 403 {
		t.Fatalf("moderator proposing: %d", r.status)
	}
	if r := e.get(mod, "/admin/v1/approvals"); r.status != 403 {
		t.Fatalf("moderator listing: %d", r.status)
	}
	// Validation.
	if r, _ := e.propose(one, caseID, "clear", "short", ""); r.status != 422 {
		t.Fatalf("short reason: %d", r.status)
	}
	if r, _ := e.propose(one, caseID, "delete", why, ""); r.status != 422 {
		t.Fatalf("bad kind: %d", r.status)
	}
	if r, _ := e.propose(one, "00000000-0000-4000-8000-000000000000", "clear", why, ""); r.status != 404 {
		t.Fatalf("unknown case: %d", r.status)
	}

	r, ap := e.propose(one, caseID, "clear", why, "")
	if r.status != 201 || ap.Approval.Status != "pending" || ap.Approval.Kind != "clear" {
		t.Fatalf("propose: %d %s", r.status, r.raw)
	}
	id := ap.Approval.ApprovalID
	// One open proposal per case and kind.
	if r, _ = e.propose(two, caseID, "clear", why, ""); r.status != 409 || r.code() != "PROPOSAL_PENDING" {
		t.Fatalf("second proposal: %d %s", r.status, r.raw)
	}
	// The proposer cannot approve or reject their own, in the API or in the database.
	for _, decision := range []string{"approve", "reject"} {
		if r = e.decide(one, id, decision, "approving my own proposal"); r.status != 403 || r.code() != "SECOND_APPROVER_REQUIRED" {
			t.Fatalf("self %s: %d %s", decision, r.status, r.raw)
		}
	}
	if _, err := e.db.Pool.Exec(e.ctx, `UPDATE evidence_approvals SET status='approved',decided_by=proposed_by,decided_at=now() WHERE approval_id=$1`, id); err == nil || !strings.Contains(err.Error(), "evidence_approvals_two_people") {
		t.Fatalf("the database let the proposer approve: %v", err)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatalf("case %s before approval", st)
	}
	// Only the proposer withdraws.
	if r = e.decide(two, id, "withdraw", "withdrawing someone else's"); r.status != 403 || r.code() != "NOT_PROPOSER" {
		t.Fatalf("withdraw by another: %d %s", r.status, r.raw)
	}
	// A different administrator approves: the case is cleared and both are on the record.
	if r = e.decide(two, id, "approve", "agreed, the list entry was wrong"); r.status != 200 {
		t.Fatalf("approve: %d %s", r.status, r.raw)
	}
	if st, _, _ := e.caseState(caseID); st != "cleared" {
		t.Fatalf("case %s after approval", st)
	}
	var got approvalReply
	r.data(&got)
	if got.Approval.Status != "approved" || got.Approval.DecidedByEmail == "" || got.Approval.DecidedByEmail == got.Approval.ProposedByEmail {
		t.Fatalf("decision %+v", got.Approval)
	}
	for _, action := range []string{"evidence_proposed", "evidence_approved", "content_case_clear"} {
		if e.auditCount(action, caseID) != 1 {
			t.Fatalf("%s audited %d times", action, e.auditCount(action, caseID))
		}
	}
	var proposedBy, approvedBy string
	e.db.Pool.QueryRow(e.ctx, `SELECT detail->>'proposedBy',detail->>'approvedBy' FROM operator_audit WHERE action='content_case_clear' AND target_id=$1`, caseID).Scan(&proposedBy, &approvedBy)
	if proposedBy == "" || approvedBy == "" || proposedBy == approvedBy {
		t.Fatalf("the clearing record names %q and %q", proposedBy, approvedBy)
	}
	// A decided proposal cannot be decided again, and a closed case cannot be proposed for clearing.
	if r = e.decide(two, id, "approve", "approving again"); r.status != 409 || r.code() != "PROPOSAL_DECIDED" {
		t.Fatalf("again: %d %s", r.status, r.raw)
	}
	if r, _ = e.propose(one, caseID, "clear", why, ""); r.status != 409 || r.code() != "CASE_STATE" {
		t.Fatalf("propose on a cleared case: %d %s", r.status, r.raw)
	}
}

func TestProposalsExpireAfterADayAndCanBeRejectedOrWithdrawn(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	one, two := e.twoAdmins()
	const why = "looks like a false positive"

	_, ap := e.propose(one, caseID, "clear", why, "")
	// 24 hours on, the second administrator is too late; the expiry is recorded and a new proposal is possible.
	e.exec(`UPDATE evidence_approvals SET expires_at=now()-interval '1 minute' WHERE approval_id=$1`, ap.Approval.ApprovalID)
	if r := e.decide(two, ap.Approval.ApprovalID, "approve", "approving too late"); r.status != 409 || r.code() != "PROPOSAL_EXPIRED" {
		t.Fatalf("late approval: %d %s", r.status, r.raw)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatalf("an expired proposal cleared the case: %s", st)
	}
	var status string
	e.db.Pool.QueryRow(e.ctx, `SELECT status FROM evidence_approvals WHERE approval_id=$1`, ap.Approval.ApprovalID).Scan(&status)
	if status != "expired" {
		t.Fatalf("status %s", status)
	}
	// Listed as expired, not pending.
	var pending struct{ Items []struct{ ApprovalID string } }
	e.get(one, "/admin/v1/approvals?status=pending").data(&pending)
	for _, it := range pending.Items {
		if it.ApprovalID == ap.Approval.ApprovalID {
			t.Fatal("an expired proposal is still listed as pending")
		}
	}
	// A pending proposal past its time reads as expired before anything writes it.
	_, ap2 := e.propose(one, caseID, "clear", why, "")
	e.exec(`UPDATE evidence_approvals SET expires_at=now()-interval '1 second' WHERE approval_id=$1`, ap2.Approval.ApprovalID)
	var list struct {
		Items []struct{ ApprovalID, Status string }
	}
	e.get(one, "/admin/v1/content-cases/"+caseID+"/proposals").data(&list)
	seen := false
	for _, it := range list.Items {
		if it.ApprovalID == ap2.Approval.ApprovalID {
			seen = it.Status == "expired"
		}
	}
	if !seen {
		t.Fatalf("expired-but-unwritten proposal not shown as expired: %+v", list.Items)
	}
	// Reject and withdraw.
	_, ap3 := e.propose(one, caseID, "clear", why, "")
	if r := e.decide(two, ap3.Approval.ApprovalID, "reject", "I think this one is real"); r.status != 200 {
		t.Fatalf("reject: %d %s", r.status, r.raw)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatalf("a rejected proposal cleared the case: %s", st)
	}
	_, ap4 := e.propose(two, caseID, "clear", why, "")
	if r := e.decide(two, ap4.Approval.ApprovalID, "withdraw", "changed my mind"); r.status != 200 {
		t.Fatalf("withdraw: %d %s", r.status, r.raw)
	}
	for _, action := range []string{"evidence_rejected", "evidence_withdrawn"} {
		if e.auditCount(action, caseID) != 1 {
			t.Fatalf("%s audited %d times", action, e.auditCount(action, caseID))
		}
	}
	if r := e.decide(one, "not-an-id", "approve", "an id that is not one"); r.status != 404 {
		t.Fatalf("bad id: %d", r.status)
	}
}

// A legal hold is set by confirming or reporting, can never be switched off by a resolution, and is lifted only
// through a proposal with counsel's reference that a second administrator approves.
func TestLegalHoldIsLiftedOnlyByTwoAdministratorsWithCounselsReference(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	caseID, _, _ := e.pendingQuarantine(e.member(false), "match", objects)
	one, two := e.twoAdmins()
	base := "/admin/v1/content-cases/" + caseID

	// 'reported' (and confirm) cannot set legalHold:false; true is fine.
	if r := e.post(one, base+"/resolve", map[string]any{"action": "confirm", "reason": "confirmed as evidence", "legalHold": false}); r.status != 422 || r.code() != "LEGAL_HOLD_APPROVAL_REQUIRED" {
		t.Fatalf("confirm with legalHold false: %d %s", r.status, r.raw)
	}
	if r := e.post(one, base+"/resolve", map[string]any{"action": "reported", "reason": "reported to the authority", "reportReference": "NCMEC-1", "legalHold": false}); r.status != 422 || r.code() != "LEGAL_HOLD_APPROVAL_REQUIRED" {
		t.Fatalf("reported with legalHold false: %d %s", r.status, r.raw)
	}
	if st, legal, _ := e.caseState(caseID); st != "open" || legal {
		t.Fatalf("a refused resolution changed the case: %s %v", st, legal)
	}
	if r := e.post(one, base+"/resolve", map[string]any{"action": "reported", "reason": "reported to the authority", "reportReference": "NCMEC-1", "legalHold": true}); r.status != 200 {
		t.Fatalf("reported: %d %s", r.status, r.raw)
	}
	if _, legal, _ := e.caseState(caseID); !legal {
		t.Fatal("a reported case carries no legal hold")
	}
	// Lifting: counsel's reference is mandatory, in the API and in the table.
	if r, _ := e.propose(one, caseID, "legal_hold_lift", "counsel has closed the matter", ""); r.status != 422 {
		t.Fatalf("lift without counsel's reference: %d %s", r.status, r.raw)
	}
	if _, err := e.db.Pool.Exec(e.ctx, `INSERT INTO evidence_approvals(approval_id,case_id,kind,proposed_by,reason,expires_at)
 SELECT gen_random_uuid(),$1,'legal_hold_lift',operator_id,'no counsel reference',now()+interval '1 day' FROM operators LIMIT 1`, caseID); err == nil || !strings.Contains(err.Error(), "evidence_approvals_counsel") {
		t.Fatalf("the table accepted a lift without counsel's reference: %v", err)
	}
	r, ap := e.propose(one, caseID, "legal_hold_lift", "counsel has closed the matter", "Counsel M. Okafor, email of 2027-02-03")
	if r.status != 201 {
		t.Fatalf("propose lift: %d %s", r.status, r.raw)
	}
	if r = e.decide(one, ap.Approval.ApprovalID, "approve", "approving my own lift"); r.status != 403 {
		t.Fatalf("self approval: %d", r.status)
	}
	if _, legal, _ := e.caseState(caseID); !legal {
		t.Fatal("the hold was lifted before a second administrator approved")
	}
	if r = e.decide(two, ap.Approval.ApprovalID, "approve", "counsel's email confirmed with the sender"); r.status != 200 {
		t.Fatalf("approve lift: %d %s", r.status, r.raw)
	}
	if _, legal, _ := e.caseState(caseID); legal {
		t.Fatal("the hold is still set after both approved")
	}
	var counsel string
	e.db.Pool.QueryRow(e.ctx, `SELECT detail->>'counselReference' FROM operator_audit WHERE action='legal_hold_lift' AND target_id=$1`, caseID).Scan(&counsel)
	if !strings.Contains(counsel, "Okafor") {
		t.Fatalf("counsel's reference is not in the audit entry: %q", counsel)
	}
	// Lifting a hold that is not set is refused.
	if r, _ = e.propose(one, caseID, "legal_hold_lift", "lifting a hold twice", "Counsel M. Okafor"); r.status != 409 {
		t.Fatalf("second lift: %d %s", r.status, r.raw)
	}
}

// Releasing the hold: also two people; a legal hold has to be lifted first; every blocker is checked again when
// the second administrator approves.
func TestReleasingAHoldNeedsTwoAdministratorsAndRechecksTheBlockers(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	uploader := e.member(false)
	caseID, _, _ := e.pendingQuarantine(uploader, "flagged", objects)
	one, two := e.twoAdmins()
	const why = "retention window ended, counsel agrees"

	if r := e.post(one, "/admin/v1/holds/"+caseID+"/release", map[string]string{"reason": why}); r.status != 409 || r.code() != "APPROVAL_REQUIRED" {
		t.Fatalf("direct release: %d %s", r.status, r.raw)
	}
	// An open case cannot even be proposed for release.
	if r, _ := e.propose(one, caseID, "release", why, ""); r.status != 409 || r.code() != "HOLD_CASE_OPEN" {
		t.Fatalf("release of an open case: %d %s", r.status, r.raw)
	}
	e.clearWithTwoAdmins(caseID, "false positive after review")
	e.exec(`UPDATE content_cases SET legal_hold=true WHERE case_id=$1`, caseID)
	if r, _ := e.propose(one, caseID, "release", why, ""); r.status != 409 || r.code() != "HOLD_LEGAL_HOLD" {
		t.Fatalf("release under a legal hold: %d %s", r.status, r.raw)
	}
	e.exec(`UPDATE content_cases SET legal_hold=false WHERE case_id=$1`, caseID)
	r, ap := e.propose(one, caseID, "release", why, "")
	if r.status != 201 {
		t.Fatalf("propose release: %d %s", r.status, r.raw)
	}
	// Between the proposal and the approval an open member report appears: the approval is refused and the
	// proposal stays open (the blocker may go away).
	report := e.report(e.member(false), uploader, "harassment")
	if r = e.decide(two, ap.Approval.ApprovalID, "approve", "approving the release"); r.status != 409 || r.code() != "HOLD_REPORT_OPEN" {
		t.Fatalf("approval with an open report: %d %s", r.status, r.raw)
	}
	if _, _, released := e.caseState(caseID); released {
		t.Fatal("released despite the open report")
	}
	e.exec(`UPDATE reports SET status='dismissed',resolved_at=now() WHERE report_id=$1`, report)
	if r = e.decide(two, ap.Approval.ApprovalID, "approve", "the report was dismissed, approving"); r.status != 200 {
		t.Fatalf("approve release: %d %s", r.status, r.raw)
	}
	if _, _, released := e.caseState(caseID); !released {
		t.Fatal("not released after two approvals")
	}
	if e.auditCount("hold_release", caseID) != 1 || e.auditCount("evidence_proposed", caseID) < 2 {
		t.Fatal("the release was not audited with its proposal")
	}
	if r, _ = e.propose(one, caseID, "release", why, ""); r.status != 409 || r.code() != "HOLD_ALREADY_RELEASED" {
		t.Fatalf("second release: %d %s", r.status, r.raw)
	}
}
