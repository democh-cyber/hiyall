package admin

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/clientip"
)

func TestTOTPMatchesRFC6238Vectors(t *testing.T) {
	secret := []byte("12345678901234567890")
	for _, v := range []struct {
		unix int64
		want string
	}{{59, "287082"}, {1111111109, "081804"}, {1111111111, "050471"}, {1234567890, "005924"}, {2000000000, "279037"}, {20000000000, "353130"}} {
		if got := TOTPCode(secret, v.unix/30); got != v.want {
			t.Fatalf("t=%d got %s want %s", v.unix, got, v.want)
		}
	}
}

func TestTOTPWindowAndMalformedCodes(t *testing.T) {
	secret := NewTOTPSecret()
	now := time.Unix(1_800_000_000, 0)
	step := TOTPStep(now)
	for delta, want := range map[int64]bool{-2: false, -1: true, 0: true, 1: true, 2: false} {
		got, ok := VerifyTOTP(secret, TOTPCode(secret, step+delta), now)
		if ok != want || (ok && got != step+delta) {
			t.Fatalf("delta %d ok=%v step=%d", delta, ok, got)
		}
	}
	good := TOTPCode(secret, step)
	for _, bad := range []string{"", "12345", "1234567", "abcdef", good + "0", " " + strings.Repeat("x", 6)} {
		if _, ok := VerifyTOTP(secret, bad, now); ok {
			t.Fatalf("accepted %q", bad)
		}
	}
	if _, ok := VerifyTOTP(secret, good[:3]+" "+good[3:], now); !ok {
		t.Fatal("a code typed with a space is the same code")
	}
	if uri := OTPAuthURI("Hiyall Admin", "a@b.test", secret); !strings.HasPrefix(uri, "otpauth://totp/Hiyall%20Admin:a@b.test?") || !strings.Contains(uri, "algorithm=SHA1") || !strings.Contains(uri, "period=30") {
		t.Fatal(uri)
	}
}

