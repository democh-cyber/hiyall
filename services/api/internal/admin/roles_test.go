package admin

import (
	"context"
	"errors"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// The least-privilege roles of database/roles/roles.sql (docs/security/15-admin-console.md). The script needs a
// superuser or CREATEROLE, which the test database user has locally and in CI; without it the tests skip.

const rolesScriptPath = "../../../../database/roles/roles.sql"
const grantsScriptPath = "../../../../database/roles/grants.sql"

func applyRoles(t *testing.T, e *env) {
	t.Helper()
	first, err := os.ReadFile(rolesScriptPath)
	if err != nil {
		t.Fatal(err)
	}
	second, err := os.ReadFile(grantsScriptPath)
	if err != nil {
		t.Fatal(err)
	}
	script := append(append(first, '\n'), second...)
	conn, err := e.db.Pool.Acquire(e.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	// Roles are cluster wide and the script is idempotent; serialize runs from parallel test packages.
	if _, err = conn.Exec(e.ctx, `SELECT pg_advisory_lock(4917399)`); err != nil {
		t.Fatal(err)
	}
	defer conn.Exec(context.WithoutCancel(e.ctx), `SELECT pg_advisory_unlock(4917399)`)
	if _, err = conn.Exec(e.ctx, string(script)); err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "42501" {
			t.Skipf("the test database user cannot create roles: %v", err)
		}
		t.Fatal(err)
	}
}

// roleDSN connects as the test user and immediately SET ROLEs, so every statement runs with only that role's grants.
func roleDSN(t *testing.T, role string) string {
	t.Helper()
	u, err := url.Parse(adminTestDSN(t))
	if err != nil {
		t.Fatal(err)
	}
	if u.RawQuery != "" {
		u.RawQuery += "&"
	}
	u.RawQuery += "options=-c%20role%3D" + role
	return u.String()
}

func rolePool(t *testing.T, role string) *pgxpool.Pool {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), roleDSN(t, role))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func denied(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "42501"
}

