package identity

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

const (
	// Firebase ID tokens are signed by this key set; the issuer does not serve
	// reliable OIDC discovery, so the keys are read directly.
	firebaseJWKS     = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
	firebaseIssuer   = "https://securetoken.google.com/"
	authTimeSkew     = 5 * time.Minute
	maxSubjectLength = 128
)

// ErrKeysUnavailable means the signing keys could not be fetched. It is not
// ErrUnauthorized, so an outage at the key host is a 503 rather than a sign-out.
var ErrKeysUnavailable = errors.New("signing keys unavailable")

// FirebaseIssuer is the issuer (and the prefix of every token's iss claim) for a Firebase project.
func FirebaseIssuer(projectID string) string { return firebaseIssuer + projectID }

// NewFirebase verifies Firebase Authentication ID tokens for projectID. Keys are
// fetched lazily and cached, so no network is needed to start.
func NewFirebase(ctx context.Context, projectID string, s *store.Store) *Verifier {
	client := &http.Client{Timeout: 10 * time.Second}
	return NewFirebaseWithKeys(projectID, oidc.NewRemoteKeySet(oidc.ClientContext(ctx, client), firebaseJWKS), s)
}

// NewFirebaseWithKeys is NewFirebase with an explicit key set, for tests.
func NewFirebaseWithKeys(projectID string, keys oidc.KeySet, s *store.Store) *Verifier {
	issuer := FirebaseIssuer(projectID)
	var record func(ctx context.Context, issuer, subject, provider string, appleLinked bool) error
	if s != nil {
		record = s.RecordSignInProvider
	}
	return &Verifier{
		record:   record,
		verifier: oidc.NewVerifier(issuer, fetchGuard{keys}, &oidc.Config{ClientID: projectID, SupportedSigningAlgs: []string{"RS256"}}),
		issuer:   issuer,
		store:    s,
		resolve:  s.ResolveOIDC,
		firebase: true,
	}
}

type fetchFailedKey struct{}

// fetchGuard tells key-fetch failures apart from bad tokens: the verifier flattens
// both into one error string, so the failure is flagged through the context.
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

func (v *Verifier) verifyFirebase(ctx context.Context, raw string) (store.Principal, error) {
	token, sid, provider, err := v.firebaseVerified(ctx, raw)
	if err != nil {
		return store.Principal{}, err
	}
	p, err := v.resolve(ctx, v.issuer, token.Subject, sid, token.Expiry)
	if err != nil {
		return p, err
	}
	v.recordProvider(ctx, token.Subject, sid, provider)
	return p, nil
}

// providerInfo is what a Firebase token says about how the person signed in.
type providerInfo struct {
	SignIn      string
	AppleLinked bool
}

// recordProvider stores the sign-in provider on the identity row (audit API-8), once per sign-in (session id)
// per process, so the request path pays one UPDATE per sign-in, not one per request. Existing identities
// fill in the first time they are seen after the release. A failure is logged by the store layer's caller and
// never fails the request: the provider is only used when an account is deleted.
func (v *Verifier) recordProvider(ctx context.Context, subject, sid string, info providerInfo) {
	if v.record == nil {
		return
	}
	v.seenMu.Lock()
	if v.seen[sid] == info {
		v.seenMu.Unlock()
		return
	}
	v.seenMu.Unlock()
	if err := v.record(ctx, v.issuer, subject, info.SignIn, info.AppleLinked); err != nil {
		return
	}
	v.seenMu.Lock()
	if v.seen == nil || len(v.seen) >= maxSeenSignIns {
		v.seen = map[string]providerInfo{}
	}
	v.seen[sid] = info
	v.seenMu.Unlock()
}

const maxSeenSignIns = 100_000

// firebaseClaims verifies a Firebase ID token and derives the session id. Firebase
// ID tokens carry neither a typ header nor a sid, so a session is identified by
// the interactive sign-in: sub plus auth_time, which stays the same across token
// refreshes and changes whenever the person signs in again. Every failure is
// ErrUnauthorized except an unverified password email (ErrEmailNotVerified) and
// unreachable signing keys (ErrKeysUnavailable). Nothing is provisioned here.
func (v *Verifier) firebaseClaims(ctx context.Context, raw string) (*oidc.IDToken, string, error) {
	token, sid, _, err := v.firebaseVerified(ctx, raw)
	return token, sid, err
}

// firebaseVerified is firebaseClaims plus the sign-in provider the token names.
func (v *Verifier) firebaseVerified(ctx context.Context, raw string) (*oidc.IDToken, string, providerInfo, error) {
	var keysFailed bool
	token, err := v.verifier.Verify(context.WithValue(ctx, fetchFailedKey{}, &keysFailed), raw)
	if err != nil {
		if keysFailed {
			return nil, "", providerInfo{}, ErrKeysUnavailable
		}
		return nil, "", providerInfo{}, domain.ErrUnauthorized
	}
	var claims struct {
		AuthTime      *float64 `json:"auth_time"`
		EmailVerified bool     `json:"email_verified"`
		Firebase      struct {
			SignInProvider string                     `json:"sign_in_provider"`
			Identities     map[string]json.RawMessage `json:"identities"`
		} `json:"firebase"`
	}
	if token.Claims(&claims) != nil {
		return nil, "", providerInfo{}, domain.ErrUnauthorized
	}
	now := time.Now()
	if token.Subject == "" || len(token.Subject) > maxSubjectLength {
		return nil, "", providerInfo{}, domain.ErrUnauthorized
	}
	if !token.IssuedAt.IsZero() && token.IssuedAt.After(now.Add(authTimeSkew)) {
		return nil, "", providerInfo{}, domain.ErrUnauthorized
	}
	if claims.AuthTime == nil || *claims.AuthTime != math.Trunc(*claims.AuthTime) || *claims.AuthTime <= 0 || *claims.AuthTime > float64(now.Add(authTimeSkew).Unix()) {
		return nil, "", providerInfo{}, domain.ErrUnauthorized
	}
	provider := claims.Firebase.SignInProvider
	if provider == "" || len(provider) > maxSubjectLength || provider == "anonymous" || provider == "custom" {
		return nil, "", providerInfo{}, domain.ErrUnauthorized
	}
	// A password sign-up can name any address, so the email must be proven before an
	// account exists. Social providers vouch for the address themselves.
	if provider == "password" && !claims.EmailVerified {
		return nil, "", providerInfo{}, domain.ErrEmailNotVerified
	}
	_, linked := claims.Firebase.Identities["apple.com"]
	return token, "fb:" + token.Subject + ":" + strconv.FormatInt(int64(*claims.AuthTime), 10), providerInfo{SignIn: provider, AppleLinked: linked || provider == "apple.com"}, nil
}
