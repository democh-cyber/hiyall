package httpapi

import (
	"context"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/store"
)

// Re-audit CHAT-2 (device removal record and push), CHAT-3 (first-contact cap and aux) and CHAT-4 (backlog
// and daily quota).

// limits makes every member's chat limits the given ones, the rest unchanged.
func (h *socialHarness) limits(backlog, perDay int) {
	h.api.Entitlements = func(context.Context, string) domain.Entitlements {
		e := domain.Free()
		e.ChatBacklogPerDevice, e.ChatMessagesPerConversationPerDay = backlog, perDay
		return e
	}
}

// inboxOf lists what is waiting for a device.
func (h *socialHarness) inboxOf(d testDevice) []map[string]any {
	h.t.Helper()
	return items(h.ok(d.user, "GET", "/v1/devices/"+d.id+"/inbox?limit=100"))
}

func (h *socialHarness) ackAll(d testDevice) {
	h.t.Helper()
	var ids []string
	for _, item := range h.inboxOf(d) {
		ids = append(ids, item["messageId"].(string))
	}
	if len(ids) > 0 {
		h.expect(h.send(d.user, "POST", "/v1/devices/"+d.id+"/inbox/ack", map[string]any{"messageIds": ids}), 200, "")
	}
}

// ---------------------------------------------------------------- CHAT-3

func TestAuxMessagesCountTowardTheFirstContactCap(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	// A stranger marks text as a reaction to dodge the cap: it counts like any message.
	for i := 0; i < store.FirstContactMessages; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
	}
	over := auxMessage(phone, bobPhone)
	h.expect(h.send(alice, "POST", path+"/messages", over), 403, "AWAITING_REPLY")
	if h.countOf(`SELECT count(*) FROM messages WHERE message_id=$1`, over["messageId"]) != 0 {
		t.Fatal("a refused aux message was stored")
	}
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 403, "AWAITING_REPLY")
	// The peer's own reaction is not a reply either.
	h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 403, "AWAITING_REPLY")
	// A written reply lifts it for both kinds, and a replay of a stored aux message was never counted again.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	for i := 0; i < 4; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
}

func TestMixedTextAndAuxShareOneFirstContactBudget(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	first := auxMessage(phone, bobPhone)
	h.expect(h.send(alice, "POST", path+"/messages", first), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	// A replay of an accepted aux message is answered from the stored row, not refused as the fourth.
	h.expect(h.send(alice, "POST", path+"/messages", first), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 403, "AWAITING_REPLY")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 403, "AWAITING_REPLY")
}

func TestInboxItemsCarryTheAuxFlag(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	text, aux := message(phone, bobPhone), auxMessage(phone, bobPhone)
	h.expect(h.send(alice, "POST", path+"/messages", text), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", aux), 200, "")
	flags := map[string]any{}
	for _, item := range h.inboxOf(bobPhone) {
		flags[item["messageId"].(string)] = item["aux"]
	}
	if flags[text["messageId"].(string)] != nil || flags[aux["messageId"].(string)] != true {
		t.Fatalf("aux flags %v", flags)
	}
}

// ---------------------------------------------------------------- CHAT-4

func TestRecipientBacklogIsCappedAndDrainingFreesIt(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.limits(3, 0)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "") // alice's device holds 1
	h.ackAll(phone)
	// Bob's device is the one that fills: three unread envelopes.
	for i := 0; i < 3; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
	over := message(phone, bobPhone)
	status, header, _ := h.full(alice, "POST", path+"/messages", "application/json", mustJSON(over))
	if status != 429 || header.Get("Retry-After") != "60" {
		t.Fatalf("status %d, Retry-After %q", status, header.Get("Retry-After"))
	}
	h.expect(h.send(alice, "POST", path+"/messages", over), 429, "RECIPIENT_BACKLOG")
	if h.countOf(`SELECT count(*) FROM messages WHERE message_id=$1`, over["messageId"]) != 0 {
		t.Fatal("a refused message was stored")
	}
	// Reactions fill the same inbox, so they are refused too; the full device never blocks the other direction.
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 429, "RECIPIENT_BACKLOG")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	// Bob picks two messages up: two slots are free, then it is full again.
	items := h.inboxOf(bobPhone)
	h.expect(h.send(bob, "POST", "/v1/devices/"+bobPhone.id+"/inbox/ack", map[string]any{"messageIds": []string{items[0]["messageId"].(string), items[1]["messageId"].(string)}}), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", over), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 429, "RECIPIENT_BACKLOG")
	// A replay of a stored message is still answered, whatever the backlog.
	h.expect(h.send(alice, "POST", path+"/messages", over), 200, "")
}

