// Package dbtest is test support for running code under the production database roles (database/roles).
// It is imported only by _test.go files.
package dbtest

import (
	"context"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Script returns the text of database/roles/<name>.
func Script(t testing.TB, name string) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(file), "../../../../database/roles", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// ApplyRoles runs roles.sql and then grants.sql on the test database, as the test user (a superuser or a role
// that can create roles and owns the tables, as locally and in CI). The test is skipped when the user cannot
// create roles. Concurrent calls from parallel test packages are safe: roles.sql tolerates a role created a
// moment ago, and grants.sql is one transaction per database.
func ApplyRoles(t testing.TB, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	for _, name := range []string{"roles.sql", "grants.sql"} {
		// Roles are cluster wide, privileges are per database: serialise the scripts of this database only.
		if _, err = conn.Exec(ctx, `SELECT pg_advisory_lock(4917399)`); err != nil {
			t.Fatal(err)
		}
		_, err = conn.Exec(ctx, Script(t, name))
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(4917399)`)
		if err != nil {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "42501" {
				t.Skipf("the test database user cannot create roles or change grants: %v", err)
			}
			t.Fatalf("%s: %v", name, err)
		}
	}
}

// RoleDSN is dsn with every connection switching to role (SET ROLE as the first thing), so each statement runs
// with only that role's grants.
func RoleDSN(t testing.TB, dsn, role string) string {
	t.Helper()
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if u.RawQuery != "" {
		u.RawQuery += "&"
	}
	u.RawQuery += "options=-c%20role%3D" + role // %20, not +: the driver does not decode + in a URL query
	return u.String()
}

// Denials records every statement that failed with "permission denied" (SQLSTATE 42501), including those a
// handler swallowed. Attach it to a store with store.WithQueryTracer.
type Denials struct {
	mu  sync.Mutex
	got []string
}

type key struct{}

func (d *Denials) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	return context.WithValue(ctx, key{}, data.SQL)
}

func (d *Denials) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryEndData) {
	var pe *pgconn.PgError
	if errors.As(data.Err, &pe) && pe.Code == "42501" {
		sql, _ := ctx.Value(key{}).(string)
		d.mu.Lock()
		d.got = append(d.got, pe.Message+" in: "+sql)
		d.mu.Unlock()
	}
}

// Got returns the denials seen so far.
func (d *Denials) Got() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.got...)
}

// Check fails the test if any statement was denied.
func (d *Denials) Check(t testing.TB) {
	t.Helper()
	for _, g := range d.Got() {
		t.Errorf("permission denied for the restricted role: %s", g)
	}
}
