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

func TestParseDeletionBodyAcceptsAppleCodeUnavailableButNotWithACode(t *testing.T) {
	parse := func(body string) (DeletionRequest, error) {
		var m map[string]json.RawMessage
		if err := json.Unmarshal([]byte(body), &m); err != nil {
			t.Fatal(err)
		}
		return ParseDeletionBody(m)
	}
	if r, err := parse(`{"confirmUsername":"@Xan","appleCodeUnavailable":true}`); err != nil || r.Confirm != "xan" || !r.AppleCodeUnavailable || r.AppleCode != "" {
		t.Fatal(r, err)
	}
	if r, err := parse(`{"confirmUsername":"xan","appleCodeUnavailable":false}`); err != nil || r.AppleCodeUnavailable {
		t.Fatal(r, err)
	}
	for _, bad := range []string{`{"confirmUsername":"x","appleCodeUnavailable":"yes"}`, `{"confirmUsername":"x","appleCodeUnavailable":1}`,
		`{"confirmUsername":"x","appleCodeUnavailable":true,"appleAuthorizationCode":"c.abc"}`, `{"appleCodeUnavailable":true}`, `{"confirmUsername":"x","appleCodeUnavailable":true,"other":1}`} {
		if _, err := parse(bad); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}
