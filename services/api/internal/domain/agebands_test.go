package domain

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestAgeBandBoundaries(t *testing.T) {
	if AdultAge != 18 || MinimumAge != 13 {
		t.Fatalf("AdultAge %d MinimumAge %d", AdultAge, MinimumAge)
	}
	day := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 12, 0, 0, 0, time.UTC) }
	now := day(2026, 10, 10)
	for _, tc := range []struct {
		name  string
		birth time.Time
		band  string
	}{
		{"turns 18 today", day(2008, 10, 10), BandAdult},
		{"turns 18 tomorrow", day(2008, 10, 11), BandMinor},
		{"17 years 364 days", day(2008, 10, 11), BandMinor},
		{"turned 18 yesterday", day(2008, 10, 9), BandAdult},
		{"turns 13 today", day(2013, 10, 10), BandMinor},
		{"a child", day(2020, 1, 1), BandMinor},
		{"an adult", day(1990, 5, 5), BandAdult},
		{"born 1900", day(1900, 1, 1), BandAdult},
	} {
		if got := BandAt(tc.birth, now); got != tc.band {
			t.Errorf("%s: %s, want %s", tc.name, got, tc.band)
		}
	}
	// Born on 29 February 2008: 18 on 1 March 2026, a minor on 28 February.
	leap := day(2008, 2, 29)
	if BandAt(leap, day(2026, 2, 28)) != BandMinor || BandAt(leap, day(2026, 3, 1)) != BandAdult {
		t.Fatal("leap-day birthday band change is not on 1 March")
	}
}

func TestMinorProtectionsAreNamedInOnePlace(t *testing.T) {
	if MinorLocationDecimals != 1 || LocationDecimals != 2 {
		t.Fatalf("decimals %d / %d", MinorLocationDecimals, LocationDecimals)
	}
	if got := NearbyBucketsFor(true); len(got) != 4 || got[0] != 10 || got[3] != 100 {
		t.Fatalf("minor buckets %v", got)
	}
	if got := NearbyBucketsFor(false); len(got) != 9 || got[0] != 1 {
		t.Fatalf("adult buckets %v", got)
	}
	// A minor's buckets are a subset of the adult ones, so the SQL needs no new boundaries.
	for _, b := range MinorNearbyBuckets {
		found := false
		for _, a := range NearbyBuckets {
			found = found || a == b
		}
		if !found {
			t.Fatalf("minor bucket %d is not an adult bucket", b)
		}
	}
	if DistanceBucketIn(MinorNearbyBuckets, 0) != 10 || DistanceBucketIn(MinorNearbyBuckets, 10.01) != 25 || DistanceBucketIn(MinorNearbyBuckets, 60) != 100 || DistanceBucketIn(MinorNearbyBuckets, 500) != 100 {
		t.Fatal("minor bucket choice")
	}
	p := DefaultPrivacy()
	if want := DefaultPrivacy().FieldAudiences["connections"]; want != AdultConnectionsAudience || AdultConnectionsAudience != "followers" {
		t.Fatalf("adult connections default %q", want)
	}
	ApplyMinorDefaults(&p)
	if p.OnlineAudience != "nobody" || p.FieldAudiences["location"] != "friends" || p.FieldAudiences["connections"] != "friends" {
		t.Fatalf("minor defaults %+v", p)
	}
	// Nothing else changes: still open and discoverable, messages friends-only, other fields everyone.
	want := DefaultPrivacy()
	if p.ProfileAudience != want.ProfileAudience || !p.Discoverable || p.MessagesFrom != "everyone" || p.RequestsFrom != want.RequestsFrom || p.FollowPolicy != want.FollowPolicy {
		t.Fatalf("minor defaults changed more than they should: %+v", p)
	}
	for field, audience := range p.FieldAudiences {
		if field != "location" && field != "connections" && audience != want.FieldAudiences[field] {
			t.Fatalf("field %s changed to %s", field, audience)
		}
	}
	var empty Privacy
	ApplyMinorDefaults(&empty)
	if empty.FieldAudiences["location"] != "friends" || empty.FieldAudiences["connections"] != "friends" {
		t.Fatal("minor defaults need a map")
	}
}

