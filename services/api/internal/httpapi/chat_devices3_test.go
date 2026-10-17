package httpapi

import (
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"hiyall/services/api/internal/store"
)

// Round 4 chat findings: CHAT-N1 (an ordinary absence loses nothing and ends in a calm return with the same keys,
// PEER_NO_DEVICES), CHAT-N2 (a ghost device filled by one sender is removed in the send), CHAT-N3 (the retry of a
// send forgets the devices its first run revoked), CHAT-N4 (the backlog sweep counts what a send counts).

func (h *socialHarness) envelopesOf(d testDevice) int {
	h.t.Helper()
	return h.countOf(`SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL`, d.id)
}

func (h *socialHarness) reasonOf(d testDevice) string {
	h.t.Helper()
	var reason *string
	if err := h.api.Store.Pool.QueryRow(h.ctx, `SELECT revoked_reason FROM devices WHERE device_id=$1`, d.id).Scan(&reason); err != nil {
		h.t.Fatal(err)
	}
	if reason == nil {
		return ""
	}
	return *reason
}

func TestAnAbsenceOfTwentyDaysKeepsTheDeviceTheCiphertextAndThePushToken(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.token(tablet, "alice-tablet-token")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	h.idleFor(tablet, "20 days")
	h.idleFor(phone, "20 days")
	if n, err := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100); err != nil || n != 0 {
		t.Fatalf("revoked %d, err %v", n, err)
	}
	if h.activeDevices(alice) != 2 || h.envelopesOf(tablet) != 1 || h.countOf(`SELECT count(*) FROM devices WHERE device_id=$1 AND push_token IS NOT NULL`, tablet.id) != 1 {
		t.Fatal("a 20-day absence cost a device, a message or a push token")
	}
	// The person comes back: nothing to register, the inbox answers.
	if got := h.inboxOf(tablet); len(got) != 1 {
		t.Fatalf("inbox %v", got)
	}
}

func TestAnIdleDeviceIsRemovedAfterThirtyFiveDaysAndReturnsWithTheSameKeys(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.token(phone, "alice-phone-token")
	h.token(tablet, "alice-tablet-token")
	h.expect(h.send(alice, "POST", "/v1/devices/"+tablet.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{tablet.oneTimeKey("k1")}, "fallbackKey": tablet.oneTimeKey("fb")}), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	h.ackAll(phone)

	h.idleFor(tablet, "34 days")
	if n, _ := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100); n != 0 {
		t.Fatalf("revoked at 34 days: %d", n)
	}
	h.idleFor(tablet, "36 days")
	if n, err := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100); err != nil || n != 1 {
		t.Fatalf("revoked at 36 days: %d, err %v", n, err)
	}
	// Recorded as idle for the owner's other devices; the push token and the keys are gone; what had not
	// expired is kept, so a return still gets it.
	if !h.revoked(tablet) || h.reasonOf(tablet) != "idle" {
		t.Fatalf("revoked %v reason %q", h.revoked(tablet), h.reasonOf(tablet))
	}
	removed := removedOf(h, alice)
	if len(removed) != 1 || removed[0]["deviceId"] != tablet.id || removed[0]["reason"] != "idle" {
		t.Fatalf("removed %v", removed)
	}
	if h.countOf(`SELECT count(*) FROM devices WHERE device_id=$1 AND push_token IS NOT NULL`, tablet.id) != 0 ||
		h.countOf(`SELECT (SELECT count(*) FROM one_time_keys WHERE device_id=$1)+(SELECT count(*) FROM fallback_keys WHERE device_id=$1)`, tablet.id) != 0 {
		t.Fatal("the idle device kept its push token or keys")
	}
	if h.envelopesOf(tablet) != 1 {
		t.Fatal("the idle removal dropped ciphertext that had not expired")
	}
	// Peers meanwhile see only the devices that remain, and can still write.
	if got := items(h.ok(bob, "GET", "/v1/users/"+alice+"/devices")); len(got) != 1 {
		t.Fatalf("peer sees %d devices", len(got))
	}
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	h.expect(h.call(alice, "GET", "/v1/devices/"+tablet.id+"/inbox"), 404, "NOT_FOUND")

	// The tablet returns: same device id, same keys. It is the same device again, not a new one.
	before := len(log.messages())
	reg := h.expect(h.send(alice, "POST", "/v1/devices", tablet.registration()), 200, "").data
	if reg["deviceId"] != tablet.id || reg["identityKey"] != tablet.identity || reg["signingKey"] != tablet.signingKey {
		t.Fatalf("registered %v", reg)
	}
	if h.revoked(tablet) || h.reasonOf(tablet) != "" || h.activeDevices(alice) != 2 {
		t.Fatal("the returning device is not active again")
	}
	if got := removedOf(h, alice); len(got) != 0 {
		t.Fatalf("a device that returned is still listed as removed: %v", got)
	}
	if got := h.inboxOf(tablet); len(got) != 1 {
		t.Fatalf("the kept ciphertext did not arrive: %v", got)
	}
	// Peers see the same device with the same keys: nothing for them to pin or announce.
	for _, d := range items(h.ok(bob, "GET", "/v1/users/"+alice+"/devices")) {
		if d["deviceId"] == tablet.id && (d["identityKey"] != tablet.identity || d["signingKey"] != tablet.signingKey) {
			t.Fatalf("keys changed: %v", d)
		}
	}
	if len(items(h.ok(bob, "GET", "/v1/users/"+alice+"/devices"))) != 2 {
		t.Fatal("the peer does not see the returned device")
	}
	// No one is pushed about a device being added.
	log.quiet(t, before, "an idle return is not a new device")
	for _, m := range log.messages()[before:] {
		if m.Kind == "device" {
			t.Fatalf("pushed %+v", m)
		}
	}
	// Registering again is idempotent, and the traffic reaches the tablet.
	h.expect(h.send(alice, "POST", "/v1/devices", tablet.registration()), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
}

