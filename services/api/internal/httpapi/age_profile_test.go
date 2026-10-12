package httpapi

import (
	"os"
	"strings"
	"testing"

	"hiyall/services/api/internal/store"
)

// profileOf opens target's profile as viewer and returns the status, the data and the raw response text.
func (h *socialHarness) profileOf(viewer, target string) (int, map[string]any, string) {
	h.t.Helper()
	status, _, raw := h.full(viewer, "GET", "/v1/users/"+target+"/profile", "", "")
	got := h.send(viewer, "GET", "/v1/users/"+target+"/profile", nil)
	if got.status != status {
		h.t.Fatalf("status %d then %d", status, got.status)
	}
	return status, got.data, string(raw)
}

func (h *socialHarness) ageAudience(id, audience string) {
	h.t.Helper()
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,age}',to_jsonb($2::text)) WHERE user_id=$1`, id, audience)
}

// A profile shows whole years of age to another member, only when the age is known, the member's age audience allows
// the viewer and the profile is not the locked card; never the birth date or a band, never null or zero.
func TestProfileShowsWholeYearsOfAgeOnlyWhenAllowed(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(cara, 30)
	h.ageAt(xan, 41)
	h.setAge(yui, 0)
	age := func(viewer, target string) (any, bool) {
		t.Helper()
		status, data, raw := h.profileOf(viewer, target)
		if status != 200 {
			t.Fatalf("%s opening %s: %d %s", viewer, target, status, raw)
		}
		if leak := ageDisclosure(raw, true); leak != "" {
			t.Fatalf("profile shows %q: %s", leak, raw)
		}
		value, ok := data["age"]
		return value, ok
	}

	// Shown, as an integer number of whole years, by default.
	if value, ok := age(alice, cara); !ok || value != float64(30) {
		t.Fatalf("age %v (present %v), want 30", value, ok)
	}
	if value, ok := age(alice, xan); !ok || value != float64(41) {
		t.Fatalf("age %v (present %v), want 41", value, ok)
	}
	// Whole years only: the day before a birthday is still the younger age, the birthday itself the older.
	for _, tc := range []struct{ years, days, want int }{{30, 0, 30}, {30, 200, 30}, {30, 364, 30}, {30, -1, 29}, {29, -1, 28}, {18, 0, 18}, {18, -1, 17}, {13, 0, 13}} {
		h.ageOffset(cara, tc.years, tc.days)
		if tc.want < 18 {
			continue // a minor is not visible to an adult viewer; checked below with a minor viewer
		}
		if value, ok := age(alice, cara); !ok || value != float64(tc.want) {
			t.Fatalf("born %d years and %d days ago: age %v, want %d", tc.years, tc.days, value, tc.want)
		}
	}
	h.ageAt(cara, 30)

	// An unknown age is omitted, never null or 0.
	if value, ok := age(alice, yui); ok {
		t.Fatalf("an unknown age is shown as %v", value)
	}

	// Only when the audience allows the viewer, the same way as every other field.
	h.ageAudience(cara, "nobody")
	if _, ok := age(alice, cara); ok {
		t.Fatal("age shown against audience nobody")
	}
	h.ageAudience(cara, "friends")
	if _, ok := age(alice, cara); ok {
		t.Fatal("age shown to a stranger against audience friends")
	}
	h.exec(`INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'accepted')`, alice, cara)
	if value, ok := age(alice, cara); !ok || value != float64(30) {
		t.Fatalf("age for a friend %v", value)
	}
	h.ageAudience(cara, "nobody")
	if _, ok := age(alice, cara); ok {
		t.Fatal("age shown to a friend against audience nobody")
	}
	h.ageAudience(cara, "followers")
	if value, ok := age(alice, cara); !ok || value != float64(30) { // a friend counts as a follower
		t.Fatalf("age for a follower-or-friend %v", value)
	}
	h.exec(`DELETE FROM friendships WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`, alice, cara)
	if _, ok := age(alice, cara); ok {
		t.Fatal("age shown to a stranger against audience followers")
	}
	h.exec(`INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active')`, alice, cara)
	if value, ok := age(alice, cara); !ok || value != float64(30) {
		t.Fatalf("age for a follower %v", value)
	}
	h.exec(`DELETE FROM follows WHERE follower_id=$1`, alice)
	// A missing audience is the same as nobody.
	h.exec(`UPDATE privacy_settings SET data=data #- '{fieldAudiences,age}' WHERE user_id=$1`, cara)
	if _, ok := age(alice, cara); ok {
		t.Fatal("age shown with no audience stored")
	}
	h.ageAudience(cara, "everyone")

	// Not on the locked card, even when the audience is everyone.
	h.policy(cara, "profileAudience", "friends")
	status, data, raw := h.profileOf(alice, cara)
	if status != 200 || data["locked"] != true {
		t.Fatalf("expected the locked card: %d %s", status, raw)
	}
	if _, ok := data["age"]; ok || ageDisclosure(raw, false) != "" {
		t.Fatalf("the locked card shows age: %s", raw)
	}
	h.policy(cara, "profileAudience", "public")

	// The owner's own profile has no age, on the member route and on GET /v1/me/profile.
	if value, ok := age(cara, cara); ok {
		t.Fatalf("a member's own profile shows age %v", value)
	}
	mine := h.send(cara, "GET", "/v1/me/profile", nil)
	if _, ok := mine.data["age"]; ok {
		t.Fatal("GET /v1/me/profile carries age")
	}
	privacy := h.send(cara, "GET", "/v1/me/privacy", nil)
	if privacy.data["fieldAudiences"].(map[string]any)["age"] != "everyone" {
		t.Fatalf("the age audience is missing from the privacy settings: %v", privacy.data["fieldAudiences"])
	}

	// Not in search or Nearby results, and not in the keys of anything else.
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.north(cara, 0.01)
	search, nearby := h.both(alice, map[string]any{})
	if !slicesContain(search, cara) || !slicesContain(nearby, cara) {
		t.Fatalf("cara is not listed: %v %v", search, nearby)
	}
	for _, path := range []string{"/v1/discovery/search", "/v1/discover/nearby"} {
		h.api.search.reset(alice)
		for _, item := range items(h.expect(h.send(alice, "POST", path, map[string]any{}), 200, "").data) {
			if _, ok := item["age"]; ok {
				t.Fatalf("%s item carries age: %v", path, item)
			}
		}
	}
}

