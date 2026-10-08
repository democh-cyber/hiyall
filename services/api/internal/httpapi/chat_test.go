package httpapi

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"testing"

	"github.com/google/uuid"
	"kairova/services/api/internal/domain"
)

var b64 = base64.RawStdEncoding

type testDevice struct {
	user, id, identity, signingKey string
	private                        ed25519.PrivateKey
}

func randomKey() string {
	raw := make([]byte, 32)
	_, _ = rand.Read(raw)
	return b64.EncodeToString(raw)
}

func newTestDevice(user string) testDevice {
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	return testDevice{user: user, id: uuid.NewString(), identity: randomKey(), signingKey: b64.EncodeToString(public), private: private}
}

func (d testDevice) sign(statement string) string {
	return b64.EncodeToString(ed25519.Sign(d.private, []byte(statement)))
}

func (d testDevice) registration() map[string]any {
	return map[string]any{"deviceId": d.id, "identityKey": d.identity, "signingKey": d.signingKey, "platform": "linux",
		"signature": d.sign(domain.DeviceStatement(d.user, d.id, d.identity, d.signingKey))}
}

func (d testDevice) oneTimeKey(id string) map[string]string {
	key := randomKey()
	return map[string]string{"keyId": id, "publicKey": key, "signature": d.sign(domain.OneTimeKeyStatement(d.user, d.id, id, key))}
}

func (h *socialHarness) register(user string) testDevice {
	h.t.Helper()
	d := newTestDevice(user)
	h.expect(h.send(user, "POST", "/v1/devices", d.registration()), 200, "")
	return d
}

func envelopes(devices ...testDevice) []map[string]any {
	result := []map[string]any{}
	for _, d := range devices {
		raw := make([]byte, 64)
		_, _ = rand.Read(raw)
		result = append(result, map[string]any{"deviceId": d.id, "type": 0, "ciphertext": b64.EncodeToString(raw)})
	}
	return result
}

func message(sender testDevice, to ...testDevice) map[string]any {
	return map[string]any{"messageId": uuid.NewString(), "senderDeviceId": sender.id, "envelopes": envelopes(to...)}
}

func TestDeviceKeysAreSignedBoundedAndClaimedOnce(t *testing.T) {
	h := newSocialHarness(t)
	d := h.register(alice)
	h.expect(h.send(alice, "POST", "/v1/devices", d.registration()), 200, "")

	forged := newTestDevice(alice)
	body := forged.registration()
	body["identityKey"] = randomKey()
	h.expect(h.send(alice, "POST", "/v1/devices", body), 422, "VALIDATION")
	// Another account cannot register a statement signed for alice.
	h.expect(h.send(bob, "POST", "/v1/devices", newTestDevice(alice).registration()), 422, "VALIDATION")
	reused := newTestDevice(alice)
	reused.id = d.id
	h.expect(h.send(alice, "POST", "/v1/devices", reused.registration()), 409, "DEVICE_CONFLICT")
	for i := 0; i < 9; i++ {
		h.register(alice)
	}
	h.expect(h.send(alice, "POST", "/v1/devices", newTestDevice(alice).registration()), 409, "TOO_MANY_DEVICES")

	keys := []map[string]string{d.oneTimeKey("k1"), d.oneTimeKey("k2")}
	bad := d.oneTimeKey("k3")
	bad["publicKey"] = randomKey()
	h.expect(h.send(alice, "POST", "/v1/devices/"+d.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{bad}}), 422, "VALIDATION")
	h.expect(h.send(bob, "POST", "/v1/devices/"+d.id+"/keys", map[string]any{"oneTimeKeys": keys}), 404, "NOT_FOUND")
	count := h.expect(h.send(alice, "POST", "/v1/devices/"+d.id+"/keys", map[string]any{"oneTimeKeys": keys, "fallbackKey": d.oneTimeKey("fb")}), 200, "").data
	if count["oneTimeKeyCount"] != float64(2) {
		t.Fatalf("count %v", count)
	}

	// Claims follow messagesFrom; each one-time key goes out once, then the fallback.
	h.expect(h.call(bob, "POST", "/v1/users/"+alice+"/devices/"+d.id+"/claim"), 403, "MESSAGES_NOT_ALLOWED")
	h.expect(h.call(bob, "GET", "/v1/users/"+alice+"/devices"), 403, "MESSAGES_NOT_ALLOWED")
	h.policy(alice, "messagesFrom", "everyone")
	if items := items(h.ok(bob, "GET", "/v1/users/"+alice+"/devices")); len(items) != 10 {
		t.Fatalf("device list has %d entries", len(items))
	}
	seen := map[string]bool{}
	for i := 0; i < 2; i++ {
		claim := h.ok(bob, "POST", "/v1/users/"+alice+"/devices/"+d.id+"/claim")
		if claim["fallback"] != false || seen[claim["keyId"].(string)] {
			t.Fatalf("claim %d wrong: %v", i, claim)
		}
		seen[claim["keyId"].(string)] = true
	}
	if claim := h.ok(bob, "POST", "/v1/users/"+alice+"/devices/"+d.id+"/claim"); claim["fallback"] != true || claim["keyId"] != "fb" {
		t.Fatalf("fallback not used: %v", claim)
	}
	if c := h.ok(alice, "GET", "/v1/devices/"+d.id+"/keys"); c["oneTimeKeyCount"] != float64(0) || c["hasFallbackKey"] != true {
		t.Fatalf("count after claims %v", c)
	}
}

