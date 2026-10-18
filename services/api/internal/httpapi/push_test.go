package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/push"
)

// pushLog is a Sender that keeps whole messages; errs are returned one per Send call.
type pushLog struct {
	mu   sync.Mutex
	got  []push.Message
	to   []push.Target
	errs []error
}

func (p *pushLog) Send(_ context.Context, t push.Target, m push.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.errs) > 0 {
		err := p.errs[0]
		p.errs = p.errs[1:]
		if err != nil {
			return err
		}
	}
	p.got = append(p.got, m)
	p.to = append(p.to, t)
	return nil
}

func (p *pushLog) messages() []push.Message {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]push.Message(nil), p.got...)
}

// wait waits for n pushes in total and then briefly for stragglers, so "exactly n" means something.
func (p *pushLog) wait(t *testing.T, n int) []push.Message {
	t.Helper()
	eventually(t, func() bool { return len(p.messages()) >= n })
	time.Sleep(60 * time.Millisecond)
	if got := p.messages(); len(got) != n {
		t.Fatalf("got %d pushes, want %d: %+v", len(got), n, got)
	}
	return p.messages()
}

// quiet asserts nothing is (or shortly becomes) pushed beyond the n already counted.
func (p *pushLog) quiet(t *testing.T, n int, why string) {
	t.Helper()
	time.Sleep(100 * time.Millisecond)
	if got := p.messages(); len(got) != n {
		t.Fatalf("%s: pushed %+v", why, got[n:])
	}
}

// pushing wires the production rules (database eligibility, token lookup, forgetting dead tokens)
// around a recording sender, on top of the harness's realtime hub.
func pushing(t *testing.T, h *socialHarness, mutate func(*push.Config)) (*pushLog, *httptest.Server) {
	t.Helper()
	server, _ := withRealtime(t, h)
	log := &pushLog{}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	cfg := push.Config{
		Sender: log, Online: h.api.RT.Connected, Queue: 32, Backoff: func(int) time.Duration { return time.Millisecond },
		Targets: func(ctx context.Context, users []string) ([]push.Target, error) {
			rows, err := h.api.Store.PushTargets(ctx, users)
			out := make([]push.Target, len(rows))
			for i, r := range rows {
				out[i] = push.Target(r)
			}
			return out, err
		},
		Check: func(ctx context.Context, n push.Notice, category string) (push.Eligibility, error) {
			ok, name, err := h.api.Store.PushAudienceFor(ctx, n.Recipient, n.Actor, n.Conversation, category, n.Kind)
			return push.Eligibility{OK: ok, ActorName: name}, err
		},
		Forget: func(ctx context.Context, tg push.Target) error {
			return h.api.Store.ClearPushToken(ctx, tg.DeviceID, tg.Provider, tg.Token)
		},
	}
	if mutate != nil {
		mutate(&cfg)
	}
	h.api.Push = push.NewDispatcher(cfg)
	h.api.Push.Run(ctx, 2)
	return log, server
}

func (h *socialHarness) token(d testDevice, token string) {
	h.t.Helper()
	h.expect(h.send(d.user, "PUT", "/v1/devices/"+d.id+"/push", map[string]string{"provider": "fcm", "token": token}), 200, "")
}

// tokenFor gives user an FCM token on a throwaway device row, without a chat key exchange.
func (h *socialHarness) tokenFor(user string) {
	h.t.Helper()
	h.token(h.register(user), "token-for-"+user[len(user)-4:])
}

func TestChatPushIsGenericAndReachesOnlyThePeersDevices(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	// Alice has a second device with a token; her own message must never wake it.
	tablet := h.register(alice)
	h.token(phone, "alice-phone-token")
	h.token(tablet, "alice-tablet-token")
	h.token(bobPhone, "bob-phone-token")
	log.quiet(t, 0, "friending and registering")

	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone, tablet)), 200, "")
	got := log.wait(t, 1)[0]
	conversation := strings.TrimPrefix(path, "/v1/conversations/")
	if got.Kind != "chat" || got.Title != "Hiyall" || got.Body != "New message" || got.CollapseKey != "chat-"+conversation {
		t.Fatalf("push %+v", got)
	}
	if len(got.Data) != 2 || got.Data["kind"] != "chat" || got.Data["conversationId"] != conversation {
		t.Fatalf("data %v", got.Data)
	}
	raw, _ := json.Marshal(got)
	for _, leak := range []string{"Anjali", "Niko", "anjali", "niko", alice, bob, "ciphertext"} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("payload leaks %q: %s", leak, raw)
		}
	}
	log.mu.Lock()
	defer log.mu.Unlock()
	for _, tg := range log.to {
		if tg.UserID != bob || tg.Token != "bob-phone-token" {
			t.Fatalf("woke %+v", tg)
		}
	}
}

