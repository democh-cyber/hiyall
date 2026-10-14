package config

import (
	"errors"
	"net/url"
	"os"
	"strings"
)

// Reporting holds the error tracker settings. Unset SENTRY_DSN means errors are only logged.
type Reporting struct {
	// SentryDSN (SENTRY_DSN) enables error reporting through cmd/api's reporter. SentryEnvironment
	// (SENTRY_ENVIRONMENT) defaults to APP_ENV and SentryRelease (SENTRY_RELEASE) is free text, such as a git sha.
	SentryDSN, SentryEnvironment, SentryRelease string
}

// Features switches off product features that are built but not offered yet.
type Features struct {
	// SpacesEventsEnabled (SPACES_EVENTS_ENABLED=true) allows creating event and moment spaces. Default off
	// for V1; communities are always allowed and existing events stay readable.
	SpacesEventsEnabled bool
}

func (c *Config) loadReporting() error {
	c.SentryDSN = strings.TrimSpace(os.Getenv("SENTRY_DSN"))
	c.SentryEnvironment = strings.TrimSpace(os.Getenv("SENTRY_ENVIRONMENT"))
	if c.SentryEnvironment == "" {
		c.SentryEnvironment = c.Env
	}
	c.SentryRelease = strings.TrimSpace(os.Getenv("SENTRY_RELEASE"))
	if c.SentryDSN != "" {
		if u, err := url.Parse(c.SentryDSN); err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User == nil || u.User.Username() == "" || strings.Trim(u.Path, "/") == "" {
			// The message never echoes the DSN: it contains the project key.
			return errors.New("SENTRY_DSN is not a valid DSN (https://<key>@<host>/<project>)")
		}
	}
	c.SpacesEventsEnabled = os.Getenv("SPACES_EVENTS_ENABLED") == "true"
	return nil
}
