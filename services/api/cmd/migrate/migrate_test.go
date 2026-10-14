package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// scratchDB creates an empty database next to TEST_DATABASE_URL and returns its URL; it is dropped when the
// test ends. The shared hiyall_test database is never touched.
func scratchDB(t *testing.T) string {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	suffix := make([]byte, 4)
	_, _ = rand.Read(suffix)
	name := "hiyall_migrate_" + hex.EncodeToString(suffix)
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = admin.Exec(ctx, `CREATE DATABASE `+name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(ctx, `DROP DATABASE `+name+` WITH (FORCE)`)
		admin.Close(ctx)
	})
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	return u.String()
}

func writeFiles(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func quick(dir string) Options {
	return Options{Dir: dir, Deadline: time.Minute, LockTimeout: 300 * time.Millisecond, StatementTimeout: 10 * time.Second,
		Sleep: func(ctx context.Context, d time.Duration) { time.Sleep(50 * time.Millisecond) }}
}

func count(t *testing.T, dsn, query string) int {
	t.Helper()
	conn, err := pgx.Connect(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	var n int
	if err = conn.QueryRow(context.Background(), query).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestSplitStatements(t *testing.T) {
	got := SplitStatements(`-- hiyall:no-transaction
-- a comment; with a semicolon
CREATE INDEX CONCURRENTLY IF NOT EXISTS a ON t(x); /* block; comment */
CREATE INDEX b ON t(y) WHERE z = 'a;b' AND "we;ird" > 1;
DO $body$ BEGIN PERFORM 1; PERFORM 2; END $body$;
;
SELECT 'it''s; fine'`)
	want := []string{
		"CREATE INDEX CONCURRENTLY IF NOT EXISTS a ON t(x)",
		`CREATE INDEX b ON t(y) WHERE z = 'a;b' AND "we;ird" > 1`,
		"DO $body$ BEGIN PERFORM 1; PERFORM 2; END $body$",
		"SELECT 'it''s; fine'",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q", got)
	}
}

// Each file is its own transaction: a failing file rolls back alone and earlier files stay applied.
func TestEachFileIsItsOwnTransaction(t *testing.T) {
	dsn := scratchDB(t)
	dir := writeFiles(t, map[string]string{
		"001_a.sql": "CREATE TABLE a(id int);",
		"002_b.sql": "CREATE TABLE b(id int); INSERT INTO nope VALUES (1);",
		"003_c.sql": "CREATE TABLE c(id int);",
	})
	applied, err := Migrate(context.Background(), dsn, quick(dir))
	if err == nil || !strings.Contains(err.Error(), "002_b.sql") {
		t.Fatalf("want failure naming 002_b.sql, got %v", err)
	}
	if !reflect.DeepEqual(applied, []string{"001_a.sql"}) {
		t.Fatalf("applied %v", applied)
	}
	if count(t, dsn, `SELECT count(*) FROM schema_migrations`) != 1 || count(t, dsn, `SELECT count(*) FROM pg_tables WHERE tablename='a'`) != 1 ||
		count(t, dsn, `SELECT count(*) FROM pg_tables WHERE tablename IN ('b','c')`) != 0 {
		t.Fatal("a failed file left something behind, or an earlier file was rolled back")
	}
	// Fixing the file and running again applies the rest only.
	if err = os.WriteFile(filepath.Join(dir, "002_b.sql"), []byte("CREATE TABLE b(id int);"), 0o600); err != nil {
		t.Fatal(err)
	}
	applied, err = Migrate(context.Background(), dsn, quick(dir))
	if err != nil || !reflect.DeepEqual(applied, []string{"002_b.sql", "003_c.sql"}) {
		t.Fatalf("second run: %v %v", applied, err)
	}
	// Nothing left to do, and a changed applied file is refused.
	if applied, err = Migrate(context.Background(), dsn, quick(dir)); err != nil || len(applied) != 0 {
		t.Fatalf("third run: %v %v", applied, err)
	}
	if err = os.WriteFile(filepath.Join(dir, "001_a.sql"), []byte("CREATE TABLE a(id int, x int);"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err = Migrate(context.Background(), dsn, quick(dir)); err == nil || !strings.Contains(err.Error(), "applied migration changed") {
		t.Fatalf("changed file: %v", err)
	}
}

func TestNoTransactionMarkerRunsConcurrentlyIndexes(t *testing.T) {
	dsn := scratchDB(t)
	dir := writeFiles(t, map[string]string{
		"001_t.sql":   "CREATE TABLE t(id int, x int);",
		"002_idx.sql": "-- hiyall:no-transaction\n-- builds without blocking writes\nCREATE INDEX CONCURRENTLY IF NOT EXISTS t_x ON t(x);\nCREATE INDEX CONCURRENTLY IF NOT EXISTS t_id ON t(id);\n",
	})
	if applied, err := Migrate(context.Background(), dsn, quick(dir)); err != nil || len(applied) != 2 {
		t.Fatalf("%v %v", applied, err)
	}
	if count(t, dsn, `SELECT count(*) FROM pg_indexes WHERE tablename='t' AND indexname IN ('t_x','t_id')`) != 2 {
		t.Fatal("concurrent indexes missing")
	}
	// The same statement without the marker cannot run in a transaction.
	dir = writeFiles(t, map[string]string{"001_t.sql": "CREATE TABLE t(id int, x int);", "002_idx.sql": "CREATE INDEX CONCURRENTLY t_x ON t(x);"})
	if _, err := Migrate(context.Background(), scratchDB(t), quick(dir)); err == nil {
		t.Fatal("CREATE INDEX CONCURRENTLY inside a transaction succeeded")
	}
}

// A lock held by someone else makes the file wait lock_timeout, roll back and retry; once the lock is
// released the retry succeeds, without the whole release failing.
func TestLockTimeoutIsRetried(t *testing.T) {
	dsn := scratchDB(t)
	ctx := context.Background()
	holder, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close(ctx)
	if _, err = holder.Exec(ctx, `CREATE TABLE busy(id int)`); err != nil {
		t.Fatal(err)
	}
	tx, err := holder.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `LOCK TABLE busy IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	dir := writeFiles(t, map[string]string{"001_alter.sql": "ALTER TABLE busy ADD COLUMN x int;"})
	retries := 0
	opts := quick(dir)
	opts.Log = func(format string, args ...any) {
		if strings.HasPrefix(format, "Lock wait timed out") {
			retries++
			if retries == 2 {
				_ = tx.Rollback(ctx) // the other session lets go
			}
		}
	}
	applied, err := Migrate(ctx, dsn, opts)
	if err != nil || len(applied) != 1 || retries < 2 {
		t.Fatalf("applied %v after %d retries: %v", applied, retries, err)
	}
	if count(t, dsn, `SELECT count(*) FROM information_schema.columns WHERE table_name='busy' AND column_name='x'`) != 1 {
		t.Fatal("column missing")
	}
}

func TestLockTimeoutGivesUpAfterTheRetries(t *testing.T) {
	dsn := scratchDB(t)
	ctx := context.Background()
	holder, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close(ctx)
	if _, err = holder.Exec(ctx, `CREATE TABLE busy(id int)`); err != nil {
		t.Fatal(err)
	}
	tx, _ := holder.Begin(ctx)
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `LOCK TABLE busy IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	dir := writeFiles(t, map[string]string{"001_alter.sql": "ALTER TABLE busy ADD COLUMN x int;"})
	opts := quick(dir)
	opts.LockTimeout = 100 * time.Millisecond
	_, err = Migrate(ctx, dsn, opts)
	if err == nil || !strings.Contains(err.Error(), "001_alter.sql") || !strings.Contains(err.Error(), "lock") {
		t.Fatalf("want a lock failure naming the file, got %v", err)
	}
}

func TestOverallDeadline(t *testing.T) {
	dsn := scratchDB(t)
	dir := writeFiles(t, map[string]string{"001_slow.sql": "SELECT pg_sleep(30);"})
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	opts := quick(dir)
	opts.Deadline = 500 * time.Millisecond
	opts.StatementTimeout = 0
	start := time.Now()
	_, err := Migrate(ctx, dsn, opts)
	if err == nil || !strings.Contains(err.Error(), "deadline") || time.Since(start) > 10*time.Second {
		t.Fatalf("deadline not enforced (%v): %v", time.Since(start), err)
	}
}

// Two runners never interleave: the second waits for the first's session lock.
func TestRunnersAreSerialised(t *testing.T) {
	dsn := scratchDB(t)
	ctx := context.Background()
	other, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(ctx)
	if _, err = other.Exec(ctx, `SELECT pg_advisory_lock($1)`, lockKey); err != nil {
		t.Fatal(err)
	}
	dir := writeFiles(t, map[string]string{"001_a.sql": "CREATE TABLE a(id int);"})
	waiting, cancel := context.WithTimeout(ctx, 400*time.Millisecond)
	defer cancel()
	if _, err = Migrate(waiting, dsn, quick(dir)); err == nil {
		t.Fatal("ran while another runner held the lock")
	}
	_, _ = other.Exec(ctx, `SELECT pg_advisory_unlock($1)`, lockKey)
	if applied, err := Migrate(ctx, dsn, quick(dir)); err != nil || len(applied) != 1 {
		t.Fatalf("%v %v", applied, err)
	}
}

// The repository's own migrations apply cleanly, one transaction per file, to an empty database.
func TestRepositoryMigrationsApply(t *testing.T) {
	dsn := scratchDB(t)
	dir := filepath.Join("..", "..", "..", "..", "database", "migrations")
	if _, err := os.Stat(dir); err != nil {
		t.Skip("migrations directory not found")
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.sql"))
	opts := quick(dir)
	opts.LockTimeout = 5 * time.Second
	applied, err := Migrate(context.Background(), dsn, opts)
	if err != nil || len(applied) != len(files) {
		t.Fatalf("applied %d of %d: %v", len(applied), len(files), err)
	}
}
