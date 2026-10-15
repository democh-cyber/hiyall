package admin

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"hiyall/services/api/internal/media"
)

// Releasing an evidence hold (docs/security/16-csam-and-illegal-content.md section 9): two administrators with a
// reason each, audited, refused while anything depends on the evidence, and deleting nothing until the window is
// over (approvals_test.go has the two-person rules; this walks the blockers and the purge).
func TestHoldReleaseRulesAuditAndPurge(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	uploader := e.member(false)
	caseID, mediaID, _ := e.pendingQuarantine(uploader, "flagged", objects)
	originalKey, fullKey := media.HoldKeys(mediaID)
	mod := e.session(e.operator(RoleModerator))
	adm, adm2 := e.twoAdmins()
	const why = "counsel says the hold has ended"
	// release proposes (by adm) and, when asked, approves (by adm2); it returns the proposal's reply and the approval's.
	release := func(s sess, id, reason string, approve bool) (reply, reply) {
		r, ap := e.propose(s, id, "release", reason, "")
		if r.status != 201 || !approve {
			return r, reply{}
		}
		return r, e.decide(adm2, ap.Approval.ApprovalID, "approve", "second administrator: "+reason)
	}
	state := func() (c struct {
		ReleaseBlocker string
		ReleasedAt     *string
	}) {
		e.get(adm, "/admin/v1/content-cases/"+caseID).data(&struct {
			Case *struct {
				ReleaseBlocker string
				ReleasedAt     *string
			} `json:"case"`
		}{&c})
		return
	}

	// Moderators cannot; an administrator needs a real reason and a real case.
	if r, _ := release(mod, caseID, why, false); r.status != 403 {
		t.Fatalf("moderator: %d", r.status)
	}
	if r, _ := release(adm, caseID, "short", false); r.status != 422 || r.code() != "VALIDATION" {
		t.Fatalf("short reason: %d %s", r.status, r.raw)
	}
	if r, _ := release(adm, "00000000-0000-4000-8000-000000000000", why, false); r.status != 404 {
		t.Fatalf("unknown case: %d", r.status)
	}
	if r, _ := release(adm, "not-an-id", why, false); r.status != 404 {
		t.Fatalf("bad id: %d", r.status)
	}

	// An open case is not releasable, and the case view says why.
	if r, _ := release(adm, caseID, why, false); r.status != 409 || r.code() != "HOLD_CASE_OPEN" {
		t.Fatalf("open case: %d %s", r.status, r.raw)
	}
	if got := state(); got.ReleaseBlocker != "CASE_OPEN" {
		t.Fatalf("blocker %q", got.ReleaseBlocker)
	}
	// Cleared (by two administrators): but a member report about the uploader that is still open references the evidence.
	e.clearWithTwoAdmins(caseID, "false positive after review")
	report := e.report(e.member(false), uploader, "harassment")
	if r, _ := release(adm, caseID, why, false); r.status != 409 || r.code() != "HOLD_REPORT_OPEN" {
		t.Fatalf("open report: %d %s", r.status, r.raw)
	}
	e.exec(`UPDATE reports SET status='dismissed',resolved_at=now() WHERE report_id=$1`, report)
	// Another open case of the same uploader.
	otherCase, _, _ := e.pendingQuarantine(uploader, "flagged", objects)
	if r, _ := release(adm, caseID, why, false); r.status != 409 || r.code() != "HOLD_OTHER_CASE_OPEN" {
		t.Fatalf("other open case: %d %s", r.status, r.raw)
	}
	e.exec(`UPDATE content_cases SET status='cleared' WHERE case_id=$1`, otherCase)
	// A legal hold.
	e.exec(`UPDATE content_cases SET legal_hold=true WHERE case_id=$1`, caseID)
	if r, _ := release(adm, caseID, why, false); r.status != 409 || r.code() != "HOLD_LEGAL_HOLD" {
		t.Fatalf("legal hold: %d %s", r.status, r.raw)
	}
	if e.auditCount("hold_release", caseID) != 0 {
		t.Fatal("a refused release was audited as a release")
	}
	e.exec(`UPDATE content_cases SET legal_hold=false WHERE case_id=$1`, caseID)

	// Released: audited with its reason, once.
	if _, r := release(adm, caseID, why, true); r.status != 200 {
		t.Fatalf("release: %d %s", r.status, r.raw)
	}
	var reason string
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT reason FROM operator_audit WHERE action='hold_release' AND target_id=$1`, caseID).Scan(&reason); err != nil || !strings.Contains(reason, why) {
		t.Fatalf("audited reason %q (%v)", reason, err)
	}
	if r, _ := release(adm, caseID, why, false); r.status != 409 || r.code() != "HOLD_ALREADY_RELEASED" {
		t.Fatalf("second release: %d %s", r.status, r.raw)
	}
	if got := state(); got.ReleasedAt == nil || got.ReleaseBlocker != "" {
		t.Fatalf("case after release: %+v", got)
	}

	// Releasing deleted nothing; the window (hold_until, 90 days) is not over, so the cleanup waits.
	n, err := e.svc.PurgeHolds(e.ctx, 10)
	if err != ErrNoEvidenceDelete {
		t.Fatalf("without the delete credential the console must not purge: %d %v", n, err)
	}
	e.svc.EvidenceDelete = objects
	n, err = e.svc.PurgeHolds(e.ctx, 10)
	if err != nil || n != 0 || !objects.Has(originalKey) || !objects.Has(fullKey) {
		t.Fatalf("before the window ended: %d %v, objects kept %v %v", n, err, objects.Has(originalKey), objects.Has(fullKey))
	}
	// A legal hold set after the release stops the removal too.
	e.exec(`UPDATE content_cases SET hold_until=now()-interval '1 day',legal_hold=true WHERE case_id=$1`, caseID)
	if n, err = e.svc.PurgeHolds(e.ctx, 10); err != nil || n != 0 || !objects.Has(originalKey) {
		t.Fatalf("with a legal hold: %d %v", n, err)
	}
	e.exec(`UPDATE content_cases SET legal_hold=false WHERE case_id=$1`, caseID)
	// Window over, still released: the objects go, the record stays, and the removal is audited.
	if n, err = e.svc.PurgeHolds(e.ctx, 10); err != nil || n != 1 {
		t.Fatalf("after the window: %d %v", n, err)
	}
	if objects.Has(originalKey) || objects.Has(fullKey) {
		t.Fatal("held objects survived")
	}
	if e.count(`SELECT count(*) FROM content_cases WHERE case_id=$1 AND objects_purged_at IS NOT NULL AND original_sha256<>''`, caseID) != 1 {
		t.Fatal("the case record was not kept and marked")
	}
	if e.auditCount("hold_objects_purged", caseID) != 1 {
		t.Fatal("the removal was not audited")
	}
	if n, err = e.svc.PurgeHolds(e.ctx, 10); err != nil || n != 0 {
		t.Fatalf("again: %d %v", n, err)
	}
	// An unreleased hold is never removed, however old.
	other, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	e.exec(`UPDATE content_cases SET status='cleared',hold_until=now()-interval '400 days' WHERE case_id=$1`, other)
	if n, err = e.svc.PurgeHolds(e.ctx, 10); err != nil || n != 0 {
		t.Fatalf("unreleased: %d %v", n, err)
	}
}

// A confirmed or reported case carries a legal hold, so it cannot be released from the console at all.
func TestConfirmedCasesKeepTheirLegalHold(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Media = objects
	caseID, _, _ := e.pendingQuarantine(e.member(false), "match", objects)
	adm := e.session(e.operator(RoleAdmin))
	if r := e.post(adm, "/admin/v1/content-cases/"+caseID+"/resolve", map[string]any{"action": "confirm", "reason": "confirmed as evidence"}); r.status != 200 {
		t.Fatalf("confirm: %d %s", r.status, r.raw)
	}
	r := e.post(adm, "/admin/v1/content-cases/"+caseID+"/proposals", map[string]string{"kind": "release", "reason": "trying to release evidence"})
	if r.status != 409 || r.code() != "HOLD_LEGAL_HOLD" {
		t.Fatalf("%d %s", r.status, r.raw)
	}
}

// Audit retention: an administrator prunes entries older than a year through the one database function; the
// append-only trigger stays on for everyone, before and after.
func TestAuditPruneKeepsTheLogAppendOnly(t *testing.T) {
	e := newEnv(t)
	adm, mod := e.session(e.operator(RoleAdmin)), e.session(e.operator(RoleModerator))
	// The audit log keeps what tests write, so the actions are unique to this run.
	oldAction, recentAction := "prune_test_old_"+uuid.NewString(), "prune_test_recent_"+uuid.NewString()
	e.exec(`INSERT INTO operator_audit(at,actor,action,reason) VALUES (now()-interval '400 days','old@example.test',$1,'x'),
 (now()-interval '366 days','old@example.test',$1,'x'), (now()-interval '364 days','new@example.test',$2,'x')`, oldAction, recentAction)
	prune := func(s sess, body map[string]any) reply { return e.post(s, "/admin/v1/audit/prune", body) }

	if r := prune(mod, map[string]any{"reason": "routine yearly pruning"}); r.status != 403 {
		t.Fatalf("moderator: %d", r.status)
	}
	if r := prune(adm, map[string]any{"reason": "short"}); r.status != 422 {
		t.Fatalf("short reason: %d", r.status)
	}
	// Never younger than 365 days, through the API or the function.
	if r := prune(adm, map[string]any{"reason": "routine yearly pruning", "olderThanDays": 30}); r.status != 422 || !strings.Contains(string(r.raw), "olderThanDays") {
		t.Fatalf("30 days: %d %s", r.status, r.raw)
	}
	if _, err := e.db.Pool.Exec(e.ctx, `SELECT prune_operator_audit(NULL,'x','a reason here',30)`); err == nil || !strings.Contains(err.Error(), "365") {
		t.Fatalf("function with 30 days: %v", err)
	}
	if _, err := e.db.Pool.Exec(e.ctx, `SELECT prune_operator_audit(NULL,'x','   ',365)`); err == nil {
		t.Fatal("function without a reason")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action=$1`, oldAction) != 2 {
		t.Fatal("a refused prune deleted rows")
	}

	var got struct{ Deleted int64 }
	r := prune(adm, map[string]any{"reason": "routine yearly pruning"})
	r.data(&got)
	if r.status != 200 || got.Deleted < 2 {
		t.Fatalf("prune: %d %s", r.status, r.raw)
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action=$1`, oldAction) != 0 || e.count(`SELECT count(*) FROM operator_audit WHERE action=$1`, recentAction) != 1 {
		t.Fatal("pruned the wrong rows")
	}
	var logged int64
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT (detail->>'deleted')::bigint FROM operator_audit WHERE action='audit_prune' AND reason='routine yearly pruning' ORDER BY audit_id DESC LIMIT 1`).Scan(&logged); err != nil || logged != got.Deleted {
		t.Fatalf("the prune was not audited: %d vs %d (%v)", logged, got.Deleted, err)
	}
	// Still append-only afterwards, for the owner as for everyone: UPDATE, DELETE and TRUNCATE are refused.
	for _, q := range []string{`UPDATE operator_audit SET reason='x'`, `DELETE FROM operator_audit WHERE action='audit_prune'`, `TRUNCATE operator_audit`} {
		if _, err := e.db.Pool.Exec(context.Background(), q); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("%q after a prune: %v", q, err)
		}
	}
	if e.count(`SELECT count(*) FROM pg_trigger WHERE tgrelid='operator_audit'::regclass AND tgname='operator_audit_no_change' AND tgenabled='O'`) != 1 {
		t.Fatal("the trigger is not enabled")
	}
}

