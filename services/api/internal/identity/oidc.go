package identity

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
)

type Verifier struct {
	verifier *oidc.IDTokenVerifier
	issuer   string
	store    *store.Store
}

func New(ctx context.Context, issuer, audience string, s *store.Store) (*Verifier, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	provider, err := oidc.NewProvider(oidc.ClientContext(ctx, client), issuer)
	if err != nil {
		return nil, err
	}
	return &Verifier{provider.Verifier(&oidc.Config{ClientID: audience, SupportedSigningAlgs: []string{"RS256", "ES256"}}), issuer, s}, nil
}
func (v *Verifier) Verify(ctx context.Context, raw string) (store.Principal, error) {
	token, sid, err := v.accessClaims(ctx, raw)
	if err != nil {
		return store.Principal{}, domain.ErrUnauthorized
	}
	return v.store.ResolveOIDC(ctx, v.issuer, token.Subject, sid, token.Expiry)
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
