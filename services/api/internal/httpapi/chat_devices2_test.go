package httpapi

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Round 3 chat device and backlog findings: CHAT-N1 (a dormant device over the cap is revoked inside the send),
// CHAT-N2 (OWN_BACKLOG), CHAT-N3 (per-sender share, barred senders do not count), CHAT-N7 (the revoking device
// is not pushed, key counts are deduplicated).

// capLimits sets the chat limits for every member: the per-device cap, the per-sender share and no daily quota.
func (h *socialHarness) capLimits(total, perSender int) {
	h.api.Entitlements = func(context.Context, string) domain.Entitlements {
		e := domain.Free()
		e.ChatBacklogPerDevice, e.ChatBacklogPerSenderPerDevice, e.ChatMessagesPerConversationPerDay = total, perSender, 0
		return e
	}
}

func (h *socialHarness) idleFor(d testDevice, interval string) {
	h.t.Helper()
	h.exec(`UPDATE devices SET last_seen_at=now()-$2::interval WHERE device_id=$1`, d.id, interval)
}

func (h *socialHarness) revoked(d testDevice) bool {
	h.t.Helper()
	return h.countOf(`SELECT count(*) FROM devices WHERE device_id=$1 AND revoked_at IS NOT NULL`, d.id) == 1
}

// fillTablet leaves alice's tablet holding n undelivered envelopes (bob wrote first, so his first-contact budget
// is not what stops the traffic) and drains her phone.
func fillTablet(h *socialHarness, path string, phone, tablet, bobPhone testDevice, n int) {
	h.t.Helper()
	for i := 0; i < n; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	}
	h.ackAll(phone)
}

func TestDormantDeviceOverTheCapIsRevokedInTheSendAndTheTrafficSelfHeals(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.token(phone, "alice-phone-token")
	h.token(tablet, "alice-tablet-token")
	h.token(bobPhone, "bob-phone-token")
	h.capLimits(3, 0)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	fillTablet(h, path, phone, tablet, bobPhone, 2)
	h.ackAll(bobPhone)
	log.messages() // chat pushes are not under test

	// Used a day ago: a slow device, not a dormant one. The cap refuses, nothing is revoked.
	h.idleFor(tablet, "6 days 23 hours")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 429, "RECIPIENT_BACKLOG")
	if h.revoked(tablet) {
		t.Fatal("a device that polled six days ago was revoked")
	}
	// Past a week it is dormant: the send revokes it and answers DEVICES_CHANGED, which the client retries.
	h.idleFor(tablet, "8 days")
	before := len(log.messages())
	retry := message(bobPhone, phone, tablet)
	h.expect(h.send(bob, "POST", path+"/messages", retry), 409, "DEVICES_CHANGED")
	if !h.revoked(tablet) {
		t.Fatal("the dormant device is still active")
	}
	if n := h.countOf(`SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL`, tablet.id); n != 0 {
		t.Fatalf("the revoked device kept %d envelopes", n)
	}
	if h.countOf(`SELECT count(*) FROM messages WHERE message_id=$1`, retry["messageId"]) != 0 {
		t.Fatal("the answered DEVICES_CHANGED send was stored")
	}
	// The owner's other device is told by push (content-free) and the removal is listed with its reason.
	var notice int
	eventually(t, func() bool {
		notice = 0
		for i, m := range log.messages()[before:] {
			if m.Kind == "device-revoked" && log.to[before+i].Token == "alice-phone-token" {
				notice++
			}
		}
		return notice == 1
	})
	removed := removedOf(h, alice)
	if len(removed) != 1 || removed[0]["deviceId"] != tablet.id || removed[0]["reason"] != "inactive" {
		t.Fatalf("removed %v", removed)
	}
	// The retry, for the devices that remain, goes through, and traffic flows again.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	if h.activeDevices(alice) != 1 {
		t.Fatalf("%d active devices", h.activeDevices(alice))
	}
}

func TestADormantOwnDeviceOverTheCapIsRevokedWhenTheSenderSends(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	tablet, third := h.register(alice), h.register(alice)
	h.token(phone, "alice-phone-token")
	h.token(third, "alice-third-token")
	h.capLimits(3, 0)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet, third)), 200, "")
	for i := 0; i < 2; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet, third)), 200, "")
	}
	h.ackAll(third)
	h.ackAll(bobPhone)
	h.idleFor(tablet, "9 days")
	// Alice's own tablet is full: she gets DEVICES_CHANGED, not OWN_BACKLOG, and the tablet goes.
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet, third)), 409, "DEVICES_CHANGED")
	if !h.revoked(tablet) {
		t.Fatal("the dormant own device is still active")
	}
	// The third device is told; the sending phone, which is mid-send, is not.
	eventually(t, func() bool {
		for i, m := range log.messages() {
			if m.Kind == "device-revoked" && log.to[i].Token == "alice-third-token" {
				return true
			}
		}
		return false
	})
	time.Sleep(60 * time.Millisecond)
	for i, m := range log.messages() {
		if m.Kind == "device-revoked" && log.to[i].Token == "alice-phone-token" {
			t.Fatal("the sending phone was pushed about the removal it just caused")
		}
	}
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, third)), 200, "")
}

