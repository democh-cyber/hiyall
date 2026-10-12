package config

import (
	"strings"
	"testing"
)

func TestProductionFailsClosed(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app?sslmode=disable")
	t.Setenv("APP_ENV", "production")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	if _, err := Load(); err == nil {
		t.Fatal("production accepted development credentials")
	}
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("OIDC_ISSUER", "https://identity.example")
	t.Setenv("OIDC_AUDIENCE", "hiyall-api")
	if _, err := Load(); err == nil {
		t.Fatal("production accepted an unverified database connection")
	}
	t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=verify-full")
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
}
func TestDevAuthCannotBindPublicly(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "0.0.0.0:8080")
	if _, err := Load(); err == nil {
		t.Fatal("public dev auth")
	}
}

func TestEnvironmentMustBeExplicit(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "")
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("OIDC_ISSUER", "http://identity.example")
	t.Setenv("OIDC_AUDIENCE", "hiyall-api")
	if _, err := Load(); err == nil {
		t.Fatal("unset APP_ENV skipped production safety checks")
	}
}

func firebaseEnv(t *testing.T, project string) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=verify-full")
	t.Setenv("APP_ENV", "production")
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	t.Setenv("OIDC_ISSUER", "")
	t.Setenv("OIDC_AUDIENCE", "")
	t.Setenv("FIREBASE_PROJECT_ID", project)
}

func TestFirebaseProjectDerivesIssuerAndAudience(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.Issuer != "https://securetoken.google.com/hiyall-prod-1" || c.Audience != "hiyall-prod-1" || c.FirebaseProjectID != "hiyall-prod-1" {
		t.Fatalf("derived %q %q", c.Issuer, c.Audience)
	}
	// Restating the derived values is harmless; generic OIDC settings stay supported without Firebase.
	t.Setenv("OIDC_ISSUER", "https://securetoken.google.com/hiyall-prod-1")
	t.Setenv("OIDC_AUDIENCE", "hiyall-prod-1")
	if _, err = Load(); err != nil {
		t.Fatal(err)
	}
	firebaseEnv(t, "")
	t.Setenv("OIDC_ISSUER", "https://identity.example")
	t.Setenv("OIDC_AUDIENCE", "hiyall-api")
	if c, err = Load(); err != nil || c.Issuer != "https://identity.example" || c.FirebaseProjectID != "" {
		t.Fatalf("generic OIDC: %+v %v", c, err)
	}
}

func TestFirebaseProjectIDFormat(t *testing.T) {
	for _, bad := range []string{"abc", "Hiyall-Prod", "hiyall_prod", "hiyall prod", "hiyall.prod", "https://securetoken.google.com/x", strings.Repeat("a", 65), "hiyall\nprod"} {
		firebaseEnv(t, bad)
		if _, err := Load(); err == nil {
			t.Fatalf("accepted project id %q", bad)
		}
	}
	for _, good := range []string{"abcd", "hiyall-1", "0123", strings.Repeat("a", 64)} {
		firebaseEnv(t, good)
		if _, err := Load(); err != nil {
			t.Fatalf("rejected project id %q: %v", good, err)
		}
	}
}

func TestFirebaseCannotBeMixedWithAnotherIssuer(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("OIDC_ISSUER", "https://identity.example")
	if _, err := Load(); err == nil {
		t.Fatal("accepted a different issuer next to Firebase")
	}
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("OIDC_AUDIENCE", "another-audience")
	if _, err := Load(); err == nil {
		t.Fatal("accepted a different audience next to Firebase")
	}
}

func TestFirebaseStillNeedsProductionSafeguards(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=disable")
	if _, err := Load(); err == nil {
		t.Fatal("production Firebase accepted an unverified database connection")
	}
	firebaseEnv(t, "")
	if _, err := Load(); err == nil {
		t.Fatal("production started with no identity provider configured")
	}
}