func TestNoPushWhileTheRecipientHasALiveSocket(t *testing.T) {
	h := newSocialHarness(t)
	log, server := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	h.token(bobPhone, "bob-phone-token")
	_, _, err := dial(t, server, bob)
	if err != nil {
		t.Fatal(err)
	}
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	log.quiet(t, 0, "recipient online")
}

// Each rule in turn is switched on and must make the recipient ineligible for a chat push, then
// off again and must restore it. The store decision is the one the dispatcher uses.
func TestChatPushEligibilityRules(t *testing.T) {
	h := newSocialHarness(t)
	path, _, _ := friendsWithChat(h)
	conversation := strings.TrimPrefix(path, "/v1/conversations/")
	patch := func(user string, body map[string]bool) {
		h.expect(h.send(user, "PATCH", "/v1/me/notifications", body), 200, "")
	}
	rules := []struct {
		name    string
		on, off func()
	}{
		{"muted conversation", func() { h.ok(bob, "POST", path+"/mute") }, func() { h.ok(bob, "DELETE", path+"/mute") }},
		{"muted person", func() { h.ok(bob, "POST", "/v1/users/"+alice+"/mute") }, func() { h.ok(bob, "DELETE", "/v1/users/"+alice+"/mute") }},
		{"restricted by the recipient", func() { h.ok(bob, "POST", "/v1/users/"+alice+"/restrict") }, func() { h.ok(bob, "DELETE", "/v1/users/"+alice+"/restrict") }},
		{"recipient restricted by the sender", func() { h.ok(alice, "POST", "/v1/users/"+bob+"/restrict") }, func() { h.ok(alice, "DELETE", "/v1/users/"+bob+"/restrict") }},
		{"chat notifications off", func() { patch(bob, map[string]bool{"chat": false}) }, func() { patch(bob, map[string]bool{"chat": true}) }},
		{"recipient suspended", func() { h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, bob) }, func() { h.exec(`UPDATE users SET status='active' WHERE user_id=$1`, bob) }},
		{"recipient pending deletion", func() {
			h.exec(`UPDATE users SET status='pending_deletion',deletion_scheduled_at=now(),deletion_due_at=now()+interval '1 day' WHERE user_id=$1`, bob)
		}, func() {
			h.exec(`UPDATE users SET status='active',deletion_scheduled_at=NULL,deletion_due_at=NULL WHERE user_id=$1`, bob)
		}},
		{"recipient deleting", func() {
			h.exec(`UPDATE users SET status='deleting',deletion_scheduled_at=now(),deletion_due_at=now() WHERE user_id=$1`, bob)
		}, func() {
			h.exec(`UPDATE users SET status='active',deletion_scheduled_at=NULL,deletion_due_at=NULL WHERE user_id=$1`, bob)
		}},
		{"recipient banned", func() { h.exec(`UPDATE users SET status='banned' WHERE user_id=$1`, bob) }, func() { h.exec(`UPDATE users SET status='active' WHERE user_id=$1`, bob) }},
		{"sender suspended", func() { h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, alice) }, func() { h.exec(`UPDATE users SET status='active' WHERE user_id=$1`, alice) }},
		{"recipient not onboarded", func() { h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, bob) }, func() { h.exec(`UPDATE onboarding SET completed_at=now() WHERE user_id=$1`, bob) }},
		{"blocked by the recipient", func() { h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, bob, alice) }, func() { h.exec(`DELETE FROM blocks`) }},
		{"blocked by the sender", func() { h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, alice, bob) }, func() { h.exec(`DELETE FROM blocks`) }},
		{"other age band", func() { h.ageAt(bob, 15) }, func() { h.ageAt(bob, 30) }},
		{"conversation closed", func() { h.exec(`UPDATE conversations SET status='closed' WHERE conversation_id=$1`, conversation) }, func() { h.exec(`UPDATE conversations SET status='active' WHERE conversation_id=$1`, conversation) }},
	}
	eligible := func(recipient, actor string) bool {
		ok, _, err := h.api.Store.PushAudience(h.ctx, recipient, actor, conversation, "chat")
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	for _, r := range rules {
		if !eligible(bob, alice) {
			t.Fatalf("%s: not eligible to begin with", r.name)
		}
		r.on()
		if eligible(bob, alice) {
			t.Fatalf("%s: still eligible", r.name)
		}
		r.off()
	}
	if !eligible(bob, alice) {
		t.Fatal("rules did not revert")
	}
	// Another member's conversation is never a reason to push: Cara is in no conversation with Alice.
	if ok, _, _ := h.api.Store.PushAudience(h.ctx, cara, alice, conversation, "chat"); ok {
		t.Fatal("non-member eligible for a conversation")
	}
	if ok, _, _ := h.api.Store.PushAudience(h.ctx, bob, cara, conversation, "chat"); ok {
		t.Fatal("conversation with a different peer accepted")
	}
	// The social category ignores the chat switch and mutes of one chat.
	patch(bob, map[string]bool{"chat": false})
	if ok, _, _ := h.api.Store.PushAudience(h.ctx, bob, alice, "", "social"); !ok {
		t.Fatal("chat switch turned social off")
	}
	patch(bob, map[string]bool{"social": false})
	if ok, _, _ := h.api.Store.PushAudience(h.ctx, bob, alice, "", "social"); ok {
		t.Fatal("social still on")
	}
}