func TestConcurrentSendsToADormantFullDeviceRevokeItOnceAndNobodyFails(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(3, 0)
	phone, tablet := h.register(alice), h.register(alice)
	senders := []string{bob, cara, dev, eli, xan, yui}
	devices, paths := map[string]testDevice{}, map[string]string{}
	for _, s := range senders {
		devices[s] = h.register(s)
		id := h.expect(h.send(s, "POST", "/v1/conversations", map[string]string{"userId": alice}), 200, "").data["conversationId"].(string)
		paths[s] = "/v1/conversations/" + id
		// Alice writing first lifts the first-contact cap, so only the backlog is under test.
		h.expect(h.send(alice, "POST", paths[s]+"/messages", message(phone, devices[s], tablet)), 200, "")
		h.ackAll(tablet)
	}
	// Three senders write back: the tablet holds three envelopes, the cap; the phone is drained.
	for _, s := range senders[:3] {
		h.expect(h.send(s, "POST", paths[s]+"/messages", message(devices[s], phone, tablet)), 200, "")
	}
	h.ackAll(phone)
	h.idleFor(tablet, "10 days")
	var wg sync.WaitGroup
	var mu sync.Mutex
	statuses := map[string]int{}
	for _, s := range senders {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got := h.send(s, "POST", paths[s]+"/messages", message(devices[s], phone, tablet))
			mu.Lock()
			defer mu.Unlock()
			statuses[fmt.Sprintf("%d %s", got.status, got.code)]++
		}()
	}
	wg.Wait()
	// Every sender is told the devices changed (the one that revoked, and those that arrived after it).
	if len(statuses) != 1 || statuses["409 DEVICES_CHANGED"] != len(senders) {
		t.Fatalf("answers %v", statuses)
	}
	if h.countOf(`SELECT count(*) FROM devices WHERE user_id=$1 AND revoked_at IS NOT NULL AND revoked_reason='inactive'`, alice) != 1 {
		t.Fatal("the tablet was not revoked exactly once")
	}
	for _, s := range senders {
		h.expect(h.send(s, "POST", paths[s]+"/messages", message(devices[s], phone)), 200, "")
		h.ackAll(phone)
	}
}

func TestBackloggedIdleDevicesAreSweptAndActiveOnesAreNot(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(10, 0)
	path, phone, bobPhone := friendsWithChat(h)
	idle, slow, light := h.register(alice), h.register(alice), h.register(alice)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, idle, slow, light)), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, idle, slow, light)), 200, "")
	for i := 0; i < 5; i++ {
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, idle, slow, light)), 200, "")
	}
	h.ackAll(light)
	// idle and slow hold 7 envelopes (more than half of 10), light has picked its up.
	h.idleFor(idle, "4 days")
	h.idleFor(slow, "2 days")
	h.idleFor(light, "30 hours")
	h.exec(`UPDATE devices SET last_seen_at=now()-interval '4 days' WHERE device_id=$1`, light.id)
	n, err := h.db.RevokeBackloggedDevices(h.ctx, 10, store.BackloggedDeviceIdle, 100)
	if err != nil || n != 1 || !h.revoked(idle) || h.revoked(slow) || h.revoked(light) {
		t.Fatalf("swept %d, err %v, idle %v slow %v light %v", n, err, h.revoked(idle), h.revoked(slow), h.revoked(light))
	}
	if h.countOf(`SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1`, idle.id) != 0 {
		t.Fatal("the swept device kept its ciphertext")
	}
	removed := removedOf(h, alice)
	if len(removed) != 1 || removed[0]["deviceId"] != idle.id || removed[0]["reason"] != "inactive" {
		t.Fatalf("removed %v", removed)
	}
	if again, _ := h.db.RevokeBackloggedDevices(h.ctx, 10, store.BackloggedDeviceIdle, 100); again != 0 {
		t.Fatalf("second sweep revoked %d", again)
	}
}