func TestOnlyAnIdleRemovalCanBeUndoneByTheDeviceItself(t *testing.T) {
	h := newSocialHarness(t)
	// A removal by the owner (or a sign-out) is final.
	gone := h.register(alice)
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+gone.id), 200, "")
	h.expect(h.send(alice, "POST", "/v1/devices", gone.registration()), 409, "DEVICE_CONFLICT")
	// So is the removal of a dormant device over the cap ("inactive"), which dropped its ciphertext.
	dormant := h.register(alice)
	h.exec(`UPDATE devices SET revoked_at=now(),revoked_by_other=true,revoked_reason='inactive' WHERE device_id=$1`, dormant.id)
	h.expect(h.send(alice, "POST", "/v1/devices", dormant.registration()), 409, "DEVICE_CONFLICT")
	// An idle device cannot come back as another account's, or with other keys, or under another id.
	idle := h.register(alice)
	h.idleFor(idle, "40 days")
	if n, err := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100); err != nil || n != 1 {
		t.Fatalf("revoked %d %v", n, err)
	}
	other := idle
	other.identity = randomKey()
	other.user = alice
	h.expect(h.send(alice, "POST", "/v1/devices", other.registration()), 409, "DEVICE_CONFLICT")
	moved := idle
	moved.id = newTestDevice(alice).id
	h.expect(h.send(alice, "POST", "/v1/devices", moved.registration()), 409, "DEVICE_CONFLICT")
	// A full account has no room for it, and it has to wait, with its identity intact.
	for i := 0; i < 10; i++ {
		h.register(alice)
	}
	h.expect(h.send(alice, "POST", "/v1/devices", idle.registration()), 409, "TOO_MANY_DEVICES")
	if h.reasonOf(idle) != "idle" {
		t.Fatalf("the refused return changed the record: %q", h.reasonOf(idle))
	}
}

func TestAPeerWithNoActiveDeviceIsAnsweredPeerNoDevices(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	h.ackAll(bobPhone)
	h.idleFor(phone, "40 days")
	if n, err := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100); err != nil || n != 1 {
		t.Fatalf("revoked %d %v", n, err)
	}
	// Bob has nobody to encrypt for: the answer says so, and nothing is stored. (A sender with no other device
	// has no envelope to send either, and the app says the same without asking the relay.)
	bobTablet := h.register(bob)
	m := message(bobPhone, bobTablet)
	h.expect(h.send(bob, "POST", path+"/messages", m), 409, "PEER_NO_DEVICES")
	if h.countOf(`SELECT count(*) FROM messages WHERE message_id=$1`, m["messageId"]) != 0 {
		t.Fatal("a refused message was stored")
	}
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, bobTablet, phone)), 409, "PEER_NO_DEVICES")
	_, _, body := h.full(bob, "POST", path+"/messages", "application/json", mustJSON(message(bobPhone, bobTablet)))
	if want := "They haven't opened Hiyall in a while. Your message can't be delivered yet."; !strings.Contains(string(body), want) {
		t.Fatalf("body %s", body)
	}
	// She comes back, and the same request goes through.
	h.expect(h.send(alice, "POST", "/v1/devices", phone.registration()), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, bobTablet)), 200, "")
}

