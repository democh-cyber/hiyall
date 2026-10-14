package httpapi

import (
	"context"
	"errors"
	"testing"
)

type fakeAppleRevoker struct {
	codes  []string
	err    error
	queued []byte
}

func (f *fakeAppleRevoker) RevokeAuthorizationCode(_ context.Context, code string) ([]byte, error) {
	f.codes = append(f.codes, code)
	return f.queued, f.err
}

func (h *acctHarness) scheduleApple(user, confirm, code string) reply {
	h.t.Helper()
	return h.send(user, "POST", "/v1/me/deletion", map[string]string{"confirmUsername": confirm, "appleAuthorizationCode": code})
}

func TestDeletionRevokesSignInWithAppleBeforeScheduling(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	apple := &fakeAppleRevoker{}
	h.api.Apple = apple

	// A request without the code works as before and never calls Apple.
	h.expect(h.schedule(cara, "cara"), 200, "")
	if len(apple.codes) != 0 {
		t.Fatalf("apple called without a code: %v", apple.codes)
	}
	// With the code from the app's Apple re-sign-in, Apple is called once and the account is scheduled.
	h.expect(h.scheduleApple(xan, "xan", "c-123"), 200, "")
	if len(apple.codes) != 1 || apple.codes[0] != "c-123" || h.status(xan) != "pending_deletion" {
		t.Fatalf("codes %v status %s", apple.codes, h.status(xan))
	}
	if h.count(`SELECT count(*) FROM apple_revocations`) != 0 {
		t.Fatal("a completed revoke left a queued token")
	}
	// An empty or non-string code is a validation error and changes nothing.
	h.expect(h.send(eli, "POST", "/v1/me/deletion", map[string]any{"confirmUsername": "eli", "appleAuthorizationCode": 5}), 422, "VALIDATION")
	h.expect(h.scheduleApple(eli, "eli", ""), 422, "VALIDATION")
	if h.status(eli) != "active" {
		t.Fatal("a refused request changed the account")
	}
}

func TestAppleFailureLeavesTheAccountActiveSoTheMemberCanRetry(t *testing.T) {
	h := newAcctHarness(t)
	h.api.Apple = &fakeAppleRevoker{err: errors.New("apple answered 400 invalid_grant")}
	h.expect(h.scheduleApple(yui, "yui", "stale"), 503, "APPLE_REVOKE_FAILED")
	if h.status(yui) != "active" {
		t.Fatal("deletion was scheduled although Apple was not told")
	}
}

func TestAppleRevokeThatCouldNotFinishIsQueuedForThePurge(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	h.exec(`INSERT INTO auth_identities(issuer,subject,user_id) VALUES('https://securetoken.google.com/test-project','apple-uid-1',$1)`, dev)
	h.api.Apple = &fakeAppleRevoker{queued: []byte("sealed-bytes")}
	h.expect(h.scheduleApple(dev, "dev_k", "c-9"), 200, "")
	if h.count(`SELECT count(*) FROM apple_revocations WHERE subject='apple-uid-1' AND token_sealed='\x7365616c65642d6279746573'::bytea`) != 1 {
		t.Fatal("the sealed token was not queued")
	}
}

func TestUnconfiguredAppleIsANoOpThatStillDeletes(t *testing.T) {
	h := newAcctHarness(t)
	h.api.Apple = nil
	h.expect(h.scheduleApple(cara, "cara", "c-1"), 200, "")
	if h.status(cara) != "pending_deletion" {
		t.Fatal("deletion blocked by missing Apple configuration")
	}
}
