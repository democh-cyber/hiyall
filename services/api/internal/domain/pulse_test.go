package domain

import (
	"strings"
	"testing"
	"time"
)

func TestParseStoryDefaultsAndOldClients(t *testing.T) {
	// A client from before text styles and lifetimes sends neither and gets the old behaviour.
	s, err := ParseStory([]byte(`{"body":" gm ","audience":"friends"}`))
	if err != nil || s.Body != "gm" || s.Background != "lime" || s.TextStyle != "clean" || s.LifetimeHours != nil || s.Lifetime() != StoryLifetime {
		t.Fatalf("%+v %v", s, err)
	}
	s, err = ParseStory([]byte(`{"body":"","background":"ink","mediaId":"019a4000-0000-7000-8000-000000000001","audience":"public"}`))
	if err != nil || s.Background != "ink" || s.TextStyle != "clean" {
		t.Fatalf("%+v %v", s, err)
	}
	s, err = ParseStory([]byte(`{"body":"x","background":"sunset","textStyle":"glow","lifetimeHours":6,"audience":"public"}`))
	if err != nil || s.Background != "sunset" || s.TextStyle != "glow" || s.Lifetime() != 6*time.Hour {
		t.Fatalf("%+v %v", s, err)
	}
}

func TestStoryBackgroundAndTextStyleAllowlists(t *testing.T) {
	for _, name := range []string{"lime", "lilac", "pink", "mint", "peach", "ink", "sunset", "bubblegum", "aurora", "ocean", "grape", "mango", "midnight", "freshmint"} {
		if _, err := ParseStory([]byte(`{"body":"x","background":"` + name + `","audience":"public"}`)); err != nil {
			t.Fatalf("background %s: %v", name, err)
		}
	}
	for _, name := range []string{"clean", "loud", "soft", "glow", "stamp", "type"} {
		if _, err := ParseStory([]byte(`{"body":"x","textStyle":"` + name + `","audience":"public"}`)); err != nil {
			t.Fatalf("text style %s: %v", name, err)
		}
	}
	for field, bad := range map[string][]string{
		"background": {"Lime", "neon", "lime ", "sunset2", "../x"},
		"textStyle":  {"Clean", "comic", "glow ", "bold!"},
	} {
		for _, value := range bad {
			_, err := ParseStory([]byte(`{"body":"x","` + field + `":"` + value + `","audience":"public"}`))
			if v, ok := err.(*ValidationError); !ok || v.Field != field {
				t.Fatalf("%s %q: %v", field, value, err)
			}
		}
	}
	if len(StoryBackgroundNames) != 14 || len(StoryTextStyleNames) != 6 {
		t.Fatalf("%d backgrounds, %d styles", len(StoryBackgroundNames), len(StoryTextStyleNames))
	}
}

func TestParseStoryLifetimeShape(t *testing.T) {
	for _, ok := range []string{`6`, `12`, `24`, `48`} {
		if _, err := ParseStory([]byte(`{"body":"x","lifetimeHours":` + ok + `,"audience":"public"}`)); err != nil {
			t.Fatalf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{`0`, `-6`, `6.5`, `"6"`, `99999999`, `true`, `[6]`} {
		_, err := ParseStory([]byte(`{"body":"x","lifetimeHours":` + bad + `,"audience":"public"}`))
		if err == nil {
			t.Fatalf("lifetimeHours %s accepted", bad)
		}
	}
	// null is the same as leaving it out.
	if s, err := ParseStory([]byte(`{"body":"x","lifetimeHours":null,"audience":"public"}`)); err != nil || s.Lifetime() != StoryLifetime {
		t.Fatalf("%+v %v", s, err)
	}
}

func TestStoryLifetimesComeFromEntitlements(t *testing.T) {
	free := Free()
	for _, h := range []int{6, 12, 24} {
		if !free.AllowsStoryLifetime(h) {
			t.Fatalf("Free refuses %d hours", h)
		}
	}
	for _, h := range []int{0, 1, 5, 7, 48, 72, -6} {
		if free.AllowsStoryLifetime(h) {
			t.Fatalf("Free allows %d hours", h)
		}
	}
	// A bigger tier is data, not code: it only lists more hours.
	big := Free()
	big.StoryLifetimes = []int{6, 12, 24, 48}
	if !big.AllowsStoryLifetime(48) || free.AllowsStoryLifetime(48) {
		t.Fatal("a tier that offers 48 hours must not change Free")
	}
	if EntitlementsFor("nonsense").AllowsStoryLifetime(48) {
		t.Fatal("an unknown plan can only restrict")
	}
	if msg := StoryLifetimeError(free.StoryLifetimes).Error(); !strings.Contains(msg, "6, 12 or 24 hours") {
		t.Fatalf("message %q", msg)
	}
}
