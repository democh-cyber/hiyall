package domain

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrNotFound      = errors.New("not found")
	ErrConflict      = errors.New("version conflict")
	ErrUsernameTaken = errors.New("username taken")
	ErrUnauthorized  = errors.New("unauthorized")
	handlePattern    = regexp.MustCompile(`^[a-z0-9_]{3,30}$`)
	localePattern    = regexp.MustCompile(`^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$`)
	countryPattern   = regexp.MustCompile(`^[A-Z]{2}$`)
)

type ValidationError struct{ Field, Message string }

func (e *ValidationError) Error() string  { return e.Field + ": " + e.Message }
func invalid(field, message string) error { return &ValidationError{field, message} }

type Profile struct {
	UserID          string       `json:"userId"`
	Username        string       `json:"username"`
	DisplayName     string       `json:"displayName"`
	Bio             string       `json:"bio"`
	Headline        string       `json:"headline"`
	Quote           string       `json:"quote"`
	SocialStats     *SocialStats `json:"socialStats,omitempty"`
	Interests       []string     `json:"interests"`
	CurrentVibe     string       `json:"currentVibe"`
	ProfileAccent   string       `json:"profileAccent"`
	ProfilePattern  string       `json:"profilePattern"`
	AvatarFrame     string       `json:"avatarFrame"`
	AvatarMediaID   *string      `json:"avatarMediaId"`
	CoverMediaID    *string      `json:"coverMediaId"`
	Pronouns        string       `json:"pronouns"`
	Gender          string       `json:"gender"`
	Country         *string      `json:"country"`
	Region          string       `json:"region"`
	City            string       `json:"city"`
	Timezone        string       `json:"timezone"`
	WebsiteURL      *string      `json:"websiteUrl"`
	Profession      string       `json:"profession"`
	Education       string       `json:"education"`
	Languages       Languages    `json:"languages"`
	ProfileAudience string       `json:"profileAudience"`
	Locale          string       `json:"locale"`
	Version         string       `json:"version"`
	CreatedAt       time.Time    `json:"createdAt"`
	UpdatedAt       time.Time    `json:"updatedAt"`
}

// ProfileView is the own-profile response: the stored profile plus signed URLs for the
// profile photo (thumbnail and full size), or null when there is none. The URLs are never
// stored; they are minted for each response.
type ProfileView struct {
	Profile
	AvatarURL     *string `json:"avatarUrl"`
	AvatarFullURL *string `json:"avatarFullUrl"`
}

// SocialStats is derived from stored relationships, visits and stories, never editable profile data.
// Visitors is the number of different members who have opened the profile (never who). Stories is the
// number of unexpired stories the viewer may see, or the member's own active stories on their own profile.
type SocialStats struct {
	Friends   int64 `json:"friends"`
	Following int64 `json:"following"`
	Followers int64 `json:"followers"`
	Visitors  int64 `json:"visitors"`
	Stories   int64 `json:"stories"`
}

type Privacy struct {
	ProfileAudience     string            `json:"profileAudience"`
	MessagesFrom        string            `json:"messagesFrom"`
	FollowPolicy        string            `json:"followPolicy"`
	RequestsFrom        string            `json:"requestsFrom"`
	StoryAudience       string            `json:"storyAudience"`
	ActivityAudience    string            `json:"activityAudience"`
	OnlineAudience      string            `json:"onlineAudience"`
	LastSeenAudience    string            `json:"lastSeenAudience"`
	LocationAudience    string            `json:"locationAudience"`
	CommentsFrom        string            `json:"commentsFrom"`
	MentionsFrom        string            `json:"mentionsFrom"`
	Discoverable        bool              `json:"discoverable"`
	ShowInterestOverlap bool              `json:"showInterestOverlap"`
	ReadReceipts        bool              `json:"readReceipts"`
	FieldAudiences      map[string]string `json:"fieldAudiences"`
	Version             string            `json:"version"`
	UpdatedAt           time.Time         `json:"updatedAt"`
}

// AdultConnectionsAudience is the starting audience of the "connections" field (who may open the
// followers and following lists) for an adult: whoever actively follows the member, and friends.
// A minor starts with MinorConnectionsAudience instead (see ApplyMinorDefaults).
const AdultConnectionsAudience = "followers"

var Fields = []string{"pronouns", "gender", "age", "counts", "location", "profession", "education", "website", "timezone", "languages", "interests", "vibe", "connections"}