// The same rules end to end, through a real send, for the cases where sending still works.
func TestMessagesAreNotPushedWhenSilenced(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	h.token(bobPhone, "bob-phone-token")
	// Bob has written once, so Alice is past the first-contact cap.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	send := func() { h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "") }
	for _, rule := range []struct {
		name    string
		on, off func()
	}{
		{"muted conversation", func() { h.ok(bob, "POST", path+"/mute") }, func() { h.ok(bob, "DELETE", path+"/mute") }},
		{"muted person", func() { h.ok(bob, "POST", "/v1/users/"+alice+"/mute") }, func() { h.ok(bob, "DELETE", "/v1/users/"+alice+"/mute") }},
		{"recipient restricted", func() { h.ok(alice, "POST", "/v1/users/"+bob+"/restrict") }, func() { h.ok(alice, "DELETE", "/v1/users/"+bob+"/restrict") }},
		{"chat switched off", func() {
			h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"chat": false}), 200, "")
		}, func() { h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"chat": true}), 200, "") }},
	} {
		rule.on()
		send()
		log.quiet(t, 0, rule.name)
		rule.off()
	}
	send()
	log.wait(t, 1)
}

func TestChatPushesCoalesceAndAreCapped(t *testing.T) {
	h := newSocialHarness(t)
	var mu sync.Mutex
	now := time.Now()
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	advance := func(d time.Duration) { mu.Lock(); now = now.Add(d); mu.Unlock() }
	log, _ := pushing(t, h, func(c *push.Config) { c.Now = clock; c.DailyCap = 3 })
	path, phone, bobPhone := friendsWithChat(h)
	h.token(bobPhone, "bob-phone-token")
	// Bob has written once, so Alice is past the first-contact cap and can send freely.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	send := func() { h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "") }

	send()
	log.wait(t, 1)
	send()
	send()
	log.quiet(t, 1, "inside the 30 second window")
	advance(31 * time.Second)
	send()
	log.wait(t, 2)
	advance(31 * time.Second)
	send()
	log.wait(t, 3)
	advance(31 * time.Second)
	send()
	log.quiet(t, 3, "daily cap")
	advance(24 * time.Hour)
	send()
	log.wait(t, 4)
}

func TestDeadTokensAreClearedAndRefreshedOnesSurvive(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	path, phone, bobPhone := friendsWithChat(h)
	h.token(bobPhone, "bob-old-token")
	log.errs = []error{fmt.Errorf("%w: gone", push.ErrUnregistered)}
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	eventually(t, func() bool {
		targets, err := h.api.Store.PushTargets(h.ctx, []string{bob})
		return err == nil && len(targets) == 0
	})
	log.quiet(t, 0, "a dead token")

	// A token the app refreshed in the meantime is not wiped by a late report about the old one.
	h.token(bobPhone, "bob-new-token")
	if err := h.api.Store.ClearPushToken(h.ctx, bobPhone.id, "fcm", "bob-old-token"); err != nil {
		t.Fatal(err)
	}
	if targets, _ := h.api.Store.PushTargets(h.ctx, []string{bob}); len(targets) != 1 || targets[0].Token != "bob-new-token" {
		t.Fatalf("targets %v", targets)
	}
}