func TestOwnOtherDeviceBacklogIsCappedToo(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.limits(2, 0)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	h.ackAll(bobPhone)
	// The tablet holds two unread envelopes; the peer is fine, but the send is refused.
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 429, "OWN_BACKLOG")
	h.ackAll(tablet)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
}

func TestBacklogCapHoldsUnderConcurrentSendersToOneRecipient(t *testing.T) {
	h := newSocialHarness(t)
	const cap = 5
	h.limits(cap, 0)
	target := h.register(bob)
	senders := []string{alice, cara, dev, eli, xan, yui}
	paths := map[string]string{}
	devices := map[string]testDevice{}
	for _, s := range senders {
		devices[s] = h.register(s)
		id := h.expect(h.send(s, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
		paths[s] = "/v1/conversations/" + id
		// Bob writing first lifts the first-contact cap, so only the backlog is under test.
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	accepted, refused := 0, 0
	for _, s := range senders {
		for i := 0; i < 3; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				got := h.send(s, "POST", paths[s]+"/messages", message(devices[s], target))
				mu.Lock()
				defer mu.Unlock()
				switch {
				case got.status == 200:
					accepted++
				case got.status == 429 && got.code == "RECIPIENT_BACKLOG":
					refused++
				default:
					t.Errorf("unexpected %d %q", got.status, got.code)
				}
			}()
		}
	}
	wg.Wait()
	// First-contact (3 per sender) never bites here; the cap lets exactly cap envelopes in.
	if accepted != cap || refused != len(senders)*3-cap {
		t.Fatalf("accepted %d, refused %d, want exactly %d accepted", accepted, refused, cap)
	}
	if n := h.countOf(`SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL`, target.id); n != cap {
		t.Fatalf("%d undelivered envelopes, cap %d", n, cap)
	}
}

func TestDailyMessageQuotaPerSenderPerConversation(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.limits(0, 4)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	for i := 0; i < 3; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
	// Reactions count: the fourth message of the day is a reaction, the fifth anything is refused.
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
	over := message(phone, bobPhone)
	status, header, _ := h.full(alice, "POST", path+"/messages", "application/json", mustJSON(over))
	after, _ := strconv.Atoi(header.Get("Retry-After"))
	if status != 429 || after < 3000 || after > 86400 {
		t.Fatalf("status %d, Retry-After %q", status, header.Get("Retry-After"))
	}
	h.expect(h.send(alice, "POST", path+"/messages", over), 429, "CHAT_DAILY_LIMIT")
	// It is per sender: the peer's own budget is untouched; and per conversation.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	other := h.register(cara)
	id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": cara}), 200, "").data["conversationId"].(string)
	h.expect(h.send(alice, "POST", "/v1/conversations/"+id+"/messages", message(phone, other)), 200, "")
	// Messages age out of the window one by one.
	h.exec(`UPDATE messages SET created_at=now()-interval '25 hours' WHERE message_id=(SELECT message_id FROM messages WHERE sender_id=$1 AND conversation_id=$2 ORDER BY created_at LIMIT 1)`, alice, path[len("/v1/conversations/"):])
	h.expect(h.send(alice, "POST", path+"/messages", over), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 429, "CHAT_DAILY_LIMIT")
	// A replay of a stored message is not counted again.
	h.expect(h.send(alice, "POST", path+"/messages", over), 200, "")
}

func TestFreeChatLimitsAreTheDocumentedNumbers(t *testing.T) {
	e := domain.Free()
	if e.ChatBacklogPerDevice != 2000 || e.ChatMessagesPerConversationPerDay != 2000 || e.ChatBacklogPerSenderPerDevice != 300 {
		t.Fatalf("chat limits %d / %d / %d", e.ChatBacklogPerDevice, e.ChatMessagesPerConversationPerDay, e.ChatBacklogPerSenderPerDevice)
	}
}

// ---------------------------------------------------------------- CHAT-2

// asOtherSession makes a registered device belong to a session other than the one the harness calls with, so a
// call made as the harness user is "a session that is not that device".
func (h *socialHarness) asOtherSession(d testDevice) {
	h.exec(`UPDATE devices SET session_id=$2 WHERE device_id=$1`, d.id, uuid.NewString())
}

func removedOf(h *socialHarness, user string) []map[string]any {
	h.t.Helper()
	raw, _ := h.ok(user, "GET", "/v1/me/devices")["removed"].([]any)
	out := make([]map[string]any, len(raw))
	for i, v := range raw {
		out[i] = v.(map[string]any)
	}
	return out
}

func TestRevokingAnotherSessionsDeviceIsRecordedForTheOwner(t *testing.T) {
	h := newSocialHarness(t)
	phone, tablet, mine := h.register(alice), h.register(alice), h.register(alice)
	h.asOtherSession(phone)
	h.asOtherSession(tablet)
	// A device removing itself (its own session) is a sign-out, not an event.
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+mine.id), 200, "")
	if got := removedOf(h, alice); len(got) != 0 {
		t.Fatalf("own removal listed: %v", got)
	}
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+phone.id), 200, "")
	got := removedOf(h, alice)
	if len(got) != 1 || got[0]["deviceId"] != phone.id || got[0]["removedAt"] == nil {
		t.Fatalf("removed %v", got)
	}
	// Only the owner reads it, and a stale record is dropped after thirty days.
	if len(removedOf(h, bob)) != 0 {
		t.Fatal("another account sees the removal")
	}
	h.exec(`UPDATE devices SET revoked_at=now()-interval '31 days' WHERE device_id=$1`, phone.id)
	if got := removedOf(h, alice); len(got) != 0 {
		t.Fatalf("old removal still listed: %v", got)
	}
	// A session revocation never records one. The idle sweep does, with its reason, so the owner's other devices
	// can tell the removal from one by a session of theirs (round 4, CHAT-N1).
	h.exec(`UPDATE devices SET last_seen_at=now()-interval '100 days' WHERE device_id=$1`, tablet.id)
	if n, err := h.db.RevokeStaleDevices(h.ctx, store.StaleDeviceAfter, 10); err != nil || n != 1 {
		t.Fatalf("stale revoke %d %v", n, err)
	}
	if got := removedOf(h, alice); len(got) != 1 || got[0]["deviceId"] != tablet.id || got[0]["reason"] != "idle" {
		t.Fatalf("idle revocation listed as %v", got)
	}
}

