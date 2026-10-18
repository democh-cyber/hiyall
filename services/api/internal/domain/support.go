package domain

import (
	"strings"
	"time"
	"unicode/utf8"
)

// In-app support (docs/api/27-stories-notices-support.md): a member writes to the Hiyall team and staff answer from
// the admin console. Support messages are PLAINTEXT stored on the server and read by staff: they are not end-to-end
// encrypted, and the app says so where the member writes. Threads are kept 365 days after they close.

var SupportCategories = []string{"account", "safety", "bug", "other"}

// SupportThread is one conversation as the member sees it.
type SupportThread struct {
	ThreadID      string    `json:"threadId"`
	Category      string    `json:"category"`
	Status        string    `json:"status"`
	CreatedAt     time.Time `json:"createdAt"`
	LastMessageAt time.Time `json:"lastMessageAt"`
	// Unread is true when staff wrote after the member last opened the thread.
	Unread bool `json:"unread"`
	// LastAuthor is "member" or "staff"; Preview is the start of the last message.
	LastAuthor string `json:"lastAuthor"`
	Preview    string `json:"preview"`
}

// SupportMessage is one message. Author is "member" or "staff"; a staff member's name is never sent, only "Hiyall team".
type SupportMessage struct {
	MessageID string    `json:"messageId"`
	Author    string    `json:"author"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"createdAt"`
}

// ParseSupportBody trims and checks one support message.
func ParseSupportBody(body string) (string, error) {
	body = Normalize(strings.TrimSpace(body))
	if body == "" || !CleanText(body) || utf8.RuneCountInString(body) > MaxSupportBody {
		return "", invalid("body", "write 1 to 2000 characters")
	}
	return body, nil
}

// ParseSupportCategory checks a category name.
func ParseSupportCategory(c string) (string, error) {
	if !member(c, SupportCategories...) {
		return "", invalid("category", "choose account, safety, bug or other")
	}
	return c, nil
}
