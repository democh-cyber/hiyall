package push

import (
	"bytes"
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
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	fcmScope    = "https://www.googleapis.com/auth/firebase.messaging"
	fcmEndpoint = "https://fcm.googleapis.com"
	// AndroidChannel is the notification channel the app creates (MainActivity) and the
	// manifest names as its default; pushes that arrive while the app is closed use it.
	AndroidChannel = "hiyall_default"
	// How long a provider may hold a push for an offline device. The app syncs on open,
	// so a push older than this would only be noise.
	pushTTL = 4 * time.Hour
	// The cached access token is refreshed this long before it expires.
	tokenMargin = 5 * time.Minute
)

// ServiceAccount is the part of a Google service-account key file the sender needs.
// The private key never appears in an error or a log line.
type ServiceAccount struct {
	Type         string `json:"type"`
	ProjectID    string `json:"project_id"`
	PrivateKeyID string `json:"private_key_id"`
	PrivateKey   string `json:"private_key"`
	ClientEmail  string `json:"client_email"`
	TokenURI     string `json:"token_uri"`
}

// LoadServiceAccount reads and validates a service-account JSON file. Errors say what
// is wrong with the file, never what is in it.
func LoadServiceAccount(path string) (ServiceAccount, error) {
	var sa ServiceAccount
	raw, err := os.ReadFile(path)
	if err != nil {
		return sa, errors.New("cannot read the FCM service account file")
	}
	if json.Unmarshal(raw, &sa) != nil {
		return sa, errors.New("the FCM service account file is not valid JSON")
	}
	if sa.Type != "service_account" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return sa, errors.New("the FCM service account file is not a service account key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	if u, err := url.Parse(sa.TokenURI); err != nil || u.Scheme != "https" {
		return sa, errors.New("the FCM service account token_uri must be https")
	}
	if _, err = sa.key(); err != nil {
		return sa, err
	}
	return sa, nil
}

func (sa ServiceAccount) key() (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errors.New("the FCM service account private key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("the FCM service account private key is not PKCS#8")
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("the FCM service account private key is not RSA")
	}
	return key, nil
}

// FCM sends through the Firebase Cloud Messaging HTTP v1 API. One provider covers
// Android and iOS: the APNs key is uploaded in the Firebase console and FCM forwards
// to Apple. The OAuth2 access token comes from a signed service-account JWT
// (RS256) exchanged at the account's token endpoint, cached until shortly before it expires.
type FCM struct {
	ProjectID string
	Account   ServiceAccount
	// Endpoint is the FCM host; empty means Google's. Tests point it at an httptest server.
	Endpoint string
	HTTP     *http.Client
	Now      func() time.Time

	mu      sync.Mutex
	key     *rsa.PrivateKey
	token   string
	expires time.Time
}

// NewFCM validates the account and returns a sender with a 10 second per-request timeout.
func NewFCM(projectID string, sa ServiceAccount) (*FCM, error) {
	key, err := sa.key()
	if err != nil {
		return nil, err
	}
	if projectID == "" {
		projectID = sa.ProjectID
	}
	if projectID == "" {
		return nil, errors.New("FCM_PROJECT_ID is required")
	}
	return &FCM{ProjectID: projectID, Account: sa, HTTP: &http.Client{Timeout: 10 * time.Second}, Now: time.Now, key: key}, nil
}

