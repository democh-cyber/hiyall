package ratelimit

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/time/rate"
)

// testPool connects to the disposable test database, or skips. The rate_limits table must exist
// (go run ./cmd/migrate against the same database).
func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for the PostgreSQL limiter")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = 20
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	var name string
	if err = pool.QueryRow(context.Background(), "SELECT current_database()").Scan(&name); err != nil || !strings.HasPrefix(name, "hiyall_test") {
		t.Fatalf("rate limit tests need a disposable database named hiyall_test*, got %q", name)
	}
	if _, err = pool.Exec(context.Background(), "SELECT 1 FROM rate_limits LIMIT 0"); err != nil {
		t.Fatalf("rate_limits missing; run go run ./cmd/migrate: %v", err)
	}
	return pool
}

func uniqueName() string { return "t" + strings.ReplaceAll(uuid.NewString(), "-", "")[:12] }

type factory struct {
	name string
	make func(t *testing.T, limit rate.Limit, burst int) Limiter
}

func factories() []factory {
	return []factory{
		{"memory", func(t *testing.T, limit rate.Limit, burst int) Limiter { return NewMemory(limit, burst, 1000) }},
		{"postgres", func(t *testing.T, limit rate.Limit, burst int) Limiter {
			pool := testPool(t)
			name := uniqueName()
			t.Cleanup(func() {
				_, _ = pool.Exec(context.Background(), `DELETE FROM rate_limits WHERE bucket LIKE $1`, name+"%")
			})
			return NewPostgres(pool, name, limit, burst)
		}},
	}
}