// ---------------------------------------------------------------- CHAT-N2

// aliceWithAGhost sets up a chatty pair, Alice with a phone in use and a tablet nobody opens any more, and Bob
// with one phone; the per-sender share is three. Alice wrote first, so Bob's first-contact budget is not the
// limit. The tablet holds Bob's first three messages.
func aliceWithAGhost(h *socialHarness) (path string, phone, tablet, bobPhone testDevice) {
	h.t.Helper()
	h.capLimits(2000, 3)
	path, phone, bobPhone = friendsWithChat(h)
	tablet = h.register(alice)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	h.ackAll(bobPhone)
	for i := 0; i < 3; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
		h.ackAll(phone)
	}
	return path, phone, tablet, bobPhone
}

func TestAGhostDeviceFilledByOneSenderIsRemovedInTheSendAndTheChatCarriesOn(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, tablet, bobPhone := aliceWithAGhost(h)
	h.token(phone, "alice-phone-token")
	h.token(tablet, "alice-tablet-token")
	log.messages()

	// In use two days ago less an hour: a slow device. It is refused, with the words for that, and left alone.
	h.idleFor(tablet, "47 hours")
	status, _, body := h.full(bob, "POST", path+"/messages", "application/json", mustJSON(message(bobPhone, phone, tablet)))
	if status != 429 || !strings.Contains(string(body), `"RECIPIENT_BACKLOG"`) || !strings.Contains(string(body), "They haven't caught up on earlier messages yet. Try again later.") {
		t.Fatalf("slow device: %d %s", status, body)
	}
	if h.revoked(tablet) {
		t.Fatal("a device that polled 47 hours ago was removed")
	}
	// Past 48 hours it is a ghost: the send removes it, the sender is told the devices changed, and the retry
	// for the devices that remain goes through. Bob never sees the "haven't picked up" text.
	h.idleFor(tablet, "49 hours")
	before := len(log.messages())
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 409, "DEVICES_CHANGED")
	if !h.revoked(tablet) || h.reasonOf(tablet) != "idle" {
		t.Fatalf("revoked %v reason %q", h.revoked(tablet), h.reasonOf(tablet))
	}
	// Idle, so the ciphertext stays until it expires, and the owner's other devices see it listed; no one is pushed
	// (it is housekeeping, not a security event).
	if h.envelopesOf(tablet) != 4 {
		t.Fatalf("the ghost kept %d envelopes", h.envelopesOf(tablet))
	}
	removed := removedOf(h, alice)
	if len(removed) != 1 || removed[0]["deviceId"] != tablet.id || removed[0]["reason"] != "idle" {
		t.Fatalf("removed %v", removed)
	}
	log.quiet(t, before, "an idle removal is not pushed")
	for i := 0; i < 20; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
		h.ackAll(phone)
	}
	// The tablet's owner picks it up again some day: it is the same device, and what Bob sent is still there.
	h.expect(h.send(alice, "POST", "/v1/devices", tablet.registration()), 200, "")
	if got := h.inboxOf(tablet); len(got) != 4 {
		t.Fatalf("the ghost's inbox has %d messages", len(got))
	}
	// And it is full for Bob again until it reads them.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 429, "RECIPIENT_BACKLOG")
}

func TestAGhostRemovedFromAPeerThatKeepsAPhoneLeavesTheTrafficRunning(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, tablet, bobPhone := aliceWithAGhost(h)
	// The phone is idle too (and holds nothing).
	h.idleFor(phone, "3 days")
	h.idleFor(tablet, "3 days")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 409, "DEVICES_CHANGED")
	if !h.revoked(tablet) || h.revoked(phone) {
		t.Fatalf("tablet revoked %v, phone revoked %v", h.revoked(tablet), h.revoked(phone))
	}
	// Alice still has her phone: Bob's retry is for it alone.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	// Had she nothing left, the answer would say so.
	h.exec(`UPDATE devices SET revoked_at=now(),revoked_by_other=true,revoked_reason='idle' WHERE device_id=$1`, phone.id)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 409, "PEER_NO_DEVICES")
}

