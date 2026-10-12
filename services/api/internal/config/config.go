package config

import (
	"errors"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"
)

var firebaseProjectPattern = regexp.MustCompile(`^[a-z0-9-]{4,64}$`)

type Config struct {
	Env, Listen, DatabaseURL, Issuer, Audience, Origin string
	// FirebaseProjectID selects Firebase Authentication. Issuer and Audience are then
	// derived from it; OIDC_ISSUER and OIDC_AUDIENCE stay available for generic OIDC.
	FirebaseProjectID string
	DevAuth           bool
	// AgeBandIsolation (AGE_BAND_ISOLATION, default true) keeps minors and adults from seeing or
	// reaching each other. false restores block-only behaviour; the minor defaults still apply.
	AgeBandIsolation bool
	// Media storage is optional; MEDIA_ENDPOINT enables it.
	MediaEndpoint, MediaAccessKey, MediaSecretKey, MediaBucket, MediaRegion string
	MediaSecure                                                             bool
	// Encrypted chat attachments live in their own bucket with their own bucket-scoped token, never the
	// social bucket above. Optional too: CHAT_MEDIA_ENDPOINT enables it, otherwise sending photos in
	// chats answers 503 CHAT_MEDIA_UNAVAILABLE.
	ChatMediaEndpoint, ChatMediaAccessKey, ChatMediaSecretKey, ChatMediaBucket, ChatMediaRegion string
	ChatMediaSecure                                                                             bool
}

func Load() (Config, error) {
	c := Config{Env: os.Getenv("APP_ENV"), Listen: os.Getenv("LISTEN_ADDR"), DatabaseURL: os.Getenv("DATABASE_URL"), Issuer: os.Getenv("OIDC_ISSUER"), Audience: os.Getenv("OIDC_AUDIENCE"), Origin: os.Getenv("WEB_ORIGIN"), DevAuth: os.Getenv("ENABLE_DEV_AUTH") == "true", FirebaseProjectID: os.Getenv("FIREBASE_PROJECT_ID")}
	if c.Listen == "" {
		c.Listen = "127.0.0.1:8080"
	}
	switch os.Getenv("AGE_BAND_ISOLATION") {
	case "", "true":
		c.AgeBandIsolation = true
	case "false":
		c.AgeBandIsolation = false
	default:
		return c, errors.New("AGE_BAND_ISOLATION must be true or false")
	}
	c.MediaEndpoint, c.MediaAccessKey, c.MediaSecretKey = os.Getenv("MEDIA_ENDPOINT"), os.Getenv("MEDIA_ACCESS_KEY"), os.Getenv("MEDIA_SECRET_KEY")
	c.MediaBucket, c.MediaRegion, c.MediaSecure = os.Getenv("MEDIA_BUCKET"), os.Getenv("MEDIA_REGION"), os.Getenv("MEDIA_SECURE") == "true"
	if c.MediaBucket == "" {
		c.MediaBucket = "hiyall-media"
	}
	if c.MediaRegion == "" {
		c.MediaRegion = "us-east-1"
	}
	if c.MediaEndpoint != "" && (c.MediaAccessKey == "" || c.MediaSecretKey == "") {
		return c, errors.New("MEDIA_ACCESS_KEY and MEDIA_SECRET_KEY are required with MEDIA_ENDPOINT")
	}
	if c.Env == "production" && c.MediaEndpoint != "" && !c.MediaSecure {
		return c, errors.New("production media storage requires MEDIA_SECURE=true")
	}
	c.ChatMediaEndpoint, c.ChatMediaAccessKey, c.ChatMediaSecretKey = os.Getenv("CHAT_MEDIA_ENDPOINT"), os.Getenv("CHAT_MEDIA_ACCESS_KEY"), os.Getenv("CHAT_MEDIA_SECRET_KEY")
	c.ChatMediaBucket, c.ChatMediaRegion, c.ChatMediaSecure = os.Getenv("CHAT_MEDIA_BUCKET"), os.Getenv("CHAT_MEDIA_REGION"), os.Getenv("CHAT_MEDIA_SECURE") == "true"
	if c.ChatMediaBucket == "" {
		c.ChatMediaBucket = "hiyall-chat"
	}
	if c.ChatMediaRegion == "" {
		c.ChatMediaRegion = "us-east-1"
	}
	if c.ChatMediaEndpoint != "" && (c.ChatMediaAccessKey == "" || c.ChatMediaSecretKey == "") {
		return c, errors.New("CHAT_MEDIA_ACCESS_KEY and CHAT_MEDIA_SECRET_KEY are required with CHAT_MEDIA_ENDPOINT")
	}
	if c.Env == "production" && c.ChatMediaEndpoint != "" && !c.ChatMediaSecure {
		return c, errors.New("production chat media storage requires CHAT_MEDIA_SECURE=true")
	}
	if c.ChatMediaEndpoint != "" && c.ChatMediaEndpoint == c.MediaEndpoint && c.ChatMediaBucket == c.MediaBucket {
		return c, errors.New("CHAT_MEDIA_BUCKET must not be the social media bucket")
	}
	if c.DatabaseURL == "" {
		return c, errors.New("DATABASE_URL is required")
	}
	if c.Env != "development" && c.Env != "production" {
		return c, errors.New("APP_ENV must be set to development or production")
	}
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return c, errors.New("invalid LISTEN_ADDR")
	}
	if c.DevAuth && (c.Env != "development" || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback()) {
		return c, errors.New("development authentication requires a loopback listener in development")
	}
	if c.FirebaseProjectID != "" {
		if !firebaseProjectPattern.MatchString(c.FirebaseProjectID) {
			return c, errors.New("FIREBASE_PROJECT_ID must be 4-64 lowercase letters, digits or hyphens")
		}
		issuer, audience := "https://securetoken.google.com/"+c.FirebaseProjectID, c.FirebaseProjectID
		if (c.Issuer != "" && c.Issuer != issuer) || (c.Audience != "" && c.Audience != audience) {
			return c, errors.New("FIREBASE_PROJECT_ID cannot be combined with a different OIDC_ISSUER or OIDC_AUDIENCE")
		}
		c.Issuer, c.Audience = issuer, audience
	}
	if !c.DevAuth && (c.Issuer == "" || c.Audience == "") {
		return c, errors.New("FIREBASE_PROJECT_ID, or OIDC_ISSUER and OIDC_AUDIENCE, are required")
	}
	if c.Env == "production" {
		issuer, e := url.Parse(c.Issuer)
		if e != nil || issuer.Scheme != "https" || issuer.Host == "" || issuer.User != nil {
			return c, errors.New("production OIDC issuer must be HTTPS")
		}
		db, e := url.Parse(c.DatabaseURL)
		if e != nil || db.Query().Get("sslmode") != "verify-full" {
			return c, errors.New("production database requires sslmode=verify-full")
		}
		if c.Origin != "" {
			origin, e := url.Parse(c.Origin)
			if e != nil || origin.Scheme != "https" || origin.Host == "" || origin.Path != "" || origin.User != nil || origin.RawQuery != "" {
				return c, errors.New("WEB_ORIGIN must be an HTTPS origin")
			}
		}
	}
	if strings.Contains(c.Listen, "\n") {
		return c, errors.New("invalid listen address")
	}
	return c, nil
}
