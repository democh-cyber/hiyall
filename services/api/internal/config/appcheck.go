package config

import (
	"errors"
	"os"
	"strings"

	"hiyall/services/api/internal/appcheck"
)

// AppCheck is the Firebase App Check setting (internal/appcheck). The default is off: App Check has to be set up in the
// Firebase console and the app has to send tokens before anything may refuse a request.
type AppCheck struct {
	// AppCheckMode (APP_CHECK_ENFORCE) is false (default: nothing is checked), log (tokens are verified and
	// missing or invalid ones are counted in hiyall_app_check_total, never refused) or true (a request without a valid
	// X-Firebase-AppCheck token answers 401 APP_CHECK_REQUIRED). Probes, the legal documents and development login
	// are exempt.
	AppCheckMode appcheck.Mode
	// FirebaseProjectNumber (FIREBASE_PROJECT_NUMBER) is the numeric project number (Firebase console, Project
	// settings), not the project id. The token's issuer and audience are built from it. Required for log and true.
	FirebaseProjectNumber string
}

func (c *Config) loadAppCheck() error {
	mode, err := appcheck.ParseMode(os.Getenv("APP_CHECK_ENFORCE"))
	if err != nil {
		return err
	}
	c.AppCheckMode = mode
	c.FirebaseProjectNumber = strings.TrimSpace(os.Getenv("FIREBASE_PROJECT_NUMBER"))
	if c.FirebaseProjectNumber != "" && !appcheck.ValidProjectNumber(c.FirebaseProjectNumber) {
		// Not echoed: it is a project identifier, but the message is the same however it is wrong.
		return errors.New("FIREBASE_PROJECT_NUMBER must be the numeric Firebase project number (digits), not the project id")
	}
	if mode != appcheck.Off && c.FirebaseProjectNumber == "" {
		return errors.New("APP_CHECK_ENFORCE=" + string(mode) + " requires FIREBASE_PROJECT_NUMBER")
	}
	return nil
}
