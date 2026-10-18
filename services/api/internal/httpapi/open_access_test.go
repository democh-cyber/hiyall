package httpapi

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// openDefaults are the privacy settings every new account starts with.
func assertOpenDefaults(t *testing.T, got map[string]any) {
	t.Helper()
	want := map[string]any{
		"profileAudience": "public", "discoverable": true, "showInterestOverlap": true, "onlineAudience": "everyone",
		"messagesFrom": "everyone", "followPolicy": "everyone", "requestsFrom": "everyone", "storyAudience": "friends",
		"commentsFrom": "friends", "mentionsFrom": "friends",
		"activityAudience": "nobody", "lastSeenAudience": "nobody", "locationAudience": "nobody",
	}
	for key, value := range want {
		if got[key] != value {
			t.Fatalf("%s is %v, want %v", key, got[key], value)
		}
	}
	fields, _ := got["fieldAudiences"].(map[string]any)
	if len(fields) != len(domain.Fields) {
		t.Fatalf("fieldAudiences %v", fields)
	}
	for _, name := range domain.Fields {
		expected := "everyone"
		switch name {
		case "connections", "aboutMe", "hometown":
			expected = "followers" // an adult's followers and following lists, about-me and hometown open to followers
		case "birthday":
			expected = "friends"
		}
		if fields[name] != expected {
			t.Fatalf("fieldAudiences.%s is %v, want %v", name, fields[name], expected)
		}
	}
}

func TestNewMembersAreOpenByDefaultAndFindableWithoutAnyEligibility(t *testing.T) {
	h := newOnboardingHarness(t)
	anjali, newcomer := h.login(alice), h.login(sam)

	// Seeded fixtures and a freshly created account carry the same open defaults, stored and mirrored in the profile.
	assertOpenDefaults(t, h.expect(h.call("GET", "/v1/me/privacy", anjali, ""), 200, "").data)
	assertOpenDefaults(t, h.expect(h.call("GET", "/v1/me/privacy", newcomer, ""), 200, "").data)
	var mirrored int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM profiles WHERE data->>'profileAudience'='public'`).Scan(&mirrored); err != nil || mirrored != 4 {
		t.Fatalf("%d profiles mirror a public audience (%v), want all 4 fixtures", mirrored, err)
	}

	listed := func() map[string]map[string]any {
		t.Helper()
		h.api.search.reset(alice)
		out := map[string]map[string]any{}
		for _, item := range items(h.expect(h.call("POST", "/v1/discovery/search", anjali, "{}"), 200, "").data) {
			out[item["userId"].(string)] = item
		}
		return out
	}
	// Niko is found straight away: there is no eligibility to grant and no privacy to change.
	if _, ok := listed()[bob]; !ok {
		t.Fatal("a seeded member is not discoverable by default")
	}
	// A member who has not finished onboarding is neither listed nor visible.
	if _, ok := listed()[sam]; ok {
		t.Fatal("a member who has not onboarded was listed")
	}
	h.expect(h.call("GET", "/v1/users/"+sam+"/profile", anjali, ""), 404, "NOT_FOUND")

	h.finishProfile(newcomer, "sam_k", "Sam")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", newcomer, completeBody(memberBirthDate(), "2026-10-01")), 200, "")

	item, ok := listed()[sam]
	if !ok || item["username"] != "sam_k" || item["displayName"] != "Sam" {
		t.Fatalf("a new member is not listed for others after onboarding: %v", item)
	}
	card := h.expect(h.call("GET", "/v1/users/"+sam+"/profile", anjali, ""), 200, "").data
	if card["locked"] != false || card["username"] != "sam_k" {
		t.Fatalf("a new member's profile is locked for a stranger: %v", card)
	}
	// Open does not mean exposed: the connection list is friends-only and nothing positional or private appears.
	for _, key := range []string{"email", "birthDate", "birthYear", "ageBand", "lastSeen"} {
		if _, found := card[key]; found {
			t.Fatalf("profile shows %s", key)
		}
	}
	// The counts are for everyone by default (the lists they summarise are not), and a member who just
	// opened the profile is already one of the visitors; nobody follows or has a story yet.
	if stats, ok := card["socialStats"].(map[string]any); !ok || stats["friends"] != float64(0) || stats["following"] != float64(0) || stats["followers"] != float64(0) || stats["stories"] != float64(0) || stats["visitors"] != float64(1) {
		t.Fatalf("a new member's counts: %v", card["socialStats"])
	}
	// A 25-year-old shows whole years of age to a member who may view the profile, and nothing else about it.
	if card["age"] != float64(25) {
		t.Fatalf("age on the profile: %v", card["age"])
	}
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM discovery_eligibility`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("eligibility rows %d (%v)", rows, err)
	}
	// Anyone may message and follow a new member without any friendship or approval.
	if got := h.expect(h.call("GET", "/v1/me/privacy", newcomer, ""), 200, "").data; got["messagesFrom"] != "everyone" || got["followPolicy"] != "everyone" {
		t.Fatalf("privacy %v", got)
	}
}

