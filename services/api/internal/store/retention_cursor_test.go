package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"hiyall/services/api/internal/dbtest"
)

// seedKeptPairs makes pairs conversations of two members, each with one old message per member. Every one of those
// messages is its sender's latest in the conversation, so PurgeMessageMetadata keeps all of them (2*pairs rows).
// tsA and tsB are SQL expressions for the two messages' times (p is the pair's number, 1..pairs). The people stay in
// the temp tables k_people and k_conv for the test to add more.
func seedKeptPairs(t *testing.T, s *Store, pairs int, tsA, tsB string) {
	t.Helper()
	mustExec(t, s, `CREATE TABLE k_people AS SELECT gen_random_uuid() AS u, gen_random_uuid() AS d, g FROM generate_series(1,$1::int) g`, pairs*2)
	mustExec(t, s, `INSERT INTO users(user_id) SELECT u FROM k_people`)
	mustExec(t, s, `INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform) SELECT d,u,'ik'||g,'sk'||g,'sig','android' FROM k_people`)
	mustExec(t, s, `CREATE TABLE k_conv AS SELECT gen_random_uuid() AS cid, a.u AS ua, a.d AS da, b.u AS ub, b.d AS db, ((a.g+1)/2)::int AS p
  FROM k_people a JOIN k_people b ON b.g=a.g+1 WHERE a.g%2=1`)
	mustExec(t, s, `INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) SELECT cid,least(ua,ub),greatest(ua,ub),ua,'active' FROM k_conv`)
	mustExec(t, s, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at) SELECT gen_random_uuid(),cid,ua,da,`+tsA+` FROM k_conv`)
	mustExec(t, s, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at) SELECT gen_random_uuid(),cid,ub,db,`+tsB+` FROM k_conv`)
}

func oldMessages(t *testing.T, s *Store) int {
	return mustCount(t, s, `SELECT count(*) FROM messages WHERE created_at<now()-$1::interval`, MessageMetadataRetention)
}

