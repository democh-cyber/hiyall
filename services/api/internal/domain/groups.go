package domain

import (
	"encoding/json"
	"strings"
	"time"
	"unicode/utf8"
)

// Group chat (docs/api/29-group-chat.md): rooms of 3 to 10 people whose messages are sealed once per recipient
// device by the senders' phones. The relay holds the roster, the roles and the name, never a message.

const (
	// GroupNameMax is the longest group name, in characters.
	GroupNameMax = 40
	// GroupInviteTTL is how long an invite waits for an answer.
	GroupInviteTTL = 7 * 24 * time.Hour
	// GroupEventRetention is how long membership events are kept.
	GroupEventRetention = 90 * 24 * time.Hour
	// MinGroupInvitees and MaxGroupInvitees bound the people a new group is created with, besides its creator:
	// a group has 3 to 10 people.
	MinGroupInvitees = 2
	MaxGroupInvitees = 9
	// MaxGroupEnvelopes is the most envelopes one group message or control message may carry: ten people with ten
	// devices each, less the sending device.
	MaxGroupEnvelopes = 100
	// MaxGroupControlCiphertext caps each envelope of a control message (decoded bytes): a few hundred bytes of
	// payload plus the Olm framing.
	MaxGroupControlCiphertext = 4096
	// MaxGroupBody is the largest request body of a group send (a message with 100 envelopes of up to 16 KiB).
	MaxGroupBody = 3 << 20
	// GroupEventsShown is how many events GET /v1/groups/{id} returns.
	GroupEventsShown = 50
)

// AuxGroup marks a control message at the relay (messages.aux). Only the group routes set it; a plain send refuses it.
const AuxGroup = "group"

var (
	ErrGroupFull     = &PolicyError{409, "GROUP_FULL", "This group is full."}
	ErrGroupLimit    = &PolicyError{409, "GROUP_LIMIT", "You’re in the most groups you can be in. Leave one to join another."}
	ErrGroupNotOwner = &PolicyError{403, "GROUP_NOT_OWNER", "Only the person who runs the group can do that."}
	ErrGroupWaiting  = &PolicyError{409, "GROUP_WAITING", "Nobody else has joined this group yet."}
)

// CannotAddError is the refusal to add one person to a group. It names the person and never the reason: a block, an
// age band, their privacy choice, their own group limit and "you do not know them" are the same answer.
type CannotAddError struct{ UserID string }

func (e *CannotAddError) Error() string { return "CANNOT_ADD_MEMBER" }

// GroupMember is one active member as the API lists them.
type GroupMember struct {
	UserSummary
	Role     string    `json:"role"`
	JoinedAt time.Time `json:"joinedAt"`
}

