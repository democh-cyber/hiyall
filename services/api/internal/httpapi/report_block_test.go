package httpapi

import "testing"

// Report and block is one transaction (audit F24): both are stored, or neither.
func TestReportAndBlockCommitTogether(t *testing.T) {
	h := newSocialHarness(t)
	got := h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "spam", "block": true}), 201, "")
	if got.data["blocked"] != true || got.data["duplicate"] != false {
		t.Fatalf("%v", got.data)
	}
	if n := h.count(`SELECT count(*) FROM blocks WHERE blocker_id=$1 AND blocked_id=$2`, alice, bob); n != 1 {
		t.Fatalf("%d blocks", n)
	}
	// The same report again (a duplicate) still blocks, and says so.
	h.expect(h.call(alice, "DELETE", "/v1/users/"+bob+"/block"), 200, "")
	got = h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "spam", "block": true}), 200, "")
	if got.data["blocked"] != true || got.data["duplicate"] != true {
		t.Fatalf("%v", got.data)
	}
	// Without the flag nothing is blocked.
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": cara, "reasonCode": "spam"}), 201, "")
	if n := h.count(`SELECT count(*) FROM blocks WHERE blocker_id=$1 AND blocked_id=$2`, alice, cara); n != 0 {
		t.Fatal("blocked without asking")
	}
}

// If the block cannot be written, the report is not either.
func TestFailedBlockRollsTheReportBack(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`CREATE FUNCTION refuse_block() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'block refused'; END $$`)
	h.exec(`CREATE TRIGGER refuse_block BEFORE INSERT ON blocks FOR EACH ROW EXECUTE FUNCTION refuse_block()`)
	t.Cleanup(func() {
		h.exec(`DROP TRIGGER refuse_block ON blocks`)
		h.exec(`DROP FUNCTION refuse_block()`)
	})
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "spam", "block": true}), 500, "INTERNAL")
	if n := h.count(`SELECT count(*) FROM reports WHERE reporter_id=$1`, alice); n != 0 {
		t.Fatalf("%d reports kept after the block failed", n)
	}
}

// A subject who cannot be blocked any more does not undo the report.
func TestReportStandsWhenTheSubjectCannotBeBlocked(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, bob)
	got := h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "spam", "block": true})
	if got.status == 500 {
		t.Fatalf("%+v", got)
	}
	if got.status == 201 && got.data["blocked"] != false {
		t.Fatalf("%v", got.data)
	}
}
