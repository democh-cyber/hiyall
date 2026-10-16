package store

import (
	"context"
	"testing"

	"hiyall/services/api/internal/domain"
)

// PurgeMessageMetadata walks the old messages once per run from a cursor (round-3 audit N11) and still keeps
// exactly what the rules keep: each member's latest real message, reported messages (as target or in evidence), a
// message with an envelope nobody received, a message with an attachment; everything else old goes, across chunk
// boundaries (the run is windows of 1000 rows examined, so the data is bigger than that on both sides of the
// kept rows).
func TestPurgeMessageMetadataKeepsTheRightRowsAcrossChunks(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	mustExec(t, s, `CREATE TABLE t_people AS SELECT user_id, gen_random_uuid() AS device_id, row_number() OVER (ORDER BY user_id) AS n FROM
  (SELECT gen_random_uuid() AS user_id FROM generate_series(1,1200)) x`)
	mustExec(t, s, `INSERT INTO users(user_id) SELECT user_id FROM t_people`)
	mustExec(t, s, `INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform) SELECT device_id,user_id,'ik'||n,'sk'||n,'sig','android' FROM t_people`)
	// Conversation 1: persons 1 and 2. Conversation 2: persons 1 and 3 (kept messages of several kinds).
	// Conversation 3: persons 1 and 4, 2600 messages of person 1. Conversations 4..: persons 5.. with 1100 pairs, one message each.
	mustExec(t, s, `CREATE TABLE t_conv AS SELECT gen_random_uuid() AS conversation_id, a.user_id AS lo, b.user_id AS hi, a.n AS an, b.n AS bn
  FROM t_people a JOIN t_people b ON (b.n=a.n+1 AND a.n=1) OR (a.n=1 AND b.n IN (3,4)) OR (a.n>=5 AND a.n<=1104 AND b.n=a.n+1)`)
	mustExec(t, s, `INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status)
  SELECT conversation_id,least(lo,hi),greatest(lo,hi),lo,'active' FROM t_conv`)
	old := `now()-interval '200 days'`
	msg := func(conv string, sender int, at string, aux bool) string {
		var id string
		if err := s.Pool.QueryRow(ctx, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at,aux)
 SELECT gen_random_uuid(),c.conversation_id,p.user_id,p.device_id,`+at+`,$2 FROM t_conv c, t_people p WHERE p.n=$1 AND `+conv+` RETURNING message_id::text`, sender, aux).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	c1, c2, c3 := `c.an=1 AND c.bn=2`, `c.an=1 AND c.bn=3`, `c.an=1 AND c.bn=4`
	a1 := msg(c1, 1, old+`-interval '3 minutes'`, false)
	a2 := msg(c1, 1, old+`-interval '2 minutes'`, false)
	a3 := msg(c1, 1, old+`-interval '1 minute'`, false) // person 1's latest in conversation 1: kept
	b1 := msg(c1, 2, old, false)                        // person 2's latest: kept
	aux := msg(c1, 1, old+`-interval '30 seconds'`, true)
	fresh := msg(c3, 1, `now()`, false) // newer than the 2600 below: they all go
	targeted := msg(c2, 1, old+`-interval '9 minutes'`, false)
	inEvidence := msg(c2, 1, old+`-interval '8 minutes'`, false)
	undelivered := msg(c2, 1, old+`-interval '7 minutes'`, false)
	withBlob := msg(c2, 1, old+`-interval '6 minutes'`, false)
	plain := msg(c2, 1, old+`-interval '5 minutes'`, false)
	last2 := msg(c2, 1, old, false)
	mustExec(t, s, `INSERT INTO message_envelopes(message_id,recipient_device_id,envelope_type,ciphertext) SELECT $1::uuid,device_id,0,'x' FROM t_people WHERE n=3`, undelivered)
	mustExec(t, s, `INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,message_id,role,size_bytes,ct_sha256,state,object_key,uploaded_at,expires_at)
 SELECT gen_random_uuid(),p.user_id,c.conversation_id,$1::uuid,'full',100,decode(repeat('ab',32),'hex'),'uploaded','k',now(),now()+interval '1 day' FROM t_people p,t_conv c WHERE p.n=1 AND `+c2, withBlob)
	mustExec(t, s, `INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status)
 SELECT gen_random_uuid(),p.user_id,'message',$1::uuid,q.user_id,'spam','normal','open' FROM t_people p,t_people q WHERE p.n=3 AND q.n=1`, targeted)
	mustExec(t, s, `INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status,disclosure_consent,evidence)
 SELECT gen_random_uuid(),p.user_id,'user',q.user_id,q.user_id,'spam','normal','open',true,jsonb_build_array(jsonb_build_object('messageId',$1::text)) FROM t_people p,t_people q WHERE p.n=3 AND q.n=1`, inEvidence)
	// Bulk: 2600 of person 1's messages in conversation 3 (all go: a newer one exists), and 1100 conversations with one old message each (all stay).
	mustExec(t, s, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at)
 SELECT gen_random_uuid(),c.conversation_id,p.user_id,p.device_id,now()-interval '300 days'+g*interval '1 second' FROM t_conv c,t_people p,generate_series(1,2600) g WHERE c.an=1 AND c.bn=4 AND p.n=1`)
	mustExec(t, s, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at)
 SELECT gen_random_uuid(),c.conversation_id,p.user_id,p.device_id,now()-interval '400 days' FROM t_conv c,t_people p WHERE c.an>=5 AND p.n=c.an`)

	before := mustCount(t, s, `SELECT count(*) FROM messages`)
	deleted, err := s.PurgeMessageMetadata(ctx, MessageMetadataRetention)
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 2+1+1+2600 { // a1,a2 ; aux ; plain ; bulk
		t.Errorf("deleted %d, want %d", deleted, 2+1+1+2600)
	}
	if after := mustCount(t, s, `SELECT count(*) FROM messages`); int64(before-after) != deleted {
		t.Errorf("rows %d -> %d but the job said %d", before, after, deleted)
	}
	for name, id := range map[string]string{"a3 (latest)": a3, "b1 (latest)": b1, "fresh": fresh, "targeted": targeted, "in evidence": inEvidence, "undelivered": undelivered, "with attachment": withBlob, "last of conversation 2": last2} {
		if mustCount(t, s, `SELECT count(*) FROM messages WHERE message_id=$1`, id) != 1 {
			t.Errorf("%s was deleted", name)
		}
	}
	for name, id := range map[string]string{"a1": a1, "a2": a2, "aux": aux, "plain": plain} {
		if mustCount(t, s, `SELECT count(*) FROM messages WHERE message_id=$1`, id) != 0 {
			t.Errorf("%s was kept", name)
		}
	}
	if n := mustCount(t, s, `SELECT count(*) FROM messages m JOIN t_conv c USING(conversation_id) WHERE c.an>=5`); n != 1100 {
		t.Errorf("%d of the 1100 single-message conversations are left", n)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM messages m JOIN t_conv c USING(conversation_id) WHERE c.an=1 AND c.bn=4`); n != 1 {
		t.Errorf("%d of conversation 3's messages are left, want the fresh one only", n)
	}
	// Idempotent.
	if n, err := s.PurgeMessageMetadata(ctx, MessageMetadataRetention); err != nil || n != 0 {
		t.Errorf("second run deleted %d (%v)", n, err)
	}
}

