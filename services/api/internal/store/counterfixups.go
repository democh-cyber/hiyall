package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Counters of a very large account (migration 0044). Suspending, restoring or deactivating an account changes
// whether it counts in its neighbours' followers, following and friends. The trigger users_status_counters does
// that in the same statement for an account with up to 20000 edges; for a bigger one it only queues the account
// in counter_fixups, so the suspension itself (which the upload scanner and the console do under a statement
// timeout) costs a bounded read however many followers the account has. ApplyCounterFixups, a maintenance job,
// then recounts the neighbours in chunks of counterFixupChunk, each in its own transaction, from the follow and
// friendship rows (the profile_social_counts view, exactly what ReconcileSocialCounters writes).
//
// Between the commit of the status change and the end of the recount the neighbours' counters still show the old
// status of the account (by at most that one account, and the account itself is hidden meanwhile). An edge that
// is removed in that window from a neighbour the recount has not reached yet leaves that neighbour one too high
// until the weekly ReconcileSocialCounters repairs it; that needs a member to change a relationship with an
// account that is suspended, deactivated or in deletion, which the API does not offer. The one process that
// deletes such edges, the purge of the account itself, finishes the account's recount first (drainCounterFixups).

// counterFixupChunk is how many neighbour counter rows one fix-up transaction locks and recounts.
const counterFixupChunk = 500

const (
	fixupStart     = "ffffffff-ffff-ffff-ffff-ffffffffffff" // before the first row of a newest-first stream
	fixupStartAsc  = "00000000-0000-0000-0000-000000000000" // before the first row of an ascending stream
	fixupLastStage = 3
)

// fixupStreams is how a queued account's neighbours are walked, each in the order of an existing index so that a
// chunk never sorts the account's whole neighbourhood: follows_follower_list, follows_followee_list, the unique
// (user_low_id, user_high_id) and friendships_high_low (migration 0044). Each returns the neighbour and the
// cursor text (created_at for the follow streams).
//
// Every ORDER BY names the table's own typed columns (f.created_at, f.followee_id), never the output column. A
// bare "ORDER BY created_at" in a query that also selects "created_at::text" means the OUTPUT column, which is
// text: the stream was then sorted by the text of the timestamp (a whole second prints without a fraction, so
// "…:05+00" sorts before "…:05.5+00" and after "…:04.9+00" for a DESC walk that wants the opposite), by the text of
// the uuid, with the collation of the database, and with a sort of the account's whole neighbourhood in every
// chunk instead of a read of the index. The keyset comparison in the WHERE clause is on the typed columns, so the
// two disagreed and neighbours could be skipped or counted twice (round-4 audit N3). The output columns are called
// nb and ts so that a name can never be captured again.
var fixupStreams = [fixupLastStage + 1]struct {
	sql  string
	desc bool
}{
	{`SELECT f.followee_id::text AS nb,f.created_at::text AS ts FROM follows f WHERE f.follower_id=$1 AND f.state='active' AND (f.created_at,f.followee_id)<($2::timestamptz,$3::uuid)
 ORDER BY f.created_at DESC,f.followee_id DESC LIMIT $4`, true},
	{`SELECT f.follower_id::text AS nb,f.created_at::text AS ts FROM follows f WHERE f.followee_id=$1 AND f.state='active' AND (f.created_at,f.follower_id)<($2::timestamptz,$3::uuid)
 ORDER BY f.created_at DESC,f.follower_id DESC LIMIT $4`, true},
	{`SELECT f.user_high_id::text AS nb,'infinity' AS ts FROM friendships f WHERE f.user_low_id=$1 AND f.status='accepted' AND f.user_high_id>$3::uuid AND $2::timestamptz IS NOT NULL
 ORDER BY f.user_high_id LIMIT $4`, false},
	{`SELECT f.user_low_id::text AS nb,'infinity' AS ts FROM friendships f WHERE f.user_high_id=$1 AND f.status='accepted' AND f.user_low_id>$3::uuid AND $2::timestamptz IS NOT NULL
 ORDER BY f.user_low_id LIMIT $4`, false},
}

// ApplyCounterFixups runs at most maxChunks chunks of the queued recounts (oldest queued account first) and
// returns how many neighbour counter rows it looked at. It stops when the queue is empty or ctx ends. A
// transaction that fails (a deadlock or lock timeout after inTx's one retry) ends the run with the error; the
// queue row keeps its position, so the next run continues there.
func (s *Store) ApplyCounterFixups(ctx context.Context, maxChunks int) (int64, error) {
	var total int64
	for range maxChunks {
		if ctx.Err() != nil {
			return total, ctx.Err()
		}
		n, found, err := s.counterFixupChunk(ctx, "")
		total += n
		if err != nil || !found {
			return total, err
		}
	}
	return total, nil
}

