package main

import (
	"errors"
	"log/slog"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/identity"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// uploadScanner builds the scanner chain from SCAN_* (docs/security/16-csam-and-illegal-content.md). With
// nothing configured it is media.None, loudly in production.
func uploadScanner(cfg config.Config) (media.Scanner, error) {
	var chain media.Chain
	if cfg.ScanHashlistFile != "" {
		list, err := media.NewHashList(cfg.ScanHashlistFile)
		if err != nil {
			return nil, err
		}
		slog.Info("upload scanner: hash list", "entries", list.Len())
		chain = append(chain, list)
	}
	if cfg.ScanProviderURL != "" {
		provider, err := media.NewHTTPProvider(cfg.ScanProviderURL, cfg.ScanProviderKeyFile, cfg.Env == "production")
		if err != nil {
			return nil, err
		}
		slog.Info("upload scanner: provider")
		chain = append(chain, provider)
	}
	if len(chain) > 0 {
		return chain, nil
	}
	if cfg.Env == "production" {
		if !cfg.ScanAllowNone {
			return nil, errors.New("no upload scanner configured")
		}
		slog.Error("UPLOADS ARE NOT SCANNED: SCAN_ALLOW_NONE=true is set in production. Photos that match known illegal imagery will be shown. Configure SCAN_HASHLIST_FILE or SCAN_PROVIDER_URL, and the Cloudflare CSAM Scanning Tool on the media zone.")
	} else {
		slog.Warn("upload scanner not configured; photos are not scanned (development only)")
	}
	return media.None{}, nil
}

// appleRevoker is nil, with a warning, when the APPLE_* values are not set.
func appleRevoker(cfg config.Config) (*identity.AppleRevoker, error) {
	if !cfg.AppleConfigured() {
		slog.Warn("Sign in with Apple token revocation not configured; deleted accounts keep their Apple authorization (APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID, APPLE_PRIVATE_KEY_FILE)")
		return nil, nil
	}
	return identity.NewAppleRevoker(identity.AppleConfig{TeamID: cfg.AppleTeamID, KeyID: cfg.AppleKeyID, ClientID: cfg.AppleClientID, PrivateKeyFile: cfg.ApplePrivateKeyFile})
}

// withApple finishes queued Apple revocations before the purge deletes an identity.
func withApple(inner store.IdentityDeleter, revoker *identity.AppleRevoker, db *store.Store) store.IdentityDeleter {
	if revoker == nil {
		return inner
	}
	return identity.AppleDeleter{Inner: inner, Revoker: revoker, Queue: db}
}
