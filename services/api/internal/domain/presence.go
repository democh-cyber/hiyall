package domain

import "time"

// Presence semantics. These are not plan limits: they define what "online" and "last seen" mean, and
// they are the same for everyone.
const (
	// PresenceOnlineWindow is how recent a member's latest session activity must be for them to count as
	// online without a live realtime connection. It is deliberately longer than the one minute at which
	// sessions.last_seen_at is refreshed (see Store.VerifyDevSession), so an active member never flickers.
	PresenceOnlineWindow = 2 * time.Minute

	// PresenceLastSeenBucket is the grain of a last-seen time. The value is rounded DOWN to this many
	// minutes (UTC, aligned to the hour), so no exact moment of activity ever leaves the server.
	PresenceLastSeenBucket = 5 * time.Minute
)

// Presence is what a viewer is told about one member: Online, or else (when the member has been active at
// all) the bucketed time they were last seen. The zero value is "nothing to show", which is also what
// a member who hides presence looks like.
type Presence struct {
	Online     bool
	LastSeenAt *time.Time
}

// LastSeenBucket rounds an activity time down to PresenceLastSeenBucket, in UTC.
func LastSeenBucket(t time.Time) time.Time { return t.UTC().Truncate(PresenceLastSeenBucket) }

// ResolvePresence is the one definition of presence. A member with a live realtime connection is online
// whatever their sessions say. Otherwise they are online when their latest session activity (lastActive,
// nil when they have no usable session) is within PresenceOnlineWindow of now, and else they were last
// seen at that activity rounded down to PresenceLastSeenBucket. A time in the future (clock skew) counts
// as now.
func ResolvePresence(live bool, lastActive *time.Time, now time.Time) Presence {
	if live {
		return Presence{Online: true}
	}
	if lastActive == nil {
		return Presence{}
	}
	if now.Sub(*lastActive) <= PresenceOnlineWindow {
		return Presence{Online: true}
	}
	seen := LastSeenBucket(*lastActive)
	return Presence{LastSeenAt: &seen}
}
