package domain

import (
	"bytes"
	"encoding/json"
)

// Language is one language of a profile and how well the member speaks it: Level is LanguageLevelMin (just
// starting) to LanguageLevelMax (native). Display names and level names belong to the app.
type Language struct {
	Code  string `json:"code"`
	Level int    `json:"level"`
}

// Languages reads what profiles stored before levels were numbers: bare tags and the words basic,
// conversational, fluent and native, and an entry without a level. Every entry comes out with a numeric level
// (LanguageLevelDefault when none was given); all writes marshal into structured entries.
type Languages []Language

func (languages *Languages) UnmarshalJSON(raw []byte) error {
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return err
	}
	result := make(Languages, 0, len(entries))
	for _, entry := range entries {
		language := Language{Level: LanguageLevelDefault}
		var tag string
		if json.Unmarshal(entry, &tag) == nil && tag != "" {
			language.Code = tag
		} else {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(entry, &fields); err != nil {
				return err
			}
			if level, exists := fields["level"]; exists && bytes.Equal(bytes.TrimSpace(level), []byte("null")) {
				return invalid("languages", "proficiency must be a number")
			}
			for name := range fields {
				if name != "code" && name != "level" {
					return invalid("languages", "unknown language field")
				}
			}
			if err := json.Unmarshal(fields["code"], &language.Code); err != nil {
				return err
			}
			level, err := parseLanguageLevel(fields["level"], true)
			if err != nil {
				// A stored level outside 1..6 cannot be shown; the default is the safe reading.
				level = LanguageLevelDefault
			}
			language.Level = level
		}
		result = append(result, language)
	}
	*languages = result
	return nil
}
