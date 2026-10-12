package domain

import "time"

// Age bands. Hiyall is for everyone from MinimumAge up, and members under 18 and
// adults share the platform, so they are kept apart: a minor and an adult do not
// see or reach each other anywhere (people search, Nearby, profiles, follows,
// friend requests, chat, the feed, spaces). The barrier is the SQL function
// interaction_barred (migration 0017) and behaves exactly like a block, so a
// cross-band attempt looks like the other member does not exist and nothing about
// it reveals age. AGE_BAND_ISOLATION=false turns the barrier off (block-only).
//
// A member's band comes from the birth date they declared at onboarding, stored
// privately in member_ages. It is self-declared and can be falsified. A member with
// no stored birth date (accounts from before it was kept) counts as an adult.

// AdultAge is the age at which a member moves from the minor band to the adult band.
// The SQL function age_band uses the same number.
const AdultAge = 18

const (
	BandMinor = "minor"
	BandAdult = "adult"
)

// BandAt is the band of someone born on birth, as of now (UTC calendar dates).
func BandAt(birth, now time.Time) string {
	if AgeAt(birth, now.UTC()) < AdultAge {
		return BandMinor
	}
	return BandAdult
}

// Protections applied to minors. They are deliberately all named here, in one place.
// messagesFrom is not one of them: it is "everyone" for minors too, inside their band.
const (
	// MinorLocationDecimals is how many decimals a minor's shared location is rounded to
	// before it is stored: 1 decimal, a grid of about 11 km, instead of the adult 2 decimals (about 1.1 km).
	// The band is read when the location is written.
	MinorLocationDecimals = 1

	// MinorOnlineAudience is the presence setting minors start with: they do not show as online.
	// It is applied once, when onboarding completes with a declared age under AdultAge.
	MinorOnlineAudience = "nobody"

	// MinorLocationFieldAudience is the audience of the country field for minors
	// ("location" in fieldAudiences): only friends, not everyone. Applied once, with the setting above.
	MinorLocationFieldAudience = "friends"

	// MinorConnectionsAudience is the audience of the connections field for minors: their followers
	// and following lists open to friends only, where an adult's open to followers too
	// (AdultConnectionsAudience). Applied once, with the settings above.
	MinorConnectionsAudience = "friends"
)

// MinorNearbyBuckets are the only distances a minor is shown in Nearby, in km: coarser than
// the adult NearbyBuckets because a minor's stored location is itself coarser. They are used
// for a viewer who is a minor, so everyone listed is a minor.
var MinorNearbyBuckets = []int{10, 25, 50, 100}

// NearbyBucketsFor is the set of distance buckets shown to a viewer in the given band.
func NearbyBucketsFor(minorViewer bool) []int {
	if minorViewer {
		return MinorNearbyBuckets
	}
	return NearbyBuckets
}

// ApplyMinorDefaults makes the stricter starting settings for a member who declared an
// age under AdultAge. Messaging is open for minors as for everyone (messagesFrom
// "everyone"), and still only within their own age band.
func ApplyMinorDefaults(p *Privacy) {
	p.OnlineAudience = MinorOnlineAudience
	if p.FieldAudiences == nil {
		p.FieldAudiences = map[string]string{}
	}
	p.FieldAudiences["location"] = MinorLocationFieldAudience
	p.FieldAudiences["connections"] = MinorConnectionsAudience
}
