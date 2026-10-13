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
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/realtime"
)

// socket reads in the background: a timed-out Read closes a coder/websocket
// connection, so waits happen on the channel instead.
type socket struct {
	t      *testing.T
	conn   *websocket.Conn
	events chan map[string]any
	// status is the close code the server sent; it is set before events is closed.
	status websocket.StatusCode
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
	s := &socket{t: t, conn: conn, events: make(chan map[string]any, 32)}
	t.Cleanup(func() { conn.CloseNow() })
	go func() {
		defer close(s.events)
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				s.status = websocket.CloseStatus(err)
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

// closedWith waits for the server to close the socket, skipping any events, and
// returns the close code.
func (s *socket) closedWith() websocket.StatusCode {
	s.t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case _, ok := <-s.events:
			if !ok {
				return s.status
			}
		case <-deadline:
			s.t.Fatal("socket still open")
			return 0
		}
	}
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

func (r *recordingSender) Send(_ context.Context, t push.Target, m push.Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, t.UserID+":"+m.Kind)
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
	h.api.Push = push.NewDispatcher(push.Config{Sender: sender, Online: h.api.RT.Connected, Queue: 16,
		Targets: func(ctx context.Context, users []string) ([]push.Target, error) {
			rows, err := h.api.Store.PushTargets(ctx, users)
			out := make([]push.Target, len(rows))
			for i, r := range rows {
				out[i] = push.Target(r)
			}
			return out, err
		},
		Check: func(ctx context.Context, n push.Notice, category string) (push.Eligibility, error) {
			ok, name, err := h.api.Store.PushAudience(ctx, n.Recipient, n.Actor, n.Conversation, category)
			return push.Eligibility{OK: ok, ActorName: name}, err
		},
		Forget: func(ctx context.Context, t push.Target) error {
			return h.api.Store.ClearPushToken(ctx, t.DeviceID, t.Provider, t.Token)
		}})
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
	if got := sender.list(); got[0] != bob+":friend_request" {
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
	if got := sender.list(); got[1] != bob+":chat" {
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

// A socket lives only as long as its session: signing it out, revoking it, signing out
// everywhere else, expiry and suspension all end it with 1008, and other sessions stay.
func TestRealtimeConnectionsEndWithTheirSession(t *testing.T) {
	h := newSocialHarness(t)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	api := New(h.db, h.db.VerifyDevSession, true, "")
	api.RT = realtime.NewHub(realtime.NewLocalBus(), 10, 100)
	api.heartbeat = 50 * time.Millisecond
	go api.RT.Run(ctx, func(int) time.Duration { return 10 * time.Millisecond })
	server := httptest.NewServer(api.Handler())
	t.Cleanup(server.Close)
	session := func(user, token string) (string, *socket) {
		t.Helper()
		p, err := h.db.CreateDevSession(ctx, user, token, "web")
		if err != nil {
			t.Fatal(err)
		}
		ws, _, err := dial(t, server, token)
		if err != nil {
			t.Fatal(err)
		}
		return p.SessionID, ws
	}
	request := func(method, path, token string) int {
		t.Helper()
		req, _ := http.NewRequest(method, server.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	_, phone := session(alice, "token-phone-0000000001")
	laptopID, laptop := session(alice, "token-laptop-000000001")
	_, tablet := session(alice, "token-tablet-000000001")
	_, bobPhone := session(bob, "token-bob-phone-000001")

	// Revoking one session from another device ends only that socket.
	if status := request("DELETE", "/v1/auth/sessions/"+laptopID, "token-phone-0000000001"); status != 200 {
		t.Fatalf("revoke %d", status)
	}
	if code := laptop.closedWith(); code != websocket.StatusPolicyViolation {
		t.Fatalf("revoked socket closed with %v", code)
	}
	phone.quiet()
	// Sign out everywhere else ends the tablet, not the phone and not another account.
	if status := request("POST", "/v1/auth/sessions/revoke-others", "token-phone-0000000001"); status != 200 {
		t.Fatalf("revoke others %d", status)
	}
	if code := tablet.closedWith(); code != websocket.StatusPolicyViolation {
		t.Fatalf("other socket closed with %v", code)
	}
	phone.quiet()
	bobPhone.quiet()
	// Signing out ends the caller's own socket.
	if status := request("POST", "/v1/auth/logout", "token-phone-0000000001"); status != 200 {
		t.Fatalf("logout %d", status)
	}
	if code := phone.closedWith(); code != websocket.StatusPolicyViolation {
		t.Fatalf("signed-out socket closed with %v", code)
	}
	// Expiry and suspension are found at the next heartbeat.
	expiringID, expiring := session(alice, "token-expiring-0000001")
	h.exec(`UPDATE sessions SET expires_at=now()-interval '1 second' WHERE session_id=$1`, expiringID)
	if code := expiring.closedWith(); code != websocket.StatusPolicyViolation {
		t.Fatalf("expired socket closed with %v", code)
	}
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, bob)
	if code := bobPhone.closedWith(); code != websocket.StatusPolicyViolation {
		t.Fatalf("suspended socket closed with %v", code)
	}
	if _, resp, err := dial(t, server, "token-bob-phone-000001"); err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatalf("suspended account reconnected: %v", err)
	}
}

// The moderation tool is a separate process: suspending through it notifies every API node on
// the realtime channel, in the same transaction, and the hub turns that into a disconnect.
func TestSuspensionNotifiesEveryNodeToEndConnections(t *testing.T) {
	h := newSocialHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := h.db.Pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err = conn.Exec(ctx, `LISTEN `+realtime.Channel); err != nil {
		t.Fatal(err)
	}
	defer conn.Exec(context.Background(), `UNLISTEN *`)
	report := h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "spam"}), 201, "").data["report"].(map[string]any)["reportId"].(string)
	if err = h.db.ResolveReport(ctx, report, "operator", "suspend", ""); err != nil {
		t.Fatal(err)
	}
	n, err := conn.Conn().WaitForNotification(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var e realtime.Event
	if err = json.Unmarshal([]byte(n.Payload), &e); err != nil || len(e.Users) != 1 || e.Users[0] != bob {
		t.Fatalf("notice %s %v", n.Payload, err)
	}
	// Delivered to a hub, the notice ends the user's connections and is never sent to a client.
	hub := realtime.NewHub(realtime.NewLocalBus(), 5, 10)
	runCtx, stop := context.WithCancel(context.Background())
	defer stop()
	go hub.Run(runCtx, func(int) time.Duration { return time.Millisecond })
	bobClient, aliceClient := realtime.NewClient(bob, 4), realtime.NewClient(alice, 4)
	hub.Register(bobClient)
	hub.Register(aliceClient)
	hub.Publish(ctx, e.Type, e.Data, e.Users...)
	select {
	case <-bobClient.Closed:
	case <-time.After(time.Second):
		t.Fatal("suspended user's connection kept")
	}
	if !bobClient.Ended() || len(bobClient.Send) != 0 {
		t.Fatalf("notice reached the client or did not end it")
	}
	select {
	case <-aliceClient.Closed:
		t.Fatal("another user's connection ended")
	default:
	}
}
