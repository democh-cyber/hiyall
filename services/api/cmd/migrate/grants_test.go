package main

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/dbtest"
)

func hasPrivilege(t *testing.T, conn *pgx.Conn, query string) bool {
	t.Helper()
	var ok bool
	if err := conn.QueryRow(context.Background(), query).Scan(&ok); err != nil {
		t.Fatal(err)
	}
	return ok
}

// One release step: MIGRATE_DATABASE_URL (the owner) is used instead of DATABASE_URL, the migrations run, and with
// MIGRATE_RUN_GRANTS=true database/roles/grants.sql follows as one transaction.
func TestMigrateRunsGrantsAfterTheMigrations(t *testing.T) {
	dsn := scratchDB(t)
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	// The roles exist already (the one-time step). A user that cannot create roles skips.
	if _, err = conn.Exec(ctx, dbtest.Script(t, "roles.sql")); err != nil {
		t.Skipf("cannot run roles.sql here: %v", err)
	}
	t.Setenv("DATABASE_URL", "postgresql://nobody@127.0.0.1:1/none")
	t.Setenv("MIGRATE_DATABASE_URL", dsn)
	t.Setenv("MIGRATIONS_DIR", "../../../../database/migrations")
	t.Setenv("MIGRATE_RUN_GRANTS", "")
	if err = run(); err != nil {
		t.Fatalf("migrate without grants: %v", err)
	}
	if hasPrivilege(t, conn, `SELECT has_table_privilege('hiyall_api','users','SELECT')`) {
		t.Fatal("grants applied although MIGRATE_RUN_GRANTS is not set")
	}
	t.Setenv("MIGRATE_RUN_GRANTS", "true")
	if err = run(); err != nil {
		t.Fatalf("migrate with grants: %v", err)
	}
	for _, q := range []string{
		`SELECT has_table_privilege('hiyall_api','users','INSERT')`,
		`SELECT has_table_privilege('hiyall_api','profile_social_counts','SELECT')`,
		`SELECT has_column_privilege('hiyall_api','content_cases','media_id','SELECT')`,
		`SELECT has_column_privilege('hiyall_api','content_cases','media_id','INSERT')`,
		`SELECT has_function_privilege('hiyall_api','held_objects_due(integer)','EXECUTE')`,
		`SELECT has_table_privilege('hiyall_admin','operator_audit','INSERT')`,
	} {
		if !hasPrivilege(t, conn, q) {
			t.Errorf("missing: %s", q)
		}
	}
	for _, q := range []string{
		`SELECT has_table_privilege('hiyall_api','content_cases','SELECT')`,
		`SELECT has_table_privilege('hiyall_api','content_cases','INSERT')`, // only the scanner's columns (round-4 N-1)
		`SELECT has_column_privilege('hiyall_api','content_cases','released_at','INSERT')`,
		`SELECT has_column_privilege('hiyall_api','content_cases','status','INSERT')`,
		`SELECT has_table_privilege('hiyall_admin','operators','INSERT')`,
		`SELECT has_column_privilege('hiyall_admin','operators','disabled_at','UPDATE')`,
		`SELECT has_table_privilege('hiyall_admin','apple_revocations','DELETE')`,
		`SELECT has_table_privilege('hiyall_api','operators','SELECT')`,
		`SELECT has_table_privilege('hiyall_api','operator_audit','INSERT')`,
		`SELECT has_table_privilege('hiyall_admin','operator_audit','UPDATE')`,
		`SELECT has_function_privilege('hiyall_api','prune_operator_audit(uuid,text,text,integer)','EXECUTE')`,
	} {
		if hasPrivilege(t, conn, q) {
			t.Errorf("must not be allowed: %s", q)
		}
	}
	// Running it again is a no-op (idempotent).
	if err = run(); err != nil {
		t.Fatalf("second run: %v", err)
	}

	// The script is atomic: a failure part way (here a division by zero after a REVOKE) leaves every earlier
	// grant as it was; there is no window in which hiyall_api has lost its rights.
	broken := writeFiles(t, map[string]string{"grants.sql": "BEGIN;\nREVOKE ALL ON ALL TABLES IN SCHEMA public FROM hiyall_api;\nSELECT 1/0;\nCOMMIT;\n"})
	err = ApplyGrants(ctx, dsn, broken+"/grants.sql", Options{})
	if err == nil || !strings.Contains(err.Error(), "division by zero") {
		t.Fatalf("broken script: %v", err)
	}
	if !hasPrivilege(t, conn, `SELECT has_table_privilege('hiyall_api','users','INSERT')`) {
		t.Fatal("a failed grants run took the API's rights away")
	}
	if err = ApplyGrants(ctx, dsn, broken+"/missing.sql", Options{}); err == nil {
		t.Fatal("a missing script must fail the release step")
	}
	// The script asserts its own outcome (a run by a role that does not own the tables only gets warnings from GRANT).
	if !strings.Contains(dbtest.Script(t, "grants.sql"), "RAISE EXCEPTION 'grants.sql: hiyall_api has no SELECT on") {
		t.Fatal("grants.sql lost its own assertion")
	}
}
