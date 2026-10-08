package domain

import (
	"strings"
	"time"
)

// PolicyError is a request the target's settings refuse; the message is safe to show.
type PolicyError struct {
	Status        int
	Code, Message string
}

func (e *PolicyError) Error() string { return e.Code }

var (
	ErrFollowNotAllowed   = &PolicyError{403, "FOLLOW_NOT_ALLOWED", "This account isn't accepting new followers"}
	ErrRequestNotAllowed  = &PolicyError{403, "REQUEST_NOT_ALLOWED", "This account isn't accepting friend requests from you"}
	ErrRequestCooldown    = &PolicyError{429, "REQUEST_COOLDOWN", "You can send another request later"}
	ErrConnectionsPrivate = &PolicyError{403, "CONNECTIONS_PRIVATE", "This list is private"}
)

// UserSummary is the minimum identity shown on request, list and activity rows.
type UserSummary struct {
	UserID      string `json:"userId"`
	Username    string `json:"username"`
	DisplayName string `json:"displayName"`
}

// Name is what a person is called in text: display name, else @username.
func (u UserSummary) Name() string {
	if name := strings.TrimSpace(u.DisplayName); name != "" {
		return name
	}
	return "@" + u.Username
}

// Relationship is always from the viewer's point of view.
type Relationship struct {
	Following        string  `json:"following"` // none, pending, active
	FollowedBy       bool    `json:"followedBy"`
	Friendship       string  `json:"friendship"` // none, pending_outgoing, pending_incoming, accepted
	FriendRequestID  *string `json:"friendRequestId,omitempty"`
	CanFollow        bool    `json:"canFollow"`
	CanFriendRequest bool    `json:"canFriendRequest"`
	// Muted and Restricted are the viewer's own private controls on the
	// target. The target's controls on the viewer are never exposed.
	Muted      bool `json:"muted"`
	Restricted bool `json:"restricted"`
}

func (r Relationship) Friends() bool { return r.Friendship == "accepted" }

// Allows reports whether an audience setting admits a viewer with this relationship.
// Friends are treated as part of a "followers" audience.
func (r Relationship) Allows(audience string) bool {
	switch audience {
	case "everyone", "public":
		return true
	case "friends":
		return r.Friends()
	case "followers":
		return r.Friends() || r.Following == "active"
	}
	return false
}

type FriendRequest struct {
	RequestID string      `json:"requestId"`
	Sender    UserSummary `json:"sender"`
	Recipient UserSummary `json:"recipient"`
	Status    string      `json:"status"`
	CreatedAt time.Time   `json:"createdAt"`
}

type Connection struct {
	User  UserSummary `json:"user"`
	Since time.Time   `json:"since"`
}

type Notification struct {
	NotificationID string        `json:"notificationId"`
	Type           string        `json:"type"`
	Event          string        `json:"event"`
	Actors         []UserSummary `json:"actors"`
	Count          int           `json:"count"`
	TargetType     string        `json:"targetType"`
	TargetID       string        `json:"targetId"`
	CreatedAt      time.Time     `json:"createdAt"`
	ReadAt         *time.Time    `json:"readAt,omitempty"`
	Text           string        `json:"text"`
}

// NotificationCopy maps a stored event to its contract type, target and text.
var NotificationCopy = map[string][3]string{
	"follow.started":   {"follow", "profile", "started following you"},
	"follow.requested": {"follow", "request", "requested to follow you"},
	"follow.accepted":  {"follow", "profile", "accepted your follow request"},
	"friend.requested": {"friend_request", "request", "sent you a friend request"},
	"friend.accepted":  {"friend_request", "profile", "accepted your friend request"},
	"post.reacted":     {"reaction", "post", "reacted to your post"},
	"post.commented":   {"comment", "post", "commented on your post"},
}