// A page of people search that ends because the candidate cap was reached, with fewer results than a page, says
// where to continue; the list does not end early (round-3 audit D8 residual). 5000 discoverable members who
// cannot be listed (onboarding unfinished) come first, then three who can.
func TestSearchPeoplePageContinuesPastTheCandidateCap(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	mustExec(t, s, `INSERT INTO users(user_id) SELECT ('00000000-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid FROM generate_series(1,5001) g`)
	mustExec(t, s, `INSERT INTO users(user_id) SELECT ('ffffffff-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid FROM generate_series(1,3) g`)
	mustExec(t, s, `INSERT INTO privacy_settings(user_id,data) SELECT user_id,'{"discoverable":true,"profileAudience":"public"}' FROM users`)
	mustExec(t, s, `INSERT INTO profiles(user_id,username,data) SELECT user_id,'u'||substr(user_id::text,25),jsonb_build_object('displayName','n') FROM users WHERE user_id::text LIKE 'ffffffff%'`)
	mustExec(t, s, `INSERT INTO onboarding(user_id,completed_at) SELECT user_id,now() FROM users WHERE user_id::text LIKE 'ffffffff%'`)
	const viewer = "00000000-0000-0000-0000-000000000001"
	items, resume, err := s.SearchPeoplePage(ctx, viewer, domain.PeopleFilters{}, "00000000-0000-0000-0000-000000000000", 21, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 || resume != "00000000-0000-0000-0000-000000005001" {
		// The viewer is skipped, so the 5000 candidates examined are members 2 to 5001.
		t.Fatalf("first page: %d items, resume %q", len(items), resume)
	}
	items, resume, err = s.SearchPeoplePage(ctx, viewer, domain.PeopleFilters{}, "00000000-0000-0000-0000-000000005001", 21, nil, nil)
	if err != nil || len(items) != 3 || resume != "" {
		t.Fatalf("second page: %d items, resume %q, %v", len(items), resume, err)
	}
}
