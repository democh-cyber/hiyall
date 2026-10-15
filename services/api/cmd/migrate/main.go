// Command migrate applies the SQL files in database/migrations, in name order, each in its own
// transaction (see migrate.go for the rules). Run it as a release step before the new API starts.
//
// Environment: DATABASE_URL (required), MIGRATIONS_DIR (default ../../database/migrations),
// MIGRATE_DEADLINE (overall, default 10m), MIGRATE_LOCK_TIMEOUT (per lock wait, default 5s),
// MIGRATE_STATEMENT_TIMEOUT (per statement, default 5m; "0" turns it off).
//
// MIGRATE_DATABASE_URL, when set, is used instead of DATABASE_URL: the release step runs as hiyall_migrate (the
// table owner) while DATABASE_URL, shared with the API, names hiyall_api. MIGRATE_RUN_GRANTS=true applies
// database/roles/grants.sql after the migrations (one transaction, as the same role), so migrate and grants are
// one release step; MIGRATE_GRANTS_FILE overrides its path (default <MIGRATIONS_DIR>/../roles/grants.sql, which is
// /roles/grants.sql in the image).
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	opts := Options{Dir: os.Getenv("MIGRATIONS_DIR"), Deadline: 10 * time.Minute, LockTimeout: 5 * time.Second, StatementTimeout: 5 * time.Minute}
	if opts.Dir == "" {
		opts.Dir = "../../database/migrations"
	}
	for name, target := range map[string]*time.Duration{"MIGRATE_DEADLINE": &opts.Deadline, "MIGRATE_LOCK_TIMEOUT": &opts.LockTimeout, "MIGRATE_STATEMENT_TIMEOUT": &opts.StatementTimeout} {
		if v := os.Getenv(name); v != "" {
			d, err := time.ParseDuration(v)
			if err != nil || d < 0 {
				return fmt.Errorf("%s must be a duration such as 30s", name)
			}
			*target = d
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), opts.Deadline)
	defer cancel()
	opts.Log = func(format string, args ...any) { fmt.Printf(format+"\n", args...) }
	dsn := os.Getenv("MIGRATE_DATABASE_URL")
	if dsn == "" {
		dsn = os.Getenv("DATABASE_URL")
	}
	if _, err := Migrate(ctx, dsn, opts); err != nil {
		return err
	}
	if strings.EqualFold(os.Getenv("MIGRATE_RUN_GRANTS"), "true") {
		path := os.Getenv("MIGRATE_GRANTS_FILE")
		if path == "" {
			path = filepath.Join(opts.Dir, "..", "roles", "grants.sql")
		}
		return ApplyGrants(ctx, dsn, path, opts)
	}
	return nil
}
