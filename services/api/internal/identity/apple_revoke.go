package identity

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Sign in with Apple token revocation (App Store guideline 5.1.1(v)): when an account is deleted, the app's
// Apple authorization must be revoked at Apple. Firebase does not give the server Apple's refresh token,
// so the app re-authenticates with Apple during deletion, sends the one-time authorization code with the
// deletion request, and this file does the rest with Apple's REST API:
//
//	POST https://appleid.apple.com/auth/token   code -> refresh token
//	POST https://appleid.apple.com/auth/revoke  refresh token -> revoked
//
// Both calls are authenticated with a client secret: an ES256 JWT signed with the Apple key (.p8) for the
// team, key id and client id (the app's bundle id, or the Services ID on the web). No SDK.

const (
	appleAudience  = "https://appleid.apple.com"
	appleTokenURL  = appleAudience + "/auth/token"
	appleRevokeURL = appleAudience + "/auth/revoke"
)

// AppleConfig is the Apple developer account side of the revocation.
type AppleConfig struct {
	TeamID, KeyID, ClientID, PrivateKeyFile string
}

// AppleRevoker exchanges authorization codes and revokes refresh tokens.
type AppleRevoker struct {
	teamID, keyID, clientID string
	key                     *ecdsa.PrivateKey
	seal                    cipher.AEAD
	tokenURL, revokeURL     string
	client                  *http.Client
	now                     func() time.Time
}

