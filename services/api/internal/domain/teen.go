package domain

import (
	"encoding/json"
	"math"
	"time"
)

// Teen safety and abuse limits (docs/architecture/18-teen-safety.md): daily caps on social actions
// and on reading the member base, the locked privacy settings of members under AdultAge, the
// refusal of age and gender filters for them, and the age gate's cooldown.

// Daily counter kinds (member_daily_counts.kind). The count is per UTC calendar day.
const (
	DailyFollows         = "follow"
	DailyFriendRequests  = "friend_request"
	DailyComments        = "comment"
	DailySpaces          = "space"
	DailySpaceEntries    = "space_entry"
	DailySearchPages     = "search_page"
	DailyProfileViews    = "profile_view"
	DailyNearbyQueries   = "nearby_query"
	DailyLocationChanges = "location_change"
)

// DailyLimitError is the refusal when a daily cap is used up. Every kind has its own message; the code is
// the same so a client can treat them alike. It is sent with Retry-After (the next UTC midnight).
var dailyLimitErrors = map[string]*PolicyError{
	DailyFollows:         {429, "DAILY_LIMIT", "You’ve followed a lot of people today. Try again tomorrow."},
	DailyFriendRequests:  {429, "DAILY_LIMIT", "You’ve sent a lot of friend requests today. Try again tomorrow."},
	DailyComments:        {429, "DAILY_LIMIT", "You’ve commented a lot today. Try again tomorrow."},
	DailySpaces:          {429, "DAILY_LIMIT", "You’ve created enough spaces for today. Try again tomorrow."},
	DailySpaceEntries:    {429, "DAILY_LIMIT", "You’ve posted a lot in spaces today. Try again tomorrow."},
	DailySearchPages:     {429, "DAILY_LIMIT", "You’ve searched a lot today. Try again tomorrow."},
	DailyProfileViews:    {429, "DAILY_LIMIT", "You’ve opened a lot of profiles today. Try again tomorrow."},
	DailyNearbyQueries:   {429, "DAILY_LIMIT", "You’ve looked at Nearby a lot today. Try again tomorrow."},
	DailyLocationChanges: {429, "DAILY_LIMIT", "Your Nearby area has changed a lot today. Try again tomorrow."},
}

// DailyLimitError is the refusal for kind, lifting after wait.
func DailyLimitError(kind string, wait time.Duration) error {
	p, ok := dailyLimitErrors[kind]
	if !ok {
		p = &PolicyError{429, "DAILY_LIMIT", "You’ve reached today’s limit. Try again tomorrow."}
	}
	return RetryAfter(p, wait)
}

// UntilNextUTCDay is how long until the daily counters start again.
func UntilNextUTCDay(now time.Time) time.Duration {
	now = now.UTC()
	next := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, time.UTC)
	return next.Sub(now)
}

var (
	// ErrFilterNotAvailable refuses age and gender filters for a viewer under AdultAge.
	ErrFilterNotAvailable = &PolicyError{422, "FILTER_NOT_AVAILABLE", "Age and gender filters aren’t available for members under 18."}
	// ErrMinorSettingLocked refuses loosening a setting that stays private for members under AdultAge.
	ErrMinorSettingLocked = &PolicyError{422, "MINOR_SETTING_LOCKED", "This setting stays more private for members under 18."}
	// ErrAgeGateCooldown refuses onboarding for an identity that declared an age under MinimumAge recently.
	ErrAgeGateCooldown = &PolicyError{403, "AGE_GATE_COOLDOWN", "You can’t finish signing up right now. Thanks for understanding."}
	// ErrNearbyOff refuses a location from a member who has not turned on "Show me in Nearby".
	ErrNearbyOff = &PolicyError{409, "NEARBY_OFF", "Turn on Show me in Nearby first."}
	// ErrLocationJump refuses a location too far from the last one for the time between them.
	ErrLocationJump = &PolicyError{422, "LOCATION_IMPLAUSIBLE", "That location is too far from your last one. Try again later."}
)

