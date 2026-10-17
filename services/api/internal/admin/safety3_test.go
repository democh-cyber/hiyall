package admin

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Round-4 audit API N-1 to N-12, DB N2 and N8 (migration 0046).

// pgCode is the SQLSTATE of err, "" when it is not a PostgreSQL error.
func pgCode(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code
	}
	return ""
}

// oneRoleTx runs f in a transaction on the pool and rolls it back, so a test can bend the shared database (disable every
// administrator, say) without anyone else seeing it.
func oneRoleTx(t *testing.T, pool *pgxpool.Pool, f func(tx pgx.Tx)) {
	t.Helper()
	tx, err := pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	f(tx)
}

// txCode runs a statement in tx inside a savepoint and returns the two-person function's tag.
func txCode(t *testing.T, tx pgx.Tx, query string, args ...any) string {
	t.Helper()
	ctx := context.Background()
	if _, err := tx.Exec(ctx, `SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	_, err := tx.Exec(ctx, query, args...)
	if err == nil {
		if _, err := tx.Exec(ctx, `RELEASE SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
		return ""
	}
	if _, rerr := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); rerr != nil {
		t.Fatal(rerr)
	}
	code := store.SafetyErrorCode(err)
	if code == "" {
		t.Fatalf("%s: %v", query, err)
	}
	return code
}

// ---- N-1: the API role can open a case and nothing more

func TestAPIRoleCannotInsertAPreReleasedOrForeignCase(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	api := rolePool(t, "hiyall_api")
	ctx := context.Background()
	owner := e.member(false)
	media1, media2 := uuid.NewString(), uuid.NewString()
	for _, id := range []string{media1, media2} {
		e.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,expires_at)
 VALUES($1,$2,'post','pending','image/jpeg',100,100,'uploads/x',now()+interval '1 hour')`, id, owner)
	}
	insert := func(columns, values string, args ...any) error {
		_, err := api.Exec(ctx, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,original_sha256,original_bytes,content_type,original_key`+columns+`)
 VALUES(gen_random_uuid(),$1,$2,'post','flagged','test','ab',3,'image/jpeg',$3`+values+`)`, args...)
		return err
	}
	originalKey1, _ := media.HoldKeys(media1)
	originalKey2, _ := media.HoldKeys(media2)

	// A pre-released case, a case that is already open, a legal hold, a report: none of these columns can even be named.
	for name, c := range map[string][2]string{
		"released":    {`,released_at,released_by,release_reason`, `,now()-interval '2 days','x','x'`},
		"status":      {`,status`, `,'cleared'`},
		"legal hold":  {`,legal_hold`, `,true`},
		"reported":    {`,reported_at,report_reference`, `,now(),'x'`},
		"purged":      {`,objects_purged_at`, `,now()`},
		"reviewed by": {`,reviewed_by,reviewed_at`, `,'x',now()`},
	} {
		if err := insert(c[0], c[1], media1, owner, originalKey1); !denied(err) {
			t.Errorf("hiyall_api inserted a case with %s: %v", name, err)
		}
	}
	// The key of the evidence is pinned to the media id: a case cannot point at another upload's objects (the attack
	// is a pre-released case for real evidence, which the console purge would delete).
	if err := insert("", "", media1, owner, originalKey2); pgCode(err) != "23514" {
		t.Errorf("a case with another upload's original key: %v", err)
	}
	if err := insert("", "", media1, owner, "hold/anything/original"); pgCode(err) != "23514" {
		t.Errorf("a case with a made-up key: %v", err)
	}
	if err := insert(",full_key", ",$4", media1, owner, originalKey1, originalKey2); pgCode(err) != "23514" {
		t.Errorf("a case with a foreign full key: %v", err)
	}
	// What the upload path writes works, and comes out pending.
	caseID := uuid.NewString()
	if _, err := api.Exec(ctx, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,original_sha256,original_bytes,content_type,original_key,full_key,hold_until)
 VALUES($1,$2,$3,'post','flagged','test','ab',3,'image/jpeg',$4,$5,now())`, caseID, media1, owner, originalKey1, "hold/"+media1+"/full.jpg"); err != nil {
		t.Fatalf("the upload path's insert: %v", err)
	}
	var status string
	var legal bool
	var releasedAt *time.Time
	var holdDays float64
	if err := e.db.Pool.QueryRow(ctx, `SELECT status,legal_hold,released_at,extract(epoch FROM hold_until-now())/86400 FROM content_cases WHERE case_id=$1`, caseID).Scan(&status, &legal, &releasedAt, &holdDays); err != nil {
		t.Fatal(err)
	}
	if status != "pending" || legal || releasedAt != nil {
		t.Fatalf("an inserted case is %s legal=%v released=%v", status, legal, releasedAt)
	}
	// A hold that is "now" is lengthened to the least EVIDENCE_RETENTION_DAYS allows.
	if holdDays < 29 {
		t.Fatalf("the API set a hold of %.1f days", holdDays)
	}
	// One case per upload: a second insert for the same media id is refused.
	if err := insert("", "", media1, owner, originalKey1); pgCode(err) != "23505" {
		t.Errorf("a second case for the same upload: %v", err)
	}

	// The trigger is a second line: even if a column were granted by mistake, the API role's insert is forced to a plain
	// pending case.
	e.exec(`GRANT INSERT (status, legal_hold, released_at, released_by, release_reason, reviewed_by, hold_until) ON content_cases TO hiyall_api`)
	t.Cleanup(func() { applyRoles(t, e) })
	caseID2 := uuid.NewString()
	if _, err := api.Exec(ctx, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,original_sha256,original_bytes,content_type,original_key,status,legal_hold,released_at,released_by,release_reason,reviewed_by,hold_until)
 VALUES($1,$2,$3,'post','flagged','test','ab',3,'image/jpeg',$4,'cleared',true,now()-interval '2 days','x','x','x',now()-interval '1 year')`, caseID2, media2, owner, originalKey2); err != nil {
		t.Fatalf("insert with the extra grants: %v", err)
	}
	var reviewedBy, releasedBy *string
	if err := e.db.Pool.QueryRow(ctx, `SELECT status,legal_hold,released_at,released_by,reviewed_by,extract(epoch FROM hold_until-now())/86400 FROM content_cases WHERE case_id=$1`, caseID2).Scan(&status, &legal, &releasedAt, &releasedBy, &reviewedBy, &holdDays); err != nil {
		t.Fatal(err)
	}
	if status != "pending" || legal || releasedAt != nil || releasedBy != nil || reviewedBy != nil || holdDays < 29 {
		t.Fatalf("the trigger let a forged case through: %s legal=%v released=%v by=%v reviewed=%v days=%.1f", status, legal, releasedAt, releasedBy, reviewedBy, holdDays)
	}
}

