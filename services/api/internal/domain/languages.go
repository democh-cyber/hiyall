package domain

import (
	"bytes"
	"encoding/json"
)

type Language struct {
	Code  string `json:"code"`
	Level string `json:"level,omitempty"`
}

// Languages reads legacy tag arrays without inventing proficiency. All writes
// marshal into structured entries; display names belong to localization.
type Languages []Language

func (languages *Languages) UnmarshalJSON(raw []byte) error {
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return err
	}
	result := make(Languages, 0, len(entries))
	for _, entry := range entries {
		var language Language
		var tag string
		if json.Unmarshal(entry, &tag) == nil && tag != "" {
			language.Code = tag
		} else {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(entry, &fields); err != nil {
				return err
			}
			if level, exists := fields["level"]; exists && bytes.Equal(bytes.TrimSpace(level), []byte("null")) {
				return invalid("languages", "proficiency must be text")
			}
			decoder := json.NewDecoder(bytes.NewReader(entry))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&language); err != nil {
				return err
			}
		}
		result = append(result, language)
	}
	*languages = result
	return nil
}
