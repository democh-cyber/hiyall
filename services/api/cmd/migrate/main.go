// Command migrate applies the SQL files in database/migrations, in name order, each in its own
// transaction (see migrate.go for the rules). Run it as a release step before the new API starts.
//
// Environment: DATABASE_URL (required), MIGRATIONS_DIR (default ../../database/migrations),
// MIGRATE_DEADLINE (overall, default 10m), MIGRATE_LOCK_TIMEOUT (per lock wait, default 5s),
// MIGRATE_STATEMENT_TIMEOUT (per statement, default 5m; "0" turns it off).
package main

import (
	"context"
	"fmt"
	"log"
	"os"
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
	_, err := Migrate(ctx, os.Getenv("DATABASE_URL"), opts)
	return err
}