// ---- N-2: operators are created and disabled through functions

func TestOperatorCreateRefusesAnAdministratorWhileAnotherIsActive(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	adm := rolePool(t, "hiyall_admin")
	e.asRole("hiyall_admin")
	e.operator(RoleAdmin) // an active administrator exists

	// The CLI's path (Service.CreateOperator, as the console role): a viewer and a moderator are made; an administrator is not.
	for _, role := range []Role{RoleViewer, RoleModerator} {
		if _, err := e.svc.CreateOperator(e.ctx, randomName("new")+"@hiyall.test", "New "+string(role), role, testPassword, "cli:test"); err != nil {
			t.Fatalf("create %s: %v", role, err)
		}
	}
	_, err := e.svc.CreateOperator(e.ctx, randomName("new")+"@hiyall.test", "New admin", RoleAdmin, testPassword, "cli:test")
	if !errors.Is(err, ErrAdminExists) {
		t.Fatalf("an administrator was created while another is active: %v", err)
	}
	// Direct INSERT with role admin is denied to the console role, and the function refuses the same.
	if _, err = adm.Exec(e.ctx, `INSERT INTO operators(operator_id,email,display_name,role,password_hash,totp_secret) VALUES(gen_random_uuid(),'direct@hiyall.test','d','admin','h','\x00')`); !denied(err) {
		t.Fatalf("direct insert of an administrator: %v", err)
	}
	var created int
	if err = e.db.Pool.QueryRow(e.ctx, `SELECT count(*) FROM operators WHERE email LIKE 'direct@%'`).Scan(&created); err != nil || created != 0 {
		t.Fatalf("a direct insert landed: %d %v", created, err)
	}
	// A duplicate address and a bad one.
	email := randomName("dup") + "@hiyall.test"
	if _, err = e.svc.CreateOperator(e.ctx, email, "Dup", RoleViewer, testPassword, "cli:test"); err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.CreateOperator(e.ctx, email, "Dup", RoleViewer, testPassword, "cli:test"); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("duplicate: %v", err)
	}
	// The function wrote the audit entry itself, naming who ran it.
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='operator_create' AND actor='cli:test' AND detail->>'email'=$1`, email) != 1 {
		t.Fatal("operator_create was not audited by the function")
	}

	// Bootstrap: with no active administrator the first one is created (in a transaction that is rolled back).
	oneRoleTx(t, e.db.Pool, func(tx pgx.Tx) {
		ctx := context.Background()
		if _, err := tx.Exec(ctx, `UPDATE operators SET disabled_at=now() WHERE role='admin' AND disabled_at IS NULL`); err != nil {
			t.Fatal(err)
		}
		id := uuid.NewString()
		if code := txCode(t, tx, `SELECT operator_create($1::uuid,'first@hiyall.test','First','admin','hash','\x0102',NULL,'cli:test')`, id); code != "" {
			t.Fatalf("the bootstrap administrator: %q", code)
		}
		// And a second one is refused as soon as the first is active.
		if code := txCode(t, tx, `SELECT operator_create(gen_random_uuid(),'second@hiyall.test','Second','admin','hash','\x0102',NULL,'cli:test')`); code != "APPROVAL_REQUIRED" {
			t.Fatalf("a second administrator: %q", code)
		}
		// The actor is required for the CLI path, and a named operator must be an active administrator.
		if code := txCode(t, tx, `SELECT operator_create(gen_random_uuid(),'third@hiyall.test','Third','viewer','hash','\x0102',NULL,'')`); code != "VALIDATION_ACTOR" {
			t.Fatalf("no actor: %q", code)
		}
		if code := txCode(t, tx, `SELECT operator_create(gen_random_uuid(),'third@hiyall.test','Third','viewer','hash','\x0102',gen_random_uuid(),'x')`); code != "NOT_ADMIN" {
			t.Fatalf("an unknown operator: %q", code)
		}
		if code := txCode(t, tx, `SELECT operator_create(gen_random_uuid(),'not an address','Third','viewer','hash','\x0102',NULL,'cli:test')`); code != "VALIDATION_EMAIL" {
			t.Fatalf("a bad address: %q", code)
		}
	})
}

func TestOperatorDisableRefusesToLeaveNoAdministratorAndThroughTheFunctionOnly(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	adm := rolePool(t, "hiyall_admin")
	// Disabling directly is denied to the console role.
	if _, err := adm.Exec(e.ctx, `UPDATE operators SET disabled_at=now() WHERE false`); !denied(err) {
		t.Fatalf("direct disable: %v", err)
	}
	oneRoleTx(t, e.db.Pool, func(tx pgx.Tx) {
		ctx := context.Background()
		// Make exactly two administrators active: one, two.
		if _, err := tx.Exec(ctx, `UPDATE operators SET disabled_at=now() WHERE role='admin' AND disabled_at IS NULL`); err != nil {
			t.Fatal(err)
		}
		mk := func(role string) string {
			id := uuid.NewString()
			if _, err := tx.Exec(ctx, `INSERT INTO operators(operator_id,email,display_name,role,password_hash,totp_secret) VALUES($1,$2,'x',$3,'h','\x00')`, id, randomName("t")+"@hiyall.test", role); err != nil {
				t.Fatal(err)
			}
			return id
		}
		one, two, viewer := mk("admin"), mk("admin"), mk("viewer")
		var remaining int
		disable := func(target string, op any, force bool) (string, int) {
			if _, err := tx.Exec(ctx, `SAVEPOINT d`); err != nil {
				t.Fatal(err)
			}
			err := tx.QueryRow(ctx, `SELECT operator_set_disabled($1::uuid,true,$2::uuid,$3,'a sufficient reason',$4)`, target, op, "cli:test", force).Scan(&remaining)
			if err != nil {
				tx.Exec(ctx, `ROLLBACK TO SAVEPOINT d`)
				return store.SafetyErrorCode(err), 0
			}
			tx.Exec(ctx, `RELEASE SAVEPOINT d`)
			return "", remaining
		}
		// A viewer can always go; an administrator can go while another is left, and the answer says how many remain.
		if code, left := disable(viewer, one, false); code != "" || left != 2 {
			t.Fatalf("disable a viewer: %q left %d", code, left)
		}
		if code, left := disable(two, one, false); code != "" || left != 1 {
			t.Fatalf("disable one of two administrators: %q left %d (warn below two)", code, left)
		}
		// Never the last one, never yourself, and no force from a named operator.
		if code, _ := disable(one, nil, false); code != "LAST_ADMIN" {
			t.Fatalf("the last administrator: %q", code)
		}
		if code, _ := disable(one, one, false); code != "SELF_DISABLE" && code != "LAST_ADMIN" {
			t.Fatalf("self disable: %q", code)
		}
		if code, _ := disable(one, one, true); code != "FORCE_FORBIDDEN" {
			t.Fatalf("a console operator forcing: %q", code)
		}
		// The CLI's emergency path (a stolen device of the only administrator) can.
		if code, left := disable(one, nil, true); code != "" || left != 0 {
			t.Fatalf("forced disable: %q left %d", code, left)
		}
		if code := txCode(t, tx, `SELECT operator_set_disabled($1::uuid,true,NULL,'cli:test','a sufficient reason',true)`, one); code != "NO_CHANGE" {
			t.Fatalf("disabling twice: %q", code)
		}
	})
}

// ---- N-3: the audit entry is written inside the function

func TestTwoPersonFunctionsWriteTheirAuditEntryInTheSameTransaction(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	adm := rolePool(t, "hiyall_admin")
	one, two := e.operator(RoleAdmin), e.operator(RoleAdmin)
	objects := media.NewMemory()
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	ctx := context.Background()
	approval := uuid.NewString()

	// Called straight on the database as the console role, with no Go audit code anywhere: the entries exist.
	func() {
		tx, err := adm.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err = tx.Exec(ctx, `SELECT set_config('hiyall.ip','203.0.113.0/24',true)`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, `SELECT evidence_propose($1::uuid,$2::uuid,'clear',$3::uuid,'a sufficient reason','')`, approval, caseID, one.ID); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, `SELECT evidence_decide($1::uuid,$2::uuid,'approve','looked again')`, approval, two.ID); err != nil {
			t.Fatal(err)
		}
		var n int
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM operator_audit WHERE target_id=$1 AND action IN ('evidence_proposed','evidence_approved','content_case_clear')`, caseID).Scan(&n); err != nil || n != 3 {
			t.Fatalf("entries inside the transaction: %d %v", n, err)
		}
		// Rolled back with the change: an action that does not commit leaves no entry, and one that commits leaves both.
		tx.Rollback(ctx)
		if e.count(`SELECT count(*) FROM operator_audit WHERE target_id=$1 AND action IN ('evidence_proposed','evidence_approved','content_case_clear')`, caseID) != 0 {
			t.Fatal("an entry outlived its rolled-back transaction")
		}
	}()
	tx, err := adm.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SELECT set_config('hiyall.ip','203.0.113.0/24',true)`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SELECT evidence_propose($1::uuid,$2::uuid,'clear',$3::uuid,'a sufficient reason','')`, approval, caseID, one.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SELECT evidence_decide($1::uuid,$2::uuid,'approve','looked again')`, approval, two.ID); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	for action, want := range map[string]struct{ actor, op string }{
		"evidence_proposed": {one.Email, one.ID}, "evidence_approved": {two.Email, two.ID}, "content_case_clear": {two.Email, two.ID},
	} {
		var actor, op, ip, reason string
		if err = e.db.Pool.QueryRow(ctx, `SELECT actor,operator_id::text,ip,reason FROM operator_audit WHERE target_id=$1 AND action=$2`, caseID, action).Scan(&actor, &op, &ip, &reason); err != nil {
			t.Fatalf("%s: %v", action, err)
		}
		if actor != want.actor || op != want.op || ip != "203.0.113.0/24" || reason == "" {
			t.Errorf("%s audit: actor=%s operator=%s ip=%s reason=%q", action, actor, op, ip, reason)
		}
	}
	var detail string
	if err = e.db.Pool.QueryRow(ctx, `SELECT detail::text FROM operator_audit WHERE target_id=$1 AND action='content_case_clear'`, caseID).Scan(&detail); err != nil || !strings.Contains(detail, one.Email) || !strings.Contains(detail, two.Email) {
		t.Fatalf("the clearing entry does not name both administrators: %s %v", detail, err)
	}

	// A refused call writes nothing; confirming, reporting and a role change are audited by their functions too.
	before := e.count(`SELECT count(*) FROM operator_audit`)
	if code := e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,'approve','again')`, approval, one.ID); code == "" {
		t.Fatal("a decided proposal was decided again")
	}
	if e.count(`SELECT count(*) FROM operator_audit`) != before {
		t.Fatal("a refused call wrote an audit entry")
	}
	open1, _, _ := e.pendingQuarantine(e.member(false), "match", objects)
	if code := e.sqlCode(`SELECT content_case_confirm($1::uuid,$2::uuid,'confirmed by the scanner team')`, open1, one.ID); code != "" {
		t.Fatal(code)
	}
	if code := e.sqlCode(`SELECT content_case_report($1::uuid,$2::uuid,'reported','NCMEC-12345')`, open1, one.ID); code != "" {
		t.Fatal(code)
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE target_id=$1 AND operator_id=$2 AND action IN ('content_case_confirm','content_case_reported')`, open1, one.ID) != 2 {
		t.Fatal("confirm and report were not audited by their functions")
	}
	oneRoleTx(t, e.db.Pool, func(tx pgx.Tx) {
		c := context.Background()
		if _, err := tx.Exec(c, `SELECT set_config('hiyall.reason','making a viewer a moderator',true),set_config('hiyall.ip','198.51.100.0/24',true)`); err != nil {
			t.Fatal(err)
		}
		viewer := e.operator(RoleViewer)
		if code := txCode(t, tx, `SELECT operator_set_role($1::uuid,'moderator',$2::uuid)`, viewer.ID, one.ID); code != "" {
			t.Fatal(code)
		}
		var actor, reason, ip string
		if err := tx.QueryRow(c, `SELECT actor,reason,ip FROM operator_audit WHERE action='operator_role' AND target_id=$1`, viewer.ID).Scan(&actor, &reason, &ip); err != nil || actor != one.Email || reason != "making a viewer a moderator" || ip != "198.51.100.0/24" {
			t.Fatalf("role audit: %s %s %s %v", actor, reason, ip, err)
		}
	})
}

// A proposal by an administrator who is no longer one cannot be approved, and disabling or demoting one withdraws what
// they proposed; this includes a pending promotion.
func TestAProposalByADisabledOrDemotedAdministratorCannotBeApproved(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	proposer, approver, third := e.operator(RoleAdmin), e.operator(RoleAdmin), e.operator(RoleAdmin)
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	target := e.operator(RoleModerator)

	propose := func(kind string) string {
		id := uuid.NewString()
		if code := e.sqlCode(`SELECT evidence_propose($1::uuid,$2::uuid,$3,$4::uuid,'a sufficient reason','')`, id, caseID, kind, proposer.ID); code != "" {
			t.Fatalf("propose %s: %q", kind, code)
		}
		return id
	}
	clear := propose("clear")
	promotion := uuid.NewString()
	if code := e.sqlCode(`SELECT operator_promotion_propose($1::uuid,$2::uuid,$3::uuid,'a sufficient reason')`, promotion, target.ID, proposer.ID); code != "" {
		t.Fatal(code)
	}
	// The proposer is disabled behind the function's back (a console that skips it, the CLI emergency path in an older
	// build): the approval is refused all the same, and the case and the target are unchanged.
	e.exec(`UPDATE operators SET disabled_at=now() WHERE operator_id=$1`, proposer.ID)
	if code := e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,'approve','looked again')`, clear, approver.ID); code != "PROPOSER_NOT_ADMIN" {
		t.Fatalf("approving a disabled proposer's clear: %q", code)
	}
	if code := e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,'approve','looked again')`, promotion, approver.ID); code != "PROPOSER_NOT_ADMIN" {
		t.Fatalf("approving a disabled proposer's promotion: %q", code)
	}
	if st, _, _ := e.caseState(caseID); st != "open" {
		t.Fatal("the case was cleared")
	}
	var role string
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT role FROM operators WHERE operator_id=$1`, target.ID).Scan(&role); err != nil || role != "moderator" {
		t.Fatalf("the target became %s", role)
	}
	// It can still be rejected, so the queue can be cleared.
	if code := e.sqlCode(`SELECT evidence_decide($1::uuid,$2::uuid,'reject','the proposer left')`, promotion, approver.ID); code != "" {
		t.Fatalf("rejecting: %q", code)
	}

	// Through the function: disabling an administrator withdraws what they proposed, demoting one does too.
	e.exec(`UPDATE operators SET disabled_at=NULL WHERE operator_id=$1`, proposer.ID)
	e.exec(`UPDATE evidence_approvals SET status='expired' WHERE approval_id=$1 AND status='pending'`, clear)
	again := propose("clear")
	var remaining int
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT operator_set_disabled($1::uuid,true,$2::uuid,'cli:test','proposer left the team',false)`, proposer.ID, third.ID).Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if e.count(`SELECT count(*) FROM evidence_approvals WHERE proposed_by=$1 AND status='pending'`, proposer.ID) != 0 {
		t.Fatal("a disabled administrator's proposal is still pending")
	}
	if e.count(`SELECT count(*) FROM evidence_approvals WHERE approval_id=$1 AND status='withdrawn'`, again) != 1 {
		t.Fatal("the proposal was not withdrawn")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='operator_disable' AND target_id=$1 AND operator_id=$2 AND (detail->>'withdrawnProposals')::int=1`, proposer.ID, third.ID) != 1 {
		t.Fatal("the disabling was not audited with the withdrawn proposals")
	}
	// A demotion: the proposal of a second administrator, withdrawn by operator_set_role.
	id := uuid.NewString()
	if code := e.sqlCode(`SELECT evidence_propose($1::uuid,$2::uuid,'legal_hold_lift',$3::uuid,'a sufficient reason','counsel ref 123')`, id, caseID, approver.ID); code == "" {
		t.Fatal("a legal hold lift on a case without a legal hold was accepted")
	}
	id = uuid.NewString()
	if code := e.sqlCode(`SELECT evidence_propose($1::uuid,$2::uuid,'release',$3::uuid,'a sufficient reason','')`, id, caseID, approver.ID); code != "HOLD_CASE_OPEN" {
		t.Fatalf("release of an open case: %q", code)
	}
}

