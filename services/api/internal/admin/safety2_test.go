package admin

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Round-3 audit API-1, API-5, API-6, API-7, API-8 (migration 0043).

// sqlCode runs a statement as the test user and returns the two-person function's tag ("" when it succeeded).
func (e *env) sqlCode(query string, args ...any) string {
	e.t.Helper()
	_, err := e.db.Pool.Exec(e.ctx, query, args...)
	if err == nil {
		return ""
	}
	code := store.SafetyErrorCode(err)
	if code == "" {
		e.t.Fatalf("%s: %v", query, err)
	}
	return code
}

// The console role has no way to write a case, a proposal or an operator's role except the functions.
func TestAdminRoleHasNoDirectWriteOnCasesApprovalsOrRoles(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	adm, api := rolePool(t, "hiyall_admin"), rolePool(t, "hiyall_api")
	ctx := context.Background()
	for _, q := range []string{
		`UPDATE content_cases SET status='cleared'`, `UPDATE content_cases SET legal_hold=false`, `UPDATE content_cases SET hold_until=now()`,
		`DELETE FROM content_cases`, `INSERT INTO content_cases(case_id) VALUES (gen_random_uuid())`,
		`UPDATE evidence_approvals SET status='approved'`, `UPDATE evidence_approvals SET decided_by=proposed_by`, `DELETE FROM evidence_approvals`,
		`INSERT INTO evidence_approvals(approval_id,kind,proposed_by,reason,expires_at) SELECT gen_random_uuid(),'clear',operator_id,'x',now() FROM operators LIMIT 1`,
		`UPDATE operators SET role='admin'`, `UPDATE operators SET role=role WHERE false`,
		`SELECT token_sealed FROM apple_revocations`, `UPDATE apple_revocations SET status='queued'`, `INSERT INTO apple_revocations(issuer,subject,status) VALUES('a','b','manual')`,
	} {
		if _, err := adm.Exec(ctx, q); !denied(err) {
			t.Errorf("hiyall_admin ran %q: %v", q, err)
		}
	}
	for _, q := range []string{
		`SELECT count(*) FROM content_cases`, `SELECT count(*) FROM evidence_approvals`, `SELECT revocation_id,issuer,subject,user_id,status,reason,created_at FROM apple_revocations`,
		`UPDATE operators SET disabled_at=disabled_at WHERE false`, `UPDATE operators SET password_hash=password_hash WHERE false`, `DELETE FROM apple_revocations WHERE false`,
		`SELECT evidence_expire_due()`, `SELECT count(*) FROM pending_cases_due(5)`,
	} {
		if _, err := adm.Exec(ctx, q); err != nil {
			t.Errorf("hiyall_admin refused %q: %v", q, err)
		}
	}
	// The API role runs three of the functions (a status flip, a re-check, counts) and none of the others.
	for _, q := range []string{`SELECT activate_quarantine_case(gen_random_uuid())`, `SELECT hold_still_releasable(gen_random_uuid())`, `SELECT * FROM safety_queue_stats()`} {
		if _, err := api.Exec(ctx, q); err != nil {
			t.Errorf("hiyall_api refused %q: %v", q, err)
		}
	}
	for _, q := range []string{
		`SELECT evidence_decide(gen_random_uuid(),gen_random_uuid(),'approve','a reason')`, `SELECT evidence_propose(gen_random_uuid(),gen_random_uuid(),'clear',gen_random_uuid(),'a reason','')`,
		`SELECT operator_set_role(gen_random_uuid(),'admin',NULL)`, `SELECT content_case_report(gen_random_uuid(),gen_random_uuid(),'n','ref')`, `SELECT evidence_expire_due()`,
		`SELECT pending_cases_due(5)`, `SELECT drop_pending_case(gen_random_uuid(),'x')`, `SELECT admin_schedule_deletion(gen_random_uuid(),'x','y','c','n')`,
		`SELECT safety_fail('X')`, `SELECT safety_admin_email(gen_random_uuid())`,
	} {
		if _, err := api.Exec(ctx, q); !denied(err) {
			t.Errorf("hiyall_api ran %q: %v", q, err)
		}
	}
	// The functions work for the console role end to end (the restricted-role test walks the HTTP side).
	one, two := e.operator(RoleAdmin), e.operator(RoleAdmin)
	objects := media.NewMemory()
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	id := uuid.NewString()
	if _, err := adm.Exec(ctx, `SELECT evidence_propose($1::uuid,$2::uuid,'clear',$3::uuid,'cleared after review','')`, id, caseID, one.ID); err != nil {
		t.Fatalf("propose as hiyall_admin: %v", err)
	}
	if _, err := adm.Exec(ctx, `SELECT evidence_decide($1::uuid,$2::uuid,'approve','second look')`, id, two.ID); err != nil {
		t.Fatalf("decide as hiyall_admin: %v", err)
	}
	if st, _, _ := e.caseState(caseID); st != "cleared" {
		t.Fatalf("case %s", st)
	}
}