func TestGenderIsAFieldWithAnAudienceAndAValidatedValue(t *testing.T) {
	found := false
	for _, f := range Fields {
		found = found || f == "gender"
	}
	if !found {
		t.Fatal("gender has no field audience")
	}
	if got := DefaultPrivacy().FieldAudiences["gender"]; got != "everyone" {
		t.Fatalf("default gender audience %q", got)
	}
	patch := func(raw string) map[string]json.RawMessage {
		var m map[string]json.RawMessage
		_ = json.Unmarshal([]byte(raw), &m)
		return m
	}
	for _, ok := range []string{`{"gender":"woman"}`, `{"gender":"man"}`, `{"gender":"nonbinary"}`, `{"gender":""}`} {
		if err := ValidateProfilePatch(patch(ok)); err != nil {
			t.Errorf("rejected %s: %v", ok, err)
		}
	}
	for _, bad := range []string{`{"gender":"female"}`, `{"gender":"Woman"}`, `{"gender":" man"}`, `{"gender":"non-binary"}`, `{"gender":null}`, `{"gender":1}`, `{"gender":["man"]}`, `{"gender":"nonbinaryperson"}`} {
		if ValidateProfilePatch(patch(bad)) == nil {
			t.Errorf("accepted %s", bad)
		}
	}
	// The audience is editable like any other field's, and nothing else about age is.
	for _, ok := range []string{`{"fieldAudiences":{"gender":"friends"}}`, `{"fieldAudiences":{"age":"friends"}}`, `{"fieldAudiences":{"age":"nobody"}}`} {
		if err := ValidatePrivacyPatch(patch(ok)); err != nil {
			t.Fatalf("%s: %v", ok, err)
		}
	}
	if got := DefaultPrivacy().FieldAudiences["age"]; got != "everyone" {
		t.Fatalf("default age audience %q", got)
	}
	for _, bad := range []string{`{"fieldAudiences":{"age":"public"}}`, `{"fieldAudiences":{"birthDate":"everyone"}}`, `{"fieldAudiences":{"birthYear":"everyone"}}`, `{"ageAudience":"everyone"}`} {
		if ValidatePrivacyPatch(patch(bad)) == nil {
			t.Errorf("accepted %s", bad)
		}
	}
	for _, bad := range []string{`{"age":15}`, `{"birthDate":"2010-01-01"}`, `{"birthYear":2010}`, `{"ageBand":"minor"}`} {
		if ValidateProfilePatch(patch(bad)) == nil {
			t.Errorf("a profile accepted %s", bad)
		}
	}
}

func filters(raw string) (PeopleFilters, error) {
	var body map[string]json.RawMessage
	_ = json.Unmarshal([]byte(raw), &body)
	return ParsePeopleFilters(body)
}