// ---- N-4: the Apple records

func TestMemberInformedAppleRecordsArePrunedAfterNinetyDaysAndNothingElseIs(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	e.exec(`DELETE FROM apple_revocations`)
	old, fresh, manual, queued := e.appleRecord(e.member(false), "member_informed"), e.appleRecord(e.member(false), "member_informed"), e.manualRevocation(e.member(false)), uuid.NewString()
	e.exec(`INSERT INTO apple_revocations(revocation_id,issuer,subject,token_sealed) VALUES($1,'https://securetoken.google.com/test',$2,'\xdeadbeef')`, queued, "q-"+queued)
	for _, id := range []string{old, manual, queued} {
		e.exec(`UPDATE apple_revocations SET created_at=now()-interval '120 days' WHERE revocation_id=$1`, id)
	}
	e.asRole("hiyall_admin")
	n, err := e.svc.Store.PruneAppleRecords(e.ctx, 90)
	if err != nil || n != 1 {
		t.Fatalf("pruned %d: %v", n, err)
	}
	for id, want := range map[string]int{old: 0, fresh: 1, manual: 1, queued: 1} {
		if got := e.count(`SELECT count(*) FROM apple_revocations WHERE revocation_id=$1`, id); got != want {
			t.Errorf("record %s: %d rows, want %d", id, got, want)
		}
	}
	if _, err = e.svc.Store.PruneAppleRecords(e.ctx, 3); err == nil {
		t.Fatal("a 3 day prune was accepted")
	}
	// The sweep's job list carries it.
	found := false
	for _, j := range e.svc.SweepJobs() {
		found = found || j.Name == "apple record prune"
	}
	if !found {
		t.Fatal("the apple record prune is not in the console's timer")
	}
}

