package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/metrics"
)

const (
	alice = "019a4000-0000-7000-8000-000000000001"
	bob   = "019a4000-0000-7000-8000-000000000002"
	conv1 = "019a4000-0000-7000-8000-0000000000c1"
	conv2 = "019a4000-0000-7000-8000-0000000000c2"
)

type fakeSender struct {
	mu   sync.Mutex
	sent []Message
	to   []Target
	errs []error // consumed one per Send call; nil or exhausted means success
	n    int
}

func (f *fakeSender) Send(_ context.Context, t Target, m Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.n++
	if len(f.errs) > 0 {
		err := f.errs[0]
		f.errs = f.errs[1:]
		if err != nil {
			return err
		}
	}
	f.sent = append(f.sent, m)
	f.to = append(f.to, t)
	return nil
}

func (f *fakeSender) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.n
}

func (f *fakeSender) delivered() []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Message(nil), f.sent...)
}

type harness struct {
	mu       sync.Mutex // the fakes below are called from workers in the tests that start them
	d        *Dispatcher
	sender   *fakeSender
	now      time.Time
	online   map[string]bool
	verdict  Eligibility
	checkErr error
	checked  int
	forgot   []Target
	asked    [][]string
}

// newHarness wires a Dispatcher to fakes. Tests call process directly, so nothing runs concurrently
// unless a test starts workers itself.
func newHarness(t *testing.T, mutate func(*Config)) *harness {
	t.Helper()
	h := &harness{sender: &fakeSender{}, now: time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC), online: map[string]bool{}, verdict: Eligibility{OK: true, ActorName: "Alex"}}
	cfg := Config{
		Sender: h.sender,
		Targets: func(_ context.Context, users []string) ([]Target, error) {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.asked = append(h.asked, users)
			var out []Target
			for _, u := range users {
				out = append(out, Target{UserID: u, DeviceID: "dev-" + u[len(u)-1:], Provider: "fcm", Token: "token-" + u[len(u)-1:]})
			}
			return out, nil
		},
		Online: func(u string) bool { h.mu.Lock(); defer h.mu.Unlock(); return h.online[u] },
		Check: func(context.Context, Notice, string) (Eligibility, error) {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.checked++
			return h.verdict, h.checkErr
		},
		Forget: func(_ context.Context, tg Target) error {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.forgot = append(h.forgot, tg)
			return nil
		},
		Backoff: func(int) time.Duration { return 0 },
		Now:     func() time.Time { return h.now },
	}
	if mutate != nil {
		mutate(&cfg)
	}
	h.d = NewDispatcher(cfg)
	return h
}

// drain runs every queued notice on this goroutine.
func (h *harness) drain() {
	for {
		select {
		case n := <-h.d.jobs:
			h.d.process(context.Background(), n)
		default:
			return
		}
	}
}

func chat(conv string) Notice {
	return Notice{Kind: "chat", Actor: alice, Recipient: bob, Conversation: conv}
}

func TestOnlyAllowlistedKindsAreQueued(t *testing.T) {
	h := newHarness(t, nil)
	for _, n := range []Notice{
		{Kind: "post.reacted", Actor: alice, Recipient: bob},
		{Kind: "story_reaction", Actor: alice, Recipient: bob},
		{Kind: "activity", Actor: alice, Recipient: bob},
		{Kind: "", Actor: alice, Recipient: bob},
		{Kind: "chat", Actor: alice, Recipient: bob}, // chat needs its conversation
		{Kind: "follow", Actor: alice, Recipient: alice},
		{Kind: "follow", Actor: alice},
	} {
		h.d.Notify(n)
	}
	if got := h.d.Stats().Queued; got != 0 {
		t.Fatalf("queued %d", got)
	}
	for _, kind := range []string{"chat", "friend_request", "friend_accepted", "follow", "follow_request", "follow_accepted", "space_invite"} {
		if !Allowed(kind) || CategoryOf(kind) == "" {
			t.Fatalf("%s not allowed", kind)
		}
	}
	for _, kind := range []string{"post.reacted", "reaction", "comment", "story_reaction", "message"} {
		if Allowed(kind) {
			t.Fatalf("%s must never be pushed", kind)
		}
	}
}

