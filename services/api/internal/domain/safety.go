package domain

import (
	"encoding/json"
	"strings"
	"time"
	"unicode/utf8"
)

// ReportReasons maps each accepted reason to its queue severity. High-severity
// reports are reviewed first.
var ReportReasons = map[string]string{
	"spam":           "normal",
	"harassment":     "normal",
	"scam":           "normal",
	"hate":           "high",
	"threats":        "high",
	"sexual_content": "high",
	"violence":       "high",
	"self_harm":      "high",
	"underage":       "high",
	"impersonation":  "normal",
	"copyright":      "normal",
	"other":          "normal",
}

const (
	maxAttachmentsPerEvidence = 4
	maxEvidence               = 10
	maxEvidenceText           = 4000
	maxDescription            = 1000
)

// Evidence is one decrypted message the reporter chose to share. The server
// can't verify the text against ciphertext; it only checks the message exists
// in a conversation the reporter belongs to.
type Evidence struct {
	MessageID string    `json:"messageId"`
	Text      string    `json:"text"`
	SentAt    time.Time `json:"sentAt"`
	FromMe    bool      `json:"fromMe"`
	// Attachments are encrypted images of this message the reporter chose to share, with the descriptor
	// (and so the key) they hold. Blobs named here are held against deletion while the report is open.
	Attachments []EvidenceAttachment `json:"attachments,omitempty"`
}

type NewReport struct {
	TargetType        string     `json:"targetType"`
	TargetID          string     `json:"targetId"`
	ReasonCode        string     `json:"reasonCode"`
	Description       string     `json:"description"`
	Evidence          []Evidence `json:"evidence"`
	DisclosureConsent bool       `json:"disclosureConsent"`
	// Block also blocks the reported person in the same request.
	Block bool `json:"block"`
}

func (r NewReport) Severity() string { return ReportReasons[r.ReasonCode] }

func ParseReport(raw []byte) (NewReport, error) {
	var r NewReport
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&r); err != nil {
		return r, invalid("body", "send targetType, targetId and reasonCode")
	}
	switch r.TargetType {
	case "user", "conversation", "message", "post", "comment", "story", "space", "space_entry":
	default:
		return r, invalid("targetType", "must be user, conversation, message, post, comment or story")
	}
	if !IsID(r.TargetID) {
		return r, invalid("targetId", "must be an id")
	}
	if _, ok := ReportReasons[r.ReasonCode]; !ok {
		return r, invalid("reasonCode", "is not a supported reason")
	}
	r.Description = strings.TrimSpace(r.Description)
	if !CleanText(r.Description) {
		return r, invalid("description", "must be valid text")
	}
	if utf8.RuneCountInString(r.Description) > maxDescription {
		return r, invalid("description", "keep it under 1000 characters")
	}
	if len(r.Evidence) > 0 && r.TargetType != "conversation" && r.TargetType != "message" {
		return r, invalid("evidence", "messages can be shared only when reporting a chat or message")
	}
	if len(r.Evidence) > maxEvidence {
		return r, invalid("evidence", "share at most 10 messages")
	}
	if len(r.Evidence) > 0 && !r.DisclosureConsent {
		return r, invalid("disclosureConsent", "confirm you want to share these messages")
	}
	seen := map[string]bool{}
	for _, e := range r.Evidence {
		if !IsID(e.MessageID) || seen[e.MessageID] {
			return r, invalid("evidence", "each message must be a distinct id")
		}
		seen[e.MessageID] = true
		if e.Text == "" || !CleanText(e.Text) || utf8.RuneCountInString(e.Text) > maxEvidenceText || e.SentAt.IsZero() {
			return r, invalid("evidence", "each message needs its text (up to 4000 characters) and time")
		}
		if len(e.Attachments) > maxAttachmentsPerEvidence {
			return r, invalid("evidence", "share at most 4 attachments per message")
		}
		for _, a := range e.Attachments {
			if !ValidBlobIDs(a.BlobIDs, MaxBlobsPerMessage) || !validDescriptor(a.Descriptor) {
				return r, invalid("evidence", "each attachment needs 1-4 distinct blob ids and its descriptor object (up to 4 KiB)")
			}
		}
	}
	if len(r.Evidence) == 0 {
		r.DisclosureConsent = false
	}
	return r, nil
}

// validDescriptor is a JSON object of bounded size; the server never interprets it.
func validDescriptor(raw json.RawMessage) bool {
	var object map[string]json.RawMessage
	return len(raw) > 0 && len(raw) <= MaxAttachmentDescriptor && json.Unmarshal(raw, &object) == nil && object != nil
}

// ReportSubject names who a report is about, only when the reporter may know them (see the
// store); like the name, a photo would reveal a member the reporter may not know, so it has none.
type ReportSubject struct {
	UserID      string `json:"userId"`
	Username    string `json:"username"`
	DisplayName string `json:"displayName"`
}

// Report is what a reporter sees of their own report.
type Report struct {
	ReportID   string        `json:"reportId"`
	TargetType string        `json:"targetType"`
	TargetID   string        `json:"targetId"`
	Subject    ReportSubject `json:"subject"`
	ReasonCode string        `json:"reasonCode"`
	Status     string        `json:"status"`
	CreatedAt  time.Time     `json:"createdAt"`
	ResolvedAt *time.Time    `json:"resolvedAt"`
	// Blocked is set by CreateReport when the report also blocked the subject; it is not part of a report's JSON.
	Blocked bool `json:"-"`
}

// Control is one entry in the caller's blocked, muted or restricted list.
type Control struct {
	User  UserSummary `json:"user"`
	Since time.Time   `json:"since"`
	Until *time.Time  `json:"until,omitempty"`
}

// ParseMuteUntil reads an optional {"until": RFC3339} body. No body or a null
// until means indefinitely. A time in the past is rejected.
func ParseMuteUntil(raw map[string]json.RawMessage, now time.Time) (*time.Time, error) {
	for key := range raw {
		if key != "until" {
			return nil, invalid(key, "field is not accepted")
		}
	}
	value, ok := raw["until"]
	if !ok || string(value) == "null" {
		return nil, nil
	}
	var until time.Time
	if json.Unmarshal(value, &until) != nil || !until.After(now) {
		return nil, invalid("until", "must be a future time")
	}
	// Echoed and stored in UTC, whatever offset the client used.
	until = until.UTC()
	return &until, nil
}
