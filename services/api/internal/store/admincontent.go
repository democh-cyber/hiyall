package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Read models for the admin console's content preview and quarantine cases
// (docs/security/15-admin-console.md, docs/security/16-csam-and-illegal-content.md).

// ErrNoPreview is answered for a report whose target is a private chat: the console shows only what the
// reporter shared, never the conversation.
var ErrNoPreview = &domain.PolicyError{Status: 422, Code: "NO_PREVIEW", Message: "Chats are end-to-end encrypted. Staff only see what the reporter chose to share."}

// AdminMediaRef is one photo of a reported item.
type AdminMediaRef struct {
	MediaID string `json:"mediaId"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
}

// AdminContent is the reported public item as members saw it.
type AdminContent struct {
	TargetType     string          `json:"targetType"`
	TargetID       string          `json:"targetId"`
	Text           string          `json:"text"`
	Title          string          `json:"title,omitempty"`
	AuthorID       string          `json:"authorId"`
	AuthorUsername string          `json:"authorUsername"`
	CreatedAt      time.Time       `json:"createdAt"`
	Deleted        bool            `json:"deleted"`
	Media          []AdminMediaRef `json:"media"`
}

// ReportedContent loads the item a report is about: the text of a post, comment, story, space or space
// entry and the photos still stored for it, or the avatar of a reported member. Reports about chats have
// no preview (ErrNoPreview).
func (s *Store) ReportedContent(ctx context.Context, reportID string) (AdminContent, error) {
	var c AdminContent
	if err := s.Pool.QueryRow(ctx, `SELECT target_type,target_id::text FROM reports WHERE report_id=$1`, reportID).Scan(&c.TargetType, &c.TargetID); err != nil {
		return c, mapped(err)
	}
	c.Media = []AdminMediaRef{}
	var err error
	switch c.TargetType {
	case "post":
		err = s.Pool.QueryRow(ctx, `SELECT p.body,p.author_id::text,coalesce(pr.username,''),p.created_at,p.deleted_at IS NOT NULL FROM posts p LEFT JOIN profiles pr ON pr.user_id=p.author_id WHERE p.post_id=$1`, c.TargetID).
			Scan(&c.Text, &c.AuthorID, &c.AuthorUsername, &c.CreatedAt, &c.Deleted)
		if err == nil {
			err = s.mediaRefs(ctx, &c, `SELECT m.media_id::text,coalesce(m.width,0),coalesce(m.height,0) FROM post_media pm JOIN media_assets m ON m.media_id=pm.media_id WHERE pm.post_id=$1 AND m.status='ready' ORDER BY pm.position`, c.TargetID)
		}
	case "comment":
		err = s.Pool.QueryRow(ctx, `SELECT c.body,c.author_id::text,coalesce(pr.username,''),c.created_at,c.deleted_at IS NOT NULL FROM comments c LEFT JOIN profiles pr ON pr.user_id=c.author_id WHERE c.comment_id=$1`, c.TargetID).
			Scan(&c.Text, &c.AuthorID, &c.AuthorUsername, &c.CreatedAt, &c.Deleted)
	case "story":
		err = s.Pool.QueryRow(ctx, `SELECT st.body,st.author_id::text,coalesce(pr.username,''),st.created_at,st.deleted_at IS NOT NULL FROM stories st LEFT JOIN profiles pr ON pr.user_id=st.author_id WHERE st.story_id=$1`, c.TargetID).
			Scan(&c.Text, &c.AuthorID, &c.AuthorUsername, &c.CreatedAt, &c.Deleted)
		if err == nil {
			err = s.mediaRefs(ctx, &c, `SELECT m.media_id::text,coalesce(m.width,0),coalesce(m.height,0) FROM stories st JOIN media_assets m ON m.media_id=st.media_id WHERE st.story_id=$1 AND m.status='ready'`, c.TargetID)
		}
	case "space":
		err = s.Pool.QueryRow(ctx, `SELECT trim(both E'\n' FROM sp.description||E'\n'||sp.rules),sp.title,sp.owner_id::text,coalesce(pr.username,''),sp.created_at,sp.status='archived' FROM spaces sp LEFT JOIN profiles pr ON pr.user_id=sp.owner_id WHERE sp.space_id=$1`, c.TargetID).
			Scan(&c.Text, &c.Title, &c.AuthorID, &c.AuthorUsername, &c.CreatedAt, &c.Deleted)
	case "space_entry":
		err = s.Pool.QueryRow(ctx, `SELECT e.body,e.author_id::text,coalesce(pr.username,''),e.created_at,e.deleted_at IS NOT NULL FROM space_entries e LEFT JOIN profiles pr ON pr.user_id=e.author_id WHERE e.entry_id=$1`, c.TargetID).
			Scan(&c.Text, &c.AuthorID, &c.AuthorUsername, &c.CreatedAt, &c.Deleted)
	case "user":
		c.AuthorID = c.TargetID
		err = s.Pool.QueryRow(ctx, `SELECT coalesce(pr.username,''),u.created_at FROM users u LEFT JOIN profiles pr ON pr.user_id=u.user_id WHERE u.user_id=$1`, c.TargetID).Scan(&c.AuthorUsername, &c.CreatedAt)
		if err == nil {
			err = s.mediaRefs(ctx, &c, `SELECT m.media_id::text,coalesce(m.width,0),coalesce(m.height,0) FROM profiles pr JOIN media_assets m ON m.media_id=nullif(pr.data->>'avatarMediaId','')::uuid AND m.owner_id=pr.user_id AND m.purpose='avatar' AND m.status='ready' WHERE pr.user_id=$1`, c.TargetID)
		}
	default:
		return c, ErrNoPreview
	}
	return c, mapped(err)
}

func (s *Store) mediaRefs(ctx context.Context, c *AdminContent, query, id string) error {
	rows, err := s.Pool.Query(ctx, query, id)
	if err != nil {
		return err
	}
	refs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminMediaRef, error) {
		var m AdminMediaRef
		return m, row.Scan(&m.MediaID, &m.Width, &m.Height)
	})
	if err == nil && refs != nil {
		c.Media = refs
	}
	return err
}

// ReadyMediaKey is the object key of the full-size variant of a photo members can see (status ready).
func (s *Store) ReadyMediaKey(ctx context.Context, mediaID string) (string, error) {
	var key *string
	err := s.Pool.QueryRow(ctx, `SELECT variants->>'full' FROM media_assets WHERE media_id=$1 AND status='ready'`, mediaID).Scan(&key)
	if err != nil || key == nil || *key == "" {
		return "", domain.ErrNotFound
	}
	return *key, nil
}

// ---- quarantine cases

// AdminContentCase is a quarantined upload as an operator sees it: the evidence record, never the image.
type AdminContentCase struct {
	CaseID          string            `json:"caseId"`
	MediaID         string            `json:"mediaId"`
	UserID          string            `json:"userId"`
	Username        string            `json:"username"`
	AgeBand         string            `json:"ageBand"`
	AccountStatus   string            `json:"accountStatus"`
	Purpose         string            `json:"purpose"`
	Result          string            `json:"result"`
	Scanner         string            `json:"scanner"`
	Signals         map[string]string `json:"signals"`
	OriginalSHA256  string            `json:"originalSha256"`
	OriginalBytes   int64             `json:"originalBytes"`
	ContentType     string            `json:"contentType"`
	SuspendedUser   bool              `json:"suspendedUser"`
	Status          string            `json:"status"`
	CreatedAt       time.Time         `json:"createdAt"`
	HoldUntil       time.Time         `json:"holdUntil"`
	LegalHold       bool              `json:"legalHold"`
	ReviewedBy      string            `json:"reviewedBy"`
	ReviewedAt      *time.Time        `json:"reviewedAt"`
	ResolutionNote  string            `json:"resolutionNote"`
	ReportReference string            `json:"reportReference"`
	ReportedAt      *time.Time        `json:"reportedAt"`
}

const contentCaseSQL = `SELECT c.case_id::text,c.media_id::text,c.user_id::text,coalesce(p.username,''),age_band(c.user_id),u.status,c.purpose,c.result,c.scanner,c.signals,
 c.original_sha256,c.original_bytes,c.content_type,c.suspended_user,c.status,c.created_at,c.hold_until,c.legal_hold,coalesce(c.reviewed_by,''),c.reviewed_at,
 coalesce(c.resolution_note,''),coalesce(c.report_reference,''),c.reported_at
 FROM content_cases c JOIN users u ON u.user_id=c.user_id LEFT JOIN profiles p ON p.user_id=c.user_id `

func scanContentCase(row pgx.Row) (AdminContentCase, error) {
	var c AdminContentCase
	var signals []byte
	if err := row.Scan(&c.CaseID, &c.MediaID, &c.UserID, &c.Username, &c.AgeBand, &c.AccountStatus, &c.Purpose, &c.Result, &c.Scanner, &signals,
		&c.OriginalSHA256, &c.OriginalBytes, &c.ContentType, &c.SuspendedUser, &c.Status, &c.CreatedAt, &c.HoldUntil, &c.LegalHold, &c.ReviewedBy, &c.ReviewedAt,
		&c.ResolutionNote, &c.ReportReference, &c.ReportedAt); err != nil {
		return c, err
	}
	c.Signals = map[string]string{}
	return c, json.Unmarshal(signals, &c.Signals)
}

// AdminContentCases lists cases newest first (status "" for all), at most limit+1 rows from the position
// (before, beforeID), so the caller can tell whether another page exists.
func (s *Store) AdminContentCases(ctx context.Context, status string, limit int, before *time.Time, beforeID string) ([]AdminContentCase, error) {
	var st any
	if status != "" {
		st = status
	}
	var at, id any
	if before != nil {
		at, id = *before, beforeID
	}
	rows, err := s.Pool.Query(ctx, contentCaseSQL+` WHERE ($1::text IS NULL OR c.status=$1) AND ($2::timestamptz IS NULL OR (c.created_at,c.case_id)<($2,$3::uuid))
 ORDER BY c.created_at DESC,c.case_id DESC LIMIT $4`, st, at, id, limit+1)
	if err != nil {
		return nil, err
	}
	cases, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminContentCase, error) { return scanContentCase(row) })
	if cases == nil && err == nil {
		cases = []AdminContentCase{}
	}
	return cases, err
}

// AdminContentCase loads one case.
func (s *Store) AdminContentCase(ctx context.Context, caseID string) (AdminContentCase, error) {
	c, err := scanContentCase(s.Pool.QueryRow(ctx, contentCaseSQL+` WHERE c.case_id=$1`, caseID))
	return c, mapped(err)
}

// HeldCaseKey is the object key of the processed copy of a quarantined photo.
func (s *Store) HeldCaseKey(ctx context.Context, caseID string) (mediaID, key string, err error) {
	var k *string
	err = s.Pool.QueryRow(ctx, `SELECT media_id::text,full_key FROM content_cases WHERE case_id=$1`, caseID).Scan(&mediaID, &k)
	if err != nil || k == nil {
		return "", "", domain.ErrNotFound
	}
	return mediaID, *k, nil
}

// ErrCaseClosed is answered when a content case does not allow the requested step.
var ErrCaseClosed = &domain.PolicyError{Status: 409, Code: "CASE_STATE", Message: "This case is not in a state that allows that"}

// ContentCaseStep moves a quarantine case: confirm and clear need an open case, reported needs an open or
// confirmed one and a report reference (the NCMEC CyberTipline number or the authority's reference).
// legalHold, when not nil, sets the legal hold flag (which keeps the evidence past hold_until). hook runs in
// the same transaction, where the console writes its audit entry.
type ContentCaseStep struct {
	Action          string // confirm, clear or reported
	Operator        string
	Note            string
	ReportReference string
	LegalHold       *bool
}

func (s *Store) ResolveContentCase(ctx context.Context, caseID string, step ContentCaseStep, hook ModerationHook) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var status, user string
		if err := tx.QueryRow(ctx, `SELECT status,user_id::text FROM content_cases WHERE case_id=$1 FOR UPDATE`, caseID).Scan(&status, &user); err != nil {
			return mapped(err)
		}
		var next string
		switch {
		case step.Action == "confirm" && status == "open":
			next = "confirmed"
		case step.Action == "clear" && status == "open":
			next = "cleared"
		case step.Action == "reported" && (status == "open" || status == "confirmed") && step.ReportReference != "":
			next = "reported"
		default:
			return ErrCaseClosed
		}
		// A confirmed or reported case is evidence: it is held until a person lifts the hold.
		_, err := tx.Exec(ctx, `UPDATE content_cases SET status=$2,reviewed_by=$3,reviewed_at=now(),resolution_note=$4,
 report_reference=CASE WHEN $2='reported' THEN $5 ELSE report_reference END,reported_at=CASE WHEN $2='reported' THEN now() ELSE reported_at END,
 legal_hold=CASE WHEN $6::boolean IS NOT NULL THEN $6 WHEN $2 IN ('confirmed','reported') THEN true ELSE legal_hold END WHERE case_id=$1`,
			caseID, next, step.Operator, step.Note, step.ReportReference, step.LegalHold)
		if err != nil {
			return err
		}
		if hook != nil {
			return hook(ctx, tx, user)
		}
		return nil
	})
}
