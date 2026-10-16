package config

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testCursorKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" // 32 bytes

// productionBasics sets what production now requires besides the identity provider.
func productionBasics(t *testing.T) {
	t.Helper()
	t.Setenv("CURSOR_KEY", testCursorKey)
	t.Setenv("RATE_LIMIT_BACKEND", "postgres")
	t.Setenv("TRUSTED_PROXY_CIDRS", "")
	t.Setenv("BEHIND_PROXY", "")
	// Production must say how clients arrive (audit API-1) and have a Nearby offset key (audit API-4).
	t.Setenv("DIRECT_LISTENER", "true")
	t.Setenv("DEBUG_LOG_PEER", "")
	t.Setenv("NEARBY_OFFSET_KEY", testCursorKey)
	for _, k := range []string{"NEARBY_OFFSET_KEY_PREVIOUS", "EVIDENCE_BUCKET", "EVIDENCE_ENDPOINT", "EVIDENCE_ACCESS_KEY", "EVIDENCE_SECRET_KEY", "EVIDENCE_SECURE", "EVIDENCE_REGION", "EVIDENCE_ALLOW_SHARED_BUCKET", "EVIDENCE_RETENTION_DAYS", "EVIDENCE_CANARY", "EVIDENCE_ALLOW_API_DELETE", "NEARBY_ACCOUNTS_PER_ADDRESS", "MEDIA_PROCESS_SLOTS", "EXPORT_CONCURRENCY"} {
		t.Setenv(k, "")
	}
	// A developer's shell may carry console or migration settings; production refuses them in the API's environment.
	for _, k := range OwnerVariables(os.Environ()) {
		t.Setenv(k, "")
	}
}

func serviceAccountFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(path, []byte(`{"type":"service_account"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProductionStartChecks(t *testing.T) {
	cases := map[string]struct {
		set  map[string]string
		want string // "" = must load
	}{
		"baseline":                   {nil, ""},
		"behind proxy without cidrs": {map[string]string{"DIRECT_LISTENER": "", "BEHIND_PROXY": "true"}, "TRUSTED_PROXY_CIDRS"},
		"behind proxy with cidrs":    {map[string]string{"DIRECT_LISTENER": "", "BEHIND_PROXY": "true", "TRUSTED_PROXY_CIDRS": "10.0.0.0/8", "CLIENT_IP_HEADER": "Fly-Client-IP"}, ""},
		"neither proxy nor direct":   {map[string]string{"DIRECT_LISTENER": ""}, "DIRECT_LISTENER"},
		"direct and proxy":           {map[string]string{"BEHIND_PROXY": "true", "TRUSTED_PROXY_CIDRS": "10.0.0.0/8"}, "DIRECT_LISTENER"},
		"direct with cidrs only":     {map[string]string{"TRUSTED_PROXY_CIDRS": "10.0.0.0/8"}, "DIRECT_LISTENER"},
		"direct listener":            {map[string]string{"DIRECT_LISTENER": "true"}, ""},
		"bad direct value":           {map[string]string{"DIRECT_LISTENER": "yes"}, "DIRECT_LISTENER"},
		"header without cidrs":       {map[string]string{"CLIENT_IP_HEADER": "Fly-Client-IP"}, "CLIENT_IP_HEADER"},
		"bad cidr":                   {map[string]string{"TRUSTED_PROXY_CIDRS": "10.0.0.0/40"}, "TRUSTED_PROXY_CIDRS"},
		"no cursor key":              {map[string]string{"CURSOR_KEY": ""}, "CURSOR_KEY"},
		"short cursor key":           {map[string]string{"CURSOR_KEY": base64.StdEncoding.EncodeToString([]byte("short"))}, "CURSOR_KEY"},
		"previous without current":   {map[string]string{"CURSOR_KEY": "", "CURSOR_KEY_PREVIOUS": testCursorKey}, "CURSOR_KEY"},
		"previous key":               {map[string]string{"CURSOR_KEY_PREVIOUS": testCursorKey}, ""},
		"isolation off":              {map[string]string{"AGE_BAND_ISOLATION": "false"}, "AGE_BAND_ISOLATION"},
		"memory limiter":             {map[string]string{"RATE_LIMIT_BACKEND": "memory"}, "RATE_LIMIT_BACKEND"},
		"default limiter":            {map[string]string{"RATE_LIMIT_BACKEND": ""}, "RATE_LIMIT_BACKEND"},
		"no firebase account":        {map[string]string{"FIREBASE_SERVICE_ACCOUNT_FILE": ""}, "FIREBASE_SERVICE_ACCOUNT_FILE"},
		"unreadable firebase file":   {map[string]string{"FIREBASE_SERVICE_ACCOUNT_FILE": "/nonexistent/sa.json"}, "FIREBASE_SERVICE_ACCOUNT_FILE"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			firebaseEnv(t, "hiyall-prod-1")
			for k, v := range tc.set {
				t.Setenv(k, v)
			}
			_, err := Load()
			switch {
			case tc.want == "" && err != nil:
				t.Fatalf("rejected: %v", err)
			case tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)):
				t.Fatalf("want error naming %s, got %v", tc.want, err)
			}
		})
	}
}

func TestDevelopmentNeedsNoProductionSettings(t *testing.T) {
	opsEnv(t, map[string]string{"CURSOR_KEY": "", "TRUSTED_PROXY_CIDRS": "", "AGE_BAND_ISOLATION": "false"})
	c, err := Load()
	if err != nil || c.CursorKey != nil || c.LogFormat != "text" || c.DBMaxConns != 20 || c.DBStatementTimeout != 5*time.Second || c.DBLockTimeout != 3*time.Second || c.DBIdleTimeout != 15*time.Second {
		t.Fatalf("%+v %v", c.Platform, err)
	}
}

func TestPlatformValues(t *testing.T) {
	opsEnv(t, map[string]string{"CURSOR_KEY": testCursorKey, "DB_MAX_CONNS": "40", "DB_STATEMENT_TIMEOUT": "9s", "LOG_FORMAT": "json",
		"MIN_CLIENT_VERSION_ANDROID": "1.4.0", "MIN_CLIENT_VERSION_WEB": " v2 ", "TRUSTED_PROXY_CIDRS": "10.0.0.0/8,fdaa::/16"})
	c, err := Load()
	if err != nil || len(c.CursorKey) != 32 || c.DBMaxConns != 40 || c.DBStatementTimeout != 9*time.Second || c.LogFormat != "json" ||
		c.MinClientVersion["android"] != "1.4.0" || c.MinClientVersion["web"] != "v2" || c.MinClientVersion["ios"] != "" || len(c.TrustedProxies) != 2 {
		t.Fatalf("%+v %v", c.Platform, err)
	}
	if !c.ClientIPResolver().Enabled() {
		t.Fatal("resolver off")
	}
	for k, v := range map[string]string{"DB_MAX_CONNS": "1", "DB_LOCK_TIMEOUT": "soon", "DB_IDLE_IN_TRANSACTION_TIMEOUT": "-1s", "LOG_FORMAT": "xml", "MIN_CLIENT_VERSION_IOS": "latest", "BEHIND_PROXY": "yes", "CURSOR_KEY": "###"} {
		t.Run(k, func(t *testing.T) {
			opsEnv(t, map[string]string{"CURSOR_KEY": testCursorKey, k: v})
			if _, err := Load(); err == nil {
				t.Fatalf("%s=%q accepted", k, v)
			}
		})
	}
	// Production defaults to JSON logs.
	firebaseEnv(t, "hiyall-prod-1")
	if c, err = Load(); err != nil || c.LogFormat != "json" {
		t.Fatalf("%q %v", c.LogFormat, err)
	}
}