// The least-privilege roles: only the console role can prune; the hold functions run for the API (shared bucket)
// and for the console's purge job; neither can read what it must not.
func TestHoldAndAuditFunctionsAreGrantedToOneRoleEach(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	api, adm := rolePool(t, "hiyall_api"), rolePool(t, "hiyall_admin")
	ctx := context.Background()
	for _, q := range []string{`SELECT held_objects_due(5)`, `SELECT mark_hold_purged(gen_random_uuid())`} {
		if _, err := adm.Exec(ctx, q); err != nil {
			t.Errorf("hiyall_admin refused %q: %v", q, err)
		}
		if _, err := api.Exec(ctx, q); err != nil {
			t.Errorf("hiyall_api refused %q: %v", q, err)
		}
	}
	if _, err := api.Exec(ctx, `SELECT prune_operator_audit(NULL,'x','a reason here',365)`); !denied(err) {
		t.Errorf("hiyall_api pruned the audit log: %v", err)
	}
	if _, err := adm.Exec(ctx, `SELECT prune_operator_audit(NULL,'role-test','role privilege check',36000)`); err != nil {
		t.Errorf("hiyall_admin cannot prune: %v", err)
	}
	// The API role still cannot read a case, and neither role can bypass the trigger.
	if _, err := api.Exec(ctx, `SELECT status FROM content_cases`); !denied(err) { // only the media_id column is readable (count(*) needs just one column privilege)
		t.Errorf("hiyall_api read cases: %v", err)
	}
	for _, q := range []string{`DELETE FROM operator_audit`, `ALTER TABLE operator_audit DISABLE TRIGGER operator_audit_no_change`} {
		if _, err := adm.Exec(ctx, q); !denied(err) {
			t.Errorf("hiyall_admin ran %q: %v", q, err)
		}
	}
}

