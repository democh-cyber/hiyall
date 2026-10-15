package httpapi

import (
	"context"
	"math/rand/v2"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// The follower, following and friend counters are kept by triggers (migration 0033). Unfollow, remove follower
// and unfriend used to change an edge without locking the two members, so a suspension committing between the
// trigger's status read and the edge's commit counted the edge twice; the weekly reconcile overwrote bumps that
// committed after its snapshot; the purge's batch delete took counter rows in row order. This runs all of them
// at once (follow, unfollow, remove follower, friend request and unfriend, block, suspend and restore, the
// reconcile in a loop, an account purge) and then demands that every counter equals a recount from the rows, and
// that the reconcile has nothing left to repair.
func TestSocialCountersEqualARecountAfterConcurrentChanges(t *testing.T) {
	h := newAcctHarness(t)
	ctx := context.Background()
	users := []string{alice, bob, cara, dev, eli, xan}
	victim := yui // is deleted and purged during the run
	free := domain.EntitlementsFor(domain.PlanFree)

	var wg sync.WaitGroup
	stop := make(chan struct{})
	var ops, contended int64
	var mu sync.Mutex
	note := func(err error) {
		mu.Lock()
		defer mu.Unlock()
		ops++
		if store.ContentionCode(err) != "" {
			contended++ // rolled back whole: no drift, and the API answers 503
		}
	}
	pairs := append(append([]string{}, users...), victim)
	worker := func(seed uint64) {
		defer wg.Done()
		rng := rand.New(rand.NewPCG(seed, seed*7919))
		for i := 0; i < 120; i++ {
			a, b := pairs[rng.IntN(len(pairs))], pairs[rng.IntN(len(pairs))]
			if a == b {
				continue
			}
			var err error
			switch rng.IntN(9) {
			case 0, 1:
				_, err = h.db.Follow(ctx, a, b, free)
			case 2:
				err = h.db.Unfollow(ctx, a, b)
			case 3:
				err = h.db.RemoveFollower(ctx, a, b)
			case 4, 5:
				_, err = h.db.SendFriendRequest(ctx, a, b, nil, free)
			case 6:
				err = h.db.Unfriend(ctx, a, b)
			case 7:
				err = h.db.SetBlock(ctx, a, b, true)
			case 8:
				err = h.db.SetBlock(ctx, a, b, false)
			}
			note(err)
		}
	}
	for s := uint64(1); s <= 6; s++ {
		wg.Add(1)
		go worker(s)
	}
	// Suspend and restore two members over and over, as moderation does.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 25; i++ {
			target := []string{bob, dev}[i%2]
			_, err := h.db.Pool.Exec(ctx, `UPDATE users SET status='suspended' WHERE user_id=$1 AND status='active'`, target)
			note(err)
			time.Sleep(time.Millisecond)
			_, err = h.db.Pool.Exec(ctx, `UPDATE users SET status='active' WHERE user_id=$1 AND status='suspended'`, target)
			note(err)
		}
	}()
	// The reconcile, over and over (every=0: each call is a full pass).
	var repairedDuring int64
	reconciles := make(chan struct{})
	go func() {
		defer close(reconciles)
		for {
			select {
			case <-stop:
				return
			default:
			}
			n, err := h.db.ReconcileSocialCounters(ctx, 0)
			note(err)
			mu.Lock()
			repairedDuring += n
			mu.Unlock()
		}
	}()
	// An account purge in the middle of it.
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(20 * time.Millisecond)
		note(func() error { _, err := h.db.ScheduleDeletion(ctx, victim); return err }())
		_, err := h.db.Pool.Exec(ctx, `UPDATE users SET deletion_due_at=now()-interval '1 minute',deletion_scheduled_at=now()-interval '30 days 1 minute' WHERE user_id=$1 AND status='pending_deletion'`, victim)
		note(err)
		for run := 0; run < 4; run++ {
			_, err = h.db.PurgeDeletedAccounts(ctx, &fakeDeleter{}, 10)
			note(err)
		}
	}()
	wg.Wait()
	close(stop)
	<-reconciles

	// Whoever is left suspended is restored: the recount below covers every state, but a clean end is easier to read.
	if _, err := h.db.Pool.Exec(ctx, `UPDATE users SET status='active' WHERE status='suspended'`); err != nil {
		t.Fatal(err)
	}
	rows, err := h.db.Pool.Query(ctx, `SELECT v.user_id::text,v.followers,v.following,v.friends,coalesce(c.followers,0),coalesce(c.following,0),coalesce(c.friends,0)
 FROM profile_social_counts v LEFT JOIN social_counters c ON c.user_id=v.user_id ORDER BY v.user_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	checked := 0
	for rows.Next() {
		var id string
		var f, g, fr, cf, cg, cfr int
		if err = rows.Scan(&id, &f, &g, &fr, &cf, &cg, &cfr); err != nil {
			t.Fatal(err)
		}
		checked++
		if f != cf || g != cg || fr != cfr {
			t.Errorf("%s: counters followers/following/friends %d/%d/%d, recount %d/%d/%d", id, cf, cg, cfr, f, g, fr)
		}
	}
	rows.Close()
	if checked < len(users) {
		t.Fatalf("only %d members checked", checked)
	}
	if repairedDuring != 0 {
		t.Errorf("the reconcile repaired %d counters while the changes ran: something drifted", repairedDuring)
	}
	// Quiet now: a full reconcile finds nothing to repair.
	if n, err := h.db.ReconcileSocialCounters(ctx, 0); err != nil || n != 0 {
		t.Errorf("final reconcile repaired %d (%v)", n, err)
	}
	t.Logf("%d operations, %d lost a lock race and were rolled back", ops, contended)
}
