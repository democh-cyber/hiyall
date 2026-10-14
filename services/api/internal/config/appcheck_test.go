package config

import (
	"strings"
	"testing"

	"hiyall/services/api/internal/appcheck"
)

func TestAppCheckSettings(t *testing.T) {
	cases := map[string]struct {
		mode, number string
		want         appcheck.Mode
		err          string // "" = must load
	}{
		"default is off":           {"", "", appcheck.Off, ""},
		"false":                    {"false", "", appcheck.Off, ""},
		"number alone":             {"", "123456789012", appcheck.Off, ""},
		"log needs the number":     {"log", "", "", "FIREBASE_PROJECT_NUMBER"},
		"true needs the number":    {"true", "", "", "FIREBASE_PROJECT_NUMBER"},
		"log":                      {"log", "123456789012", appcheck.Log, ""},
		"enforce":                  {"true", "123456789012", appcheck.Enforce, ""},
		"unknown mode":             {"enforce", "123456789012", "", "APP_CHECK_ENFORCE"},
		"project id, not number":   {"log", "hiyall-prod-1", "", "FIREBASE_PROJECT_NUMBER"},
		"project id with mode off": {"", "hiyall-prod-1", "", "FIREBASE_PROJECT_NUMBER"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			firebaseEnv(t, "hiyall-prod-1")
			t.Setenv("APP_CHECK_ENFORCE", tc.mode)
			t.Setenv("FIREBASE_PROJECT_NUMBER", tc.number)
			c, err := Load()
			switch {
			case tc.err == "" && err != nil:
				t.Fatal(err)
			case tc.err != "" && (err == nil || !strings.Contains(err.Error(), tc.err)):
				t.Fatalf("got %v, want an error naming %s", err, tc.err)
			case tc.err == "" && c.AppCheckMode != tc.want:
				t.Fatalf("mode %q, want %q", c.AppCheckMode, tc.want)
			}
			if err != nil && strings.Contains(err.Error(), tc.number) && tc.number != "" {
				t.Fatalf("the error repeats the value: %v", err)
			}
		})
	}
}
