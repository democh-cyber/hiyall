package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestContentionCodeNamesTheRetryableErrors(t *testing.T) {
	for _, code := range []string{"55P03", "57014", "40P01", "40001"} {
		wrapped := fmt.Errorf("load: %w", &pgconn.PgError{Code: code})
		if got := ContentionCode(wrapped); got != code {
			t.Errorf("%s: got %q", code, got)
		}
	}
	for _, err := range []error{nil, errors.New("boom"), &pgconn.PgError{Code: "23505"}, &pgconn.PgError{Code: "42501"}, context.Canceled} {
		if got := ContentionCode(err); got != "" {
			t.Errorf("%v: got %q, want none", err, got)
		}
	}
}

// inTx runs the transaction once more after a deadlock or a lock timeout, and only once; other errors are not
// retried. The failure is injected as the PgError the server would send.
func TestInTxRetriesOnceOnDeadlockAndLockTimeout(t *testing.T) {
	s := opsTestStore(t)
	ctx := context.Background()
	contentionPause = func() time.Duration { return time.Millisecond }
	t.Cleanup(func() { contentionPause = func() time.Duration { return 10 * time.Millisecond } })
	run := func(failures []string) (calls int, err error) {
		err = s.inTx(ctx, func(tx pgx.Tx) error {
			calls++
			if calls <= len(failures) {
				return &pgconn.PgError{Code: failures[calls-1]}
			}
			_, err := tx.Exec(ctx, `SELECT 1`)
			return err
		})
		return
	}
	for _, code := range []string{"40P01", "55P03"} {
		if calls, err := run([]string{code}); err != nil || calls != 2 {
			t.Errorf("%s once: %d calls, %v", code, calls, err)
		}
		if calls, err := run([]string{code, code}); ContentionCode(err) != code || calls != 2 {
			t.Errorf("%s twice: %d calls, %v (want the second failure after exactly one retry)", code, calls, err)
		}
	}
	// A statement timeout, a serialization failure and any other error are returned at once.
	for _, code := range []string{"57014", "40001", "23505", "42501"} {
		if calls, err := run([]string{code}); err == nil || calls != 1 {
			t.Errorf("%s: %d calls, %v (want one call and the error)", code, calls, err)
		}
	}
	// No retry once the caller's context is over.
	done, cancel := context.WithCancel(ctx)
	calls := 0
	err := s.inTx(done, func(tx pgx.Tx) error {
		calls++
		cancel()
		return &pgconn.PgError{Code: "40P01"}
	})
	if calls != 1 || ContentionCode(err) != "40P01" {
		t.Errorf("cancelled: %d calls, %v", calls, err)
	}
	// inTxOnce never retries.
	calls = 0
	_ = s.inTxOnce(ctx, func(tx pgx.Tx) error { calls++; return &pgconn.PgError{Code: "40P01"} })
	if calls != 1 {
		t.Errorf("inTxOnce ran %d times", calls)
	}
}

// A real deadlock between two transactions: the server aborts one with 40P01, inTx runs it again, and both
// transactions finish (about a second: PostgreSQL's deadlock_timeout).
func TestInTxRecoversFromARealDeadlock(t *testing.T) {
	s := opsTestStore(t)
	ctx := context.Background()
	const a, b = 4917411, 4917412
	var wg sync.WaitGroup
	var barrier sync.WaitGroup
	barrier.Add(2)
	errs := make([]error, 2)
	attempts := make([]int, 2)
	for i, order := range [][2]int{{a, b}, {b, a}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = s.inTx(ctx, func(tx pgx.Tx) error {
				attempts[i]++
				if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, order[0]); err != nil {
					return err
				}
				if attempts[i] == 1 {
					barrier.Done()
					barrier.Wait() // both hold their first lock before either asks for the second
				}
				_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, order[1])
				return err
			})
		}()
	}
	wg.Wait()
	if errs[0] != nil || errs[1] != nil {
		t.Fatalf("errors %v %v (attempts %v)", errs[0], errs[1], attempts)
	}
	if attempts[0]+attempts[1] != 3 {
		t.Fatalf("attempts %v: exactly one transaction should have been retried once", attempts)
	}
}
