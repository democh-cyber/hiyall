package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/dbtest"
)

// The production release runs as hiyall_migrate: a role that is NOT a superuser, owns every table and function, and
// is the only thing the SECURITY DEFINER functions run as. Every other test runs the migrations as a superuser, which
// can do anything, so a statement in a definer function that needs more than ownership (ALTER TABLE ... DISABLE
// TRIGGER on someone else's table, a trigger writing a table nobody granted) would pass them all and fail in
// production (round-3 audit DB-NEW-2). This builds a scratch database the way the deploy guide says: roles.sql as the
// administrator, then migrations and grants.sql as hiyall_migrate, then calls each definer function as the role that
// is meant to use it.
func TestOwnerPathWithoutSuperuser(t *testing.T) {
	dsn := scratchDB(t)
	ctx := context.Background()
	super, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer super.Close(ctx)
	dbtest.ApplyRolesScript(t, ctx, super)

	owner := dbtest.RoleDSN(t, dsn, "hiyall_migrate")
	t.Setenv("DATABASE_URL", "postgresql://nobody@127.0.0.1:1/none")
	t.Setenv("MIGRATE_DATABASE_URL", owner)
	t.Setenv("MIGRATIONS_DIR", "../../../../database/migrations")
	t.Setenv("MIGRATE_RUN_GRANTS", "true")
	// Roles are cluster wide: another package's role scripts running at the same moment can win a deadlock.
	if err = dbtest.Retry(run); err != nil {
		t.Fatalf("migrate and grants as hiyall_migrate: %v", err)
	}
	asRole := func(role string) *pgx.Conn {
		t.Helper()
		c, err := pgx.Connect(ctx, dbtest.RoleDSN(t, dsn, role))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close(ctx) })
		return c
	}
	one := func(c *pgx.Conn, q string, args ...any) (n int) {
		t.Helper()
		if err := c.QueryRow(ctx, q, args...).Scan(&n); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return n
	}
	exec := func(c *pgx.Conn, q string, args ...any) {
		t.Helper()
		if _, err := c.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	// The role really is not a superuser, and owns what the migrations made (the schema's objects, the functions).
	if one(asRole("hiyall_migrate"), `SELECT count(*) FROM pg_roles WHERE rolname=current_user AND (rolsuper OR rolcreaterole OR rolbypassrls)`) != 0 {
		t.Fatal("hiyall_migrate must not be a superuser, create roles or bypass row security")
	}
	if n := one(super, `SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S') AND pg_get_userbyid(c.relowner)<>'hiyall_migrate'`); n != 0 {
		t.Fatalf("%d relations are not owned by hiyall_migrate", n)
	}
	if n := one(super, `SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND pg_get_userbyid(p.proowner)<>'hiyall_migrate'`); n != 0 {
		t.Fatalf("%d functions are not owned by hiyall_migrate", n)
	}
	for _, f := range []string{"prune_operator_audit", "users_status_counters", "revoke_session_devices", "held_objects_due", "mark_hold_purged"} {
		if one(super, `SELECT count(*) FROM pg_proc WHERE proname=$1 AND (prosecdef = false)`, f) != 0 {
			t.Errorf("%s is not SECURITY DEFINER", f)
		}
	}

	// Data, as the administrator of the database (the triggers it fires run as the owner).
	exec(super, `INSERT INTO users(user_id) SELECT gen_random_uuid() FROM generate_series(1,5)`)
	exec(super, `CREATE TABLE people AS SELECT user_id, row_number() OVER (ORDER BY user_id) n FROM users`)
	exec(super, `INSERT INTO follows(follower_id,followee_id,state) SELECT b.user_id,a.user_id,'active' FROM people a, people b WHERE a.n=1 AND b.n IN (2,3,4)`)
	exec(super, `INSERT INTO social_counters(user_id,followers) SELECT user_id,3 FROM people WHERE n=1 ON CONFLICT (user_id) DO UPDATE SET followers=3`)
	exec(super, `INSERT INTO sessions(session_id,user_id,expires_at) SELECT gen_random_uuid(),user_id,now()+interval '1 day' FROM people WHERE n=5`)
	exec(super, `INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform,session_id) SELECT gen_random_uuid(),p.user_id,'ik','sk','sig','android',s.session_id FROM people p JOIN sessions s USING(user_id) WHERE p.n=5`)

	admin, api := asRole("hiyall_admin"), asRole("hiyall_api")
	id := func(n int) string {
		var s string
		if err := super.QueryRow(ctx, `SELECT user_id::text FROM people WHERE n=$1`, n).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}

	// users_status_counters: the console suspends a member; the neighbours' counters change although the console
	// has no grant on follows or social_counters.
	exec(admin, `UPDATE users SET status='suspended' WHERE user_id=$1`, id(1))
	exec(admin, `UPDATE users SET status='active' WHERE user_id=$1`, id(1))
	exec(admin, `UPDATE users SET status='suspended' WHERE user_id=$1`, id(2)) // member 2 follows member 1: its followers drop
	if n := one(super, `SELECT followers FROM social_counters WHERE user_id=(SELECT user_id FROM people WHERE n=1)`); n != 2 {
		t.Errorf("followers of the member after one follower was suspended: %d, want 2", n)
	}
	// revoke_session_devices: revoking a session revokes its chat devices.
	exec(admin, `UPDATE sessions SET revoked_at=now() WHERE user_id=$1`, id(5))
	if n := one(super, `SELECT count(*) FROM devices WHERE user_id=(SELECT user_id FROM people WHERE n=5) AND revoked_at IS NOT NULL`); n != 1 {
		t.Errorf("devices revoked with their session: %d, want 1", n)
	}
	// The queue for a very large account is written by the same trigger and read by the API role.
	if n := one(api, `SELECT count(*) FROM counter_fixups`); n != 0 {
		t.Errorf("counter_fixups: %d", n)
	}

	// prune_operator_audit: ALTER TABLE ... DISABLE TRIGGER needs the table's owner; the console is not. Old entries
	// go, in batches; a call with nothing old takes no table lock at all.
	exec(super, `INSERT INTO operator_audit(at,actor,action) SELECT now()-interval '400 days'-g*interval '1 minute','seed','seed' FROM generate_series(1,50) g`)
	exec(super, `INSERT INTO operator_audit(at,actor,action) VALUES(now(),'seed','recent')`)
	if n := one(admin, `SELECT prune_operator_audit(NULL,'owner-path test','proving the definer path',365)::int`); n != 50 {
		t.Fatalf("pruned %d, want 50", n)
	}
	if n := one(super, `SELECT count(*) FROM operator_audit WHERE action='seed'`); n != 0 {
		t.Errorf("%d old entries survived", n)
	}
	if n := one(super, `SELECT count(*) FROM operator_audit WHERE action IN ('recent','audit_prune')`); n != 2 {
		t.Errorf("the recent entry and the prune record must stay: %d", n)
	}
	// A reader that holds the table open does not block a prune that has nothing to do (no ALTER TABLE).
	blocker, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close(ctx)
	tx, err := blocker.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `LOCK TABLE operator_audit IN SHARE ROW EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if n := one(admin, `SELECT prune_operator_audit(NULL,'owner-path test','nothing to prune',365)::int`); n != 0 {
		t.Errorf("nothing was old, pruned %d", n)
	}
	if time.Since(start) > time.Second {
		t.Errorf("an empty prune waited %v for a table lock", time.Since(start))
	}
	tx.Rollback(ctx)
	// The API role has no business with it.
	if _, err = api.Exec(ctx, `SELECT prune_operator_audit(NULL,'x','a reason here',365)`); err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("hiyall_api must not run prune_operator_audit: %v", err)
	}

	// The hold functions: a released case whose retention window is over is listed and recorded as purged by the API role.
	exec(super, `INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,attached,expires_at,declared_bytes)
 SELECT '00000000-0000-0000-0000-0000000000f1',user_id,'post','quarantined','image/jpeg',10,'hold/1',false,now(),10 FROM people WHERE n=3`)
	exec(super, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,original_sha256,original_bytes,content_type,original_key,status,hold_until,released_at,released_by,release_reason)
 SELECT '00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000f1',user_id,'post','flagged','test','x',10,'image/jpeg','hold/1','cleared',now()-interval '1 day',now()-interval '2 days','a','b' FROM people WHERE n=3`)
	if n := one(api, `SELECT count(*) FROM held_objects_due(10)`); n != 1 {
		t.Fatalf("held_objects_due as hiyall_api: %d, want 1", n)
	}
	var done bool
	if err = api.QueryRow(ctx, `SELECT mark_hold_purged('00000000-0000-0000-0000-0000000000f2')`).Scan(&done); err != nil || !done {
		t.Fatalf("mark_hold_purged as hiyall_api: %v %v", done, err)
	}
	if n := one(api, `SELECT count(*) FROM held_objects_due(10)`); n != 0 {
		t.Errorf("a purged hold is still listed: %d", n)
	}
	if n := one(super, `SELECT count(*) FROM operator_audit WHERE action='hold_objects_purged'`); n != 1 {
		t.Errorf("the purge was not audited: %d", n)
	}
	// And the API role still cannot read what it must not.
	if _, err = api.Exec(ctx, `SELECT 1 FROM operator_audit`); err == nil {
		t.Error("hiyall_api can read operator_audit")
	}
}
