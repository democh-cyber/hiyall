package store

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func opsTestStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	s, err := New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Pool.Close)
	var name string
	if err = s.Pool.QueryRow(context.Background(), "SELECT current_database()").Scan(&name); err != nil || !strings.HasPrefix(name, "hiyall_test") {
		t.Fatalf("requires a disposable database named hiyall_test*, got %q", name)
	}
	return s
}

// A lock key of its own, so a running development API or another test never competes with these.
const testLeaderKey int64 = 4917399

func TestLeaderIsExclusiveAndHandsOver(t *testing.T) {
	ctx := context.Background()
	a, b := opsTestStore(t), opsTestStore(t)
	la, lb := a.NewLeader(testLeaderKey), b.NewLeader(testLeaderKey)
	defer la.Release(ctx)
	defer lb.Release(ctx)
	if ok, err := la.Acquire(ctx); err != nil || !ok {
		t.Fatalf("first instance: %v %v", ok, err)
	}
	if ok, err := lb.Acquire(ctx); err != nil || ok {
		t.Fatalf("second instance took the lock too: %v %v", ok, err)
	}
	// Asking again while holding it stays true and does not stack locks.
	if ok, _ := la.Acquire(ctx); !ok {
		t.Fatal("leader lost its own lock")
	}
	if err := la.Release(ctx); err != nil {
		t.Fatal(err)
	}
	if ok, err := lb.Acquire(ctx); err != nil || !ok {
		t.Fatalf("handover after release failed: %v %v", ok, err)
	}
	if la.IsLeader() || !lb.IsLeader() {
		t.Fatal("IsLeader disagrees with the lock")
	}
}

func TestLeaderRecoversWhenItsConnectionDies(t *testing.T) {
	ctx := context.Background()
	a, b := opsTestStore(t), opsTestStore(t)
	la, lb := a.NewLeader(testLeaderKey), b.NewLeader(testLeaderKey)
	defer la.Release(ctx)
	defer lb.Release(ctx)
	if ok, _ := la.Acquire(ctx); !ok {
		t.Fatal("no lock")
	}
	// The database kills the leader's session (failover, idle timeout, operator).
	var pid int32
	if err := la.conn.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Pool.Exec(ctx, `SELECT pg_terminate_backend($1)`, pid); err != nil {
		t.Fatal(err)
	}
	// The other instance takes over as soon as the dead session's lock is released.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if ok, _ := lb.Acquire(ctx); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no takeover after the leader's connection died")
		}
		time.Sleep(50 * time.Millisecond)
	}
	// The old leader notices on its next tick that it no longer holds the lock.
	if ok, _ := la.Acquire(ctx); ok {
		t.Fatal("two leaders at once")
	}
	if la.IsLeader() {
		t.Fatal("old leader still believes it leads")
	}
}

func TestMissingMigrations(t *testing.T) {
	s := opsTestStore(t)
	ctx := context.Background()
	var one string
	if err := s.Pool.QueryRow(ctx, `SELECT version FROM schema_migrations ORDER BY version LIMIT 1`).Scan(&one); err != nil {
		t.Fatal(err)
	}
	missing, err := s.MissingMigrations(ctx, []string{one, "9999_not_applied.sql"})
	if err != nil || len(missing) != 1 || missing[0] != "9999_not_applied.sql" {
		t.Fatalf("missing = %v, err %v", missing, err)
	}
	if missing, err = s.MissingMigrations(ctx, nil); err != nil || len(missing) != 0 {
		t.Fatalf("nothing expected, got %v %v", missing, err)
	}
}

func TestMigrationNamesAreSorted(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"0002_b.sql", "0001_a.sql", "notes.txt"} {
		if err := os.WriteFile(dir+"/"+n, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	names, err := MigrationNames(dir)
	if err != nil || len(names) != 2 || names[0] != "0001_a.sql" || names[1] != "0002_b.sql" {
		t.Fatalf("names = %v, err %v", names, err)
	}
}