// The age-band barrier still decides who can open a profile: across bands it is a 404 and never shows an age.
func TestAgeIsNeverShownAcrossAgeBands(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	h.ageAt(eli, 16)
	h.ageAt(cara, 30)
	for _, pair := range [][2]string{{dev, cara}, {cara, dev}, {eli, cara}, {cara, eli}} {
		status, _, raw := h.profileOf(pair[0], pair[1])
		if status != 404 || strings.Contains(raw, `"age"`) {
			t.Fatalf("%s opening %s: %d %s", pair[0], pair[1], status, raw)
		}
	}
	// Inside the minor band the age is shown like any other member's.
	if status, data, raw := h.profileOf(dev, eli); status != 200 || data["age"] != float64(16) || ageDisclosure(raw, true) != "" {
		t.Fatalf("a minor opening a minor: %d %v %s", status, data["age"], raw)
	}
	if status, data, _ := h.profileOf(eli, dev); status != 200 || data["age"] != float64(15) {
		t.Fatalf("%d %v", status, data["age"])
	}
	// The day a member turns 18 they leave the minor band: 17 is shown to minors, then nothing.
	h.ageOffset(dev, 18, -1)
	if status, data, _ := h.profileOf(eli, dev); status != 200 || data["age"] != float64(17) {
		t.Fatalf("a member of 17: %d %v", status, data["age"])
	}
	h.ageOffset(dev, 18, 0)
	if status, _, raw := h.profileOf(eli, dev); status != 404 || strings.Contains(raw, `"age"`) {
		t.Fatalf("a member of 18 opened by a minor: %d %s", status, raw)
	}
	if status, data, _ := h.profileOf(cara, dev); status != 200 || data["age"] != float64(18) {
		t.Fatalf("a member of 18 opened by an adult: %d %v", status, data["age"])
	}
	// With isolation off the barrier is block-only, so an age can be shown across bands, and a block still hides it.
	off := newSocialHarnessWith(t, store.WithAgeBandIsolation(false))
	off.ageAt(dev, 15)
	off.ageAt(cara, 30)
	if status, data, _ := off.profileOf(dev, cara); status != 200 || data["age"] != float64(30) {
		t.Fatalf("isolation off: %d %v", status, data["age"])
	}
	off.expect(off.call(cara, "POST", "/v1/users/"+dev+"/block"), 200, "")
	if status, _, raw := off.profileOf(dev, cara); status != 404 || strings.Contains(raw, `"age"`) {
		t.Fatalf("a blocked profile: %d %s", status, raw)
	}
}

// 0018 adds the age audience where it is missing, bumps the version only there, and changes nothing when run again.
func TestMigration0018AddsTheAgeAudienceIdempotently(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0018_age_field_audience.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_18`,
		`SET LOCAL search_path = migration_scratch_18`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`CREATE TABLE privacy_settings(user_id uuid PRIMARY KEY REFERENCES users(user_id), data jsonb NOT NULL, version bigint NOT NULL DEFAULT 1, updated_at timestamptz NOT NULL DEFAULT '2020-01-01')`,
		`INSERT INTO users VALUES ('019a4000-0000-7000-8000-000000000d01'),('019a4000-0000-7000-8000-000000000d02'),('019a4000-0000-7000-8000-000000000d03')`,
		`INSERT INTO privacy_settings(user_id,data,version) VALUES
 ('019a4000-0000-7000-8000-000000000d01','{"customKey":"kept","fieldAudiences":{"gender":"friends","vibe":"nobody"}}',4),
 ('019a4000-0000-7000-8000-000000000d02','{"fieldAudiences":{"age":"nobody","gender":"everyone"}}',7),
 ('019a4000-0000-7000-8000-000000000d03','{"profileAudience":"friends"}',1)`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := func() string {
		rows, err := tx.Query(ctx, `SELECT user_id::text||' '||version||' '||(data->'fieldAudiences')::text||' '||coalesce(data->>'customKey','') FROM privacy_settings ORDER BY user_id`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var line string
			_ = rows.Scan(&line)
			out = append(out, line)
		}
		return strings.Join(out, "\n")
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("migration: %v", err)
	}
	first := snapshot()
	for _, want := range []string{
		`019a4000-0000-7000-8000-000000000d01 5 {"age": "everyone", "vibe": "nobody", "gender": "friends"} kept`,
		`019a4000-0000-7000-8000-000000000d02 7 {"age": "nobody", "gender": "everyone"} `, // already chose: untouched, version unchanged
		`019a4000-0000-7000-8000-000000000d03 2 {"age": "everyone"} `,
	} {
		if !strings.Contains(first, want) {
			t.Fatalf("after the migration:\n%s\nmissing %q", first, want)
		}
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatal(err)
	}
	if second := snapshot(); second != first {
		t.Fatalf("running it again changed rows:\n%s\n--\n%s", first, second)
	}
	_ = tx.Rollback(ctx)
	var exists bool
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_18.privacy_settings') IS NOT NULL`).Scan(&exists); err != nil || exists {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