func TestPasswordHashing(t *testing.T) {
	if DefaultPasswordParams.Memory < 8 {
		t.Fatal("test params")
	}
	h, err := HashPassword("correct horse", PasswordParams{1, 64, 1})
	if err != nil || !strings.HasPrefix(h, "$argon2id$v=19$m=64,t=1,p=1$") {
		t.Fatal(h, err)
	}
	if ok, err := VerifyPassword("correct horse", h); !ok || err != nil {
		t.Fatal("should verify")
	}
	if ok, _ := VerifyPassword("wrong horse", h); ok {
		t.Fatal("wrong password verified")
	}
	h2, _ := HashPassword("correct horse", PasswordParams{1, 64, 1})
	if h == h2 {
		t.Fatal("salt must differ")
	}
	for _, bad := range []string{"", "plain", "$argon2id$v=19$m=64,t=1,p=1$AAAA", "$argon2id$v=19$m=99999999,t=1,p=1$AAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAA", "$bcrypt$x$y$z$q"} {
		if ok, err := VerifyPassword("x", bad); ok || err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	// The production cost is above the OWASP minimum (19 MiB, 2 passes).
	prod := PasswordParams{Time: 3, Memory: 64 * 1024, Threads: 2}
	if prod.Memory < 19*1024 || prod.Time < 2 {
		t.Fatal("weak parameters")
	}
}

func TestSealedValuesAreBoundToTheirOperator(t *testing.T) {
	k, err := newKeys(testConfig().DataKey)
	if err != nil {
		t.Fatal(err)
	}
	sealed := k.seal([]byte("seed-seed-seed"), "op-1")
	if strings.Contains(string(sealed), "seed-seed") {
		t.Fatal("plaintext in sealed value")
	}
	if got, err := k.open(sealed, "op-1"); err != nil || string(got) != "seed-seed-seed" {
		t.Fatal(err)
	}
	if _, err := k.open(sealed, "op-2"); err == nil {
		t.Fatal("opened for another operator")
	}
	other, _ := newKeys(make([]byte, 32))
	if _, err := other.open(sealed, "op-1"); err == nil {
		t.Fatal("opened with another key")
	}
	if _, err := newKeys([]byte("short")); err == nil {
		t.Fatal("short key accepted")
	}
	if string(k.mac("ip", "a")) == string(k.mac("account", "a")) {
		t.Fatal("labels must separate keys")
	}
}

func TestRemoteBindIsRefusedWithoutTLS(t *testing.T) {
	for addr, want := range map[string]bool{
		"127.0.0.1:8081": true, "localhost:8081": true, "[::1]:8081": true,
		"0.0.0.0:8081": false, ":8081": false, "10.0.0.5:8081": false, "admin.internal:8081": false, "[::]:8081": false, "garbage": false,
	} {
		if got := IsLoopbackAddr(addr); got != want {
			t.Fatalf("%s loopback=%v", addr, got)
		}
	}
	if err := ValidateBind("0.0.0.0:8081", false, true, true); err == nil {
		t.Fatal("remote bind allowed without ADMIN_ALLOW_REMOTE")
	}
	if err := ValidateBind("0.0.0.0:8081", true, false, false); err == nil {
		t.Fatal("remote bind allowed without TLS in front")
	}
	if err := ValidateBind("0.0.0.0:8081", true, false, true); err != nil {
		t.Fatal(err)
	}
	if err := ValidateBind("0.0.0.0:8081", true, true, false); err != nil {
		t.Fatal(err)
	}
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	base := map[string]string{"APP_ENV": "development", "DATABASE_URL": "postgres://x", "ADMIN_DATA_KEY": key}
	with := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	c, err := LoadConfig(env(base))
	if err != nil || c.Addr != "127.0.0.1:8081" || c.StaticDir != "apps/admin/dist" || c.SecureCookies {
		t.Fatalf("defaults %+v %v", c, err)
	}
	for name, m := range map[string]map[string]string{
		"remote":               with(map[string]string{"ADMIN_ADDR": "0.0.0.0:8081"}),
		"remote no tls":        with(map[string]string{"ADMIN_ADDR": "0.0.0.0:8081", "ADMIN_ALLOW_REMOTE": "true", "ADMIN_ALLOWED_HOSTS": "a.test"}),
		"remote no hosts":      with(map[string]string{"ADMIN_ADDR": "0.0.0.0:8081", "ADMIN_ALLOW_REMOTE": "true", "ADMIN_TRUST_PROXY": "true"}),
		"no key":               with(map[string]string{"ADMIN_DATA_KEY": ""}),
		"short key":            with(map[string]string{"ADMIN_DATA_KEY": "c2hvcnQ="}),
		"half tls":             with(map[string]string{"ADMIN_TLS_CERT": "/x"}),
		"production dbssl":     with(map[string]string{"APP_ENV": "production", "DATABASE_URL": "postgres://x?sslmode=require"}),
		"production shared db": with(map[string]string{"APP_ENV": "production", "DATABASE_URL": "postgres://x?sslmode=verify-full"}),
		"media half":           with(map[string]string{"ADMIN_MEDIA_ENDPOINT": "s3.example.test"}),
		"bad flag":             with(map[string]string{"ADMIN_ALLOW_REMOTE": "yes"}),
		"no env":               with(map[string]string{"APP_ENV": ""}),
	} {
		if _, err := LoadConfig(env(m)); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	if c, err = LoadConfig(env(with(map[string]string{"APP_ENV": "production", "ADMIN_DATABASE_URL": "postgres://admin@x?sslmode=verify-full"}))); err != nil || c.SharedDatabase || c.DatabaseURL != "postgres://admin@x?sslmode=verify-full" {
		t.Fatalf("own role %+v %v", c, err)
	}
	if _, err = LoadConfig(env(with(map[string]string{"APP_ENV": "production", "DATABASE_URL": "postgres://x?sslmode=verify-full", "ADMIN_ALLOW_SHARED_DB": "true"}))); err != nil {
		t.Fatalf("explicit shared role refused: %v", err)
	}
	c, err = LoadConfig(env(with(map[string]string{"ADMIN_ADDR": "0.0.0.0:8081", "ADMIN_ALLOW_REMOTE": "true", "ADMIN_TRUST_PROXY": "true", "ADMIN_ALLOWED_HOSTS": "Admin.Internal, other.test"})))
	if err != nil || !c.SecureCookies || len(c.AllowedHosts) != 2 || c.AllowedHosts[0] != "admin.internal" {
		t.Fatalf("remote behind proxy %+v %v", c, err)
	}
}

func TestReasonIsMandatory(t *testing.T) {
	for _, bad := range []string{"", "   ", "too short", "123456789", strings.Repeat("x", 1001), "bad\x00reason here"} {
		if _, err := Reason(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	if r, err := Reason("  credible threat to a minor \n"); err != nil || r != "credible threat to a minor" {
		t.Fatal(r, err)
	}
}

func TestIPsAreTruncatedForTheAuditLog(t *testing.T) {
	for in, want := range map[string]string{"203.0.113.77": "203.0.113.0/24", "2001:db8:1:2:3:4:5:6": "2001:db8:1::/48", "nonsense": "", "": ""} {
		if got := TruncateIP(in); got != want {
			t.Fatalf("%q -> %q want %q", in, got, want)
		}
	}
}

func TestRolesAreOrdered(t *testing.T) {
	if !RoleAdmin.Allows(RoleModerator) || !RoleModerator.Allows(RoleViewer) || RoleViewer.Allows(RoleModerator) || Role("").Allows(RoleViewer) || Role("root").Allows(RoleViewer) {
		t.Fatal("role order")
	}
}

func newBareServer(cfg Config) http.Handler { return NewServer(nil, cfg).Handler() }

func TestSecurityHeadersHostCheckAndNoCORS(t *testing.T) {
	h := newBareServer(testConfig())
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "http://localhost/admin/v1/me", nil)
	req.Header.Set("Origin", "https://evil.example")
	h.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatal(rec.Code)
	}
	hd := rec.Header()
	for k, frag := range map[string]string{"Content-Security-Policy": "default-src 'self'", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY", "Cache-Control": "no-store"} {
		if !strings.Contains(hd.Get(k), frag) {
			t.Fatalf("%s = %q", k, hd.Get(k))
		}
	}
	csp := hd.Get("Content-Security-Policy")
	if !strings.Contains(csp, "frame-ancestors 'none'") || strings.Contains(csp, "unsafe-inline") || strings.Contains(csp, "unsafe-eval") {
		t.Fatal(csp)
	}
	for k := range hd {
		if strings.HasPrefix(strings.ToLower(k), "access-control-") {
			t.Fatalf("CORS header %s", k)
		}
	}
	// A preflight gets no permission.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("OPTIONS", "http://localhost/admin/v1/login", nil)
	req.Header.Set("Origin", "https://evil.example")
	req.Header.Set("Access-Control-Request-Method", "POST")
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Access-Control-Allow-Origin") != "" || rec.Code < 400 {
		t.Fatalf("preflight %d", rec.Code)
	}
	// DNS rebinding: an unknown Host is refused before anything runs.
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "http://evil.example/admin/v1/me", nil))
	if rec.Code != http.StatusMisdirectedRequest {
		t.Fatal(rec.Code)
	}
	// JSON 404 for unknown API paths.
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "http://localhost/admin/v1/nothing", nil))
	if rec.Code != 404 || !strings.Contains(rec.Body.String(), `"success":false`) {
		t.Fatal(rec.Code, rec.Body.String())
	}
}