// The thief's flow: a stolen token opens a socket for the account, registers a device, and removes the owner's
// phone. The owner's other devices must still be told, by push, with no help from the socket or the chat cap.
func TestStolenTokenCannotSilenceTheDevicePushes(t *testing.T) {
	h := newSocialHarness(t)
	log, server := pushing(t, h, func(c *push.Config) { c.DailyCap = 1 })
	phone, tablet := h.register(alice), h.register(alice)
	h.asOtherSession(phone)
	h.asOtherSession(tablet)
	log.quiet(t, 0, "registering the first two devices (no tokens yet)")
	h.token(phone, "alice-phone-token")
	h.token(tablet, "alice-tablet-token")

	// The thief holds a live socket for the account.
	socket, _, err := dial(t, server, alice)
	if err != nil {
		t.Fatal(err)
	}
	_ = socket
	eventually(t, func() bool { return h.api.RT.Connected(alice) })

	// Register: the owner's devices are pushed although the account is "online", the new one is left out.
	h.register(alice)
	pushes := log.wait(t, 2)
	for _, m := range pushes {
		if m.Kind != "device" || m.Body != "New device added to your account" {
			t.Fatalf("push %+v", m)
		}
	}
	// A second registration straight after is not coalesced away either.
	h.register(alice)
	log.wait(t, 4)
	// The chat cap is 1 here: had the device pushes shared it, the second registration would be dropped.
	// Revoke the owner's phone with the thief's session: the remaining devices are told, content-free.
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+phone.id), 200, "")
	revoked := 0
	eventually(t, func() bool {
		revoked = 0
		for _, m := range log.messages() {
			if m.Kind == "device-revoked" {
				revoked++
			}
		}
		return revoked >= 1
	})
	time.Sleep(60 * time.Millisecond)
	if revoked != 1 {
		t.Fatalf("%d device-revoked pushes, want one (the tablet; the removed phone has no token)", revoked)
	}
	for _, m := range log.messages() {
		if m.Kind == "device-revoked" {
			if m.Body != "A device was removed from your account" || m.Data["kind"] != "device" || len(m.Data) != 1 {
				t.Fatalf("revoked push %+v", m)
			}
		}
	}
	if got := removedOf(h, alice); len(got) != 1 || got[0]["deviceId"] != phone.id {
		t.Fatalf("removed %v", got)
	}
	// The removed phone finds out on its next inbox read (404) and starts over with a new identity; the record
	// the other devices fetch stays, so the reset does not hide the removal.
	h.expect(h.call(alice, "GET", "/v1/devices/"+phone.id+"/inbox"), 404, "NOT_FOUND")
	h.expect(h.send(alice, "POST", "/v1/devices", phone.registration()), 409, "DEVICE_CONFLICT")
	h.register(alice)
	if got := removedOf(h, alice); len(got) != 1 || got[0]["deviceId"] != phone.id {
		t.Fatalf("removed after the reset %v", got)
	}
}