func TestSharedSpacesNeedNoEligibility(t *testing.T) {
	h := newOnboardingHarness(t)
	anjali, newcomer := h.login(alice), h.login(sam)
	h.finishProfile(newcomer, "sam_k", "Sam")
	// An adult, like Anjali: spaces are shared within an age band (see the age band tests).
	h.expect(h.call("POST", "/v1/me/onboarding/complete", newcomer, completeBody(memberBirthDate(), "2026-10-01")), 200, "")
	created := h.expect(h.call("POST", "/v1/spaces", newcomer, `{"kind":"community","title":"Study hall","description":"Quiet hours","visibility":"public","capacity":20,"timezone":"Asia/Kolkata"}`), 201, "").data
	id := created["spaceId"].(string)
	h.expect(h.call("PUT", "/v1/spaces/"+id+"/membership", anjali, `{}`), 200, "")
	seen := items(h.expect(h.call("GET", "/v1/spaces", anjali, ""), 200, "").data)
	if len(seen) != 1 || seen[0]["spaceId"] != id || seen[0]["myState"] != "active" {
		t.Fatalf("spaces %v", seen)
	}
	h.expect(h.call("POST", "/v1/spaces/"+id+"/entries", anjali, `{"body":"hello"}`), 201, "")
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM discovery_eligibility`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("eligibility rows %d (%v)", rows, err)
	}
}

func TestFirebaseSignInProvisionsAnOpenProfile(t *testing.T) {
	f := newFirebaseHarness(t)
	token := f.token(idToken{sub: "google-uid-open", provider: "google.com"})
	assertOpenDefaults(t, f.expect(f.call("GET", "/v1/me/privacy", token, ""), 200, "").data)
	var audience, discoverable string
	if err := f.db.Pool.QueryRow(f.ctx, `SELECT p.data->>'profileAudience',q.data->>'discoverable' FROM auth_identities a JOIN profiles p USING(user_id) JOIN privacy_settings q USING(user_id) WHERE a.subject='google-uid-open'`).Scan(&audience, &discoverable); err != nil || audience != "public" || discoverable != "true" {
		t.Fatalf("stored %q %q (%v)", audience, discoverable, err)
	}
}

// What the database holds for the fixtures is exactly the Go default, so the migration, provisioning and Seed agree.
func TestSeededPrivacyEqualsTheDefault(t *testing.T) {
	h := newOnboardingHarness(t)
	var raw []byte
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT data FROM privacy_settings WHERE user_id=$1`, alice).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var stored map[string]any
	_ = json.Unmarshal(raw, &stored)
	wantRaw, _ := json.Marshal(domain.DefaultPrivacy())
	var want map[string]any
	_ = json.Unmarshal(wantRaw, &want)
	if !reflect.DeepEqual(stored, want) {
		t.Fatalf("stored %v\nwant   %v", stored, want)
	}
}

