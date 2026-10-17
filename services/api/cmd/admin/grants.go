package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/store"
)

// checkAdminGrants is the console's start check on the grants of the role it runs as (round-4 audit N1). When
// that role is hiyall_admin it must hold every grant database/roles/grants.sql gives it (store.GrantProblems): a
// table it reads, a column it updates and each EXECUTE on a two-person function. Without them the console starts,
// answers its login page and fails the first time an operator proposes, decides or schedules something. In
// production a gap refuses the start and names what is missing and the fix; elsewhere it is a warning. Any other
// role (the shared DATABASE_URL role, a developer's own role, an owner) is not judged here: the console already says
// when it shares the API's role, and the owner has every privilege.
func checkAdminGrants(ctx context.Context, db *store.Store, env string) error {
	role, err := db.CurrentRole(ctx)
	if err == nil && role != store.AdminRole {
		return nil
	}
	var problems []string
	if err == nil {
		problems, err = db.GrantProblems(ctx, role)
	}
	if err != nil {
		if env == "production" {
			return errors.New("database grants check failed; check the console's database role")
		}
		slog.Warn("console database grants not checked", "reason", logscrub.Err(err))
		return nil
	}
	if len(problems) == 0 {
		return nil
	}
	if env != "production" {
		slog.Warn("the console's database role is missing grants this release needs (production refuses to start): run database/roles/grants.sql as the table owner", "problems", problems)
		return nil
	}
	return fmt.Errorf("the database role %s is missing grants this release needs: %s. Run database/roles/grants.sql as the table owner (hiyall_migrate), or set MIGRATE_RUN_GRANTS=true on the release's migrate step, then start again", role, strings.Join(problems, "; "))
}
