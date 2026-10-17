package httpapi

import (
	"context"
	"testing"

	"hiyall/services/api/internal/identity"
)

// Round-3 audit API-1 / APP-N2, round-4 N-4: an Apple account whose app cannot obtain an authorization code can still
// delete itself. The server schedules the deletion and tells the member (appleAction) to remove the app's access in Apple
// ID settings: nobody at Hiyall can revoke it for them. The queue row only records that they were told.

func (h *acctHarness) scheduleUnavailable(user, confirm string) reply {
	h.t.Helper()
	return h.send(user, "POST", "/v1/me/deletion", map[string]any{"confirmUsername": confirm, "appleCodeUnavailable": true})
}

func TestAppleCodeUnavailableSchedulesTheDeletionAndRecordsThatTheMemberWasTold(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	apple := &fakeAppleRevoker{}
	h.api.Apple = apple
	h.identity(xan, "apple-uid-x", "apple.com", true)
	h.identity(eli, "google-uid-e", "google.com", true) // Google sign-in, Apple linked: also an Apple authorization

	// Without the flag the server still insists on the code.
	h.expect(h.schedule(xan, "xan"), 422, "APPLE_CODE_REQUIRED")
	// With it, the deletion goes ahead and Apple is not called.
	got := h.expect(h.scheduleUnavailable(xan, "xan"), 200, "")
	if got.data["pending"] != true || h.status(xan) != "pending_deletion" || len(apple.codes) != 0 {
		t.Fatalf("data %v status %s apple calls %v", got.data, h.status(xan), apple.codes)
	}
	// The response tells the member what is left to do at Apple; the app shows it (docs/api/22).
	if got.data["appleAction"] != "remove_in_apple_settings" {
		t.Fatalf("the response does not tell the member to remove access in Apple settings: %v", got.data)
	}
	if h.count(`SELECT count(*) FROM apple_revocations WHERE status='manual'`) != 0 {
		t.Fatal("a record that an operator has to act on was written for a deletion the app could tell the member about")
	}
	if h.count(`SELECT count(*) FROM apple_revocations WHERE subject='apple-uid-x' AND status='member_informed' AND token_sealed IS NULL AND user_id=$1`, xan) != 1 {
		t.Fatal("no member_informed record was written")
	}
	if got = h.expect(h.scheduleUnavailable(eli, "eli"), 200, ""); got.data["appleAction"] != "remove_in_apple_settings" {
		t.Fatalf("a linked Apple authorization: %v", got.data)
	}
	if h.count(`SELECT count(*) FROM apple_revocations WHERE status='member_informed'`) != 2 {
		t.Fatal("a linked Apple authorization was not recorded")
	}
	// Asking again (a retry after a lost response) changes nothing and keeps a row that already exists.
	if _, err := h.db.ScheduleDeletionManualApple(h.ctx, xan); err != nil {
		t.Fatal(err)
	}
	if h.count(`SELECT count(*) FROM apple_revocations WHERE status='member_informed'`) != 2 {
		t.Fatal("a second request duplicated the revocation")
	}
}

func TestAppleCodeUnavailableIsNoOpForAccountsWithoutAppleAndRefusedWithACode(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	h.api.Apple = &fakeAppleRevoker{}
	h.identity(cara, "google-uid-c", "google.com", false)
	if got := h.expect(h.scheduleUnavailable(cara, "cara"), 200, ""); got.data["appleAction"] != nil {
		t.Fatalf("a Google-only account was told to remove Apple access: %v", got.data)
	}
	if h.status(cara) != "pending_deletion" || h.count(`SELECT count(*) FROM apple_revocations`) != 0 {
		t.Fatal("a Google-only account got an Apple record")
	}
	// The code and the statement that there is none cannot both be sent; nothing changes.
	h.identity(yui, "apple-uid-y", "apple.com", false)
	h.expect(h.send(yui, "POST", "/v1/me/deletion", map[string]any{"confirmUsername": "yui", "appleAuthorizationCode": "c-1", "appleCodeUnavailable": true}), 422, "VALIDATION")
	h.expect(h.send(yui, "POST", "/v1/me/deletion", map[string]any{"confirmUsername": "yui", "appleCodeUnavailable": "yes"}), 422, "VALIDATION")
	if h.status(yui) != "active" {
		t.Fatal("a refused request changed the account")
	}
	// The statement still needs the username confirmation and a recent sign-in like any deletion.
	h.expect(h.send(yui, "POST", "/v1/me/deletion", map[string]any{"confirmUsername": "wrong", "appleCodeUnavailable": true}), 422, "VALIDATION")
	if h.status(yui) != "active" {
		t.Fatal("a wrong confirmation changed the account")
	}
}

func TestCancellingTheDeletionDropsTheAppleRecordAndThePurgeSkipsApple(t *testing.T) {
	h := newAcctHarness(t)
	h.exec(`TRUNCATE apple_revocations`)
	h.api.Apple = &fakeAppleRevoker{}
	h.identity(xan, "apple-uid-x", "apple.com", true)
	h.expect(h.scheduleUnavailable(xan, "xan"), 200, "")
	h.signIn(xan, 0)

	// The purge: no token to revoke, so Apple is not called (no revoker is even needed), the identity is deleted and the
	// record stays (the console removes it after 90 days).
	inner := &recordingDeleter{}
	deleter := identity.AppleDeleter{Inner: inner, Queue: h.db}
	if err := deleter.DeleteIdentity(context.Background(), "https://securetoken.google.com/test-project", "apple-uid-x"); err != nil {
		t.Fatal(err)
	}
	if len(inner.deleted) != 1 || h.count(`SELECT count(*) FROM apple_revocations WHERE status='member_informed'`) != 1 {
		t.Fatalf("deleted %v", inner.deleted)
	}
	// The member changes their mind within the grace period: the record is not needed.
	h.expect(h.send(xan, "DELETE", "/v1/me/deletion", nil), 200, "")
	if h.status(xan) != "active" || h.count(`SELECT count(*) FROM apple_revocations`) != 0 {
		t.Fatal("cancelling left an Apple record")
	}
}

type recordingDeleter struct{ deleted []string }

func (r *recordingDeleter) DeleteIdentity(_ context.Context, issuer, subject string) error {
	r.deleted = append(r.deleted, issuer+"|"+subject)
	return nil
}
