package store

import (
	"context"
	"errors"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"hiyall/services/api/internal/metrics"
)

// Contention is the database telling a request to try again rather than that it is wrong: a lock wait that
// timed out (55P03), a statement that ran past its timeout or was cancelled (57014), a deadlock the server broke
// by aborting this transaction (40P01) or a serialization failure (40001). The HTTP layer answers these with
// 503 TEMPORARILY_UNAVAILABLE and Retry-After, and counts them in hiyall_db_contention_total{code}.

// ContentionCode returns the SQLSTATE of err when it is one of the contention errors above, otherwise "".
func ContentionCode(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		switch pe.Code {
		case "55P03", "57014", "40P01", "40001":
			return pe.Code
		}
	}
	return ""
}

var contentionRetries = metrics.NewCounter("hiyall_db_contention_retries_total", "Transactions run a second time after a deadlock (40P01) or a lock timeout (55P03), by SQLSTATE and whether the second run succeeded.", "code", "result")

// contentionPause is how long a transaction waits before its single retry; random, so two transactions that
// deadlocked do not collide again in step.
var contentionPause = func() time.Duration {
	return 10*time.Millisecond + time.Duration(rand.Int64N(int64(40*time.Millisecond)))
}

// inTx runs work in one transaction. When the server aborted it for a deadlock (40P01) or a lock wait timed out
// (55P03) it runs the whole transaction once more: the first run was rolled back completely, so nothing it did
// is visible, and work must therefore be repeatable (no side effect outside tx; assigning to the caller's
// variables is fine). Any other error, and a second contention error, is returned as it is. The caller's context
// bounds the retry: it is not attempted once that has ended.
func (s *Store) inTx(ctx context.Context, work func(pgx.Tx) error) error {
	err := s.inTxOnce(ctx, work)
	code := ContentionCode(err)
	if (code != "40P01" && code != "55P03") || ctx.Err() != nil {
		return err
	}
	timer := time.NewTimer(contentionPause())
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
		return err
	}
	err = s.inTxOnce(ctx, work)
	result := "ok"
	if err != nil {
		result = "failed"
	}
	contentionRetries.Inc(code, result)
	return err
}

// inTxOnce is one transaction without a retry, for work that cannot be repeated.
func (s *Store) inTxOnce(ctx context.Context, work func(pgx.Tx) error) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = work(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
