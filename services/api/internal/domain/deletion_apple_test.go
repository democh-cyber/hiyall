package domain

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseDeletionAcceptsAnOptionalAppleCode(t *testing.T) {
	parse := func(body string) (string, string, error) {
		var m map[string]json.RawMessage
		if err := json.Unmarshal([]byte(body), &m); err != nil {
			t.Fatal(err)
		}
		return ParseDeletion(m)
	}
	if c, a, err := parse(`{"confirmUsername":"@Xan"}`); err != nil || c != "xan" || a != "" {
		t.Fatal(c, a, err)
	}
	if c, a, err := parse(`{"confirmUsername":"xan","appleAuthorizationCode":"c.abc"}`); err != nil || c != "xan" || a != "c.abc" {
		t.Fatal(c, a, err)
	}
	for _, bad := range []string{`{}`, `{"appleAuthorizationCode":"c"}`, `{"confirmUsername":"x","appleAuthorizationCode":""}`, `{"confirmUsername":"x","appleAuthorizationCode":7}`,
		`{"confirmUsername":"x","appleAuthorizationCode":"` + strings.Repeat("a", 2049) + `"}`, `{"confirmUsername":"x","other":1}`} {
		if _, _, err := parse(bad); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}
