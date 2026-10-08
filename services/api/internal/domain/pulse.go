package domain

import (
	"encoding/json"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

var (
	ErrCommentsNotAllowed = &PolicyError{403, "COMMENTS_NOT_ALLOWED", "Comments on this post are limited"}
	ErrMediaNotReady      = &PolicyError{409, "MEDIA_NOT_READY", "Finish uploading your photos first"}
)

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

var storyBackgrounds = map[string]bool{"lime": true, "lilac": true, "pink": true, "mint": true, "peach": true, "ink": true}

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
	Media      *MediaView `json:"media"`
	Audience   string     `json:"audience"`
	CreatedAt  time.Time  `json:"createdAt"`
	ExpiresAt  time.Time  `json:"expiresAt"`
	Seen       bool       `json:"seen"`
	// ViewCount is only filled for the author's own stories.
	ViewCount *int `json:"viewCount,omitempty"`
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
	p.Body = strings.TrimSpace(p.Body)
	if !utf8.ValidString(p.Body) || utf8.RuneCountInString(p.Body) > MaxPostBody {
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
		if _, err := uuid.Parse(id); err != nil || seen[id] {
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
	c.Body = strings.TrimSpace(c.Body)
	if c.Body == "" || !utf8.ValidString(c.Body) || utf8.RuneCountInString(c.Body) > MaxCommentBody {
		return c, invalid("body", "comments are 1–1000 characters")
	}
	if c.ParentID != nil {
		if _, err := uuid.Parse(*c.ParentID); err != nil {
			return c, invalid("parentId", "must be a comment id")
		}
	}
	return c, nil
}

type NewStory struct {
	Body       string  `json:"body"`
	Background string  `json:"background"`
	MediaID    *string `json:"mediaId"`
	Audience   string  `json:"audience"`
}

func ParseStory(raw []byte) (NewStory, error) {
	var s NewStory
	if strict(raw, &s) != nil {
		return s, invalid("body", "send body or mediaId, and audience")
	}
	s.Body = strings.TrimSpace(s.Body)
	if !utf8.ValidString(s.Body) || utf8.RuneCountInString(s.Body) > MaxStoryBody {
		return s, invalid("body", "keep it under 280 characters")
	}
	if s.Background == "" {
		s.Background = "lime"
	}
	if !storyBackgrounds[s.Background] {
		return s, invalid("background", "is not a supported colour")
	}
	if !Audiences[s.Audience] {
		return s, invalid("audience", "must be public, followers or friends")
	}
	if s.MediaID != nil {
		if _, err := uuid.Parse(*s.MediaID); err != nil {
			return s, invalid("mediaId", "must be an id")
		}
	}
	if s.MediaID == nil && s.Body == "" {
		return s, invalid("body", "add a photo or some words")
	}
	return s, nil
}
