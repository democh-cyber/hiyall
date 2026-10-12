package domain

import (
	"encoding/json"
	"testing"
)

func TestParsePeopleFiltersOnlineIsAStrictBoolean(t *testing.T) {
	parse := func(raw string) (PeopleFilters, error) {
		return ParsePeopleFilters(map[string]json.RawMessage{"online": json.RawMessage(raw)})
	}
	if f, err := parse("true"); err != nil || !f.Online {
		t.Fatalf("true: %v %v", f.Online, err)
	}
	if f, err := parse("false"); err != nil || f.Online {
		t.Fatalf("false: %v %v", f.Online, err)
	}
	for _, bad := range []string{`"true"`, `1`, `0`, `null`, `[]`, `{}`, `"yes"`} {
		if _, err := parse(bad); err == nil {
			t.Fatalf("%s was accepted", bad)
		}
	}
	// An unset or false filter leaves the serialised filter (and so the cursor hash) unchanged.
	if data, _ := json.Marshal(PeopleFilters{}); string(data) != `{"interests":null,"languages":null,"country":"","vibe":""}` {
		t.Fatalf("filters json changed: %s", data)
	}
}
