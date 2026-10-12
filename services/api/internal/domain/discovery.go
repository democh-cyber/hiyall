package domain

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Search consumes only explicitly public profile fields. Within a collection,
// any selected value may match; different filter dimensions combine with AND.
//
// AgeMin and AgeMax are an inclusive range over the member's private age (either
// may be absent); a member whose age is unknown never matches an age filter. Gender
// is one of Genders, empty for any, and matches only members whose gender audience
// is "everyone". Neither age nor gender is ever returned in a result. These filters
// are also the shared filters of Nearby, and are part of the cursor hash.
type PeopleFilters struct {
	Interests []string `json:"interests"`
	Languages []string `json:"languages"`
	Country   string   `json:"country"`
	Vibe      string   `json:"vibe"`
	AgeMin    *int     `json:"ageMin,omitempty"`
	AgeMax    *int     `json:"ageMax,omitempty"`
	Gender    string   `json:"gender,omitempty"`
	// Online narrows the list to members who show their presence to the viewer and have been
	// active within PresenceOnlineWindow (see Store.SearchPeople). It is part of the cursor hash.
	Online bool   `json:"online,omitempty"`
	Cursor string `json:"cursor,omitempty"`
}

// MaxFilterAge is the top of the age filter range; the bottom is MinimumAge.
const MaxFilterAge = 99

// parseFilterAge reads a JSON integer from MinimumAge to MaxFilterAge. Only a plain
// integer literal is accepted: no string, null, fraction, exponent or sign.
func parseFilterAge(key string, raw json.RawMessage) (*int, error) {
	n, err := strconv.Atoi(string(raw))
	if err != nil || strconv.Itoa(n) != string(raw) || n < MinimumAge || n > MaxFilterAge {
		return nil, invalid(key, fmt.Sprintf("must be a whole number from %d to %d", MinimumAge, MaxFilterAge))
	}
	return &n, nil
}

func ParsePeopleFilters(body map[string]json.RawMessage) (PeopleFilters, error) {
	f := PeopleFilters{Interests: []string{}, Languages: []string{}}
	for key, raw := range body {
		switch key {
		case "interests", "languages":
			var values []string
			if string(raw) == "null" || json.Unmarshal(raw, &values) != nil || len(values) > 10 {
				return f, invalid(key, "choose at most 10 values")
			}
			seen := map[string]bool{}
			for _, v := range values {
				v = strings.TrimSpace(v)
				if key == "languages" {
					v = strings.ToLower(v)
				}
				if v == "" || !CleanLine(v) || utf8.RuneCountInString(v) > 40 || (key == "languages" && (len(v) > 35 || !localePattern.MatchString(v))) {
					return f, invalid(key, "invalid selection")
				}
				folded := strings.ToLower(v)
				if seen[folded] {
					return f, invalid(key, "duplicate selection")
				}
				seen[folded] = true
				if key == "interests" {
					f.Interests = append(f.Interests, v)
				} else {
					f.Languages = append(f.Languages, v)
				}
			}
		case "ageMin", "ageMax":
			age, err := parseFilterAge(key, raw)
			if err != nil {
				return f, err
			}
			if key == "ageMin" {
				f.AgeMin = age
			} else {
				f.AgeMax = age
			}
		case "gender":
			var v string
			if string(raw) == "null" || json.Unmarshal(raw, &v) != nil || (v != "" && !member(v, Genders...)) {
				return f, invalid(key, "choose woman, man or nonbinary, or leave it empty for any")
			}
			f.Gender = v
		case "online":
			// Only a JSON boolean: a string, number or null is refused.
			var v bool
			if string(raw) != "true" && string(raw) != "false" {
				return f, invalid(key, "must be true or false")
			}
			_ = json.Unmarshal(raw, &v)
			f.Online = v
		case "country", "vibe", "cursor":
			var v string
			if json.Unmarshal(raw, &v) != nil || string(raw) == "null" || !CleanLine(v) {
				return f, invalid(key, "must be text")
			}
			switch key {
			case "country":
				if v != "" && !countryPattern.MatchString(v) {
					return f, invalid(key, "choose a country code")
				}
				f.Country = v
			case "vibe":
				v = strings.TrimSpace(v)
				if utf8.RuneCountInString(v) > 80 {
					return f, invalid(key, "must be at most 80 characters")
				}
				f.Vibe = v
			case "cursor":
				if len(v) > 2048 {
					return f, invalid(key, "invalid cursor")
				}
				f.Cursor = v
			}
		default:
			return f, invalid(key, "unsupported search field")
		}
	}
	if f.AgeMin != nil && f.AgeMax != nil && *f.AgeMin > *f.AgeMax {
		return f, invalid("ageMin", "must not be above ageMax")
	}
	return f, nil
}
