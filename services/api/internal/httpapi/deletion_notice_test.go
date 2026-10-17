package httpapi

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/push"
)

// Round-4 N-5: appleCodeUnavailable is only the client's statement, and a stolen token can delete an account. Every new
// deletion sends one content-free push to the devices that held a token, before the deletion's own clearing of the tokens
// makes that impossible. Recency (an interactive sign-in within five minutes) is the other line, and is tested here for
// the paths that carry an Apple code or the statement that there is none.

func TestDeletionSendsOneContentFreePushToEveryDeviceThatHadAToken(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	// A live socket on this node does not silence it: whoever holds a stolen credential can keep one open.
	log, _ := pushing(t, h.socialHarness, func(c *push.Config) { c.Online = func(string) bool { return true } })
	phone, tablet, bystander := h.register(xan), h.register(xan), h.register(yui)
	h.token(phone, "xan-phone-token")
	h.token(tablet, "xan-tablet-token")
	h.token(bystander, "yui-phone-token")
	// Adding a device is itself a security push ("new device added"); count from after those.
	time.Sleep(200 * time.Millisecond)
	base := len(log.messages())

	h.expect(h.schedule(xan, "xan"), 200, "")
	got := log.wait(t, base+2)[base:]
	tokens := map[string]bool{}
	for i, m := range got {
		raw, _ := json.Marshal(m)
		if m.Kind != "deletion" || m.Title != "Hiyall" || m.Body != "Account deletion scheduled" || m.CollapseKey != "deletion" || len(m.Data) != 1 || m.Data["kind"] != "deletion" {
			t.Fatalf("push %d: %+v", i, m)
		}
		if strings.Contains(string(raw), "xan") {
			t.Fatalf("the push carries something about the account: %s", raw)
		}
	}
	log.mu.Lock()
	for _, to := range log.to {
		tokens[to.Token] = true
		if to.UserID != xan {
			t.Fatalf("pushed to %s", to.UserID)
		}
	}
	log.mu.Unlock()
	if !tokens["xan-phone-token"] || !tokens["xan-tablet-token"] || len(tokens) != 2 {
		t.Fatalf("tokens %v", tokens)
	}
	// The tokens are cleared afterwards, as before, and the other member was left alone.
	if h.count(`SELECT count(*) FROM devices WHERE user_id=$1 AND push_token IS NOT NULL`, xan) != 0 {
		t.Fatal("the deletion left push tokens")
	}
	if h.count(`SELECT count(*) FROM devices WHERE user_id=$1 AND push_token IS NOT NULL`, yui) != 1 {
		t.Fatal("another member's token was cleared")
	}
	// Asking again while pending changes nothing, hands back no tokens and sends nothing.
	if _, targets, err := h.api.Store.ScheduleDeletionNotify(h.ctx, xan); err != nil || len(targets) != 0 {
		t.Fatalf("a repeated request: %v %v", targets, err)
	}
	log.quiet(t, base+2, "a repeated request")

	// The statement that there is no Apple code goes through the same push.
	h.api.Apple = &fakeAppleRevoker{}
	h.identity(eli, "apple-uid-e", "apple.com", true)
	h.token(h.register(eli), "eli-phone-token")
	time.Sleep(200 * time.Millisecond)
	base = len(log.messages())
	h.expect(h.scheduleUnavailable(eli, "eli"), 200, "")
	if last := log.wait(t, base+1); last[base].Kind != "deletion" {
		t.Fatalf("%+v", last[base])
	}
}

func TestAnAccountWithoutPushTokensIsDeletedWithoutAPush(t *testing.T) {
	h := newAcctHarness(t)
	log, _ := pushing(t, h.socialHarness, nil)
	h.register(cara) // a device with no token
	h.expect(h.schedule(cara, "cara"), 200, "")
	log.quiet(t, 0, "an account with no tokens")
	if h.status(cara) != "pending_deletion" {
		t.Fatal("not scheduled")
	}
}

// A development session has no auth_time and is allowed to delete; the harness's verifier is not development
// authentication, so here an undatable session is NOT recent and neither is one from six minutes ago.
func TestAppleDeletionPathsStillNeedASignInFromTheLastFiveMinutes(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	apple := &fakeAppleRevoker{}
	h.api.Apple = apple
	log, _ := pushing(t, h.socialHarness, nil)
	h.identity(xan, "apple-uid-x", "apple.com", true)
	h.token(h.register(xan), "xan-phone-token")

	refused := func(why string) {
		t.Helper()
		h.expect(h.scheduleUnavailable(xan, "xan"), 403, "REAUTH_REQUIRED")
		h.expect(h.send(xan, "POST", "/v1/me/deletion", map[string]any{"confirmUsername": "xan", "appleAuthorizationCode": "code-1"}), 403, "REAUTH_REQUIRED")
		if h.status(xan) != "active" || len(apple.codes) != 0 || h.count(`SELECT count(*) FROM apple_revocations`) != 0 ||
			h.count(`SELECT count(*) FROM devices WHERE user_id=$1 AND push_token IS NOT NULL`, xan) != 1 {
			t.Fatalf("%s: a refused request changed something (status %s, apple calls %v)", why, h.status(xan), apple.codes)
		}
		log.quiet(t, 0, why)
	}
	h.signIn(xan, 10*time.Minute)
	refused("ten minutes")
	h.signIn(xan, 5*time.Minute+15*time.Second)
	refused("just over five minutes")
	// A session the server cannot date (no Firebase auth_time) is refused outside development authentication.
	sid := uuid.NewString()
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at) VALUES($1,$2,now()+interval '1 hour')`, sid, xan)
	h.mu.Lock()
	h.sids[xan] = sid
	h.mu.Unlock()
	refused("a session with no auth_time")
	// Within five minutes it goes through, with the statement that there is no code.
	h.signIn(xan, 4*time.Minute)
	got := h.expect(h.scheduleUnavailable(xan, "xan"), 200, "")
	if got.data["appleAction"] != "remove_in_apple_settings" || len(apple.codes) != 0 {
		t.Fatalf("%v %v", got.data, apple.codes)
	}
	log.wait(t, 1)
}
