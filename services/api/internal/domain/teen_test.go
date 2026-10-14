package domain

import (
	"encoding/json"
	"errors"
	"math"
	"testing"
	"time"
)

func patch(t *testing.T, raw string) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestMinorPrivacyPatchCannotLoosenLockedSettings(t *testing.T) {
	refused := []string{
		`{"onlineAudience":"everyone"}`, `{"onlineAudience":"friends"}`, `{"onlineAudience":"followers"}`,
		`{"locationAudience":"everyone"}`, `{"locationAudience":"friends"}`,
		`{"fieldAudiences":{"location":"everyone"}}`, `{"fieldAudiences":{"location":"followers"}}`,
		`{"fieldAudiences":{"connections":"everyone"}}`, `{"fieldAudiences":{"connections":"followers"}}`,
		`{"fieldAudiences":{"age":"everyone","connections":"everyone"}}`,
	}
	for _, raw := range refused {
		err := ValidateMinorPrivacyPatch(patch(t, raw))
		if !errors.Is(err, ErrMinorSettingLocked) {
			t.Errorf("%s: %v", raw, err)
		}
	}
	allowed := []string{
		`{"onlineAudience":"nobody"}`, `{"locationAudience":"nobody"}`,
		`{"fieldAudiences":{"location":"friends"}}`, `{"fieldAudiences":{"location":"nobody"}}`,
		`{"fieldAudiences":{"connections":"friends"}}`, `{"fieldAudiences":{"connections":"nobody"}}`,
		`{"fieldAudiences":{"age":"everyone","interests":"everyone"}}`,
		`{"profileAudience":"private"}`, `{"messagesFrom":"friends"}`, `{"discoverable":false}`,
	}
	for _, raw := range allowed {
		if err := ValidateMinorPrivacyPatch(patch(t, raw)); err != nil {
			t.Errorf("%s: %v", raw, err)
		}
	}
	// The minor defaults themselves satisfy the lock.
	p := DefaultPrivacy()
	ApplyMinorDefaults(&p)
	raw, _ := json.Marshal(map[string]any{"onlineAudience": p.OnlineAudience, "locationAudience": p.LocationAudience, "fieldAudiences": map[string]string{"location": p.FieldAudiences["location"], "connections": p.FieldAudiences["connections"]}})
	if err := ValidateMinorPrivacyPatch(patch(t, string(raw))); err != nil {
		t.Fatalf("defaults refused: %v", err)
	}
}

func TestFreeDailyCaps(t *testing.T) {
	e := Free()
	got := []int{e.FollowsPerDay, e.FriendRequestsPerDay, e.CommentsPerDay, e.SpacesPerDay, e.SpaceEntriesPerDay, e.SearchPagesPerDay, e.ProfileViewsPerDay, e.NearbyQueriesPerDay, e.LocationChangesPerDay}
	want := []int{200, 50, 300, 3, 100, 300, 500, 200, 5}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("caps %v, want %v", got, want)
		}
	}
}

func TestUntilNextUTCDay(t *testing.T) {
	at := time.Date(2026, 10, 13, 23, 0, 0, 0, time.UTC)
	if d := UntilNextUTCDay(at); d != time.Hour {
		t.Fatalf("%v", d)
	}
	if d := UntilNextUTCDay(time.Date(2026, 12, 31, 0, 0, 0, 0, time.UTC)); d != 24*time.Hour {
		t.Fatalf("%v", d)
	}
}

func TestRandomOffsetStaysInTheDisc(t *testing.T) {
	for _, uv := range [][2]float64{{0, 0}, {0.999999, 0.3}, {0.5, 0.5}, {0.25, 0.9}} {
		o := RandomOffset(5, uv[0], uv[1])
		if math.Hypot(o.NorthKm, o.EastKm) > 5+1e-9 {
			t.Fatalf("%v outside the disc: %+v", uv, o)
		}
	}
}

func TestShiftMovesByTheOffsetAndStaysOnTheGlobe(t *testing.T) {
	p := Location{12.97, 77.59}.Shift(Offset{NorthKm: 11.1195, EastKm: 0})
	if math.Abs(p.Latitude-13.07) > 0.001 || p.Longitude != 77.59 {
		t.Fatalf("%+v", p)
	}
	if q := (Location{89.99, 10}).Shift(Offset{NorthKm: 50}); q.Latitude != 90 {
		t.Fatalf("latitude not clamped: %+v", q)
	}
	if q := (Location{0, 179.99}).Shift(Offset{EastKm: 5}); q.Longitude > -179 || q.Longitude < -180 {
		t.Fatalf("longitude did not wrap: %+v", q)
	}
}

func TestImplausibleJump(t *testing.T) {
	blr, chn, nyc := Location{12.97, 77.59}, Location{13.08, 80.27}, Location{40.71, -74.0}
	if ImplausibleJump(blr, Location{12.99, 77.62}, time.Second) {
		t.Fatal("a few km in a second is within the grid and offset tolerance")
	}
	if ImplausibleJump(blr, chn, 30*time.Minute) {
		t.Fatal("290 km in half an hour is 580 km/h")
	}
	if !ImplausibleJump(blr, chn, 5*time.Minute) {
		t.Fatal("290 km in five minutes is not plausible")
	}
	if !ImplausibleJump(blr, nyc, 2*time.Hour) {
		t.Fatal("13,000 km in two hours is not plausible")
	}
	if ImplausibleJump(blr, nyc, 24*time.Hour) {
		t.Fatal("13,000 km in a day is a flight")
	}
}

