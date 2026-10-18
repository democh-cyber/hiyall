package domain

import (
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// The notice board: short posts from the Hiyall team (safety advice, news, app updates). A notice is plain
// text with three bits of markup, nothing else: paragraphs (separated by a blank line), **bold** and
// [label](https://link) links, https only. Clients draw the markup themselves; no HTML ever reaches a screen.

var (
	NoticeCategories = []string{"safety", "news", "update"}
	NoticeAudiences  = []string{"all", "minors", "adults"}
	noticeLocale     = regexp.MustCompile(`^([a-z]{2,3}(-[A-Za-z0-9]{2,8})*)?$`)
	noticeLink       = regexp.MustCompile(`\[([^\[\]\n]{1,80})\]\(([^()\s]{1,300})\)`)
)

// Notice is one board entry as a member reads it.
type Notice struct {
	NoticeID    string     `json:"noticeId"`
	Category    string     `json:"category"`
	Title       string     `json:"title"`
	Body        string     `json:"body"`
	Pinned      bool       `json:"pinned"`
	PublishedAt time.Time  `json:"publishedAt"`
	ExpiresAt   *time.Time `json:"expiresAt"`
	// Unread is true for a notice published after the member last opened the board.
	Unread bool `json:"unread"`
}

// NewNotice is what the console submits to publish or edit a notice.
type NewNotice struct {
	Category    string     `json:"category"`
	Title       string     `json:"title"`
	Body        string     `json:"body"`
	Audience    string     `json:"audience"`
	Locale      string     `json:"locale"`
	Pinned      bool       `json:"pinned"`
	PublishedAt *time.Time `json:"publishedAt"`
	ExpiresAt   *time.Time `json:"expiresAt"`
}

// Validate normalises the notice in place and reports what is wrong with it. now is the current time: a notice
// that expires before it is published (or before now) is refused.
func (n *NewNotice) Validate(now time.Time) error {
	if !member(n.Category, NoticeCategories...) {
		return invalid("category", "must be safety, news or update")
	}
	if n.Audience == "" {
		n.Audience = "all"
	}
	if !member(n.Audience, NoticeAudiences...) {
		return invalid("audience", "must be all, minors or adults")
	}
	n.Locale = strings.TrimSpace(n.Locale)
	if !noticeLocale.MatchString(n.Locale) || len(n.Locale) > 20 {
		return invalid("locale", "must be empty (every language) or a language code such as en or pt-BR")
	}
	n.Title = Normalize(strings.TrimSpace(n.Title))
	if !CleanLine(n.Title) || n.Title == "" || utf8.RuneCountInString(n.Title) > MaxNoticeTitle {
		return invalid("title", "1 to 120 characters, on one line")
	}
	n.Body = Normalize(strings.TrimSpace(strings.ReplaceAll(n.Body, "\r\n", "\n")))
	if err := ValidateNoticeBody(n.Body); err != nil {
		return err
	}
	if n.PublishedAt != nil && n.ExpiresAt != nil && !n.ExpiresAt.After(*n.PublishedAt) {
		return invalid("expiresAt", "must be after the publish time")
	}
	if n.ExpiresAt != nil && !n.ExpiresAt.After(now) {
		return invalid("expiresAt", "must be in the future")
	}
	return nil
}

// ValidateNoticeBody accepts paragraphs, **bold** and [label](https://…) links and refuses everything else that
// could be markup: HTML, images, a link that is not https or is not well formed, unbalanced bold.
func ValidateNoticeBody(body string) error {
	if body == "" || !CleanText(body) || utf8.RuneCountInString(body) > MaxNoticeBody {
		return invalid("body", "1 to 4000 characters")
	}
	if strings.ContainsAny(body, "<>") {
		return invalid("body", "HTML is not allowed")
	}
	if strings.Contains(body, "![") {
		return invalid("body", "images are not allowed")
	}
	for _, m := range noticeLink.FindAllStringSubmatch(body, -1) {
		if !ValidNoticeLink(m[2]) {
			return invalid("body", "links must be https addresses")
		}
	}
	rest := noticeLink.ReplaceAllString(body, "")
	if strings.Contains(rest, "](") {
		return invalid("body", "a link is written [label](https://address)")
	}
	for _, paragraph := range strings.Split(body, "\n\n") {
		if strings.Count(paragraph, "**")%2 != 0 {
			return invalid("body", "bold text must be closed with **")
		}
	}
	return nil
}

// ValidNoticeLink says whether target is a well formed https URL with a host and no credentials.
func ValidNoticeLink(target string) bool {
	u, err := url.Parse(target)
	return err == nil && u.Scheme == "https" && u.Host != "" && u.User == nil && !strings.ContainsAny(u.Host, " ") && u.Hostname() != ""
}

// NoticeVisibleTo is the audience rule: a notice for minors reaches members under 18, one for adults the rest.
func NoticeVisibleTo(audience string, minor bool) bool {
	switch audience {
	case "minors":
		return minor
	case "adults":
		return !minor
	}
	return true
}
