package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// NoTransactionMarker as the first line of a file runs its statements one by one outside any
// transaction, which CREATE INDEX CONCURRENTLY and similar statements require. Such a file must be
// idempotent (IF NOT EXISTS, and a failed CONCURRENTLY index is dropped first): a failure part way leaves
// what ran in place and the file is attempted again by the next release step.
const NoTransactionMarker = "-- hiyall:no-transaction"

// lockKey serialises runners: two overlapping releases cannot interleave.
const lockKey = 4917301

// maxLockRetries is how many times one file is retried after a lock wait timed out (55P03), with a growing pause.
const maxLockRetries = 8

// Options tune Migrate. Zero timeouts turn that limit off.
type Options struct {
	Dir string
	// Deadline is enforced by the caller's context; it is here so the message can name it.
	Deadline time.Duration
	// LockTimeout bounds each wait for a table lock; on expiry the file's transaction is rolled back and
	// retried, so a long query holding a lock delays the release instead of failing it (or, worse,
	// queueing behind it and blocking every request that needs the table).
	LockTimeout time.Duration
	// StatementTimeout bounds one statement of a transactional file.
	StatementTimeout time.Duration
	// Log receives one line per applied file and per retry; nil is silent.
	Log func(format string, args ...any)
	// Sleep is replaced by tests; nil sleeps for real.
	Sleep func(context.Context, time.Duration)
}

func (o Options) logf(format string, args ...any) {
	if o.Log != nil {
		o.Log(format, args...)
	}
}

func ms(d time.Duration) string { return fmt.Sprintf("%dms", d.Milliseconds()) }

// Migrate applies every unapplied file in opts.Dir and returns the names it applied. Each file runs in its
// own transaction with SET LOCAL lock_timeout, together with its schema_migrations row, so a failure rolls
// back only that file and earlier files stay applied. A file whose checksum differs from the recorded one is
// refused.
func Migrate(ctx context.Context, dsn string, opts Options) (applied []string, err error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer conn.Close(context.WithoutCancel(ctx))
	// The runner lock is a session lock held for the whole run, because there is no single transaction
	// any more. Waiting for it respects the deadline.
	if _, err = conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, lockKey); err != nil {
		return nil, fmt.Errorf("waiting for another migration run: %w", err)
	}
	defer func() { _, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, lockKey) }()
	if _, err = conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations(version text PRIMARY KEY,checksum text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, err
	}
	files, err := filepath.Glob(filepath.Join(opts.Dir, "*.sql"))
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, errors.New("no migrations found")
	}
	sort.Strings(files)
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return applied, err
		}
		name := filepath.Base(file)
		sum := fmt.Sprintf("%x", sha256.Sum256(data))
		var previous string
		switch err = conn.QueryRow(ctx, `SELECT checksum FROM schema_migrations WHERE version=$1`, name).Scan(&previous); {
		case err == nil:
			if previous != sum {
				return applied, fmt.Errorf("applied migration changed: %s", name)
			}
			continue
		case !errors.Is(err, pgx.ErrNoRows):
			return applied, err
		}
		if err = applyFile(ctx, conn, name, string(data), sum, opts); err != nil {
			if ctx.Err() != nil {
				return applied, fmt.Errorf("migration %s: stopped at the overall deadline (%v): %w", name, opts.Deadline, err)
			}
			return applied, fmt.Errorf("migration %s: %w", name, err)
		}
		opts.logf("Applied %s", name)
		applied = append(applied, name)
	}
	return applied, nil
}

func applyFile(ctx context.Context, conn *pgx.Conn, name, body, sum string, opts Options) error {
	if strings.HasPrefix(strings.TrimLeft(strings.TrimPrefix(body, "\xef\xbb\xbf"), " \t"), NoTransactionMarker) {
		return applyOutsideTransaction(ctx, conn, body, name, sum, opts)
	}
	var err error
	for attempt := 0; ; attempt++ {
		if err = applyInTransaction(ctx, conn, body, name, sum, opts); !lockTimeout(err) || attempt >= maxLockRetries || ctx.Err() != nil {
			return err
		}
		pause := time.Duration(attempt+1) * 2 * time.Second
		opts.logf("Lock wait timed out applying %s; retrying in %v (%d/%d)", name, pause, attempt+1, maxLockRetries)
		sleep(ctx, opts, pause)
	}
}