func TestAgeBandIsolationDefaultsOnAndParsesStrictly(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	for value, want := range map[string]bool{"": true, "true": true, "false": false} {
		t.Setenv("AGE_BAND_ISOLATION", value)
		c, err := Load()
		if err != nil || c.AgeBandIsolation != want {
			t.Fatalf("AGE_BAND_ISOLATION=%q: %v (%v), want %v", value, c.AgeBandIsolation, err, want)
		}
	}
	for _, bad := range []string{"TRUE", "False", "1", "0", "yes", "no", "on", "off", " true", "true ", "disabled"} {
		t.Setenv("AGE_BAND_ISOLATION", bad)
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "AGE_BAND_ISOLATION") {
			t.Fatalf("AGE_BAND_ISOLATION=%q was accepted (%v)", bad, err)
		}
	}
	// Production keeps the safe default when the variable is not set.
	t.Setenv("AGE_BAND_ISOLATION", "")
	t.Setenv("APP_ENV", "production")
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("OIDC_ISSUER", "https://identity.example")
	t.Setenv("OIDC_AUDIENCE", "hiyall-api")
	t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=verify-full")
	if c, err := Load(); err != nil || !c.AgeBandIsolation {
		t.Fatalf("production default: %v (%v)", c.AgeBandIsolation, err)
	}
}

func chatMediaEnv(t *testing.T) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	for _, name := range []string{"MEDIA_ENDPOINT", "MEDIA_ACCESS_KEY", "MEDIA_SECRET_KEY", "MEDIA_BUCKET", "CHAT_MEDIA_ENDPOINT", "CHAT_MEDIA_ACCESS_KEY", "CHAT_MEDIA_SECRET_KEY", "CHAT_MEDIA_BUCKET", "CHAT_MEDIA_REGION", "CHAT_MEDIA_SECURE"} {
		t.Setenv(name, "")
	}
}

func TestChatMediaIsOptionalAndSeparateFromSocialMedia(t *testing.T) {
	chatMediaEnv(t)
	c, err := Load()
	if err != nil || c.ChatMediaEndpoint != "" || c.ChatMediaBucket != "hiyall-chat" || c.ChatMediaRegion != "us-east-1" || c.ChatMediaSecure {
		t.Fatalf("unconfigured: %+v %v", c, err)
	}
	// Keys are required with an endpoint, as for MEDIA_*.
	t.Setenv("CHAT_MEDIA_ENDPOINT", "acct.r2.cloudflarestorage.com")
	if _, err = Load(); err == nil || !strings.Contains(err.Error(), "CHAT_MEDIA_ACCESS_KEY") {
		t.Fatalf("endpoint without keys: %v", err)
	}
	t.Setenv("CHAT_MEDIA_ACCESS_KEY", "id")
	if _, err = Load(); err == nil {
		t.Fatal("endpoint with one key")
	}
	t.Setenv("CHAT_MEDIA_SECRET_KEY", "secret")
	t.Setenv("CHAT_MEDIA_REGION", "auto")
	t.Setenv("CHAT_MEDIA_SECURE", "true")
	c, err = Load()
	if err != nil || c.ChatMediaEndpoint != "acct.r2.cloudflarestorage.com" || c.ChatMediaBucket != "hiyall-chat" || c.ChatMediaRegion != "auto" || !c.ChatMediaSecure || c.ChatMediaSecretKey != "secret" {
		t.Fatalf("configured: %+v %v", c, err)
	}
	// The social store's settings are not used for chat and vice versa.
	if c.MediaEndpoint != "" || c.MediaAccessKey != "" {
		t.Fatalf("social media picked up chat settings: %+v", c)
	}
	// The chat bucket can never be the social bucket.
	t.Setenv("MEDIA_ENDPOINT", "acct.r2.cloudflarestorage.com")
	t.Setenv("MEDIA_ACCESS_KEY", "a")
	t.Setenv("MEDIA_SECRET_KEY", "b")
	t.Setenv("MEDIA_BUCKET", "hiyall-chat")
	if _, err = Load(); err == nil {
		t.Fatal("chat and social media share a bucket")
	}
	t.Setenv("MEDIA_BUCKET", "hiyall")
	if _, err = Load(); err != nil {
		t.Fatal(err)
	}
}

func TestProductionChatMediaRequiresTLS(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("CHAT_MEDIA_ENDPOINT", "acct.r2.cloudflarestorage.com")
	t.Setenv("CHAT_MEDIA_ACCESS_KEY", "id")
	t.Setenv("CHAT_MEDIA_SECRET_KEY", "secret")
	t.Setenv("CHAT_MEDIA_SECURE", "")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "CHAT_MEDIA_SECURE") {
		t.Fatalf("production accepted plain-text chat storage: %v", err)
	}
	t.Setenv("CHAT_MEDIA_SECURE", "true")
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
}
