package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"

	"hiyall/services/api/internal/domain"
)

// The daily limit on starting conversations (docs/api/20-chat.md#limits): conversations the member created,
// over a rolling 24 hours, never refunded, enforced where the conversation is created.

const newChatsLimitMessage = "You’ve reached today’s limit for starting new chats. Try again later."

// strangersFor provisions n members to start conversations with.
func (h *socialHarness) strangersFor(n int) []string {
	h.t.Helper()
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("019a4000-0000-7000-8000-%012d", 2000+i)
		h.user(out[i], fmt.Sprintf("hello_%d", i))
	}
	return out
}

// openCall opens a conversation with the per-account limiters reset, so only the daily limit answers.
func (h *socialHarness) openCall(from, to string) limitReply {
	h.t.Helper()
	h.api.firstChats.reset(from)
	h.api.graph.reset(from)
	return h.limited(from, "POST", "/v1/conversations", map[string]string{"userId": to})
}

func (r limitReply) wantOpened(t *testing.T) {
	t.Helper()
	if r.status != 200 {
		t.Fatalf("got %d %s, want 200", r.status, r.body)
	}
}

// createdBy counts the conversations a member started, whatever their age or status.
func (h *socialHarness) createdBy(user string) int {
	h.t.Helper()
	return h.countOf(`SELECT count(*) FROM conversations WHERE created_by=$1`, user)
}

// startChats has from open a conversation with each peer, all of which must succeed.
func (h *socialHarness) startChats(from string, peers []string) {
	h.t.Helper()
	for i, peer := range peers {
		if got := h.openCall(from, peer); got.status != 200 {
			h.t.Fatalf("conversation %d: %d %s", i+1, got.status, got.body)
		}
	}
}

func TestStartingNewConversationsIsLimitedPerDay(t *testing.T) {
	h := newSocialHarness(t)
	if got := domain.Free().NewConversationsPerDay; got != 40 {
		t.Fatalf("Free allows %d new conversations a day, want 40", got)
	}
	peers := h.strangersFor(45)
	h.startChats(alice, peers[:40])
	// The 41st person is refused with the standard envelope and a Retry-After for when the oldest leaves.
	refused := h.openCall(alice, peers[40])
	refused.wantQuota(t, newChatsLimitMessage, true)
	refused.wantRetryAbout(t, 24*3600)
	if got := h.createdBy(alice); got != 40 {
		t.Fatalf("%d conversations after the refusal, want 40", got)
	}
	// The limit is per member: another account starts its own.
	h.openCall(bob, peers[40]).wantOpened(t)
	// Reopening any of the 40 is not starting one, at the limit or not.
	for _, peer := range []string{peers[0], peers[20], peers[39]} {
		h.openCall(alice, peer).wantOpened(t)
	}
	// Closing one (a block does) does not give the slot back.
	h.exec(`UPDATE conversations SET status='closed' WHERE created_by=$1 AND user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`, alice, peers[3])
	h.openCall(alice, peers[41]).wantQuota(t, newChatsLimitMessage, true)
	// A refused open leaves nothing half-made.
	if got := h.countOf(`SELECT count(*) FROM conversation_members WHERE user_id=$1`, alice); got != 40 {
		t.Fatalf("%d conversation memberships for the member, want 40", got)
	}
}