// Genders are the values of the optional profile field gender. An empty value is
// unset or prefer not to say. Gender is a profile field with its own audience, and the
// only way to search by it is the gender filter, which matches only members whose
// audience for it is "everyone".
var Genders = []string{"woman", "man", "nonbinary"}

// DefaultPrivacy is what every new account starts with. Hiyall is open by
// default: every onboarded member is discoverable and their profile is public,
// anyone who is not blocked and is in the same age band may message them
// (minors included, within their band), and a follow takes effect at once.
// The followers and following lists are open to the member's followers and
// friends (field "connections" is "followers"; ApplyMinorDefaults makes it
// "friends" for a minor), and the friends list stays friends-only; the counts on
// a profile (field "counts") are for everyone. Stories, comments and mentions stay friends-only,
// and the activity, last seen and location audiences stay "nobody" (no screen
// exposes them). "friends", "followers", "nobody" and "approval" remain
// available through the API for members who set them.
func DefaultPrivacy() Privacy {
	fields := make(map[string]string)
	for _, name := range Fields {
		fields[name] = "everyone"
	}
	fields["connections"] = AdultConnectionsAudience
	return Privacy{ProfileAudience: "public", MessagesFrom: "everyone", FollowPolicy: "everyone", RequestsFrom: "everyone", StoryAudience: "friends", ActivityAudience: "nobody", OnlineAudience: "everyone", LastSeenAudience: "nobody", LocationAudience: "nobody", CommentsFrom: "friends", MentionsFrom: "friends", Discoverable: true, ShowInterestOverlap: true, FieldAudiences: fields, Version: "1"}
}

func member(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if candidate == value {
			return true
		}
	}
	return false
}

// multiline lists the text fields that may contain line breaks.
var multiline = map[string]bool{"bio": true, "quote": true}

func validateString(name string, raw json.RawMessage, min, max int) (string, error) {
	if string(raw) == "null" {
		return "", invalid(name, "must be text")
	}
	var value string
	// Only the free-text bio and quote may span lines; every other field is
	// shown on one line, so line breaks there are refused too.
	clean := CleanLine
	if multiline[name] {
		clean = CleanText
	}
	if json.Unmarshal(raw, &value) != nil {
		return "", invalid(name, "must be valid text")
	}
	value = Normalize(value)
	if !clean(value) {
		return "", invalid(name, "must be valid text")
	}
	length := utf8.RuneCountInString(value)
	if length < min || length > max {
		return "", invalid(name, fmt.Sprintf("must be %d–%d characters", min, max))
	}
	return value, nil
}

