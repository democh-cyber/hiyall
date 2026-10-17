package store

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/dbtest"
)

// The follow streams of the counter fix-up job order by the typed columns (round-4 audit N3). They used to order by
// the output alias of the same name, that is by the text of the timestamp and the uuid, in the collation of the
// database: under a language collation a whole second sorts after its fractions, the reverse of the timestamps, the
// chunk's cursor then jumped past neighbours that had not been read, and their counters were never recounted.
// 1300 followers, 1300 followed and 700 friends of one account on an ICU database, with timestamps that alternate
// between a whole second and half a second later, all with a wrong counter: after the job every neighbour is right
// and was looked at exactly once.
func TestCounterFixupsVisitEveryNeighbourUnderALanguageCollation(t *testing.T) {
	s := storeOn(t, dbtest.ScratchICU(t), WithTimeouts(MaintenanceTimeouts))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if n := mustCount(t, s, `SELECT ('2026-01-05 10:00:05+00'::timestamptz::text > '2026-01-05 10:00:05.5+00'::timestamptz::text)::int`); n != 1 {
		t.Fatal("this collation sorts a whole second before its fractions: the test proves nothing")
	}
	mustExec(t, s, `CREATE TABLE hub AS SELECT gen_random_uuid() AS user_id`)
	mustExec(t, s, `CREATE TABLE crowd AS SELECT gen_random_uuid() AS user_id, g FROM generate_series(1,3300) g`)
	mustExec(t, s, `INSERT INTO users(user_id) SELECT user_id FROM hub UNION ALL SELECT user_id FROM crowd`)
	const second = `timestamptz '2026-01-05 10:00:05+00'`
	// Followers 1..1300, followed 1301..2600 (a few of them also followers), friends 2601..3300.
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state,created_at) SELECT c.user_id,h.user_id,'active',`+second+`+(c.g%2)*interval '500 ms' FROM crowd c,hub h WHERE c.g<=1300`)
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state,created_at) SELECT h.user_id,c.user_id,'active',`+second+`+(c.g%2)*interval '500 ms' FROM crowd c,hub h WHERE c.g BETWEEN 1200 AND 2600`)
	mustExec(t, s, `INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status)
 SELECT gen_random_uuid(),least(h.user_id,c.user_id),greatest(h.user_id,c.user_id),h.user_id,'accepted' FROM crowd c,hub h WHERE c.g>2600`)
	if d := counterDrift(t, s); d != 0 {
		t.Fatalf("%d members drifted while the edges were created", d)
	}
	hub := ""
	if err := s.Pool.QueryRow(ctx, `SELECT user_id::text FROM hub`).Scan(&hub); err != nil {
		t.Fatal(err)
	}
	// Every neighbour's counters are wrong, and the account is queued as the trigger does for a big one.
	mustExec(t, s, `UPDATE social_counters SET followers=followers+7,following=following+7,friends=friends+7 WHERE user_id<>$1`, hub)
	mustExec(t, s, `UPDATE users SET status='suspended' WHERE user_id=$1`, hub) // small: done inline, and right
	mustExec(t, s, `UPDATE social_counters SET followers=followers+7,following=following+7,friends=friends+7 WHERE user_id<>$1`, hub)
	mustExec(t, s, `INSERT INTO counter_fixups(user_id) VALUES($1)`, hub)
	want := 1300 + 1401 + 700 // 1200..2600 is 1401 accounts
	seen, err := s.ApplyCounterFixups(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if seen != int64(want) {
		t.Errorf("the job looked at %d neighbours, want each of the %d edges exactly once", seen, want)
	}
	// The neighbours that are not an edge of the hub keep their (wrong) counters on purpose; everyone who is one is right.
	if n := mustCount(t, s, `SELECT count(*) FROM profile_social_counts v JOIN social_counters c USING(user_id) WHERE v.user_id<>$1
 AND (v.followers<>c.followers OR v.following<>c.following OR v.friends<>c.friends)
 AND (v.user_id IN (SELECT follower_id FROM follows WHERE followee_id=$1 UNION SELECT followee_id FROM follows WHERE follower_id=$1
   UNION SELECT user_low_id FROM friendships WHERE user_high_id=$1 UNION SELECT user_high_id FROM friendships WHERE user_low_id=$1))`, hub); n != 0 {
		t.Fatalf("%d neighbours were skipped by the job", n)
	}
}