func TestTrustedProxyMustTerminateTLS(t *testing.T) {
	cfg := testConfig()
	cfg.TrustProxy, cfg.SecureCookies, cfg.TLSInFront = true, true, true
	h := newBareServer(cfg)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "http://localhost/admin/v1/me", nil))
	if rec.Code != 400 {
		t.Fatalf("plain HTTP accepted behind a TLS proxy: %d", rec.Code)
	}
	req := httptest.NewRequest("GET", "http://localhost/admin/v1/me", nil)
	req.Header.Set("X-Forwarded-Proto", "https")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 401 || rec.Header().Get("Strict-Transport-Security") == "" {
		t.Fatal(rec.Code, rec.Header())
	}
	// The proxy's address is configured: only its X-Forwarded-For is believed (audit, admin clientIP).
	cfg.TrustedProxies, _ = clientip.ParseCIDRs("10.0.0.0/8")
	s := NewServer(nil, cfg)
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.1:1"
	r.Header.Set("X-Forwarded-For", "6.6.6.6, 198.51.100.4")
	if s.clientIP(r) != "198.51.100.4" {
		t.Fatal("must use the address the proxy appended")
	}
	// A client that reaches the console directly cannot choose its address by sending the header.
	direct := httptest.NewRequest("GET", "/", nil)
	direct.RemoteAddr = "203.0.113.50:9999"
	direct.Header.Set("X-Forwarded-For", "198.51.100.4")
	if got := s.clientIP(direct); got != "203.0.113.50" {
		t.Fatalf("a forwarded header from an untrusted peer was believed: %q", got)
	}
	// The proxy's single-address header, when configured, is preferred.
	cfg.ClientIPHeader = "Fly-Client-IP"
	s = NewServer(nil, cfg)
	r.Header.Set("Fly-Client-IP", "192.0.2.77")
	if s.clientIP(r) != "192.0.2.77" {
		t.Fatal("the proxy's client address header was ignored")
	}
	// TrustProxy without the proxy's address believes nobody.
	cfg.TrustedProxies, cfg.ClientIPHeader = nil, ""
	s = NewServer(nil, cfg)
	if s.clientIP(r) != "10.0.0.1" {
		t.Fatal("without ADMIN_TRUSTED_PROXY_CIDRS the peer is the client")
	}
	cfg.TrustProxy = false
	cfg.TrustedProxies, _ = clientip.ParseCIDRs("10.0.0.0/8")
	s = NewServer(nil, cfg)
	if s.clientIP(r) != "10.0.0.1" {
		t.Fatal("forwarded headers are not trusted without a proxy")
	}
}