// AgeGateCooldown is how long an identity that declared an age under MinimumAge is refused onboarding.
const AgeGateCooldown = 7 * 24 * time.Hour

// privacyRank orders audiences from most open to most private. A minor may only move a locked setting
// to the same or a more private value than their default.
var privacyRank = map[string]int{"everyone": 0, "followers": 1, "friends": 2, "nobody": 3}

// minorLocked are the settings of a member under AdultAge that cannot be loosened past these values:
// presence, the location audience, and the country ("location") and connections fields.
var minorLocked = map[string]string{"onlineAudience": MinorOnlineAudience, "locationAudience": "nobody"}
var minorLockedFields = map[string]string{"location": MinorLocationFieldAudience, "connections": MinorConnectionsAudience}

// ValidateMinorPrivacyPatch refuses a privacy patch (already validated by ValidatePrivacyPatch) that
// would make a locked setting of a member under AdultAge more open than its minor default.
func ValidateMinorPrivacyPatch(patch map[string]json.RawMessage) error {
	for name, floor := range minorLocked {
		raw, ok := patch[name]
		if !ok {
			continue
		}
		var value string
		if json.Unmarshal(raw, &value) != nil || privacyRank[value] < privacyRank[floor] {
			return ErrMinorSettingLocked
		}
	}
	if raw, ok := patch["fieldAudiences"]; ok {
		var values map[string]string
		if json.Unmarshal(raw, &values) != nil {
			return ErrMinorSettingLocked
		}
		for field, floor := range minorLockedFields {
			if value, ok := values[field]; ok && privacyRank[value] < privacyRank[floor] {
				return ErrMinorSettingLocked
			}
		}
	}
	return nil
}

// Nearby location hardening.
const (
	// NearbyOffsetKm and MinorNearbyOffsetKm are the radius of the per-member daily random offset added to
	// a shared point before it is rounded and stored. It changes every UTC day, so the stored point is
	// not the member's grid cell and an attacker who narrows it down learns only that day's offset point.
	NearbyOffsetKm      = 2.0
	MinorNearbyOffsetKm = 5.0
	// MaxTravelKmh is the fastest a member's shared point may move between two writes. JumpToleranceKm
	// absorbs the grid and the offset (which changes daily).
	MaxTravelKmh    = 1000.0
	JumpToleranceKm = 30.0
)

// Offset is a displacement on the ground, in km.
type Offset struct{ NorthKm, EastKm float64 }

// RandomOffset is a point uniformly distributed in a disc of radiusKm, from two uniform values in [0,1).
func RandomOffset(radiusKm, u, v float64) Offset {
	r := radiusKm * math.Sqrt(u)
	theta := 2 * math.Pi * v
	return Offset{NorthKm: r * math.Cos(theta), EastKm: r * math.Sin(theta)}
}

// Shift moves a point by an offset, keeping it on the globe: latitude is clamped and longitude wraps.
func (l Location) Shift(o Offset) Location {
	const kmPerDegree = 2 * math.Pi * EarthRadiusKm / 360
	lat := math.Max(-90, math.Min(90, l.Latitude+o.NorthKm/kmPerDegree))
	cos := math.Cos(lat * math.Pi / 180)
	lon := l.Longitude
	if cos > 1e-6 {
		lon += o.EastKm / (kmPerDegree * cos)
	}
	for lon > 180 {
		lon -= 360
	}
	for lon < -180 {
		lon += 360
	}
	return Location{lat, lon}
}

// ImplausibleJump reports whether moving from prev to next in elapsed is faster than MaxTravelKmh,
// after allowing JumpToleranceKm for the grid and the offset.
func ImplausibleJump(prev, next Location, elapsed time.Duration) bool {
	km := HaversineKm(prev, next) - JumpToleranceKm
	if km <= 0 {
		return false
	}
	return km > MaxTravelKmh*math.Max(elapsed.Hours(), 0)
}

// UsesAgeOrGender reports whether the filters ask for an age range or a gender.
func (f PeopleFilters) UsesAgeOrGender() bool {
	return f.AgeMin != nil || f.AgeMax != nil || f.Gender != ""
}
