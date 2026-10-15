package httpapi

import (
	"testing"
)

// A message that a report names, as its target or in its evidence, keeps its metadata row through the account
// purge, as it does through the retention job (PurgeMessageMetadata); the rest of the conversation goes.
func TestAccountPurgeKeepsMessagesThatReportsName(t *testing.T) {
	w := newPurgeWorld(t)
	h := w.acctHarness
	var xanMsg, eliMsg string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT message_id::text FROM messages WHERE conversation_id=$1 AND sender_id=$2 LIMIT 1),(SELECT message_id::text FROM messages WHERE conversation_id=$1 AND sender_id=$3 LIMIT 1)`, w.convoEli, xan, eli).Scan(&xanMsg, &eliMsg); err != nil {
		t.Fatal(err)
	}
	// eli reports xan with xan's message as evidence; cara reports eli's message in the same conversation as the target.
	h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status,evidence,disclosure_consent)
 VALUES(gen_random_uuid(),$1,'user',$2,$2,'spam','normal','open',$3::jsonb,true)`, eli, xan, `[{"messageId":"`+xanMsg+`","text":"x","sentAt":"2026-10-12T10:00:00Z"}]`)
	h.exec(`INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,severity,status) VALUES(gen_random_uuid(),$1,'message',$2,$3,'spam','normal','open')`, cara, eliMsg, eli)
	// Extra messages nobody reported, made directly so they have no attachment holding them.
	var plain string
	if err := h.db.Pool.QueryRow(h.ctx, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,created_at)
 SELECT gen_random_uuid(),conversation_id,sender_id,sender_device_id,created_at FROM messages WHERE message_id=$1 RETURNING message_id::text`, xanMsg).Scan(&plain); err != nil {
		t.Fatal(err)
	}

	h.scheduled(xan, "xan")
	h.expire(xan)
	w.purgeUntilDone(&fakeDeleter{})

	kept := func(id string) bool { return h.count(`SELECT count(*) FROM messages WHERE message_id=$1`, id) == 1 }
	if !kept(xanMsg) {
		t.Error("the message named in a report's evidence was deleted by the purge")
	}
	if !kept(eliMsg) {
		t.Error("the message a report targets was deleted by the purge")
	}
	if kept(plain) {
		t.Error("an unreported message of the deleted member was kept")
	}
}