func TestStaleDeviceWindowIsTwoWeeks(t *testing.T) {
	if store.StaleDeviceAfter != 14*24*time.Hour || store.DormantDeviceAfter != 7*24*time.Hour || store.BackloggedDeviceIdle != 3*24*time.Hour {
		t.Fatalf("windows %v %v %v", store.StaleDeviceAfter, store.DormantDeviceAfter, store.BackloggedDeviceIdle)
	}
}

// ---------------------------------------------------------------- CHAT-N2

func TestOwnDeviceBacklogHasItsOwnCodeAndTheRecipientTextIsUnchanged(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.limits(2, 0)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	h.ackAll(bobPhone)
	status, _, body := h.full(alice, "POST", path+"/messages", "application/json", mustJSON(message(phone, bobPhone, tablet)))
	if status != 429 || !strings.Contains(string(body), `"OWN_BACKLOG"`) || !strings.Contains(string(body), "Chat devices") || strings.Contains(string(body), "They haven't") {
		t.Fatalf("own backlog: %d %s", status, body)
	}
	// The peer's full device is still RECIPIENT_BACKLOG with the old words.
	h.ackAll(tablet)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	status, _, body = h.full(alice, "POST", path+"/messages", "application/json", mustJSON(message(phone, bobPhone, tablet)))
	if status != 429 || !strings.Contains(string(body), `"RECIPIENT_BACKLOG"`) || !strings.Contains(string(body), "They haven't picked up their earlier messages yet. Try again later.") {
		t.Fatalf("recipient backlog: %d %s", status, body)
	}
}

// ---------------------------------------------------------------- CHAT-N3

func TestOneSenderCannotFillAVictimsDeviceAlone(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(2000, 3)
	victim, victimPhone := bob, h.register(bob)
	attacker, friend := cara, alice
	attackerPhone, friendPhone := h.register(attacker), h.register(friend)
	open := func(from string) string {
		id := h.expect(h.send(from, "POST", "/v1/conversations", map[string]string{"userId": victim}), 200, "").data["conversationId"].(string)
		path := "/v1/conversations/" + id
		// The victim writing first lifts the first-contact cap, so only the backlog share is under test.
		return path
	}
	attackerPath, friendPath := open(attacker), open(friend)
	for _, p := range []string{attackerPath, friendPath} {
		d := attackerPhone
		if p == friendPath {
			d = friendPhone
		}
		h.expect(h.send(victim, "POST", p+"/messages", message(victimPhone, d)), 200, "")
	}
	for i := 0; i < 3; i++ {
		h.expect(h.send(attacker, "POST", attackerPath+"/messages", message(attackerPhone, victimPhone)), 200, "")
	}
	over := message(attackerPhone, victimPhone)
	status, header, _ := h.full(attacker, "POST", attackerPath+"/messages", "application/json", mustJSON(over))
	if status != 429 || header.Get("Retry-After") != "60" {
		t.Fatalf("status %d, Retry-After %q", status, header.Get("Retry-After"))
	}
	h.expect(h.send(attacker, "POST", attackerPath+"/messages", over), 429, "RECIPIENT_BACKLOG")
	// Only that sender is held back: another account still reaches the victim, and the victim reaches the attacker.
	for i := 0; i < 3; i++ {
		h.expect(h.send(friend, "POST", friendPath+"/messages", message(friendPhone, victimPhone)), 200, "")
	}
	h.expect(h.send(victim, "POST", attackerPath+"/messages", message(victimPhone, attackerPhone)), 200, "")
	// When the victim picks up, the share frees.
	h.ackAll(victimPhone)
	h.expect(h.send(attacker, "POST", attackerPath+"/messages", over), 200, "")
}

func TestThePerSenderShareDoesNotApplyToTheSendersOwnDevices(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(2000, 2)
	path, phone, bobPhone := friendsWithChat(h)
	tablet := h.register(alice)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone, tablet)), 200, "")
	for i := 0; i < 5; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
		h.ackAll(bobPhone)
	}
}

