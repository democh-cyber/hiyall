package domain

import (
	"encoding/json"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// Profile and discovery v2 (docs/api/25-profile-and-discovery-v2.md): language levels, personality tags,
// the about-me and hometown fields, the gallery limits and the two new social-visibility windows.

// Language levels. A language on a profile has a level from LanguageLevelMin (just starting) to LanguageLevelMax
// (native). The names are display text and belong to the app; the API only knows the number.
const (
	LanguageLevelMin = 1
	LanguageLevelMax = 6
	// LanguageLevelDefault is the level of a language written without one (a bare tag, an older client).
	LanguageLevelDefault = 3
	// LanguageLearningMax is the highest level that counts as "still learning" for possible matches; a
	// language at LanguageFluentMin or above counts as one the member can help others with.
	LanguageLearningMax = 3
	LanguageFluentMin   = 4
)

// legacyLanguageLevels are the words older clients and stored profiles used.
var legacyLanguageLevels = map[string]int{"basic": 2, "conversational": 3, "fluent": 4, "native": 6}

// PersonalityTags are the fixed tags a member can pick (PersonalityTagsMin to Entitlements.PersonalityTagsMax,
// or none). The server stores the id; the app owns the words and the icons.
var PersonalityTags = []string{
	"curious", "night_owl", "early_bird", "homebody", "explorer", "bookish", "foodie", "maker", "playful", "sporty",
	"music_lover", "film_fan", "jokester", "deep_thinker", "planner", "spontaneous", "empathetic", "chatty", "low_key",
}

// PersonalityTagsMin is the fewest tags a member who picks any must pick.
const PersonalityTagsMin = 3

// IsPersonalityTag reports whether tag is one of PersonalityTags.
func IsPersonalityTag(tag string) bool { return member(tag, PersonalityTags...) }

// AboutMeMax and HometownMax are the longest about-me and hometown text, in characters.
const (
	AboutMeMax  = 160
	HometownMax = 80
	// MinorHometownMax is the longest hometown a member under 18 may write.
	MinorHometownMax = 40
)

// addressWords are words that make a hometown look like a street address rather than a town or a city.
var addressWords = regexp.MustCompile(`(?i)\b(street|road|avenue|lane|boulevard|apartment|apt|flat|house|plot|sector|floor|p\.?o\.? box)\b`)

// ValidateHometown checks a hometown or city that a member typed: coarse free text, never an address. It is at
// most HometownMax characters (MinorHometownMax for a member under 18), has at most two digits and none of the
// characters #, @, / or :, and no street, apartment or box words. The empty text clears it. The message never
// repeats the input.
func ValidateHometown(value string, minor bool) error {
	max := HometownMax
	if minor {
		max = MinorHometownMax
	}
	if utf8.RuneCountInString(value) > max {
		return invalid("hometown", "must be at most "+itoa(max)+" characters")
	}
	digits := 0
	for _, r := range value {
		if r >= '0' && r <= '9' {
			digits++
		}
	}
	if digits > 2 || strings.ContainsAny(value, "#@/:") || addressWords.MatchString(value) {
		return invalid("hometown", "write a town or city, not an address")
	}
	return nil
}

// Visitor windows. Recent visitors and "places I've visited" look back VisitWindow and show at most
// VisitListMax people (the list is also bounded by the member's Entitlements.VisitorListLimit for the owner list).
const (
	VisitWindow  = 30 * 24 * time.Hour
	VisitListMax = 200
)

// Errors of the v2 profile.
var (
	ErrPhotosFull         = &PolicyError{409, "PHOTOS_FULL", "You’ve reached the photo limit. Remove one to add another."}
	ErrPhotoNotFound      = &PolicyError{404, "NOT_FOUND", "That photo isn’t in your gallery."}
	ErrVisitorsPrivate    = &PolicyError{403, "VISITORS_PRIVATE", "This member doesn’t share who visited their profile."}
	ErrSameCountryUnknown = &PolicyError{422, "COUNTRY_NOT_SET", "Add your country to your profile to find people from the same country."}
)

// normaliseLanguages validates the languages of a profile patch against max and returns the canonical JSON:
// [{"code","level"}] with an integer level. An entry may be a bare tag, an object whose level is a number
// from LanguageLevelMin to LanguageLevelMax, one of the older words, or missing (LanguageLevelDefault).
func normaliseLanguages(raw json.RawMessage, max int) (json.RawMessage, error) {
	bad := invalid("languages", "invalid or duplicate language or proficiency")
	var entries []json.RawMessage
	if string(raw) == "null" || json.Unmarshal(raw, &entries) != nil || len(entries) > max {
		return nil, invalid("languages", "select up to "+itoa(max)+" languages")
	}
	out := make(Languages, 0, len(entries))
	seen := map[string]bool{}
	for _, entry := range entries {
		var l Language
		var tag string
		if json.Unmarshal(entry, &tag) == nil {
			l = Language{Code: tag, Level: LanguageLevelDefault}
		} else {
			var fields map[string]json.RawMessage
			if json.Unmarshal(entry, &fields) != nil {
				return nil, bad
			}
			for name := range fields {
				if name != "code" && name != "level" {
					return nil, bad
				}
			}
			if json.Unmarshal(fields["code"], &l.Code) != nil {
				return nil, bad
			}
			level, err := parseLanguageLevel(fields["level"], true)
			if err != nil {
				return nil, bad
			}
			l.Level = level
		}
		key := strings.ToLower(l.Code)
		if len(l.Code) > 35 || !localePattern.MatchString(l.Code) || seen[key] {
			return nil, bad
		}
		seen[key] = true
		out = append(out, l)
	}
	canonical, _ := json.Marshal(out)
	return canonical, nil
}

// parseLanguageLevel reads a level: a JSON integer from 1 to 6, or (when legacy is set) one of the older words
// or nothing at all, which is the default level. null is never a level.
func parseLanguageLevel(raw json.RawMessage, legacy bool) (int, error) {
	if len(raw) == 0 {
		if legacy {
			return LanguageLevelDefault, nil
		}
		return 0, invalid("languages", "proficiency is required")
	}
	if string(raw) == "null" {
		return 0, invalid("languages", "proficiency must be a number")
	}
	var n int
	if json.Unmarshal(raw, &n) == nil && itoa(n) == string(raw) {
		if n < LanguageLevelMin || n > LanguageLevelMax {
			return 0, invalid("languages", "proficiency must be from 1 to 6")
		}
		return n, nil
	}
	var word string
	if legacy && json.Unmarshal(raw, &word) == nil {
		if word == "" {
			return LanguageLevelDefault, nil
		}
		if n, ok := legacyLanguageLevels[word]; ok {
			return n, nil
		}
	}
	return 0, invalid("languages", "proficiency must be a number from 1 to 6")
}

// normalisePersonalityTags validates the personality tags of a patch: none, or PersonalityTagsMin to max
// distinct tags of PersonalityTags.
func normalisePersonalityTags(raw json.RawMessage, max int) (json.RawMessage, error) {
	var tags []string
	if string(raw) == "null" || json.Unmarshal(raw, &tags) != nil {
		return nil, invalid("personalityTags", "choose personality tags from the list")
	}
	if len(tags) != 0 && (len(tags) < PersonalityTagsMin || len(tags) > max) {
		return nil, invalid("personalityTags", "choose "+itoa(PersonalityTagsMin)+" to "+itoa(max)+" tags, or none")
	}
	seen := map[string]bool{}
	for _, t := range tags {
		if !IsPersonalityTag(t) || seen[t] {
			return nil, invalid("personalityTags", "choose distinct personality tags from the list")
		}
		seen[t] = true
	}
	if tags == nil {
		tags = []string{}
	}
	canonical, _ := json.Marshal(tags)
	return canonical, nil
}

// validateFreeText checks the optional about-me and hometown text: a single trimmed line of up to max
// characters (about-me may hold line breaks), empty to clear.
func validateFreeText(name string, raw json.RawMessage, max int) (string, error) {
	value, err := validateString(name, raw, 0, max)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(value) != value {
		return "", invalid(name, "must not start or end with spaces")
	}
	if utf8.RuneCountInString(value) > max {
		return "", invalid(name, "is too long")
	}
	return value, nil
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}