// ---- N-7: the evidence bucket probe

func TestEvidenceProbeGatesTheSweepAndThePurge(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Evidence = objects
	e.svc.EvidenceDelete = objects
	e.svc.cfg.EvidenceBucket = "hiyall-evidence"
	owner := e.member(false)
	flagged, flaggedMedia := e.pendingCase(owner, "flagged") // its objects are NOT in this bucket
	e.exec(`UPDATE content_cases SET created_at=now()-interval '2 hours' WHERE case_id=$1`, flagged)

	// No marker: this console cannot show it reads the API's bucket. The sweep does nothing and says so; the flagged case
	// whose objects "are missing" is NOT dropped.
	if _, err := e.svc.SweepEvidence(e.ctx); !errors.Is(err, ErrEvidenceProbe) {
		t.Fatalf("the sweep without a marker: %v", err)
	}
	if st, _, _ := e.caseState(flagged); st != "pending" {
		t.Fatalf("a case was dropped or opened on an unproven bucket: %s", st)
	}
	if e.count(`SELECT count(*) FROM media_assets WHERE media_id=$1 AND status='deleted'`, flaggedMedia) != 0 {
		t.Fatal("an upload was marked deleted on an unproven bucket")
	}
	// A marker for another bucket: the same.
	_ = objects.Put(e.ctx, media.EvidenceBucketMarker, []byte("some-other-bucket\n"), "text/plain")
	if _, err := e.svc.SweepEvidence(e.ctx); !errors.Is(err, ErrEvidenceProbe) || !strings.Contains(err.Error(), "some-other-bucket") {
		t.Fatalf("the sweep with another bucket's marker: %v", err)
	}
	// The purge does nothing either: a released hold's objects stay.
	done, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	e.exec(`UPDATE content_cases SET status='cleared',released_at=now(),hold_until=now()-interval '1 day' WHERE case_id=$1`, done)
	if n, err := e.svc.PurgeHolds(e.ctx, 5); !errors.Is(err, ErrEvidenceProbe) || n != 0 {
		t.Fatalf("the purge with another bucket's marker: %d %v", n, err)
	}
	if e.count(`SELECT count(*) FROM content_cases WHERE case_id=$1 AND objects_purged_at IS NULL`, done) != 1 {
		t.Fatal("the purge recorded a case on an unproven bucket")
	}
	// The right marker, the right bucket: the sweep drops the flagged case with missing objects, the purge runs.
	_ = objects.Put(e.ctx, media.EvidenceBucketMarker, []byte("hiyall-evidence"), "text/plain")
	if n, err := e.svc.SweepEvidence(e.ctx); err != nil || n < 1 {
		t.Fatalf("the sweep with the right marker: %d %v", n, err)
	}
	if e.count(`SELECT count(*) FROM content_cases WHERE case_id=$1`, flagged) != 0 {
		t.Fatal("a flagged case with missing objects was kept on a proven bucket")
	}
	if n, err := e.svc.PurgeHolds(e.ctx, 5); err != nil || n < 1 {
		t.Fatalf("the purge with the right marker: %d %v", n, err)
	}
	// A bucket that cannot be listed is a failed probe too.
	e.svc.Evidence = failingLister{Memory: objects}
	if err := e.svc.EvidenceProbe(e.ctx); !errors.Is(err, ErrEvidenceProbe) {
		t.Fatalf("an unlistable bucket: %v", err)
	}
}