// The cursor of PurgeMessageMetadata survives the run (round-4 audit N5): rows that stay are not examined again on
// every run, a run cut short by a crash is continued from where it stopped, and a new pass over the oldest rows
// starts MessageMetadataRewalk after the last one finished, so a row that was kept and stopped being needed goes.
func TestPurgeMessageMetadataResumesPastKeptRows(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	// 1100 conversations, 2200 kept messages (older first), then 5 more old messages of one member (the 4 older of them and the one she had before go).
	seedKeptPairs(t, s, 1100, `now()-interval '300 days'+p*interval '1 second'`, `now()-interval '300 days'+p*interval '1 second'+interval '500 ms'`)
	mustExec(t, s, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at)
 SELECT gen_random_uuid(),cid,ua,da,now()-interval '250 days'+g*interval '1 second' FROM k_conv,generate_series(1,5) g WHERE p=1`)
	total := oldMessages(t, s) // 2205

	deleted, examined, err := s.purgeMessageMetadata(ctx, MessageMetadataRetention)
	if err != nil || deleted != 5 || examined != int64(total) {
		t.Fatalf("first run: deleted %d examined %d (want 5 and %d), %v", deleted, examined, total, err)
	}
	total -= 5
	// Nothing has aged in since: the next run looks at nothing, although 2200 kept rows are old.
	if deleted, examined, err = s.purgeMessageMetadata(ctx, MessageMetadataRetention); err != nil || deleted != 0 || examined != 0 {
		t.Fatalf("second run: deleted %d examined %d, want 0 and 0 (the kept rows are not looked at again), %v", deleted, examined, err)
	}
	// A message that has aged in since is the only one looked at. It also makes the member's previous latest
	// message (kept in the first pass) unnecessary, but that row is behind the cursor and waits for the next pass.
	mustExec(t, s, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at)
 SELECT gen_random_uuid(),cid,ua,da,now()-interval '200 days' FROM k_conv WHERE p=1`)
	total++
	if deleted, examined, err = s.purgeMessageMetadata(ctx, MessageMetadataRetention); err != nil || deleted != 0 || examined != 1 {
		t.Fatalf("third run: deleted %d examined %d, want 0 and 1, %v", deleted, examined, err)
	}
	// MessageMetadataRewalk after the pass ended, a new pass starts from the oldest message and removes it.
	mustExec(t, s, `UPDATE reconcile_state SET finished_at=now()-$2::interval WHERE job=$1`, messagePurgeJob, MessageMetadataRewalk+time.Hour)
	if deleted, examined, err = s.purgeMessageMetadata(ctx, MessageMetadataRetention); err != nil || deleted != 1 || examined != int64(total) {
		t.Fatalf("new pass: deleted %d examined %d, want 1 and %d, %v", deleted, examined, total, err)
	}
	total--
	if n, _ := s.PurgeMessageMetadata(ctx, MessageMetadataRetention); n != 0 {
		t.Fatalf("an idempotent run deleted %d", n)
	}

	// A crash in the middle of a pass: the run ends after its second window, and the next one carries on from there.
	mustExec(t, s, `DELETE FROM reconcile_state WHERE job=$1`, messagePurgeJob)
	cut, stop := context.WithCancel(ctx)
	messagePurgeAfterWindow = func(windows int) {
		if windows == 2 {
			stop()
		}
	}
	_, examined, err = s.purgeMessageMetadata(cut, MessageMetadataRetention)
	messagePurgeAfterWindow = nil
	if !errors.Is(err, context.Canceled) || examined != 2*retentionChunk {
		t.Fatalf("the interrupted run examined %d (%v), want %d and a cancelled context", examined, err, 2*retentionChunk)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM reconcile_state WHERE job=$1 AND cursor IS NOT NULL AND finished_at IS NULL`, messagePurgeJob); n != 1 {
		t.Fatal("the cursor was not saved when the run was cut")
	}
	if _, examined, err = s.purgeMessageMetadata(ctx, MessageMetadataRetention); err != nil || examined != int64(total-2*retentionChunk) {
		t.Fatalf("the resumed run examined %d (%v), want the %d rows after the cursor", examined, err, total-2*retentionChunk)
	}
}

// Under a language collation the text of a timestamp sorts a whole second AFTER its fractions ("05+00" after
// "05.5+00"), the reverse of the timestamps. The last row of a window was picked by that text, so the cursor fell
// behind the last row and the next window examined rows again (round-4 audit N3). On an ICU database every row is
// examined once.
func TestPurgeMessageMetadataCursorIsTypedUnderALanguageCollation(t *testing.T) {
	s := storeOn(t, dbtest.ScratchICU(t))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second) // a cursor that never advances would loop for ever
	defer cancel()
	if n := mustCount(t, s, `SELECT count(*) FROM pg_database WHERE datname=current_database() AND datlocprovider='i'`); n != 1 {
		t.Fatal("the test database does not use the ICU provider")
	}
	if n := mustCount(t, s, `SELECT ('2026-01-05 10:00:05+00'::timestamptz::text > '2026-01-05 10:00:05.5+00'::timestamptz::text)::int`); n != 1 {
		t.Fatal("this collation sorts a whole second before its fractions: the test proves nothing")
	}
	// 1100 whole-second messages, then 1100 half-second ones: the window that holds both ends on a fraction.
	seedKeptPairs(t, s, 1100, `timestamptz '2026-01-05 10:00:05+00'`, `timestamptz '2026-01-05 10:00:05.5+00'`)
	deleted, examined, err := s.purgeMessageMetadata(ctx, MessageMetadataRetention)
	if err != nil || deleted != 0 || examined != 2200 {
		t.Fatalf("deleted %d examined %d, want 0 and 2200 (each row once), %v", deleted, examined, err)
	}
}