// The four streams are served by their indexes: no chunk sorts the neighbourhood (a Sort node would read every edge
// of the account for each chunk of 500). The planner is held to index scans so that a plan with a Sort is the
// query's own doing.
func TestCounterFixupStreamsAreIndexOrdered(t *testing.T) {
	s := storeOn(t, dbtest.ScratchICU(t), WithTimeouts(MaintenanceTimeouts))
	ctx := context.Background()
	mustExec(t, s, `CREATE TABLE hub AS SELECT gen_random_uuid() AS user_id`)
	mustExec(t, s, `CREATE TABLE crowd AS SELECT gen_random_uuid() AS user_id, g FROM generate_series(1,6000) g`)
	mustExec(t, s, `INSERT INTO users(user_id) SELECT user_id FROM hub UNION ALL SELECT user_id FROM crowd`)
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state,created_at) SELECT c.user_id,h.user_id,'active',now()-c.g*interval '1 second' FROM crowd c,hub h WHERE c.g<=3000`)
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state,created_at) SELECT h.user_id,c.user_id,'active',now()-c.g*interval '1 second' FROM crowd c,hub h WHERE c.g>3000`)
	mustExec(t, s, `INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status)
 SELECT gen_random_uuid(),least(h.user_id,c.user_id),greatest(h.user_id,c.user_id),h.user_id,'accepted' FROM crowd c,hub h WHERE c.g%2=0`)
	mustExec(t, s, `ANALYZE`)
	hub := ""
	if err := s.Pool.QueryRow(ctx, `SELECT user_id::text FROM hub`).Scan(&hub); err != nil {
		t.Fatal(err)
	}
	for i, st := range fixupStreams {
		start := fixupStart
		if !st.desc {
			start = fixupStartAsc
		}
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		for _, set := range []string{`SET LOCAL enable_seqscan=off`, `SET LOCAL enable_bitmapscan=off`, `SET LOCAL enable_sort=off`} {
			if _, err = tx.Exec(ctx, set); err != nil {
				t.Fatal(err)
			}
		}
		// enable_sort=off makes a Sort node cost a huge penalty rather than impossible: if the plan has one the query
		// needed it.
		rows, err := tx.Query(ctx, `EXPLAIN `+st.sql, hub, "infinity", start, counterFixupChunk)
		if err != nil {
			t.Fatalf("stream %d: %v", i, err)
		}
		var plan []string
		for rows.Next() {
			var line string
			if err = rows.Scan(&line); err != nil {
				t.Fatal(err)
			}
			plan = append(plan, line)
		}
		rows.Close()
		_ = tx.Rollback(ctx)
		all := strings.Join(plan, "\n")
		if strings.Contains(all, "Sort") || !strings.Contains(all, "Index") {
			t.Errorf("stream %d is not served by an index in order:\n%s", i, all)
		}
	}
}