type failingLister struct{ *media.Memory }

func (failingLister) List(context.Context, string, int) ([]media.ObjectInfo, error) {
	return nil, errors.New("NoSuchBucket")
}

// A pending case for a scanner MATCH is never dropped, not by the sweep and not by the database function either.
func TestAMatchCaseIsNeverDroppedByTheSweepOrTheFunction(t *testing.T) {
	e := newEnv(t)
	e.svc.Evidence = media.NewMemory()
	match, _ := e.pendingCase(e.member(false), "match")
	e.exec(`UPDATE content_cases SET created_at=now()-interval '3 hours' WHERE case_id=$1`, match)
	for i := 0; i < 2; i++ {
		if n, err := e.svc.SweepEvidence(e.ctx); err != nil || n != 0 {
			t.Fatalf("sweep %d: %d %v", i, n, err)
		}
	}
	var dropped bool
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT drop_pending_case($1::uuid,'test')`, match).Scan(&dropped); err != nil || dropped {
		t.Fatalf("drop_pending_case dropped a match: %v %v", dropped, err)
	}
	if st, _, _ := e.caseState(match); st != "pending" {
		t.Fatalf("the match case is %s", st)
	}
	// Reported once in the audit log, however many sweeps ran.
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='pending_match_case_stuck' AND target_id=$1`, match) != 1 {
		t.Fatal("the stuck match was not audited exactly once")
	}
}

