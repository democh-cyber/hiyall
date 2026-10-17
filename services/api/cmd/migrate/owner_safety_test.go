package main

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/store"
)

// ownerSafetyFunctions calls every definer function that database/roles/grants.sql grants (round-4 audit N9), on the
// database the owner-path test built the way production does (migrations and grants as hiyall_migrate, not a
// superuser), once as the owner and once as the role each function is granted to. A statement in a function that
// needs more than its owner's rights, or a grant that does not reach the role that calls it, fails here and not in
// production. The final check refuses a grants.sql that gains a function this test does not call.
func ownerSafetyFunctions(t *testing.T, ctx context.Context, super, owner, admin, api *pgx.Conn) {
	t.Helper()
	covered := map[string]bool{}
	run := func(c *pgx.Conn, fn, q string, args ...any) string {
		t.Helper()
		var out *string
		if err := c.QueryRow(ctx, q, args...).Scan(&out); err != nil {
			t.Fatalf("%s: %s: %v", fn, q, err)
		}
		covered[fn] = true
		if out == nil {
			return ""
		}
		return *out
	}
	exec := func(c *pgx.Conn, fn, q string, args ...any) {
		t.Helper()
		if _, err := c.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %s: %v", fn, q, err)
		}
		covered[fn] = true
	}
	str := func(q string, args ...any) string {
		t.Helper()
		var s string
		if err := super.QueryRow(ctx, q, args...).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return s
	}
	newUser := func() string {
		return str(`INSERT INTO users(user_id) VALUES(gen_random_uuid()) RETURNING user_id::text`)
	}
	newOperator := func(tag, role string) string {
		return str(`INSERT INTO operators(operator_id,email,display_name,role,password_hash,totp_secret) VALUES(gen_random_uuid(),$1,'Op','`+role+`','x','\x01') RETURNING operator_id::text`, tag+"@example.test")
	}
	// A case of its own member: status, scanner result, and whether the hold was released and is due.
	newCase := func(user, status, result string, released bool) string {
		return str(`WITH m AS (INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,attached,expires_at,declared_bytes)
  VALUES(gen_random_uuid(),$1,'post','quarantined','image/jpeg',10,'k',false,now(),10) RETURNING media_id)
 INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,original_sha256,original_bytes,content_type,original_key,status,created_at,hold_until,released_at,released_by,release_reason)
 SELECT gen_random_uuid(),m.media_id,$1,'post',$3,'test','x',10,'image/jpeg','hold/'||m.media_id||'/original',$2,now()-interval '2 hours',
  CASE WHEN $4 THEN now()-interval '1 day' ELSE now()+interval '300 days' END, CASE WHEN $4 THEN now()-interval '2 days' END, CASE WHEN $4 THEN 'a' END, CASE WHEN $4 THEN 'b' END FROM m
 RETURNING case_id::text`, user, status, result, released)
	}

	scenario := func(tag string, as, asAPI *pgx.Conn) {
		t.Helper()
		a, b, c := newOperator("a-"+tag, "admin"), newOperator("b-"+tag, "admin"), newOperator("c-"+tag, "viewer")

		// Two-person clearing of a case: one proposes, the other approves.
		open := newCase(newUser(), "open", "flagged", false)
		p := run(as, "evidence_propose", `SELECT evidence_propose(gen_random_uuid(),$1,'clear',$2,'looks fine',NULL)::text`, open, a)
		if got := run(as, "evidence_decide", `SELECT evidence_decide($1,$2,'approve','agreed')`, p, b); got != "approved" {
			t.Fatalf("%s: evidence_decide returned %q", tag, got)
		}
		if got := str(`SELECT status FROM content_cases WHERE case_id=$1`, open); got != "cleared" {
			t.Fatalf("%s: the case is %q, want cleared", tag, got)
		}
		// A promotion to administrator needs a second administrator; the new one can be demoted again.
		pp := run(as, "operator_promotion_propose", `SELECT operator_promotion_propose(gen_random_uuid(),$1,$2,'needs the role')::text`, c, a)
		run(as, "evidence_decide", `SELECT evidence_decide($1,$2,'approve','agreed')`, pp, b)
		if got := str(`SELECT role FROM operators WHERE operator_id=$1`, c); got != "admin" {
			t.Fatalf("%s: operator %q, want admin", tag, got)
		}
		exec(as, "operator_set_role", `SELECT operator_set_role($1,'moderator',$2)`, c, a)
		if got := str(`SELECT role FROM operators WHERE operator_id=$1`, c); got != "moderator" {
			t.Fatalf("%s: operator %q, want moderator", tag, got)
		}
		// Creating, disabling and enabling an operator.
		id := str(`SELECT gen_random_uuid()::text`)
		exec(as, "operator_create", `SELECT operator_create($1,$2,'New','moderator','hash','\x02',$3,NULL)`, id, "new-"+tag+"@example.test", a)
		if n := run(as, "operator_set_disabled", `SELECT operator_set_disabled($1,true,$2,NULL,'left the team',false)::text`, id, a); n == "" {
			t.Fatalf("%s: operator_set_disabled returned nothing", tag)
		}
		run(as, "operator_set_disabled", `SELECT operator_set_disabled($1,false,$2,NULL,'came back',false)::text`, id, a)
		run(as, "evidence_expire_due", `SELECT evidence_expire_due()::text`)
		// Confirming and reporting a case.
		confirmed := newCase(newUser(), "open", "match", false)
		run(as, "content_case_confirm", `SELECT content_case_confirm($1,$2,'confirmed')::text`, confirmed, a)
		run(as, "content_case_report", `SELECT content_case_report($1,$2,'reported','REF-1')::text`, confirmed, a)
		// Pending cases: the sweep lists them, drops a flagged one (its photo gets a deletion time), and the upload
		// path activates one it has written the objects of.
		flagged := newCase(newUser(), "pending", "flagged", false)
		if n := run(as, "pending_cases_due", `SELECT count(*)::text FROM pending_cases_due(10)`); n == "0" {
			t.Fatalf("%s: pending_cases_due lists nothing", tag)
		}
		if got := run(as, "drop_pending_case", `SELECT drop_pending_case($1,'sweep')::text`, flagged); got != "true" {
			t.Fatalf("%s: drop_pending_case returned %q", tag, got)
		}
		if got := str(`SELECT count(*)::text FROM media_assets WHERE status='deleted' AND deleted_at IS NOT NULL AND variants IS NULL AND media_id NOT IN (SELECT media_id FROM content_cases)`); got == "0" {
			t.Fatalf("%s: the dropped case's photo has no deleted_at", tag)
		}
		match := newCase(newUser(), "pending", "match", false)
		if got := run(asAPI, "activate_quarantine_case", `SELECT activate_quarantine_case($1)::text`, match); got != "true" {
			t.Fatalf("%s: activate_quarantine_case returned %q", tag, got)
		}
		run(as, "activate_quarantine_case", `SELECT activate_quarantine_case($1)::text`, match) // already open: false, and no error
		// A released hold whose window is over: listed, still releasable, locked for the purge, then recorded as purged.
		held := newCase(newUser(), "cleared", "flagged", true)
		if got := run(asAPI, "hold_still_releasable", `SELECT hold_still_releasable($1)::text`, held); got != "true" {
			t.Fatalf("%s: hold_still_releasable returned %q", tag, got)
		}
		if got := run(asAPI, "hold_lock_for_purge", `SELECT hold_lock_for_purge($1)::text`, held); got != "true" {
			t.Fatalf("%s: hold_lock_for_purge returned %q", tag, got)
		}
		run(as, "hold_lock_for_purge", `SELECT hold_lock_for_purge($1)::text`, held)
		run(as, "held_objects_due", `SELECT count(*)::text FROM held_objects_due(10)`)
		if got := run(asAPI, "held_objects_due", `SELECT count(*)::text FROM held_objects_due(10)`); got == "0" {
			t.Fatalf("%s: held_objects_due lists nothing", tag)
		}
		if got := run(asAPI, "mark_hold_purged", `SELECT mark_hold_purged($1)::text`, held); got != "true" {
			t.Fatalf("%s: mark_hold_purged returned %q", tag, got)
		}
		run(as, "mark_hold_purged", `SELECT mark_hold_purged($1)::text`, held) // already purged: false
		// Support-driven deletion of a member who signed in with Apple, and the record it leaves for an operator.
		member := newUser()
		str(`INSERT INTO auth_identities(issuer,subject,user_id,sign_in_provider) VALUES('https://appleid.apple.com',$2,$1,'apple.com') RETURNING subject`, member, "s-"+tag)
		run(as, "admin_schedule_deletion", `SELECT admin_schedule_deletion($1,$2,'erasure request','deletion_channel','n')::text`, member, "a-"+tag+"@example.test")
		rev := str(`SELECT revocation_id::text FROM apple_revocations WHERE user_id=$1`, member)
		exec(as, "apple_revocation_acknowledge", `SELECT apple_revocation_acknowledge($1,$2,'told the member')`, rev, a)
		run(as, "apple_revocations_prune", `SELECT apple_revocations_prune(30)::text`)
		// Queue numbers and the audit prune.
		run(asAPI, "safety_queue_stats", `SELECT pending_approvals::text FROM safety_queue_stats()`)
		run(as, "safety_queue_stats", `SELECT pending_approvals::text FROM safety_queue_stats()`)
		run(as, "prune_operator_audit", `SELECT prune_operator_audit(NULL,'owner-path test','nothing is old enough',365)::text`)
	}
	scenario("owner", owner, owner)
	scenario("roles", admin, api)

	// Every function grants.sql grants is called above.
	for _, g := range store.ExpectedGrants {
		if g.Kind != "function" {
			continue
		}
		for _, sig := range g.Objects {
			name, _, _ := strings.Cut(sig, "(")
			if !covered[name] {
				t.Errorf("grants.sql grants EXECUTE on %s, but the owner-path test never calls it: add it to ownerSafetyFunctions", sig)
			}
		}
	}
}
