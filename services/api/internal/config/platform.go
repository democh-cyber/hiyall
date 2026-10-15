package config

import (
	"encoding/base64"
	"errors"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"hiyall/services/api/internal/clientip"
	"hiyall/services/api/internal/domain"
)

// Platform holds the cross-cutting settings: client addresses behind a proxy, the cursor key, the database
// pool and its timeouts, the minimum client versions and the log format. See
// infrastructure/docker/api.example.env for every variable.
type Platform struct {
	// TrustedProxies (TRUSTED_PROXY_CIDRS, comma list) are the proxies whose forwarded headers are believed.
	// Empty: the direct peer is the client. ClientIPHeader (CLIENT_IP_HEADER) is a single-address header a
	// trusted proxy sets, such as Fly-Client-IP or CF-Connecting-IP; otherwise the rightmost untrusted
	// X-Forwarded-For hop is used. BehindProxy (BEHIND_PROXY=true) says the API is only reached through a
	// proxy; in production it then refuses to start without TrustedProxies.
	TrustedProxies []netip.Prefix
	ClientIPHeader string
	BehindProxy    bool
	// DirectListener (DIRECT_LISTENER=true) is the operator's statement that clients reach this process
	// directly, with no proxy in front: the peer address is the client. Production needs exactly one of
	// BEHIND_PROXY=true (with TRUSTED_PROXY_CIDRS) and DIRECT_LISTENER=true, so a forgotten proxy setting
	// can no longer pass for a deliberate one (audit API-1).
	DirectListener bool
	// DebugLogPeer (DEBUG_LOG_PEER=true) logs the peer and the forwarding headers of the first 20 requests so
	// the proxy's address can be read from the log. Temporary: unset it once TRUSTED_PROXY_CIDRS is set.
	DebugLogPeer bool

	// CursorKey (CURSOR_KEY, standard or URL-safe base64 of 32 bytes) signs list cursors, so a cursor works
	// on every node and across deploys. Required in production; development uses a random key per process
	// when it is unset. CursorKeyPrevious (CURSOR_KEY_PREVIOUS) is still accepted for verification during a
	// rotation.
	CursorKey, CursorKeyPrevious []byte

	// DBMaxConns (DB_MAX_CONNS, default 20) sizes the pool unless DATABASE_URL carries pool_max_conns,
	// which wins. The timeouts are set on every connection (DB_STATEMENT_TIMEOUT 5s, DB_LOCK_TIMEOUT 3s,
	// DB_IDLE_IN_TRANSACTION_TIMEOUT 15s; Go durations such as 7s or 1m30s).
	DBMaxConns                                       int32
	DBMaxConnsFromDSN                                bool
	DBStatementTimeout, DBLockTimeout, DBIdleTimeout time.Duration

	// MinClientVersion maps a platform (android, ios, web) to the oldest app version (semver) still served;
	// MIN_CLIENT_VERSION_ANDROID, _IOS and _WEB. Missing or empty means no minimum for that platform.
	MinClientVersion map[string]string

	// LogFormat is "json" or "text" (LOG_FORMAT); default json in production, text in development.
	LogFormat string
}

// Defaults for the per-connection database limits.
const (
	DefaultDBMaxConns         = 20
	DefaultStatementTimeout   = 5 * time.Second
	DefaultLockTimeout        = 3 * time.Second
	DefaultIdleInTransTimeout = 15 * time.Second
)

// ClientIPResolver builds the resolver the HTTP layer uses for per-address limits.
func (p Platform) ClientIPResolver() *clientip.Resolver {
	return clientip.New(p.TrustedProxies, p.ClientIPHeader).WithDebug(p.DebugLogPeer)
}

