package identity

import (
	"context"
	"errors"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// Sign in with Apple arrives as an ordinary Firebase ID token whose sign-in provider
// is apple.com. Apple vouches for the address, including its private relay form, so
// the API must not hold such an account for email verification.
func appleClaims(email any, verified any) map[string]any {
	return map[string]any{
		"email":          email,
		"email_verified": verified,
		"firebase": map[string]any{
			"sign_in_provider": "apple.com",
			"identities":       map[string]any{"apple.com": []string{"001234.abcdef.5678"}},
		},
	}
}

func TestAppleTokensAreAcceptedWhateverTheEmailClaimsSay(t *testing.T) {
	f := newFirebaseFixture(t)
	for _, tc := range []struct {
		name     string
		override map[string]any
	}{
		{"private relay address, verified", appleClaims("x1y2z3@privaterelay.appleid.com", true)},
		{"private relay address, not marked verified", appleClaims("x1y2z3@privaterelay.appleid.com", false)},
		{"real address shared", appleClaims("member@example.test", true)},
		{"no email claim at all", appleClaims(nil, nil)},
		{"email_verified missing", appleClaims("x1y2z3@privaterelay.appleid.com", nil)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.resolved = nil
			p, err := f.verifier.Verify(context.Background(), f.token(tc.override))
			if err != nil {
				t.Fatalf("rejected: %v", err)
			}
			if len(f.resolved) != 1 || f.resolved[0].subject != "firebase-uid-1" {
				t.Fatalf("resolved %+v", f.resolved)
			}
			if p.UserID == "" {
				t.Fatalf("principal %+v", p)
			}
		})
	}
}

func TestAppleNeedsNoEmailVerificationButPasswordStillDoes(t *testing.T) {
	f := newFirebaseFixture(t)
	if _, _, err := f.verifier.firebaseClaims(context.Background(), f.token(appleClaims("x@privaterelay.appleid.com", false))); err != nil {
		t.Fatalf("apple: %v", err)
	}
	_, _, err := f.verifier.firebaseClaims(context.Background(), f.token(providerClaims("password", false)))
	if !errors.Is(err, domain.ErrEmailNotVerified) {
		t.Fatalf("an unverified password address must still be held, got %v", err)
	}
}

func TestAppleTokenStillNeedsAValidSignatureAndAudience(t *testing.T) {
	f := newFirebaseFixture(t)
	now := time.Now()
	for name, override := range map[string]map[string]any{
		"expired":        {"exp": now.Add(-time.Minute).Unix()},
		"wrong audience": {"aud": "someone-else"},
		"wrong issuer":   {"iss": "https://securetoken.google.com/someone-else"},
	} {
		merged := appleClaims("x@privaterelay.appleid.com", true)
		for k, v := range override {
			merged[k] = v
		}
		if _, err := f.verifier.Verify(context.Background(), f.token(merged)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
