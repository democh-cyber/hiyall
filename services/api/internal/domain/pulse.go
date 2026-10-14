package domain

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrCommentsNotAllowed = &PolicyError{403, "COMMENTS_NOT_ALLOWED", "Comments on this post are limited"}
	ErrMediaNotReady      = &PolicyError{409, "MEDIA_NOT_READY", "Finish uploading your photos first"}
	// A daily limit lifts by itself, so the store attaches a Retry-After; full storage lifts only
	// when the member deletes something, so it carries none. The numbers are Entitlements.
	ErrUploadQuota = &PolicyError{429, "QUOTA", "You’ve reached today’s photo upload limit. Try again later."}
	ErrStorageFull = &PolicyError{429, "QUOTA", "Your photo storage is full. Delete some posts or stories to free space."}
)

// PostQuotaError and StoryQuotaError name the member's daily limit of posts or stories.
func PostQuotaError(limit int) *PolicyError { return dailyLimit(limit, "post", "posts") }

func StoryQuotaError(limit int) *PolicyError { return dailyLimit(limit, "story", "stories") }

func dailyLimit(limit int, one, many string) *PolicyError {
	noun := many
	if limit == 1 {
		noun = one
	}
	return &PolicyError{429, "QUOTA", "You’ve reached today’s limit of " + strconv.Itoa(limit) + " " + noun + ". Try again later."}
}

// Reactions people can leave on a post; one per person.
var Reactions = map[string]bool{"heart": true, "fire": true, "laugh": true, "wow": true, "sad": true}

// Audiences a post or story can have. Followers includes friends.
var Audiences = map[string]bool{"public": true, "followers": true, "friends": true}

const (
	MaxPostBody    = 2200
	MaxPostMedia   = 10
	MaxCommentBody = 1000
	MaxStoryBody   = 280
	StoryLifetime  = 24 * time.Hour
)

// Story backgrounds: the six solid colours the first clients shipped, then gradient presets. Names are
// what is stored and sent; each client draws its own colours for them and falls back to lime for a name
// it does not know, so adding one here never breaks an older app.
var StoryBackgroundNames = []string{
	"lime", "lilac", "pink", "mint", "peach", "ink",
	"sunset", "bubblegum", "aurora", "ocean", "grape", "mango", "midnight", "freshmint",
}

// Text styles for a story's words, drawn by the client from its bundled fonts. "clean" is what a story
// without one (every story from before they existed) is shown with.
var StoryTextStyleNames = []string{"clean", "loud", "soft", "glow", "stamp", "type"}

const (
	DefaultStoryBackground = "lime"
	DefaultStoryTextStyle  = "clean"
)

var storyBackgrounds, storyTextStyles = nameSet(StoryBackgroundNames), nameSet(StoryTextStyleNames)

func nameSet(names []string) map[string]bool {
	set := make(map[string]bool, len(names))
	for _, n := range names {
		set[n] = true
	}
	return set
}