// ---- N-12

// The orphan report is the database's, so another console node answers the same.
func TestEvidenceOrphansAreAnsweredFromTheDatabaseOnAnyNode(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	e.svc.Evidence = objects
	orphan := uuid.NewString()
	o, f := media.HoldKeys(orphan)
	_ = objects.Put(e.ctx, o, []byte("x"), "")
	_ = objects.Put(e.ctx, f, []byte("x"), "")
	objects.Modified[o], objects.Modified[f] = time.Now().Add(-3*time.Hour), time.Now().Add(-3*time.Hour)
	if _, err := e.svc.SweepEvidence(e.ctx); err != nil {
		t.Fatal(err)
	}
	other, err := NewService(e.db, testConfig()) // a second console node: it has never swept
	if err != nil {
		t.Fatal(err)
	}
	rep, err := other.EvidenceOrphans(e.ctx)
	if err != nil || rep.CheckedAt == nil || len(rep.Items) < 2 {
		t.Fatalf("another node's view: %+v %v", rep, err)
	}
	found := 0
	for _, it := range rep.Items {
		if it.MediaID == orphan {
			found++
		}
	}
	if found != 2 {
		t.Fatalf("the orphan's objects: %d listed", found)
	}
	// And over HTTP from that node.
	srv := NewServer(other, other.cfg)
	e.srv, e.h = srv, srv.Handler()
	adm := e.session(e.operator(RoleAdmin))
	if r := e.get(adm, "/admin/v1/evidence/orphans"); r.status != 200 || !strings.Contains(string(r.raw), orphan) {
		t.Fatalf("orphans over HTTP: %d %s", r.status, r.raw)
	}
}

