package main

import (
	"context"
	"strings"
	"testing"

	"hiyall/services/api/internal/dbtest"
	"hiyall/services/api/internal/store"
)

// The console refuses to start in production on a hiyall_admin role that lacks a grant (round-4 audit N1), names
// what is missing and the fix, warns in development, and does not judge a role that is not hiyall_admin.
func TestAdminStartChecksItsGrants(t *testing.T) {
	dsn := dbtest.Scratch(t)
	ctx := context.Background()
	owner, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(owner.Pool.Close)
	dbtest.ApplyRoles(t, ctx, owner.Pool)
	admin, err := store.New(ctx, dbtest.RoleDSN(t, dsn, "hiyall_admin"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Pool.Close)
	if err := checkAdminGrants(ctx, admin, "production"); err != nil {
		t.Fatalf("a complete hiyall_admin: %v", err)
	}
	if _, err = owner.Pool.Exec(ctx, `REVOKE EXECUTE ON FUNCTION evidence_decide(uuid, uuid, text, text) FROM hiyall_admin`); err != nil {
		t.Fatal(err)
	}
	err = checkAdminGrants(ctx, admin, "production")
	if err == nil || !strings.Contains(err.Error(), "evidence_decide(uuid, uuid, text, text)") || !strings.Contains(err.Error(), "grants.sql") || strings.Contains(err.Error(), "postgresql://") {
		t.Fatalf("production must refuse and name the missing function and the fix: %v", err)
	}
	if err = checkAdminGrants(ctx, admin, "development"); err != nil {
		t.Fatalf("development only warns: %v", err)
	}
	// The owner (a developer's own role) is not judged.
	if err = checkAdminGrants(ctx, owner, "production"); err != nil {
		t.Fatalf("a role that is not hiyall_admin is not checked here: %v", err)
	}
}
