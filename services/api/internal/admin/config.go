package admin

import (
	"encoding/base64"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"os"
	"strings"

	"hiyall/services/api/internal/clientip"
)

// Config is the admin console's process configuration. It is read from the environment and shares
// nothing with the public API's config: the two binaries have separate settings and separate listeners.
type Config struct {
	Env         string // APP_ENV: development or production
	DatabaseURL string // ADMIN_DATABASE_URL (the hiyall_admin role), else DATABASE_URL (see database/roles/roles.sql)
	// SharedDatabase is true when the console runs on DATABASE_URL, the API's role. Production refuses that
	// unless ADMIN_ALLOW_SHARED_DB=true: the API role has no access to the operator tables.
	SharedDatabase bool
	// Media (ADMIN_MEDIA_*) is a READ-ONLY token for the media bucket, used to show reported photos and,
	// to administrators, quarantined ones. Optional: without it the console shows content text only.
	MediaEndpoint, MediaAccessKey, MediaSecretKey, MediaBucket, MediaRegion string
	MediaSecure                                                             bool
	Addr                                                                    string // ADMIN_ADDR, default 127.0.0.1:8081
	StaticDir                                                               string // ADMIN_STATIC_DIR, default apps/admin/dist
	// AllowRemote (ADMIN_ALLOW_REMOTE=true) permits a listener that is not loopback. It is only accepted
	// with TLS in front: native TLS (ADMIN_TLS_CERT and ADMIN_TLS_KEY) or a trusted TLS terminating
	// reverse proxy (ADMIN_TRUST_PROXY=true).
	AllowRemote bool
	// TrustProxy (ADMIN_TRUST_PROXY=true) says a reverse proxy that terminates TLS and that you control
	// is in front. The console then takes the client address from the last X-Forwarded-For entry,
	// refuses any request that did not arrive as X-Forwarded-Proto: https, and marks cookies Secure.
	TrustProxy bool
	// TrustedProxies (ADMIN_TRUSTED_PROXY_CIDRS) are the proxies whose X-Forwarded-For the console believes,
	// and ClientIPHeader (ADMIN_CLIENT_IP_HEADER) an optional single-address header they set. A request from
	// any other peer is keyed by the peer, so nobody can pick their own lockout bucket or audit address by
	// sending a header (audit, admin clientIP). Production needs them with ADMIN_TRUST_PROXY=true.
	TrustedProxies []netip.Prefix
	ClientIPHeader string
	// Evidence (ADMIN_EVIDENCE_*) is the READ-ONLY token for the evidence bucket that holds quarantined
	// originals, apart from the media bucket. EvidenceDeleteAccessKey and EvidenceDeleteSecretKey
	// (ADMIN_EVIDENCE_DELETE_*) are a different credential for the same bucket that may delete: only the hold
	// purge job (admin purge-holds, or the hourly loop in serve) uses it, never a request. Without
	// ADMIN_EVIDENCE_ENDPOINT, cases are read from the media bucket (development, or
	// EVIDENCE_ALLOW_SHARED_BUCKET=true).
	EvidenceEndpoint, EvidenceAccessKey, EvidenceSecretKey, EvidenceBucket, EvidenceRegion string
	EvidenceSecure                                                                         bool
	EvidenceDeleteAccessKey, EvidenceDeleteSecretKey                                       string
	TLSCert, TLSKey                                                                        string
	AllowedHosts                                                                           []string // ADMIN_ALLOWED_HOSTS: Host header values (without port) the console answers to
	DataKey                                                                                []byte   // ADMIN_DATA_KEY or ADMIN_DATA_KEY_FILE: 32 random bytes, base64
	SecureCookies                                                                          bool     // derived: cookies carry Secure and the __Host- prefix
	TLSInFront                                                                             bool     // derived: native TLS or a trusted proxy
}

