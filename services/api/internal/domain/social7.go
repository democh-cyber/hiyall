package domain

import (
	"strings"
	"unicode/utf8"
)

// Limits and refusals added with the Wave 7 social features (docs/api/27-stories-notices-support.md).

const (
	// DailyPulseSearchPages counts the pages of a post or story search a member reads per UTC day, apart from the
	// people search's DailySearchPages.
	DailyPulseSearchPages = "pulse_search_page"
	// DailySupportMessages counts the messages a member sends to support per UTC day.
	DailySupportMessages = "support_message"

	// MaxSearchQuery is the longest search text; MinSearchQuery the shortest.
	MaxSearchQuery = 80
	MinSearchQuery = 2
	// MaxSearchPages is how many pages one search may be read to, a cap like the people search's.
	MaxSearchPages = 10
	// MaxVoiceSeconds is the longest voice clip of a post or story.
	MaxVoiceSeconds = 60
	// MaxVoiceBytes is the largest voice upload: 60 seconds of AAC at 128 kbit/s is under 1 MiB, so this leaves room for
	// the container and for recorders that ignore the bit rate.
	MaxVoiceBytes = 4 << 20
	// MaxSupportBody is the longest support message.
	MaxSupportBody = 2000
	// MaxNoticeTitle and MaxNoticeBody bound a notice.
	MaxNoticeTitle = 120
	MaxNoticeBody  = 4000
)

func init() {
	dailyLimitErrors[DailyPulseSearchPages] = &PolicyError{429, "DAILY_LIMIT", "You’ve searched a lot today. Try again tomorrow."}
	dailyLimitErrors[DailySupportMessages] = &PolicyError{429, "DAILY_LIMIT", "You’ve sent a lot of messages to support today. Try again tomorrow."}
}

var (
	ErrVoiceTooLong = &PolicyError{422, "VOICE_TOO_LONG", "Voice notes can be up to 60 seconds."}
	// ErrSupportThreadOpen is a second open conversation in a category; the member continues the open one.
	ErrSupportThreadOpen   = &PolicyError{409, "SUPPORT_THREAD_OPEN", "You already have an open conversation about this. Reply there."}
	ErrSupportThreadClosed = &PolicyError{409, "SUPPORT_THREAD_CLOSED", "This conversation is closed. Start a new one if you still need help."}
)

// ParseSearchQuery trims and checks the text of a search.
func ParseSearchQuery(q string) (string, error) {
	q = Normalize(strings.TrimSpace(q))
	n := utf8.RuneCountInString(q)
	if !CleanLine(q) || n < MinSearchQuery || n > MaxSearchQuery {
		return "", invalid("q", "search for 2 to 80 characters")
	}
	return q, nil
}