func TestEncryptedRelayDeliversToEveryDeviceAndForgetsCiphertext(t *testing.T) {
	h := newSocialHarness(t)
	phone, laptop := h.register(alice), h.register(alice)
	// Sessions with your own other devices need their keys too.
	h.expect(h.send(alice, "POST", "/v1/devices/"+laptop.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{laptop.oneTimeKey("own")}}), 200, "")
	if claim := h.ok(alice, "POST", "/v1/users/"+alice+"/devices/"+laptop.id+"/claim"); claim["keyId"] != "own" {
		t.Fatalf("own-device claim failed: %v", claim)
	}
	bobPhone := h.register(bob)

	// Default messagesFrom is friends.
	h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 403, "MESSAGES_NOT_ALLOWED")
	h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	convo := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data
	id := convo["conversationId"].(string)
	if again := h.expect(h.send(bob, "POST", "/v1/conversations", map[string]string{"userId": alice}), 200, "").data; again["conversationId"] != id {
		t.Fatal("pair got two conversations")
	}
	path := "/v1/conversations/" + id + "/messages"

	// The envelope set must be exactly the peer's devices plus the sender's others.
	h.expect(h.send(alice, "POST", path, message(phone, bobPhone)), 409, "DEVICES_CHANGED")
	h.expect(h.send(alice, "POST", path, message(phone, bobPhone, laptop, newTestDevice(bob))), 409, "DEVICES_CHANGED")
	h.expect(h.send(alice, "POST", path, message(bobPhone, bobPhone, laptop)), 404, "NOT_FOUND")
	h.expect(h.call(cara, "GET", "/v1/conversations/"+id), 404, "NOT_FOUND")
	h.expect(h.send(cara, "POST", path, message(phone, bobPhone, laptop)), 404, "NOT_FOUND")
	sent := message(phone, bobPhone, laptop)
	first := h.expect(h.send(alice, "POST", path, sent), 200, "").data
	if retry := h.expect(h.send(alice, "POST", path, sent), 200, "").data; retry["createdAt"] != first["createdAt"] {
		t.Fatal("retry was not idempotent")
	}
	stolen := message(bobPhone, phone, laptop)
	stolen["messageId"] = sent["messageId"]
	h.expect(h.send(bob, "POST", path, stolen), 422, "VALIDATION")

	inbox := func(d testDevice) []map[string]any {
		return items(h.ok(d.user, "GET", "/v1/devices/"+d.id+"/inbox"))
	}
	if len(inbox(phone)) != 0 || len(inbox(laptop)) != 1 || len(inbox(bobPhone)) != 1 {
		t.Fatal("envelopes not routed per device")
	}
	got := inbox(bobPhone)[0]
	want := sent["envelopes"].([]map[string]any)[0]
	if got["ciphertext"] != want["ciphertext"] || got["senderDeviceId"] != phone.id || got["senderIdentityKey"] != phone.identity || got["type"] != float64(0) {
		t.Fatalf("envelope altered: %v", got)
	}
	h.expect(h.call(alice, "GET", "/v1/devices/"+bobPhone.id+"/inbox"), 404, "NOT_FOUND")
	h.expect(h.send(alice, "POST", "/v1/devices/"+bobPhone.id+"/inbox/ack", map[string]any{"messageIds": []any{got["messageId"]}}), 200, "")
	if len(inbox(bobPhone)) != 1 {
		t.Fatal("another account acknowledged bob's envelope")
	}
	h.expect(h.send(bob, "POST", "/v1/devices/"+bobPhone.id+"/inbox/ack", map[string]any{"messageIds": []any{got["messageId"]}}), 200, "")
	if len(inbox(bobPhone)) != 0 {
		t.Fatal("acknowledged envelope redelivered")
	}
	var stored *string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT ciphertext FROM message_envelopes WHERE message_id=$1 AND recipient_device_id=$2`, got["messageId"], bobPhone.id).Scan(&stored); err != nil || stored != nil {
		t.Fatalf("ciphertext kept after delivery: %v %v", stored, err)
	}
	if list := items(h.ok(bob, "GET", "/v1/conversations")); len(list) != 1 || list[0]["peer"].(map[string]any)["userId"] != alice {
		t.Fatalf("conversation list wrong: %v", list)
	}

	// Once someone has written, the other side can always reply.
	h.policy(alice, "messagesFrom", "nobody")
	h.expect(h.send(bob, "POST", path, message(bobPhone, phone, laptop)), 200, "")

	// A revoked device stops receiving and must be left out.
	h.ok(alice, "DELETE", "/v1/devices/"+laptop.id)
	h.expect(h.call(alice, "GET", "/v1/devices/"+laptop.id+"/inbox"), 404, "NOT_FOUND")
	h.expect(h.send(bob, "POST", path, message(bobPhone, phone, laptop)), 409, "DEVICES_CHANGED")
	h.expect(h.send(bob, "POST", path, message(bobPhone, phone)), 200, "")

	// Blocking closes the conversation and drops undelivered ciphertext both ways.
	if pending := len(inbox(phone)); pending != 2 {
		t.Fatalf("phone pending %d", pending)
	}
	h.ok(alice, "POST", "/v1/users/"+bob+"/block")
	if len(inbox(phone)) != 0 {
		t.Fatal("blocked sender's ciphertext still delivered")
	}
	h.expect(h.send(bob, "POST", path, message(bobPhone, phone)), 404, "NOT_FOUND")
	if len(items(h.ok(alice, "GET", "/v1/conversations"))) != 0 {
		t.Fatal("blocked conversation still listed")
	}
	h.ok(alice, "DELETE", "/v1/users/"+bob+"/block")
	h.expect(h.send(bob, "POST", path, message(bobPhone, phone)), 403, "CONVERSATION_CLOSED")
}

func TestMessageValidationAndRateLimit(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(bob, "messagesFrom", "everyone")
	mine, theirs := h.register(alice), h.register(bob)
	id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
	path := "/v1/conversations/" + id + "/messages"
	bad := []map[string]any{
		{"messageId": "nope", "senderDeviceId": mine.id, "envelopes": envelopes(theirs)},
		{"messageId": uuid.NewString(), "senderDeviceId": mine.id, "envelopes": []map[string]any{}},
		{"messageId": uuid.NewString(), "senderDeviceId": mine.id, "envelopes": []map[string]any{{"deviceId": theirs.id, "type": 2, "ciphertext": "AAAAAA"}}},
		{"messageId": uuid.NewString(), "senderDeviceId": mine.id, "envelopes": []map[string]any{{"deviceId": theirs.id, "type": 1, "ciphertext": "not base64!"}}},
		{"messageId": uuid.NewString(), "senderDeviceId": mine.id, "envelopes": []map[string]any{{"deviceId": theirs.id, "type": 1, "ciphertext": b64.EncodeToString(make([]byte, 16385))}}},
		{"messageId": uuid.NewString(), "senderDeviceId": mine.id, "envelopes": envelopes(theirs), "plaintext": "hi"},
	}
	for i, body := range bad {
		if got := h.send(alice, "POST", path, body); got.status != 422 {
			t.Fatalf("case %d accepted: %d %s", i, got.status, got.code)
		}
	}
	limited := 0
	for i := 0; i < 80; i++ {
		if h.send(alice, "POST", path, message(mine, theirs)).status == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("message flood never limited")
	}
}