func TestNewConversationLimitSlidesWithTheRollingWindow(t *testing.T) {
	h := newSocialHarness(t)
	peers := h.strangersFor(46)
	h.startChats(alice, peers[:40])
	// Three of them were started more than a day ago; one of the rest 23 hours ago, so the next
	// slot to free is that one, in about an hour.
	h.exec(`UPDATE conversations SET created_at=now()-interval '25 hours' WHERE conversation_id IN (SELECT conversation_id FROM conversations WHERE created_by=$1 ORDER BY created_at LIMIT 3)`, alice)
	h.exec(`UPDATE conversations SET created_at=now()-interval '23 hours' WHERE conversation_id IN (SELECT conversation_id FROM conversations WHERE created_by=$1 AND created_at>now()-interval '24 hours' ORDER BY created_at LIMIT 1)`, alice)
	for i := 40; i < 43; i++ {
		h.openCall(alice, peers[i]).wantOpened(t)
	}
	refused := h.openCall(alice, peers[43])
	refused.wantQuota(t, newChatsLimitMessage, true)
	// The oldest counted one is the 23 hour old one: its slot frees in about an hour.
	refused.wantRetryAbout(t, 3600)
	// It leaves the window and the next start works.
	h.exec(`UPDATE conversations SET created_at=now()-interval '24 hours 1 second' WHERE conversation_id IN (SELECT conversation_id FROM conversations WHERE created_by=$1 AND created_at<now()-interval '22 hours' AND created_at>now()-interval '24 hours')`, alice)
	h.openCall(alice, peers[43]).wantOpened(t)
	h.openCall(alice, peers[44]).wantQuota(t, newChatsLimitMessage, true)
	// Two of the newest start to age out as well, and two more starts fit.
	h.exec(`UPDATE conversations SET created_at=now()-interval '30 hours' WHERE conversation_id IN (SELECT conversation_id FROM conversations WHERE created_by=$1 ORDER BY created_at DESC LIMIT 2)`, alice)
	h.openCall(alice, peers[44]).wantOpened(t)
	h.openCall(alice, peers[45]).wantOpened(t)
	h.openCall(alice, peers[1]).wantOpened(t) // reopening, any time
}

func TestReopeningAndReceivingConversationsDoesNotCount(t *testing.T) {
	h := newSocialHarness(t)
	peers := h.strangersFor(45)
	h.startChats(alice, peers[:39])
	// Reopening the same conversation many times is free.
	for i := 0; i < 50; i++ {
		h.openCall(alice, peers[i%39]).wantOpened(t)
	}
	// Someone else starting a conversation with alice is not alice starting it, and alice opening that
	// one is a reopening.
	h.openCall(peers[40], alice).wantOpened(t)
	h.openCall(peers[41], alice).wantOpened(t)
	h.openCall(alice, peers[40]).wantOpened(t)
	h.openCall(alice, peers[41]).wantOpened(t)
	if got := h.createdBy(alice); got != 39 {
		t.Fatalf("alice started %d conversations, want 39", got)
	}
	// So alice still has one start left: the 40th, and then the limit.
	h.openCall(alice, peers[42]).wantOpened(t)
	h.openCall(alice, peers[43]).wantQuota(t, newChatsLimitMessage, true)
	// A conversation that was closed and is opened again keeps its creator: a reopening, not a start.
	h.exec(`UPDATE conversations SET status='closed' WHERE created_by=$1 AND user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`, peers[40], alice)
	h.openCall(alice, peers[40]).wantOpened(t)
	if got := h.createdBy(alice); got != 40 {
		t.Fatalf("alice started %d conversations after reopening a closed one, want 40", got)
	}
}

// The limit comes after the rules that already applied: a refusal by the target's settings, a block or the
// age-band barrier answers as before at any count, and none of them uses a slot.
func TestNewConversationLimitKeepsTheExistingChatRules(t *testing.T) {
	h := newSocialHarness(t)
	peers := h.strangersFor(44)
	h.policy(peers[41], "messagesFrom", "nobody")
	h.ageAt(peers[42], 15)
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, peers[43], alice)
	refusals := func() {
		h.t.Helper()
		h.openCall(alice, peers[41]).wantError(t, 403, "MESSAGES_NOT_ALLOWED")
		h.openCall(alice, peers[42]).wantError(t, 404, "NOT_FOUND")
		h.openCall(alice, peers[43]).wantError(t, 404, "NOT_FOUND")
	}
	refusals()
	if got := h.createdBy(alice); got != 0 {
		t.Fatalf("refused opens created %d conversations", got)
	}
	h.startChats(alice, peers[:40])
	// At the limit the same answers, not QUOTA.
	refusals()
	h.openCall(alice, peers[40]).wantQuota(t, newChatsLimitMessage, true)
	// The target's setting is honoured once they allow it, and the limit then applies.
	h.policy(peers[41], "messagesFrom", "everyone")
	h.openCall(alice, peers[41]).wantQuota(t, newChatsLimitMessage, true)
	// Sending into an existing conversation is not limited by it.
	devices := h.devicesFor(alice, peers[0])
	convo := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": peers[0]}), 200, "").data["conversationId"].(string)
	h.api.messages.reset(alice)
	h.expect(h.send(alice, "POST", "/v1/conversations/"+convo+"/messages", message(devices[alice], devices[peers[0]])), 200, "")
}

