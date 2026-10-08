package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"kairova/services/api/internal/push"
	"kairova/services/api/internal/realtime"
)

// socket reads in the background: a timed-out Read closes a coder/websocket
// connection, so waits happen on the channel instead.
type socket struct {
	t      *testing.T
	conn   *websocket.Conn
	events chan map[string]any
}

func dial(t *testing.T, server *httptest.Server, token string) (*socket, *http.Response, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	conn, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/realtime", &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		return nil, resp, err
	}
	s := &socket{t, conn, make(chan map[string]any, 32)}
	t.Cleanup(func() { conn.CloseNow() })
	go func() {
		defer close(s.events)
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				return
			}
			var e map[string]any
			_ = json.Unmarshal(data, &e)
			s.events <- e
		}
	}()
	if e := s.next(); e["type"] != "ready" {
		t.Fatalf("first event %v", e)
	}
	return s, resp, nil
}

// next returns the next event, failing after two seconds.
func (s *socket) next() map[string]any {
	s.t.Helper()
	select {
	case e, ok := <-s.events:
		if !ok {
			s.t.Fatal("socket closed")
		}
		return e
	case <-time.After(2 * time.Second):
		s.t.Fatal("no event")
	}
	return nil
}

// quiet asserts nothing arrives for a short while.
func (s *socket) quiet() {
	s.t.Helper()
	select {
	case e := <-s.events:
		s.t.Fatalf("unexpected event %v", e)
	case <-time.After(300 * time.Millisecond):
	}
}

func (s *socket) write(v any) {
	raw, _ := json.Marshal(v)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := s.conn.Write(ctx, websocket.MessageText, raw); err != nil {
		s.t.Fatal(err)
	}
}

type recordingSender struct {
	mu   sync.Mutex
	sent []string
}

func (r *recordingSender) Send(_ context.Context, t push.Target, kind string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, t.UserID+":"+kind)
	return nil
}

func (r *recordingSender) list() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.sent...)
}

func withRealtime(t *testing.T, h *socialHarness) (*httptest.Server, *recordingSender) {
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	h.api.RT = realtime.NewHub(realtime.NewLocalBus(), 2, 100)
	go h.api.RT.Run(ctx, func(int) time.Duration { return 10 * time.Millisecond })
	sender := &recordingSender{}
	h.api.Push = push.NewDispatcher(sender, func(ctx context.Context, users []string) ([]push.Target, error) {
		rows, err := h.api.Store.PushTargets(ctx, users)
		out := make([]push.Target, len(rows))
		for i, r := range rows {
			out[i] = push.Target(r)
		}
		return out, err
	}, h.api.RT.Connected, 16)
	h.api.Push.Run(ctx, 1)
	server := httptest.NewServer(h.api.Handler())
	t.Cleanup(server.Close)
	return server, sender
}

func eventually(t *testing.T, check func() bool) {
	t.Helper()
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if check() {
			return
		}
	}
	t.Fatal("condition not met in time")
}