func TestADeviceSigningItselfOutDoesNotPush(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	phone, tablet := h.register(alice), h.register(alice)
	h.token(tablet, "alice-tablet-token")
	log.wait(t, 0)
	// The harness session is the one both devices registered under: this is a device signing itself out.
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+phone.id), 200, "")
	log.quiet(t, 0, "a device signing out")
}

// ---------------------------------------------------------------- push token handover

func TestPushTokenOfAStaleDeviceOfAnotherAccountIsHandedOver(t *testing.T) {
	h := newSocialHarness(t)
	old := h.register(alice)
	h.token(old, "shared-install-token")
	mine := h.register(bob)
	// Alice's device is in use (seen just now): the token is not taken.
	h.expect(h.send(bob, "PUT", "/v1/devices/"+mine.id+"/push", map[string]string{"provider": "fcm", "token": "shared-install-token"}), 409, "PUSH_TOKEN_IN_USE")
	// Unseen for more than a day, it is what a previous sign-in on this install left: revoked, token accepted.
	h.expect(h.send(alice, "POST", "/v1/devices/"+old.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{old.oneTimeKey("k1")}}), 200, "")
	h.exec(`UPDATE devices SET last_seen_at=now()-interval '25 hours' WHERE device_id=$1`, old.id)
	h.expect(h.send(bob, "PUT", "/v1/devices/"+mine.id+"/push", map[string]string{"provider": "fcm", "token": "shared-install-token"}), 200, "")
	if h.countOf(`SELECT count(*) FROM devices WHERE device_id=$1 AND revoked_at IS NOT NULL AND push_token IS NULL AND NOT revoked_by_other`, old.id) != 1 {
		t.Fatal("the stale device was not revoked")
	}
	if h.countOf(`SELECT count(*) FROM one_time_keys WHERE device_id=$1`, old.id) != 0 {
		t.Fatal("the revoked device kept its keys")
	}
	if h.countOf(`SELECT count(*) FROM devices WHERE device_id=$1 AND push_token='shared-install-token'`, mine.id) != 1 {
		t.Fatal("the new holder has no token")
	}
	h.expect(h.call(alice, "GET", "/v1/devices/"+old.id+"/inbox"), 404, "NOT_FOUND")
}
