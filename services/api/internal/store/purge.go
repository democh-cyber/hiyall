package store

import (
	"context"
	"errors"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// The account purge runs in bounded batches (audit D2). Each batch is its own short transaction that first
// checks the account is still in status 'deleting' (the fence: a purge never touches an account that is
// active again, and CancelDeletion cannot reach an account in 'deleting'), so a large account never holds one
// long transaction or one long set of row locks, and a crash or an error loses only the batch in flight. Every
// statement is idempotent: running the purge again repeats nothing and finishes what was left.

// purgeBatch is the largest number of rows one purge statement touches.
const purgeBatch = 1000

// purgeMaxRounds bounds the loop of one statement, so a statement that never runs dry (a bug) ends in an error
// the next run retries instead of spinning.
const purgeMaxRounds = 100000

// errPurgeFenced means the account is no longer in status 'deleting'; the purge stops quietly.
var errPurgeFenced = errors.New("account is no longer being deleted")

// purgeTx runs fn in its own transaction, after checking the fence.
func (s *Store) purgeTx(ctx context.Context, id string, fn func(pgx.Tx) error) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM users WHERE user_id=$1`, id).Scan(&status); err != nil {
			return mapped(err)
		}
		if status != "deleting" {
			return errPurgeFenced
		}
		return fn(tx)
	})
}

var (
	boundedDelete = regexp.MustCompile(`(?s)^DELETE FROM (\w+)(?: (\w+))? WHERE (.+)$`)
	boundedUpdate = regexp.MustCompile(`(?s)^UPDATE (\w+)(?: (\w+))? SET (.+?) WHERE (.+)$`)
)

// bounded rewrites a single-table DELETE or UPDATE ... WHERE so that it touches at most $2 rows:
//
//	DELETE FROM t a WHERE cond  ->  DELETE FROM t a WHERE a.ctid IN (SELECT a.ctid FROM t a WHERE cond LIMIT $2)
//
// An UPDATE must stop matching its own condition once applied (every purge update does), or its loop would
// never end. Any other statement is returned unchanged.
func bounded(stmt string) string {
	if m := boundedDelete.FindStringSubmatch(stmt); m != nil {
		table, alias, cond := m[1], m[2], m[3]
		ref := table
		if alias != "" {
			ref = alias
		}
		return "DELETE FROM " + strings.TrimSpace(table+" "+alias) + " WHERE " + ref + ".ctid IN (SELECT " + ref + ".ctid FROM " + strings.TrimSpace(table+" "+alias) + " WHERE " + cond + " LIMIT $2)"
	}
	if m := boundedUpdate.FindStringSubmatch(stmt); m != nil {
		table, alias, set, cond := m[1], m[2], m[3], m[4]
		ref := table
		if alias != "" {
			ref = alias
		}
		return "UPDATE " + strings.TrimSpace(table+" "+alias) + " SET " + set + " WHERE " + ref + ".ctid IN (SELECT " + ref + ".ctid FROM " + strings.TrimSpace(table+" "+alias) + " WHERE " + cond + " LIMIT $2)"
	}
	return stmt
}

// purgeStatement runs stmt (with $1 the account and, when it uses it, $2 the batch size) in batches until a
// batch is short. A statement that starts with SELECT or WITH returns its row count as one number (a
// data-modifying CTE that deletes or updates and adjusts a counter in the same statement); anything else
// counts affected rows. untilZero keeps going until a batch touches nothing, for steps where finishing one
// batch exposes more work (comment threads are deleted leaf first).
func (s *Store) purgeStatement(ctx context.Context, id, stmt string, untilZero bool) error {
	return s.purgeStatementArgs(ctx, id, stmt, untilZero, id)
}

// purgeStatementArgs is purgeStatement with its own first argument (a space id, say): the batch size is
// always the argument after args.
func (s *Store) purgeStatementArgs(ctx context.Context, id, stmt string, untilZero bool, args ...any) error {
	stmt = bounded(stmt)
	limited := strings.Contains(stmt, "$"+strconv.Itoa(len(args)+1))
	if limited {
		args = append(append([]any{}, args...), purgeBatch)
	}
	counted := strings.HasPrefix(stmt, "SELECT") || strings.HasPrefix(stmt, "WITH")
	for range purgeMaxRounds {
		var n int64
		err := s.purgeTx(ctx, id, func(tx pgx.Tx) error {
			if counted {
				return tx.QueryRow(ctx, stmt, args...).Scan(&n)
			}
			tag, err := tx.Exec(ctx, stmt, args...)
			n = tag.RowsAffected()
			return err
		})
		if err != nil {
			return err
		}
		if n == 0 || !limited || (!untilZero && n < purgeBatch) {
			return nil
		}
	}
	return errors.New("a purge step did not finish; the next run continues it")
}
