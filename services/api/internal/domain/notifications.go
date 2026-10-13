package domain

import "encoding/json"

// NotificationPrefs are a member's push choices (docs/api/23-push-notifications.md): chat
// is new messages, social is friend requests, new followers and follow requests. Both
// start on. Muting a chat or a person applies on top of them.
type NotificationPrefs struct {
	Chat   bool `json:"chat"`
	Social bool `json:"social"`
}

// ParseNotificationPrefs reads a PATCH body: one or both of chat and social, each a boolean.
// A missing key keeps the current value, which is why the result is partial.
func ParseNotificationPrefs(raw map[string]json.RawMessage) (chat, social *bool, err error) {
	if len(raw) == 0 {
		return nil, nil, invalid("notifications", "send chat, social or both")
	}
	for name, value := range raw {
		var on bool
		if name != "chat" && name != "social" {
			return nil, nil, invalid(name, "field is not editable")
		}
		if string(value) == "null" || json.Unmarshal(value, &on) != nil {
			return nil, nil, invalid(name, "must be true or false")
		}
		if name == "chat" {
			chat = &on
		} else {
			social = &on
		}
	}
	return chat, social, nil
}
