// Package appcheck verifies Firebase App Check tokens (the X-Firebase-AppCheck header): a short-lived JWT that
// Firebase issues to an app instance it has attested (Play Integrity on Android, App Attest or DeviceCheck on iOS),
// so the API can tell the real app from a script that only has a stolen sign-in. It proves the app, not the
// member: sign-in still decides who is asking. Setup and rollout: docs/deployment/10-deploy-guide.md, "App Check".
package appcheck

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

const (
	// Header carries the token on every request.
	Header = "X-Firebase-AppCheck"

	// jwksURL serves the keys App Check tokens are signed with.
	jwksURL = "https://firebaseappcheck.googleapis.com/v1/jwks"
	// issuerPrefix is followed by the Firebase project number.
	issuerPrefix = "https://firebaseappcheck.googleapis.com/"
	// maxTokenLength bounds what is parsed: real tokens are under 1 KB.
	maxTokenLength = 4096
)

var projectNumberPattern = regexp.MustCompile(`^[0-9]{6,20}$`)

// ValidProjectNumber reports whether s looks like a Firebase project number (digits; not the project id).
func ValidProjectNumber(s string) bool { return projectNumberPattern.MatchString(s) }

// Mode is what the API does with the token.
type Mode string

const (
	// Off checks nothing (the default until App Check is set up in the Firebase console and the app sends tokens).
	Off Mode = "false"
	// Log verifies a token when there is one and counts missing and invalid ones, but never refuses.
	Log Mode = "log"
	// Enforce refuses a request without a valid token: 401 APP_CHECK_REQUIRED.
	Enforce Mode = "true"
)

// ParseMode reads APP_CHECK_ENFORCE: false (or empty), log or true.
func ParseMode(s string) (Mode, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "false":
		return Off, nil
	case "log":
		return Log, nil
	case "true":
		return Enforce, nil
	}
	return Off, errors.New("APP_CHECK_ENFORCE must be false, log or true")
}

var (
	// ErrInvalid is a token that is not a valid App Check token for this project.
	ErrInvalid = errors.New("invalid App Check token")
	// ErrUnavailable means the signing keys could not be fetched: not the app's fault, so not an attestation failure.
	ErrUnavailable = errors.New("App Check keys unavailable")
)

// Verifier checks tokens for one Firebase project.
type Verifier struct {
	verifier *oidc.IDTokenVerifier
}

// New verifies App Check tokens for the project with the given number (not its id). Keys are fetched lazily
// and cached, so no network is needed to start.
func New(ctx context.Context, projectNumber string) *Verifier {
	client := &http.Client{Timeout: 10 * time.Second}
	return NewWithKeys(projectNumber, oidc.NewRemoteKeySet(oidc.ClientContext(ctx, client), jwksURL))
}

// NewWithKeys is New with an explicit key set, for tests.
func NewWithKeys(projectNumber string, keys oidc.KeySet) *Verifier {
	return &Verifier{verifier: oidc.NewVerifier(issuerPrefix+projectNumber, fetchGuard{keys},
		&oidc.Config{ClientID: "projects/" + projectNumber, SupportedSigningAlgs: []string{"RS256"}})}
}

type fetchFailedKey struct{}

// fetchGuard tells a key-fetch failure from a bad token: the verifier flattens both into one error, so the
// failure is flagged through the context (as the Firebase sign-in verifier does).
type fetchGuard struct{ keys oidc.KeySet }

func (g fetchGuard) VerifySignature(ctx context.Context, jwt string) ([]byte, error) {
	payload, err := g.keys.VerifySignature(ctx, jwt)
	if err != nil && strings.HasPrefix(err.Error(), "fetching keys") {
		if failed, ok := ctx.Value(fetchFailedKey{}).(*bool); ok {
			*failed = true
		}
	}
	return payload, err
}

// Verify checks the signature (RS256, Firebase's keys), the issuer (https://firebaseappcheck.googleapis.com/<project
// number>), the audience (projects/<project number>), the expiry and that the token names an app (sub). It returns
// ErrInvalid or ErrUnavailable.
func (v *Verifier) Verify(ctx context.Context, raw string) error {
	if raw == "" || len(raw) > maxTokenLength {
		return ErrInvalid
	}
	var keysFailed bool
	token, err := v.verifier.Verify(context.WithValue(ctx, fetchFailedKey{}, &keysFailed), raw)
	if err != nil {
		if keysFailed {
			return ErrUnavailable
		}
		return ErrInvalid
	}
	if token.Subject == "" || len(token.Subject) > 256 {
		return ErrInvalid
	}
	return nil
}
