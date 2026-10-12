package domain

import (
	"strings"
	"time"
	"unicode/utf8"
)

type NewSpace struct {
	Kind        string     `json:"kind"`
	Title       string     `json:"title"`
	Description string     `json:"description"`
	Rules       string     `json:"rules"`
	Visibility  string     `json:"visibility"`
	ParentID    *string    `json:"parentId"`
	Capacity    int        `json:"capacity"`
	StartsAt    *time.Time `json:"startsAt"`
	EndsAt      *time.Time `json:"endsAt"`
	Timezone    string     `json:"timezone"`
	Location    string     `json:"location"`
}

type Space struct {
	SpaceID string      `json:"spaceId"`
	Owner   UserSummary `json:"owner"`
	NewSpace
	Status      string    `json:"status"`
	MemberCount int       `json:"memberCount"`
	MyRole      string    `json:"myRole"`
	MyState     string    `json:"myState"`
	MyRSVP      string    `json:"myRsvp"`
	CanDiscuss  bool      `json:"canDiscuss"`
	CreatedAt   time.Time `json:"createdAt"`
}
type SpaceMember struct {
	User      UserSummary `json:"user"`
	Role      string      `json:"role"`
	State     string      `json:"state"`
	RSVP      string      `json:"rsvp"`
	CreatedAt time.Time   `json:"createdAt"`
}
type SpaceEntry struct {
	EntryID   string      `json:"entryId"`
	Author    UserSummary `json:"author"`
	Body      string      `json:"body"`
	CreatedAt time.Time   `json:"createdAt"`
	CanDelete bool        `json:"canDelete"`
}

func SpaceText(text string, min, max int) bool {
	n := utf8.RuneCountInString(text)
	return CleanText(text) && n >= min && n <= max
}
func ParseSpace(raw []byte) (NewSpace, error) {
	var s NewSpace
	if strict(raw, &s) != nil {
		return s, invalid("body", "send the space details")
	}
	s.Title = strings.TrimSpace(s.Title)
	s.Description = strings.TrimSpace(s.Description)
	s.Rules = strings.TrimSpace(s.Rules)
	s.Location = strings.TrimSpace(s.Location)
	if s.Kind != "community" && s.Kind != "moment" && s.Kind != "event" {
		return s, invalid("kind", "choose community, moment or event")
	}
	if !SpaceText(s.Title, 1, 80) || !SpaceText(s.Description, 0, 2000) || !SpaceText(s.Rules, 0, 2000) || !SpaceText(s.Location, 0, 240) {
		return s, invalid("text", "check the title and description lengths")
	}
	if s.Visibility != "public" && s.Visibility != "private" && s.Visibility != "invite" {
		return s, invalid("visibility", "choose public, private or invite")
	}
	if s.Capacity < 2 || s.Capacity > 10000 {
		return s, invalid("capacity", "choose 2–10000 participants")
	}
	if s.ParentID != nil {
		if !IsID(*s.ParentID) {
			return s, invalid("parentId", "must be a community id")
		}
	}
	if s.Timezone == "" {
		s.Timezone = "UTC"
	}
	if len(s.Timezone) > 100 {
		return s, invalid("timezone", "use an IANA time zone")
	}
	if _, err := time.LoadLocation(s.Timezone); err != nil || s.Timezone == "Local" {
		return s, invalid("timezone", "use an IANA time zone")
	}
	if s.Kind == "community" {
		if s.ParentID != nil || s.StartsAt != nil || s.EndsAt != nil {
			return s, invalid("schedule", "communities have no parent or end time")
		}
		s.Location = ""
	} else {
		if s.StartsAt == nil || s.EndsAt == nil || !s.EndsAt.After(*s.StartsAt) || !s.EndsAt.After(time.Now()) || s.EndsAt.Sub(*s.StartsAt) > 30*24*time.Hour {
			return s, invalid("schedule", "provide a start and later end, up to 30 days apart")
		}
		if s.Kind == "moment" && s.EndsAt.Sub(*s.StartsAt) > 24*time.Hour {
			return s, invalid("schedule", "Moments last up to 24 hours")
		}
	}
	return s, nil
}