func TestRealtimeSignalsMessagesReadsTypingAndActivity(t *testing.T) {
	h := newSocialHarness(t)
	server, sender := withRealtime(t, h)

	if _, resp, err := dial(t, server, ""); err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatalf("unauthenticated socket accepted: %v", err)
	}
	if _, resp, err := dial(t, server, "not-a-user"); err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatalf("bad token accepted: %v", err)
	}

	phone, bobPhone := h.register(alice), h.register(bob)
	h.expect(h.send(bobPhone.user, "PUT", "/v1/devices/"+bobPhone.id+"/push", map[string]string{"provider": "fcm", "token": "bob-token-123"}), 200, "")
	h.expect(h.send(alice, "PUT", "/v1/devices/"+bobPhone.id+"/push", map[string]string{"provider": "fcm", "token": "steal-1234"}), 404, "NOT_FOUND")
	h.expect(h.send(bob, "PUT", "/v1/devices/"+bobPhone.id+"/push", map[string]string{"provider": "sms", "token": "x"}), 422, "VALIDATION")

	// Bob is offline: a friend request reaches him by push, with no content.
	h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	eventually(t, func() bool { return len(sender.list()) == 1 })
	if got := sender.list(); got[0] != bob+":activity" {
		t.Fatalf("push %v", got)
	}

	aliceWS, _, err := dial(t, server, alice)
	if err != nil {
		t.Fatal(err)
	}
	bobWS, _, err := dial(t, server, bob)
	if err != nil {
		t.Fatal(err)
	}
	// Bob's crossing request makes them friends and signals Alice, who is
	// online, so no push is sent to her.
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	if e := aliceWS.next(); e["type"] != "activity" {
		t.Fatalf("alice got %v", e)
	}

	id := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
	path := "/v1/conversations/" + id
	sent := h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "").data
	for _, ws := range []*socket{aliceWS, bobWS} {
		if e := ws.next(); e["type"] != "inbox" || e["data"].(map[string]any)["conversationId"] != id {
			t.Fatalf("inbox signal %v", e)
		}
	}
	// Signals never carry message content or ciphertext.
	for _, ws := range []*socket{aliceWS, bobWS} {
		ws.quiet()
	}
	if c := h.ok(bob, "GET", path); c["unreadCount"] != float64(1) || c["peerReadAt"] != nil {
		t.Fatalf("bob's view %v", c)
	}
	if u := h.ok(bob, "GET", "/v1/conversations/unread"); u["messages"] != float64(1) || u["conversations"] != float64(1) {
		t.Fatalf("unread %v", u)
	}
	if c := h.ok(alice, "GET", path); c["unreadCount"] != float64(0) {
		t.Fatalf("sender's own message counted unread: %v", c)
	}

	// Receipts are off by default: Bob's own devices learn of the read, Alice does not.
	h.expect(h.send(bob, "POST", path+"/read", map[string]any{"readAt": sent["createdAt"]}), 200, "")
	if e := bobWS.next(); e["type"] != "read" {
		t.Fatalf("bob read signal %v", e)
	}
	aliceWS.quiet()
	if u := h.ok(bob, "GET", "/v1/conversations/unread"); u["messages"] != float64(0) {
		t.Fatalf("still unread %v", u)
	}
	// Reading the same point again changes nothing and signals nothing.
	h.expect(h.send(bob, "POST", path+"/read", map[string]any{"readAt": sent["createdAt"]}), 200, "")
	bobWS.quiet()
	bobWS.write(map[string]string{"type": "typing", "conversationId": id})
	aliceWS.quiet()

	// With receipts on for both, reads and typing reach the peer.
	h.policy(alice, "readReceipts", true)
	h.policy(bob, "readReceipts", true)
	next := h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "").data
	aliceWS.next()
	bobWS.next()
	h.expect(h.send(bob, "POST", path+"/read", map[string]any{"readAt": next["createdAt"]}), 200, "")
	bobWS.next()
	if e := aliceWS.next(); e["type"] != "read" || e["data"].(map[string]any)["userId"] != bob {
		t.Fatalf("peer read signal %v", e)
	}
	if c := h.ok(alice, "GET", path); c["peerReadAt"] == nil {
		t.Fatalf("peerReadAt missing with receipts on: %v", c)
	}
	bobWS.write(map[string]string{"type": "typing", "conversationId": id})
	if e := aliceWS.next(); e["type"] != "typing" || e["data"].(map[string]any)["userId"] != bob {
		t.Fatalf("typing %v", e)
	}
	// Outsiders cannot type into, read or mark a conversation.
	caraWS, _, err := dial(t, server, cara)
	if err != nil {
		t.Fatal(err)
	}
	caraWS.write(map[string]string{"type": "typing", "conversationId": id})
	aliceWS.quiet()
	h.expect(h.send(cara, "POST", path+"/read", map[string]any{"readAt": next["createdAt"]}), 404, "NOT_FOUND")
	h.expect(h.send(bob, "POST", path+"/read", map[string]any{}), 422, "VALIDATION")
	h.expect(h.send(bob, "POST", "/v1/devices/"+bobPhone.id+"/inbox/ack", map[string]any{"messageIds": []string{"nope"}}), 422, "VALIDATION")

	// Two sockets per account in this test; a third is refused, not queued.
	if _, _, err := dial(t, server, alice); err != nil {
		t.Fatal(err)
	}
	if _, resp, err := dial(t, server, alice); err == nil || resp == nil || resp.StatusCode != 503 {
		t.Fatalf("connection limit not enforced: %v", err)
	}

	// Once Bob disconnects, a message wakes his phone instead.
	bobWS.conn.Close(websocket.StatusNormalClosure, "")
	eventually(t, func() bool { return !h.api.RT.Connected(bob) })
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	eventually(t, func() bool { return len(sender.list()) == 2 })
	if got := sender.list(); got[1] != bob+":message" {
		t.Fatalf("push %v", got)
	}
	// Revoking the device removes its token.
	h.ok(bob, "DELETE", "/v1/devices/"+bobPhone.id)
	if targets, err := h.api.Store.PushTargets(context.Background(), []string{bob}); err != nil || len(targets) != 0 {
		t.Fatalf("revoked device still targeted: %v %v", targets, err)
	}
}

func TestSlowClientsAreDisconnectedNotBuffered(t *testing.T) {
	hub := realtime.NewHub(realtime.NewLocalBus(), 5, 10)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go hub.Run(ctx, func(int) time.Duration { return time.Millisecond })
	slow := realtime.NewClient("u", 2)
	if !hub.Register(slow) {
		t.Fatal("register")
	}
	for range 3 {
		hub.Publish(ctx, "inbox", nil, "u")
	}
	select {
	case <-slow.Closed:
	case <-time.After(time.Second):
		t.Fatal("slow client kept")
	}
	hub.Unregister(slow)
	if hub.Count() != 0 || hub.Connected("u") {
		t.Fatal("not unregistered")
	}
	for range 10 {
		if !hub.Register(realtime.NewClient("v"+time.Now().String(), 1)) {
			t.Fatal("under node limit refused")
		}
	}
	if hub.Register(realtime.NewClient("w", 1)) {
		t.Fatal("node limit not enforced")
	}
}