// The rules are in SQL: a console that skips every check in Go still cannot approve its own proposal, clear a case under
// a legal hold, lift a hold without counsel or promote an administrator alone.
func TestTwoPersonRulesAreEnforcedInSQL(t *testing.T) {
	e := newEnv(t)
	one, two, viewer := e.operator(RoleAdmin), e.operator(RoleAdmin), e.operator(RoleViewer)
	objects := media.NewMemory()
	uploader := e.member(false)
	caseID, _, _ := e.pendingQuarantine(uploader, "flagged", objects)
	propose := func(kind string, op testOperator, counsel string) (string, string) {
		id := uuid.NewString()
		return id, e.sqlCode(`SELECT evidence_propose($1::uuid,$2::uuid,$3,$4::uuid,'a sufficient reason',$5)`, id, caseID, kind, op.ID, counsel)
	}
	decide := func(id, decision string, op testOperator) string {
		return e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,$3,'a sufficient reason')`, id, op.ID, decision)
	}
	// Only administrators propose or decide.
	if _, code := propose("clear", viewer, ""); code != "NOT_ADMIN" {
		t.Fatalf("viewer proposed: %q", code)
	}
	disabled := e.operator(RoleAdmin)
	e.exec(`UPDATE operators SET disabled_at=now() WHERE operator_id=$1`, disabled.ID)
	if _, code := propose("clear", disabled, ""); code != "NOT_ADMIN" {
		t.Fatalf("disabled admin proposed: %q", code)
	}
	// proposed_by <> decided_by, in the function and in the table.
	id, code := propose("clear", one, "")
	if code != "" {
		t.Fatal(code)
	}
	if got := decide(id, "approve", one); got != "SECOND_APPROVER_REQUIRED" {
		t.Fatalf("self approval: %q", got)
	}
	if got := decide(id, "reject", one); got != "SECOND_APPROVER_REQUIRED" {
		t.Fatalf("self rejection: %q", got)
	}
	if got := decide(id, "approve", viewer); got != "NOT_ADMIN" {
		t.Fatalf("viewer approved: %q", got)
	}
	if got := decide(id, "withdraw", two); got != "NOT_PROPOSER" {
		t.Fatalf("other withdrew: %q", got)
	}
	if got := decide(id, "approve", disabled); got != "NOT_ADMIN" {
		t.Fatalf("disabled admin approved: %q", got)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatal("a refused approval changed the case")
	}
	if _, err := e.db.Pool.Exec(e.ctx, `UPDATE evidence_approvals SET status='approved',decided_by=proposed_by,decided_at=now() WHERE approval_id=$1`, id); err == nil || !strings.Contains(err.Error(), "evidence_approvals_two_people") {
		t.Fatalf("the table accepted a self approval: %v", err)
	}
	if got := decide(id, "withdraw", one); got != "" {
		t.Fatalf("withdraw: %q", got)
	}
	if got := decide(id, "approve", two); got != "PROPOSAL_DECIDED" {
		t.Fatalf("approving a withdrawn proposal: %q", got)
	}
	// A case under a legal hold is not cleared and its hold is not released.
	e.exec(`UPDATE content_cases SET legal_hold=true WHERE case_id=$1`, caseID)
	if _, code = propose("clear", one, ""); code != "HOLD_LEGAL_HOLD" {
		t.Fatalf("clear under a legal hold: %q", code)
	}
	e.exec(`UPDATE content_cases SET status='confirmed' WHERE case_id=$1`, caseID)
	if _, code = propose("release", one, ""); code != "HOLD_LEGAL_HOLD" {
		t.Fatalf("release under a legal hold: %q", code)
	}
	// Counsel's reference: required to lift, and of the form ^[A-Za-z0-9][A-Za-z0-9 ._/-]{5,119}$.
	for ref, want := range map[string]string{
		"": "COUNSEL_REFERENCE", "short": "COUNSEL_REFERENCE", "x1234": "COUNSEL_REFERENCE", "Okafor, 2027-02-03": "COUNSEL_REFERENCE",
		"Okafor; email": "COUNSEL_REFERENCE", "Okafor\nemail": "COUNSEL_REFERENCE", strings.Repeat("a", 121): "COUNSEL_REFERENCE", "-Okafor email": "COUNSEL_REFERENCE",
		"Okafor1": "", "Counsel M. Okafor 2027/02-03 ref_1.2": "", strings.Repeat("a", 120): "",
	} {
		if _, got := propose("legal_hold_lift", one, ref); got != want {
			t.Errorf("counsel %q: got %q, want %q", ref, got, want)
		}
		e.exec(`UPDATE evidence_approvals SET status='withdrawn',decided_by=proposed_by,decided_at=now() WHERE case_id=$1 AND status='pending'`, caseID)
	}
	// Lifting needs the approval and the approval re-checks the reference's form.
	id, _ = propose("legal_hold_lift", one, "Counsel Okafor email 2027-02-03")
	if got := decide(id, "approve", two); got != "" {
		t.Fatalf("approve lift: %q", got)
	}
	if _, legal, _ := e.caseState(caseID); legal {
		t.Fatal("legal hold still set")
	}
}

// A late "reported" keeps the evidence at least a year from the report, and never shortens a longer hold.
func TestReportedMovesHoldUntilToAtLeastAYearAndNeverEarlier(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleAdmin)
	for name, tc := range map[string]struct {
		holdDays int
		atLeast  float64
	}{"hold nearly over": {2, 364}, "hold already over": {-30, 364}, "a longer hold stays": {900, 899}} {
		t.Run(name, func(t *testing.T) {
			objects := media.NewMemory()
			caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
			e.exec(`UPDATE content_cases SET hold_until=now()+make_interval(days=>$2) WHERE case_id=$1`, caseID, tc.holdDays)
			if got := e.sqlCode(`SELECT content_case_report($1::uuid,$2::uuid,'reported to the authority','NCMEC-1')`, caseID, op.ID); got != "" {
				t.Fatal(got)
			}
			var days float64
			if err := e.db.Pool.QueryRow(e.ctx, `SELECT extract(epoch FROM hold_until-now())/86400 FROM content_cases WHERE case_id=$1`, caseID).Scan(&days); err != nil {
				t.Fatal(err)
			}
			if days < tc.atLeast {
				t.Fatalf("hold_until is %.1f days away, want at least %.0f", days, tc.atLeast)
			}
			if _, legal, _ := e.caseState(caseID); !legal {
				t.Fatal("a reported case has no legal hold")
			}
		})
	}
}

// Counsel's reference over HTTP: the same form, a 422 with the rule.
func TestCounselReferenceFormOverHTTP(t *testing.T) {
	e := newEnv(t)
	caseID, _, _ := e.pendingQuarantine(e.member(false), "match", media.NewMemory())
	one, two := e.twoAdmins()
	if r := e.post(one, "/admin/v1/content-cases/"+caseID+"/resolve", map[string]any{"action": "confirm", "reason": "confirmed as evidence"}); r.status != 200 {
		t.Fatal(r.raw)
	}
	for _, bad := range []string{"", "ab", "Okafor, 2027-02-03", strings.Repeat("c", 121), "#ref-123"} {
		r, _ := e.propose(one, caseID, "legal_hold_lift", "counsel closed the matter", bad)
		if r.status != 422 || r.code() != "VALIDATION" || !strings.Contains(string(r.raw), "counselReference") {
			t.Errorf("counsel %q: %d %s", bad, r.status, r.raw)
		}
	}
	if r, _ := e.propose(one, caseID, "release", "release it please now", "Okafor, nope"); r.status != 422 {
		t.Fatalf("a malformed reference on another kind: %d", r.status)
	}
	r, ap := e.propose(one, caseID, "legal_hold_lift", "counsel closed the matter", "Counsel Okafor email 2027-02-03")
	if r.status != 201 {
		t.Fatalf("%d %s", r.status, r.raw)
	}
	if r = e.decide(two, ap.Approval.ApprovalID, "approve", "verified with the sender"); r.status != 200 {
		t.Fatal(r.raw)
	}
}

// Promotion to administrator: no one else is an administrator, then a second administrator is needed.
func TestPromotionToAdministratorNeedsASecondAdministratorUnlessNoneIsActive(t *testing.T) {
	e := newEnv(t)
	e.exec(`UPDATE operators SET disabled_at=now() WHERE role='admin' AND disabled_at IS NULL`)
	first, second := e.operator(RoleViewer), e.operator(RoleViewer)
	// Bootstrap: nobody is an active administrator, so a role can be set directly (no acting operator).
	if got := e.sqlCode(`SELECT operator_set_role($1::uuid,'admin',NULL)`, first.ID); got != "" {
		t.Fatalf("bootstrap: %q", got)
	}
	// Now there is one: a promotion is refused in SQL, with or without an acting administrator.
	if got := e.sqlCode(`SELECT operator_set_role($1::uuid,'admin',$2::uuid)`, second.ID, first.ID); got != "APPROVAL_REQUIRED" {
		t.Fatalf("direct promotion: %q", got)
	}
	if got := e.sqlCode(`SELECT operator_set_role($1::uuid,'admin',NULL)`, second.ID); got != "NOT_ADMIN" {
		t.Fatalf("anonymous promotion: %q", got)
	}
	// The last administrator is never demoted.
	if got := e.sqlCode(`SELECT operator_set_role($1::uuid,'viewer',$1::uuid)`, first.ID); got != "LAST_ADMIN" {
		t.Fatalf("last admin: %q", got)
	}
	// The proposal route: the proposer is not the approver, a disabled or existing admin is refused.
	id := uuid.NewString()
	if got := e.sqlCode(`SELECT operator_promotion_propose($1::uuid,$2::uuid,$3::uuid,'needs the second pair of eyes')`, id, second.ID, first.ID); got != "" {
		t.Fatalf("propose: %q", got)
	}
	if got := e.sqlCode(`SELECT operator_promotion_propose($1::uuid,$2::uuid,$3::uuid,'needs the second pair of eyes')`, uuid.NewString(), second.ID, first.ID); got != "PROPOSAL_PENDING" {
		t.Fatalf("duplicate: %q", got)
	}
	if got := e.sqlCode(`SELECT operator_promotion_propose($1::uuid,$2::uuid,$3::uuid,'already one')`, uuid.NewString(), first.ID, first.ID); got != "NO_CHANGE" {
		t.Fatalf("promoting an admin: %q", got)
	}
	if got := e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,'approve','my own')`, id, first.ID); got != "SECOND_APPROVER_REQUIRED" {
		t.Fatalf("self approval: %q", got)
	}
	third := e.operator(RoleAdmin)
	if got := e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,'approve','checked')`, id, third.ID); got != "" {
		t.Fatalf("approval: %q", got)
	}
	var role string
	e.db.Pool.QueryRow(e.ctx, `SELECT role FROM operators WHERE operator_id=$1`, second.ID).Scan(&role)
	if role != "admin" {
		t.Fatalf("role %q after approval", role)
	}
}

// The console says how many administrators are active; below two nothing can be approved.
func TestApprovalsListReportsTheActiveAdministratorCount(t *testing.T) {
	e := newEnv(t)
	e.exec(`UPDATE operators SET disabled_at=now() WHERE role='admin' AND disabled_at IS NULL`)
	one := e.session(e.operator(RoleAdmin))
	var out struct{ ActiveAdmins int }
	e.get(one, "/admin/v1/approvals").data(&out)
	if out.ActiveAdmins != 1 {
		t.Fatalf("activeAdmins %d", out.ActiveAdmins)
	}
	e.operator(RoleAdmin)
	e.get(one, "/admin/v1/approvals").data(&out)
	if out.ActiveAdmins != 2 {
		t.Fatalf("activeAdmins %d", out.ActiveAdmins)
	}
}

// Expiry is a function too: proposals past their time are marked, and nothing is decided on them.
func TestExpiredProposalsAreMarkedAndRefused(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	one, two := e.twoAdmins()
	r, ap := e.propose(one, caseID, "clear", "a false positive, reviewed", "")
	if r.status != 201 {
		t.Fatal(r.raw)
	}
	e.exec(`UPDATE evidence_approvals SET expires_at=now()-interval '1 minute' WHERE approval_id=$1`, ap.Approval.ApprovalID)
	if r = e.decide(two, ap.Approval.ApprovalID, "approve", "too late to approve"); r.status != 409 || r.code() != "PROPOSAL_EXPIRED" {
		t.Fatalf("late approval: %d %s", r.status, r.raw)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatal("an expired proposal cleared the case")
	}
	r, ap2 := e.propose(one, caseID, "clear", "a second attempt", "")
	if r.status != 201 {
		t.Fatalf("propose after expiry: %d %s", r.status, r.raw)
	}
	e.exec(`UPDATE evidence_approvals SET expires_at=now()-interval '1 minute' WHERE approval_id=$1`, ap2.Approval.ApprovalID)
	n, err := e.svc.ExpireApprovals(e.ctx)
	if err != nil || n < 1 {
		t.Fatalf("expire: %d %v", n, err)
	}
	if e.count(`SELECT count(*) FROM evidence_approvals WHERE approval_id=$1 AND status='expired'`, ap2.Approval.ApprovalID) != 1 {
		t.Fatal("not marked expired")
	}
}

// ---- Apple revocations queued for a human

func (e *env) manualRevocation(userID string) string {
	e.t.Helper()
	id := uuid.NewString()
	e.exec(`INSERT INTO apple_revocations(revocation_id,issuer,subject,status,user_id,reason) VALUES($1,'https://securetoken.google.com/test',$2,'manual',$3,'the app could not obtain a code')`, id, "fb-"+id, userID)
	return id
}

func TestManualAppleRevocationsAreListedAndMarkedDoneWithAnAuditEntry(t *testing.T) {
	e := newEnv(t)
	e.exec(`DELETE FROM apple_revocations`)
	uid := e.member(false)
	id := e.manualRevocation(uid)
	e.exec(`INSERT INTO apple_revocations(issuer,subject,token_sealed) VALUES('https://securetoken.google.com/test',$1,'\xdeadbeef')`, "queued-"+id)
	adm, mod := e.session(e.operator(RoleAdmin)), e.session(e.operator(RoleModerator))
	if r := e.get(mod, "/admin/v1/apple-revocations"); r.status != 403 {
		t.Fatalf("moderator: %d", r.status)
	}
	var list struct {
		Items []struct{ RevocationID, Issuer, Subject, UserID, Reason string }
	}
	r := e.get(adm, "/admin/v1/apple-revocations")
	r.data(&list)
	if r.status != 200 || len(list.Items) != 1 || list.Items[0].RevocationID != id || list.Items[0].UserID != uid {
		t.Fatalf("list: %d %s", r.status, r.raw)
	}
	if strings.Contains(string(r.raw), "deadbeef") || strings.Contains(strings.ToLower(string(r.raw)), "sealed") {
		t.Fatal("the list shows a sealed token")
	}
	if r = e.post(adm, "/admin/v1/apple-revocations/"+id+"/revoked", map[string]string{"reason": "short"}); r.status != 422 {
		t.Fatalf("reason: %d", r.status)
	}
	if r = e.post(mod, "/admin/v1/apple-revocations/"+id+"/revoked", map[string]string{"reason": "revoked in Apple's console"}); r.status != 403 {
		t.Fatalf("moderator marked: %d", r.status)
	}
	if r = e.post(adm, "/admin/v1/apple-revocations/"+id+"/revoked", map[string]string{"reason": "revoked in Apple's console, ticket 7"}); r.status != 200 {
		t.Fatalf("mark: %d %s", r.status, r.raw)
	}
	if e.count(`SELECT count(*) FROM apple_revocations WHERE revocation_id=$1`, id) != 0 {
		t.Fatal("the row stayed")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='apple_revocation_done' AND target_id=$1 AND reason LIKE '%ticket 7%'`, uid) != 1 {
		t.Fatal("not audited")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='apple_revocations_view'`) < 1 {
		t.Fatal("the list read was not audited")
	}
	if r = e.post(adm, "/admin/v1/apple-revocations/"+id+"/revoked", map[string]string{"reason": "revoked in Apple's console, again"}); r.status != 404 {
		t.Fatalf("second mark: %d", r.status)
	}
	// A queued token row is not an operator's job and is not marked from here.
	var qid string
	e.db.Pool.QueryRow(e.ctx, `SELECT revocation_id::text FROM apple_revocations WHERE subject=$1`, "queued-"+id).Scan(&qid)
	if r = e.post(adm, "/admin/v1/apple-revocations/"+qid+"/revoked", map[string]string{"reason": "revoked in Apple's console, queued"}); r.status != 404 {
		t.Fatalf("queued row marked: %d", r.status)
	}
}

// ---- the evidence sweep

func (e *env) pendingCase(owner, result string, write ...bool) (caseID, mediaID string) {
	e.t.Helper()
	mediaID = uuid.NewString()
	e.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,expires_at)
 VALUES($1,$2,'post','pending','image/jpeg',100,100,'uploads/x',now()+interval '1 hour')`, mediaID, owner)
	originalKey, fullKey := media.HoldKeys(mediaID)
	caseID, err := e.db.BeginQuarantine(e.ctx, store.Quarantine{MediaID: mediaID, Owner: owner, Purpose: "post", Result: result, Scanner: "hashlist",
		OriginalSHA256: "ab", OriginalBytes: 3, ContentType: "image/jpeg", OriginalKey: originalKey, FullKey: fullKey})
	if err != nil {
		e.t.Fatal(err)
	}
	return caseID, mediaID
}

