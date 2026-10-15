package main

import (
	"fmt"
	"io"
	"log/slog"
	"strings"

	"hiyall/services/api/internal/appcheck"
	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/identity"
	"hiyall/services/api/internal/push"
)

// checkConfig is `api check-config [-release]`: it loads the environment exactly as a start does
// (config.Load, then the same pushSender, uploadScanner, appleRevoker and Firebase deleter construction, which
// read and parse the key files) and reports what a start would refuse, without opening the database (unless -db) or the
// network. It never prints a value, only the variable name and the rule.
//
// With -release it also applies the V1 release requirements that a start tolerates (push, error reporting, a
// minimum client version, Apple revocation and real media buckets), because a server that starts is not
// necessarily one that is fit to ship. With -db it also connects to DATABASE_URL and checks the database role
// and the grants of database/roles/grants.sql (dbrole.go). Exit 0: nothing to fix (warnings may print). 1: problems. 2: usage.
// config.Load stops at its first complaint, so fix and rerun until it is clean.
func checkConfig(args []string, stdout, stderr io.Writer) int {
	release, database := false, false
	for _, a := range args {
		switch a {
		case "-release", "--release":
			release = true
		case "-db", "--db":
			database = true
		default:
			fmt.Fprintln(stderr, "usage: api check-config [-release] [-db]")
			return 2
		}
	}
	// The start path logs while it builds these; a check prints its own findings instead.
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer slog.SetDefault(previous)

	problems, warnings := reviewConfig(release)
	if database {
		// -db opens DATABASE_URL (read only): the role's shape and the grants of database/roles/grants.sql.
		p, w := reviewDatabase()
		problems, warnings = append(problems, p...), append(warnings, w...)
	}
	for _, w := range warnings {
		fmt.Fprintln(stdout, "warning:", w)
	}
	for _, p := range problems {
		fmt.Fprintln(stdout, "problem:", p)
	}
	if len(problems) > 0 {
		fmt.Fprintf(stdout, "config check failed: %d problem(s)\n", len(problems))
		return 1
	}
	fmt.Fprintln(stdout, "config check passed")
	return 0
}

// reviewConfig returns what must be fixed and what deserves a look.
func reviewConfig(release bool) (problems, warnings []string) {
	cfg, err := config.Load()
	if err != nil {
		return []string{err.Error()}, nil
	}
	// The same constructors the start uses, so a key file that a start would reject is rejected here.
	sender, err := pushSender(cfg)
	if err != nil {
		problems = append(problems, err.Error())
	}
	if _, err := uploadScanner(cfg); err != nil {
		problems = append(problems, err.Error())
	}
	if _, err := appleRevoker(cfg); err != nil {
		problems = append(problems, err.Error())
	}
	if cfg.FirebaseServiceAccountFile != "" {
		if _, err := identity.NewFirebaseDeleter(cfg.FirebaseProjectID, cfg.FirebaseServiceAccountFile); err != nil {
			problems = append(problems, err.Error())
		}
	}
	warnings = advisories(cfg)
	if release {
		problems = append(problems, releaseProblems(cfg, sender)...)
	}
	return problems, warnings
}

// advisories are legal but worth knowing about.
func advisories(cfg config.Config) []string {
	var w []string
	if cfg.Env != "production" {
		return w
	}
	if cfg.ScanAllowNone && !cfg.Scanning() {
		w = append(w, "SCAN_ALLOW_NONE=true: uploaded photos are NOT scanned for illegal imagery; configure SCAN_HASHLIST_FILE or SCAN_PROVIDER_URL")
	}
	if cfg.AppCheckMode == appcheck.Off {
		w = append(w, "APP_CHECK_ENFORCE=false: requests are not tied to the real app (the app does not send App Check tokens yet; see the deploy guide, App Check)")
	}
	if !cfg.BehindProxy && !cfg.DirectListener {
		w = append(w, "neither BEHIND_PROXY=true nor DIRECT_LISTENER=true is set: if the API is reached through a proxy, every client shares one rate-limit bucket")
	}
	if cfg.BehindProxy && cfg.ClientIPHeader == "" {
		w = append(w, "CLIENT_IP_HEADER is not set: the rightmost untrusted X-Forwarded-For hop is used; a proxy that sets one header (Fly-Client-IP, CF-Connecting-IP) is more robust")
	}
	if cfg.DebugLogPeer {
		w = append(w, "DEBUG_LOG_PEER=true logs forwarding headers of the first requests; unset it once TRUSTED_PROXY_CIDRS is right")
	}
	if cfg.SentryDSN == "" {
		w = append(w, "SENTRY_DSN is not set: panics and 500s are only logged")
	}
	if cfg.FCMServiceAccountFile == "" {
		w = append(w, "FCM_SERVICE_ACCOUNT_FILE is not set: pushes are only logged")
	}
	if !cfg.AppleConfigured() {
		w = append(w, "APPLE_* is not configured: deleted accounts keep their Sign in with Apple authorization")
	}
	if cfg.MediaEndpoint == "" || cfg.ChatMediaEndpoint == "" {
		w = append(w, "MEDIA_ENDPOINT or CHAT_MEDIA_ENDPOINT is not set: photo uploads or chat photos are off")
	}
	return w
}