func TestDatabaseRolesHaveLeastPrivilege(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	api, adm := rolePool(t, "hiyall_api"), rolePool(t, "hiyall_admin")
	ctx := context.Background()

	// The API role cannot read, write or reach any operator table, or the audit log's sequence.
	for _, q := range []string{
		`SELECT count(*) FROM operators`, `SELECT count(*) FROM operator_sessions`, `SELECT count(*) FROM operator_login_attempts`, `SELECT count(*) FROM operator_audit`,
		`INSERT INTO operator_audit(actor,action) VALUES('api','x')`, `UPDATE operators SET role='admin'`, `DELETE FROM operator_sessions`,
		`SELECT nextval('operator_audit_audit_id_seq')`,
		// It cannot read or change cases, only open one; it cannot rewrite migration history.
		`SELECT status FROM content_cases`, `SELECT user_id, original_key FROM content_cases`, `SELECT * FROM content_cases`, `UPDATE content_cases SET status='cleared'`, `INSERT INTO schema_migrations(version,checksum) VALUES('x','y')`,
		// Nor change the schema or the trigger that protects the audit log.
		`ALTER TABLE operator_audit DISABLE TRIGGER ALL`, `DROP TABLE operator_audit`, `CREATE TABLE api_made(x int)`, `TRUNCATE users CASCADE`,
	} {
		if _, err := api.Exec(ctx, q); !denied(err) {
			t.Errorf("hiyall_api ran %q: %v", q, err)
		}
	}
	// What it needs works (the statements do nothing when the table is empty or the row absent).
	for _, q := range []string{`SELECT count(*) FROM users`, `UPDATE sessions SET revoked_at=revoked_at WHERE false`, `SELECT count(*) FROM schema_migrations`, `SELECT count(*) FROM media_assets`, `SELECT count(*) FROM apple_revocations`,
		// A view reads with its owner's rights; the one column of content_cases the tombstone purge needs.
		`SELECT count(*) FROM profile_social_counts`, `SELECT media_id FROM content_cases WHERE false`} {
		if _, err := api.Exec(ctx, q); err != nil {
			t.Errorf("hiyall_api refused %q: %v", q, err)
		}
	}

	// The console role appends to and reads the audit log, and nothing else on it, even though the
	// trigger would also refuse: the grant is the first line.
	if _, err := adm.Exec(ctx, `INSERT INTO operator_audit(actor,action,reason) VALUES('role-test','role_test','privilege check')`); err != nil {
		t.Fatalf("append: %v", err)
	}
	if _, err := adm.Exec(ctx, `SELECT count(*) FROM operator_audit`); err != nil {
		t.Fatalf("read: %v", err)
	}
	for _, q := range []string{
		`UPDATE operator_audit SET reason='x'`, `DELETE FROM operator_audit`, `TRUNCATE operator_audit`,
		`ALTER TABLE operator_audit DISABLE TRIGGER operator_audit_no_change`, `DROP TRIGGER operator_audit_no_change ON operator_audit`, `DROP TABLE operator_audit`,
		// Tables the console has no business with.
		`SELECT count(*) FROM messages`, `SELECT count(*) FROM message_envelopes`, `SELECT count(*) FROM user_locations`, `SELECT count(*) FROM profile_visits`,
		`SELECT count(*) FROM devices`, `UPDATE profiles SET username=username`, `DELETE FROM posts`, `INSERT INTO schema_migrations(version,checksum) VALUES('x','y')`,
	} {
		if _, err := adm.Exec(ctx, q); !denied(err) {
			t.Errorf("hiyall_admin ran %q: %v", q, err)
		}
	}
	// The trigger still stops the owner-less paths a grant cannot: it is there for the superuser and migrate role.
	if _, err := e.db.Pool.Exec(ctx, `UPDATE operator_audit SET reason='x' WHERE actor='role-test'`); err == nil || !strings.Contains(err.Error(), "append-only") {
		t.Fatalf("trigger: %v", err)
	}
}

// asRole runs the console on a database role instead of the test user. Fixtures still use e.db.
func (e *env) asRole(role string) {
	e.t.Helper()
	db, err := store.New(e.ctx, roleDSN(e.t, role))
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(db.Pool.Close)
	svc, err := NewService(db, testConfig())
	if err != nil {
		e.t.Fatal(err)
	}
	svc.Now = func() time.Time { return e.clock }
	e.svc, e.srv = svc, NewServer(svc, svc.cfg)
	e.h = e.srv.Handler()
}