type MediaView struct {
	MediaID  string `json:"mediaId"`
	URL      string `json:"url"`
	ThumbURL string `json:"thumbUrl"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}

type Post struct {
	PostID     string      `json:"postId"`
	Author     UserSummary `json:"author"`
	Body       string      `json:"body"`
	Audience   string      `json:"audience"`
	CreatedAt  time.Time   `json:"createdAt"`
	EditedAt   *time.Time  `json:"editedAt"`
	Media      []MediaView `json:"media"`
	Reactions  int         `json:"reactionCount"`
	Comments   int         `json:"commentCount"`
	MyReaction *string     `json:"myReaction"`
	Saved      bool        `json:"saved"`
	Mine       bool        `json:"mine"`
	// SortAt is the feed cursor key; for saved lists it is when it was saved.
	SortAt time.Time `json:"-"`
}

type Comment struct {
	CommentID string      `json:"commentId"`
	PostID    string      `json:"postId"`
	Author    UserSummary `json:"author"`
	ParentID  *string     `json:"parentId"`
	Body      string      `json:"body"`
	CreatedAt time.Time   `json:"createdAt"`
	Mine      bool        `json:"mine"`
	// CanDelete is true for the writer and for the post's author.
	CanDelete bool `json:"canDelete"`
}

type Story struct {
	StoryID    string     `json:"storyId"`
	Body       string     `json:"body"`
	Background string     `json:"background"`
	TextStyle  string     `json:"textStyle"`
	Media      *MediaView `json:"media"`
	Audience   string     `json:"audience"`
	CreatedAt  time.Time  `json:"createdAt"`
	ExpiresAt  time.Time  `json:"expiresAt"`
	Seen       bool       `json:"seen"`
	// ViewCount is only filled for the author's own stories.
	ViewCount *int `json:"viewCount,omitempty"`
	// ViewCountMore is true when more members than ViewCount saw the story: the count stops at 99 and the
	// app shows "99+".
	ViewCountMore bool `json:"viewCountMore,omitempty"`
}

// StoryGroup is one author's active stories in the tray.
type StoryGroup struct {
	Author  UserSummary `json:"author"`
	Stories []Story     `json:"stories"`
	AllSeen bool        `json:"allSeen"`
	Mine    bool        `json:"mine"`
	Latest  time.Time   `json:"latest"`
}

type NewPost struct {
	Body     string   `json:"body"`
	Audience string   `json:"audience"`
	MediaIDs []string `json:"mediaIds"`
}

func strict(raw []byte, v any) error {
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	return d.Decode(v)
}

func ParsePost(raw []byte) (NewPost, error) {
	var p NewPost
	if strict(raw, &p) != nil {
		return p, invalid("body", "send body, audience and optional mediaIds")
	}
	p.Body = Normalize(strings.TrimSpace(p.Body))
	if !CleanText(p.Body) || utf8.RuneCountInString(p.Body) > MaxPostBody {
		return p, invalid("body", "keep it under 2200 characters")
	}
	if !Audiences[p.Audience] {
		return p, invalid("audience", "must be public, followers or friends")
	}
	if len(p.MediaIDs) > MaxPostMedia {
		return p, invalid("mediaIds", "add up to 10 photos")
	}
	seen := map[string]bool{}
	for _, id := range p.MediaIDs {
		if !IsID(id) || seen[id] {
			return p, invalid("mediaIds", "each photo must be a distinct id")
		}
		seen[id] = true
	}
	if p.Body == "" && len(p.MediaIDs) == 0 {
		return p, invalid("body", "write something or add a photo")
	}
	return p, nil
}

type NewComment struct {
	Body     string  `json:"body"`
	ParentID *string `json:"parentId"`
}

func ParseComment(raw []byte) (NewComment, error) {
	var c NewComment
	if strict(raw, &c) != nil {
		return c, invalid("body", "send body and optional parentId")
	}
	c.Body = Normalize(strings.TrimSpace(c.Body))
	if c.Body == "" || !CleanText(c.Body) || utf8.RuneCountInString(c.Body) > MaxCommentBody {
		return c, invalid("body", "comments are 1–1000 characters")
	}
	if c.ParentID != nil {
		if !IsID(*c.ParentID) {
			return c, invalid("parentId", "must be a comment id")
		}
	}
	return c, nil
}

type NewStory struct {
	Body       string  `json:"body"`
	Background string  `json:"background"`
	TextStyle  string  `json:"textStyle"`
	MediaID    *string `json:"mediaId"`
	Audience   string  `json:"audience"`
	// LifetimeHours is how long the story stays up. Parsing only fixes the default (StoryLifetime); the
	// hours a member may choose are their entitlements (StoryLifetimeError), checked where it is stored.
	LifetimeHours *int `json:"lifetimeHours"`
}

// Lifetime is how long the story lives from now.
func (s NewStory) Lifetime() time.Duration {
	if s.LifetimeHours == nil {
		return StoryLifetime
	}
	return time.Duration(*s.LifetimeHours) * time.Hour
}

// StoryLifetimeError is the refusal of a lifetime the member's plan does not offer.
func StoryLifetimeError(allowed []int) error {
	hours := make([]string, len(allowed))
	for i, h := range allowed {
		hours[i] = strconv.Itoa(h)
	}
	return invalid("lifetimeHours", "choose "+joinOr(hours)+" hours")
}

func joinOr(items []string) string {
	switch len(items) {
	case 0:
		return "a supported number of"
	case 1:
		return items[0]
	}
	return strings.Join(items[:len(items)-1], ", ") + " or " + items[len(items)-1]
}

func ParseStory(raw []byte) (NewStory, error) {
	var s NewStory
	if strict(raw, &s) != nil {
		return s, invalid("body", "send body or mediaId, and audience")
	}
	s.Body = Normalize(strings.TrimSpace(s.Body))
	if !CleanText(s.Body) || utf8.RuneCountInString(s.Body) > MaxStoryBody {
		return s, invalid("body", "keep it under 280 characters")
	}
	if s.Background == "" {
		s.Background = DefaultStoryBackground
	}
	if !storyBackgrounds[s.Background] {
		return s, invalid("background", "is not a supported colour")
	}
	if s.TextStyle == "" {
		s.TextStyle = DefaultStoryTextStyle
	}
	if !storyTextStyles[s.TextStyle] {
		return s, invalid("textStyle", "is not a supported text style")
	}
	if s.LifetimeHours != nil && (*s.LifetimeHours < 1 || *s.LifetimeHours > 24*365) {
		return s, invalid("lifetimeHours", "must be a whole number of hours")
	}
	if !Audiences[s.Audience] {
		return s, invalid("audience", "must be public, followers or friends")
	}
	if s.MediaID != nil {
		if !IsID(*s.MediaID) {
			return s, invalid("mediaId", "must be an id")
		}
	}
	if s.MediaID == nil && s.Body == "" {
		return s, invalid("body", "add a photo or some words")
	}
	return s, nil
}
