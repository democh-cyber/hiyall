package httpapi

import (
	"bytes"
	"log/slog"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

func (h *onboardingHarness) memberAge(id string) (birth string, band string, age *int) {
	h.t.Helper()
	var stored *string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT birth_date::text FROM member_ages WHERE user_id=$1),age_band($1),member_age($1)`, id).Scan(&stored, &band, &age); err != nil {
		h.t.Fatal(err)
	}
	if stored != nil {
		birth = *stored
	}
	return
}

var (
	// a whole-year age as a JSON number, and the key set to null or zero, which is never sent.
	numericAge = regexp.MustCompile(`"age"\s*:\s*[0-9]`)
	emptyAge   = regexp.MustCompile(`"age"\s*:\s*(null|0[^0-9.]|"")`)
)

// ageDisclosure returns what in a response text says how old someone is, or "". Whole years appear on exactly one
// route, another member's profile, so allowWholeYears is set only for that route. A birth date, a band, an age
// key that is null or zero, and any of the dates in dates are never allowed. The privacy settings' own "age"
// audience key is a string and is fine: it is a setting, not an age.
func ageDisclosure(raw string, allowWholeYears bool, dates ...string) string {
	for _, leak := range append([]string{"birthDate", "birthYear", "birth_date", "ageBand", "age_band", "member_age", `"minor"`, `"adult"`, `"band"`}, dates...) {
		if leak != "" && strings.Contains(raw, leak) {
			return leak
		}
	}
	if emptyAge.MatchString(raw) {
		return `"age" null or zero`
	}
	if !allowWholeYears && numericAge.MatchString(raw) {
		return `"age" as a number`
	}
	return ""
}

func (h *onboardingHarness) privacy(token string) map[string]any {
	h.t.Helper()
	return h.expect(h.call("GET", "/v1/me/privacy", token, ""), 200, "").data
}

// The first stored birth date is final, the minor defaults are applied once at completion, and an adult's are
// untouched.
func TestCompletionStoresTheBirthDateOnceAndAppliesMinorDefaults(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(sam)
	h.finishProfile(token, "sam_k", "Sam")
	if before := h.privacy(token); before["version"] != "1" || before["onlineAudience"] != "everyone" {
		t.Fatalf("new account privacy %v", before)
	}
	// Under 13 is refused and stores nothing at all.
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(underageBirthDate(), "2026-10-01")), 403, "AGE_REQUIREMENT_NOT_MET")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(turnsTomorrow(13), "2026-10-01")), 403, "AGE_REQUIREMENT_NOT_MET")
	if birth, band, age := h.memberAge(sam); birth != "" || age != nil || band != "adult" {
		t.Fatalf("a refused declaration stored %q band %s age %v", birth, band, age)
	}
	if h.privacy(token)["version"] != "1" {
		t.Fatal("a refused declaration changed privacy")
	}

	// Someone who turns 13 today is accepted, and is a minor.
	first := birthdayToday(13)
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(first, "2026-10-01")), 200, "")
	if birth, band, age := h.memberAge(sam); birth != first || band != "minor" || age == nil || *age != 13 {
		t.Fatalf("stored %q band %s age %v", birth, band, age)
	}
	p := h.privacy(token)
	fields := p["fieldAudiences"].(map[string]any)
	if p["onlineAudience"] != "nobody" || fields["location"] != "friends" || p["version"] != "2" {
		t.Fatalf("minor defaults not applied once: online %v location %v version %v", p["onlineAudience"], fields["location"], p["version"])
	}
	// Everything else keeps the open defaults; messages stay friends-only.
	for _, name := range domain.Fields {
		want := "everyone"
		switch name {
		case "connections":
			want = "friends"
		case "location":
			want = "friends"
		case "aboutMe", "hometown", "birthday":
			want = "nobody" // profile v2: hidden for a minor (a minor may later choose friends for the first two)
		}
		if fields[name] != want {
			t.Fatalf("field %s is %v, want %v", name, fields[name], want)
		}
	}
	// Messaging is open for minors too (inside their band); there is no minor-specific messagesFrom.
	if p["messagesFrom"] != "everyone" || p["followPolicy"] != "everyone" || p["profileAudience"] != "public" || p["discoverable"] != true {
		t.Fatalf("a minor's other defaults changed: %v", p)
	}

	// Completing again, even with an adult date, ignores it: nothing is stored or re-applied.
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody("1980-01-02", "2026-10-01")), 200, "")
	if birth, band, _ := h.memberAge(sam); birth != first || band != "minor" {
		t.Fatalf("the stored birth date moved: %q band %s", birth, band)
	}
	// A minor cannot loosen presence (it stays locked, MINOR_SETTING_LOCKED), but can change other settings, and a
	// repeat completion does not take them back.
	version := h.privacy(token)["version"].(string)
	h.expect(serve(t, h.handler, "PATCH", "/v1/me/privacy", token, map[string]string{"If-Match": `"` + version + `"`}, `{"onlineAudience":"everyone"}`), 422, "MINOR_SETTING_LOCKED")
	h.expect(serve(t, h.handler, "PATCH", "/v1/me/privacy", token, map[string]string{"If-Match": `"` + version + `"`}, `{"messagesFrom":"friends"}`), 200, "")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(first, "2026-10-01")), 200, "")
	if h.privacy(token)["messagesFrom"] != "friends" || h.privacy(token)["onlineAudience"] != "nobody" {
		t.Fatal("a repeat completion reset the member's own setting, or presence was loosened")
	}
}

// A birth date already stored is final even before onboarding completes: a different date at completion cannot
// move the member to another band.
func TestAStoredBirthDateCannotBeChangedAtCompletion(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(sam)
	h.finishProfile(token, "sam_k", "Sam")
	h.mustExec(`INSERT INTO member_ages(user_id,birth_date) VALUES($1,(now() AT TIME ZONE 'UTC')::date-make_interval(years=>30))`, sam)
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(minorBirthDate(), "2026-10-01")), 200, "")
	if _, band, age := h.memberAge(sam); band != "adult" || age == nil || *age != 30 {
		t.Fatalf("band %s age %v", band, age)
	}
	if p := h.privacy(token); p["onlineAudience"] != "everyone" || p["version"] != "1" {
		t.Fatalf("an adult got minor defaults: %v", p)
	}
}

// An adult's defaults are untouched by completion.
func TestAdultCompletionKeepsTheOpenDefaults(t *testing.T) {
	f := newFirebaseHarness(t)
	token := f.token(idToken{sub: "adult-uid", provider: "google.com"})
	f.expect(f.call("GET", "/v1/me/onboarding", token, ""), 200, "")
	f.finishProfile(token, "adult_one", "Adult")
	f.expect(f.call("POST", "/v1/me/onboarding/complete", token, completeBody(birthdayToday(18), "2026-10-01")), 200, "")
	p := f.privacy(token)
	assertOpenDefaults(t, p)
	if p["version"] != "1" {
		t.Fatalf("version %v", p["version"])
	}
	if _, band, _ := f.memberAge(userOf(t, f.onboardingHarness, "adult-uid")); band != "adult" {
		t.Fatalf("band %s", band)
	}
	// 17 years and 364 days is still a minor.
	g := f.token(idToken{sub: "almost-uid", provider: "google.com"})
	f.expect(f.call("GET", "/v1/me/onboarding", g, ""), 200, "")
	f.finishProfile(g, "almost_adult", "Almost")
	f.expect(f.call("POST", "/v1/me/onboarding/complete", g, completeBody(turnsTomorrow(18), "2026-10-01")), 200, "")
	if _, band, _ := f.memberAge(userOf(t, f.onboardingHarness, "almost-uid")); band != "minor" {
		t.Fatalf("band %s the day before the 18th birthday", band)
	}
	if f.privacy(g)["onlineAudience"] != "nobody" {
		t.Fatal("the minor defaults were not applied the day before the 18th birthday")
	}
}

func userOf(t *testing.T, h *onboardingHarness, subject string) string {
	t.Helper()
	var id string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT user_id::text FROM auth_identities WHERE subject=$1`, subject).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

