package billing

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// AdMobKeysURL is where Google publishes the public keys that sign server-side verification callbacks.
	AdMobKeysURL = "https://www.gstatic.com/admob/reward/verifier-keys.json"
	adKeysTTL    = 24 * time.Hour
	// SSVMaxAge is how old a callback's timestamp may be.
	SSVMaxAge = 24 * time.Hour
)

// Reward is a verified AdMob server-side-verification callback.
type Reward struct {
	AdUnit        string
	TransactionID string
	UserID        string
	CustomData    string
	Timestamp     time.Time
}

// AdMob verifies SSV callbacks: the signature is ECDSA P-256 over the query string up to "&signature=", with one of Google's published keys
// (https://developers.google.com/admob/android/ssv).
type AdMob struct {
	KeysURL string
	// AdUnits are the ad units that may credit coins (full "ca-app-pub-x/y" or only the unit id after the slash).
	AdUnits []string
	HTTP    *http.Client
	Now     func() time.Time

	mu      sync.Mutex
	keys    map[int64]*ecdsa.PublicKey
	fetched time.Time
}

// NewAdMob returns a verifier for the given ad units.
func NewAdMob(adUnits []string) *AdMob {
	return &AdMob{KeysURL: AdMobKeysURL, AdUnits: adUnits, HTTP: &http.Client{Timeout: 10 * time.Second}, Now: time.Now}
}

func (m *AdMob) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func unitID(s string) string {
	if i := strings.LastIndex(s, "/"); i >= 0 {
		return s[i+1:]
	}
	return s
}

func (m *AdMob) unitAllowed(unit string) bool {
	for _, u := range m.AdUnits {
		if unitID(u) == unitID(unit) {
			return true
		}
	}
	return false
}

// key returns the public key with id, refetching the list when it is older than a day or does not hold the id (Google rotates keys).
func (m *AdMob) key(ctx context.Context, id int64) (*ecdsa.PublicKey, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	fresh := m.keys != nil && m.now().Sub(m.fetched) < adKeysTTL
	if k, ok := m.keys[id]; ok && fresh {
		return k, nil
	}
	// A key id we do not know refetches at most once a minute, so garbage key ids cannot make us hammer Google.
	if m.keys != nil && m.now().Sub(m.fetched) < time.Minute {
		return nil, ErrInvalid
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.KeysURL, nil)
	if err != nil {
		return nil, ErrMisconfigured
	}
	resp, err := m.HTTP.Do(req)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, ErrUnavailable
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<18))
	var list struct {
		Keys []struct {
			KeyID int64  `json:"keyId"`
			PEM   string `json:"pem"`
		} `json:"keys"`
	}
	if json.Unmarshal(raw, &list) != nil {
		return nil, ErrUnavailable
	}
	keys := map[int64]*ecdsa.PublicKey{}
	for _, k := range list.Keys {
		block, _ := pem.Decode([]byte(k.PEM))
		if block == nil {
			continue
		}
		pub, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			continue
		}
		if e, ok := pub.(*ecdsa.PublicKey); ok {
			keys[k.KeyID] = e
		}
	}
	m.keys, m.fetched = keys, m.now()
	if k, ok := keys[id]; ok {
		return k, nil
	}
	return nil, ErrInvalid
}

// Verify checks a callback's raw query string and returns the reward it describes. ErrInvalid: a bad or missing signature, an ad unit
// that is not ours, an old timestamp or missing fields.
func (m *AdMob) Verify(ctx context.Context, rawQuery string) (Reward, error) {
	var r Reward
	idx := strings.Index(rawQuery, "&signature=")
	if idx < 0 {
		return r, ErrInvalid
	}
	signed := rawQuery[:idx]
	q, err := url.ParseQuery(rawQuery)
	if err != nil {
		return r, ErrInvalid
	}
	keyID, err := strconv.ParseInt(q.Get("key_id"), 10, 64)
	if err != nil {
		return r, ErrInvalid
	}
	sig, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(q.Get("signature"), "="))
	if err != nil || len(sig) == 0 {
		return r, ErrInvalid
	}
	pub, err := m.key(ctx, keyID)
	if err != nil {
		return r, err
	}
	sum := sha256.Sum256([]byte(signed))
	if !ecdsa.VerifyASN1(pub, sum[:], sig) {
		return r, ErrInvalid
	}
	ts, err := strconv.ParseInt(q.Get("timestamp"), 10, 64)
	if err != nil {
		return r, ErrInvalid
	}
	// SSV timestamps are in milliseconds.
	r = Reward{AdUnit: q.Get("ad_unit"), TransactionID: q.Get("transaction_id"), UserID: q.Get("user_id"), CustomData: q.Get("custom_data"), Timestamp: time.UnixMilli(ts)}
	if r.TransactionID == "" || r.UserID == "" || r.CustomData == "" || !m.unitAllowed(r.AdUnit) {
		return Reward{}, ErrInvalid
	}
	if age := m.now().Sub(r.Timestamp); age > SSVMaxAge || age < -time.Hour {
		return Reward{}, ErrInvalid
	}
	return r, nil
}
