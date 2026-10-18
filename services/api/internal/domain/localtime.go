package domain

import (
	"fmt"
	"time"
	_ "time/tzdata" // zone data travels with the binary: a minimal container image has none
)

// LocalTime is the member's local time zone as seen at one moment, for "it's 3:42 PM there". The server
// computes the offset from the stored IANA zone (so daylight saving is right today); the app adds it to its
// own clock and ticks once a minute. The zone name itself is never sent here.
type LocalTime struct {
	// UTCOffsetMinutes is the offset from UTC now, in minutes (+330 for India, -240 for New York in summer).
	UTCOffsetMinutes int `json:"utcOffsetMinutes"`
	// Label is the offset written for people: "UTC+5:30", "UTC-4", "UTC".
	Label string `json:"label"`
}

// LocalTimeFor is the local time of zone at now, or nil when the zone is empty, "Local" or unknown (the
// response then simply has no localTime rather than a wrong one).
func LocalTimeFor(zone string, now time.Time) *LocalTime {
	if zone == "" || zone == "Local" {
		return nil
	}
	loc, err := time.LoadLocation(zone)
	if err != nil {
		return nil
	}
	_, offset := now.In(loc).Zone()
	minutes := offset / 60
	return &LocalTime{UTCOffsetMinutes: minutes, Label: OffsetLabel(minutes)}
}

// OffsetLabel writes an offset in minutes as "UTC", "UTC+2" or "UTC+5:30".
func OffsetLabel(minutes int) string {
	if minutes == 0 {
		return "UTC"
	}
	sign := "+"
	if minutes < 0 {
		sign, minutes = "-", -minutes
	}
	if minutes%60 == 0 {
		return fmt.Sprintf("UTC%s%d", sign, minutes/60)
	}
	return fmt.Sprintf("UTC%s%d:%02d", sign, minutes/60, minutes%60)
}