func applyInTransaction(ctx context.Context, conn *pgx.Conn, body, name, sum string, opts Options) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	if _, err = tx.Exec(ctx, `SELECT set_config('lock_timeout',$1,true),set_config('statement_timeout',$2,true)`, ms(opts.LockTimeout), ms(opts.StatementTimeout)); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, body); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO schema_migrations(version,checksum) VALUES($1,$2)`, name, sum); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// applyOutsideTransaction runs a no-transaction file statement by statement (each is its own implicit
// transaction), retrying a statement whose lock wait timed out. The record is written after the last one.
func applyOutsideTransaction(ctx context.Context, conn *pgx.Conn, body, name, sum string, opts Options) error {
	// Session settings for this file only; reset so later files start clean.
	if _, err := conn.Exec(ctx, `SELECT set_config('lock_timeout',$1,false),set_config('statement_timeout','0',false)`, ms(opts.LockTimeout)); err != nil {
		return err
	}
	defer func() {
		_, _ = conn.Exec(context.WithoutCancel(ctx), `RESET lock_timeout; RESET statement_timeout`)
	}()
	for _, statement := range SplitStatements(body) {
		for attempt := 0; ; attempt++ {
			err := execSimple(ctx, conn, statement)
			if err == nil {
				break
			}
			if !lockTimeout(err) || attempt >= maxLockRetries || ctx.Err() != nil {
				return err
			}
			pause := time.Duration(attempt+1) * 2 * time.Second
			opts.logf("Lock wait timed out in %s; retrying in %v (%d/%d)", name, pause, attempt+1, maxLockRetries)
			sleep(ctx, opts, pause)
		}
	}
	_, err := conn.Exec(ctx, `INSERT INTO schema_migrations(version,checksum) VALUES($1,$2)`, name, sum)
	return err
}

// execSimple sends one statement with the simple protocol, which allows CREATE INDEX CONCURRENTLY.
func execSimple(ctx context.Context, conn *pgx.Conn, statement string) error {
	_, err := conn.Exec(ctx, statement, pgx.QueryExecModeSimpleProtocol)
	return err
}

func lockTimeout(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "55P03"
}

func sleep(ctx context.Context, opts Options, d time.Duration) {
	if opts.Sleep != nil {
		opts.Sleep(ctx, d)
		return
	}
	select {
	case <-time.After(d):
	case <-ctx.Done():
	}
}

// SplitStatements cuts a SQL script into statements at semicolons that are not inside a string, a quoted
// identifier, a dollar-quoted body or a comment. Comments are dropped; empty statements are skipped.
func SplitStatements(sql string) []string {
	var out []string
	var cur strings.Builder
	flush := func() {
		if s := strings.TrimSpace(cur.String()); s != "" {
			out = append(out, s)
		}
		cur.Reset()
	}
	for i := 0; i < len(sql); {
		c := sql[i]
		switch {
		case c == '-' && strings.HasPrefix(sql[i:], "--"):
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
		case c == '/' && strings.HasPrefix(sql[i:], "/*"):
			depth := 0
			for i < len(sql) {
				if strings.HasPrefix(sql[i:], "/*") {
					depth++
					i += 2
				} else if strings.HasPrefix(sql[i:], "*/") {
					depth--
					i += 2
					if depth == 0 {
						break
					}
				} else {
					i++
				}
			}
			cur.WriteByte(' ')
		case c == '\'' || c == '"':
			j := i + 1
			for j < len(sql) {
				if sql[j] == c {
					if j+1 < len(sql) && sql[j+1] == c {
						j += 2
						continue
					}
					break
				}
				j++
			}
			end := min(j+1, len(sql))
			cur.WriteString(sql[i:end])
			i = end
		case c == '$':
			// $tag$ ... $tag$
			j := i + 1
			for j < len(sql) && (sql[j] == '_' || sql[j] >= 'a' && sql[j] <= 'z' || sql[j] >= 'A' && sql[j] <= 'Z' || sql[j] >= '0' && sql[j] <= '9') {
				j++
			}
			if j < len(sql) && sql[j] == '$' {
				tag := sql[i : j+1]
				if end := strings.Index(sql[j+1:], tag); end >= 0 {
					stop := j + 1 + end + len(tag)
					cur.WriteString(sql[i:stop])
					i = stop
					continue
				}
			}
			cur.WriteByte(c)
			i++
		case c == ';':
			flush()
			i++
		default:
			cur.WriteByte(c)
			i++
		}
	}
	flush()
	return out
}
