package store

import (
	"context"
	"testing"
	"time"

	"hiyall/services/api/internal/dbtest"
)

// scratchStore is a store on a fresh, fully migrated database of its own (dbtest.Scratch), for tests that commit
// bulk data.
func scratchStore(t *testing.T, opts ...Option) *Store {
	t.Helper()
	return storeOn(t, dbtest.Scratch(t), opts...)
}

func storeOn(t *testing.T, dsn string, opts ...Option) *Store {
	t.Helper()
	s, err := New(context.Background(), dsn, opts...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Pool.Close)
	return s
}

func mustExec(t *testing.T, s *Store, q string, args ...any) {
	t.Helper()
	if _, err := s.Pool.Exec(context.Background(), q, args...); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
}

func mustCount(t *testing.T, s *Store, q string, args ...any) int {
	t.Helper()
	var n int
	if err := s.Pool.QueryRow(context.Background(), q, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return n
}

// counterDrift is how many members' counter rows differ from a recount of their rows.
func counterDrift(t *testing.T, s *Store) int {
	return mustCount(t, s, `SELECT count(*) FROM profile_social_counts v LEFT JOIN social_counters c ON c.user_id=v.user_id
 WHERE v.followers<>coalesce(c.followers,0) OR v.following<>coalesce(c.following,0) OR v.friends<>coalesce(c.friends,0)`)
}

// Suspending an account with more than 20000 edges queues the neighbours' recount instead of rewriting every
// neighbour's counter row in the suspending statement (round-3 audit DB-NEW-8: 1,000,000 followers took 12.9 s in
// that statement, past the 5 s statement timeout of the upload scanner's auto-suspend). The suspension is then
// bounded; the maintenance job (ApplyCounterFixups) recounts the neighbours in chunks, in every direction, across
// chunk boundaries, and the counters end up equal to a recount of the rows. A small account is still done inline.
func TestSuspendingAHighDegreeAccountIsBoundedAndCountersConverge(t *testing.T) {
	// The default 5 s statement timeout, as the upload scanner's request pool has.
	dsn := dbtest.Scratch(t)
	s := storeOn(t, dsn, WithTimeouts(DefaultTimeouts))
	seed := storeOn(t, dsn, WithTimeouts(MaintenanceTimeouts)) // creating 21599 edges one trigger at a time is not what is timed
	ctx := context.Background()
	// hub = a member in the middle of the id range: 20100 followers, follows 700, 799 friends (their ids fall on
	// both sides of the hub's, so both friendship streams are walked).
	mustExec(t, seed, `INSERT INTO users(user_id) SELECT gen_random_uuid() FROM generate_series(1,21401)`)
	mustExec(t, seed, `CREATE TABLE hub_pick AS SELECT user_id FROM users ORDER BY user_id OFFSET 10700 LIMIT 1`)
	mustExec(t, seed, `INSERT INTO follows(follower_id,followee_id,state) SELECT u.user_id,(SELECT user_id FROM hub_pick),'active' FROM users u
 WHERE u.user_id<>(SELECT user_id FROM hub_pick) ORDER BY u.user_id LIMIT 20100`)
	mustExec(t, seed, `INSERT INTO follows(follower_id,followee_id,state) SELECT (SELECT user_id FROM hub_pick),u.user_id,'active' FROM users u
 WHERE u.user_id<>(SELECT user_id FROM hub_pick) ORDER BY u.user_id DESC LIMIT 700 ON CONFLICT DO NOTHING`)
	mustExec(t, seed, `INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status)
 SELECT gen_random_uuid(),least(h.user_id,u.user_id),greatest(h.user_id,u.user_id),h.user_id,'accepted' FROM users u, hub_pick h
 WHERE u.user_id<>h.user_id ORDER BY u.user_id OFFSET 10300 LIMIT 800`)
	if d := counterDrift(t, s); d != 0 {
		t.Fatalf("%d members drifted while the edges were created", d)
	}
	hub := ""
	if err := s.Pool.QueryRow(ctx, `SELECT user_id::text FROM hub_pick`).Scan(&hub); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	mustExec(t, s, `UPDATE users SET status='suspended' WHERE user_id=$1`, hub)
	took := time.Since(start)
	if took > 2*time.Second {
		t.Errorf("suspending took %v", took)
	}
	t.Logf("suspension of an account with %d edges took %v", 20100+700+799, took)
	if n := mustCount(t, s, `SELECT count(*) FROM counter_fixups WHERE user_id=$1`, hub); n != 1 {
		t.Fatalf("the account was not queued: %d rows", n)
	}
	if counterDrift(t, s) == 0 {
		t.Fatal("the neighbours cannot be right before the job has run: the suspension must not have rewritten them")
	}
	seen, err := s.ApplyCounterFixups(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if seen < 20100+700+799 {
		t.Errorf("the job looked at %d neighbours, want at least %d", seen, 20100+700+799)
	}
	if n, _, _ := s.PendingCounterFixups(ctx); n != 0 {
		t.Fatalf("%d accounts still queued", n)
	}
	if d := counterDrift(t, s); d != 0 {
		t.Fatalf("%d members' counters differ from a recount after the job", d)
	}

	// Restored while the first recount had not finished: a delta now would be counted twice by the running
	// recount, so the trigger queues again and the end state is right.
	mustExec(t, s, `UPDATE users SET status='active' WHERE user_id=$1`, hub)
	if _, err = s.ApplyCounterFixups(ctx, 3); err != nil { // part of it only (3 chunks)
		t.Fatal(err)
	}
	mustExec(t, s, `UPDATE users SET status='suspended' WHERE user_id=$1`, hub)
	mustExec(t, s, `UPDATE users SET status='active' WHERE user_id=$1`, hub)
	if n := mustCount(t, s, `SELECT count(*) FROM counter_fixups WHERE user_id=$1 AND stream=0 AND after_ts='infinity'`, hub); n != 1 {
		t.Fatalf("a status change during a recount must start it over: %d", n)
	}
	if _, err = s.ApplyCounterFixups(ctx, 1000); err != nil {
		t.Fatal(err)
	}
	if d := counterDrift(t, s); d != 0 {
		t.Fatalf("%d members' counters differ from a recount after restore", d)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM social_counters WHERE user_id IN (SELECT follower_id FROM follows WHERE followee_id=$1) AND following<1`, hub); n != 0 {
		t.Fatalf("%d followers do not count the restored account", n)
	}

	// A small account stays on the inline path: right at once, nothing queued.
	mustExec(t, s, `CREATE TABLE small_pick AS SELECT user_id FROM users WHERE user_id<>$1 ORDER BY user_id DESC LIMIT 1`, hub)
	mustExec(t, s, `UPDATE users SET status='suspended' WHERE user_id=(SELECT user_id FROM small_pick)`)
	if n := mustCount(t, s, `SELECT count(*) FROM counter_fixups`); n != 0 {
		t.Fatalf("a small account was queued: %d", n)
	}
	if d := counterDrift(t, s); d != 0 {
		t.Fatalf("%d members drifted after a small suspension", d)
	}
}
