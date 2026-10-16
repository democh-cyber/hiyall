package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

type recordingObjects struct {
	mu     sync.Mutex
	gone   []string
	failOn string
}

func (r *recordingObjects) Delete(_ context.Context, keys ...string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, k := range keys {
		if r.failOn != "" && strings.Contains(k, r.failOn) {
			return errors.New("storage unavailable")
		}
	}
	r.gone = append(r.gone, keys...)
	return nil
}

// PurgeMedia reads its two kinds of work (expired uploads, deleted photos with objects) in keyset order from a
// cursor (round-3 audit N11): every eligible row is finished across several chunks of 50, a row whose object cannot
// be removed stays for the next run without stopping the others, and rows that must not be touched (attached,
// still pending and not yet expired, quarantined, already finished) are left alone.
func TestPurgeMediaWalksTheBacklogInKeysetChunks(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	mustExec(t, s, `INSERT INTO users(user_id) VALUES('00000000-0000-0000-0000-0000000000a1')`)
	exec := func(q string, args ...any) { t.Helper(); mustExec(t, s, q, args...) }
	// 130 expired unattached uploads, 90 deleted photos whose objects remain.
	exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,attached,expires_at,declared_bytes)
 SELECT gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','pending','image/jpeg',10,'up/'||g,false,now()-interval '1 hour'-g*interval '1 minute',10 FROM generate_series(1,130) g`)
	exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,variants,attached,expires_at,deleted_at,declared_bytes)
 SELECT gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','deleted','image/jpeg',10,'del/'||g,jsonb_build_object('full','full/'||g,'thumb','thumb/'||g),true,now()+interval '1 day',now()-g*interval '1 minute',10 FROM generate_series(1,90) g`)
	// Left alone: attached and unexpired, pending but not expired yet, quarantined, a finished tombstone.
	exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,attached,expires_at,declared_bytes) VALUES
 (gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','ready','image/jpeg',10,'keep/attached',true,now()-interval '1 day',10),
 (gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','pending','image/jpeg',10,'keep/pending',false,now()+interval '1 hour',10),
 (gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','quarantined','image/jpeg',10,'keep/quarantined',false,now()-interval '1 day',10)`)
	exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,attached,expires_at,deleted_at,declared_bytes)
 VALUES(gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','deleted','image/jpeg',10,'keep/tomb',false,now(),now(),10)`)

	objects := &recordingObjects{failOn: "up/7"} // up/7 and up/70..79 and up/7x: ten and one rows that fail
	n, err := s.PurgeMedia(ctx, objects, 5000)
	if err == nil {
		t.Fatal("a failed object removal must be reported")
	}
	failing := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE upload_key LIKE 'up/7%'`)
	if want := int64(130 - failing + 90); n != want {
		t.Errorf("finished %d rows, want %d", n, want)
	}
	if left := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE status='pending' AND NOT attached AND expires_at<now()`); left != failing {
		t.Errorf("%d expired uploads are left, want the %d whose object failed", left, failing)
	}
	if left := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE status='deleted' AND variants IS NOT NULL`); left != 0 {
		t.Errorf("%d deleted photos still hold objects", left)
	}
	if mustCount(t, s, `SELECT count(*) FROM media_assets WHERE upload_key LIKE 'keep/%' AND status IN ('ready','pending','quarantined')`) != 3 {
		t.Error("a row that must stay was touched")
	}
	// The next run (storage back) finishes the failed ones, and a batch limit stops a run early (50 per chunk).
	objects.failOn = ""
	n, err = s.PurgeMedia(ctx, objects, 5000)
	if err != nil || n != int64(failing) {
		t.Fatalf("second run finished %d (%v), want %d", n, err, failing)
	}
	exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,upload_key,attached,expires_at,declared_bytes)
 SELECT gen_random_uuid(),'00000000-0000-0000-0000-0000000000a1','post','pending','image/jpeg',10,'more/'||g,false,now()-interval '1 hour',10 FROM generate_series(1,120) g`)
	n, err = s.PurgeMedia(ctx, objects, 60)
	if err != nil || n < 60 || n > 100 {
		t.Fatalf("a run limited to 60 finished %d (%v)", n, err)
	}
	if _, err = s.PurgeMedia(ctx, objects, 5000); err != nil {
		t.Fatal(err)
	}
	if left := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE status='pending' AND NOT attached AND expires_at<now()`); left != 0 {
		t.Errorf("%d expired uploads are left after the last run", left)
	}
}

// A lock timeout, a cancelled statement or a dropped connection while an account's status is read is that class of
// failure (503 through the central mapping), not "no such account" (404): the profile, privacy and onboarding
// writes (round-3 audit N10).
func TestAccountWritesKeepTheErrorClassOfALockTimeout(t *testing.T) {
	s := scratchStore(t, WithTimeouts(Timeouts{Statement: 5 * time.Second, Lock: 300 * time.Millisecond, IdleInTransaction: 10 * time.Second}))
	ctx := context.Background()
	const user = "00000000-0000-0000-0000-0000000000b1"
	mustExec(t, s, `INSERT INTO users(user_id) VALUES($1)`, user)
	holder, err := s.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Rollback(ctx)
	if _, err = holder.Exec(ctx, `SELECT 1 FROM users WHERE user_id=$1 FOR UPDATE`, user); err != nil {
		t.Fatal(err)
	}
	check := func(name string, err error) {
		t.Helper()
		if err == nil || errors.Is(err, domain.ErrNotFound) {
			t.Errorf("%s: a lock timeout was answered as %v", name, err)
		} else if ContentionCode(err) != "55P03" {
			t.Errorf("%s: %v is not a lock timeout", name, err)
		}
	}
	check("UpdateProfile", s.updateProfile(ctx, user, 1, map[string]json.RawMessage{"bio": []byte(`"hello"`)}))
	_, err = s.UpdatePrivacy(ctx, user, 1, map[string]json.RawMessage{"readReceipts": []byte(`true`)})
	check("UpdatePrivacy", err)
	_, err = s.CompleteOnboarding(ctx, user, time.Now().AddDate(-20, 0, 0))
	check("CompleteOnboarding", err)
	// An account that is not there, or not active, is still a 404.
	holder.Rollback(ctx)
	if err := s.updateProfile(ctx, "00000000-0000-0000-0000-0000000000b2", 1, map[string]json.RawMessage{"bio": []byte(`"x"`)}); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("unknown account: %v", err)
	}
	mustExec(t, s, `UPDATE users SET status='suspended' WHERE user_id=$1`, user)
	if _, err := s.UpdatePrivacy(ctx, user, 1, map[string]json.RawMessage{"readReceipts": []byte(`true`)}); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("suspended account: %v", err)
	}
}