func TestConsoleWorksEndToEndOnTheRestrictedAdminRole(t *testing.T) {
	e := newEnv(t)
	applyRoles(t, e)
	e.asRole("hiyall_admin")
	objects := media.NewMemory()
	e.svc.Media = objects

	// Real sign-in (attempt log, session, last login), then the work every role does.
	op := e.operator(RoleAdmin)
	login := e.login(op, op.password, e.nextCode(op), "")
	c := sessionCookie(login)
	if login.status != 200 || c == nil {
		t.Fatalf("login: %d %s", login.status, login.raw)
	}
	s := sess{token: c.Value, csrf: e.svc.csrfFor(c.Value)}
	f := e.contentFixture(objects)
	minorReport := e.report(e.member(true), f.author, "sexual_content")

	ok := func(r reply, what string) reply {
		t.Helper()
		if r.status != 200 {
			t.Fatalf("%s on the admin role: %d %s", what, r.status, r.raw)
		}
		return r
	}
	ok(e.get(s, "/admin/v1/me"), "me")
	ok(e.get(s, "/admin/v1/reports?status=all&limit=5"), "queue")
	ok(e.get(s, "/admin/v1/reports/"+minorReport), "case")
	ok(e.get(s, "/admin/v1/users/"+f.author+"?identity=true"), "user with identity")
	ok(e.post(s, "/admin/v1/reports/"+f.reports["post"]+"/content", map[string]string{"reason": "preview on the restricted role"}), "content")
	ok(e.post(s, "/admin/v1/reports/"+minorReport+"/resolve", map[string]any{"action": "suspend", "reason": "suspending on the restricted role", "confirm": true}), "suspend")
	if e.count(`SELECT count(*) FROM users WHERE user_id=$1 AND status='suspended'`, f.author) != 1 {
		t.Fatal("suspend did not suspend")
	}
	ok(e.post(s, "/admin/v1/users/"+f.author+"/restore", map[string]string{"reason": "restoring on the restricted role"}), "restore")
	ok(e.post(s, "/admin/v1/reports/"+f.reports["comment"]+"/resolve", map[string]any{"action": "warn", "reason": "warning on the restricted role"}), "warn")

	// Quarantine cases: list, view, reveal, resolve.
	caseID, _, _ := e.pendingQuarantine(e.member(false), "match", objects)
	ok(e.get(s, "/admin/v1/content-cases"), "case list")
	ok(e.get(s, "/admin/v1/content-cases/"+caseID), "case view")
	var view struct{ URL string }
	ok(e.post(s, "/admin/v1/content-cases/"+caseID+"/view", map[string]string{"reason": "viewing on the restricted role"}), "case view media").data(&view)
	ok(e.get(s, view.URL), "case media")
	ok(e.post(s, "/admin/v1/content-cases/"+caseID+"/reveal", map[string]string{"reason": "reveal on the restricted role"}), "reveal")
	ok(e.post(s, "/admin/v1/content-cases/"+caseID+"/resolve", map[string]any{"action": "confirm", "reason": "confirmed on the restricted role"}), "resolve case")

	// Two-person control and the hold purge, on the restricted role: propose, approve by a second administrator,
	// release, and the purge job runs the hold functions.
	second := e.session(e.operator(RoleAdmin))
	flagged, _, _ := e.pendingQuarantine(e.member(false), "flagged", objects)
	if r, ap := e.propose(s, flagged, "clear", "clearing on the restricted role", ""); r.status != 201 {
		t.Fatalf("propose on the admin role: %d %s", r.status, r.raw)
	} else if r = e.decide(second, ap.Approval.ApprovalID, "approve", "approving on the restricted role"); r.status != 200 {
		t.Fatalf("approve on the admin role: %d %s", r.status, r.raw)
	}
	ok(e.get(s, "/admin/v1/approvals?status=approved"), "approvals list")
	if r, ap := e.propose(s, flagged, "release", "releasing on the restricted role", ""); r.status != 201 {
		t.Fatalf("propose release on the admin role: %d %s", r.status, r.raw)
	} else if r = e.decide(second, ap.Approval.ApprovalID, "approve", "approving the release on the restricted role"); r.status != 200 {
		t.Fatalf("approve release on the admin role: %d %s", r.status, r.raw)
	}
	e.svc.EvidenceDelete = objects
	if _, err := e.svc.PurgeHolds(e.ctx, 5); err != nil {
		t.Fatalf("hold purge on the admin role: %v", err)
	}

	// Operator management and the audit log.
	other := e.operator(RoleViewer)
	ok(e.get(s, "/admin/v1/operators"), "operators")
	ok(e.post(s, "/admin/v1/operators/"+other.ID+"/role", map[string]string{"role": "moderator", "reason": "promoting on the restricted role"}), "role change")
	ok(e.post(s, "/admin/v1/operators/"+other.ID+"/disable", map[string]string{"reason": "disabling on the restricted role"}), "disable")
	ok(e.post(s, "/admin/v1/operators/"+other.ID+"/enable", map[string]string{"reason": "enabling on the restricted role"}), "enable")
	ok(e.get(s, "/admin/v1/audit?limit=10"), "audit")
	ok(e.post(s, "/admin/v1/me/password", map[string]string{"current": op.password, "new": "another long password here"}), "password change")
	ok(e.post(s, "/admin/v1/logout", map[string]string{}), "logout")
}