// The prune removes one batch of 5000 per call, each call its own transaction, so the table lock lasts moments;
// the service repeats until fewer than a batch is left (re-audit: the prune must not hold audited reads).
func TestAuditPruneWorksInBatchesOf5000(t *testing.T) {
	e := newEnv(t)
	marker := "prune_batch_" + uuid.NewString()
	e.exec(`INSERT INTO operator_audit(at,actor,action,target_type) SELECT now()-interval '500 days','batch@example.test',$1,'x' FROM generate_series(1,5300)`, marker)
	op := e.operator(RoleAdmin)
	// One call removes at most one batch.
	var first int64
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT prune_operator_audit($1,'batch@example.test','batch test, one call',400)`, op.ID).Scan(&first); err != nil {
		t.Fatal(err)
	}
	if first < 1 || first > 5000 {
		t.Fatalf("one call removed %d, the batch is 5000", first)
	}
	// While a batch runs, other audit writes are held up for moments only: the function has its own lock_timeout.
	var lockTimeout string
	e.db.Pool.QueryRow(e.ctx, `SELECT array_to_string(proconfig,',') FROM pg_proc WHERE proname='prune_operator_audit'`).Scan(&lockTimeout)
	if !strings.Contains(lockTimeout, "lock_timeout=2s") {
		t.Fatalf("the prune has no lock timeout: %q", lockTimeout)
	}
	// The service drains the rest across calls.
	p := &Principal{Operator: op.Operator}
	removed, more, err := e.svc.PruneAudit(e.ctx, p, "batch test, the rest", 400)
	if err != nil || more {
		t.Fatalf("%d %v %v", removed, more, err)
	}
	if first+removed < 5300 || e.count(`SELECT count(*) FROM operator_audit WHERE action=$1`, marker) != 0 {
		t.Fatalf("%d + %d removed, %d left", first, removed, e.count(`SELECT count(*) FROM operator_audit WHERE action=$1`, marker))
	}
	// Each batch left its own audit entry with the count, and the trigger is back on.
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='audit_prune' AND reason LIKE 'batch test%'`) < 2 {
		t.Fatal("the batches were not each audited")
	}
	if e.count(`SELECT count(*) FROM pg_trigger WHERE tgrelid='operator_audit'::regclass AND tgname='operator_audit_no_change' AND tgenabled='O'`) != 1 {
		t.Fatal("the trigger is not enabled")
	}
}