func TestSweepOpensPendingCasesWithObjectsAndDropsThoseWithout(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Evidence = objects
	owner := e.member(false)
	whole, wholeMedia := e.pendingCase(owner, "flagged")
	missing, missingMedia := e.pendingCase(e.member(false), "match")
	half, halfMedia := e.pendingCase(e.member(false), "flagged")
	fresh, _ := e.pendingCase(e.member(false), "flagged")
	for _, id := range []string{wholeMedia, halfMedia} {
		o, f := media.HoldKeys(id)
		_ = objects.Put(e.ctx, o, []byte("x"), "")
		if id == wholeMedia {
			_ = objects.Put(e.ctx, f, []byte("x"), "")
		}
	}
	// A pending case is not an open one: nothing lists it as open, and its hold is not releasable.
	if st, _, _ := e.caseState(whole); st != "pending" {
		t.Fatalf("status %s", st)
	}
	if e.count(`SELECT count(*) FROM content_cases WHERE case_id=$1 AND hold_release_blocker(case_id)='CASE_OPEN'`, whole) != 1 {
		t.Fatal("a pending case does not block a release")
	}
	e.exec(`UPDATE content_cases SET created_at=now()-interval '2 hours' WHERE case_id IN ($1,$2,$3)`, whole, missing, half)
	n, err := e.svc.SweepEvidence(e.ctx)
	if err != nil || n != 3 {
		t.Fatalf("sweep handled %d: %v", n, err)
	}
	if st, _, _ := e.caseState(whole); st != "open" {
		t.Fatalf("complete case: %s", st)
	}
	for _, id := range []string{missing, half} {
		if e.count(`SELECT count(*) FROM content_cases WHERE case_id=$1`, id) != 0 {
			t.Fatalf("case %s was not dropped", id)
		}
	}
	if st, _, _ := e.caseState(fresh); st != "pending" {
		t.Fatalf("a case under an hour old was touched: %s", st)
	}
	if e.count(`SELECT count(*) FROM media_assets WHERE media_id IN ($1,$2) AND status='deleted'`, missingMedia, halfMedia) != 2 {
		t.Fatal("the uploads of dropped cases were not marked deleted")
	}
	// Every step is audited (a match's suspension stays: the sweep never restores a member).
	if e.count(`SELECT count(*) FROM users WHERE status='suspended' AND user_id IN (SELECT subject_id FROM moderation_actions WHERE note LIKE '%'||$1||'%')`, missing) != 1 {
		t.Fatal("the suspension a match caused did not stay")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE actor='system:evidence-sweep' AND action IN ('pending_case_activated','pending_case_dropped') AND target_id IN ($1,$2,$3)`, whole, missing, half) != 3 {
		t.Fatal("the sweep's steps were not audited")
	}
	// Run again: nothing is left to do, and without a reader the sweep does nothing at all.
	if n, err = e.svc.SweepEvidence(e.ctx); err != nil || n != 0 {
		t.Fatalf("second sweep: %d %v", n, err)
	}
	e.svc.Evidence, e.svc.Media = nil, nil
	e.exec(`UPDATE content_cases SET created_at=now()-interval '2 hours' WHERE case_id=$1`, fresh)
	if n, err = e.svc.SweepEvidence(e.ctx); err != nil || n != 0 {
		t.Fatalf("sweep without a reader: %d %v", n, err)
	}
}

func TestSweepListsEvidenceObjectsWithoutACaseAndNeverDeletesThem(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Evidence = objects
	caseID, mediaID, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	_ = caseID
	orphanID := uuid.NewString()
	freshID := uuid.NewString()
	for _, id := range []string{orphanID, freshID} {
		o, f := media.HoldKeys(id)
		_ = objects.Put(e.ctx, o, []byte("x"), "")
		_ = objects.Put(e.ctx, f, []byte("x"), "")
	}
	// Old enough: the orphan's two objects and the cased photo's two (which have a case, so are not orphans).
	old := time.Now().Add(-3 * time.Hour)
	for _, id := range []string{orphanID, mediaID} {
		o, f := media.HoldKeys(id)
		objects.Modified[o], objects.Modified[f] = old, old
	}
	_ = objects.Put(e.ctx, "canary/probe", []byte("x"), "")
	objects.Modified["canary/probe"] = old
	if _, err := e.svc.SweepEvidence(e.ctx); err != nil {
		t.Fatal(err)
	}
	rep := e.svc.EvidenceOrphans()
	if rep.CheckedAt == nil || !rep.Complete || len(rep.Items) != 2 {
		t.Fatalf("orphans: %+v", rep)
	}
	for _, o := range rep.Items {
		if o.MediaID != orphanID {
			t.Fatalf("listed %+v", o)
		}
	}
	for _, id := range []string{orphanID, freshID, mediaID} {
		o, f := media.HoldKeys(id)
		if !objects.Has(o) || !objects.Has(f) {
			t.Fatalf("the sweep deleted objects of %s", id)
		}
	}
	adm := e.session(e.operator(RoleAdmin))
	var out struct {
		Items []struct{ Key, MediaID string }
	}
	if r := e.get(adm, "/admin/v1/evidence/orphans"); r.status != 200 {
		t.Fatal(r.raw)
	} else {
		r.data(&out)
	}
	if len(out.Items) != 2 {
		t.Fatalf("endpoint: %+v", out)
	}
	if r := e.get(e.session(e.operator(RoleModerator)), "/admin/v1/evidence/orphans"); r.status != 403 {
		t.Fatalf("moderator: %d", r.status)
	}
	// A standing orphan is written to the audit log once, not on every sweep.
	before := e.count(`SELECT count(*) FROM operator_audit WHERE action='evidence_orphans_found'`)
	if _, err := e.svc.SweepEvidence(e.ctx); err != nil {
		t.Fatal(err)
	}
	if got := e.count(`SELECT count(*) FROM operator_audit WHERE action='evidence_orphans_found'`); got != before || before < 1 {
		t.Fatalf("orphan audit entries %d then %d", before, got)
	}
}

// ---- the purge asks again before every delete

type afterFirstDelete struct {
	*media.Memory
	once sync.Once
	do   func()
}

func (a *afterFirstDelete) Delete(ctx context.Context, keys ...string) error {
	err := a.Memory.Delete(ctx, keys...)
	a.once.Do(a.do)
	return err
}

func TestPurgeRechecksTheHoldBeforeEachObjectDelete(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	uploader := e.member(false)
	caseID, mediaID, _ := e.pendingQuarantine(uploader, "flagged", objects)
	e.clearWithTwoAdmins(caseID, "false positive after review")
	one, two := e.twoAdmins()
	r, ap := e.propose(one, caseID, "release", "retention window ended, counsel agrees", "")
	if r.status != 201 || e.decide(two, ap.Approval.ApprovalID, "approve", "approving the release").status != 200 {
		t.Fatal("release setup", r.raw)
	}
	e.exec(`UPDATE content_cases SET hold_until=now()-interval '1 day' WHERE case_id=$1`, caseID)
	originalKey, fullKey := media.HoldKeys(mediaID)
	var report string
	holder := &afterFirstDelete{Memory: objects}
	holder.do = func() { report = e.report(e.member(false), uploader, "harassment") } // a report opens after the first object went
	e.svc.EvidenceDelete = holder
	n, err := e.svc.PurgeHolds(e.ctx, 5)
	if err != nil || n != 0 {
		t.Fatalf("purge finished %d cases despite the report: %v", n, err)
	}
	if objects.Has(originalKey) || !objects.Has(fullKey) {
		t.Fatalf("original present=%v full present=%v: the second object must be kept", objects.Has(originalKey), objects.Has(fullKey))
	}
	if e.count(`SELECT count(*) FROM content_cases WHERE case_id=$1 AND objects_purged_at IS NULL`, caseID) != 1 {
		t.Fatal("the case was recorded as purged")
	}
	// Once the report is dismissed the rest goes.
	e.exec(`UPDATE reports SET status='dismissed',resolved_at=now() WHERE report_id=$1`, report)
	e.svc.EvidenceDelete = objects
	if n, err = e.svc.PurgeHolds(e.ctx, 5); err != nil || n != 1 || objects.Has(fullKey) {
		t.Fatalf("second purge: %d %v full present=%v", n, err, objects.Has(fullKey))
	}
}

// hold_still_releasable is the single question the purge asks.
func TestHoldStillReleasableAnswersFalseForEverythingButADueReleasedHold(t *testing.T) {
	e := newEnv(t)
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", media.NewMemory())
	ask := func() bool {
		var ok bool
		if err := e.db.Pool.QueryRow(e.ctx, `SELECT hold_still_releasable($1::uuid)`, caseID).Scan(&ok); err != nil {
			t.Fatal(err)
		}
		return ok
	}
	if ask() {
		t.Fatal("an open case is releasable")
	}
	e.exec(`UPDATE content_cases SET status='cleared',released_at=now(),hold_until=now()-interval '1 day' WHERE case_id=$1`, caseID)
	if !ask() {
		t.Fatal("a due released hold is not releasable")
	}
	e.exec(`UPDATE content_cases SET legal_hold=true WHERE case_id=$1`, caseID)
	if ask() {
		t.Fatal("a legal hold is releasable")
	}
	e.exec(`UPDATE content_cases SET legal_hold=false,hold_until=now()+interval '1 day' WHERE case_id=$1`, caseID)
	if ask() {
		t.Fatal("a hold inside its window is releasable")
	}
	var ok bool
	e.db.Pool.QueryRow(e.ctx, `SELECT hold_still_releasable(gen_random_uuid())`).Scan(&ok)
	if ok {
		t.Fatal("an unknown case is releasable")
	}
}

func TestQueueStatsCountPendingApprovalsManualRevocationsAndPendingCases(t *testing.T) {
	e := newEnv(t)
	before, err := e.db.SafetyQueueStats(e.ctx)
	if err != nil {
		t.Fatal(err)
	}
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", media.NewMemory())
	one, _ := e.twoAdmins()
	if r, _ := e.propose(one, caseID, "clear", "a false positive, reviewed", ""); r.status != 201 {
		t.Fatal(r.raw)
	}
	e.manualRevocation(e.member(false))
	e.pendingCase(e.member(false), "flagged")
	after, err := e.db.SafetyQueueStats(e.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.PendingApprovals != before.PendingApprovals+1 || after.ManualAppleRevokes != before.ManualAppleRevokes+1 || after.PendingCases != before.PendingCases+1 || after.OldestPendingSeconds < 0 {
		t.Fatalf("stats %+v -> %+v", before, after)
	}
}

// The console role has no access to the member tables, yet the support-driven deletion works through its function.
func TestSupportDeletionWorksOnTheRestrictedAdminRole(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	uid := e.member(false)
	e.exec(`INSERT INTO auth_identities(issuer,subject,user_id,sign_in_provider,apple_linked) VALUES('https://securetoken.google.com/test',$1,$2,'apple.com',false)`, "apple-"+uid, uid)
	e.exec(`INSERT INTO sessions(session_id,user_id,expires_at) VALUES(gen_random_uuid(),$1,now()+interval '1 day')`, uid)
	db, err := store.New(e.ctx, roleDSN(t, "hiyall_admin"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	if _, err = db.Pool.Exec(e.ctx, `UPDATE devices SET push_token=NULL`); !denied(err) {
		t.Fatalf("the console role can write devices directly: %v", err)
	}
	due, err := db.AdminScheduleDeletion(e.ctx, uid, "cli:test", "support ticket 4412")
	if err != nil || time.Until(due) < 29*24*time.Hour {
		t.Fatalf("due %v: %v", due, err)
	}
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='pending_deletion'`, uid) != 1 ||
		e.count(`SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, uid) != 0 ||
		e.count(`SELECT count(*) FROM apple_revocations WHERE user_id=$1 AND status='manual'`, uid) != 1 {
		t.Fatal("the deletion was not applied")
	}
	if _, err = db.AdminScheduleDeletion(e.ctx, uuid.NewString(), "cli:test", "support ticket 4412"); err == nil {
		t.Fatal("an unknown member was scheduled")
	}
}
