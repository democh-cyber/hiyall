package identity

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
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
	"sync"
	"time"
)

// Deleting the identity-provider account is the last step of an account purge (store.IdentityDeleter), so
// the same Google or password sign-in does not quietly open a new, empty member. It is a few REST calls:
// a service account signs a JWT, Google's token endpoint trades it for an access token, and Identity Toolkit's
// accounts:delete removes the Firebase user. No SDK is used. The service account needs the Firebase
// Authentication Admin role (or any role with firebaseauth.users.delete).

const (
	identityToolkit = "https://identitytoolkit.googleapis.com/v1/projects/"
	googleTokenURI  = "https://oauth2.googleapis.com/token"
	deleteScope     = "https://www.googleapis.com/auth/cloud-platform"
)

// LogDeleter stands in when no service account is configured: the purge completes without touching the
// identity provider, and says so. The Firebase user then still exists; signing in with it creates a new member.
type LogDeleter struct{}

func (LogDeleter) DeleteIdentity(context.Context, string, string) error {
	slog.Warn("identity provider account not deleted: FIREBASE_SERVICE_ACCOUNT_FILE is not configured")
	return nil
}

// FirebaseDeleter deletes Firebase users of one project.
type FirebaseDeleter struct {
	projectID string
	email     string
	key       *rsa.PrivateKey
	tokenURI  string
	apiBase   string
	client    *http.Client
	now       func() time.Time

	mu      sync.Mutex
	token   string
	expires time.Time
}

// NewFirebaseDeleter reads a service-account key file (the JSON downloaded from Google Cloud). The
// file is read once here; a file that cannot be read or is not a service account key is an error, so a
// broken configuration stops the server at startup rather than after the first deletion.
func NewFirebaseDeleter(projectID, file string) (*FirebaseDeleter, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, errors.New("cannot read FIREBASE_SERVICE_ACCOUNT_FILE")
	}
	var account struct {
		Type        string `json:"type"`
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if json.Unmarshal(data, &account) != nil || account.ClientEmail == "" || account.PrivateKey == "" || (account.Type != "" && account.Type != "service_account") {
		return nil, errors.New("FIREBASE_SERVICE_ACCOUNT_FILE is not a service account key")
	}
	block, _ := pem.Decode([]byte(account.PrivateKey))
	if block == nil {
		return nil, errors.New("FIREBASE_SERVICE_ACCOUNT_FILE has no private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	key, ok := parsed.(*rsa.PrivateKey)
	if err != nil || !ok {
		return nil, errors.New("FIREBASE_SERVICE_ACCOUNT_FILE has an unusable private key")
	}
	if account.TokenURI == "" {
		account.TokenURI = googleTokenURI
	}
	return &FirebaseDeleter{projectID: projectID, email: account.ClientEmail, key: key, tokenURI: account.TokenURI, apiBase: identityToolkit,
		client: &http.Client{Timeout: 15 * time.Second}, now: time.Now}, nil
}

// DeleteIdentity deletes the Firebase user with this subject (its uid). An identity from another issuer is
// not ours to delete and is skipped; a user that is already gone counts as deleted.
func (d *FirebaseDeleter) DeleteIdentity(ctx context.Context, issuer, subject string) error {
	if issuer != FirebaseIssuer(d.projectID) {
		slog.Warn("identity not deleted: not a Firebase identity of this project")
		return nil
	}
	token, err := d.accessToken(ctx)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]string{"localId": subject})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.apiBase+d.projectID+"/accounts:delete", strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := d.client.Do(req)
	if err != nil {
		return errors.New("identity provider unreachable")
	}
	defer res.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	if res.StatusCode/100 == 2 {
		return nil
	}
	var failure struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(payload, &failure)
	if res.StatusCode == http.StatusBadRequest && strings.HasPrefix(failure.Error.Message, "USER_NOT_FOUND") {
		return nil
	}
	if res.StatusCode == http.StatusUnauthorized {
		d.forgetToken()
	}
	// The provider's message names the operation, never the person; the subject is not repeated.
	return fmt.Errorf("identity provider refused the deletion (HTTP %d, %s)", res.StatusCode, failure.Error.Message)
}

func (d *FirebaseDeleter) forgetToken() {
	d.mu.Lock()
	d.token = ""
	d.mu.Unlock()
}

// accessToken returns a cached OAuth token, minting a new one a minute before the old one ends.
func (d *FirebaseDeleter) accessToken(ctx context.Context) (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.token != "" && d.now().Add(time.Minute).Before(d.expires) {
		return d.token, nil
	}
	now := d.now()
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{"iss": d.email, "scope": deleteScope, "aud": d.tokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, d.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", errors.New("cannot sign the service account assertion")
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.tokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := d.client.Do(req)
	if err != nil {
		return "", errors.New("identity provider token endpoint unreachable")
	}
	defer res.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err = json.NewDecoder(io.LimitReader(res.Body, 16384)).Decode(&out); err != nil || res.StatusCode != http.StatusOK || out.AccessToken == "" {
		return "", fmt.Errorf("identity provider refused the service account (HTTP %d)", res.StatusCode)
	}
	d.token = out.AccessToken
	d.expires = now.Add(time.Duration(out.ExpiresIn) * time.Second)
	return d.token, nil
}