func TestStaticConsole(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "assets"), 0o755)
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("<!doctype html><title>x</title>"), 0o644)
	os.WriteFile(filepath.Join(dir, "assets", "app.js"), []byte("console.log(1)"), 0o644)
	os.WriteFile(filepath.Join(filepath.Dir(dir), "outside.txt"), []byte("secret"), 0o644)
	cfg := testConfig()
	cfg.StaticDir = dir
	h := newBareServer(cfg)
	get := func(p string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "http://localhost"+p, nil))
		return rec
	}
	if rec := get("/"); rec.Code != 200 || !strings.Contains(rec.Body.String(), "<title>") || rec.Header().Get("Content-Security-Policy") == "" {
		t.Fatal(rec.Code)
	}
	if rec := get("/reports/123"); rec.Code != 200 || !strings.Contains(rec.Body.String(), "<title>") {
		t.Fatal("client side routes fall back to the app")
	}
	if rec := get("/assets/app.js"); rec.Code != 200 || !strings.Contains(rec.Header().Get("Content-Type"), "javascript") {
		t.Fatal(rec.Code, rec.Header())
	}
	if rec := get("/assets/missing.js"); rec.Code != 404 {
		t.Fatal(rec.Code)
	}
	if rec := get("/assets"); rec.Code != 200 { // a directory is not listed; it is a client route
		t.Fatal(rec.Code)
	}
	if rec := get("/../outside.txt"); strings.Contains(rec.Body.String(), "secret") {
		t.Fatal("path traversal")
	}
	cfg.StaticDir = filepath.Join(dir, "missing")
	rec := httptest.NewRecorder()
	newBareServer(cfg).ServeHTTP(rec, httptest.NewRequest("GET", "http://localhost/", nil))
	if rec.Code != 503 {
		t.Fatal(rec.Code)
	}
}
