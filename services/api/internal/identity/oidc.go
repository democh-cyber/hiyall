package identity

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Resolve maps a verified provider identity to an account and session.
type Resolve func(ctx context.Context, issuer, subject, sid string, expiry time.Time) (store.Principal, error)

type Verifier struct {
	verifier *oidc.IDTokenVerifier
	issuer   string
	store    *store.Store
	resolve  Resolve
	// firebase selects Firebase ID-token semantics instead of OIDC access tokens.
	firebase bool
	// seen remembers which sign-ins already have their provider recorded (see recordProvider).
	record func(ctx context.Context, issuer, subject, provider string, appleLinked bool) error
	seenMu sync.Mutex
	seen   map[string]providerInfo
}

func New(ctx context.Context, issuer, audience string, s *store.Store) (*Verifier, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	provider, err := oidc.NewProvider(oidc.ClientContext(ctx, client), issuer)
	if err != nil {
		return nil, err
	}
	return &Verifier{verifier: provider.Verifier(&oidc.Config{ClientID: audience, SupportedSigningAlgs: []string{"RS256", "ES256"}}), issuer: issuer, store: s, resolve: s.ResolveOIDC}, nil
}
func (v *Verifier) Verify(ctx context.Context, raw string) (store.Principal, error) {
	if v.firebase {
		return v.verifyFirebase(ctx, raw)
	}
	token, sid, err := v.accessClaims(ctx, raw)
	if err != nil {
		return store.Principal{}, domain.ErrUnauthorized
	}
	return v.resolve(ctx, v.issuer, token.Subject, sid, token.Expiry)
}
func (v *Verifier) accessClaims(ctx context.Context, raw string) (*oidc.IDToken, string, error) {
	token, err := v.verifier.Verify(ctx, raw)
	if err != nil {
		return nil, "", err
	}
	var claims struct {
		SID      string `json:"sid"`
		TokenUse string `json:"token_use"`
	}
	if err = token.Claims(&claims); err != nil {
		return nil, "", err
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return nil, "", errors.New("invalid access token")
	}
	bytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, "", err
	}
	var header struct {
		Type string `json:"typ"`
	}
	if json.Unmarshal(bytes, &header) != nil {
		return nil, "", errors.New("invalid token header")
	}
	// Explicit access-token semantics prevent an ID token being used as an API credential.
	if claims.SID == "" || len(claims.SID) > 256 || token.Subject == "" || len(token.Subject) > 256 || (!accessTokenType(header.Type) && claims.TokenUse != "access") {
		return nil, "", errors.New("access token with sid required")
	}
	return token, claims.SID, nil
}

func accessTokenType(typ string) bool {
	typ = strings.ToLower(typ)
	return typ == "at+jwt" || typ == "application/at+jwt"
}
