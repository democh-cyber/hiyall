package domain

import (
	"encoding/json"
	"testing"
	"time"
)

func TestParseSpaceValidatesZoneTextAndSchedule(t *testing.T) {
	in := map[string]any{"kind": "moment", "title": "One song", "visibility": "public", "capacity": 20, "timezone": "Asia/Kolkata", "startsAt": time.Now().Add(time.Hour), "endsAt": time.Now().Add(2 * time.Hour)}
	parse := func() error { raw, _ := json.Marshal(in); _, e := ParseSpace(raw); return e }
	if e := parse(); e != nil {
		t.Fatal(e)
	}
	for _, zone := range []string{"Local", "../etc/passwd", "Invalid/Zone"} {
		in["timezone"] = zone
		if parse() == nil {
			t.Fatalf("accepted zone %q", zone)
		}
	}
	in["timezone"] = "UTC"
	in["title"] = "bad\x00title"
	if parse() == nil {
		t.Fatal("accepted NUL")
	}
	in["title"] = "One song"
	in["endsAt"] = time.Now().Add(26 * time.Hour)
	if parse() == nil {
		t.Fatal("accepted oversized Moment")
	}
	in["endsAt"] = time.Now().Add(-time.Hour)
	if parse() == nil {
		t.Fatal("accepted past end")
	}
	in["endsAt"] = time.Now().Add(2 * time.Hour)
	in["unknown"] = true
	if parse() == nil {
		t.Fatal("accepted unknown field")
	}
}