// loadPlatform reads the platform settings and applies the production start checks that span several
// settings. It runs after everything else in Load.
func (c *Config) loadPlatform() error {
	p := &c.Platform
	var err error
	if p.TrustedProxies, err = clientip.ParseCIDRs(os.Getenv("TRUSTED_PROXY_CIDRS")); err != nil {
		return errors.New("TRUSTED_PROXY_CIDRS: " + err.Error())
	}
	p.ClientIPHeader = strings.TrimSpace(os.Getenv("CLIENT_IP_HEADER"))
	if p.ClientIPHeader != "" && !headerName(p.ClientIPHeader) {
		return errors.New("CLIENT_IP_HEADER must be a header name such as Fly-Client-IP")
	}
	if p.ClientIPHeader != "" && len(p.TrustedProxies) == 0 {
		return errors.New("CLIENT_IP_HEADER needs TRUSTED_PROXY_CIDRS: the header is only believed from a trusted proxy")
	}
	switch os.Getenv("BEHIND_PROXY") {
	case "", "false":
	case "true":
		p.BehindProxy = true
	default:
		return errors.New("BEHIND_PROXY must be true or false")
	}
	if p.DirectListener, err = boolEnv("DIRECT_LISTENER"); err != nil {
		return err
	}
	if p.DebugLogPeer, err = boolEnv("DEBUG_LOG_PEER"); err != nil {
		return err
	}
	if p.DirectListener && (p.BehindProxy || len(p.TrustedProxies) > 0) {
		return errors.New("DIRECT_LISTENER=true cannot be combined with BEHIND_PROXY or TRUSTED_PROXY_CIDRS: either a proxy is in front or it is not")
	}

	if p.CursorKey, err = cursorKey("CURSOR_KEY"); err != nil {
		return err
	}
	if p.CursorKeyPrevious, err = cursorKey("CURSOR_KEY_PREVIOUS"); err != nil {
		return err
	}
	if p.CursorKeyPrevious != nil && p.CursorKey == nil {
		return errors.New("CURSOR_KEY_PREVIOUS needs CURSOR_KEY")
	}

	p.DBMaxConns = DefaultDBMaxConns
	if v := os.Getenv("DB_MAX_CONNS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 2 || n > 500 {
			return errors.New("DB_MAX_CONNS must be a number from 2 to 500")
		}
		p.DBMaxConns = int32(n)
	}
	p.DBMaxConnsFromDSN = strings.Contains(c.DatabaseURL, "pool_max_conns")
	for _, d := range []struct {
		name     string
		target   *time.Duration
		fallback time.Duration
	}{
		{"DB_STATEMENT_TIMEOUT", &p.DBStatementTimeout, DefaultStatementTimeout},
		{"DB_LOCK_TIMEOUT", &p.DBLockTimeout, DefaultLockTimeout},
		{"DB_IDLE_IN_TRANSACTION_TIMEOUT", &p.DBIdleTimeout, DefaultIdleInTransTimeout},
	} {
		*d.target = d.fallback
		if v := os.Getenv(d.name); v != "" {
			parsed, err := time.ParseDuration(v)
			// 0 turns the limit off (PostgreSQL's meaning), which is allowed but never the default.
			if err != nil || parsed < 0 || parsed > time.Hour {
				return errors.New(d.name + " must be a duration from 0 to 1h, such as 5s")
			}
			*d.target = parsed
		}
	}

	p.MinClientVersion = map[string]string{}
	for platform, name := range map[string]string{"android": "MIN_CLIENT_VERSION_ANDROID", "ios": "MIN_CLIENT_VERSION_IOS", "web": "MIN_CLIENT_VERSION_WEB"} {
		v := strings.TrimSpace(os.Getenv(name))
		if v == "" {
			continue
		}
		if _, ok := domain.ParseClientVersion(v); !ok {
			return errors.New(name + " must be a version such as 1.4.0")
		}
		p.MinClientVersion[platform] = v
	}

	switch p.LogFormat = os.Getenv("LOG_FORMAT"); p.LogFormat {
	case "":
		p.LogFormat = "text"
		if c.Env == "production" {
			p.LogFormat = "json"
		}
	case "json", "text":
	default:
		return errors.New("LOG_FORMAT must be json or text")
	}

	if c.Env == "production" {
		return c.productionChecks()
	}
	return nil
}

// productionChecks refuse a production start that would break a promise made elsewhere (privacy policy,
// teens document) or that would silently degrade under load.
func (c *Config) productionChecks() error {
	p := c.Platform
	if p.BehindProxy && len(p.TrustedProxies) == 0 {
		return errors.New("BEHIND_PROXY=true needs TRUSTED_PROXY_CIDRS in production: without it every client shares the proxy's rate-limit bucket")
	}
	if !p.BehindProxy && !p.DirectListener {
		return errors.New("production needs BEHIND_PROXY=true with TRUSTED_PROXY_CIDRS (the API is behind a proxy), or DIRECT_LISTENER=true (clients reach it directly): without one of them the client address cannot be trusted")
	}
	if p.CursorKey == nil {
		return errors.New("CURSOR_KEY (base64 of 32 random bytes: openssl rand -base64 32) is required in production")
	}
	if !c.AgeBandIsolation {
		return errors.New("AGE_BAND_ISOLATION=false is refused in production: minors and adults are always kept apart")
	}
	if c.RateLimitBackend != "postgres" {
		return errors.New("RATE_LIMIT_BACKEND=postgres is required in production: per-node limits multiply with every machine")
	}
	// The account purge must delete the Firebase user too (the privacy policy says so).
	if c.FirebaseProjectID != "" || strings.HasPrefix(c.Issuer, "https://securetoken.google.com/") {
		if c.FirebaseServiceAccountFile == "" {
			return errors.New("FIREBASE_SERVICE_ACCOUNT_FILE is required in production: an account purge must delete the Firebase user")
		}
		if data, err := os.ReadFile(c.FirebaseServiceAccountFile); err != nil || len(data) == 0 {
			return errors.New("FIREBASE_SERVICE_ACCOUNT_FILE cannot be read")
		}
	}
	return nil
}

func cursorKey(name string) ([]byte, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return nil, nil
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if key, err := enc.DecodeString(v); err == nil {
			if len(key) != 32 {
				break
			}
			return key, nil
		}
	}
	return nil, errors.New(name + " must be base64 of exactly 32 bytes (openssl rand -base64 32)")
}

func headerName(s string) bool {
	if len(s) > 64 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
			return false
		}
	}
	return true
}
