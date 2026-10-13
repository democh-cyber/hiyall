// Package maintenance runs the API's periodic cleanup jobs on exactly one instance at a time.
//
// Every API instance starts Run; each tick, only the instance that holds the leader lock (see
// store.Leader) runs the jobs, the others skip the tick and try to take over on the next one, so a
// crashed leader is replaced within one interval. Jobs are small idempotent batches, so a handover in
// the middle of a run is safe.
package maintenance

import (
	"context"
	"log/slog"
	"time"

	"hiyall/services/api/internal/metrics"
)

// Job is one cleanup task. Run does one batch and returns how many rows (or objects) it handled; the
// runner repeats it while it returns a full batch.
type Job struct {
	Name string
	Run  func() (int64, error)
}

// Elector decides which instance runs the jobs. store.Leader implements it.
type Elector interface {
	Acquire(ctx context.Context) (bool, error)
	Release(ctx context.Context) error
}

var (
	runs     = metrics.NewCounter("hiyall_maintenance_job_runs_total", "Maintenance job runs by outcome.", "job", "result")
	rows     = metrics.NewCounter("hiyall_maintenance_job_rows_total", "Rows or objects handled by maintenance jobs.", "job")
	duration = metrics.NewHistogram("hiyall_maintenance_job_duration_seconds", "Time a maintenance job took to drain its backlog.", []float64{.01, .05, .25, 1, 5, 30, 120, 600}, "job")
	lastRun  = metrics.NewGauge("hiyall_maintenance_job_last_run_timestamp_seconds", "Unix time the job last finished, successfully or not.", "job")
	skipped  = metrics.NewCounter("hiyall_maintenance_ticks_total", "Maintenance ticks by what this instance did.", "outcome")
	leader   = metrics.NewGauge("hiyall_maintenance_leader", "1 while this instance holds the maintenance lock.")
)

// Run executes the jobs every interval until ctx ends, then releases leadership. It returns after the
// release, so callers can wait for it to give the lock up on shutdown.
func Run(ctx context.Context, el Elector, jobs []Job, interval time.Duration, batch int64) {
	tick := time.NewTicker(interval)
	defer tick.Stop()
	defer func() {
		leader.Set(0)
		release, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := el.Release(release); err != nil {
			slog.Warn("maintenance leadership release failed", "reason", err.Error())
		}
	}()
	for {
		RunOnce(ctx, el, jobs, batch)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// RunOnce runs every job once if this instance is the leader, and reports whether it was.
func RunOnce(ctx context.Context, el Elector, jobs []Job, batch int64) bool {
	led, err := el.Acquire(ctx)
	if err != nil {
		leader.Set(0)
		skipped.Inc("error")
		if ctx.Err() == nil {
			slog.Warn("maintenance leader election failed", "reason", err.Error())
		}
		return false
	}
	if !led {
		leader.Set(0)
		skipped.Inc("follower")
		return false
	}
	leader.Set(1)
	skipped.Inc("leader")
	for _, job := range jobs {
		runJob(ctx, job, batch)
	}
	return true
}

func runJob(ctx context.Context, job Job, batch int64) {
	start := time.Now()
	var total int64
	result := "ok"
	for ctx.Err() == nil {
		n, err := job.Run()
		total += n
		if err != nil {
			result = "error"
			if ctx.Err() == nil {
				slog.Warn(job.Name+" failed", "reason", err.Error())
			}
			break
		}
		if n < batch {
			break
		}
	}
	if ctx.Err() != nil && result == "ok" {
		result = "canceled"
	}
	runs.Inc(job.Name, result)
	rows.Add(float64(total), job.Name)
	duration.Observe(time.Since(start).Seconds(), job.Name)
	lastRun.Set(float64(time.Now().Unix()), job.Name)
}