func TestAgeAndGenderFilters(t *testing.T) {
	f, err := filters(`{"ageMin":18,"ageMax":24,"gender":"woman","country":"IN"}`)
	if err != nil || f.AgeMin == nil || *f.AgeMin != 18 || f.AgeMax == nil || *f.AgeMax != 24 || f.Gender != "woman" {
		t.Fatalf("%+v (%v)", f, err)
	}
	f, err = filters(`{"ageMin":13}`)
	if err != nil || f.AgeMax != nil || *f.AgeMin != 13 {
		t.Fatalf("%+v (%v)", f, err)
	}
	f, err = filters(`{"ageMax":99,"gender":""}`)
	if err != nil || f.AgeMin != nil || *f.AgeMax != 99 || f.Gender != "" {
		t.Fatalf("%+v (%v)", f, err)
	}
	if f, err = filters(`{"ageMin":30,"ageMax":30}`); err != nil || *f.AgeMin != 30 {
		t.Fatalf("equal ends %+v (%v)", f, err)
	}
	for _, bad := range []string{
		`{"ageMin":12}`, `{"ageMin":100}`, `{"ageMax":12}`, `{"ageMax":100}`, `{"ageMin":0}`, `{"ageMin":-13}`,
		`{"ageMin":"20"}`, `{"ageMin":20.5}`, `{"ageMin":20.0}`, `{"ageMin":2e1}`, `{"ageMin":null}`, `{"ageMax":true}`, `{"ageMin":[20]}`,
		`{"ageMin":40,"ageMax":30}`, `{"gender":"male"}`, `{"gender":"Man"}`, `{"gender":" woman"}`, `{"gender":null}`, `{"gender":1}`, `{"gender":["man"]}`, `{"age":20}`,
	} {
		_, err := filters(bad)
		var validation *ValidationError
		if err == nil || !errors.As(err, &validation) {
			t.Errorf("%s: %v", bad, err)
			continue
		}
		// A refusal never repeats what was sent beyond the field name.
		if strings.Contains(validation.Message, "30") || strings.Contains(validation.Message, "20") {
			t.Errorf("%s: message repeats the input: %q", bad, validation.Message)
		}
	}
	// The filters are part of what a cursor is bound to: marshalled filters differ when they differ, and the
	// zero filters marshal as they did before the age and gender filters existed.
	plain, _ := filters(`{}`)
	aged, _ := filters(`{"ageMin":20}`)
	gendered, _ := filters(`{"gender":"man"}`)
	other, _ := filters(`{"ageMin":21}`)
	a, _ := json.Marshal(plain)
	b, _ := json.Marshal(aged)
	c, _ := json.Marshal(gendered)
	d, _ := json.Marshal(other)
	if string(a) == string(b) || string(a) == string(c) || string(b) == string(d) || string(b) == string(c) {
		t.Fatalf("filters do not distinguish: %s %s %s %s", a, b, c, d)
	}
	if strings.Contains(string(a), "ageM") || strings.Contains(string(a), "gender") {
		t.Fatalf("unset filters appear in the hash input: %s", a)
	}
	// Nearby takes the same filters through ParseNearbyRequest.
	req, err := ParseNearbyRequest(locationBody(`{"radiusKm":10,"ageMin":20,"ageMax":30,"gender":"nonbinary"}`))
	if err != nil || req.RadiusKm != 10 || *req.Filters.AgeMin != 20 || *req.Filters.AgeMax != 30 || req.Filters.Gender != "nonbinary" {
		t.Fatalf("nearby %+v (%v)", req, err)
	}
	if _, err = ParseNearbyRequest(locationBody(`{"ageMin":12}`)); err == nil {
		t.Fatal("nearby accepted an age below 13")
	}
}

func TestOnboardingReturnsTheBirthDateAndStillRefusesUnderThirteen(t *testing.T) {
	now := time.Date(2026, 10, 10, 8, 0, 0, 0, time.UTC)
	birth, err := ParseOnboardingCompletion(completion("2010-03-14", TermsVersion), now)
	if err != nil || birth.Format(time.DateOnly) != "2010-03-14" {
		t.Fatalf("%v (%v)", birth, err)
	}
	if got, err := ParseOnboardingCompletion(completion("2013-10-11", TermsVersion), now); !errors.Is(err, ErrAgeRequirement) || !got.IsZero() {
		t.Fatalf("under 13: %v %v", got, err)
	}
	if got, err := ParseOnboardingCompletion(completion("2013-10-10", TermsVersion), now); err != nil || got.IsZero() {
		t.Fatalf("exactly 13: %v %v", got, err)
	}
	if BandAt(birth, now) != BandMinor {
		t.Fatal("a 16 year old is not a minor")
	}
}
