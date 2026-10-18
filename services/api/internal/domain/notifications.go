package domain

import "encoding/json"

// NotificationPrefs are a member's push choices (docs/api/23-push-notifications.md and 27): a master switch,
// chat, and one switch per kind of social push. Every switch starts on, except Visits (profile visit notices
// are an opt-in). Muting a chat or a person applies on top of them, and a security push (a new device on the
// account, an account deletion) is never switched off by any of them.
//
// HideNames makes social pushes generic: they say "You have a new follower" and not who. Its default is the
// member's age band: names are hidden for a member under 18 and shown for an adult. The display name of a
// stranger would otherwise travel through FCM and APNs to a lock screen.
//
// Social is the legacy umbrella switch (an older app sets and reads it): true while any of the social
// categories is on, and setting it sets all of them (Visits excepted, which only its own switch changes).
type NotificationPrefs struct {
	Enabled        bool `json:"enabled"`
	Chat           bool `json:"chat"`
	Social         bool `json:"social"`
	Follows        bool `json:"follows"`
	Comments       bool `json:"comments"`
	Reactions      bool `json:"reactions"`
	Replies        bool `json:"replies"`
	FriendRequests bool `json:"friendRequests"`
	Visits         bool `json:"visits"`
	HideNames      bool `json:"hideNames"`
}

// DefaultNotificationPrefs is what a member without a row has: everything on but visit notices, names shown for an
// adult and hidden for a minor.
func DefaultNotificationPrefs(minor bool) NotificationPrefs {
	return NotificationPrefs{Enabled: true, Chat: true, Social: true, Follows: true, Comments: true, Reactions: true, Replies: true, FriendRequests: true, HideNames: minor}
}

// NotificationPatch is a partial update: nil keeps the current value.
type NotificationPatch struct {
	Enabled, Chat, Social, Follows, Comments, Reactions, Replies, FriendRequests, Visits, HideNames *bool
}

// notificationFields maps a JSON name to the field of a patch it sets.
func (p *NotificationPatch) field(name string) **bool {
	switch name {
	case "enabled":
		return &p.Enabled
	case "chat":
		return &p.Chat
	case "social":
		return &p.Social
	case "follows":
		return &p.Follows
	case "comments":
		return &p.Comments
	case "reactions":
		return &p.Reactions
	case "replies":
		return &p.Replies
	case "friendRequests":
		return &p.FriendRequests
	case "visits":
		return &p.Visits
	case "hideNames":
		return &p.HideNames
	}
	return nil
}

// ParseNotificationPrefs reads a PATCH body: any of the fields of NotificationPrefs, each a boolean. A missing
// key keeps the current value, which is why the result is partial.
func ParseNotificationPrefs(raw map[string]json.RawMessage) (NotificationPatch, error) {
	var patch NotificationPatch
	if len(raw) == 0 {
		return patch, invalid("notifications", "send at least one notification choice")
	}
	for name, value := range raw {
		field := patch.field(name)
		if field == nil {
			return patch, invalid(name, "field is not editable")
		}
		var on bool
		if string(value) == "null" || json.Unmarshal(value, &on) != nil {
			return patch, invalid(name, "must be true or false")
		}
		*field = &on
	}
	return patch, nil
}
