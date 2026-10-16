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

// DeletionRequest is the body of POST /v1/me/deletion.
type DeletionRequest struct {
	// Confirm is the username typed to confirm, lower-cased and without a leading "@".
	Confirm string
	// AppleCode is the one-time Sign in with Apple authorization code from re-authenticating with Apple.
	AppleCode string
	// AppleCodeUnavailable is the client's statement that it re-authenticated and still could not obtain a code
	// (appleCodeUnavailable: true). The server then schedules the deletion anyway and queues a manual revocation
	// for an operator, so a member is never locked out of leaving.
	AppleCodeUnavailable bool
}

// ParseDeletionBody reads the body of POST /v1/me/deletion: {confirmUsername} and, for a member who signs in with
// Apple, either {appleAuthorizationCode} or {appleCodeUnavailable: true}, never both.
func ParseDeletionBody(body map[string]json.RawMessage) (DeletionRequest, error) {
	var r DeletionRequest
	rest := map[string]json.RawMessage{}
	for k, v := range body {
		switch k {
		case "appleAuthorizationCode":
			if json.Unmarshal(v, &r.AppleCode) != nil || r.AppleCode == "" || len(r.AppleCode) > 2048 {
				return r, &ValidationError{Field: "appleAuthorizationCode", Message: "send the code Apple returned"}
			}
		case "appleCodeUnavailable":
			if json.Unmarshal(v, &r.AppleCodeUnavailable) != nil {
				return r, &ValidationError{Field: "appleCodeUnavailable", Message: "must be true or false"}
			}
		default:
			rest[k] = v
		}
	}
	if r.AppleCode != "" && r.AppleCodeUnavailable {
		return r, &ValidationError{Field: "appleCodeUnavailable", Message: "send the authorization code or say it is unavailable, not both"}
	}
	var err error
	r.Confirm, err = ParseDeletionRequest(rest)
	return r, err
}

// ParseDeletion is ParseDeletionBody for a caller that does not use appleCodeUnavailable.
func ParseDeletion(body map[string]json.RawMessage) (confirm, appleCode string, err error) {
	r, err := ParseDeletionBody(body)
	if err != nil {
		return "", "", err
	}
	return r.Confirm, r.AppleCode, nil
}
