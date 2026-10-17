package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// A pending case the sweep drops leaves its photo deleted WITH a deleted_at, so the tombstone purge removes it
// (round-4 audit N4); the rows the old function left without one are given one by migration 0047.
func TestDroppedPendingCasePhotoGetsDeletedAtAndIsPurged(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	mustExec(t, s, `INSERT INTO users(user_id) VALUES('00000000-0000-0000-0000-0000000000a1')`)
	mustExec(t, s, `INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,variants,expires_at)
 VALUES('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000a1','post','quarantined','image/jpeg',10,10,'u/b1','{"full":"k"}',now()+interval '1 day')`)
	mustExec(t, s, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,original_sha256,original_bytes,content_type,original_key,status,created_at)
 VALUES('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000a1','post','flagged','test','00',10,'image/jpeg',
  'hold/00000000-0000-0000-0000-0000000000b1/original','pending',now()-interval '2 hours')`)
	if n := mustCount(t, s, `SELECT drop_pending_case('00000000-0000-0000-0000-0000000000c1','test')::int`); n != 1 {
		t.Fatal("the case was not dropped")
	}
	if n := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE media_id='00000000-0000-0000-0000-0000000000b1' AND status='deleted' AND variants IS NULL AND deleted_at IS NOT NULL`); n != 1 {
		t.Fatal("the dropped case's photo has no deleted_at: the tombstone purge would never find it")
	}
	// Not yet old enough: kept. Then 31 days later: gone.
	if n, err := s.PurgeMediaTombstones(ctx, MediaTombstoneRetention); err != nil || n != 0 {
		t.Fatalf("a fresh tombstone: %d %v", n, err)
	}
	mustExec(t, s, `UPDATE media_assets SET deleted_at=now()-interval '31 days' WHERE media_id='00000000-0000-0000-0000-0000000000b1'`)
	if n, err := s.PurgeMediaTombstones(ctx, MediaTombstoneRetention); err != nil || n != 1 {
		t.Fatalf("an old tombstone: %d %v", n, err)
	}

	// The backfill of the migration, on a row the old function left behind.
	mustExec(t, s, `INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,variants,expires_at)
 VALUES('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000a1','post','deleted','image/jpeg',10,10,'u/b2',NULL,now())`)
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "database", "migrations", "0047_data3.sql"))
	if err != nil {
		t.Fatal(err)
	}
	stmt := regexp.MustCompile(`(?m)^UPDATE media_assets SET deleted_at = now\(\) WHERE status = 'deleted' AND deleted_at IS NULL;`).FindString(string(raw))
	if stmt == "" {
		t.Fatal("the backfill statement is not in 0047_data3.sql")
	}
	mustExec(t, s, stmt)
	if n := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE status='deleted' AND deleted_at IS NULL`); n != 0 {
		t.Fatalf("%d deleted photos still have no deleted_at after the backfill", n)
	}
	// The function keeps its owner and its ACL: nobody but the roles grants.sql names may run it.
	if n := mustCount(t, s, `SELECT count(*) FROM pg_proc WHERE proname='drop_pending_case' AND prosecdef AND NOT has_function_privilege('public','drop_pending_case(uuid,text)','EXECUTE')`); n != 1 {
		t.Fatal("drop_pending_case lost its SECURITY DEFINER or became executable by PUBLIC")
	}
}

// Revoked identity-provider session rows older than 400 days are deleted only when the identity's "sign out
// everywhere" watermark covers them, and a deleted tombstone does not let its sign-in come back (round-4 audit N10).
func TestRevokedSessionTombstonesGoOnlyWhenTheWatermarkCoversThem(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	const issuer = firebaseIssuerPrefix + "hiyall-test"
	const user, subject = "00000000-0000-0000-0000-0000000000d1", "uid-d1"
	mustExec(t, s, `INSERT INTO users(user_id) VALUES($1)`, user)
	// Watermark: 200 days ago. A sign-in at auth_time 300 days ago is covered; one 100 days ago is not.
	mustExec(t, s, `INSERT INTO auth_identities(issuer,subject,user_id,sessions_revoked_before) VALUES($1,$2,$3,now()-interval '200 days')`, issuer, subject, user)
	const other = "00000000-0000-0000-0000-0000000000d2"
	mustExec(t, s, `INSERT INTO users(user_id) VALUES($1)`, other)
	mustExec(t, s, `INSERT INTO auth_identities(issuer,subject,user_id) VALUES($1,'uid-d2',$2)`, issuer, other) // never signed out everywhere
	now := time.Now()
	authAt := func(daysAgo int) string { return "fb:" + subject + ":" + itoa(now.AddDate(0, 0, -daysAgo).Unix()) }
	session := func(id, usr, iss, sid, revokedAgo string) {
		mustExec(t, s, `INSERT INTO sessions(session_id,user_id,issuer,external_sid,expires_at,revoked_at) VALUES($1,$2,$3,$4,now()-interval '500 days',now()-$5::interval)`, id, usr, iss, sid, revokedAgo)
	}
	const (
		covered, uncovered, young, noWatermark, foreign, devSession = "00000000-0000-0000-0000-0000000e0001", "00000000-0000-0000-0000-0000000e0002",
			"00000000-0000-0000-0000-0000000e0003", "00000000-0000-0000-0000-0000000e0004", "00000000-0000-0000-0000-0000000e0005", "00000000-0000-0000-0000-0000000e0006"
	)
	session(covered, user, issuer, authAt(300), "450 days")                                                                                                              // gone
	session(uncovered, user, issuer, authAt(100), "450 days")                                                                                                            // a sign-in after the watermark: signed out one device only; stays
	session(young, user, issuer, authAt(301), "399 days")                                                                                                                // not 400 days yet: stays
	session(noWatermark, other, issuer, "fb:uid-d2:"+itoa(now.Unix()), "450 days")                                                                                       // no watermark: stays
	session(foreign, user, "https://accounts.example.com", "sid-1", "450 days")                                                                                          // another provider: stays
	mustExec(t, s, `INSERT INTO sessions(session_id,user_id,expires_at,revoked_at) VALUES($1,$2,now()-interval '500 days',now()-interval '450 days')`, devSession, user) // not an IdP session: PurgeSessions' business

	n, err := s.PurgeRevokedSessionTombstones(ctx, RevokedSessionTombstoneRetention)
	if err != nil || n != 1 {
		t.Fatalf("deleted %d (%v), want exactly the covered one", n, err)
	}
	for id, want := range map[string]int{covered: 0, uncovered: 1, young: 1, noWatermark: 1, foreign: 1, devSession: 1} {
		if got := mustCount(t, s, `SELECT count(*) FROM sessions WHERE session_id=$1`, id); got != want {
			t.Errorf("session %s: %d rows, want %d", id, got, want)
		}
	}
	// The deleted tombstone's sign-in is still refused: the watermark does what the row did. A sign-in after the
	// watermark (not covered) is refused by its row.
	expiry := time.Now().Add(time.Hour)
	if _, err = s.ResolveOIDC(ctx, issuer, subject, authAt(300), expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("the purged tombstone's sign-in must stay refused: %v", err)
	}
	if _, err = s.ResolveOIDC(ctx, issuer, subject, authAt(100), expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("the kept tombstone's sign-in must stay refused: %v", err)
	}
	if mustCount(t, s, `SELECT count(*) FROM sessions WHERE session_id=$1`, covered) != 0 {
		t.Fatal("a refused sign-in recreated the session")
	}

	// The cursor: the next run looks at nothing it has passed. After the watermark advances and a day passes, the
	// walk starts over and removes the one that was not covered before.
	mustExec(t, s, `UPDATE auth_identities SET sessions_revoked_before=now() WHERE subject=$1`, subject)
	if n, err = s.PurgeRevokedSessionTombstones(ctx, RevokedSessionTombstoneRetention); err != nil || n != 0 {
		t.Fatalf("a second run before the next pass: %d %v", n, err)
	}
	mustExec(t, s, `UPDATE reconcile_state SET finished_at=now()-interval '2 days' WHERE job=$1`, sessionTombstoneJob)
	if n, err = s.PurgeRevokedSessionTombstones(ctx, RevokedSessionTombstoneRetention); err != nil || n != 1 {
		t.Fatalf("the new pass: %d %v, want the session the watermark now covers", n, err)
	}
	if mustCount(t, s, `SELECT count(*) FROM sessions WHERE session_id=$1`, uncovered) != 0 {
		t.Fatal("the session the advanced watermark covers was not removed")
	}
	if _, err = s.ResolveOIDC(ctx, issuer, subject, authAt(100), expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("its sign-in must stay refused: %v", err)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