// Nothing says how old anyone is: no response, profile JSON, outbox payload or log line carries a birth date or age,
// and the only table that holds one is member_ages.
func TestAgeAndBirthDateAppearNowhereElse(t *testing.T) {
	h := newOnboardingHarness(t)
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previous) })

	kai, anjali := h.login(store.KaiID), h.login(alice)
	token := h.login(sam)
	h.finishProfile(token, "sam_k", "Sam")
	const birth = "2010-03-14"
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(birth, "2026-10-01")), 200, "")

	var kaiBirth string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT birth_date::text FROM member_ages WHERE user_id=$1`, store.KaiID).Scan(&kaiBirth); err != nil {
		t.Fatal(err)
	}
	// Own and others' views, every projection that mentions a person. Whole years of age appear on exactly one of
	// them: Anjali opening Niko's profile. Nothing here ever shows a birth date, a band, or age as null or zero.
	for _, call := range []struct {
		token, path string
		wholeYears  bool
	}{
		{token, "/v1/me/profile", false}, {token, "/v1/me/privacy", false}, {token, "/v1/me/onboarding", false}, {token, "/v1/auth/sessions", false},
		{kai, "/v1/me/profile", false}, {kai, "/v1/me/privacy", false}, {kai, "/v1/users/" + store.KaiID + "/profile", false},
		{anjali, "/v1/me/profile", false}, {anjali, "/v1/users/" + bob + "/profile", true}, {anjali, "/v1/users/" + alice + "/profile", false},
		{anjali, "/v1/me/friends", false}, {anjali, "/v1/notifications", false},
	} {
		raw := h.rawCall("GET", call.path, call.token)
		if leak := ageDisclosure(raw, call.wholeYears, birth, kaiBirth); leak != "" {
			t.Fatalf("%s shows %q: %s", call.path, leak, raw)
		}
	}
	// Search and Nearby results have no age or gender either, with or without the filters.
	h.mustExec(`INSERT INTO nearby_prefs(user_id,visible) VALUES($1,true),($2,true)`, alice, bob)
	h.mustExec(`INSERT INTO user_locations(user_id,latitude,longitude) VALUES($1,12.97,77.59),($2,12.97,77.59)`, alice, bob)
	for _, body := range []string{`{}`, `{"ageMin":20,"ageMax":40}`, `{"gender":"man"}`} {
		for _, path := range []string{"/v1/discovery/search", "/v1/discover/nearby"} {
			h.api.search.reset(alice)
			raw := string(h.rawPost(path, anjali, body))
			if leak := ageDisclosure(raw, false, birth, kaiBirth); leak != "" {
				t.Fatalf("POST %s %s shows %q: %s", path, body, leak, raw)
			}
			for _, leak := range []string{`"gender"`, `"ageMin"`, `"ageMax"`} {
				if strings.Contains(raw, leak) {
					t.Fatalf("POST %s %s shows %q: %s", path, body, leak, raw)
				}
			}
		}
	}
	// Every table and the logs: a birth date is in member_ages only.
	var events int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM profiles WHERE data::text LIKE '%birth%' OR data::text LIKE '%"age%'`).Scan(&events); err != nil || events != 0 {
		t.Fatalf("%d profiles carry age data (%v)", events, err)
	}
	var tables []string
	rows, err := h.db.Pool.Query(h.ctx, `SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname<>'member_ages' AND c.relname NOT IN ('schema_migrations')`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var name string
		_ = rows.Scan(&name)
		tables = append(tables, name)
	}
	rows.Close()
	for _, name := range tables {
		for _, date := range []string{birth, kaiBirth} {
			var hits int
			if err = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM `+name+` t WHERE t::text LIKE $1`, "%"+date+"%").Scan(&hits); err != nil || hits != 0 {
				t.Fatalf("%s found in %s (%v)", date, name, err)
			}
		}
	}
	for _, date := range []string{birth, kaiBirth} {
		if strings.Contains(logs.String(), date) {
			t.Fatalf("%s was logged", date)
		}
	}
	// No API route returns it either: the owner asking for age or birth date by any plausible name gets nothing.
	for _, path := range []string{"/v1/me/age", "/v1/me/birth-date", "/v1/me/birthdate", "/v1/me/age-band", "/v1/users/" + sam + "/age"} {
		if got := h.call("GET", path, token, ""); got.status != 404 {
			t.Fatalf("%s answered %d", path, got.status)
		}
	}
}

// rawPost posts a JSON body and returns the response text.
func (h *onboardingHarness) rawPost(path, token, body string) []byte {
	h.t.Helper()
	req := httptest.NewRequest("POST", path, bytes.NewBufferString(body))
	req.RemoteAddr = "127.0.0.1:44001"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec.Body.Bytes()
}

// The dev fixtures: Kai is a minor with the minor defaults, Anjali and Niko are adults, and the two groups cannot see each other.
func TestSeededFixturesHaveAgeBands(t *testing.T) {
	h := newOnboardingHarness(t)
	for id, want := range map[string]string{alice: "adult", bob: "adult", store.KaiID: "minor", sam: "adult"} {
		if _, band, _ := h.memberAge(id); band != want {
			t.Fatalf("%s is %s, want %s", id, band, want)
		}
	}
	if _, _, age := h.memberAge(store.KaiID); age == nil || *age != 15 {
		t.Fatalf("Kai's age %v", age)
	}
	if _, _, age := h.memberAge(sam); age != nil {
		t.Fatalf("Sam has an age before onboarding: %v", *age)
	}
	var stored int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM member_ages`).Scan(&stored); err != nil || stored != 3 {
		t.Fatalf("%d birth dates after Seed (%v), want Anjali, Niko and Kai", stored, err)
	}
	kai := h.login(store.KaiID)
	h.expect(h.call("GET", "/v1/me/onboarding", kai, ""), 200, "")
	p := h.privacy(kai)
	if p["onlineAudience"] != "nobody" || p["fieldAudiences"].(map[string]any)["location"] != "friends" || p["messagesFrom"] != "everyone" {
		t.Fatalf("Kai's privacy %v", p)
	}
	if profile := h.expect(h.call("GET", "/v1/me/profile", kai, ""), 200, "").data; profile["username"] != "kai" || profile["displayName"] != "Kai" || profile["gender"] != "" {
		t.Fatalf("Kai's profile %v", profile)
	}
	// Kai finds no adult, and no adult finds Kai.
	anjali := h.login(alice)
	listed := func(token string) []string {
		h.api.search.reset(alice)
		h.api.search.reset(store.KaiID)
		var out []string
		for _, item := range items(h.expect(h.call("POST", "/v1/discovery/search", token, "{}"), 200, "").data) {
			out = append(out, item["userId"].(string))
		}
		return out
	}
	if got := listed(kai); len(got) != 0 {
		t.Fatalf("Kai sees %v", got)
	}
	if got := listed(anjali); slicesContain(got, store.KaiID) || !slicesContain(got, bob) {
		t.Fatalf("Anjali sees %v", got)
	}
	h.expect(h.call("GET", "/v1/users/"+store.KaiID+"/profile", anjali, ""), 404, "NOT_FOUND")
	h.expect(h.call("GET", "/v1/users/"+alice+"/profile", kai, ""), 404, "NOT_FOUND")
	// Seeding again changes nothing.
	for i := 0; i < 2; i++ {
		if err := h.db.Seed(h.ctx); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM member_ages`).Scan(&stored); err != nil || stored != 3 {
		t.Fatalf("%d birth dates after reseeding (%v)", stored, err)
	}
	if h.privacy(kai)["version"] != "2" {
		t.Fatal("reseeding re-applied Kai's minor defaults")
	}
	// An existing database that predates the birth dates gains the fixtures' dates without re-applying any defaults.
	h.mustExec(`DELETE FROM member_ages`)
	if err := h.db.Seed(h.ctx); err != nil {
		t.Fatal(err)
	}
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM member_ages`).Scan(&stored); err != nil || stored != 3 {
		t.Fatalf("%d birth dates after reseeding an old database (%v)", stored, err)
	}
}
