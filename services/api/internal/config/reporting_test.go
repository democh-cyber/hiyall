package config

import (
	"strings"
	"testing"
)

func devEnv(t *testing.T) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
}

func TestReportingAndEventsDefaultsAreOff(t *testing.T) {
	devEnv(t)
	t.Setenv("SENTRY_DSN", "")
	t.Setenv("SPACES_EVENTS_ENABLED", "")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.SentryDSN != "" || c.SpacesEventsEnabled {
		t.Fatalf("defaults must be off: %+v %v", c.Reporting, c.Features)
	}
}

func TestSentrySettingsAreRead(t *testing.T) {
	devEnv(t)
	t.Setenv("SENTRY_DSN", "https://key@o1.ingest.example.io/42")
	t.Setenv("SENTRY_RELEASE", "abc123")
	t.Setenv("SPACES_EVENTS_ENABLED", "true")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.SentryDSN == "" || c.SentryEnvironment != "development" || c.SentryRelease != "abc123" || !c.SpacesEventsEnabled {
		t.Fatalf("%+v %v", c.Reporting, c.Features)
	}
	t.Setenv("SENTRY_ENVIRONMENT", "staging")
	if c, _ = Load(); c.SentryEnvironment != "staging" {
		t.Fatal(c.SentryEnvironment)
	}
}

func TestMalformedDSNIsRefusedWithoutEchoingIt(t *testing.T) {
	devEnv(t)
	for _, bad := range []string{"not-a-dsn", "https://host.example/42", "ftp://k@h/1", "https://k@host.example/"} {
		t.Setenv("SENTRY_DSN", bad)
		_, err := Load()
		if err == nil {
			t.Fatalf("%q accepted", bad)
		}
		if strings.Contains(err.Error(), bad) {
			t.Fatalf("error echoes the DSN: %v", err)
		}
	}
}
