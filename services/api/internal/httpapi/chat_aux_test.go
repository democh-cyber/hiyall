package httpapi

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/time/rate"
	"hiyall/services/api/internal/push"
)

// Reactions are relayed as ordinary ciphertext, flagged `aux: "reaction"` by the sender because the relay
// cannot read message kinds. These tests pin what the flag changes (nothing the peer is alerted by) and
// what it must never change (every gate, idempotency, the send limiters).

func auxMessage(sender testDevice, to ...testDevice) map[string]any {
	m := message(sender, to...)
	m["aux"] = "reaction"
	return m
}

type convoState struct {
	unread    float64
	last      any
	sortAt    string
	readAt    any
	unreadAll float64
}

func (h *socialHarness) convoState(user, path string) convoState {
	h.t.Helper()
	c := h.ok(user, "GET", path)
	var sortAt string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT sort_at::text FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, strings.TrimPrefix(path, "/v1/conversations/"), user).Scan(&sortAt); err != nil {
		h.t.Fatal(err)
	}
	return convoState{unread: c["unreadCount"].(float64), last: c["lastMessageAt"], sortAt: sortAt, readAt: c["readAt"],
		unreadAll: h.ok(user, "GET", "/v1/conversations/unread")["messages"].(float64)}
}

func TestAuxMessageIsDeliveredButNeverUnreadNeverPushedNeverReorders(t *testing.T) {
	h := newSocialHarness(t)
	var mu sync.Mutex
	now := time.Now()
	log, _ := pushing(t, h, func(c *push.Config) { c.Now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now } })
	path, phone, bobPhone := friendsWithChat(h)
	h.token(phone, "alice-phone-token")
	h.token(bobPhone, "bob-phone-token")

	// An ordinary message: unread for Bob, a push, the list key moves.
	first := h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "").data
	log.wait(t, 1)
	beforeBob, beforeAlice := h.convoState(bob, path), h.convoState(alice, path)
	if beforeBob.unread != 1 || beforeBob.unreadAll != 1 || beforeBob.last == nil {
		t.Fatalf("ordinary message not counted: %+v", beforeBob)
	}

	// Bob reacts, then Alice reacts back: neither changes unread, the sort key, last_message_at or pushes.
	time.Sleep(20 * time.Millisecond)
	h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
	log.quiet(t, 1, "reactions")
	if got := h.convoState(bob, path); got != beforeBob {
		t.Fatalf("bob's conversation changed by reactions: %+v -> %+v", beforeBob, got)
	}
	if got := h.convoState(alice, path); got != beforeAlice {
		t.Fatalf("alice's conversation changed by reactions: %+v -> %+v", beforeAlice, got)
	}

	// Still delivered: one envelope for the ordinary message and one reaction for each device.
	inbox := func(d testDevice) []map[string]any { return items(h.ok(d.user, "GET", "/v1/devices/"+d.id+"/inbox")) }
	if len(inbox(bobPhone)) != 2 || len(inbox(phone)) != 1 {
		t.Fatalf("reactions were not delivered: bob %d alice %d", len(inbox(bobPhone)), len(inbox(phone)))
	}

	// Reading up to the ordinary message leaves nothing unread: the recount skips reactions too.
	h.expect(h.send(bob, "POST", path+"/read", map[string]any{"readAt": first["createdAt"]}), 200, "")
	if got := h.convoState(bob, path); got.unread != 0 || got.unreadAll != 0 {
		t.Fatalf("reaction counted by the unread recount: %+v", got)
	}

	// Old clients send no aux and are unchanged: unread, push and the list key all move.
	mu.Lock()
	now = now.Add(31 * time.Second) // past the push coalescing window
	mu.Unlock()
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	log.wait(t, 2)
	if got := h.convoState(bob, path); got.unread != 1 || got.sortAt == beforeBob.sortAt {
		t.Fatalf("ordinary message after reactions: %+v", got)
	}
	var aux, plain int
	h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FILTER (WHERE aux), count(*) FILTER (WHERE NOT aux) FROM messages WHERE conversation_id=$1`, strings.TrimPrefix(path, "/v1/conversations/")).Scan(&aux, &plain)
	if aux != 2 || plain != 2 {
		t.Fatalf("stored %d aux, %d plain", aux, plain)
	}
}

// A reaction still wakes the peer's devices through the realtime inbox event, so it is fetched at once.
func TestAuxMessageStillSignalsTheInbox(t *testing.T) {
	h := newSocialHarness(t)
	server, sender := withRealtime(t, h)
	path, phone, bobPhone := friendsWithChat(h)
	h.token(bobPhone, "bob-phone-token")
	aliceWS, _, err := dial(t, server, alice)
	if err != nil {
		t.Fatal(err)
	}
	bobWS, _, err := dial(t, server, bob)
	if err != nil {
		t.Fatal(err)
	}
	// Drain the activity signals from becoming friends.
	time.Sleep(50 * time.Millisecond)
	before := len(sender.list())
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
	id := strings.TrimPrefix(path, "/v1/conversations/")
	for _, ws := range []*socket{aliceWS, bobWS} {
		for {
			e := ws.next()
			if e["type"] == "inbox" && e["data"].(map[string]any)["conversationId"] == id {
				break
			}
		}
	}
	if len(sender.list()) != before {
		t.Fatalf("a reaction pushed: %v", sender.list())
	}
}

func TestAuxMessageStillPassesEveryGate(t *testing.T) {
	t.Run("block", func(t *testing.T) {
		h := newSocialHarness(t)
		path, phone, bobPhone := friendsWithChat(h)
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
		h.ok(alice, "POST", "/v1/users/"+bob+"/block")
		h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 404, "NOT_FOUND")
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 404, "NOT_FOUND")
		h.ok(alice, "DELETE", "/v1/users/"+bob+"/block")
		h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 403, "CONVERSATION_CLOSED")
	})
	t.Run("age band", func(t *testing.T) {
		h := newSocialHarness(t)
		h.setAge(alice, 30)
		h.setAge(bob, 31)
		path, phone, bobPhone := friendsWithChat(h)
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
		h.setAge(bob, 15)
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 404, "NOT_FOUND")
		h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 404, "NOT_FOUND")
	})
	t.Run("messagesFrom", func(t *testing.T) {
		h := newSocialHarness(t)
		phone, bobPhone := h.register(alice), h.register(bob)
		id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
		path := "/v1/conversations/" + id + "/messages"
		h.policy(bob, "messagesFrom", "nobody")
		h.expect(h.send(alice, "POST", path, auxMessage(phone, bobPhone)), 403, "MESSAGES_NOT_ALLOWED")
		// A reaction from Bob is not "Bob replied": it does not unlock Alice's messages.
		h.expect(h.send(bob, "POST", path, auxMessage(bobPhone, phone)), 200, "")
		h.expect(h.send(alice, "POST", path, message(phone, bobPhone)), 403, "MESSAGES_NOT_ALLOWED")
		h.expect(h.send(alice, "POST", path, auxMessage(phone, bobPhone)), 403, "MESSAGES_NOT_ALLOWED")
		// A real message from Bob does.
		h.expect(h.send(bob, "POST", path, message(bobPhone, phone)), 200, "")
		h.expect(h.send(alice, "POST", path, message(phone, bobPhone)), 200, "")
	})
	t.Run("exact device set", func(t *testing.T) {
		h := newSocialHarness(t)
		path, phone, bobPhone := friendsWithChat(h)
		tablet := h.register(alice)
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 409, "DEVICES_CHANGED")
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone, tablet)), 200, "")
	})
}

// A reaction is not the "reply" that lets the other side send photos.
func TestReactionDoesNotUnlockImages(t *testing.T) {
	e := newBlobEnv(t)
	content := noise(400)
	e.expect(e.send(alice, "POST", e.messagesPathA, message(e.a, e.b)), 200, "")
	e.expect(e.send(bob, "POST", e.messagesPathA, auxMessage(e.b, e.a)), 200, "")
	e.expect(e.slot(alice, e.convo, "full", content), 403, "ATTACHMENTS_NOT_ALLOWED")
	e.expect(e.send(bob, "POST", e.messagesPathA, message(e.b, e.a)), 200, "")
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")
}

func TestAuxMessagesHaveTheirOwnBoundaryAndStillUseTheSendLimiter(t *testing.T) {
	t.Run("60 per conversation then 429", func(t *testing.T) {
		h := newSocialHarness(t)
		h.api.messages = newKeyedLimiter(rate.Limit(10000), 10000, 16) // isolate the aux limiter
		path, phone, bobPhone := friendsWithChat(h)
		// Bob has written, so the first-contact cap (which counts reactions too) no longer applies.
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
		for i := 0; i < 60; i++ {
			h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
		}
		// Retry-After is present and within the 10 seconds it takes to earn one token back.
		status, header, _ := h.full(alice, "POST", path+"/messages", "application/json", mustJSON(auxMessage(phone, bobPhone)))
		after, _ := strconv.Atoi(header.Get("Retry-After"))
		if status != 429 || after < 1 || after > 10 {
			t.Fatalf("status %d, Retry-After %q", status, header.Get("Retry-After"))
		}
		h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 429, "RATE_LIMITED")
		// Ordinary messages in the same conversation, the peer's reactions and another conversation are untouched.
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
		h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 200, "")
	})
	t.Run("a reaction also spends the normal send limiter", func(t *testing.T) {
		h := newSocialHarness(t)
		path, phone, bobPhone := friendsWithChat(h)
		h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
		ok := 0
		for i := 0; i < 55; i++ {
			if h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)).status == 200 {
				ok++
			}
		}
		// The normal limiter has a burst of 40 (plus a little refill): reactions cannot dodge it.
		if ok < 40 || ok >= 55 {
			t.Fatalf("%d reactions got through in a burst; the normal send limiter should stop them near 40", ok)
		}
		// And it is shared: ordinary messages are limited right after.
		h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 429, "RATE_LIMITED")
	})
}

func TestAuxMessageEnvelopesAreCappedAtTwoKiB(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	sized := func(n int, aux bool) map[string]any {
		m := message(phone, bobPhone)
		m["envelopes"] = []map[string]any{{"deviceId": bobPhone.id, "type": 1, "ciphertext": b64.EncodeToString(make([]byte, n))}}
		if aux {
			m["aux"] = "reaction"
		}
		return m
	}
	h.expect(h.send(alice, "POST", path+"/messages", sized(2048, true)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", sized(2049, true)), 413, "TOO_LARGE")
	// The cap belongs to reactions only: an ordinary message of the same size is fine.
	h.expect(h.send(alice, "POST", path+"/messages", sized(2049, false)), 200, "")
	h.expect(h.send(alice, "POST", path+"/messages", sized(16384, false)), 200, "")
}

func TestAuxFieldIsValidated(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	for name, value := range map[string]any{"unknown": "typing", "boolean": true, "empty": "", "number": 1, "null": nil, "uppercase": "Reaction"} {
		m := message(phone, bobPhone)
		m["aux"] = value
		got := h.send(alice, "POST", path+"/messages", m)
		// An empty string and null mean "not aux" and are accepted as ordinary messages.
		if name == "empty" || name == "null" {
			if got.status != 200 {
				t.Fatalf("%s: %d %s", name, got.status, got.code)
			}
			continue
		}
		if got.status != 422 {
			t.Fatalf("%s accepted: %d %s", name, got.status, got.code)
		}
	}
	// A reaction carries no attachments.
	m := auxMessage(phone, bobPhone)
	m["blobIds"] = []string{"019a4000-0000-7000-8000-00000000aaaa"}
	h.expect(h.send(alice, "POST", path+"/messages", m), 422, "VALIDATION")
}

func TestAuxMessageIsIdempotentAndStaysQuiet(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	h.token(bobPhone, "bob-phone-token")
	sent := auxMessage(phone, bobPhone)
	first := h.expect(h.send(alice, "POST", path+"/messages", sent), 200, "").data
	// A retry, even one that forgets the flag, is answered from the stored row, stays quiet and adds nothing.
	retry := h.expect(h.send(alice, "POST", path+"/messages", sent), 200, "").data
	delete(sent, "aux")
	forgetful := h.expect(h.send(alice, "POST", path+"/messages", sent), 200, "").data
	if retry["createdAt"] != first["createdAt"] || forgetful["createdAt"] != first["createdAt"] {
		t.Fatal("retry was not idempotent")
	}
	log.quiet(t, 0, "reaction retries")
	var rows, envelopes int
	h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM messages WHERE message_id=$1`, sent["messageId"]).Scan(&rows)
	h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM message_envelopes WHERE message_id=$1`, sent["messageId"]).Scan(&envelopes)
	if rows != 1 || envelopes != 1 {
		t.Fatalf("%d rows, %d envelopes", rows, envelopes)
	}
	// The id cannot be taken over by the peer.
	stolen := auxMessage(bobPhone, phone)
	stolen["messageId"] = sent["messageId"]
	h.expect(h.send(bob, "POST", path+"/messages", stolen), 422, "VALIDATION")
}

// An aux flag a sender sets on an ordinary message only silences it for the peer; it cannot reach any
// state beyond what a quiet message already could, and it buys no extra sending capacity.
func TestLyingAboutAuxOnlySilencesYourOwnMessage(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 200, "")
	if got := h.convoState(bob, path); got.unread != 0 || got.last != nil {
		t.Fatalf("%+v", got)
	}
	// It is still bound by the sender's gates (a block stops it) and delivered to exactly the right devices.
	h.ok(bob, "POST", "/v1/users/"+alice+"/block")
	h.expect(h.send(alice, "POST", path+"/messages", auxMessage(phone, bobPhone)), 404, "NOT_FOUND")
}

// Reactions are not messages anyone can report: selecting one as evidence drops it, never an error, and
// the real messages beside it are kept.
func TestReportEvidenceIgnoresReactions(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	real := h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "").data["messageId"].(string)
	react := h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 200, "").data["messageId"].(string)
	convo := strings.TrimPrefix(path, "/v1/conversations/")
	at := time.Now().UTC().Format(time.RFC3339)
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{
		"targetType": "conversation", "targetId": convo, "reasonCode": "threats", "disclosureConsent": true,
		"evidence": []map[string]any{
			{"messageId": real, "text": "the words", "sentAt": at},
			{"messageId": react, "text": "❤️", "sentAt": at},
		},
	}), 201, "")
	queue, err := h.db.ReportQueue(h.ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(queue) != 1 || len(queue[0].Evidence) != 1 || queue[0].Evidence[0].MessageID != real {
		t.Fatalf("evidence %+v", queue)
	}
}

// The OpenAPI generator names the new field (the generated JSON is rebuilt by scripts/check.sh).
func TestContractGeneratorDescribesAux(t *testing.T) {
	raw, err := os.ReadFile("../../../../scripts/build_foundation_contract.py")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "schemas['EncryptedMessageSend']['properties']['aux']") || !strings.Contains(string(raw), "'enum':['reaction']") {
		t.Fatal("contract generator does not describe aux")
	}
}

func mustJSON(v any) string {
	raw, _ := json.Marshal(v)
	return string(raw)
}
