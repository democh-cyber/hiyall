package httpapi

import (
	"slices"
	"testing"
)

// Leftover chat audit items: device names are the owner's alone (G5), a push token is never taken from
// another account (F21), a peer who only reacted does not unlock lookups (F24, verified not a defect), and a
// new device is announced by a content-free push that the member's notification choices cannot switch off.

func (h *socialHarness) registerNamed(user, name string) testDevice {
	h.t.Helper()
	d := newTestDevice(user)
	reg := d.registration()
	reg["displayName"] = name
	h.expect(h.send(user, "POST", "/v1/devices", reg), 200, "")
	return d
}

func TestPeersDoNotSeeDeviceNamesButTheOwnerDoes(t *testing.T) {
	h := newSocialHarness(t)
	h.registerNamed(alice, "Alice's secret iPhone")
	// Bob may message Alice (messagesFrom is "everyone"), so he may list her devices, without the names.
	peers := items(h.ok(bob, "GET", "/v1/users/"+alice+"/devices"))
	if len(peers) != 1 {
		t.Fatalf("peer sees %d devices", len(peers))
	}
	if name, _ := peers[0]["displayName"].(string); name != "" {
		t.Fatalf("a peer was shown the device name %q", name)
	}
	if peers[0]["identityKey"] == nil || peers[0]["signature"] == nil {
		t.Fatalf("a peer needs the keys: %v", peers[0])
	}
	// The owner sees the name on both lists.
	mine := items(h.ok(alice, "GET", "/v1/me/devices"))
	if mine[0]["displayName"] != "Alice's secret iPhone" {
		t.Fatalf("owner list %v", mine[0])
	}
	own := items(h.ok(alice, "GET", "/v1/users/"+alice+"/devices"))
	if own[0]["displayName"] != "Alice's secret iPhone" {
		t.Fatalf("own devices through the peer route %v", own[0])
	}
}

func TestPushTokenIsNeverTakenFromAnotherAccount(t *testing.T) {
	h := newSocialHarness(t)
	aPhone, aTablet, bPhone := h.register(alice), h.register(alice), h.register(bob)
	set := func(user string, d testDevice, token string) reply {
		return h.send(user, "PUT", "/v1/devices/"+d.id+"/push", map[string]string{"provider": "fcm", "token": token})
	}
	holder := func(token string) []string {
		rows, err := h.api.Store.PushTargets(t.Context(), []string{alice, bob})
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, r := range rows {
			if r.Token == token {
				out = append(out, r.DeviceID)
			}
		}
		return out
	}
	h.expect(set(alice, aPhone, "shared-token-1"), 200, "")
	// Another account presenting the same token is refused and nothing changes for the holder.
	h.expect(set(bob, bPhone, "shared-token-1"), 409, "PUSH_TOKEN_IN_USE")
	if got := holder("shared-token-1"); !slices.Equal(got, []string{aPhone.id}) {
		t.Fatalf("token holders after the refused call: %v", got)
	}
	// The refusal says nothing about who holds it.
	if r := set(bob, bPhone, "shared-token-1"); r.data != nil {
		t.Fatalf("refusal carries data: %v", r.data)
	}
	// The same account moving the token between its own devices (a reinstall) still works.
	h.expect(set(alice, aTablet, "shared-token-1"), 200, "")
	if got := holder("shared-token-1"); !slices.Equal(got, []string{aTablet.id}) {
		t.Fatalf("token holders after the move: %v", got)
	}
	// Once the holder lets go, the other account may use it.
	h.expect(h.call(alice, "DELETE", "/v1/devices/"+aTablet.id+"/push"), 200, "")
	h.expect(set(bob, bPhone, "shared-token-1"), 200, "")
}

func TestAPeerWhoOnlyReactedDoesNotUnlockLookups(t *testing.T) {
	h := newSocialHarness(t)
	aPhone, bPhone := h.register(alice), h.register(bob)
	h.expect(h.send(alice, "POST", "/v1/devices/"+aPhone.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{aPhone.oneTimeKey("a1")}}), 200, "")
	h.expect(h.send(bob, "POST", "/v1/devices/"+bPhone.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{bPhone.oneTimeKey("b1"), bPhone.oneTimeKey("b2")}}), 200, "")
	id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
	// Alice writes; Bob only reacts (an auxiliary message).
	h.expect(h.send(alice, "POST", "/v1/conversations/"+id+"/messages", message(aPhone, bPhone)), 200, "")
	reaction := message(bPhone, aPhone)
	reaction["aux"] = "reaction"
	h.expect(h.send(bob, "POST", "/v1/conversations/"+id+"/messages", reaction), 200, "")
	// Bob now accepts messages from friends only. Alice is not his friend and Bob has never written a
	// message of his own, so his reaction must not count as a reply that lets her through.
	h.policy(bob, "messagesFrom", "friends")
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/devices"), 403, "MESSAGES_NOT_ALLOWED")
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/devices/"+bPhone.id+"/claim"), 403, "MESSAGES_NOT_ALLOWED")
	// A real message from Bob does.
	h.policy(bob, "messagesFrom", "everyone")
	h.expect(h.send(bob, "POST", "/v1/conversations/"+id+"/messages", message(bPhone, aPhone)), 200, "")
	h.policy(bob, "messagesFrom", "friends")
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/devices"), 200, "")
}

func TestANewDeviceIsAnnouncedByAContentFreePushThatChoicesCannotSwitchOff(t *testing.T) {
	h := newSocialHarness(t)
	_, sender := withRealtime(t, h)
	set := func(d testDevice, token string) {
		h.expect(h.send(alice, "PUT", "/v1/devices/"+d.id+"/push", map[string]string{"provider": "fcm", "token": token}), 200, "")
	}
	first := h.register(alice)
	set(first, "first-device-token")
	// Every push choice is off.
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]bool{"chat": false, "social": false}), 200, "")
	h.registerNamed(alice, "Someone else's phone")
	eventually(t, func() bool { return slices.Contains(sender.list(), alice+":device") })
	// Registering the same device again (it is not new) says nothing more.
	if n := countOf(sender.list(), alice+":device"); n != 1 {
		t.Fatalf("%d device pushes for one new device", n)
	}
	// Other people's pushes still obey the choices.
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]bool{"social": false}), 200, "")
	if slices.Contains(sender.list(), alice+":friend_request") {
		t.Fatalf("a push went out against the member's choice: %v", sender.list())
	}
}

func countOf(list []string, want string) int {
	n := 0
	for _, v := range list {
		if v == want {
			n++
		}
	}
	return n
}