// GroupPending is a person invited and not yet joined.
type GroupPending struct {
	UserSummary
	InvitedAt time.Time `json:"invitedAt"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// GroupEvent is a membership event the relay recorded.
type GroupEvent struct {
	EventID   string    `json:"eventId"`
	Kind      string    `json:"kind"`
	ActorID   *string   `json:"actorId"`
	SubjectID *string   `json:"subjectId"`
	MessageID *string   `json:"messageId"`
	Name      *string   `json:"name"`
	At        time.Time `json:"at"`
}

// GroupLimits tells the app what the relay enforces, for the picker.
type GroupLimits struct {
	MaxMembers         int `json:"maxMembers"`
	InviteExpiryDays   int `json:"inviteExpiryDays"`
	NameMax            int `json:"nameMax"`
	MaxGroupsPerMember int `json:"maxGroups"`
}

// Group is a group as the caller sees it.
type Group struct {
	GroupID        string         `json:"groupId"`
	ConversationID string         `json:"conversationId"`
	Kind           string         `json:"kind"`
	Name           string         `json:"name"`
	OwnerID        string         `json:"ownerId"`
	Status         string         `json:"status"`
	CreatedAt      time.Time      `json:"createdAt"`
	LastMessageAt  *time.Time     `json:"lastMessageAt"`
	MemberCount    int            `json:"memberCount"`
	Members        []GroupMember  `json:"members"`
	Pending        []GroupPending `json:"pending"`
	MyState        string         `json:"myState"`
	UnreadCount    int            `json:"unreadCount"`
	ReadAt         *time.Time     `json:"readAt"`
	MutedUntil     *time.Time     `json:"mutedUntil"`
	PinnedAt       *time.Time     `json:"pinnedAt"`
	HiddenAt       *time.Time     `json:"hiddenAt"`
	RestoreUntil   *time.Time     `json:"restoreUntil,omitempty"`
	Limits         GroupLimits    `json:"limits"`
	Events         []GroupEvent   `json:"events,omitempty"`
	// SortAt orders the list (not serialised).
	SortAt time.Time `json:"-"`
}

// GroupInvite is a pending invitation as the invited person sees it: no content, only who and how many.
type GroupInvite struct {
	GroupID     string        `json:"groupId"`
	Name        string        `json:"name"`
	InvitedBy   UserSummary   `json:"invitedBy"`
	InvitedAt   time.Time     `json:"invitedAt"`
	ExpiresAt   time.Time     `json:"expiresAt"`
	MemberCount int           `json:"memberCount"`
	Members     []UserSummary `json:"members"`
}

// GroupName normalises and validates a group name. An empty name is allowed (the apps show the member names).
func GroupName(raw string) (string, error) {
	name := Normalize(strings.TrimSpace(raw))
	if utf8.RuneCountInString(name) > GroupNameMax || !CleanLine(name) {
		return "", invalid("name", "keep the group name under 40 characters")
	}
	return name, nil
}

// NewGroup is the body of POST /v1/groups.
type NewGroup struct {
	Name      string
	MemberIDs []string
}

func distinctIDs(field string, ids []string, min, max int) error {
	if len(ids) < min || len(ids) > max {
		return invalid(field, "choose between "+itoa(min)+" and "+itoa(max)+" people")
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if !IsID(id) || seen[id] {
			return invalid(field, "send each person once, as an id")
		}
		seen[id] = true
	}
	return nil
}

// ParseNewGroup reads {"name": optional, "memberIds": [2 to 9 ids]}.
func ParseNewGroup(body map[string]json.RawMessage) (NewGroup, error) {
	var g NewGroup
	for key := range body {
		if !member(key, "name", "memberIds") {
			return g, invalid(key, "field is not accepted")
		}
	}
	if raw, ok := body["name"]; ok {
		var name string
		if json.Unmarshal(raw, &name) != nil {
			return g, invalid("name", "must be text")
		}
		clean, err := GroupName(name)
		if err != nil {
			return g, err
		}
		g.Name = clean
	}
	if json.Unmarshal(body["memberIds"], &g.MemberIDs) != nil {
		return g, invalid("memberIds", "send the people to invite")
	}
	return g, distinctIDs("memberIds", g.MemberIDs, MinGroupInvitees, MaxGroupInvitees)
}

// ParseGroupInvites reads {"userIds": [1 to 9 ids]}.
func ParseGroupInvites(body map[string]json.RawMessage) ([]string, error) {
	var ids []string
	if len(body) != 1 || json.Unmarshal(body["userIds"], &ids) != nil {
		return nil, invalid("userIds", "send the people to invite")
	}
	return ids, distinctIDs("userIds", ids, 1, MaxGroupInvitees)
}

// GroupControl is the encrypted control message that travels with a membership change: the same shape as a message.
type GroupControl = SendMessage

// ParseControl reads the optional "control" member of a group request. It returns nil when the member is absent.
func ParseControl(body map[string]json.RawMessage) (*GroupControl, error) {
	raw, ok := body["control"]
	if !ok || string(raw) == "null" {
		return nil, nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return nil, invalid("control", "send the encrypted membership message")
	}
	m, err := parseSend(fields, MaxGroupEnvelopes, false)
	if err != nil {
		return nil, err
	}
	// A control message is not a message: no attachments, no aux member, and small envelopes.
	for _, e := range m.Envelopes {
		if len(e.Ciphertext) > base64Len(MaxGroupControlCiphertext) {
			return nil, &PolicyError{Status: 413, Code: "TOO_LARGE", Message: "A membership message envelope is at most 4 KiB"}
		}
	}
	if len(m.BlobIDs) > 0 {
		return nil, invalid("control", "a membership message has no attachments")
	}
	m.Aux = AuxGroup
	return &m, nil
}

func base64Len(n int) int { return (n*8 + 5) / 6 }

// ParseGroupRename reads {"name": text, "control": {...}}.
func ParseGroupRename(body map[string]json.RawMessage) (string, *GroupControl, error) {
	for key := range body {
		if !member(key, "name", "control") {
			return "", nil, invalid(key, "field is not accepted")
		}
	}
	var name string
	if json.Unmarshal(body["name"], &name) != nil {
		return "", nil, invalid("name", "send the new name")
	}
	clean, err := GroupName(name)
	if err != nil {
		return "", nil, err
	}
	control, err := ParseControl(body)
	return clean, control, err
}

// ParseGroupControlOnly reads {"control": {...}} (accept and remove).
func ParseGroupControlOnly(body map[string]json.RawMessage) (*GroupControl, error) {
	for key := range body {
		if key != "control" {
			return nil, invalid(key, "field is not accepted")
		}
	}
	return ParseControl(body)
}

// ParseGroupLeave reads {"control": {...}, "newOwnerId": id}; both are optional here, the store requires them
// when they apply.
func ParseGroupLeave(body map[string]json.RawMessage) (string, *GroupControl, error) {
	for key := range body {
		if !member(key, "control", "newOwnerId") {
			return "", nil, invalid(key, "field is not accepted")
		}
	}
	var owner string
	if raw, ok := body["newOwnerId"]; ok && string(raw) != "null" {
		if json.Unmarshal(raw, &owner) != nil || !IsID(owner) {
			return "", nil, invalid("newOwnerId", "must be an id")
		}
	}
	control, err := ParseControl(body)
	return owner, control, err
}
