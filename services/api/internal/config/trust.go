package config

import (
	"errors"
	"os"
)

// Trust is the trust-and-safety configuration: the upload scanner and Sign in with Apple revocation
// (docs/security/16-csam-and-illegal-content.md, docs/api/22-account-deletion-and-export.md).
type Trust struct {
	// ScanHashlistFile (SCAN_HASHLIST_FILE) is an operator-supplied list of SHA-256 and perceptual hashes
	// of known illegal images. Never committed. ScanProviderURL and ScanProviderKeyFile
	// (SCAN_PROVIDER_URL, SCAN_PROVIDER_KEY_FILE) name a hosted scanning service. With neither, uploads are
	// not scanned, which production refuses unless ScanAllowNone (SCAN_ALLOW_NONE=true) is set.
	ScanHashlistFile, ScanProviderURL, ScanProviderKeyFile string
	ScanAllowNone                                          bool
	// Sign in with Apple token revocation at account deletion (App Store guideline 5.1.1(v)). All four
	// APPLE_* values go together; AppleSignInEnabled (APPLE_SIGN_IN_ENABLED=true) says the app offers
	// Apple sign-in, which makes them mandatory in production.
	AppleSignInEnabled                                          bool
	AppleTeamID, AppleKeyID, AppleClientID, ApplePrivateKeyFile string
}

// Scanning says whether any scanner is configured.
func (t Trust) Scanning() bool { return t.ScanHashlistFile != "" || t.ScanProviderURL != "" }

// AppleConfigured says whether Apple revocation can run.
func (t Trust) AppleConfigured() bool {
	return t.AppleTeamID != "" && t.AppleKeyID != "" && t.AppleClientID != "" && t.ApplePrivateKeyFile != ""
}

func boolEnv(name string) (bool, error) {
	switch os.Getenv(name) {
	case "", "false":
		return false, nil
	case "true":
		return true, nil
	}
	return false, errors.New(name + " must be true or false")
}

func (c *Config) loadTrust() error {
	var err error
	t := &c.Trust
	t.ScanHashlistFile, t.ScanProviderURL, t.ScanProviderKeyFile = os.Getenv("SCAN_HASHLIST_FILE"), os.Getenv("SCAN_PROVIDER_URL"), os.Getenv("SCAN_PROVIDER_KEY_FILE")
	t.AppleTeamID, t.AppleKeyID, t.AppleClientID, t.ApplePrivateKeyFile = os.Getenv("APPLE_TEAM_ID"), os.Getenv("APPLE_KEY_ID"), os.Getenv("APPLE_CLIENT_ID"), os.Getenv("APPLE_PRIVATE_KEY_FILE")
	if t.ScanAllowNone, err = boolEnv("SCAN_ALLOW_NONE"); err != nil {
		return err
	}
	if t.AppleSignInEnabled, err = boolEnv("APPLE_SIGN_IN_ENABLED"); err != nil {
		return err
	}
	if (t.ScanProviderURL == "") != (t.ScanProviderKeyFile == "") {
		return errors.New("SCAN_PROVIDER_URL and SCAN_PROVIDER_KEY_FILE go together")
	}
	set := 0
	for _, v := range []string{t.AppleTeamID, t.AppleKeyID, t.AppleClientID, t.ApplePrivateKeyFile} {
		if v != "" {
			set++
		}
	}
	if set != 0 && set != 4 {
		return errors.New("APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID and APPLE_PRIVATE_KEY_FILE go together")
	}
	if c.Env == "production" {
		if c.MediaEndpoint != "" && !t.Scanning() && !t.ScanAllowNone {
			return errors.New("production photo uploads need an upload scanner: set SCAN_HASHLIST_FILE or SCAN_PROVIDER_URL, or SCAN_ALLOW_NONE=true to run unscanned (not recommended)")
		}
		if t.AppleSignInEnabled && set != 4 {
			return errors.New("APPLE_SIGN_IN_ENABLED=true needs APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID and APPLE_PRIVATE_KEY_FILE so deleted accounts can revoke their Apple tokens")
		}
	}
	return nil
}