// LoadConfig reads and validates the configuration. getenv is os.Getenv in production.
func LoadConfig(getenv func(string) string) (Config, error) {
	c := Config{
		Env: getenv("APP_ENV"), DatabaseURL: getenv("ADMIN_DATABASE_URL"), Addr: getenv("ADMIN_ADDR"), StaticDir: getenv("ADMIN_STATIC_DIR"),
		AllowRemote: getenv("ADMIN_ALLOW_REMOTE") == "true", TrustProxy: getenv("ADMIN_TRUST_PROXY") == "true",
		TLSCert: getenv("ADMIN_TLS_CERT"), TLSKey: getenv("ADMIN_TLS_KEY"),
	}
	if c.DatabaseURL == "" {
		c.DatabaseURL, c.SharedDatabase = getenv("DATABASE_URL"), true
	}
	c.MediaEndpoint, c.MediaAccessKey, c.MediaSecretKey = getenv("ADMIN_MEDIA_ENDPOINT"), getenv("ADMIN_MEDIA_ACCESS_KEY"), getenv("ADMIN_MEDIA_SECRET_KEY")
	c.MediaBucket, c.MediaRegion, c.MediaSecure = getenv("ADMIN_MEDIA_BUCKET"), getenv("ADMIN_MEDIA_REGION"), getenv("ADMIN_MEDIA_SECURE") == "true"
	if c.MediaBucket == "" {
		c.MediaBucket = "hiyall-media"
	}
	if c.MediaRegion == "" {
		c.MediaRegion = "us-east-1"
	}
	if c.MediaEndpoint != "" && (c.MediaAccessKey == "" || c.MediaSecretKey == "") {
		return c, errors.New("ADMIN_MEDIA_ACCESS_KEY and ADMIN_MEDIA_SECRET_KEY are required with ADMIN_MEDIA_ENDPOINT")
	}
	if c.Env == "production" && c.MediaEndpoint != "" && !c.MediaSecure {
		return c, errors.New("production media storage requires ADMIN_MEDIA_SECURE=true")
	}
	c.EvidenceEndpoint, c.EvidenceAccessKey, c.EvidenceSecretKey = getenv("ADMIN_EVIDENCE_ENDPOINT"), getenv("ADMIN_EVIDENCE_ACCESS_KEY"), getenv("ADMIN_EVIDENCE_SECRET_KEY")
	c.EvidenceBucket, c.EvidenceRegion, c.EvidenceSecure = getenv("ADMIN_EVIDENCE_BUCKET"), getenv("ADMIN_EVIDENCE_REGION"), getenv("ADMIN_EVIDENCE_SECURE") == "true"
	c.EvidenceDeleteAccessKey, c.EvidenceDeleteSecretKey = getenv("ADMIN_EVIDENCE_DELETE_ACCESS_KEY"), getenv("ADMIN_EVIDENCE_DELETE_SECRET_KEY")
	if c.EvidenceBucket == "" {
		c.EvidenceBucket = "hiyall-evidence"
	}
	if c.EvidenceRegion == "" {
		c.EvidenceRegion = "us-east-1"
	}
	if c.EvidenceEndpoint != "" {
		if c.EvidenceAccessKey == "" || c.EvidenceSecretKey == "" {
			return c, errors.New("ADMIN_EVIDENCE_ACCESS_KEY and ADMIN_EVIDENCE_SECRET_KEY (a read-only token) are required with ADMIN_EVIDENCE_ENDPOINT")
		}
		if c.EvidenceEndpoint == c.MediaEndpoint && c.EvidenceBucket == c.MediaBucket {
			return c, errors.New("ADMIN_EVIDENCE_BUCKET must not be the media bucket")
		}
		if (c.EvidenceDeleteAccessKey == "") != (c.EvidenceDeleteSecretKey == "") {
			return c, errors.New("ADMIN_EVIDENCE_DELETE_ACCESS_KEY and ADMIN_EVIDENCE_DELETE_SECRET_KEY go together")
		}
		if c.EvidenceDeleteAccessKey != "" && c.EvidenceDeleteAccessKey == c.EvidenceAccessKey {
			return c, errors.New("ADMIN_EVIDENCE_DELETE_* must be a different credential from the read-only ADMIN_EVIDENCE_ACCESS_KEY")
		}
		if c.Env == "production" && !c.EvidenceSecure {
			return c, errors.New("production evidence storage requires ADMIN_EVIDENCE_SECURE=true")
		}
	} else if c.EvidenceAccessKey != "" || c.EvidenceDeleteAccessKey != "" || c.EvidenceSecretKey != "" || c.EvidenceDeleteSecretKey != "" {
		return c, errors.New("ADMIN_EVIDENCE_* credentials need ADMIN_EVIDENCE_ENDPOINT")
	}
	if c.Addr == "" {
		c.Addr = "127.0.0.1:8081"
	}
	if c.StaticDir == "" {
		c.StaticDir = "apps/admin/dist"
	}
	var err error
	if c.TrustedProxies, err = clientip.ParseCIDRs(getenv("ADMIN_TRUSTED_PROXY_CIDRS")); err != nil {
		return c, errors.New("ADMIN_TRUSTED_PROXY_CIDRS: " + err.Error())
	}
	if c.ClientIPHeader = strings.TrimSpace(getenv("ADMIN_CLIENT_IP_HEADER")); c.ClientIPHeader != "" && len(c.TrustedProxies) == 0 {
		return c, errors.New("ADMIN_CLIENT_IP_HEADER needs ADMIN_TRUSTED_PROXY_CIDRS: the header is only believed from a trusted proxy")
	}
	for _, name := range []string{"ADMIN_ALLOW_REMOTE", "ADMIN_TRUST_PROXY", "ADMIN_ALLOW_SHARED_DB", "ADMIN_MEDIA_SECURE", "ADMIN_EVIDENCE_SECURE", "EVIDENCE_ALLOW_SHARED_BUCKET"} {
		if v := getenv(name); v != "" && v != "true" && v != "false" {
			return c, errors.New(name + " must be true or false")
		}
	}
	if c.Env != "development" && c.Env != "production" {
		return c, errors.New("APP_ENV must be set to development or production")
	}
	if c.DatabaseURL == "" {
		return c, errors.New("DATABASE_URL is required")
	}
	if c.Env == "production" {
		db, err := url.Parse(c.DatabaseURL)
		if err != nil || db.Query().Get("sslmode") != "verify-full" {
			return c, errors.New("production database requires sslmode=verify-full")
		}
		if c.TrustProxy && len(c.TrustedProxies) == 0 {
			return c, errors.New("ADMIN_TRUST_PROXY=true needs ADMIN_TRUSTED_PROXY_CIDRS in production: without the proxy's address every operator would share one lockout bucket and one audit address")
		}
		if c.MediaEndpoint != "" && c.EvidenceEndpoint == "" && getenv("EVIDENCE_ALLOW_SHARED_BUCKET") != "true" {
			return c, errors.New("production console needs ADMIN_EVIDENCE_ENDPOINT (the evidence bucket, read-only token), or EVIDENCE_ALLOW_SHARED_BUCKET=true to read quarantined photos from the media bucket")
		}
		if c.SharedDatabase && getenv("ADMIN_ALLOW_SHARED_DB") != "true" {
			return c, errors.New("production console needs its own database role: set ADMIN_DATABASE_URL (the hiyall_admin role, database/roles/roles.sql), or ADMIN_ALLOW_SHARED_DB=true to accept the API's role")
		}
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return c, errors.New("ADMIN_TLS_CERT and ADMIN_TLS_KEY go together")
	}
	if err := ValidateBind(c.Addr, c.AllowRemote, c.TLSCert != "", c.TrustProxy); err != nil {
		return c, err
	}
	c.TLSInFront = c.TLSCert != "" || c.TrustProxy
	c.SecureCookies = c.TLSInFront || c.AllowRemote
	if raw := getenv("ADMIN_ALLOWED_HOSTS"); raw != "" {
		for _, h := range strings.Split(raw, ",") {
			if h = strings.ToLower(strings.TrimSpace(h)); h != "" {
				c.AllowedHosts = append(c.AllowedHosts, h)
			}
		}
	}
	if len(c.AllowedHosts) == 0 {
		if !IsLoopbackAddr(c.Addr) {
			return c, errors.New("ADMIN_ALLOWED_HOSTS is required when the listener is not loopback")
		}
		c.AllowedHosts = []string{"localhost", "127.0.0.1", "::1"}
	}
	key, err := loadDataKey(getenv)
	if err != nil {
		return c, err
	}
	c.DataKey = key
	return c, nil
}

