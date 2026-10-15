package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
)

// ApplyGrants runs the privilege refresh script (database/roles/grants.sql) on its own connection, as the role
// in dsn (hiyall_migrate, the table owner). The script is one transaction (BEGIN ... COMMIT) and asserts its
// own result, so an error here leaves the previous grants in force and the release step fails visibly. It is
// sent with the simple query protocol, which takes a script of several statements.
func ApplyGrants(ctx context.Context, dsn, path string, opts Options) error {
	script, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("grants script: %w", err)
	}
	if len(script) == 0 {
		return errors.New("grants script is empty: " + path)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return err
	}
	defer conn.Close(context.WithoutCancel(ctx))
	if _, err = conn.Exec(ctx, string(script), pgx.QueryExecModeSimpleProtocol); err != nil {
		// A failed script leaves the session inside the aborted transaction; closing the connection ends it.
		return fmt.Errorf("grants script %s: %w", path, err)
	}
	opts.logf("Applied grants from %s", path)
	return nil
}