func (f *FCM) now() time.Time {
	if f.Now != nil {
		return f.Now()
	}
	return time.Now()
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// assertion is the signed JWT that is exchanged for an access token.
func (f *FCM) assertion(now time.Time) (string, error) {
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": f.Account.PrivateKeyID})
	claims, _ := json.Marshal(map[string]any{"iss": f.Account.ClientEmail, "scope": fcmScope, "aud": f.Account.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
	signing := b64(header) + "." + b64(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", errors.New("cannot sign the FCM token request")
	}
	return signing + "." + b64(sig), nil
}

// accessToken returns the cached token, fetching a new one when it is missing or
// within tokenMargin of expiry. Concurrent senders wait for one fetch instead of each making their own.
func (f *FCM) accessToken(ctx context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	now := f.now()
	if f.token != "" && now.Add(tokenMargin).Before(f.expires) {
		return f.token, nil
	}
	assertion, err := f.assertion(now)
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.Account.TokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", errors.New("invalid FCM token endpoint")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := f.HTTP.Do(req)
	if err != nil {
		return "", &TransientError{Err: errors.New("FCM token request failed: " + errKind(err))}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusOK {
		err := fmt.Errorf("FCM token request refused (HTTP %d)", resp.StatusCode)
		if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
			return "", &TransientError{Err: err, After: retryAfter(resp)}
		}
		return "", err
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if json.Unmarshal(body, &out) != nil || out.AccessToken == "" {
		return "", errors.New("FCM token response was not understood")
	}
	if out.ExpiresIn <= 0 {
		out.ExpiresIn = 3600
	}
	f.token, f.expires = out.AccessToken, now.Add(time.Duration(out.ExpiresIn)*time.Second)
	return f.token, nil
}

// forget drops the cached token when FCM says it was refused.
func (f *FCM) forget(token string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.token == token {
		f.token = ""
	}
}

// errKind names a network failure without its text, which can contain URLs.
func errKind(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "canceled"
	}
	return "network error"
}

func retryAfter(resp *http.Response) time.Duration {
	if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s > 0 {
		return min(time.Duration(s)*time.Second, time.Minute)
	}
	return 0
}

// payload is the FCM v1 message for one device. Both platforms get the same visible
// notification (so the system shows it even when the app is closed) and the same data keys.
func (f *FCM) payload(t Target, m Message) any {
	android := map[string]any{
		"priority":     "HIGH",
		"ttl":          fmt.Sprintf("%ds", int(pushTTL.Seconds())),
		"notification": map[string]any{"channel_id": AndroidChannel},
	}
	headers := map[string]string{
		"apns-push-type":  "alert",
		"apns-priority":   "10",
		"apns-expiration": strconv.FormatInt(f.now().Add(pushTTL).Unix(), 10),
	}
	if m.CollapseKey != "" {
		android["collapse_key"] = m.CollapseKey
		headers["apns-collapse-id"] = m.CollapseKey
	}
	return map[string]any{"message": map[string]any{
		"token":        t.Token,
		"notification": map[string]string{"title": m.Title, "body": m.Body},
		"data":         m.Data,
		"android":      android,
		"apns":         map[string]any{"headers": headers, "payload": map[string]any{"aps": map[string]any{"sound": "default"}}},
	}}
}

// Send delivers one message. Provider "apns" is accepted by the API but not implemented:
// the device would need a raw APNs token, and iOS registers its FCM token instead.
func (f *FCM) Send(ctx context.Context, t Target, m Message) error {
	if t.Provider != "fcm" {
		return fmt.Errorf("push provider %q is not implemented", t.Provider)
	}
	access, err := f.accessToken(ctx)
	if err != nil {
		return err
	}
	raw, err := json.Marshal(f.payload(t, m))
	if err != nil {
		return err
	}
	endpoint := f.Endpoint
	if endpoint == "" {
		endpoint = fcmEndpoint
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/projects/"+url.PathEscape(f.ProjectID)+"/messages:send", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	resp, err := f.HTTP.Do(req)
	if err != nil {
		return &TransientError{Err: errors.New("FCM request failed: " + errKind(err))}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	if resp.StatusCode == http.StatusUnauthorized {
		f.forget(access)
	}
	return fcmError(resp, body)
}

// fcmError maps an FCM v1 error response. The body's message text is not logged: it can
// echo request fields.
func fcmError(resp *http.Response, body []byte) error {
	var e struct {
		Error struct {
			Status  string `json:"status"`
			Message string `json:"message"`
			Details []struct {
				ErrorCode       string `json:"errorCode"`
				FieldViolations []struct {
					Field string `json:"field"`
				} `json:"fieldViolations"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	code := ""
	badToken := false
	for _, d := range e.Error.Details {
		if d.ErrorCode != "" {
			code = d.ErrorCode
		}
		for _, v := range d.FieldViolations {
			badToken = badToken || strings.HasSuffix(v.Field, ".token")
		}
	}
	if code == "" {
		code = e.Error.Status
	}
	label := fmt.Sprintf("FCM refused the push (HTTP %d %s)", resp.StatusCode, code)
	switch {
	// A bare 404 NOT_FOUND is not enough: a wrong project id answers that too, and must not wipe every token.
	case code == "UNREGISTERED":
		return fmt.Errorf("%w: %s", ErrUnregistered, label)
	// The credentials and the device token belong to different Firebase projects: that is this server's
	// configuration, and it would wipe every token if it were treated as a dead one.
	case code == "SENDER_ID_MISMATCH":
		return fmt.Errorf("%w: %s", ErrConfig, label)
	case code == "INVALID_ARGUMENT" && (badToken || strings.Contains(strings.ToLower(e.Error.Message), "registration token")):
		return fmt.Errorf("%w: %s", ErrUnregistered, label)
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 || resp.StatusCode == http.StatusUnauthorized:
		return &TransientError{Err: errors.New(label), After: retryAfter(resp)}
	}
	return errors.New(label)
}
