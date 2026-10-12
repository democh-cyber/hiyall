package httpapi

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// Story looks and lifetimes (docs/api/16-pulse-and-media.md#stories).

func (h *socialHarness) storyWith(user string, fields map[string]any) reply {
	h.t.Helper()
	h.api.content.reset(user)
	if _, ok := fields["audience"]; !ok {
		fields["audience"] = "public"
	}
	return h.send(user, "POST", "/v1/stories", fields)
}

// lifetimeOf is how long from creation a story was given, to the second.
func (h *socialHarness) lifetimeOf(id string) time.Duration {
	h.t.Helper()
	var seconds float64
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT extract(epoch FROM expires_at-created_at) FROM stories WHERE story_id=$1`, id).Scan(&seconds); err != nil {
		h.t.Fatal(err)
	}
	return time.Duration(seconds * float64(time.Second)).Round(time.Minute)
}

func TestStoryTextStyleAndBackgroundAreStoredAndValidated(t *testing.T) {
	h := newSocialHarness(t)
	// An old client sends neither a text style nor a lifetime: clean, lime, 24 hours.
	old := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "gm", "audience": "public"}), 201, "").data["storyId"].(string)
	var style, background string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT text_style,background FROM stories WHERE story_id=$1`, old).Scan(&style, &background); err != nil || style != "clean" || background != "lime" {
		t.Fatalf("defaults %q %q (%v)", style, background, err)
	}
	if got := h.lifetimeOf(old); got != 24*time.Hour {
		t.Fatalf("default lifetime %v", got)
	}
	for _, name := range domain.StoryBackgroundNames {
		h.expect(h.storyWith(bob, map[string]any{"body": "x", "background": name}), 201, "")
		h.api.content.reset(bob)
	}
	for _, name := range domain.StoryTextStyleNames {
		h.expect(h.storyWith(cara, map[string]any{"body": "x", "textStyle": name}), 201, "")
	}
	for _, bad := range []map[string]any{
		{"body": "x", "background": "neon"},
		{"body": "x", "background": "Sunset"},
		{"body": "x", "textStyle": "comic"},
		{"body": "x", "textStyle": ""},
		{"body": "x", "textStyle": 5},
	} {
		got := h.storyWith(dev, bad)
		if bad["textStyle"] == "" { // an empty value is "not sent"
			h.expect(got, 201, "")
			continue
		}
		h.expect(got, 422, "VALIDATION")
	}
	if n := h.countOf(`SELECT count(*) FROM stories WHERE author_id=$1`, dev); n != 1 {
		t.Fatalf("a refused story was stored: %d", n)
	}
}

func TestStoryTextStyleRoundTripsInEveryListing(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(alice, "followPolicy", "everyone")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.expect(h.storyWith(alice, map[string]any{"body": "neon", "background": "midnight", "textStyle": "glow"}), 201, "")
	// A story from before the column existed has the plain default.
	h.exec(`INSERT INTO stories(story_id,author_id,body,audience,expires_at) VALUES('019a4000-0000-7000-8000-0000000000aa',$1,'old','public',now()+interval '1 hour')`, alice)

	check := func(where string, rows []map[string]any) {
		t.Helper()
		got := map[string]string{}
		for _, r := range rows {
			got[r["body"].(string)] = r["textStyle"].(string) + "/" + r["background"].(string)
		}
		if len(got) != 2 || got["neon"] != "glow/midnight" || got["old"] != "clean/lime" {
			t.Fatalf("%s: %v", where, got)
		}
	}
	check("my stories", items(h.ok(alice, "GET", "/v1/me/stories")))
	check("user stories", items(h.ok(bob, "GET", "/v1/users/"+alice+"/stories")))
	var tray []map[string]any
	for _, g := range items(h.ok(bob, "GET", "/v1/stories/tray")) {
		for _, s := range g["stories"].([]any) {
			tray = append(tray, s.(map[string]any))
		}
	}
	check("tray", tray)
	var own []map[string]any
	for _, s := range items(h.ok(alice, "GET", "/v1/stories/tray"))[0]["stories"].([]any) {
		own = append(own, s.(map[string]any))
	}
	check("own tray", own)
}

