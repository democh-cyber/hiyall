package identity

import (
	"context"
	"errors"
	"testing"
)

type providerRecord struct {
	subject, provider string
	apple             bool
}

// The sign-in provider is written once per sign-in per process, not per request, and Apple is recognised both
// as the sign-in provider and as a linked one (audit API-8).
func TestSignInProviderIsRecordedOncePerSignIn(t *testing.T) {
	f := newFirebaseFixture(t)
	var got []providerRecord
	f.verifier.record = func(_ context.Context, issuer, subject, provider string, apple bool) error {
		if issuer != FirebaseIssuer(testProject) {
			t.Fatalf("issuer %q", issuer)
		}
		got = append(got, providerRecord{subject, provider, apple})
		return nil
	}
	google := f.token(nil)
	for i := 0; i < 5; i++ {
		if _, err := f.verifier.Verify(context.Background(), google); err != nil {
			t.Fatal(err)
		}
	}
	if len(got) != 1 || got[0] != (providerRecord{"firebase-uid-1", "google.com", false}) {
		t.Fatalf("recorded %+v", got)
	}
	// Apple as the provider.
	got = nil
	if _, err := f.verifier.Verify(context.Background(), f.token(appleClaims("x@privaterelay.appleid.com", true))); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].provider != "apple.com" || !got[0].apple {
		t.Fatalf("apple sign-in recorded %+v", got)
	}
	// Signed in with Google, Apple linked to the same Firebase user: the Apple authorization still exists.
	got = nil
	linked := f.token(map[string]any{"auth_time": f.claims(nil)["auth_time"].(int64) - 100, "firebase": map[string]any{"sign_in_provider": "google.com", "identities": map[string]any{"google.com": []string{"1"}, "apple.com": []string{"2"}}}})
	if _, err := f.verifier.Verify(context.Background(), linked); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].provider != "google.com" || !got[0].apple {
		t.Fatalf("linked apple recorded %+v", got)
	}
}

// A storage failure never fails the request, and is retried at the next request of the same sign-in.
func TestProviderRecordingFailureNeverFailsTheRequest(t *testing.T) {
	f := newFirebaseFixture(t)
	calls := 0
	f.verifier.record = func(context.Context, string, string, string, bool) error { calls++; return errors.New("database busy") }
	token := f.token(nil)
	for i := 0; i < 3; i++ {
		if _, err := f.verifier.Verify(context.Background(), token); err != nil {
			t.Fatalf("request %d failed: %v", i, err)
		}
	}
	if calls != 3 {
		t.Fatalf("%d attempts, want one per request until it succeeds", calls)
	}
	f.verifier.record = nil
	if _, err := f.verifier.Verify(context.Background(), token); err != nil {
		t.Fatal(err)
	}
}