func TestTheSendersOwnFullDeviceIsNotAGhostForTheShare(t *testing.T) {
	// The per-sender share is not applied to the sender's own devices, so a sender's own idle device is only ever
	// removed by the over-the-cap rule, never by the share.
	h := newSocialHarness(t)
	h.capLimits(2000, 1)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	for i := 0; i < 4; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
		h.ackAll(bobPhone)
	}
	h.idleFor(tablet, "10 days")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	if h.revoked(tablet) {
		t.Fatal("the sender's own device was removed by the share")
	}
}

// ---------------------------------------------------------------- CHAT-N3

// A send whose first run is rolled back (a deadlock) and whose second run stores the message must not answer
// DEVICES_CHANGED, nor signal a removal, because of a device the first run revoked.
func TestARetriedSendForgetsTheDevicesItsFirstRunRevoked(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(3, 0)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	for i := 0; i < 2; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	}
	h.ackAll(phone)
	h.ackAll(bobPhone)
	h.idleFor(tablet, "9 days")
	attempts := 0
	store.SendTxHook = func(stage string) error {
		switch stage {
		case "begin":
			attempts++
			if attempts == 2 {
				// Between the runs the tablet is opened and reads its mail: no longer dormant, no longer full.
				h.exec(`UPDATE devices SET last_seen_at=now() WHERE device_id=$1`, tablet.id)
				h.ackAll(tablet)
			}
		case "revoked":
			if attempts == 1 {
				return &pgconn.PgError{Code: "40P01"}
			}
		}
		return nil
	}
	t.Cleanup(func() { store.SendTxHook = nil })
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	if attempts != 2 {
		t.Fatalf("the send ran %d times, want a retry", attempts)
	}
	if h.revoked(tablet) {
		t.Fatal("the tablet stayed revoked although the first run was rolled back")
	}
}

// ---------------------------------------------------------------- CHAT-N4

func TestTheBacklogSweepCountsWhatASendCountsAndLeavesBarredSendersOut(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(10, 0)
	path, phone, bobPhone := friendsWithChat(h)
	idle := h.register(alice)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, idle)), 200, "")
	for i := 0; i < 6; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, idle)), 200, "")
	}
	h.idleFor(idle, "4 days")
	// Bob's envelopes are all that is waiting, and Alice has since blocked him (rows written directly: a block
	// through the API drops the pair's envelopes at once, which is not what is under test). They are never
	// delivered, so they are not a backlog; the send path leaves them out too.
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, alice, bob)
	if n, err := h.db.RevokeBackloggedDevices(h.ctx, 10, store.BackloggedDeviceIdle, 100); err != nil || n != 0 {
		t.Fatalf("swept %d (%v) a device whose backlog is all barred", n, err)
	}
	h.exec(`DELETE FROM blocks WHERE blocker_id=$1`, alice)
	if n, err := h.db.RevokeBackloggedDevices(h.ctx, 10, store.BackloggedDeviceIdle, 100); err != nil || n != 1 || !h.revoked(idle) {
		t.Fatalf("swept %d (%v), revoked %v", n, err, h.revoked(idle))
	}
}

func TestBarredSendersDoNotFillADeviceInTheSendPath(t *testing.T) {
	// The cheap count includes barred senders; the exact one must not. Alice's tablet holds three envelopes of a
	// sender she has blocked since: below the cap of four after the pair's other traffic, though raw it is above.
	h := newSocialHarness(t)
	h.capLimits(4, 0)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	cara1 := h.register(cara)
	h.ok(alice, "POST", "/v1/users/"+cara+"/friend-requests")
	h.ok(cara, "POST", "/v1/users/"+alice+"/friend-requests")
	caraChat := "/v1/conversations/" + h.expect(h.send(cara, "POST", "/v1/conversations", map[string]string{"userId": alice}), 200, "").data["conversationId"].(string)
	h.expect(h.send(alice, "POST", caraChat+"/messages", message(phone, cara1, tablet)), 200, "")
	for i := 0; i < 3; i++ {
		h.expect(h.send(cara, "POST", caraChat+"/messages", message(cara1, phone, tablet)), 200, "")
	}
	h.ackAll(phone)
	h.ackAll(cara1)
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, alice, cara)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	// Three of Cara's (barred) and two of Alice's own are 5 raw, over the cap of 4; only the 2 of Alice's count.
	// Two of Bob's make 4, and the next is refused.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 429, "RECIPIENT_BACKLOG")
}