// wantError checks a refusal that is not a limit: its status and error code.
func (r limitReply) wantError(t *testing.T, status int, code string) {
	t.Helper()
	var body struct {
		Error map[string]string `json:"error"`
	}
	if err := json.Unmarshal(r.body, &body); err != nil || r.status != status || body.Error["code"] != code {
		t.Fatalf("got %d %s, want %d %s", r.status, r.body, status, code)
	}
}

// Parallel requests cannot pass the limit: the check and the insert share one transaction behind the
// member's lock.
func TestParallelNewConversationsCannotExceedTheLimit(t *testing.T) {
	h := newSocialHarness(t)
	peers := h.strangersFor(60)
	var wg sync.WaitGroup
	var opened, refused, other atomic.Int32
	e := domain.Free()
	for _, peer := range peers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := h.db.OpenConversation(context.Background(), alice, peer, e, h.api.signer(h.ctx), h.api.presence)
			var quota *domain.PolicyError
			switch {
			case err == nil:
				opened.Add(1)
			case errors.As(err, &quota) && quota.Code == "QUOTA":
				refused.Add(1)
			default:
				other.Add(1)
				t.Errorf("open: %v", err)
			}
		}()
	}
	wg.Wait()
	if opened.Load() != 40 || refused.Load() != 20 || other.Load() != 0 {
		t.Fatalf("opened %d, refused %d, failed %d; want 40, 20, 0", opened.Load(), refused.Load(), other.Load())
	}
	if got := h.createdBy(alice); got != 40 {
		t.Fatalf("%d conversations, want 40", got)
	}
	// Opening the same person in parallel is one conversation, and only one slot.
	h2 := newSocialHarness(t)
	peer := h2.strangersFor(1)[0]
	var group sync.WaitGroup
	for i := 0; i < 10; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if _, err := h2.db.OpenConversation(context.Background(), alice, peer, e, h2.api.signer(h2.ctx), h2.api.presence); err != nil {
				t.Errorf("reopen: %v", err)
			}
		}()
	}
	group.Wait()
	if got := h2.createdBy(alice); got != 1 {
		t.Fatalf("%d conversations from parallel opens of one person, want 1", got)
	}
}

// The limit is data from the member's entitlements: a bigger tier allows more, a smaller one stops sooner and
// members the resolver does not cover stay on Free.
func TestNewConversationLimitComesFromTheEntitlementsResolver(t *testing.T) {
	h := newSocialHarness(t)
	peers := h.strangersFor(45)
	big, small := domain.Free(), domain.Free()
	big.NewConversationsPerDay, small.NewConversationsPerDay = 45, 2
	var seen sync.Map
	h.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		seen.Store(user, true)
		switch user {
		case alice:
			return big
		case bob:
			return small
		}
		return domain.Free()
	}
	h.startChats(alice, peers[:45]) // past Free's 40
	h.openCall(alice, bob).wantQuota(t, newChatsLimitMessage, true)
	h.openCall(bob, peers[0]).wantOpened(t)
	h.openCall(bob, peers[1]).wantOpened(t)
	h.openCall(bob, peers[2]).wantQuota(t, newChatsLimitMessage, true)
	h.startChats(cara, peers[:40])
	h.openCall(cara, peers[40]).wantQuota(t, newChatsLimitMessage, true)
	for _, user := range []string{alice, bob, cara} {
		if _, ok := seen.Load(user); !ok {
			t.Fatalf("the resolver was not asked about %s", user)
		}
	}
}
