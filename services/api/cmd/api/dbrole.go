package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/store"
)

// enforceDBRole is the production start check on the database role in DATABASE_URL (database/roles/roles.sql).
// The API must not connect as a superuser, as the owner of the tables, or as any role that can read the operator
// tables or case evidence or change the audit log: a flaw in an internet facing process would otherwise reach
// staff password hashes and the audit trail. A start refuses with the reasons, unless DB_ALLOW_OWNER_ROLE=true
// (a single role deployment that has accepted the risk), which logs them loudly at every start instead.
// Development runs as whatever role it has and is not checked.
func enforceDBRole(ctx context.Context, db *store.Store, env string) error {
	if env != "production" {
		return nil
	}
	problems, err := db.RoleProblems(ctx)
	if err != nil {
		return errors.New("database role check failed; check DATABASE_URL and its role's rights")
	}
	if len(problems) == 0 {
		return nil
	}
	if strings.EqualFold(os.Getenv("DB_ALLOW_OWNER_ROLE"), "true") {
		for _, p := range problems {
			slog.Error("DB_ALLOW_OWNER_ROLE=true: the API runs with too much database authority; use the hiyall_api role (database/roles/roles.sql)", "problem", p)
		}
		return nil
	}
	return fmt.Errorf("DATABASE_URL must use the least-privilege hiyall_api role (database/roles/roles.sql): %s. Set DB_ALLOW_OWNER_ROLE=true only to accept this knowingly", strings.Join(problems, "; "))
}

// reviewDatabase is `api check-config -db`: it connects with DATABASE_URL (read only, short timeouts) and checks
// the role (RoleProblems) and the grants a release applied (GrantProblems for hiyall_api). Against production
// a problem is fatal; elsewhere the role findings are warnings, because a development database is owned by the
// developer's own role on purpose. A failure to connect is a problem in both.
func reviewDatabase() (problems, warnings []string) {
	cfg, err := config.Load()
	if err != nil {
		return nil, nil // reviewConfig already reported it
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	db, err := store.New(ctx, cfg.DatabaseURL, store.WithMaxConns(2), store.WithTimeouts(store.Timeouts{Statement: 10 * time.Second, Lock: 2 * time.Second, IdleInTransaction: 10 * time.Second}))
	if err != nil {
		return []string{"cannot connect to DATABASE_URL (check the address, credentials and sslmode)"}, nil
	}
	defer db.Pool.Close()
	add := func(list []string, lines ...string) []string { return append(list, lines...) }
	roleLines, err := db.RoleProblems(ctx)
	if err != nil {
		return []string{"the database role check failed: " + err.Error()}, nil
	}
	if cfg.Env == "production" {
		problems = add(problems, roleLines...)
	} else {
		warnings = add(warnings, roleLines...)
	}
	grantLines, err := db.GrantProblems(ctx, store.GrantsRole)
	if err != nil {
		return append(problems, "the grants check failed: "+err.Error()), warnings
	}
	if cfg.Env == "production" {
		problems = add(problems, grantLines...)
	} else {
		warnings = add(warnings, grantLines...)
	}
	return problems, warnings
}
