package maintenance_test

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

type fakeElector struct {
	lead     bool
	err      error
	released atomic.Bool
}

func (f *fakeElector) Acquire(context.Context) (bool, error) { return f.lead, f.err }
func (f *fakeElector) Release(context.Context) error         { f.released.Store(true); return nil }

func TestJobsOnlyRunOnTheLeaderAndDrainBatches(t *testing.T) {
	var calls atomic.Int64
	remaining := []int64{5, 5, 2} // two full batches, then a short one ends the drain
	jobs := []maintenance.Job{
		{"drains", func() (int64, error) {
			n := remaining[0]
			remaining = remaining[1:]
			calls.Add(1)
			return n, nil
		}},
		{"fails", func() (int64, error) { return 0, errors.New("boom") }},
		{"after failure", func() (int64, error) { calls.Add(100); return 0, nil }},
	}
	follower := &fakeElector{lead: false}
	if maintenance.RunOnce(context.Background(), follower, jobs, 5) || calls.Load() != 0 {
		t.Fatal("a follower ran jobs")
	}
	if maintenance.RunOnce(context.Background(), &fakeElector{err: errors.New("db down")}, jobs, 5) || calls.Load() != 0 {
		t.Fatal("an instance that could not elect ran jobs")
	}
	if !maintenance.RunOnce(context.Background(), &fakeElector{lead: true}, jobs, 5) {
		t.Fatal("leader did not run")
	}
	if calls.Load() != 3+100 {
		t.Fatalf("calls = %d: batches not drained, or a failing job stopped the others", calls.Load())
	}
	var sb strings.Builder
	metrics.Default.WriteTo(&sb)
	out := sb.String()
	for _, want := range []string{
		`hiyall_maintenance_job_runs_total{job="drains",result="ok"} 1`,
		`hiyall_maintenance_job_runs_total{job="fails",result="error"} 1`,
		`hiyall_maintenance_job_rows_total{job="drains"} 12`,
		`hiyall_maintenance_job_duration_seconds_count{job="drains"} 1`,
		`hiyall_maintenance_ticks_total{outcome="follower"} 1`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("metric %q missing:\n%s", want, out)
		}
	}
}

func TestRunReleasesLeadershipOnShutdown(t *testing.T) {
	el := &fakeElector{lead: true}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { maintenance.Run(ctx, el, nil, time.Hour, 5); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Run did not stop")
	}
	if !el.released.Load() {
		t.Fatal("leadership not released at shutdown")
	}
}

// Two Store instances (two API nodes) on one database: only one runs each tick, and when it shuts
// down the other takes over.
func TestOnlyOneStoreInstanceRunsTheJobs(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	a, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Pool.Close()
	b, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Pool.Close()
	// A lock key of its own: a development API against this database must not compete with the test.
	const key int64 = 4917398
	var ranA, ranB atomic.Int64
	jobsA := []maintenance.Job{{"leader-test", func() (int64, error) { ranA.Add(1); return 0, nil }}}
	jobsB := []maintenance.Job{{"leader-test", func() (int64, error) { ranB.Add(1); return 0, nil }}}
	la, lb := a.NewLeader(key), b.NewLeader(key)
	defer la.Release(ctx)
	defer lb.Release(ctx)
	for i := 0; i < 5; i++ {
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); maintenance.RunOnce(ctx, la, jobsA, 5000) }()
		go func() { defer wg.Done(); maintenance.RunOnce(ctx, lb, jobsB, 5000) }()
		wg.Wait()
	}
	if ranA.Load()+ranB.Load() != 5 {
		t.Fatalf("jobs ran %d+%d times in 5 ticks across two instances, want exactly 5 in total", ranA.Load(), ranB.Load())
	}
	if (ranA.Load() == 0) == (ranB.Load() == 0) {
		t.Fatalf("one instance must run all ticks, got %d and %d", ranA.Load(), ranB.Load())
	}
	// The leader goes away: the other instance takes over on its next tick.
	leader, follower, followerJobs, followerRan := la, lb, jobsB, &ranB
	if ranB.Load() > 0 {
		leader, follower, followerJobs, followerRan = lb, la, jobsA, &ranA
	}
	before := followerRan.Load()
	if err = leader.Release(ctx); err != nil {
		t.Fatal(err)
	}
	if !maintenance.RunOnce(ctx, follower, followerJobs, 5000) || followerRan.Load() != before+1 {
		t.Fatal("the other instance did not take over")
	}
}