// 0016 rewrites every existing privacy row to the open defaults and renames the age column. It runs in a
// scratch schema inside a rolled-back transaction, with the tables it touches recreated as they were before it.
func TestMigration0016OpensExistingAccountsAndCreatesLocations(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0016_open_profiles_nearby.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	closed := `{"profileAudience":"friends","messagesFrom":"everyone","followPolicy":"everyone","requestsFrom":"nobody","storyAudience":"public","activityAudience":"everyone","onlineAudience":"nobody","lastSeenAudience":"friends","locationAudience":"friends","commentsFrom":"nobody","mentionsFrom":"everyone","discoverable":false,"showInterestOverlap":false,"readReceipts":true,"customKey":"kept","fieldAudiences":{"pronouns":"nobody","location":"friends","profession":"nobody","education":"nobody","website":"nobody","timezone":"nobody","languages":"nobody","interests":"nobody","vibe":"nobody","connections":"everyone"}}`
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch`,
		`SET LOCAL search_path = migration_scratch`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`CREATE TABLE onboarding(user_id uuid PRIMARY KEY REFERENCES users(user_id), adult_declared_at timestamptz, terms_version text)`,
		`CREATE TABLE profiles(user_id uuid PRIMARY KEY REFERENCES users(user_id), data jsonb NOT NULL, version bigint NOT NULL DEFAULT 1, updated_at timestamptz NOT NULL DEFAULT now())`,
		`CREATE TABLE privacy_settings(user_id uuid PRIMARY KEY REFERENCES users(user_id), data jsonb NOT NULL, version bigint NOT NULL DEFAULT 1, updated_at timestamptz NOT NULL DEFAULT '2020-01-01')`,
		`CREATE TABLE discovery_eligibility(user_id uuid PRIMARY KEY REFERENCES users(user_id))`,
		`INSERT INTO users VALUES ('019a4000-0000-7000-8000-000000000b01'),('019a4000-0000-7000-8000-000000000b02')`,
		`INSERT INTO onboarding VALUES ('019a4000-0000-7000-8000-000000000b01','2024-05-06 07:08:09+00','2026-10-01'),('019a4000-0000-7000-8000-000000000b02',NULL,NULL)`,
		`INSERT INTO profiles VALUES ('019a4000-0000-7000-8000-000000000b01','{"displayName":"A","profileAudience":"friends","bio":"kept"}',3,'2020-01-01'),('019a4000-0000-7000-8000-000000000b02','{"displayName":"B"}',1,'2020-01-01')`,
		`INSERT INTO privacy_settings(user_id,data,version) VALUES ('019a4000-0000-7000-8000-000000000b01','` + closed + `',5),('019a4000-0000-7000-8000-000000000b02','{"profileAudience":"private"}',1)`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("migration: %v", err)
	}

	// The age column is renamed and keeps its value.
	var declared *time.Time
	if err = tx.QueryRow(ctx, `SELECT age_declared_at FROM onboarding WHERE user_id='019a4000-0000-7000-8000-000000000b01'`).Scan(&declared); err != nil || declared == nil || declared.UTC().Format(time.DateOnly) != "2024-05-06" {
		t.Fatalf("age_declared_at %v (%v)", declared, err)
	}
	var oldColumn bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='migration_scratch' AND table_name='onboarding' AND column_name='adult_declared_at')`).Scan(&oldColumn); err != nil || oldColumn {
		t.Fatalf("adult_declared_at still exists (%v)", err)
	}

	// Every privacy row equals the Go defaults on every default key, version bumped, other keys untouched.
	wantRaw, _ := json.Marshal(domain.DefaultPrivacy())
	var want map[string]any
	_ = json.Unmarshal(wantRaw, &want)
	// Migration 0017, not this one, adds the gender field audience.
	delete(want["fieldAudiences"].(map[string]any), "gender")
	delete(want["fieldAudiences"].(map[string]any), "age")    // and 0018 the age audience
	delete(want["fieldAudiences"].(map[string]any), "counts") // and 0019 the counts audience
	for _, field := range []string{"aboutMe", "hometown", "personality", "birthday"} {
		delete(want["fieldAudiences"].(map[string]any), field) // and 0048 the profile v2 audiences
	}
	for _, key := range []string{"showLocalTime", "showDistance", "visitorsVisibleToOthers", "showBirthday"} {
		delete(want, key) // and 0048 the v2 sharing settings
	}
	want["fieldAudiences"].(map[string]any)["connections"] = "friends" // 0026, not this one, opens it to followers
	// 0019 also made messaging and follows open; 0016 set the values that were the defaults then.
	want["messagesFrom"], want["followPolicy"] = "friends", "approval"
	for _, id := range []string{"019a4000-0000-7000-8000-000000000b01", "019a4000-0000-7000-8000-000000000b02"} {
		var raw []byte
		var version int64
		var updated time.Time
		if err = tx.QueryRow(ctx, `SELECT data,version,updated_at FROM privacy_settings WHERE user_id=$1`, id).Scan(&raw, &version, &updated); err != nil {
			t.Fatal(err)
		}
		var got map[string]any
		_ = json.Unmarshal(raw, &got)
		for key, value := range want {
			if key == "version" || key == "updatedAt" || key == "readReceipts" {
				continue
			}
			if !reflect.DeepEqual(got[key], value) {
				t.Fatalf("%s: %s is %v after the migration, want %v", id, key, got[key], value)
			}
		}
		if updated.Year() < 2026 {
			t.Fatalf("updated_at not bumped: %v", updated)
		}
		if id == "019a4000-0000-7000-8000-000000000b01" {
			if version != 6 || got["readReceipts"] != true || got["customKey"] != "kept" {
				t.Fatalf("version %d, readReceipts %v, customKey %v", version, got["readReceipts"], got["customKey"])
			}
		} else if version != 2 {
			t.Fatalf("version %d", version)
		}
	}
	// Profiles mirror the public audience and keep their own data.
	var audience, bio string
	var version int64
	if err = tx.QueryRow(ctx, `SELECT data->>'profileAudience',coalesce(data->>'bio',''),version FROM profiles WHERE user_id='019a4000-0000-7000-8000-000000000b01'`).Scan(&audience, &bio, &version); err != nil || audience != "public" || bio != "kept" || version != 4 {
		t.Fatalf("profile %q %q v%d (%v)", audience, bio, version, err)
	}
	if err = tx.QueryRow(ctx, `SELECT data->>'profileAudience' FROM profiles WHERE user_id='019a4000-0000-7000-8000-000000000b02'`).Scan(&audience); err != nil || audience != "public" {
		t.Fatalf("profile without an audience %q (%v)", audience, err)
	}

	// The retired table stays, flagged as retired, and nothing was copied into it.
	var comment *string
	if err = tx.QueryRow(ctx, `SELECT obj_description('migration_scratch.discovery_eligibility'::regclass,'pg_class')`).Scan(&comment); err != nil || comment == nil || !strings.HasPrefix(*comment, "Retired") {
		t.Fatalf("discovery_eligibility comment %v (%v)", comment, err)
	}

	// user_locations: one row per member, coordinates checked, indexes on position and age.
	insert := func(lat, lon any) error {
		_, e := tx.Exec(ctx, fmt.Sprintf(`SAVEPOINT s; INSERT INTO user_locations(user_id,latitude,longitude) VALUES('019a4000-0000-7000-8000-000000000b01',%v,%v)`, lat, lon))
		if e != nil {
			_, _ = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`)
		}
		return e
	}
	for _, bad := range [][2]any{{90.01, 0}, {-90.01, 0}, {0, 180.01}, {0, -180.01}} {
		if insert(bad[0], bad[1]) == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
	if err = insert(90, -180); err != nil {
		t.Fatal(err)
	}
	if insert(1, 1) == nil {
		t.Fatal("a second location row for one member was accepted")
	}
	var updated time.Time
	if err = tx.QueryRow(ctx, `SELECT updated_at FROM user_locations`).Scan(&updated); err != nil || time.Since(updated) > time.Minute {
		t.Fatalf("updated_at default %v (%v)", updated, err)
	}
	var indexes []string
	rows, err := tx.Query(ctx, `SELECT indexdef FROM pg_indexes WHERE schemaname='migration_scratch' AND tablename='user_locations' ORDER BY indexname`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var def string
		_ = rows.Scan(&def)
		indexes = append(indexes, def)
	}
	rows.Close()
	joined := strings.Join(indexes, "\n")
	if !strings.Contains(joined, "(latitude, longitude)") || !strings.Contains(joined, "(updated_at)") {
		t.Fatalf("indexes:\n%s", joined)
	}
	// Deleting the member removes the point with it.
	for _, table := range []string{"onboarding", "profiles", "privacy_settings"} {
		if _, err = tx.Exec(ctx, `DELETE FROM `+table+` WHERE user_id='019a4000-0000-7000-8000-000000000b01'`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, `DELETE FROM users WHERE user_id='019a4000-0000-7000-8000-000000000b01'`); err != nil {
		t.Fatal(err)
	}
	var left int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM user_locations`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("%d locations outlive their member (%v)", left, err)
	}
	_ = tx.Rollback(ctx)
	var exists bool
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch.user_locations') IS NOT NULL`).Scan(&exists); err != nil || exists {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}

// 0017 adds the gender audience to every existing privacy row without disturbing anything else, and creates the
// private birth date table with its checks. It runs in a scratch schema inside a rolled-back transaction.
func TestMigration0017AddsGenderAudienceAndMemberAges(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0017_member_ages_and_gender.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_17`,
		`SET LOCAL search_path = migration_scratch_17`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`CREATE TABLE blocks(blocker_id uuid NOT NULL, blocked_id uuid NOT NULL)`,
		`CREATE TABLE privacy_settings(user_id uuid PRIMARY KEY REFERENCES users(user_id), data jsonb NOT NULL, version bigint NOT NULL DEFAULT 1, updated_at timestamptz NOT NULL DEFAULT '2020-01-01')`,
		`INSERT INTO users VALUES ('019a4000-0000-7000-8000-000000000c01'),('019a4000-0000-7000-8000-000000000c02'),('019a4000-0000-7000-8000-000000000c03')`,
		`INSERT INTO privacy_settings(user_id,data,version) VALUES
 ('019a4000-0000-7000-8000-000000000c01','{"profileAudience":"public","customKey":"kept","fieldAudiences":{"pronouns":"nobody","vibe":"friends"}}',4),
 ('019a4000-0000-7000-8000-000000000c02','{"profileAudience":"public","fieldAudiences":{"gender":"friends","vibe":"everyone"}}',7),
 ('019a4000-0000-7000-8000-000000000c03','{"profileAudience":"friends"}',1)`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("migration: %v", err)
	}
	// 0021 renames the setting the isolation switch is read from.
	rename, err := os.ReadFile("../../../../database/migrations/0021_rename_isolation_setting.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, string(rename)); err != nil {
		t.Fatalf("migration 0021: %v", err)
	}
	audiences := func(id string) (string, any, int64) {
		var raw []byte
		var version int64
		if err := tx.QueryRow(ctx, `SELECT data,version FROM privacy_settings WHERE user_id=$1`, id).Scan(&raw, &version); err != nil {
			t.Fatal(err)
		}
		var data map[string]any
		_ = json.Unmarshal(raw, &data)
		fields, _ := data["fieldAudiences"].(map[string]any)
		return fmt.Sprint(fields), data["customKey"], version
	}
	// Added where missing, version bumped, other fields and keys untouched.
	if fields, custom, version := audiences("019a4000-0000-7000-8000-000000000c01"); fields != "map[gender:everyone pronouns:nobody vibe:friends]" || custom != "kept" || version != 5 {
		t.Fatalf("row 1: %s %v v%d", fields, custom, version)
	}
	// A row that already chose an audience for it keeps it, and its version is left alone.
	if fields, _, version := audiences("019a4000-0000-7000-8000-000000000c02"); fields != "map[gender:friends vibe:everyone]" || version != 7 {
		t.Fatalf("row 2: %s v%d", fields, version)
	}
	// A row with no field audiences at all gets the one.
	if fields, _, version := audiences("019a4000-0000-7000-8000-000000000c03"); fields != "map[gender:everyone]" || version != 2 {
		t.Fatalf("row 3: %s v%d", fields, version)
	}

	// member_ages: private table, one row per member, no future dates, removed with the member.
	if _, err = tx.Exec(ctx, `INSERT INTO member_ages(user_id,birth_date) VALUES('019a4000-0000-7000-8000-000000000c01','2010-05-06')`); err != nil {
		t.Fatal(err)
	}
	var created time.Time
	if err = tx.QueryRow(ctx, `SELECT created_at FROM member_ages`).Scan(&created); err != nil || time.Since(created) > time.Minute {
		t.Fatalf("created_at default %v (%v)", created, err)
	}
	for _, statement := range []string{
		`SAVEPOINT s; INSERT INTO member_ages(user_id,birth_date) VALUES('019a4000-0000-7000-8000-000000000c01','2011-01-01')`,
		`SAVEPOINT s; INSERT INTO member_ages(user_id,birth_date) VALUES('019a4000-0000-7000-8000-000000000c02',current_date+1)`,
		`SAVEPOINT s; INSERT INTO member_ages(user_id,birth_date) VALUES('019a4000-0000-7000-8000-000000000c02',NULL)`,
		`SAVEPOINT s; INSERT INTO member_ages(user_id,birth_date) VALUES('019a4000-0000-7000-8000-0000000fffff','2000-01-01')`,
	} {
		if _, err = tx.Exec(ctx, statement); err == nil {
			t.Fatalf("accepted: %s", statement)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
	}
	var age *int
	var band string
	if err = tx.QueryRow(ctx, `SELECT member_age('019a4000-0000-7000-8000-000000000c01'),age_band('019a4000-0000-7000-8000-000000000c01')`).Scan(&age, &band); err != nil || age == nil || band != "minor" {
		t.Fatalf("functions: age %v band %s (%v)", age, band, err)
	}
	if err = tx.QueryRow(ctx, `SELECT member_age('019a4000-0000-7000-8000-000000000c02'),age_band('019a4000-0000-7000-8000-000000000c02')`).Scan(&age, &band); err != nil || age != nil || band != "adult" {
		t.Fatalf("unknown age: %v %s (%v)", age, band, err)
	}
	// The isolation switch is read from the session: on by default, off only when set to 'off'.
	barred := func() bool {
		var b bool
		if err := tx.QueryRow(ctx, `SELECT interaction_barred('019a4000-0000-7000-8000-000000000c01','019a4000-0000-7000-8000-000000000c02')`).Scan(&b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	if !barred() {
		t.Fatal("a minor and an adult are not barred by default")
	}
	for setting, want := range map[string]bool{"off": false, "on": true, "false": true, "": true} {
		if _, err = tx.Exec(ctx, `SELECT set_config('hiyall.age_band_isolation',$1,true)`, setting); err != nil {
			t.Fatal(err)
		}
		if barred() != want {
			t.Fatalf("setting %q: barred=%v, want %v", setting, !want, want)
		}
	}
	if _, err = tx.Exec(ctx, `DELETE FROM member_ages WHERE user_id='019a4000-0000-7000-8000-000000000c01'`); err != nil {
		t.Fatal(err)
	}
	_ = tx.Rollback(ctx)
	var exists bool
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_17.member_ages') IS NOT NULL`).Scan(&exists); err != nil || exists {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