func TestParseBirthDate(t *testing.T) {
	now := time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)
	if _, err := ParseBirthDate(patch(t, `{"birthDate":"2013-10-14"}`), now); !errors.Is(err, ErrAgeRequirement) {
		t.Fatalf("12 years old: %v", err)
	}
	if _, err := ParseBirthDate(patch(t, `{"birthDate":"2013-10-13"}`), now); err != nil {
		t.Fatalf("13 today: %v", err)
	}
	for _, raw := range []string{`{}`, `{"birthDate":"13/10/2013"}`, `{"birthDate":"2013-10-13","termsVersion":"x"}`, `{"birthDate":"2999-01-01"}`} {
		var ve *ValidationError
		if _, err := ParseBirthDate(patch(t, raw), now); !errors.As(err, &ve) {
			t.Errorf("%s: %v", raw, err)
		}
	}
}

func TestCleanTextRules(t *testing.T) {
	ok := []string{
		"Aditya", "Zoë café", "👨\u200D👩\u200D👧 family", "❤️ heart", "🏳️\u200D🌈 flag", "नमस्ते क्\u200Dष", "می\u200Cخواهم", "line\nbreak", "tab\there", "é", "日本語 ハンドル",
	}
	for _, s := range ok {
		if !CleanText(s) {
			t.Errorf("rejected %q", s)
		}
	}
	bad := map[string]string{
		"nul": "a\x00b", "c1": "a\u0085b", "del": "a\x7fb", "bidi override": "abc\u202Edef", "bidi isolate": "a\u2066b", "lrm": "a\u200Eb",
		"zero width space": "ab\u200Bcd", "word joiner": "a\u2060b", "bom": "\uFEFFname", "soft hyphen": "a\u00ADb", "private use": "a\uE000b",
		"line separator": "a\u2028b", "tag char": "a\U000E0041b", "arabic letter mark": "a\u061Cb", "invalid utf8": "a\xffb",
		"leading zwj": "\u200Dab", "trailing zwj": "ab\u200D", "doubled zwj": "a\u200D\u200Db", "zwj by space": "a \u200Db",
		"zalgo": "á̂̃̄̅̆",
	}
	for name, s := range bad {
		if CleanText(s) {
			t.Errorf("%s accepted: %q", name, s)
		}
	}
	if CleanLine("a\nb") || CleanLine("a\tb") {
		t.Error("a line must not hold breaks")
	}
	if !CleanText("é̂̃̄̅") {
		t.Error("five combining marks should pass")
	}
}

func TestNormalizeIsNFC(t *testing.T) {
	if got := Normalize("Café"); got != "Café" {
		t.Fatalf("%q", got)
	}
	if got := Normalize("a\xffb"); got != "a\xffb" {
		t.Fatalf("invalid text changed: %q", got)
	}
}

func TestProfilePatchStoresNormalisedAndCleanText(t *testing.T) {
	p := patch(t, `{"displayName":"Café"}`)
	if err := ValidateProfilePatch(p); err != nil {
		t.Fatal(err)
	}
	var got string
	_ = json.Unmarshal(p["displayName"], &got)
	if got != "Café" {
		t.Fatalf("stored %q", got)
	}
	for _, raw := range []string{`{"displayName":"ab\u202Ecd"}`, `{"displayName":"a\u200Bb"}`, `{"bio":"x\u0085y"}`, `{"interests":["mu\u200Bsic"]}`} {
		if err := ValidateProfilePatch(patch(t, raw)); err == nil {
			t.Errorf("accepted %s", raw)
		}
	}
	q := patch(t, `{"interests":["Café"]}`)
	if err := ValidateProfilePatch(q); err != nil {
		t.Fatal(err)
	}
	var list []string
	_ = json.Unmarshal(q["interests"], &list)
	if len(list) != 1 || list[0] != "Café" {
		t.Fatalf("interests %q", list)
	}
}

func TestPostCommentStoryAndSpaceTextAreNormalisedAndCleaned(t *testing.T) {
	post, err := ParsePost([]byte(`{"body":"Café","audience":"public","mediaIds":[]}`))
	if err != nil || post.Body != "Café" {
		t.Fatalf("%q %v", post.Body, err)
	}
	if _, err = ParsePost([]byte(`{"body":"a\u202Eb","audience":"public","mediaIds":[]}`)); err == nil {
		t.Error("post with a bidi override accepted")
	}
	if _, err = ParseComment([]byte(`{"body":"hi\u200Bthere"}`)); err == nil {
		t.Error("comment with a zero width space accepted")
	}
	if c, err := ParseComment([]byte(`{"body":"Café"}`)); err != nil || c.Body != "Café" {
		t.Errorf("%q %v", c.Body, err)
	}
	if _, err = ParseStory([]byte(`{"body":"a\u2066b","audience":"public"}`)); err == nil {
		t.Error("story with an isolate accepted")
	}
	if SpaceText("a\u202Eb", 1, 10) {
		t.Error("space text with an override accepted")
	}
}
