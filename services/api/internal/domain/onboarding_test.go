package domain

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func completion(birth, terms string) map[string]json.RawMessage {
	body := map[string]json.RawMessage{}
	if birth != "" {
		body["birthDate"], _ = json.Marshal(birth)
	}
	if terms != "" {
		body["termsVersion"], _ = json.Marshal(terms)
	}
	return body
}

func TestOnboardingCompletionValidation(t *testing.T) {
	now := time.Date(2026, 10, 10, 23, 59, 0, 0, time.UTC)
	for _, tc := range []struct {
		name  string
		body  map[string]json.RawMessage
		want  error
		field string
	}{
		{"adult", completion("1990-04-12", TermsVersion), nil, ""},
		{"seventeen", completion("2009-06-01", TermsVersion), nil, ""},
		{"turns 18 today", completion("2008-10-10", TermsVersion), nil, ""},
		{"turns 13 today", completion("2013-10-10", TermsVersion), nil, ""},
		{"turns 13 tomorrow", completion("2013-10-11", TermsVersion), ErrAgeRequirement, ""},
		{"twelve", completion("2013-12-31", TermsVersion), ErrAgeRequirement, ""},
		{"minor", completion("2015-01-01", TermsVersion), ErrAgeRequirement, ""},
		{"born today", completion("2026-10-10", TermsVersion), ErrAgeRequirement, ""},
		{"oldest accepted year", completion("1900-01-01", TermsVersion), nil, ""},
		{"before 1900", completion("1899-12-31", TermsVersion), nil, "birthDate"},
		{"future", completion("2026-10-11", TermsVersion), nil, "birthDate"},
		{"far future", completion("2999-01-01", TermsVersion), nil, "birthDate"},
		{"impossible date", completion("2000-02-30", TermsVersion), nil, "birthDate"},
		{"month 13", completion("2000-13-01", TermsVersion), nil, "birthDate"},
		{"slashes", completion("01/02/2000", TermsVersion), nil, "birthDate"},
		{"unpadded", completion("2000-1-02", TermsVersion), nil, "birthDate"},
		{"timestamp", completion("2000-01-02T00:00:00Z", TermsVersion), nil, "birthDate"},
		{"padded with spaces", completion(" 2000-01-0", TermsVersion), nil, "birthDate"},
		{"empty", completion("", TermsVersion), nil, "birthDate"},
		{"wrong terms", completion("1990-04-12", "2025-01-01"), nil, "termsVersion"},
		{"missing terms", completion("1990-04-12", ""), nil, "termsVersion"},
		{"terms with other case", completion("1990-04-12", strings.ToUpper(TermsVersion)+"x"), nil, "termsVersion"},
		{"unknown field", map[string]json.RawMessage{"birthDate": json.RawMessage(`"1990-04-12"`), "termsVersion": json.RawMessage(`"` + TermsVersion + `"`), "email": json.RawMessage(`"a@b.c"`)}, nil, "email"},
		{"date as number", map[string]json.RawMessage{"birthDate": json.RawMessage(`19900412`), "termsVersion": json.RawMessage(`"` + TermsVersion + `"`)}, nil, "birthDate"},
		{"date null", map[string]json.RawMessage{"birthDate": json.RawMessage(`null`), "termsVersion": json.RawMessage(`"` + TermsVersion + `"`)}, nil, "birthDate"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateOnboardingCompletion(tc.body, now)
			var validation *ValidationError
			switch {
			case tc.field != "":
				if !errors.As(err, &validation) || validation.Field != tc.field {
					t.Fatalf("got %v, want validation error on %s", err, tc.field)
				}
			case tc.want == nil && err != nil, tc.want != nil && !errors.Is(err, tc.want):
				t.Fatalf("got %v, want %v", err, tc.want)
			}
			// Errors must never repeat the birth date.
			var supplied string
			if json.Unmarshal(tc.body["birthDate"], &supplied) == nil && len(supplied) > 4 && err != nil && strings.Contains(err.Error(), supplied) {
				t.Fatalf("error repeats input: %v", err)
			}
		})
	}
}

// The refusal copy follows MinimumAge, which is the legal floor of the identity providers.
func TestMinimumAgeIsThirteenAndTheMessageFollowsIt(t *testing.T) {
	if MinimumAge != 13 {
		t.Fatalf("MinimumAge %d", MinimumAge)
	}
	if ErrAgeRequirement.Status != 403 || ErrAgeRequirement.Code != "AGE_REQUIREMENT_NOT_MET" || ErrAgeRequirement.Message != "Hiyall is for people 13 and over." {
		t.Fatalf("age refusal %+v", ErrAgeRequirement)
	}
	// Someone born on 29 February is 13 on 1 March of a common year, and not the day before.
	now := time.Date(2025, 2, 28, 12, 0, 0, 0, time.UTC)
	if err := ValidateOnboardingCompletion(completion("2012-02-29", TermsVersion), now); !errors.Is(err, ErrAgeRequirement) {
		t.Fatalf("leap-day 12-year-old on 28 February: %v", err)
	}
	if err := ValidateOnboardingCompletion(completion("2012-02-29", TermsVersion), now.AddDate(0, 0, 1)); err != nil {
		t.Fatalf("leap-day 13-year-old on 1 March: %v", err)
	}
}

func TestAgeAtUsesCalendarDates(t *testing.T) {
	day := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }
	for _, tc := range []struct {
		birth, now time.Time
		age        int
	}{
		{day(2000, 1, 1), day(2018, 1, 1), 18},
		{day(2000, 1, 2), day(2018, 1, 1), 17},
		{day(2000, 12, 31), day(2018, 12, 30), 17},
		{day(2000, 12, 31), day(2018, 12, 31), 18},
		{day(2008, 2, 29), day(2026, 2, 28), 17},
		{day(2008, 2, 29), day(2026, 3, 1), 18},
		{day(2008, 2, 29), day(2028, 2, 29), 20},
	} {
		if got := AgeAt(tc.birth, tc.now); got != tc.age {
			t.Fatalf("born %s on %s: age %d, want %d", tc.birth.Format(time.DateOnly), tc.now.Format(time.DateOnly), got, tc.age)
		}
	}
}

func TestPlaceholderIdentity(t *testing.T) {
	id := "019a4000-0000-7000-8000-0000000000a1"
	if got := PlaceholderUsername(id); got != "member_0000000000a1" || !IsPlaceholderUsername(got) || ValidateUsername(got) != nil {
		t.Fatalf("placeholder %q", got)
	}
	for _, name := range []string{"member_alice", "member_0000000000A1", "member_0000000000a", "member_0000000000a12", "amember_0000000000a1", "niko"} {
		if IsPlaceholderUsername(name) {
			t.Fatalf("%q is not a generated placeholder", name)
		}
	}
	for _, tc := range []struct {
		username, name string
		placeholder    bool
	}{
		{"niko", "Niko", false},
		{"member_0000000000a1", "Niko", true},
		{"niko", "Hiyall member", true},
		{"niko", " hiyall MEMBER ", true},
		{"niko", "", true},
		{"niko", "   ", true},
		{"member_alice", "Alice", false},
	} {
		if got := ProfileIsPlaceholder(tc.username, tc.name); got != tc.placeholder {
			t.Fatalf("%q/%q placeholder=%v, want %v", tc.username, tc.name, got, tc.placeholder)
		}
	}
	for _, bad := range []string{"", "ab", "UPPER", "has-dash", strings.Repeat("a", 31), "émile"} {
		if ValidateUsername(bad) == nil {
			t.Fatalf("accepted username %q", bad)
		}
	}
}
