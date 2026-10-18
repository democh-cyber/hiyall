package domain

import "strings"

// Topics are the subjects a post or a story can be filed under. The names are what the API stores, sends and
// filters by; each client draws its own label and icon for them and shows a name it does not know (a newer
// server) as plain text. The database only checks the shape of the name (migration 0050), so adding one is a
// code change here and never another migration.
var Topics = []string{"language", "music", "food", "travel", "games", "art", "sport", "study"}

var topicSet = nameSet(Topics)

// IsTopic says whether name is one of Topics.
func IsTopic(name string) bool { return topicSet[name] }

// ParseTopic reads the optional topic of a post, a story or a feed filter: nil and "" mean none.
func ParseTopic(topic *string) (*string, error) {
	if topic == nil {
		return nil, nil
	}
	name := strings.TrimSpace(*topic)
	if name == "" {
		return nil, nil
	}
	if !topicSet[name] {
		return nil, invalid("topic", "choose one of "+strings.Join(Topics, ", "))
	}
	return &name, nil
}