func TestSkipsRecipientsWithALiveSocketHere(t *testing.T) {
	h := newHarness(t, nil)
	h.online[bob] = true
	h.d.Notify(chat(conv1))
	if h.d.Stats().Queued != 0 {
		t.Fatal("queued for an online recipient")
	}
	// Connecting while the push waited in the queue also cancels it.
	h.online[bob] = false
	h.d.Notify(chat(conv1))
	h.online[bob] = true
	h.drain()
	if len(h.sender.delivered()) != 0 || h.checked != 0 {
		t.Fatalf("sent to an online recipient: %v", h.sender.delivered())
	}
}

func TestIneligibleRecipientsGetNothingAndErrorsFailClosed(t *testing.T) {
	h := newHarness(t, nil)
	h.verdict = Eligibility{}
	h.d.Notify(chat(conv1))
	h.drain()
	if len(h.sender.delivered()) != 0 || len(h.asked) != 0 {
		t.Fatalf("ineligible recipient reached tokens: %v %v", h.sender.delivered(), h.asked)
	}
	h.verdict, h.checkErr = Eligibility{OK: true}, errors.New("database down")
	h.d.Notify(chat(conv1))
	h.drain()
	if len(h.sender.delivered()) != 0 {
		t.Fatal("a failed check sent a push")
	}
	// A refused push does not use up the coalescing window.
	h.checkErr = nil
	h.d.Notify(chat(conv1))
	h.drain()
	if len(h.sender.delivered()) != 1 {
		t.Fatal("window consumed by a push that was never sent")
	}
}

func TestChatPayloadHasNoContentAndNoNames(t *testing.T) {
	h := newHarness(t, nil)
	h.verdict = Eligibility{OK: true, ActorName: "Secret Stranger"}
	h.d.Notify(chat(conv1))
	h.drain()
	got := h.sender.delivered()
	if len(got) != 1 {
		t.Fatalf("sent %d", len(got))
	}
	m := got[0]
	if m.Title != "Hiyall" || m.Body != "New message" || m.CollapseKey != "chat-"+conv1 {
		t.Fatalf("message %+v", m)
	}
	if len(m.Data) != 2 || m.Data["kind"] != "chat" || m.Data["conversationId"] != conv1 {
		t.Fatalf("data %v", m.Data)
	}
	raw, _ := json.Marshal(m)
	for _, leak := range []string{"Secret", "Stranger", alice} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("payload leaks %q: %s", leak, raw)
		}
	}
}

func TestSocialPayloadsUseTheNameOnlyWhenGiven(t *testing.T) {
	cases := []struct {
		kind, name, body string
	}{
		{"follow", "Alex", "Alex started following you"},
		{"follow", "", "You have a new follower"},
		{"follow_request", "Alex", "Alex asked to follow you"},
		{"follow_request", "", "You have a new follow request"},
		{"friend_request", "Alex", "Alex sent you a friend request"},
		{"friend_accepted", "", "Your friend request was accepted"},
		{"follow", "Al‮ex\nBad", "AlexBad started following you"},
		{"follow", strings.Repeat("a", 60), strings.Repeat("a", 40) + "… started following you"},
	}
	for i, c := range cases {
		h := newHarness(t, nil)
		h.verdict = Eligibility{OK: true, ActorName: c.name}
		h.d.Notify(Notice{Kind: c.kind, Actor: alice, Recipient: bob})
		h.drain()
		got := h.sender.delivered()
		if len(got) != 1 || got[0].Body != c.body || got[0].Title != "Hiyall" {
			t.Fatalf("case %d %s/%q: %+v", i, c.kind, c.name, got)
		}
		if got[0].Data["kind"] != "social" || got[0].Data["event"] != c.kind || got[0].CollapseKey != "social" || len(got[0].Data) != 2 {
			t.Fatalf("case %d data %v %q", i, got[0].Data, got[0].CollapseKey)
		}
	}
}

func TestCoalescesPerRecipientAndConversation(t *testing.T) {
	h := newHarness(t, nil)
	h.d.Notify(chat(conv1))
	h.drain()
	h.now = h.now.Add(10 * time.Second)
	h.d.Notify(chat(conv1)) // inside 30s: dropped before it is even queued
	if h.d.Stats().Queued != 1 {
		t.Fatalf("queued %d", h.d.Stats().Queued)
	}
	h.d.Notify(chat(conv2)) // another conversation has its own window
	h.drain()
	if got := len(h.sender.delivered()); got != 2 {
		t.Fatalf("sent %d, want 2", got)
	}
	h.now = h.now.Add(25 * time.Second) // 35s after the first
	h.d.Notify(chat(conv1))
	h.drain()
	if got := len(h.sender.delivered()); got != 3 {
		t.Fatalf("sent %d after the window, want 3", got)
	}
}