func TestEnvelopesOfBarredSendersDoNotCountTowardTheCap(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(3, 300)
	victimPhone := h.register(bob)
	carasPhone, alicesPhone := h.register(cara), h.register(alice)
	paths := map[string]string{}
	for _, s := range []string{cara, alice} {
		id := h.expect(h.send(s, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
		paths[s] = "/v1/conversations/" + id
	}
	h.expect(h.send(bob, "POST", paths[cara]+"/messages", message(victimPhone, carasPhone)), 200, "")
	for i := 0; i < 3; i++ {
		h.expect(h.send(cara, "POST", paths[cara]+"/messages", message(carasPhone, victimPhone)), 200, "")
	}
	// The device is full of cara's messages: everyone else is refused too.
	h.expect(h.send(bob, "POST", paths[alice]+"/messages", message(victimPhone, alicesPhone)), 200, "")
	h.expect(h.send(alice, "POST", paths[alice]+"/messages", message(alicesPhone, victimPhone)), 429, "RECIPIENT_BACKLOG")
	// Bob blocks cara by a path that leaves the envelopes in place (a block row alone): the inbox never delivers
	// them, so they stop counting.
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, bob, cara)
	if len(h.inboxOf(victimPhone)) != 0 {
		t.Fatal("a barred sender's envelope is delivered")
	}
	if h.countOf(`SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL`, victimPhone.id) != 3 {
		t.Fatal("the envelopes should still be stored for this test")
	}
	h.expect(h.send(alice, "POST", paths[alice]+"/messages", message(alicesPhone, victimPhone)), 200, "")
}

func TestBlockingPurgesTheBlockedSendersPendingEnvelopes(t *testing.T) {
	h := newSocialHarness(t)
	h.capLimits(3, 300)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	for i := 0; i < 3; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
	h.ok(bob, "POST", "/v1/users/"+alice+"/block")
	if n := h.countOf(`SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL`, bobPhone.id); n != 0 {
		t.Fatalf("%d envelopes of the blocked sender remain", n)
	}
}

// ---------------------------------------------------------------- CHAT-N7

func TestTheDeviceThatRevokedAnotherIsNotPushedAboutIt(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	caller, other, gone := h.register(alice), h.register(alice), h.register(alice)
	h.asOtherSession(other)
	h.asOtherSession(gone)
	h.token(caller, "caller-token")
	h.token(other, "other-token")
	h.token(gone, "gone-token")
	// The harness session registered caller, so a removal by it is "by another session" for the others.
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+gone.id), 200, "")
	eventually(t, func() bool { return len(log.messages()) >= 1 })
	time.Sleep(80 * time.Millisecond)
	got := log.messages()
	if len(got) != 1 || got[0].Kind != "device-revoked" || log.to[0].Token != "other-token" {
		t.Fatalf("pushes %+v to %+v", got, log.to)
	}
}

func TestOneTimeKeyCapCountsEachKeyOnce(t *testing.T) {
	h := newSocialHarness(t)
	d := h.register(alice)
	keys := func(from, to int) []map[string]string {
		out := []map[string]string{}
		for i := from; i < to; i++ {
			out = append(out, d.oneTimeKey(fmt.Sprintf("k%d", i)))
		}
		return out
	}
	upload := func(list []map[string]string) reply {
		return h.send(alice, "POST", "/v1/devices/"+d.id+"/keys", map[string]any{"oneTimeKeys": list})
	}
	first := keys(0, 50)
	if got := h.expect(upload(first), 200, "").data["oneTimeKeyCount"]; got != float64(50) {
		t.Fatalf("count %v", got)
	}
	// The same request twice in one body: 50 distinct keys, not 100.
	h.expect(upload(append(keys(50, 100), first...)), 422, "VALIDATION") // 51+ keys in one request is refused by size
	second := keys(50, 100)
	if got := h.expect(upload(append(second[:25:25], second[:25]...)), 200, "").data["oneTimeKeyCount"]; got != float64(75) {
		t.Fatalf("duplicates inside one upload counted twice: %v", got)
	}
	// Keys the device already holds add nothing, so re-sending them at the cap is not an overflow.
	if got := h.expect(upload(second[:25]), 200, "").data["oneTimeKeyCount"]; got != float64(75) {
		t.Fatalf("held keys counted again: %v", got)
	}
	h.expect(upload(second[25:]), 200, "")
	h.expect(upload(first[:10]), 200, "") // all held, at the cap of 100
	h.expect(upload(keys(100, 101)), 422, "VALIDATION")
}

// ---------------------------------------------------------------- CHAT-N9

// The app's session repair (the "noop" it sends to a peer device) is an aux message and counts toward the
// first-contact cap like any other: at the cap the relay refuses it with AWAITING_REPLY, stores nothing, and the
// peer's reply lifts it. The app treats the refusal as "try again later" (it never throws).
func TestUnwedgeNoopIsRefusedAtTheFirstContactCapAndStoresNothing(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	for i := 0; i < store.FirstContactMessages; i++ {
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	}
	noop := auxMessage(phone, bobPhone)
	h.expect(h.send(alice, "POST", path+"/messages", noop), 403, "AWAITING_REPLY")
	if h.countOf(`SELECT count(*) FROM messages WHERE message_id=$1`, noop["messageId"]) != 0 ||
		h.countOf(`SELECT count(*) FROM message_envelopes WHERE message_id=$1`, noop["messageId"]) != 0 {
		t.Fatal("a refused noop was stored")
	}
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", noop), 200, "")
}