// placeholderValue says whether a setting still holds the template text of config/api.production.example.env.
func placeholderValue(v string) bool {
	u := strings.ToUpper(v)
	return strings.ContainsAny(v, "<>") || strings.Contains(u, "CHANGE-ME") || strings.Contains(u, "CHANGE_ME") || strings.Contains(u, "REPLACE_ME") || strings.Contains(u, "YOUR-DOMAIN")
}

// releaseProblems are the requirements for shipping to real people that a start does not enforce.
func releaseProblems(cfg config.Config, sender push.Sender) []string {
	var p []string
	add := func(format string, a ...any) { p = append(p, fmt.Sprintf(format, a...)) }
	if cfg.Env != "production" {
		add("APP_ENV must be production for a release (got %q)", cfg.Env)
	}
	if cfg.DevAuth {
		add("ENABLE_DEV_AUTH must not be set for a release")
	}
	// How clients reach the API must be a decision, not an absence (audit API-1).
	if !(cfg.BehindProxy && len(cfg.TrustedProxies) > 0) && !cfg.DirectListener {
		add("set BEHIND_PROXY=true with TRUSTED_PROXY_CIDRS (and CLIENT_IP_HEADER), or DIRECT_LISTENER=true: the client address must be known to be right")
	}
	if cfg.DebugLogPeer {
		add("DEBUG_LOG_PEER must be unset for a release: it is a temporary aid for finding the proxy address")
	}
	if cfg.MediaEndpoint != "" && !cfg.EvidenceSeparate() {
		add("EVIDENCE_BUCKET (and its write-only token) is required: quarantined originals must not sit where the API's token can delete them")
	}
	if cfg.FirebaseProjectID == "" {
		add("FIREBASE_PROJECT_ID is required: the apps sign in with Firebase")
	}
	for _, v := range []struct{ name, value string }{
		{"DATABASE_URL", cfg.DatabaseURL}, {"MEDIA_ENDPOINT", cfg.MediaEndpoint},
		{"CHAT_MEDIA_ENDPOINT", cfg.ChatMediaEndpoint}, {"WEB_ORIGIN", cfg.Origin},
	} {
		if placeholderValue(v.value) {
			add("%s still contains template placeholder text", v.name)
		}
	}
	if cfg.MediaEndpoint == "" {
		add("MEDIA_ENDPOINT (and its bucket and token) is required: profile and post photos")
	}
	if cfg.ChatMediaEndpoint == "" {
		add("CHAT_MEDIA_ENDPOINT (and its bucket and token) is required: chat photos")
	}
	if !cfg.Scanning() && !cfg.ScanAllowNone {
		add("configure SCAN_HASHLIST_FILE or SCAN_PROVIDER_URL (+ SCAN_PROVIDER_KEY_FILE), or set SCAN_ALLOW_NONE=true to ship unscanned on purpose")
	}
	if _, ok := sender.(*push.FCM); !ok {
		add("FCM_SERVICE_ACCOUNT_FILE is required: pushes are otherwise only logged")
	}
	if cfg.SentryDSN == "" {
		add("SENTRY_DSN is required: errors must reach an error tracker")
	}
	if !cfg.AppleSignInEnabled || !cfg.AppleConfigured() {
		add("APPLE_SIGN_IN_ENABLED=true with APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID and APPLE_PRIVATE_KEY_FILE is required: the app offers Sign in with Apple, so deleting an account must revoke it (App Store 5.1.1(v))")
	}
	for _, platform := range []string{"android", "ios"} {
		if cfg.MinClientVersion[platform] == "" {
			add("MIN_CLIENT_VERSION_%s is required (for example 1.0.0) so a bad release can be retired with 426 UPGRADE_REQUIRED", strings.ToUpper(platform))
		}
	}
	return p
}