func take(t *testing.T, l Limiter, key string) Decision {
	t.Helper()
	d, err := l.Allow(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// Every implementation must pass the same table: burst, per-key isolation, refill, Retry-After, reset.
func TestLimiterSemantics(t *testing.T) {
	for _, f := range factories() {
		t.Run(f.name, func(t *testing.T) {
			t.Run("burst then refuse, a refusal takes nothing", func(t *testing.T) {
				l := f.make(t, rate.Every(time.Hour), 3)
				for i := 0; i < 3; i++ {
					if d := take(t, l, "a"); !d.Allowed || d.RetryAfter != 0 {
						t.Fatalf("request %d: %+v", i, d)
					}
				}
				for i := 0; i < 5; i++ {
					d := take(t, l, "a")
					if d.Allowed {
						t.Fatalf("refusal %d was allowed", i)
					}
					// About an hour until the next token; refusals must not push it further out.
					if d.RetryAfter < 59*time.Minute || d.RetryAfter > time.Hour+time.Second {
						t.Fatalf("refusal %d: Retry-After %v, want about an hour", i, d.RetryAfter)
					}
				}
			})
			t.Run("keys are isolated", func(t *testing.T) {
				l := f.make(t, rate.Every(time.Hour), 1)
				if !take(t, l, "a").Allowed || take(t, l, "a").Allowed {
					t.Fatal("burst of one not enforced")
				}
				if !take(t, l, "b").Allowed {
					t.Fatal("one key used another key's budget")
				}
			})
			t.Run("refills at the configured rate and caps at burst", func(t *testing.T) {
				l := f.make(t, 10, 2) // one token per 100 ms
				take(t, l, "k")
				take(t, l, "k")
				d := take(t, l, "k")
				if d.Allowed || d.RetryAfter <= 0 || d.RetryAfter > 110*time.Millisecond {
					t.Fatalf("third request: %+v, want refused with at most ~100ms", d)
				}
				time.Sleep(450 * time.Millisecond) // more than two tokens' worth, the most the bucket holds
				if !take(t, l, "k").Allowed || !take(t, l, "k").Allowed {
					t.Fatal("bucket did not refill to burst")
				}
				if take(t, l, "k").Allowed {
					t.Fatal("bucket refilled beyond burst")
				}
			})
			t.Run("reset restores a full bucket", func(t *testing.T) {
				l := f.make(t, rate.Every(time.Hour), 1)
				take(t, l, "a")
				if take(t, l, "a").Allowed {
					t.Fatal("not limited")
				}
				if err := l.Reset(context.Background(), "a"); err != nil {
					t.Fatal(err)
				}
				if !take(t, l, "a").Allowed {
					t.Fatal("reset did not restore the budget")
				}
			})
			t.Run("parallel requests never exceed the burst", func(t *testing.T) {
				l := f.make(t, rate.Every(time.Hour), 7)
				var allowed atomic.Int64
				var wg sync.WaitGroup
				start := make(chan struct{})
				for i := 0; i < 60; i++ {
					wg.Add(1)
					go func() {
						defer wg.Done()
						<-start
						d, err := l.Allow(context.Background(), "hot")
						if err != nil {
							t.Error(err)
							return
						}
						if d.Allowed {
							allowed.Add(1)
						}
					}()
				}
				close(start)
				wg.Wait()
				if allowed.Load() != 7 {
					t.Fatalf("%d of 60 parallel requests allowed, want exactly 7", allowed.Load())
				}
			})
			t.Run("parallel keys do not interfere", func(t *testing.T) {
				l := f.make(t, rate.Every(time.Hour), 2)
				var wg sync.WaitGroup
				var allowed atomic.Int64
				for k := 0; k < 10; k++ {
					for i := 0; i < 5; i++ {
						wg.Add(1)
						go func() {
							defer wg.Done()
							if d, _ := l.Allow(context.Background(), fmt.Sprintf("key-%d", k)); d.Allowed {
								allowed.Add(1)
							}
						}()
					}
				}
				wg.Wait()
				if allowed.Load() != 20 {
					t.Fatalf("%d allowed, want 2 per key = 20", allowed.Load())
				}
			})
		})
	}
}

func TestMemoryEvictsLeastRecentlyUsedAndNeverLocksOut(t *testing.T) {
	m := NewMemory(rate.Every(time.Hour), 2, 3)
	ctx := context.Background()
	m.Allow(ctx, "a")
	m.Allow(ctx, "a")
	if d, _ := m.Allow(ctx, "a"); d.Allowed {
		t.Fatal("burst not enforced")
	}
	for i := 0; i < 100; i++ {
		if d, _ := m.Allow(ctx, fmt.Sprintf("flood-%d", i)); !d.Allowed {
			t.Fatalf("new key %d refused when the table was full", i)
		}
	}
	if m.Len() > 3 {
		t.Fatalf("table grew to %d entries", m.Len())
	}
	if d, _ := m.Allow(ctx, "legit"); !d.Allowed {
		t.Fatal("legitimate client locked out by a key flood")
	}
}

// Two nodes (separate pools and limiter values) share one budget: this is the point of the backend.
func TestPostgresIsSharedAcrossNodes(t *testing.T) {
	poolA := testPool(t)
	cfg, _ := pgxpool.ParseConfig(os.Getenv("TEST_DATABASE_URL"))
	poolB, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer poolB.Close()
	name := uniqueName()
	defer poolA.Exec(context.Background(), `DELETE FROM rate_limits WHERE bucket LIKE $1`, name+"%")
	a, b := NewPostgres(poolA, name, rate.Every(time.Hour), 4), NewPostgres(poolB, name, rate.Every(time.Hour), 4)
	var allowed int
	for i := 0; i < 10; i++ {
		l := a
		if i%2 == 1 {
			l = b
		}
		if take(t, l, "u").Allowed {
			allowed++
		}
	}
	if allowed != 4 {
		t.Fatalf("%d allowed across two nodes, want 4", allowed)
	}
	// A different limiter name is a different bucket.
	if other := NewPostgres(poolA, name+"x", rate.Every(time.Hour), 4); !take(t, other, "u").Allowed {
		t.Fatal("limiters with different names share a bucket")
	}
}

func TestPostgresPurgeRemovesOnlyIdleFullBuckets(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	name := uniqueName()
	defer pool.Exec(ctx, `DELETE FROM rate_limits WHERE bucket LIKE $1`, name+"%")
	fast := NewPostgres(pool, name, 1000, 2)                      // refills in milliseconds
	slow := NewPostgres(pool, name+"s", rate.Every(time.Hour), 2) // stays partly empty
	take(t, fast, "u")
	take(t, slow, "u")
	// Age both rows past the one-minute grace: only the one that is full again is information-free.
	if _, err := pool.Exec(ctx, `UPDATE rate_limits SET updated_at = updated_at - interval '10 minutes', full_at = full_at - interval '10 minutes' WHERE bucket LIKE $1`, name+"%"); err != nil {
		t.Fatal(err)
	}
	if _, err := Purge(ctx, pool, 0); err == nil {
		t.Fatal("a zero batch must be rejected")
	}
	// Purge is global, so assert on our own rows rather than the count.
	if _, err := Purge(ctx, pool, 1000); err != nil {
		t.Fatal(err)
	}
	var fastRows, slowRows int
	pool.QueryRow(ctx, `SELECT count(*) FROM rate_limits WHERE bucket = $1`, name+":u").Scan(&fastRows)
	pool.QueryRow(ctx, `SELECT count(*) FROM rate_limits WHERE bucket = $1`, name+"s:u").Scan(&slowRows)
	if fastRows != 0 || slowRows != 1 {
		t.Fatalf("after purge: refilled bucket rows=%d (want 0), still-limited bucket rows=%d (want 1)", fastRows, slowRows)
	}
	if d := take(t, slow, "u"); !d.Allowed {
		t.Fatal("the second token was lost")
	}
}

func TestPostgresLongKeysAreHashedNotRejected(t *testing.T) {
	pool := testPool(t)
	name := uniqueName()
	defer pool.Exec(context.Background(), `DELETE FROM rate_limits WHERE bucket LIKE $1`, name+"%")
	l := NewPostgres(pool, name, rate.Every(time.Hour), 1)
	long := strings.Repeat("k", 500)
	if !take(t, l, long).Allowed || take(t, l, long).Allowed {
		t.Fatal("long key not limited")
	}
}
