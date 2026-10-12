package domain

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

// TermsVersion is the version of the terms and privacy notice a new account must
// accept. Bump it only together with the client copy that presents it.
const TermsVersion = "2026-10-01"

// MinimumAge is the youngest age a person may declare to join. 13 is the legal
// floor the identity providers themselves apply; the owner may change it here
// and the refusal message follows it. It is a self-declared policy gate, not age
// assurance. The declared birth date is kept privately (member_ages) to place the
// member in an age band; see agebands.go.
const MinimumAge = 13

// PlaceholderDisplayName is the display name every automatically provisioned
// account starts with.
const PlaceholderDisplayName = "Hiyall member"

var placeholderUsernamePattern = regexp.MustCompile(`^member_[0-9a-f]{12}$`)

var (
	ErrEmailNotVerified   = &PolicyError{403, "EMAIL_NOT_VERIFIED", "Verify your email to continue."}
	ErrOnboardingRequired = &PolicyError{403, "ONBOARDING_REQUIRED", "Finish setting up your profile to continue."}
	ErrAgeRequirement     = &PolicyError{403, "AGE_REQUIREMENT_NOT_MET", fmt.Sprintf("Hiyall is for people %d and over.", MinimumAge)}
	ErrProfileIncomplete  = &PolicyError{422, "PROFILE_INCOMPLETE", "Choose a name and username first."}
)

// PlaceholderUsername is the generated handle an account holds until its owner
// chooses one. The suffix is the last 12 hex digits of the account id.
func PlaceholderUsername(userID string) string {
	return "member_" + uuid.MustParse(userID).String()[24:]
}

// IsPlaceholderUsername reports whether username has the generated shape. Such
// handles are never offered to people, so a placeholder is always recognisable.
func IsPlaceholderUsername(username string) bool {
	return placeholderUsernamePattern.MatchString(username)
}

// ProfileIsPlaceholder reports whether a profile still carries provisioning defaults.
func ProfileIsPlaceholder(username, displayName string) bool {
	name := strings.TrimSpace(displayName)
	return IsPlaceholderUsername(username) || name == "" || strings.EqualFold(name, PlaceholderDisplayName)
}

// ValidateUsername applies the profile username grammar.
func ValidateUsername(username string) error {
	if !handlePattern.MatchString(username) {
		return invalid("username", "use 3–30 lowercase letters, numbers or underscores")
	}
	return nil
}

// ParseOnboardingCompletion checks the completion request and returns the declared
// birth date for the caller to store privately (member_ages). The birth date is
// otherwise never returned, echoed, logged or put in an event, and no error message
// repeats it. A declaration under MinimumAge is ErrAgeRequirement and nothing is stored.
func ParseOnboardingCompletion(body map[string]json.RawMessage, now time.Time) (time.Time, error) {
	for name := range body {
		if name != "birthDate" && name != "termsVersion" {
			return time.Time{}, invalid(name, "field is not accepted")
		}
	}
	rawDate, ok := body["birthDate"]
	if !ok {
		return time.Time{}, invalid("birthDate", "is required")
	}
	rawTerms, ok := body["termsVersion"]
	if !ok {
		return time.Time{}, invalid("termsVersion", "is required")
	}
	value, err := validateString("birthDate", rawDate, 10, 10)
	if err != nil {
		return time.Time{}, invalid("birthDate", "use a date written as YYYY-MM-DD")
	}
	birth, err := time.Parse(time.DateOnly, value)
	if err != nil || birth.Year() < 1900 {
		return time.Time{}, invalid("birthDate", "use a real date written as YYYY-MM-DD, from 1900 onwards")
	}
	now = now.UTC()
	if birth.After(time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)) {
		return time.Time{}, invalid("birthDate", "cannot be in the future")
	}
	terms, err := validateString("termsVersion", rawTerms, 1, 32)
	if err != nil || terms != TermsVersion {
		return time.Time{}, invalid("termsVersion", "accept the current terms and privacy notice")
	}
	if AgeAt(birth, now) < MinimumAge {
		return time.Time{}, ErrAgeRequirement
	}
	return birth, nil
}

// ValidateOnboardingCompletion is ParseOnboardingCompletion without the date.
func ValidateOnboardingCompletion(body map[string]json.RawMessage, now time.Time) error {
	_, err := ParseOnboardingCompletion(body, now)
	return err
}

// AgeAt is the number of whole years between birth and now, by calendar date.
// Someone born on 29 February turns a year older on 1 March in common years.
func AgeAt(birth, now time.Time) int {
	years := now.Year() - birth.Year()
	if now.Month() < birth.Month() || (now.Month() == birth.Month() && now.Day() < birth.Day()) {
		years--
	}
	return years
}
