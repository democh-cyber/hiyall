package domain

import (
	"testing"
	"time"
)

func TestResolvePresence(t *testing.T) {
	now := time.Date(2026, 10, 13, 14, 23, 41, 0, time.UTC)
	at := func(ago time.Duration) *time.Time { v := now.Add(-ago); return &v }
	bucket := func(day, h, m int) *time.Time { v := time.Date(2026, 10, day, h, m, 0, 0, time.UTC); return &v }
	cases := []struct {
		name string
		live bool
		last *time.Time
		want Presence
	}{
		{"connected without a session", true, nil, Presence{Online: true}},
		{"connected with a stale session", true, at(48 * time.Hour), Presence{Online: true}},
		{"no session and not connected", false, nil, Presence{}},
		{"active just now", false, at(0), Presence{Online: true}},
		{"active a minute ago", false, at(time.Minute), Presence{Online: true}},
		{"exactly at the window", false, at(PresenceOnlineWindow), Presence{Online: true}},
		{"a moment past the window", false, at(PresenceOnlineWindow + time.Second), Presence{LastSeenAt: bucket(13, 14, 20)}},
		{"clock skew counts as now", false, at(-time.Hour), Presence{Online: true}},
		{"rounded down to five minutes", false, at(17*time.Minute + 30*time.Second), Presence{LastSeenAt: bucket(13, 14, 5)}},
		{"on a bucket edge", false, at(18*time.Minute + 41*time.Second), Presence{LastSeenAt: bucket(13, 14, 5)}},
		{"yesterday", false, at(24 * time.Hour), Presence{LastSeenAt: bucket(12, 14, 20)}},
	}
	for _, tc := range cases {
		got := ResolvePresence(tc.live, tc.last, now)
		if got.Online != tc.want.Online || (got.LastSeenAt == nil) != (tc.want.LastSeenAt == nil) || (got.LastSeenAt != nil && !got.LastSeenAt.Equal(*tc.want.LastSeenAt)) {
			t.Errorf("%s: got %+v, want %+v", tc.name, got, tc.want)
		}
	}
}

func TestLastSeenBucketIsFiveMinutesInUTC(t *testing.T) {
	zone := time.FixedZone("IST", 5*3600+1800)
	local := time.Date(2026, 10, 13, 19, 58, 59, 999, zone) // 14:28:59 UTC
	got := LastSeenBucket(local)
	if got.Location() != time.UTC || !got.Equal(time.Date(2026, 10, 13, 14, 25, 0, 0, time.UTC)) {
		t.Fatalf("bucket %v", got)
	}
	if PresenceOnlineWindow != 2*time.Minute || PresenceLastSeenBucket != 5*time.Minute {
		t.Fatal("presence constants changed: the app copy and docs describe 2 and 5 minutes")
	}
}