// slowDelete blocks inside Delete until released, so a test can act while a purge holds its row lock.
type slowDelete struct {
	*media.Memory
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (s *slowDelete) Delete(ctx context.Context, keys ...string) error {
	s.once.Do(func() { close(s.entered) })
	<-s.release
	return s.Memory.Delete(ctx, keys...)
}

// The purge holds a share lock on the case row across its object deletes: a legal hold (an UPDATE of the row) waits for it.
func TestHoldPurgeLocksTheCaseRowAcrossTheObjectDelete(t *testing.T) {
	e := newEnv(t)
	objects := media.NewMemory()
	caseID, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	e.exec(`UPDATE content_cases SET status='cleared',released_at=now(),hold_until=now()-interval '1 day' WHERE case_id=$1`, caseID)
	slow := &slowDelete{Memory: objects, entered: make(chan struct{}), release: make(chan struct{})}
	e.svc.EvidenceDelete = slow
	var wg sync.WaitGroup
	var purged int64
	var perr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		purged, perr = e.svc.PurgeHolds(e.ctx, 1)
	}()
	select {
	case <-slow.entered:
	case <-time.After(10 * time.Second):
		t.Fatal("the purge never reached its first delete")
	}
	// A legal hold set now has to wait: with a 300 ms lock timeout it gives up instead.
	tx, err := e.db.Pool.Begin(e.ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(e.ctx, `SET LOCAL lock_timeout='300ms'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(e.ctx, `UPDATE content_cases SET legal_hold=true WHERE case_id=$1`, caseID)
	tx.Rollback(e.ctx)
	if pgCode(err) != "55P03" {
		t.Errorf("a legal hold was set while the purge held the row: %v", err)
	}
	close(slow.release)
	wg.Wait()
	if perr != nil || purged != 1 {
		t.Fatalf("purge: %d %v", purged, perr)
	}
	// After the purge the row is free.
	e.exec(`UPDATE content_cases SET legal_hold=true WHERE case_id=$1`, caseID)
}

// Support-driven deletion works for a suspended member, and a member suspended when it was scheduled cannot cancel it.
func TestSupportDeletionOfASuspendedMemberCannotBeCancelledByTheMember(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleAdmin)
	suspended := e.member(false)
	e.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, suspended)
	active := e.member(false)
	other := e.member(false)
	e.exec(`UPDATE users SET status='deactivated' WHERE user_id=$1`, other)
	for _, u := range []string{suspended, active, other} {
		if _, err := e.db.AdminScheduleDeletion(e.ctx, u, op.Email, "an erasure request received by support"); err != nil {
			t.Fatalf("schedule for %s: %v", u, err)
		}
	}
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='pending_deletion' AND deletion_prior_status='suspended'`, suspended) != 1 {
		t.Fatal("the suspended member was not scheduled with their prior status recorded")
	}
	if _, err := e.db.CancelDeletion(e.ctx, suspended); !errors.Is(err, domain.ErrDeletionClosed) {
		t.Fatal("a suspended member cancelled their deletion")
	}
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='pending_deletion'`, suspended) != 1 {
		t.Fatal("the cancel changed a suspended member's deletion")
	}
	if _, err := e.db.CancelDeletion(e.ctx, active); err != nil {
		t.Fatalf("an active member could not cancel: %v", err)
	}
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='active' AND deletion_prior_status IS NULL`, active) != 1 {
		t.Fatal("the active member was not restored")
	}
	if _, err := e.db.CancelDeletion(e.ctx, other); err != nil {
		t.Fatal(err)
	}
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='deactivated'`, other) != 1 {
		t.Fatal("a deactivated member came back active")
	}
	// The operator must be a named, active administrator: a shell user, a viewer or nothing is refused.
	victim := e.member(false)
	for _, who := range []string{"cli:root", "root", "", "nobody@hiyall.test", e.operator(RoleViewer).Email} {
		if _, err := e.db.AdminScheduleDeletion(e.ctx, victim, who, "an erasure request received by support"); err == nil {
			t.Fatalf("scheduled as %q", who)
		}
	}
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='active'`, victim) != 1 {
		t.Fatal("a refused request changed the member")
	}
}