func TestSocialPushesNameTheActorOnlyWhenTheyAreVisible(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	h.tokenFor(bob)
	h.tokenFor(cara)
	h.tokenFor(alice)

	// Open follow: Bob hears that Anjali followed him.
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	m := log.wait(t, 1)[0]
	if m.Kind != "follow" || m.Title != "Hiyall" || m.Body != "Anjali started following you" || m.Data["kind"] != "social" || m.Data["event"] != "follow" || len(m.Data) != 2 {
		t.Fatalf("follow push %+v", m)
	}
	// Follow on approval: a request, then the acceptance goes back to the requester.
	h.policy(bob, "followPolicy", "approval")
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	if m = log.wait(t, 2)[1]; m.Kind != "follow_request" || m.Body != "Cara asked to follow you" {
		t.Fatalf("follow request push %+v", m)
	}
	h.ok(bob, "POST", "/v1/users/"+cara+"/follow-requests/accept")
	if m = log.wait(t, 3)[2]; m.Kind != "follow_accepted" || m.Body != "Niko accepted your follow request" {
		t.Fatalf("follow accepted push %+v", m)
	}
	// Friend request and its acceptance.
	h.ok(cara, "POST", "/v1/users/"+alice+"/friend-requests")
	if m = log.wait(t, 4)[3]; m.Kind != "friend_request" || m.Body != "Cara sent you a friend request" {
		t.Fatalf("friend request push %+v", m)
	}
	req := h.ok(alice, "GET", "/v1/me/friend-requests")
	id := items(req)[0]["requestId"].(string)
	h.ok(alice, "POST", "/v1/friend-requests/"+id+"/accept")
	if m = log.wait(t, 5)[4]; m.Kind != "friend_accepted" || m.Body != "Anjali accepted your friend request" {
		t.Fatalf("friend accepted push %+v", m)
	}
}

func TestReactionsAndCommentsArePushedAsGenericOrNamedLines(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	h.tokenFor(alice)
	h.policy(alice, "followPolicy", "everyone")
	h.policy(alice, "commentsFrom", "everyone")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	log.wait(t, 1) // the follow itself
	post := h.post(alice, "followers", "hello")
	h.expect(h.send(bob, "PUT", "/v1/posts/"+post+"/reaction", map[string]string{"reaction": "heart"}), 200, "")
	h.expect(h.send(bob, "POST", "/v1/posts/"+post+"/comments", map[string]string{"body": "nice"}), 201, "")
	got := log.wait(t, 3)
	if got[1].Kind != "reaction" || got[1].Body != "Niko reacted to your post" || got[2].Kind != "comment" || got[2].Body != "Niko commented on your post" {
		t.Fatalf("pushes %+v", got)
	}
	// Neither carries the post's text or the comment, and they are still listed for Alice.
	for _, m := range got[1:] {
		if strings.Contains(m.Body, "hello") || strings.Contains(m.Body, "nice") {
			t.Fatalf("content in a push: %+v", m)
		}
	}
	if n := h.ok(alice, "GET", "/v1/notifications"); len(items(n)) < 2 {
		t.Fatalf("activity %v", n)
	}
}

func TestSocialPushRulesFollowTheRecipientsChoicesAndSafety(t *testing.T) {
	h := newSocialHarness(t)
	log, _ := pushing(t, h, nil)
	h.tokenFor(bob)
	h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"social": false}), 200, "")
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	log.quiet(t, 0, "social switched off")
	h.ok(alice, "DELETE", "/v1/users/"+bob+"/follow")
	h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"social": true}), 200, "")
	h.ok(bob, "POST", "/v1/users/"+alice+"/mute")
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	log.quiet(t, 0, "muted actor")
	h.ok(alice, "DELETE", "/v1/users/"+bob+"/follow")
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/mute")
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	log.wait(t, 1)
	// The actor's own follow of themselves is refused, and a push to oneself is never queued.
	h.api.Push.Notify(push.Notice{Kind: "follow", Actor: bob, Recipient: bob})
	log.quiet(t, 1, "self")
}

func TestNotificationPreferencesAPI(t *testing.T) {
	h := newSocialHarness(t)
	if got := h.ok(bob, "GET", "/v1/me/notifications"); got["chat"] != true || got["social"] != true {
		t.Fatalf("defaults %v", got)
	}
	h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"chat": false}), 200, "")
	if got := h.ok(bob, "GET", "/v1/me/notifications"); got["chat"] != false || got["social"] != true {
		t.Fatalf("after chat off %v", got)
	}
	// A key left out keeps its value.
	if got := h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"social": false}), 200, "").data; got["chat"] != false || got["social"] != false {
		t.Fatalf("patch social %v", got)
	}
	if got := h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"chat": true, "social": true}), 200, "").data; got["chat"] != true || got["social"] != true {
		t.Fatalf("both on %v", got)
	}
	// Nobody else's choices change, and bad bodies are refused.
	h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]bool{"chat": false}), 200, "")
	if got := h.ok(alice, "GET", "/v1/me/notifications"); got["chat"] != true {
		t.Fatalf("alice affected: %v", got)
	}
	for _, body := range []any{map[string]bool{}, map[string]string{"chat": "yes"}, map[string]any{"chat": nil}, map[string]bool{"marketing": true}, map[string]any{"chat": true, "other": 1}} {
		h.expect(h.send(bob, "PATCH", "/v1/me/notifications", body), 422, "VALIDATION")
	}
}