func TestConcurrentNoticesInOneWindowSendOnce(t *testing.T) {
	h := newHarness(t, nil)
	// Both pass Notify's peek because nothing was sent yet; only one may pass admit.
	h.d.Notify(chat(conv1))
	h.d.Notify(chat(conv1))
	if h.d.Stats().Queued != 2 {
		t.Fatalf("queued %d", h.d.Stats().Queued)
	}
	h.drain()
	if got := len(h.sender.delivered()); got != 1 {
		t.Fatalf("sent %d, want 1", got)
	}
}

func TestSocialCoalescesPerActor(t *testing.T) {
	h := newHarness(t, nil)
	other := "019a4000-0000-7000-8000-000000000003"
	h.d.Notify(Notice{Kind: "follow", Actor: alice, Recipient: bob})
	h.d.Notify(Notice{Kind: "follow", Actor: other, Recipient: bob})
	h.drain()
	h.d.Notify(Notice{Kind: "follow", Actor: alice, Recipient: bob}) // follow, unfollow, follow
	h.drain()
	if got := len(h.sender.delivered()); got != 2 {
		t.Fatalf("sent %d, want 2", got)
	}
}

func TestDailyCapPerRecipient(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.DailyCap = 3 })
	for i := range 5 {
		h.d.Notify(chat(fmt.Sprintf("019a4000-0000-7000-8000-0000000001%02d", i)))
	}
	h.drain()
	if got := len(h.sender.delivered()); got != 3 {
		t.Fatalf("sent %d, want the cap of 3", got)
	}
	// Another recipient has their own allowance.
	h.d.Notify(Notice{Kind: "chat", Actor: bob, Recipient: alice, Conversation: conv1})
	h.drain()
	if got := len(h.sender.delivered()); got != 4 {
		t.Fatalf("sent %d, want 4", got)
	}
	h.now = h.now.Add(24*time.Hour + time.Second)
	h.d.Notify(chat(conv2))
	h.drain()
	if got := len(h.sender.delivered()); got != 5 {
		t.Fatalf("cap did not reset: %d", got)
	}
}

func TestOnlyTheRecipientsDevicesAreTargeted(t *testing.T) {
	h := newHarness(t, func(c *Config) {
		c.Targets = func(_ context.Context, users []string) ([]Target, error) {
			// A lookup that wrongly returns the actor's device must not reach it.
			return []Target{{UserID: bob, DeviceID: "d1", Provider: "fcm", Token: "t1"}, {UserID: alice, DeviceID: "d2", Provider: "fcm", Token: "t2"}}, nil
		}
	})
	h.d.Notify(chat(conv1))
	h.drain()
	if len(h.sender.to) != 1 || h.sender.to[0].UserID != bob {
		t.Fatalf("targets %v", h.sender.to)
	}
}

func TestNoTokensSendsNothingAndKeepsTheWindow(t *testing.T) {
	h := newHarness(t, func(c *Config) {
		c.Targets = func(context.Context, []string) ([]Target, error) { return nil, nil }
	})
	h.d.Notify(chat(conv1))
	h.drain()
	if h.d.coalesced(chat(conv1), kinds["chat"]) {
		t.Fatal("window consumed with no device to push to")
	}
}

func TestUnregisteredTokenIsForgotten(t *testing.T) {
	h := newHarness(t, nil)
	h.sender.errs = []error{fmt.Errorf("%w: gone", ErrUnregistered)}
	h.d.Notify(chat(conv1))
	h.drain()
	if len(h.forgot) != 1 || h.forgot[0].DeviceID != "dev-2" || h.forgot[0].Token != "token-2" || h.sender.n != 1 {
		t.Fatalf("forgot %v after %d sends", h.forgot, h.sender.n)
	}
	if s := h.d.Stats(); s.Forgotten != 1 || s.Sent != 0 || s.Failed != 0 {
		t.Fatalf("stats %+v", s)
	}
}