// Disabling an operator over HTTP says how many administrators are active afterwards, and warns below two.
func TestDisablingAnOperatorReportsTheActiveAdministrators(t *testing.T) {
	e := newEnv(t)
	adm := e.session(e.operator(RoleAdmin))
	e.operator(RoleAdmin) // at least two active
	viewer := e.operator(RoleViewer)
	var out struct {
		ActiveAdmins       *int
		TwoPersonAvailable *bool
		Warning            string
	}
	r := e.post(adm, "/admin/v1/operators/"+viewer.ID+"/disable", map[string]string{"reason": "left the team last week"})
	r.data(&out)
	if r.status != 200 || out.ActiveAdmins == nil || *out.ActiveAdmins < 2 || out.TwoPersonAvailable == nil || !*out.TwoPersonAvailable || out.Warning != "" {
		t.Fatalf("disable: %d %s", r.status, r.raw)
	}
	// Re-enabling reports it too.
	r = e.post(adm, "/admin/v1/operators/"+viewer.ID+"/enable", map[string]string{"reason": "came back after all"})
	if r.status != 200 || !strings.Contains(string(r.raw), "activeAdmins") {
		t.Fatalf("enable: %d %s", r.status, r.raw)
	}
	// The console's own account cannot be disabled by itself, and the answer is the function's.
	self := e.operator(RoleAdmin)
	r = e.post(e.session(self), "/admin/v1/operators/"+self.ID+"/disable", map[string]string{"reason": "disabling myself now"})
	if r.status != 409 || (r.code() != "SELF_DISABLE" && r.code() != "LAST_ADMIN") {
		t.Fatalf("self disable: %d %s", r.status, r.raw)
	}
}
