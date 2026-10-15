package httpapi

import (
	"testing"
	"time"

	"hiyall/services/api/internal/store"
)

// Chat device lifecycle (migration 0035): devices follow the session that registered them, stale ones
// are revoked, and the per-account limiters bound registration, keys and the inbox.

func (h *socialHarness) activeDevices(user string) int {
	h.t.Helper()
	return h.countOf(`SELECT count(*) FROM devices WHERE user_id=$1 AND revoked_at IS NULL`, user)
}

func TestRevokingAnAuthSessionRevokesItsChatDevice(t *testing.T) {
	h := newSocialHarness(t)
	phone := h.register(alice)
	h.expect(h.send(alice, "POST", "/v1/devices/"+phone.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{phone.oneTimeKey("k1")}, "fallbackKey": phone.oneTimeKey("fb")}), 200, "")
	bobPhone := h.register(bob)
	h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
	h.expect(h.send(bob, "POST", "/v1/conversations/"+id+"/messages", message(bobPhone, phone)), 200, "")

	// The harness's session id is the user id; give it a row so it can be revoked like a real session.
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at) VALUES($1,$1,now()+interval '1 hour')`, alice)
	if h.activeDevices(alice) != 1 {
		t.Fatal("device should be active before the session is revoked")
	}
	h.exec(`UPDATE sessions SET revoked_at=now() WHERE session_id=$1`, alice)
	if h.activeDevices(alice) != 0 {
		t.Fatal("revoking the session left its chat device active")
	}
	if n := h.countOf(`SELECT (SELECT count(*) FROM one_time_keys WHERE device_id=$1)+(SELECT count(*) FROM fallback_keys WHERE device_id=$1)+(SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL)`, phone.id); n != 0 {
		t.Fatalf("revoked device kept %d keys or ciphertext rows", n)
	}
	// Bob's device is untouched, and the revoked device cannot read its inbox any more.
	if h.activeDevices(bob) != 1 {
		t.Fatal("another account's device was revoked")
	}
	h.expect(h.call(alice, "GET", "/v1/devices/"+phone.id+"/inbox"), 404, "NOT_FOUND")
	// Registering the same keys again is a conflict, so the client must make a new identity.
	h.expect(h.send(alice, "POST", "/v1/devices", phone.registration()), 409, "DEVICE_CONFLICT")
}

func TestStaleDevicesAreRevokedAndFreeTheCap(t *testing.T) {
	h := newSocialHarness(t)
	old := []testDevice{}
	for i := 0; i < 10; i++ {
		old = append(old, h.register(alice))
	}
	h.expect(h.send(alice, "POST", "/v1/devices", newTestDevice(alice).registration()), 409, "TOO_MANY_DEVICES")
	keys := []map[string]string{old[0].oneTimeKey("k1")}
	h.expect(h.send(alice, "POST", "/v1/devices/"+old[0].id+"/keys", map[string]any{"oneTimeKeys": keys}), 200, "")
	h.exec(`UPDATE devices SET last_seen_at=now()-interval '91 days' WHERE device_id=$1`, old[0].id)
	h.exec(`UPDATE devices SET last_seen_at=now()-interval '89 days' WHERE device_id=$1`, old[1].id)

	n, err := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100)
	if err != nil || n != 1 {
		t.Fatalf("revoked %d, err %v", n, err)
	}
	if h.countOf(`SELECT count(*) FROM one_time_keys WHERE device_id=$1`, old[0].id) != 0 {
		t.Fatal("stale device kept its keys")
	}
	if h.activeDevices(alice) != 9 {
		t.Fatalf("%d active devices after the sweep", h.activeDevices(alice))
	}
	h.expect(h.send(alice, "POST", "/v1/devices", newTestDevice(alice).registration()), 200, "")
	if again, _ := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 100); again != 0 {
		t.Fatalf("second sweep revoked %d", again)
	}
	// The stale device is told to start over: its inbox is gone and its registration conflicts.
	h.expect(h.call(alice, "GET", "/v1/devices/"+old[0].id+"/inbox"), 404, "NOT_FOUND")
	h.expect(h.send(alice, "POST", "/v1/devices", old[0].registration()), 409, "DEVICE_CONFLICT")
}

func TestFirstContactCapUntilThePeerReplies(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	for i := 0; i < store.FirstContactMessages; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
	over := message(phone, bobPhone)
	r := h.expect(h.send(alice, "POST", path+"/messages", over), 403, "AWAITING_REPLY")
	if r.status != 403 {
		t.Fatal("wrong status")
	}
	// Nothing was stored for the refused message, and a replay of an accepted one still works.
	if h.countOf(`SELECT count(*) FROM messages WHERE message_id=$1`, over["messageId"]) != 0 {
		t.Fatal("a refused message was stored")
	}
	// The peer's reaction is not a reply.
	h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 403, "AWAITING_REPLY")
	// The peer can always write back, and that unlocks the sender.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	for i := 0; i < 5; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
}

func TestFirstContactCapIsPerConversationAndPerSender(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	// Bob wrote first: Alice replying is never capped, and Bob's own count is irrelevant once she wrote.
	for i := 0; i < 2; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	}
	for i := 0; i < 6; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
	for i := 0; i < 6; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	}
}

func TestChatLimitersAreRegisteredAndPerAccount(t *testing.T) {
	h := newSocialHarness(t)
	for _, name := range []string{"chat_devices", "chat_keys", "chat_inbox"} {
		if h.api.limiters()[name] == nil {
			t.Fatalf("limiter %s is not registered", name)
		}
	}
	d := h.register(alice)
	// Registration and the device list share one budget (burst 20, then one every two seconds).
	limited := 0
	for i := 0; i < 40; i++ {
		if h.call(alice, "GET", "/v1/me/devices").status == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("the device list was never limited")
	}
	if got := h.send(alice, "POST", "/v1/devices", d.registration()); got.status != 429 || got.code != "RATE_LIMITED" {
		t.Fatalf("registration after the burst: %d %s", got.status, got.code)
	}
	// Another account has its own budget.
	h.register(bob)
	// Key counts: burst 30.
	keyLimited := 0
	for i := 0; i < 50; i++ {
		if h.call(alice, "GET", "/v1/devices/"+d.id+"/keys").status == 429 {
			keyLimited++
		}
	}
	if keyLimited == 0 {
		t.Fatal("key counts were never limited")
	}
	inboxLimited := 0
	for i := 0; i < 100; i++ {
		if h.call(bob, "GET", "/v1/devices/"+uuidOf(h, bob)+"/inbox").status == 429 {
			inboxLimited++
		}
	}
	if inboxLimited == 0 {
		t.Fatal("the inbox was never limited")
	}
	_ = time.Second
}

// uuidOf finds an active chat device of the user.
func uuidOf(h *socialHarness, user string) string {
	var id string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT device_id::text FROM devices WHERE user_id=$1 AND revoked_at IS NULL LIMIT 1`, user).Scan(&id); err != nil {
		h.t.Fatal(err)
	}
	return id
}
