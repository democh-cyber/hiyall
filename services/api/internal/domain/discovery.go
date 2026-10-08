package domain

import (
	"encoding/json"
	"strings"
	"unicode/utf8"
)

// Search consumes only explicitly public profile fields. Within a collection,
// any selected value may match; different filter dimensions combine with AND.
type PeopleFilters struct {
	Interests []string `json:"interests"`
	Languages []string `json:"languages"`
	Country   string   `json:"country"`
	Vibe      string   `json:"vibe"`
	Cursor    string   `json:"cursor,omitempty"`
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
				if v == "" || !utf8.ValidString(v) || utf8.RuneCountInString(v) > 40 || (key == "languages" && (len(v) > 35 || !localePattern.MatchString(v))) {
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
		case "country", "vibe", "cursor":
			var v string
			if json.Unmarshal(raw, &v) != nil || string(raw) == "null" || !utf8.ValidString(v) {
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
	return f, nil
}