// ValidateProfilePatch rejects identity/version writes and unsupported media references.
// avatarMediaId must be a photo id or null here; that the photo is the caller's own, ready and
// unused is decided in the store, inside the update's transaction. coverMediaId is not
// enabled yet, so only null passes.
func ValidateProfilePatch(patch map[string]json.RawMessage) error {
	if len(patch) == 0 {
		return invalid("profile", "at least one field is required")
	}
	limits := map[string][2]int{"username": {3, 30}, "displayName": {1, 80}, "bio": {0, 300}, "headline": {0, 100}, "quote": {0, 160}, "currentVibe": {0, 80}, "profileAccent": {1, 12}, "profilePattern": {1, 12}, "avatarFrame": {1, 12}, "pronouns": {0, 40}, "region": {0, 100}, "city": {0, 100}, "timezone": {1, 100}, "profession": {0, 100}, "education": {0, 150}, "locale": {2, 35}, "profileAudience": {1, 20}, "gender": {0, 12}}
	for name, raw := range patch {
		if bound, ok := limits[name]; ok {
			value, err := validateString(name, raw, bound[0], bound[1])
			if err != nil {
				return err
			}
			// The stored value is the normalised one (NFC), not the text as typed.
			normalised, _ := json.Marshal(value)
			patch[name] = normalised
			switch name {
			case "profileAccent":
				if !member(value, "lime", "violet", "cyan") {
					return invalid(name, "choose a supported accent")
				}
			case "profilePattern":
				if !member(value, "glow", "orbit", "plain") {
					return invalid(name, "choose a supported background")
				}
			case "avatarFrame":
				if !member(value, "minimal", "orbit") {
					return invalid(name, "choose a supported frame")
				}
			case "username":
				if !handlePattern.MatchString(value) {
					return invalid(name, "use lowercase letters, numbers or underscores")
				}
			case "locale":
				if !localePattern.MatchString(value) {
					return invalid(name, "invalid language tag")
				}
			case "profileAudience":
				if !member(value, "public", "friends", "followers", "private") {
					return invalid(name, "invalid audience")
				}
			case "gender":
				if value != "" && !member(value, Genders...) {
					return invalid(name, "choose woman, man, nonbinary or leave it empty")
				}
			case "timezone":
				// "Local" would mean the server's own zone, not a place.
				if _, err := time.LoadLocation(value); err != nil || value == "Local" {
					return invalid(name, "invalid IANA time zone")
				}
			}
			continue
		}
		switch name {
		case "country":
			if string(raw) == "null" {
				continue
			}
			value, err := validateString(name, raw, 2, 2)
			if err != nil {
				return err
			}
			if !countryPattern.MatchString(value) {
				return invalid(name, "use a two-letter uppercase country code")
			}
		case "websiteUrl":
			if string(raw) == "null" {
				continue
			}
			value, err := validateString(name, raw, 1, 2048)
			if err != nil {
				return err
			}
			u, err := url.Parse(value)
			if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
				return invalid(name, "use an HTTPS URL without embedded credentials")
			}
		case "avatarMediaId":
			var id *string
			if json.Unmarshal(raw, &id) != nil || (id != nil && !IsID(*id)) {
				return invalid(name, "must be a profile photo id or null")
			}
		case "coverMediaId":
			if string(raw) != "null" {
				return invalid(name, "media uploads are not enabled yet")
			}
		case "languages":
			var values Languages
			if string(raw) == "null" || json.Unmarshal(raw, &values) != nil || len(values) > 9 {
				return invalid(name, "select up to nine languages")
			}
			seen := map[string]bool{}
			for _, value := range values {
				key := strings.ToLower(value.Code)
				if len(value.Code) > 35 || !localePattern.MatchString(value.Code) || seen[key] || !member(value.Level, "", "basic", "conversational", "fluent", "native") {
					return invalid(name, "invalid or duplicate language or proficiency")
				}
				seen[key] = true
			}
		case "interests":
			var values []string
			if string(raw) == "null" || json.Unmarshal(raw, &values) != nil || len(values) > 10 {
				return invalid(name, "choose up to ten interests")
			}
			seen := map[string]bool{}
			for i, value := range values {
				value = Normalize(value)
				values[i] = value
				key := strings.ToLower(value)
				if strings.TrimSpace(value) != value || value == "" || !CleanLine(value) || utf8.RuneCountInString(value) > 40 || seen[key] {
					return invalid(name, "use unique interests of 1–40 characters")
				}
				seen[key] = true
			}
			normalised, _ := json.Marshal(values)
			patch[name] = normalised
		default:
			return invalid(name, "field is not editable")
		}
	}
	return nil
}

func ValidatePrivacyPatch(patch map[string]json.RawMessage) error {
	if len(patch) == 0 {
		return invalid("privacy", "at least one field is required")
	}
	access := []string{"everyone", "friends", "followers", "nobody"}
	for name, raw := range patch {
		switch name {
		case "profileAudience", "storyAudience":
			value, err := validateString(name, raw, 1, 20)
			if err != nil {
				return err
			}
			if !member(value, "public", "friends", "followers", "private") {
				return invalid(name, "invalid audience")
			}
		case "followPolicy":
			value, err := validateString(name, raw, 1, 20)
			if err != nil {
				return err
			}
			if !member(value, "everyone", "approval", "nobody") {
				return invalid(name, "invalid follow policy")
			}
		case "discoverable", "showInterestOverlap", "readReceipts":
			var value bool
			if string(raw) == "null" || json.Unmarshal(raw, &value) != nil {
				return invalid(name, "must be true or false")
			}
		case "fieldAudiences":
			var values map[string]string
			if string(raw) == "null" || json.Unmarshal(raw, &values) != nil || len(values) == 0 {
				return invalid(name, "choose at least one field audience")
			}
			for key, value := range values {
				if !member(key, Fields...) || !member(value, access...) {
					return invalid(name, "invalid field or audience")
				}
			}
		case "messagesFrom", "requestsFrom", "activityAudience", "onlineAudience", "lastSeenAudience", "locationAudience", "commentsFrom", "mentionsFrom":
			value, err := validateString(name, raw, 1, 20)
			if err != nil {
				return err
			}
			if !member(value, access...) {
				return invalid(name, "invalid audience")
			}
		default:
			return invalid(name, "field is not editable")
		}
	}
	return nil
}
