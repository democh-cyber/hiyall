package main

import (
	"context"
	"os"
	"strings"
	"testing"

	"hiyall/services/api/internal/dbtest"
	"hiyall/services/api/internal/identity"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// testStores opens the test database as its own user (a superuser or the owner) and as hiyall_api.
func testStores(t *testing.T) (owner, api *store.Store, denials *dbtest.Denials) {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	owner, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(owner.Pool.Close)
	var name string
	if err = owner.Pool.QueryRow(ctx, `SELECT current_database()`).Scan(&name); err != nil || !strings.HasPrefix(name, "hiyall_test") {
		t.Fatal("integration tests require a database named hiyall_test*")
	}
	dbtest.ApplyRoles(t, ctx, owner.Pool)
	denials = &dbtest.Denials{}
	api, err = store.New(ctx, dbtest.RoleDSN(t, dsn, "hiyall_api"), store.WithQueryTracer(denials))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(api.Pool.Close)
	return owner, api, denials
}

// Every job of the hourly maintenance loop, from the real list, runs on the production role without a
// permission error (the retention and reconcile jobs, the media and chat blob cleanups, the account purge).
func TestEveryMaintenanceJobRunsOnTheRestrictedAPIRole(t *testing.T) {
	_, api, denials := testStores(t)
	jobs := maintenanceJobs(api, media.NewMemory(), media.NewMemory(), identity.LogDeleter{})
	if len(jobs) < 20 {
		t.Fatalf("only %d maintenance jobs: the list changed shape", len(jobs))
	}
	for _, j := range jobs {
		if _, err := j.Run(context.Background()); err != nil {
			t.Errorf("job %q: %v", j.Name, err)
		}
	}
	denials.Check(t)
}

func TestProductionStartRefusesARoleThatIsTooPowerful(t *testing.T) {
	owner, api, _ := testStores(t)
	ctx := context.Background()
	t.Setenv("DB_ALLOW_OWNER_ROLE", "")
	if err := enforceDBRole(ctx, api, "production"); err != nil {
		t.Fatalf("hiyall_api was refused: %v", err)
	}
	// The test user owns the tables (and is usually a superuser): production refuses it, naming why and the override.
	err := enforceDBRole(ctx, owner, "production")
	if err == nil || !strings.Contains(err.Error(), "hiyall_api") || !strings.Contains(err.Error(), "DB_ALLOW_OWNER_ROLE") {
		t.Fatalf("the owner role must be refused in production: %v", err)
	}
	if strings.Contains(err.Error(), "postgresql://") {
		t.Fatalf("the refusal must not carry credentials: %v", err)
	}
	// Development does not check; the override accepts it (and logs loudly).
	if err := enforceDBRole(ctx, owner, "development"); err != nil {
		t.Fatalf("development: %v", err)
	}
	t.Setenv("DB_ALLOW_OWNER_ROLE", "true")
	if err := enforceDBRole(ctx, owner, "production"); err != nil {
		t.Fatalf("DB_ALLOW_OWNER_ROLE=true: %v", err)
	}
}

// RoleProblems names each way a role is too powerful, so an operator can fix the right thing.
func TestRoleProblemsAndGrantProblemsSeeWhatIsWrong(t *testing.T) {
	owner, api, _ := testStores(t)
	ctx := context.Background()
	if p, err := api.RoleProblems(ctx); err != nil || len(p) != 0 {
		t.Fatalf("hiyall_api: %v %v", p, err)
	}
	if p, err := api.GrantProblems(ctx, ""); err != nil || len(p) != 0 {
		t.Fatalf("grants of hiyall_api: %v %v", p, err)
	}
	problems, err := owner.RoleProblems(ctx)
	if err != nil || len(problems) == 0 || !strings.Contains(strings.Join(problems, "|"), "owns tables") {
		t.Fatalf("the owner role should report owning tables: %v %v", problems, err)
	}
	// A role with wrong grants is reported: no view, no column of content_cases, a readable operator table.
	probe := "hiyall_grants_probe"
	for _, q := range []string{`DROP OWNED BY ` + probe, `DROP ROLE IF EXISTS ` + probe} {
		_, _ = owner.Pool.Exec(ctx, q) // a leftover of an interrupted run
	}
	for _, q := range []string{`CREATE ROLE ` + probe + ` NOLOGIN`, `GRANT USAGE ON SCHEMA public TO ` + probe,
		`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ` + probe, `REVOKE ALL ON profile_social_counts FROM ` + probe,
		`REVOKE ALL ON content_cases FROM ` + probe, `GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ` + probe} {
		if _, err = owner.Pool.Exec(ctx, q); err != nil {
			t.Skipf("cannot create a probe role: %v", err)
		}
	}
	t.Cleanup(func() {
		_, _ = owner.Pool.Exec(context.Background(), `DROP OWNED BY `+probe)
		_, _ = owner.Pool.Exec(context.Background(), `DROP ROLE `+probe)
	})
	got, err := owner.GrantProblems(ctx, probe)
	if err != nil {
		t.Fatal(err)
	}
	all := strings.Join(got, " | ")
	for _, want := range []string{"has no SELECT on: profile_social_counts", "has access it must not have to:", "operator_audit", "content_cases.media_id", "cannot insert into content_cases"} {
		if !strings.Contains(all, want) {
			t.Errorf("GrantProblems missed %q in: %s", want, all)
		}
	}
	if got, err := owner.GrantProblems(ctx, "hiyall_no_such_role"); err != nil || len(got) != 1 || !strings.Contains(got[0], "does not exist") {
		t.Fatalf("an absent role: %v %v", got, err)
	}
}

// `api check-config -db` against a live database: clean for hiyall_api; for the owner role a development
// database only warns (production would fail), and a database that cannot be reached is a problem.
func TestCheckConfigDatabaseFlag(t *testing.T) {
	_, _, _ = testStores(t) // roles and grants applied
	dsn := os.Getenv("TEST_DATABASE_URL")
	t.Setenv("APP_ENV", "development")
	t.Setenv("FIREBASE_PROJECT_ID", "hiyall-test")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	t.Setenv("DATABASE_URL", dbtest.RoleDSN(t, dsn, "hiyall_api"))
	if problems, warnings := reviewDatabase(); len(problems) != 0 || len(warnings) != 0 {
		t.Fatalf("hiyall_api: problems %v warnings %v", problems, warnings)
	}
	if code, out := runCheck(t, "-db"); code != 0 && strings.Contains(out, "grants") {
		t.Fatalf("check-config -db found a grants problem on hiyall_api: %s", out)
	}
	t.Setenv("DATABASE_URL", dsn)
	problems, warnings := reviewDatabase()
	if len(problems) != 0 || len(warnings) == 0 {
		t.Fatalf("owner role in development: problems %v warnings %v", problems, warnings)
	}
	t.Setenv("DATABASE_URL", "postgresql://nobody@127.0.0.1:1/none?sslmode=disable&connect_timeout=2")
	if problems, _ := reviewDatabase(); len(problems) != 1 || !strings.Contains(problems[0], "cannot connect") || strings.Contains(problems[0], "nobody") {
		t.Fatalf("unreachable database: %v", problems)
	}
	if code, _ := runCheck(t, "-bogus"); code != 2 {
		t.Fatalf("usage: %d", code)
	}
}
