package config

import (
	"strings"
	"testing"
)

// trustEnv is a development configuration with photo uploads on, which the trust checks then tighten.
func trustEnv(t *testing.T, env map[string]string) error {
	t.Helper()
	base := map[string]string{
		"DATABASE_URL": "postgresql://db.example/app?sslmode=verify-full", "APP_ENV": "development", "ENABLE_DEV_AUTH": "false",
		"OIDC_ISSUER": "https://identity.example", "OIDC_AUDIENCE": "hiyall-api", "LISTEN_ADDR": "127.0.0.1:8080",
		"MEDIA_ENDPOINT": "s3.example", "MEDIA_ACCESS_KEY": "a", "MEDIA_SECRET_KEY": "b", "MEDIA_SECURE": "true",
		"SCAN_HASHLIST_FILE": "", "SCAN_PROVIDER_URL": "", "SCAN_PROVIDER_KEY_FILE": "", "SCAN_ALLOW_NONE": "",
		"APPLE_SIGN_IN_ENABLED": "", "APPLE_TEAM_ID": "", "APPLE_KEY_ID": "", "APPLE_CLIENT_ID": "", "APPLE_PRIVATE_KEY_FILE": "",
		"CURSOR_KEY": testCursorKey, "RATE_LIMIT_BACKEND": "postgres", "TRUSTED_PROXY_CIDRS": "", "BEHIND_PROXY": "", "FIREBASE_SERVICE_ACCOUNT_FILE": "",
	}
	for k, v := range env {
		base[k] = v
	}
	for k, v := range base {
		t.Setenv(k, v)
	}
	_, err := Load()
	return err
}

func TestProductionRefusesUnscannedUploadsUnlessExplicitlyAllowed(t *testing.T) {
	// Only the scanner rule is under test, so ask the trust loader directly in production mode.
	for name, c := range map[string]struct {
		cfg  Config
		want string
	}{
		"no scanner":        {Config{Env: "production", Platform: Platform{}}, "upload scanner"},
		"hash list":         {Config{Env: "production", Trust: Trust{ScanHashlistFile: "/x"}}, ""},
		"provider":          {Config{Env: "production", Trust: Trust{ScanProviderURL: "https://x", ScanProviderKeyFile: "/k"}}, ""},
		"explicit none":     {Config{Env: "production", Trust: Trust{ScanAllowNone: true}}, ""},
		"development":       {Config{Env: "development"}, ""},
		"no media, no scan": {Config{Env: "production"}, ""},
	} {
		c.cfg.MediaEndpoint = "s3.example"
		if name == "no media, no scan" {
			c.cfg.MediaEndpoint = ""
		}
		t.Setenv("SCAN_ALLOW_NONE", map[bool]string{true: "true", false: ""}[c.cfg.ScanAllowNone])
		t.Setenv("SCAN_HASHLIST_FILE", c.cfg.ScanHashlistFile)
		t.Setenv("SCAN_PROVIDER_URL", c.cfg.ScanProviderURL)
		t.Setenv("SCAN_PROVIDER_KEY_FILE", c.cfg.ScanProviderKeyFile)
		for _, k := range []string{"APPLE_SIGN_IN_ENABLED", "APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_CLIENT_ID", "APPLE_PRIVATE_KEY_FILE"} {
			t.Setenv(k, "")
		}
		err := c.cfg.loadTrust()
		if (c.want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), c.want)) {
			t.Fatalf("%s: %v, want %q", name, err, c.want)
		}
	}
}

func TestScanAndAppleSettingsMustBeConsistent(t *testing.T) {
	for name, env := range map[string]map[string]string{
		"provider without key": {"SCAN_PROVIDER_URL": "https://scan.example"},
		"key without provider": {"SCAN_PROVIDER_KEY_FILE": "/k"},
		"bad allow flag":       {"SCAN_ALLOW_NONE": "yes"},
		"bad apple flag":       {"APPLE_SIGN_IN_ENABLED": "1"},
		"half apple":           {"APPLE_TEAM_ID": "T", "APPLE_KEY_ID": "K"},
	} {
		if err := trustEnv(t, env); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	// Apple unset is fine in development, and in production when the app does not offer Apple sign-in.
	if err := trustEnv(t, map[string]string{}); err != nil {
		t.Fatal(err)
	}
	c := Config{Env: "production", Trust: Trust{AppleTeamID: "T", AppleKeyID: "K", AppleClientID: "C", ApplePrivateKeyFile: "/p", AppleSignInEnabled: true, ScanAllowNone: true}}
	t.Setenv("APPLE_SIGN_IN_ENABLED", "true")
	t.Setenv("APPLE_TEAM_ID", "T")
	t.Setenv("APPLE_KEY_ID", "K")
	t.Setenv("APPLE_CLIENT_ID", "C")
	t.Setenv("APPLE_PRIVATE_KEY_FILE", "/p")
	t.Setenv("SCAN_ALLOW_NONE", "true")
	t.Setenv("SCAN_HASHLIST_FILE", "")
	t.Setenv("SCAN_PROVIDER_URL", "")
	t.Setenv("SCAN_PROVIDER_KEY_FILE", "")
	if err := c.loadTrust(); err != nil || !c.AppleConfigured() {
		t.Fatal(err)
	}
	// Production with Apple sign-in on needs all four values: deleted accounts must revoke their tokens.
	t.Setenv("APPLE_PRIVATE_KEY_FILE", "")
	t.Setenv("APPLE_TEAM_ID", "")
	t.Setenv("APPLE_KEY_ID", "")
	t.Setenv("APPLE_CLIENT_ID", "")
	t.Setenv("APPLE_SIGN_IN_ENABLED", "")
	if err := (&Config{Env: "production"}).loadTrust(); err != nil {
		t.Fatalf("production without Apple sign-in: %v", err)
	}
	t.Setenv("APPLE_SIGN_IN_ENABLED", "true")
	if err := (&Config{Env: "production"}).loadTrust(); err == nil || !strings.Contains(err.Error(), "APPLE_SIGN_IN_ENABLED") {
		t.Fatalf("production Apple sign-in without keys: %v", err)
	}
}