// FCM's SENDER_ID_MISMATCH means our credentials and the device token belong to different projects: every
// token would fail, so none may be cleared. It is counted as a failure and a configuration error.
func TestConfigErrorKeepsTheTokenAndIsCounted(t *testing.T) {
	h := newHarness(t, nil)
	before := configErrors(t)
	h.sender.errs = []error{fmt.Errorf("%w: FCM refused the push (HTTP 403 SENDER_ID_MISMATCH)", ErrConfig)}
	h.d.Notify(chat(conv1))
	h.drain()
	if len(h.forgot) != 0 || h.sender.n != 1 {
		t.Fatalf("a config error cleared %v tokens after %d sends", h.forgot, h.sender.n)
	}
	if s := h.d.Stats(); s.Forgotten != 0 || s.Failed != 1 {
		t.Fatalf("stats %+v", s)
	}
	if after := configErrors(t); after != before+1 {
		t.Fatalf("hiyall_push_config_errors_total %v -> %v", before, after)
	}
}

func configErrors(t *testing.T) float64 {
	t.Helper()
	var sb strings.Builder
	metrics.Default.WriteTo(&sb)
	for _, line := range strings.Split(sb.String(), "\n") {
		if strings.HasPrefix(line, "hiyall_push_config_errors_total{") {
			var v float64
			_, _ = fmt.Sscan(line[strings.LastIndex(line, " ")+1:], &v)
			return v
		}
	}
	return 0
}

func TestTransientFailuresRetryWithBackoffThenGiveUp(t *testing.T) {
	var waits []int
	h := newHarness(t, func(c *Config) {
		c.Backoff = func(attempt int) time.Duration { waits = append(waits, attempt); return 0 }
	})
	transient := &TransientError{Err: errors.New("HTTP 503")}
	h.sender.errs = []error{transient, transient}
	h.d.Notify(chat(conv1))
	h.drain()
	if s := h.d.Stats(); s.Sent != 1 || s.Retried != 2 || h.sender.n != 3 || fmt.Sprint(waits) != "[1 2]" {
		t.Fatalf("stats %+v sends %d waits %v", s, h.sender.n, waits)
	}

	h = newHarness(t, nil)
	h.sender.errs = []error{transient, transient, transient, transient, transient, transient}
	h.d.Notify(chat(conv1))
	h.drain()
	if s := h.d.Stats(); s.Failed != 1 || s.Sent != 0 || h.sender.n != 4 || len(h.forgot) != 0 {
		t.Fatalf("a persistent outage: stats %+v sends %d", s, h.sender.n)
	}

	// A refusal that is not transient is not retried and does not clear the token.
	h = newHarness(t, nil)
	h.sender.errs = []error{errors.New("HTTP 403 PERMISSION_DENIED")}
	h.d.Notify(chat(conv1))
	h.drain()
	if s := h.d.Stats(); s.Failed != 1 || s.Retried != 0 || h.sender.n != 1 || len(h.forgot) != 0 {
		t.Fatalf("permanent failure: stats %+v sends %d", s, h.sender.n)
	}
}

func TestBackoffGrowsWithJitterAndHonoursRetryAfter(t *testing.T) {
	for attempt := 1; attempt <= 4; attempt++ {
		base := 500 * time.Millisecond << (attempt - 1)
		for range 50 {
			if d := backoff(attempt); d < base || d > base+base/2 {
				t.Fatalf("attempt %d waited %v, want %v..%v", attempt, d, base, base+base/2)
			}
		}
	}
	h := newHarness(t, nil)
	h.sender.errs = []error{&TransientError{Err: errors.New("HTTP 429"), After: 30 * time.Millisecond}}
	start := time.Now()
	h.d.Notify(chat(conv1))
	h.drain()
	if time.Since(start) < 30*time.Millisecond || h.d.Stats().Sent != 1 {
		t.Fatalf("Retry-After ignored: %v %+v", time.Since(start), h.d.Stats())
	}
}

func TestShutdownInterruptsBackoff(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.Backoff = func(int) time.Duration { return time.Hour } })
	h.sender.errs = []error{&TransientError{Err: errors.New("HTTP 503")}}
	ctx, cancel := context.WithCancel(context.Background())
	h.d.Run(ctx, 2)
	h.d.Notify(chat(conv1))
	for deadline := time.Now().Add(2 * time.Second); h.sender.count() == 0 && time.Now().Before(deadline); time.Sleep(time.Millisecond) {
	}
	cancel()
	done := make(chan struct{})
	go func() { h.d.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("workers did not stop on shutdown")
	}
}

