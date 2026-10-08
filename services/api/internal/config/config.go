package config

import (
	"errors"
	"net"
	"net/url"
	"os"
	"strings"
)

type Config struct {
	Env, Listen, DatabaseURL, Issuer, Audience, Origin string
	DevAuth                                            bool
	// Media storage is optional; MEDIA_ENDPOINT enables it.
	MediaEndpoint, MediaAccessKey, MediaSecretKey, MediaBucket, MediaRegion string
	MediaSecure                                                             bool
}

func Load() (Config, error) {
	c := Config{Env: os.Getenv("APP_ENV"), Listen: os.Getenv("LISTEN_ADDR"), DatabaseURL: os.Getenv("DATABASE_URL"), Issuer: os.Getenv("OIDC_ISSUER"), Audience: os.Getenv("OIDC_AUDIENCE"), Origin: os.Getenv("WEB_ORIGIN"), DevAuth: os.Getenv("ENABLE_DEV_AUTH") == "true"}
	if c.Listen == "" {
		c.Listen = "127.0.0.1:8080"
	}
	c.MediaEndpoint, c.MediaAccessKey, c.MediaSecretKey = os.Getenv("MEDIA_ENDPOINT"), os.Getenv("MEDIA_ACCESS_KEY"), os.Getenv("MEDIA_SECRET_KEY")
	c.MediaBucket, c.MediaRegion, c.MediaSecure = os.Getenv("MEDIA_BUCKET"), os.Getenv("MEDIA_REGION"), os.Getenv("MEDIA_SECURE") == "true"
	if c.MediaBucket == "" {
		c.MediaBucket = "kairova-media"
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
	if !c.DevAuth && (c.Issuer == "" || c.Audience == "") {
		return c, errors.New("OIDC_ISSUER and OIDC_AUDIENCE are required")
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