// Follows, unfollows and the recount of a queued account's neighbours and the purge of that account all at once
// (round-4 audit N9). A big account (more than 20000 edges) is queued when it goes into deletion; its recount chunks,
// the purge deleting its edges in batches, and members following and unfollowing each other (every one a trigger
// that bumps two counter rows) run together. No statement may fail with a deadlock after its one retry, and when
// everything has finished the counters equal a recount.
func TestCounterFixupsAndAccountPurgeRaceWithFollows(t *testing.T) {
	dsn := dbtest.Scratch(t)
	s := storeOn(t, dsn, WithMaxConns(12), WithTimeouts(MaintenanceTimeouts))
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	mustExec(t, s, `CREATE TABLE hub AS SELECT gen_random_uuid() AS user_id`)
	mustExec(t, s, `CREATE TABLE crowd AS SELECT gen_random_uuid() AS user_id, g FROM generate_series(1,20200) g`)
	mustExec(t, s, `INSERT INTO users(user_id) SELECT user_id FROM hub UNION ALL SELECT user_id FROM crowd`)
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state,created_at) SELECT c.user_id,h.user_id,'active',now()-c.g*interval '1 second' FROM crowd c,hub h`)
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state,created_at) SELECT h.user_id,c.user_id,'active',now()-c.g*interval '1 second' FROM crowd c,hub h WHERE c.g<=300`)
	if d := counterDrift(t, s); d != 0 {
		t.Fatalf("%d members drifted while the edges were created", d)
	}
	hub := ""
	if err := s.Pool.QueryRow(ctx, `SELECT user_id::text FROM hub`).Scan(&hub); err != nil {
		t.Fatal(err)
	}
	var crowd []string
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM crowd ORDER BY g LIMIT 400`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		crowd = append(crowd, id)
	}
	rows.Close()

	// The account goes into deletion and its grace period is over: the trigger queues the recount (20500 edges).
	mustExec(t, s, `UPDATE users SET status='pending_deletion',deletion_scheduled_at=now()-interval '31 days',deletion_due_at=now()-interval '1 day' WHERE user_id=$1`, hub)
	if n := mustCount(t, s, `SELECT count(*) FROM counter_fixups WHERE user_id=$1`, hub); n != 1 {
		t.Fatalf("the account was not queued: %d", n)
	}

	var deadlocks, failures atomic.Int64
	var failure atomic.Value
	fail := func(what string, err error) {
		if err == nil || errors.Is(err, context.Canceled) {
			return
		}
		if ContentionCode(err) == "40P01" {
			deadlocks.Add(1)
		}
		failures.Add(1)
		failure.Store(what + ": " + err.Error())
	}
	var wg sync.WaitGroup
	done := make(chan struct{})
	wg.Add(1)
	go func() { // the maintenance job's two parts
		defer wg.Done()
		for {
			if _, err := s.ApplyCounterFixups(ctx, 4); err != nil {
				fail("counter fix-ups", err)
			}
			select {
			case <-done:
				return
			default:
			}
		}
	}()
	// Members following and unfollowing each other, as Follow and Unfollow do it: one transaction per edge.
	var ops atomic.Int64
	for w := 0; w < 6; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; ; i++ {
				select {
				case <-done:
					return
				default:
				}
				a, b := crowd[(w*37+i*7)%len(crowd)], crowd[(w*53+i*11+1)%len(crowd)]
				if a == b {
					continue
				}
				err := s.inTx(ctx, func(tx pgx.Tx) error {
					if i%3 == 2 {
						_, err := tx.Exec(ctx, `DELETE FROM follows WHERE follower_id=$1 AND followee_id=$2`, a, b)
						return err
					}
					_, err := tx.Exec(ctx, `INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active') ON CONFLICT DO NOTHING`, a, b)
					return err
				})
				fail("follow", err)
				ops.Add(1)
			}
		}(w)
	}
	// The purge of the account, until it is finished.
	for i := 0; i < 200; i++ {
		if _, err := s.PurgeDeletedAccounts(ctx, nil, 10); err != nil {
			fail("purge", err)
			break
		}
		if mustCount(t, s, `SELECT count(*) FROM users WHERE user_id=$1 AND status='deleted'`, hub) == 1 {
			break
		}
	}
	close(done)
	wg.Wait()
	if deadlocks.Load() != 0 || failures.Load() != 0 {
		t.Fatalf("%d deadlocks survived the retry, %d failures, last: %v", deadlocks.Load(), failures.Load(), failure.Load())
	}
	if n := mustCount(t, s, `SELECT count(*) FROM users WHERE user_id=$1 AND status='deleted'`, hub); n != 1 {
		t.Fatal("the purge of the account did not finish")
	}
	// What is left of the queue, and a last recount.
	if _, err := s.ApplyCounterFixups(ctx, 100000); err != nil {
		t.Fatal(err)
	}
	if n, _, _ := s.PendingCounterFixups(ctx); n != 0 {
		t.Fatalf("%d accounts still queued", n)
	}
	t.Logf("%d follow operations ran alongside the recount and the purge", ops.Load())
	if d := counterDrift(t, s); d != 0 {
		rows, _ := s.Pool.Query(ctx, `SELECT v.user_id::text,v.followers,c.followers,v.following,c.following,v.friends,c.friends,(v.user_id=$1) FROM profile_social_counts v LEFT JOIN social_counters c ON c.user_id=v.user_id
 WHERE v.followers<>coalesce(c.followers,0) OR v.following<>coalesce(c.following,0) OR v.friends<>coalesce(c.friends,0) LIMIT 8`, hub)
		for rows.Next() {
			var id string
			var a, b, c, d2, e, f int
			var ishub bool
			_ = rows.Scan(&id, &a, &b, &c, &d2, &e, &f, &ishub)
			t.Logf("drift %s followers %d/%d following %d/%d friends %d/%d hub=%v", id, a, b, c, d2, e, f, ishub)
		}
		t.Fatalf("%d members' counters differ from a recount of their rows", d)
	}
}