// ValidateBind is the listener rule: loopback only, unless ADMIN_ALLOW_REMOTE=true and TLS is in front.
// It cannot see a proxy, so ADMIN_TRUST_PROXY=true (or native TLS) is the operator's statement that one
// exists; with it set the console enforces X-Forwarded-Proto: https on every request.
func ValidateBind(addr string, allowRemote, nativeTLS, trustProxy bool) error {
	if IsLoopbackAddr(addr) {
		return nil
	}
	if !allowRemote {
		return errors.New("ADMIN_ADDR " + addr + " is not a loopback address; the console refuses to listen there unless ADMIN_ALLOW_REMOTE=true with TLS in front")
	}
	if !nativeTLS && !trustProxy {
		return errors.New("ADMIN_ALLOW_REMOTE=true requires TLS: set ADMIN_TLS_CERT and ADMIN_TLS_KEY, or ADMIN_TRUST_PROXY=true behind a TLS terminating proxy")
	}
	return nil
}

// IsLoopbackAddr is true only for host:port with a loopback IP literal or "localhost". An empty host
// (":8081", every interface) and any other name are not loopback.
func IsLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func loadDataKey(getenv func(string) string) ([]byte, error) {
	raw := getenv("ADMIN_DATA_KEY")
	if file := getenv("ADMIN_DATA_KEY_FILE"); raw == "" && file != "" {
		b, err := os.ReadFile(file)
		if err != nil {
			return nil, errors.New("ADMIN_DATA_KEY_FILE cannot be read")
		}
		raw = string(b)
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("ADMIN_DATA_KEY (or ADMIN_DATA_KEY_FILE) is required: 32 random bytes, base64 (openssl rand -base64 32)")
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(raw); err == nil && len(b) == 32 {
			return b, nil
		}
	}
	return nil, errors.New("ADMIN_DATA_KEY must be 32 random bytes, base64 encoded")
}