// counterFixupChunk does one chunk of the oldest queued account, or of account only when it is not empty. found is
// false when there is nothing to do (or the only row is held by another worker).
func (s *Store) counterFixupChunk(ctx context.Context, only string) (seen int64, found bool, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		seen, found = 0, false
		var user, ts, after string
		var stream int
		err := tx.QueryRow(ctx, `SELECT user_id::text,stream,after_ts::text,after_id::text FROM counter_fixups WHERE ($1='' OR user_id=$1::uuid) ORDER BY queued_at LIMIT 1 FOR UPDATE SKIP LOCKED`, only).Scan(&user, &stream, &ts, &after)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		found = true
		rows, err := tx.Query(ctx, fixupStreams[stream].sql, user, ts, after, counterFixupChunk)
		if err != nil {
			return err
		}
		var ids []string
		var lastTS string
		for rows.Next() {
			var id string
			if err = rows.Scan(&id, &lastTS); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return err
		}
		if len(ids) > 0 {
			if err = recountSocial(ctx, tx, ids); err != nil {
				return err
			}
		}
		seen = int64(len(ids))
		switch {
		case len(ids) == counterFixupChunk:
			_, err = tx.Exec(ctx, `UPDATE counter_fixups SET after_ts=$2::timestamptz,after_id=$3::uuid WHERE user_id=$1`, user, lastTS, ids[len(ids)-1])
		case stream == fixupLastStage:
			_, err = tx.Exec(ctx, `DELETE FROM counter_fixups WHERE user_id=$1`, user)
		default:
			start := fixupStart
			if !fixupStreams[stream+1].desc {
				start = fixupStartAsc
			}
			_, err = tx.Exec(ctx, `UPDATE counter_fixups SET stream=stream+1,after_ts='infinity',after_id=$2::uuid WHERE user_id=$1`, user, start)
		}
		return err
	})
	return seen, found, err
}

// drainCounterFixups finishes the recount that account user has queued, on the caller's goroutine, and says whether
// none is left. The account purge calls it before it deletes the account's follows and friendships: the recount
// walks those rows, so a neighbour whose edge the purge deleted first is never visited and keeps the counter that
// still counted the (by now inactive) account until the weekly reconcile (round-4 audit N9: found by the concurrency
// test, 9000 followers one too high). It is false while another worker holds the queue row, in which case the purge
// waits for its next run.
func (s *Store) drainCounterFixups(ctx context.Context, user string) (bool, error) {
	for {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		_, found, err := s.counterFixupChunk(ctx, user)
		if err != nil {
			return false, err
		}
		if found {
			continue
		}
		var queued bool
		if err = s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM counter_fixups WHERE user_id=$1)`, user).Scan(&queued); err != nil {
			return false, err
		}
		return !queued, nil
	}
}

// recountSocial makes the counter rows of ids equal to what their follow and friendship rows say. The rows are
// created if missing and locked in id order first, then recounted in a statement with a fresh snapshot: a
// transaction that changed an edge and has not committed holds the rows, so the recount waits for it, and one
// whose bump has not run yet lands its change on top of the repaired value (see ReconcileSocialCounters).
func recountSocial(ctx context.Context, tx pgx.Tx, ids []string) error {
	if _, err := tx.Exec(ctx, `INSERT INTO social_counters(user_id) SELECT u FROM unnest($1::uuid[]) u ORDER BY u ON CONFLICT (user_id) DO NOTHING`, ids); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM social_counters WHERE user_id=ANY($1::uuid[]) ORDER BY user_id FOR UPDATE`, ids); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE social_counters c SET followers=v.followers,following=v.following,friends=v.friends,updated_at=now()
 FROM profile_social_counts v WHERE v.user_id=c.user_id AND c.user_id=ANY($1::uuid[]) AND (c.followers<>v.followers OR c.following<>v.following OR c.friends<>v.friends)`, ids)
	return err
}

// PendingCounterFixups is how many accounts still wait for their neighbours' recount.
func (s *Store) PendingCounterFixups(ctx context.Context) (n int64, oldest *time.Time, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT count(*),min(queued_at) FROM counter_fixups`).Scan(&n, &oldest)
	return n, oldest, err
}