func TestStoryLifetimeHours(t *testing.T) {
	h := newSocialHarness(t)
	for _, hours := range []int{6, 12, 24} {
		id := h.expect(h.storyWith(alice, map[string]any{"body": "x", "lifetimeHours": hours}), 201, "").data["storyId"].(string)
		if got := h.lifetimeOf(id); got != time.Duration(hours)*time.Hour {
			t.Fatalf("%d hours stored as %v", hours, got)
		}
	}
	// expiresAt is what clients show the time left from: it follows the choice.
	short := h.expect(h.storyWith(alice, map[string]any{"body": "short", "lifetimeHours": 6}), 201, "").data["storyId"].(string)
	for _, s := range items(h.ok(alice, "GET", "/v1/me/stories")) {
		if s["storyId"] != short {
			continue
		}
		created, _ := time.Parse(time.RFC3339Nano, s["createdAt"].(string))
		expires, _ := time.Parse(time.RFC3339Nano, s["expiresAt"].(string))
		if d := expires.Sub(created).Round(time.Minute); d != 6*time.Hour {
			t.Fatalf("expiresAt-createdAt = %v", d)
		}
	}
	before := h.countOf(`SELECT count(*) FROM stories WHERE author_id=$1`, alice)
	for _, bad := range []any{48, 72, 0, 1, 5, 7, -6, 6.5, "6", 100000} {
		h.expect(h.storyWith(alice, map[string]any{"body": "x", "lifetimeHours": bad}), 422, "VALIDATION")
	}
	if n := h.countOf(`SELECT count(*) FROM stories WHERE author_id=$1`, alice); n != before {
		t.Fatalf("a refused lifetime stored a story (%d, was %d)", n, before)
	}
	// The refusal names what is offered and is not a quota (nothing was used up).
	got := h.storyWith(alice, map[string]any{"body": "x", "lifetimeHours": 48})
	if got.status != 422 || got.code != "VALIDATION" {
		t.Fatalf("%d %s", got.status, got.code)
	}
	// A short story leaves the tray when it has run out.
	h.exec(`UPDATE stories SET expires_at=now()-interval '1 minute' WHERE story_id=$1`, short)
	for _, s := range items(h.ok(alice, "GET", "/v1/me/stories")) {
		if s["storyId"] == short {
			t.Fatal("an expired story is listed")
		}
	}
}

func TestStoryLifetimesComeFromTheEntitlementsResolver(t *testing.T) {
	h := newSocialHarness(t)
	big := domain.Free()
	big.StoryLifetimes = []int{6, 12, 24, 48}
	tiny := domain.Free()
	tiny.StoryLifetimes = []int{24}
	h.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		switch user {
		case alice:
			return big
		case bob:
			return tiny
		}
		return domain.Free()
	}
	id := h.expect(h.storyWith(alice, map[string]any{"body": "two days", "lifetimeHours": 48}), 201, "").data["storyId"].(string)
	if got := h.lifetimeOf(id); got != 48*time.Hour {
		t.Fatalf("a tier that offers 48 hours got %v", got)
	}
	// Free refuses the same request.
	h.expect(h.storyWith(cara, map[string]any{"body": "two days", "lifetimeHours": 48}), 422, "VALIDATION")
	h.expect(h.storyWith(cara, map[string]any{"body": "a day", "lifetimeHours": 24}), 201, "")
	// A tier with fewer choices is held to them; leaving it out is still a day.
	h.expect(h.storyWith(bob, map[string]any{"body": "x", "lifetimeHours": 6}), 422, "VALIDATION")
	h.expect(h.storyWith(bob, map[string]any{"body": "x"}), 201, "")
	// The refusal comes before the quota is touched.
	h.addStories(cara, 29, "1 hour", false)
	h.expect(h.storyWith(cara, map[string]any{"body": "x", "lifetimeHours": 48}), 422, "VALIDATION")
}

// Migration 0027 on top of 0010: existing stories get the plain style; the shape check refuses odd names.
func TestMigration0027StoryStyle(t *testing.T) {
	ctx, db := connectTestDB(t)
	pulse, err := os.ReadFile("../../../../database/migrations/0010_pulse.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../../../../database/migrations/0027_story_style.sql")
	if err != nil {
		t.Fatal(err)
	}
	table := func(name string) string {
		start := strings.Index(string(pulse), "CREATE TABLE IF NOT EXISTS "+name+" (")
		if start < 0 {
			t.Fatalf("%s not found in 0010", name)
		}
		return string(pulse)[start : start+strings.Index(string(pulse)[start:], "\n);")+3]
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	const owner = "019a4000-0000-7000-8000-000000000f41"
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_27`,
		`SET LOCAL search_path = migration_scratch_27`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`INSERT INTO users VALUES ('` + owner + `')`,
		table("media_assets"),
		table("stories"),
		`INSERT INTO stories(story_id,author_id,body,audience,expires_at) VALUES (gen_random_uuid(),'` + owner + `','old','public',now()+interval '1 hour')`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	for run := 0; run < 2; run++ { // applying it again changes nothing
		if _, err = tx.Exec(ctx, string(migration)); err != nil {
			t.Fatalf("migration run %d: %v", run+1, err)
		}
	}
	var style string
	if err = tx.QueryRow(ctx, `SELECT text_style FROM stories`).Scan(&style); err != nil || style != "clean" {
		t.Fatalf("existing story style %q (%v)", style, err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO stories(story_id,author_id,body,audience,text_style,expires_at) VALUES (gen_random_uuid(),'`+owner+`','x','public','glow',now())`); err != nil {
		t.Fatalf("a style name was refused: %v", err)
	}
	for _, bad := range []string{"", "Glow", "glow!", "a-very-long-style-name-that-is-too-long"} {
		if _, err = tx.Exec(ctx, `SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, `INSERT INTO stories(story_id,author_id,body,audience,text_style,expires_at) VALUES (gen_random_uuid(),'`+owner+`','x','public',$1,now())`, bad); err == nil {
			t.Fatalf("text_style %q was accepted", bad)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	var applied, leaked bool
	if err = db.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0027_story_style.sql')`).Scan(&applied); err != nil || !applied {
		t.Fatalf("0027 not applied: %v", err)
	}
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_27.stories') IS NOT NULL`).Scan(&leaked); err != nil || leaked {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