func TestFullQueueDropsWithoutBlocking(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.Queue = 2 })
	done := make(chan struct{})
	go func() {
		for i := range 5 {
			h.d.Notify(chat(fmt.Sprintf("019a4000-0000-7000-8000-0000000002%02d", i)))
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Notify blocked on a full queue")
	}
	if s := h.d.Stats(); s.Queued != 2 || s.Dropped != 3 {
		t.Fatalf("stats %+v", s)
	}
}

func TestWorkersDeliverQueuedPushes(t *testing.T) {
	h := newHarness(t, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h.d.Run(ctx, 3)
	h.d.Notify(chat(conv1))
	for deadline := time.Now().Add(2 * time.Second); len(h.sender.delivered()) == 0 && time.Now().Before(deadline); time.Sleep(time.Millisecond) {
	}
	if len(h.sender.delivered()) != 1 {
		t.Fatal("not delivered by a worker")
	}
}

func TestLogSenderNeverFailsAndIsTheUnconfiguredDefault(t *testing.T) {
	if err := (LogSender{}).Send(context.Background(), Target{Provider: "fcm", Token: "secret-token-value"}, Message{Kind: "chat"}); err != nil {
		t.Fatal(err)
	}
	// Dispatching through it works end to end with the same rules.
	h := newHarness(t, func(c *Config) { c.Sender = LogSender{} })
	h.d.Notify(chat(conv1))
	h.drain()
	if h.d.Stats().Sent != 1 {
		t.Fatal("log sender did not count as delivered")
	}
}

func TestDeviceNoticeIsContentFreeSecurityPushToTheOtherDevices(t *testing.T) {
	var asked []string
	h := newHarness(t, func(c *Config) {
		c.Targets = func(_ context.Context, users []string) ([]Target, error) {
			return []Target{
				{UserID: bob, DeviceID: "old-phone", Provider: "fcm", Token: "t1"},
				{UserID: bob, DeviceID: "old-tablet", Provider: "apns", Token: "t2"},
				{UserID: bob, DeviceID: "new-phone", Provider: "fcm", Token: "t3"},
			}, nil
		}
		check := c.Check
		c.Check = func(ctx context.Context, n Notice, category string) (Eligibility, error) {
			asked = append(asked, category)
			return check(ctx, n, category)
		}
	})
	// The actor is the recipient: the notice is about the account itself.
	h.d.Notify(Notice{Kind: "device", Actor: bob, Recipient: bob, Device: "new-phone"})
	h.drain()
	if len(asked) != 1 || asked[0] != CategorySecurity || CategoryOf("device") != CategorySecurity {
		t.Fatalf("category %v", asked)
	}
	got := h.sender.delivered()
	if len(got) != 2 {
		t.Fatalf("sent %d, want the two other devices", len(got))
	}
	for _, m := range got {
		if m.Title != "Hiyall" || m.Body != "New device added to your account" || m.CollapseKey != "device" {
			t.Fatalf("message %+v", m)
		}
		if len(m.Data) != 1 || m.Data["kind"] != "device" {
			t.Fatalf("data %v", m.Data)
		}
	}
	if h.sender.count() != 2 {
		t.Fatal("the new device was woken")
	}
	// Coalesced inside a minute, sent again after it.
	h.d.Notify(Notice{Kind: "device", Actor: bob, Recipient: bob, Device: "new-phone"})
	h.drain()
	if h.sender.count() != 2 {
		t.Fatal("a second notice inside the window went out")
	}
	h.now = h.now.Add(2 * time.Minute)
	h.d.Notify(Notice{Kind: "device", Actor: bob, Recipient: bob, Device: "new-phone"})
	h.drain()
	if h.sender.count() != 4 {
		t.Fatalf("sent %d after the window", h.sender.count())
	}
}

func TestOtherKindsStillNeverNotifyTheirOwnActor(t *testing.T) {
	h := newHarness(t, nil)
	h.d.Notify(Notice{Kind: "follow", Actor: bob, Recipient: bob})
	h.d.Notify(Notice{Kind: "chat", Actor: bob, Recipient: bob, Conversation: conv1})
	h.drain()
	if h.sender.count() != 0 {
		t.Fatal("a notice went to its own actor")
	}
}
