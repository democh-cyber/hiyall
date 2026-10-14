package domain

import (
	"encoding/json"
	"strings"
	"time"
)

// Account deletion and data export (docs/api/22-account-deletion-and-export.md).
const (
	// DeletionGrace is how long a member who asked to delete their account can still change their mind.
	DeletionGrace = 30 * 24 * time.Hour
	// ReauthWindow is how recent a member's sign-in (Firebase auth_time) must be to schedule a deletion.
	ReauthWindow = 5 * time.Minute
	// ExportInterval is the minimum time between two data exports of one member.
	ExportInterval = 24 * time.Hour
	// ExportURLLifetime is how long the media links in an export stay valid.
	ExportURLLifetime = 24 * time.Hour
)

var (
	ErrReauthRequired = &PolicyError{403, "REAUTH_REQUIRED", "Confirm it's you by signing in again."}
	// ErrDeletionClosed answers a cancel that arrives once the grace period is over: the purge may already be running.
	ErrDeletionClosed = &PolicyError{409, "DELETION_WINDOW_CLOSED", "The 30 days to keep this account have passed."}
	ErrExportLimited  = &PolicyError{429, "RATE_LIMITED", "You can download your data once a day. Try again later."}
)

// ParseDeletionRequest reads the body of POST /v1/me/deletion: exactly {confirmUsername}.
// The username is compared by the caller, case-insensitively and without a leading "@".
func ParseDeletionRequest(body map[string]json.RawMessage) (string, error) {
	var confirm string
	if len(body) != 1 || json.Unmarshal(body["confirmUsername"], &confirm) != nil {
		return "", &ValidationError{Field: "confirmUsername", Message: "type your username to confirm"}
	}
	return strings.ToLower(strings.TrimPrefix(strings.TrimSpace(confirm), "@")), nil
}

// ParseDeletion reads the body of POST /v1/me/deletion: {confirmUsername} and, for a member who signs in
// with Apple, {appleAuthorizationCode}, the one-time code from re-authenticating with Apple.
func ParseDeletion(body map[string]json.RawMessage) (confirm, appleCode string, err error) {
	if code, ok := body["appleAuthorizationCode"]; ok {
		if json.Unmarshal(code, &appleCode) != nil || appleCode == "" || len(appleCode) > 2048 {
			return "", "", &ValidationError{Field: "appleAuthorizationCode", Message: "send the code Apple returned"}
		}
		rest := map[string]json.RawMessage{}
		for k, v := range body {
			if k != "appleAuthorizationCode" {
				rest[k] = v
			}
		}
		body = rest
	}
	confirm, err = ParseDeletionRequest(body)
	return confirm, appleCode, err
}
