// Package dbtest is test support for running code under the production database roles (database/roles).
// It is imported only by _test.go files.
package dbtest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

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
		// The scripts are one explicit transaction: a failure in the middle (a deadlock with a script of another
		// package) leaves the connection in an aborted transaction, which would fail the retry and every later user
		// of the pooled connection with "current transaction is aborted", hiding the real error.
		err = Retry(func() error {
			_, _ = conn.Exec(context.WithoutCancel(ctx), `ROLLBACK`)
			_, err := conn.Exec(ctx, Script(t, name))
			return err
		})
		_, _ = conn.Exec(context.WithoutCancel(ctx), `ROLLBACK`)
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

// Scratch creates a database of its own next to the test database (TEST_DATABASE_URL), applies every migration to
// it in file order and returns its connection string; the database is dropped when the test ends. Tests that commit
// bulk data (and must not meet the truncates of the shared hiyall_test) use it. Skipped when TEST_DATABASE_URL is
// unset or its user cannot create databases.
func Scratch(t testing.TB) string {
	t.Helper()
	return scratch(t, "")
}

// ScratchICU is Scratch on a database whose text collation is not C: UTF8 with the ICU provider and the en-US
// locale, which orders punctuation, digits and letters the way a production database created with a language
// locale does (a "." sorts before a "+", a hyphen before a digit). Code that sorts the text of a timestamp or a
// uuid instead of the typed column is only wrong under such a collation. Skipped when the server has no ICU.
func ScratchICU(t testing.TB) string {
	t.Helper()
	return scratch(t, ` ENCODING 'UTF8' LOCALE_PROVIDER icu ICU_LOCALE 'en-US' LOCALE 'C' TEMPLATE template0`)
}

func scratch(t testing.TB, createOptions string) string {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	suffix := make([]byte, 4)
	_, _ = rand.Read(suffix)
	name := "hiyall_scratch_" + hex.EncodeToString(suffix)
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = admin.Exec(ctx, `CREATE DATABASE `+name+createOptions); err != nil {
		admin.Close(ctx)
		t.Skipf("cannot create a scratch database: %v", err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), `DROP DATABASE `+name+` WITH (FORCE)`)
		admin.Close(context.Background())
	})
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	dsn := u.String()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	_, file, _, _ := runtime.Caller(0)
	dir := filepath.Join(filepath.Dir(file), "../../../../database/migrations")
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no migrations in %s: %v", dir, err)
	}
	sort.Strings(files)
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = conn.Exec(ctx, string(raw), pgx.QueryExecModeSimpleProtocol); err != nil {
			t.Fatalf("%s: %v", filepath.Base(f), err)
		}
	}
	return dsn
}

// ApplyRolesScript runs roles.sql alone on conn (the one-time step that creates the three roles and the schema
// rights), serialised against the other test packages that create the same cluster-wide roles. The test is skipped
// when the connection's user cannot create roles.
func ApplyRolesScript(t testing.TB, ctx context.Context, conn *pgx.Conn) {
	t.Helper()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(4917399)`); err != nil {
		t.Fatal(err)
	}
	err := Retry(func() error {
		_, _ = conn.Exec(context.WithoutCancel(ctx), `ROLLBACK`)
		_, err := conn.Exec(ctx, Script(t, "roles.sql"))
		return err
	})
	_, _ = conn.Exec(context.WithoutCancel(ctx), `ROLLBACK`)
	_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(4917399)`)
	if err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "42501" {
			t.Skipf("the test database user cannot create roles: %v", err)
		}
		t.Fatalf("roles.sql: %v", err)
	}
}

// Retry runs fn again (up to six times) when PostgreSQL broke a deadlock (40P01) in it or two role changes met ("tuple concurrently updated"). The role scripts change
// cluster-wide roles, and tests that run them in different databases at the same time (advisory locks are per
// database, so they cannot wait for each other) can be picked as the victim of a deadlock on the shared catalogs;
// the scripts are idempotent and atomic, so running one again is safe.
func Retry(fn func() error) error {
	var err error
	for attempt := 0; attempt < 6; attempt++ {
		if err = fn(); err == nil {
			return nil
		}
		var pe *pgconn.PgError
		transient := errors.As(err, &pe) && (pe.Code == "40P01" || strings.Contains(pe.Message, "tuple concurrently updated"))
		if !transient && !strings.Contains(err.Error(), "40P01") && !strings.Contains(err.Error(), "tuple concurrently updated") {
			return err
		}
		time.Sleep(time.Duration(50*(attempt+1)) * time.Millisecond)
	}
	return err
}
