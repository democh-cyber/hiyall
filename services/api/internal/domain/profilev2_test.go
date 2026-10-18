package domain

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func patchOf(t *testing.T, input string) map[string]json.RawMessage {
	t.Helper()
	var patch map[string]json.RawMessage
	if err := json.Unmarshal([]byte(input), &patch); err != nil {
		t.Fatal(err)
	}
	return patch
}

func TestLanguageLevelsAreNumbersAndLegacyWordsMap(t *testing.T) {
	patch := patchOf(t, `{"languages":[{"code":"en","level":6},{"code":"ko","level":"basic"},{"code":"hi","level":"fluent"},{"code":"es"},"fr"]}`)
	if err := ValidateProfilePatch(patch); err != nil {
		t.Fatal(err)
	}
	if got := string(patch["languages"]); got != `[{"code":"en","level":6},{"code":"ko","level":2},{"code":"hi","level":4},{"code":"es","level":3},{"code":"fr","level":3}]` {
		t.Fatalf("canonical languages: %s", got)
	}
	for _, bad := range []string{`{"languages":[{"code":"en","level":0}]}`, `{"languages":[{"code":"en","level":7}]}`, `{"languages":[{"code":"en","level":2.5}]}`, `{"languages":[{"code":"en","level":"3"}]}`, `{"languages":[{"code":"en","level":true}]}`, `{"languages":[{"code":"en"},{"code":"EN"}]}`} {
		if ValidateProfilePatch(patchOf(t, bad)) == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestLanguagesMaxComesFromTheEntitlement(t *testing.T) {
	five := `{"languages":[{"code":"en"},{"code":"hi"},{"code":"ko"},{"code":"ja"},{"code":"es"}]}`
	six := `{"languages":[{"code":"en"},{"code":"hi"},{"code":"ko"},{"code":"ja"},{"code":"es"},{"code":"fr"}]}`
	if err := ValidateProfilePatch(patchOf(t, five)); err != nil {
		t.Fatal(err)
	}
	if ValidateProfilePatch(patchOf(t, six)) == nil {
		t.Fatal("six languages accepted under the free limit of five")
	}
	e := Free()
	e.LanguagesMax = 9
	if err := ValidateProfilePatchFor(patchOf(t, six), e); err != nil {
		t.Fatalf("a raised limit was not honoured: %v", err)
	}
	if Free().LanguagesMax != 5 || Free().InterestsMax != 10 || Free().PersonalityTagsMax != 5 || Free().ProfilePhotosMax != 8 {
		t.Fatalf("free limits %+v", Free())
	}
}

func TestPersonalityTags(t *testing.T) {
	if len(PersonalityTags) != 19 {
		t.Fatalf("%d tags, want 19", len(PersonalityTags))
	}
	seen := map[string]bool{}
	for _, tag := range PersonalityTags {
		if seen[tag] || !handlePattern.MatchString(tag) {
			t.Fatalf("bad or duplicate tag %q", tag)
		}
		seen[tag] = true
	}
	ok := []string{`{"personalityTags":[]}`, `{"personalityTags":["curious","foodie","maker"]}`, `{"personalityTags":["curious","foodie","maker","playful","sporty"]}`}
	for _, input := range ok {
		if err := ValidateProfilePatch(patchOf(t, input)); err != nil {
			t.Errorf("%s: %v", input, err)
		}
	}
	bad := []string{`{"personalityTags":["curious"]}`, `{"personalityTags":["curious","foodie"]}`, `{"personalityTags":["curious","foodie","maker","playful","sporty","chatty"]}`, `{"personalityTags":["curious","curious","foodie"]}`, `{"personalityTags":["curious","foodie","hacker"]}`, `{"personalityTags":null}`, `{"personalityTags":"curious"}`}
	for _, input := range bad {
		if ValidateProfilePatch(patchOf(t, input)) == nil {
			t.Errorf("accepted %s", input)
		}
	}
}

func TestInterestsLimitIsTen(t *testing.T) {
	var eleven []string
	for i := 0; i < 11; i++ {
		eleven = append(eleven, string(rune('a'+i))+"x")
	}
	raw, _ := json.Marshal(map[string]any{"interests": eleven[:10]})
	var patch map[string]json.RawMessage
	_ = json.Unmarshal(raw, &patch)
	if err := ValidateProfilePatch(patch); err != nil {
		t.Fatal(err)
	}
	raw, _ = json.Marshal(map[string]any{"interests": eleven})
	_ = json.Unmarshal(raw, &patch)
	if ValidateProfilePatch(patch) == nil {
		t.Fatal("eleven interests accepted")
	}
}

func TestAboutMeAndHometown(t *testing.T) {
	long := `"` + strings.Repeat("a", AboutMeMax+1) + `"`
	if ValidateProfilePatch(patchOf(t, `{"aboutMe":`+long+`}`)) == nil {
		t.Fatal("about me over the limit accepted")
	}
	if err := ValidateProfilePatch(patchOf(t, `{"aboutMe":"I like slow mornings and loud music.","hometown":"Pune"}`)); err != nil {
		t.Fatal(err)
	}
	if err := ValidateProfilePatch(patchOf(t, `{"aboutMe":"","hometown":""}`)); err != nil {
		t.Fatalf("clearing the fields: %v", err)
	}
	for _, bad := range []string{`{"aboutMe":"two\nlines"}`, `{"hometown":"12 Baker Street"}`, `{"hometown":"Flat 4, Green Park"}`, `{"hometown":"Block B, Sector 21"}`, `{"hometown":"home #4"}`, `{"hometown":"me@example.test"}`, `{"hometown":"` + strings.Repeat("a", HometownMax+1) + `"}`, `{"hometown":null}`} {
		if ValidateProfilePatch(patchOf(t, bad)) == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestHometownForMinorsIsShorterAndNeverAnAddress(t *testing.T) {
	if err := ValidateHometown("Lisbon", true); err != nil {
		t.Fatal(err)
	}
	if ValidateHometown(strings.Repeat("a", MinorHometownMax+1), true) == nil || ValidateHometown(strings.Repeat("a", MinorHometownMax+1), false) != nil {
		t.Fatal("the minor limit is 40 characters and the adult limit is not")
	}
	for _, input := range []string{"221B Baker St", "Plot 12", "5th Avenue", "near 1234", "Main Road", "PO Box", "p.o. box"} {
		if ValidateHometown(input, true) == nil && ValidateHometown(input, false) == nil {
			t.Errorf("accepted %q", input)
		}
	}
	err := ValidateHometown("12 Baker Street", true)
	if err == nil || strings.Contains(err.Error(), "Baker") {
		t.Fatalf("the message must not repeat the input: %v", err)
	}
}

func TestPrivacyPatchV2Fields(t *testing.T) {
	for _, ok := range []string{`{"showLocalTime":false}`, `{"showDistance":true}`, `{"visitorsVisibleToOthers":true}`, `{"showBirthday":true}`, `{"fieldAudiences":{"aboutMe":"friends","hometown":"nobody","personality":"everyone","birthday":"friends"}}`} {
		if err := ValidatePrivacyPatch(patchOf(t, ok)); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{`{"showLocalTime":null}`, `{"showDistance":"yes"}`, `{"showBirthday":1}`, `{"fieldAudiences":{"dob":"everyone"}}`} {
		if ValidatePrivacyPatch(patchOf(t, bad)) == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestMinorPrivacyV2(t *testing.T) {
	for _, bad := range []string{`{"visitorsVisibleToOthers":true}`, `{"showBirthday":true}`, `{"fieldAudiences":{"birthday":"friends"}}`, `{"fieldAudiences":{"aboutMe":"followers"}}`, `{"fieldAudiences":{"aboutMe":"everyone"}}`, `{"fieldAudiences":{"hometown":"followers"}}`, `{"fieldAudiences":{"hometown":"everyone"}}`} {
		if err := ValidateMinorPrivacyPatch(patchOf(t, bad)); err != ErrMinorSettingLocked {
			t.Errorf("%s: %v, want ErrMinorSettingLocked", bad, err)
		}
	}
	for _, ok := range []string{`{"visitorsVisibleToOthers":false}`, `{"showBirthday":false}`, `{"fieldAudiences":{"aboutMe":"friends","hometown":"friends"}}`, `{"fieldAudiences":{"hometown":"nobody","aboutMe":"nobody","birthday":"nobody"}}`, `{"showLocalTime":true,"showDistance":true}`} {
		if err := ValidateMinorPrivacyPatch(patchOf(t, ok)); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
}

func TestDefaultsForAdultsAndMinors(t *testing.T) {
	adult := DefaultPrivacy()
	if !adult.ShowLocalTime || !adult.ShowDistance || adult.VisitorsVisibleToOthers || adult.ShowBirthday {
		t.Fatalf("adult defaults %+v", adult)
	}
	if adult.FieldAudiences["aboutMe"] != "followers" || adult.FieldAudiences["hometown"] != "followers" || adult.FieldAudiences["birthday"] != "friends" || adult.FieldAudiences["personality"] != "everyone" {
		t.Fatalf("adult field audiences %v", adult.FieldAudiences)
	}
}

func TestPeopleFiltersV2(t *testing.T) {
	f, err := ParsePeopleFilters(patchOf(t, `{"languages":["ko","EN"],"languageMinLevel":4,"personalityTags":["curious","maker"],"sameCountry":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if f.LanguageMinLevel != 4 || len(f.PersonalityTags) != 2 || !f.SameCountry || f.Languages[1] != "en" {
		t.Fatalf("%+v", f)
	}
	for _, bad := range []string{`{"languageMinLevel":3}`, `{"languages":["en"],"languageMinLevel":7}`, `{"languages":["en"],"languageMinLevel":"4"}`, `{"personalityTags":["nope"]}`, `{"personalityTags":["curious","curious"]}`, `{"sameCountry":"yes"}`, `{"sameCountry":true,"country":"IN"}`} {
		if _, err := ParsePeopleFilters(patchOf(t, bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
	// The cursor hash covers every new filter, so changing one invalidates the cursor.
	a, _ := json.Marshal(PeopleFilters{})
	b, _ := json.Marshal(PeopleFilters{PersonalityTags: []string{"maker"}})
	c, _ := json.Marshal(PeopleFilters{SameCountry: true})
	d, _ := json.Marshal(PeopleFilters{LanguageMinLevel: 3})
	if string(a) == string(b) || string(a) == string(c) || string(a) == string(d) {
		t.Fatal("a new filter does not change the encoded filters")
	}
}

func TestPossibleRequest(t *testing.T) {
	r, err := ParsePossibleRequest(patchOf(t, `{}`))
	if err != nil || r.Limit != PossibleMatchesPerPage || r.ExcludeFollowing {
		t.Fatalf("%+v %v", r, err)
	}
	r, err = ParsePossibleRequest(patchOf(t, `{"limit":12,"excludeFollowing":true}`))
	if err != nil || r.Limit != 12 || !r.ExcludeFollowing {
		t.Fatalf("%+v %v", r, err)
	}
	for _, bad := range []string{`{"limit":0}`, `{"limit":21}`, `{"limit":"5"}`, `{"excludeFollowing":"true"}`, `{"interests":["a"]}`} {
		if _, err := ParsePossibleRequest(patchOf(t, bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestMatchScoreFixtures(t *testing.T) {
	me := MatchProfile{
		Interests: []string{"music", "books", "hiking", "chess", "film", "art", "yoga"},
		Tags:      []string{"curious", "maker"},
		Languages: map[string]int{"en": 6, "ko": 2},
		Country:   "IN",
	}
	cases := []struct {
		name  string
		them  MatchProfile
		score int
		why   []string
	}{
		{"nothing in common", MatchProfile{Interests: []string{"golf"}, Languages: map[string]int{"fr": 6}}, 0, []string{}},
		{"two interests", MatchProfile{Interests: []string{"Music", "books"}}, 6, []string{"interests"}},
		{"interests are capped at five", MatchProfile{Interests: []string{"music", "books", "hiking", "chess", "film", "art", "yoga"}}, 15, []string{"interests"}},
		{"tags", MatchProfile{Tags: []string{"curious", "maker", "playful"}}, 4, []string{"personality"}},
		{"they can teach me Korean", MatchProfile{Languages: map[string]int{"ko": 5}}, 4, []string{"languages"}},
		{"I can teach them English", MatchProfile{Languages: map[string]int{"en": 2}}, 4, []string{"languages"}},
		{"both directions", MatchProfile{Languages: map[string]int{"ko": 6, "en": 1}}, 8, []string{"languages"}},
		{"same level is not complementary", MatchProfile{Languages: map[string]int{"ko": 2, "en": 6}}, 0, []string{}},
		{"fluent both is not complementary", MatchProfile{Languages: map[string]int{"en": 5}}, 0, []string{}},
		{"same country", MatchProfile{Country: "IN"}, 1, []string{"country"}},
		{"everything", MatchProfile{Interests: []string{"music"}, Tags: []string{"maker"}, Languages: map[string]int{"ko": 4}, Country: "IN"}, 3 + 2 + 4 + 1, []string{"interests", "personality", "languages", "country"}},
	}
	for _, c := range cases {
		got := Score(me, c.them)
		if got.Total() != c.score {
			t.Errorf("%s: score %d, want %d", c.name, got.Total(), c.score)
		}
		if strings.Join(got.Reasons(), ",") != strings.Join(c.why, ",") {
			t.Errorf("%s: reasons %v, want %v", c.name, got.Reasons(), c.why)
		}
	}
	if (Score(MatchProfile{}, MatchProfile{Country: ""}).SameCountry) {
		t.Fatal("two unknown countries are not the same country")
	}
	full := MatchProfile{Interests: me.Interests, Tags: []string{"curious", "maker", "playful", "sporty", "chatty", "foodie"}, Languages: map[string]int{"ko": 6, "en": 1}, Country: "IN"}
	if got := Score(MatchProfile{Interests: me.Interests, Tags: full.Tags, Languages: me.Languages, Country: "IN"}, full).Total(); got != MatchMaxScore {
		t.Fatalf("largest score %d, MatchMaxScore %d", got, MatchMaxScore)
	}
}

func TestLocalTimeAcrossDST(t *testing.T) {
	winter := time.Date(2026, 1, 15, 12, 0, 0, 0, time.UTC)
	summer := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		zone         string
		now          time.Time
		offset       int
		label        string
		sameAsWinter bool
	}{
		{"America/New_York", winter, -300, "UTC-5", false},
		{"America/New_York", summer, -240, "UTC-4", false},
		{"Europe/London", winter, 0, "UTC", false},
		{"Europe/London", summer, 60, "UTC+1", false},
		{"Australia/Sydney", winter, 660, "UTC+11", false},
		{"Australia/Sydney", summer, 600, "UTC+10", false},
		{"Asia/Kolkata", winter, 330, "UTC+5:30", false},
		{"Asia/Kolkata", summer, 330, "UTC+5:30", false},
		{"Asia/Kathmandu", summer, 345, "UTC+5:45", false},
		{"America/St_Johns", winter, -210, "UTC-3:30", false},
		{"UTC", summer, 0, "UTC", false},
	}
	for _, c := range cases {
		got := LocalTimeFor(c.zone, c.now)
		if got == nil || got.UTCOffsetMinutes != c.offset || got.Label != c.label {
			t.Errorf("%s at %s: %+v, want %d %s", c.zone, c.now.Format("2006-01-02"), got, c.offset, c.label)
		}
	}
	// The change happens at the transition itself: New York on the night clocks go forward in 2026 (8 March).
	before := time.Date(2026, 3, 8, 6, 59, 0, 0, time.UTC) // 01:59 EST
	after := time.Date(2026, 3, 8, 7, 1, 0, 0, time.UTC)   // 03:01 EDT
	if LocalTimeFor("America/New_York", before).UTCOffsetMinutes != -300 || LocalTimeFor("America/New_York", after).UTCOffsetMinutes != -240 {
		t.Fatal("the offset does not follow the daylight saving change")
	}
	for _, zone := range []string{"", "Local", "Nowhere/Land", "not a zone"} {
		if LocalTimeFor(zone, summer) != nil {
			t.Errorf("zone %q gave a local time", zone)
		}
	}
	data, _ := json.Marshal(LocalTimeFor("Asia/Kolkata", summer))
	if string(data) != `{"utcOffsetMinutes":330,"label":"UTC+5:30"}` {
		t.Fatal(string(data))
	}
}