// NewAppleRevoker reads the key file once. An unreadable key, or one that is not a P-256 PKCS#8 key, is an
// error, so a bad configuration stops the server at start rather than at the first deletion.
func NewAppleRevoker(c AppleConfig) (*AppleRevoker, error) {
	raw, err := os.ReadFile(c.PrivateKeyFile)
	if err != nil {
		return nil, errors.New("cannot read APPLE_PRIVATE_KEY_FILE")
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("APPLE_PRIVATE_KEY_FILE is not a PEM key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	key, ok := parsed.(*ecdsa.PrivateKey)
	if err != nil || !ok || key.Curve.Params().BitSize != 256 {
		return nil, errors.New("APPLE_PRIVATE_KEY_FILE must be an Apple .p8 (PKCS#8 P-256) key")
	}
	// Tokens queued for a retry are sealed with a key derived from the Apple key file, so no second secret
	// is needed; replacing the Apple key makes queued tokens unreadable (they are then dropped with a warning).
	sealKey := sha256.Sum256(append([]byte("hiyall/apple-revocation/v1\x00"), raw...))
	blockCipher, _ := aes.NewCipher(sealKey[:])
	gcm, _ := cipher.NewGCM(blockCipher)
	if c.TeamID == "" || c.KeyID == "" || c.ClientID == "" {
		return nil, errors.New("APPLE_TEAM_ID, APPLE_KEY_ID and APPLE_CLIENT_ID are required")
	}
	return &AppleRevoker{teamID: c.TeamID, keyID: c.KeyID, clientID: c.ClientID, key: key, seal: gcm,
		tokenURL: appleTokenURL, revokeURL: appleRevokeURL, client: &http.Client{Timeout: 10 * time.Second}, now: time.Now}, nil
}

// clientSecret is the JWT Apple asks for: valid five minutes, the shortest that survives clock skew.
func (a *AppleRevoker) clientSecret() (string, error) {
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.keyID, "typ": "JWT"})
	now := a.now()
	claims, _ := json.Marshal(map[string]any{"iss": a.teamID, "iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix(), "aud": appleAudience, "sub": a.clientID})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + enc.EncodeToString(sig), nil
}

func (a *AppleRevoker) post(ctx context.Context, endpoint string, form url.Values) ([]byte, error) {
	secret, err := a.clientSecret()
	if err != nil {
		return nil, err
	}
	form.Set("client_id", a.clientID)
	form.Set("client_secret", secret)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, errors.New("apple unreachable")
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != http.StatusOK {
		// Apple's error body names the problem (invalid_grant, invalid_client) and holds no secret.
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(body, &e)
		return nil, fmt.Errorf("apple answered %d %s", resp.StatusCode, e.Error)
	}
	return body, nil
}

// ExchangeCode trades the one-time authorization code from the app's Apple re-sign-in for a refresh token.
func (a *AppleRevoker) ExchangeCode(ctx context.Context, code string) (string, error) {
	body, err := a.post(ctx, a.tokenURL, url.Values{"code": {code}, "grant_type": {"authorization_code"}})
	if err != nil {
		return "", err
	}
	var out struct {
		RefreshToken string `json:"refresh_token"`
	}
	if json.Unmarshal(body, &out) != nil || out.RefreshToken == "" {
		return "", errors.New("apple answer had no refresh token")
	}
	return out.RefreshToken, nil
}

// Revoke ends the app's Apple authorization for the refresh token. Revoking one that is already revoked
// is not an error at Apple.
func (a *AppleRevoker) Revoke(ctx context.Context, refreshToken string) error {
	_, err := a.post(ctx, a.revokeURL, url.Values{"token": {refreshToken}, "token_type_hint": {"refresh_token"}})
	return err
}

// RevokeAuthorizationCode is what the deletion request calls: exchange, then revoke. When the exchange
// worked but the revoke did not, the refresh token comes back sealed so the caller can queue it for the
// purge to retry; when the exchange itself failed there is nothing to keep and err says so (the code is
// single use and expires in minutes, so the member must sign in with Apple again to retry).
func (a *AppleRevoker) RevokeAuthorizationCode(ctx context.Context, code string) (queued []byte, err error) {
	token, err := a.ExchangeCode(ctx, code)
	if err != nil {
		return nil, err
	}
	if err = a.Revoke(ctx, token); err != nil {
		slog.Warn("apple token revoke failed; queued for the account purge", "reason", err.Error())
		return a.Seal(token), nil
	}
	return nil, nil
}

// Seal encrypts a refresh token for storage.
func (a *AppleRevoker) Seal(token string) []byte {
	nonce := make([]byte, a.seal.NonceSize())
	_, _ = rand.Read(nonce)
	return a.seal.Seal(nonce, nonce, []byte(token), nil)
}

// Open reverses Seal.
func (a *AppleRevoker) Open(sealed []byte) (string, error) {
	n := a.seal.NonceSize()
	if len(sealed) < n {
		return "", errors.New("sealed token too short")
	}
	plain, err := a.seal.Open(nil, sealed[:n], sealed[n:], nil)
	return string(plain), err
}

// AppleQueue is the part of the store the purge needs for queued revocations.
type AppleQueue interface {
	PendingAppleRevocation(ctx context.Context, issuer, subject string) ([]byte, error)
	DoneAppleRevocation(ctx context.Context, issuer, subject string) error
}

// IdentityDeleter is what the account purge calls for each identity (store.IdentityDeleter).
type IdentityDeleter interface {
	DeleteIdentity(ctx context.Context, issuer, subject string) error
}

// AppleDeleter finishes any queued Apple revocation before the identity provider account is deleted. A
// revoke that still fails makes the purge retry on its next run, like a failed identity deletion.
type AppleDeleter struct {
	Inner   IdentityDeleter
	Revoker *AppleRevoker
	Queue   AppleQueue
}

func (d AppleDeleter) DeleteIdentity(ctx context.Context, issuer, subject string) error {
	sealed, err := d.Queue.PendingAppleRevocation(ctx, issuer, subject)
	if err != nil {
		return err
	}
	if sealed != nil {
		token, openErr := d.Revoker.Open(sealed)
		if openErr != nil {
			// The Apple key changed since the token was sealed; it cannot be revoked any more.
			slog.Warn("queued apple token unreadable (key replaced); dropping it")
		} else if err = d.Revoker.Revoke(ctx, token); err != nil {
			return errors.New("apple token not revoked; the purge retries it on the next run")
		}
		if err = d.Queue.DoneAppleRevocation(ctx, issuer, subject); err != nil {
			return err
		}
	}
	return d.Inner.DeleteIdentity(ctx, issuer, subject)
}
