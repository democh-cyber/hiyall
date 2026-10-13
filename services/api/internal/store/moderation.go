package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Read models of the admin console (docs/security/15-admin-console.md). They are deliberately narrow:
// a member is shown by name, username, age band, account status and report counts, never by birth date,
// location, visitors, messages or contact details, and an encrypted image by id, size and hash only.
// Nothing here reads the messages or chat_blobs object keys, and a shared image's descriptor (which holds
// its key) is dropped before the case leaves this file.

// AdminMember is the moderation summary of one account.
type AdminMember struct {
	UserID                string    `json:"userId"`
	Username              string    `json:"username"`
	DisplayName           string    `json:"displayName"`
	AgeBand               string    `json:"ageBand"` // "minor" (under 18) or "adult"; never the age or the birth date
	Status                string    `json:"status"`
	CreatedAt             time.Time `json:"createdAt"`
	ReportsAgainst        int       `json:"reportsAgainst"`
	OpenReportsAgainst    int       `json:"openReportsAgainst"`
	ReportsFiled          int       `json:"reportsFiled"`
	ReportsFiledDismissed int       `json:"reportsFiledDismissed"`
}

// AdminReportRow is one line of the report queue.
type AdminReportRow struct {
	ReportID         string     `json:"reportId"`
	TargetType       string     `json:"targetType"`
	TargetID         string     `json:"targetId"`
	ReasonCode       string     `json:"reasonCode"`
	Severity         string     `json:"severity"`
	Status           string     `json:"status"`
	Minor            bool       `json:"minor"` // the reporter or the reported member is under 18
	ReporterMinor    bool       `json:"reporterMinor"`
	SubjectMinor     bool       `json:"subjectMinor"`
	SubjectID        string     `json:"subjectId"`
	SubjectName      string     `json:"subjectUsername"`
	PriorReportCount int        `json:"priorReportCount"`
	EvidenceCount    int        `json:"evidenceCount"`
	HeldImageCount   int        `json:"heldImageCount"`
	CreatedAt        time.Time  `json:"createdAt"`
	ResolvedAt       *time.Time `json:"resolvedAt"`

	// Sort keys of the queue order, for the cursor.
	MinorRank int `json:"-"`
	SevRank   int `json:"-"`
}

// AdminEvidence is one message the reporter chose to share, with the blob ids of the images that came
// with it (their sizes and hashes are in AdminCase.HeldImages). The descriptor is never here.
type AdminEvidence struct {
	MessageID    string    `json:"messageId"`
	Text         string    `json:"text"`
	SentAt       time.Time `json:"sentAt"`
	FromReporter bool      `json:"fromReporter"`
	ImageBlobIDs []string  `json:"imageBlobIds"`
}

// AdminBlob is an encrypted image held for a report: identifiers, size and hash, never a key.
type AdminBlob struct {
	BlobID    string `json:"blobId"`
	Role      string `json:"role"`
	SizeBytes int64  `json:"sizeBytes"`
	SHA256    string `json:"sha256"`
	State     string `json:"state"`
}

// AdminReportRef is a report in a member's history.
type AdminReportRef struct {
	ReportID       string     `json:"reportId"`
	ReasonCode     string     `json:"reasonCode"`
	Severity       string     `json:"severity"`
	Status         string     `json:"status"`
	ResolutionCode string     `json:"resolutionCode"`
	CreatedAt      time.Time  `json:"createdAt"`
	ResolvedAt     *time.Time `json:"resolvedAt"`
}

// AdminAction is a moderation action taken about a member.
type AdminAction struct {
	ActionID  string    `json:"actionId"`
	ReportID  *string   `json:"reportId"`
	Actor     string    `json:"actor"`
	Type      string    `json:"type"`
	Note      string    `json:"note"`
	CreatedAt time.Time `json:"createdAt"`
}

// AdminCase is everything an operator sees about one report.
type AdminCase struct {
	AdminReportRow
	Description       string           `json:"description"`
	DisclosureConsent bool             `json:"disclosureConsent"`
	ResolutionCode    string           `json:"resolutionCode"`
	Reporter          AdminMember      `json:"reporter"`
	Subject           AdminMember      `json:"subject"`
	Evidence          []AdminEvidence  `json:"evidence"`
	HeldImages        []AdminBlob      `json:"heldImages"`
	PriorReports      []AdminReportRef `json:"priorReports"`
	Actions           []AdminAction    `json:"actions"`
}

// AdminUser is the moderation view of an account.
type AdminUser struct {
	AdminMember
	ActiveSessions int              `json:"activeSessions"`
	Reports        []AdminReportRef `json:"reports"`
	Actions        []AdminAction    `json:"actions"`
}

// AdminReportQuery selects a page of reports. Status "open" is the work queue (minor first, then high
// severity, then oldest); any other status lists newest first.
type AdminReportQuery struct {
	Status    string // open, actioned, dismissed or all
	Severity  string // high, normal or "" for both
	MinorOnly bool
	Subject   string // only reports about this member
	Limit     int
	After     *AdminReportKey
}

// AdminReportKey is a position in a report listing: the last row of the previous page.
type AdminReportKey struct {
	MinorRank, SevRank int
	At                 time.Time
	ID                 string
}

// AdminReports lists reports for the console. It returns at most Limit+1 rows so the caller can tell
// whether another page exists.
func (s *Store) AdminReports(ctx context.Context, q AdminReportQuery) ([]AdminReportRow, error) {
	queue := q.Status == "open"
	var status any
	if q.Status != "all" {
		status = q.Status
	}
	var severity any
	if q.Severity != "" {
		severity = q.Severity
	}
	var subject any
	if q.Subject != "" {
		subject = q.Subject
	}
	var mrank, srank any
	var at any
	var id any
	if q.After != nil {
		mrank, srank, at, id = q.After.MinorRank, q.After.SevRank, q.After.At, q.After.ID
	}
	order := `ORDER BY created_at DESC,report_id DESC`
	// $3 and $4 only order the queue; naming their types keeps the statement valid for the newest-first listing.
	after := `($3::int IS NULL OR $4::int IS NULL OR true) AND ($5::timestamptz IS NULL OR (created_at,report_id)<($5,$6::uuid))`
	if queue {
		order = `ORDER BY mrank,srank,created_at,report_id`
		after = `($3::int IS NULL OR (mrank,srank,created_at,report_id)>($3,$4::int,$5,$6::uuid))`
	}
	rows, err := s.Pool.Query(ctx, `SELECT report_id::text,target_type,target_id::text,reason_code,severity,status,minor,reporter_minor,subject_minor,
 subject_id::text,subject_username,prior,evidence_count,held,created_at,resolved_at,mrank,srank
 FROM (
  SELECT r.report_id,r.target_type,r.target_id,r.reason_code,r.severity,r.status,r.created_at,r.resolved_at,r.subject_id,
   coalesce(p.username,'') AS subject_username,
   (age_band(r.reporter_id)='minor' OR age_band(r.subject_id)='minor') AS minor,
   age_band(r.reporter_id)='minor' AS reporter_minor,age_band(r.subject_id)='minor' AS subject_minor,
   CASE WHEN age_band(r.reporter_id)='minor' OR age_band(r.subject_id)='minor' THEN 0 ELSE 1 END AS mrank,
   CASE WHEN r.severity='high' THEN 0 ELSE 1 END AS srank,
   (SELECT count(*) FROM reports o WHERE o.subject_id=r.subject_id AND o.report_id<>r.report_id)::int AS prior,
   CASE WHEN r.evidence IS NULL THEN 0 ELSE jsonb_array_length(r.evidence) END AS evidence_count,
   (SELECT count(*) FROM chat_blobs b WHERE b.held_report_id=r.report_id)::int AS held
  FROM reports r LEFT JOIN profiles p ON p.user_id=r.subject_id
  WHERE ($1::text IS NULL OR r.status=$1) AND ($2::text IS NULL OR r.severity=$2)
 ) x
 WHERE (NOT $7::boolean OR minor) AND ($9::uuid IS NULL OR subject_id=$9) AND `+after+`
 `+order+` LIMIT $8`, status, severity, mrank, srank, at, id, q.MinorOnly, q.Limit+1, subject)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminReportRow, error) {
		var r AdminReportRow
		return r, row.Scan(&r.ReportID, &r.TargetType, &r.TargetID, &r.ReasonCode, &r.Severity, &r.Status, &r.Minor, &r.ReporterMinor, &r.SubjectMinor,
			&r.SubjectID, &r.SubjectName, &r.PriorReportCount, &r.EvidenceCount, &r.HeldImageCount, &r.CreatedAt, &r.ResolvedAt, &r.MinorRank, &r.SevRank)
	})
}

const memberSummarySQL = `SELECT u.user_id::text,coalesce(p.username,''),coalesce(p.data->>'displayName',''),age_band(u.user_id),u.status,u.created_at,
 (SELECT count(*) FROM reports a WHERE a.subject_id=u.user_id)::int,
 (SELECT count(*) FROM reports a WHERE a.subject_id=u.user_id AND a.status='open')::int,
 (SELECT count(*) FROM reports f WHERE f.reporter_id=u.user_id)::int,
 (SELECT count(*) FROM reports f WHERE f.reporter_id=u.user_id AND f.status='dismissed')::int
 FROM users u LEFT JOIN profiles p ON p.user_id=u.user_id WHERE u.user_id=$1`

func (s *Store) adminMember(ctx context.Context, id string) (AdminMember, error) {
	var m AdminMember
	err := s.Pool.QueryRow(ctx, memberSummarySQL, id).Scan(&m.UserID, &m.Username, &m.DisplayName, &m.AgeBand, &m.Status, &m.CreatedAt,
		&m.ReportsAgainst, &m.OpenReportsAgainst, &m.ReportsFiled, &m.ReportsFiledDismissed)
	return m, mapped(err)
}

func (s *Store) adminReportRefs(ctx context.Context, subject, except string, limit int) ([]AdminReportRef, error) {
	rows, err := s.Pool.Query(ctx, `SELECT report_id::text,reason_code,severity,status,coalesce(resolution_code,''),created_at,resolved_at
 FROM reports WHERE subject_id=$1 AND ($2::text='' OR report_id<>$2::uuid) ORDER BY created_at DESC,report_id DESC LIMIT $3`, subject, except, limit)
	if err != nil {
		return nil, err
	}
	refs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminReportRef, error) {
		var r AdminReportRef
		return r, row.Scan(&r.ReportID, &r.ReasonCode, &r.Severity, &r.Status, &r.ResolutionCode, &r.CreatedAt, &r.ResolvedAt)
	})
	if refs == nil && err == nil {
		refs = []AdminReportRef{}
	}
	return refs, err
}

func (s *Store) adminActions(ctx context.Context, subject string, limit int) ([]AdminAction, error) {
	rows, err := s.Pool.Query(ctx, `SELECT action_id::text,report_id::text,actor,action_type,coalesce(note,''),created_at
 FROM moderation_actions WHERE subject_id=$1 ORDER BY created_at DESC,action_id DESC LIMIT $2`, subject, limit)
	if err != nil {
		return nil, err
	}
	actions, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminAction, error) {
		var a AdminAction
		return a, row.Scan(&a.ActionID, &a.ReportID, &a.Actor, &a.Type, &a.Note, &a.CreatedAt)
	})
	if actions == nil && err == nil {
		actions = []AdminAction{}
	}
	return actions, err
}

// AdminCase loads one report for an operator: the reporter and reported member in summary, what the
// reporter chose to share, the held images by id, size and hash, the subject's other reports and every
// earlier action about them. It never reads message rows: only text the reporter selected is shown.
func (s *Store) AdminCase(ctx context.Context, reportID string) (AdminCase, error) {
	var c AdminCase
	var reporter, subject string
	var evidence []byte
	err := s.Pool.QueryRow(ctx, `SELECT r.report_id::text,r.target_type,r.target_id::text,r.reason_code,r.severity,r.status,
 (age_band(r.reporter_id)='minor' OR age_band(r.subject_id)='minor'),age_band(r.reporter_id)='minor',age_band(r.subject_id)='minor',
 r.subject_id::text,coalesce(p.username,''),r.created_at,r.resolved_at,
 coalesce(r.description,''),r.disclosure_consent,coalesce(r.resolution_code,''),r.reporter_id::text,r.evidence
 FROM reports r LEFT JOIN profiles p ON p.user_id=r.subject_id WHERE r.report_id=$1`, reportID).
		Scan(&c.ReportID, &c.TargetType, &c.TargetID, &c.ReasonCode, &c.Severity, &c.Status, &c.Minor, &c.ReporterMinor, &c.SubjectMinor,
			&c.SubjectID, &c.SubjectName, &c.CreatedAt, &c.ResolvedAt, &c.Description, &c.DisclosureConsent, &c.ResolutionCode, &reporter, &evidence)
	if err != nil {
		return c, mapped(err)
	}
	subject = c.SubjectID
	if c.Reporter, err = s.adminMember(ctx, reporter); err != nil {
		return c, err
	}
	if c.Subject, err = s.adminMember(ctx, subject); err != nil {
		return c, err
	}
	c.Evidence = []AdminEvidence{}
	if evidence != nil {
		var shared []domain.Evidence
		if err = json.Unmarshal(evidence, &shared); err != nil {
			return c, err
		}
		for _, e := range shared {
			item := AdminEvidence{MessageID: e.MessageID, Text: e.Text, SentAt: e.SentAt, FromReporter: e.FromMe, ImageBlobIDs: []string{}}
			for _, a := range e.Attachments {
				item.ImageBlobIDs = append(item.ImageBlobIDs, a.BlobIDs...) // the descriptor, which holds the key, is dropped here
			}
			c.Evidence = append(c.Evidence, item)
		}
	}
	c.EvidenceCount, c.PriorReportCount = len(c.Evidence), c.Subject.ReportsAgainst-1
	blobs, err := s.HeldBlobs(ctx, reportID)
	if err != nil {
		return c, err
	}
	c.HeldImages = make([]AdminBlob, 0, len(blobs))
	for _, b := range blobs {
		c.HeldImages = append(c.HeldImages, AdminBlob{BlobID: b.BlobID, Role: b.Role, SizeBytes: b.SizeBytes, SHA256: b.CtSha256, State: b.State})
	}
	c.HeldImageCount = len(c.HeldImages)
	if c.PriorReports, err = s.adminReportRefs(ctx, subject, reportID, 20); err != nil {
		return c, err
	}
	c.Actions, err = s.adminActions(ctx, subject, 50)
	return c, err
}

// AdminUser is the moderation view of an account: status, age band, report history and the number of
// live sessions. No messages, location, visitors or contact details.
func (s *Store) AdminUser(ctx context.Context, userID string) (AdminUser, error) {
	var u AdminUser
	var err error
	if u.AdminMember, err = s.adminMember(ctx, userID); err != nil {
		return u, err
	}
	if err = s.Pool.QueryRow(ctx, `SELECT count(*)::int FROM sessions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>now()`, userID).Scan(&u.ActiveSessions); err != nil {
		return u, err
	}
	if u.Reports, err = s.adminReportRefs(ctx, userID, "", 50); err != nil {
		return u, err
	}
	u.Actions, err = s.adminActions(ctx, userID, 50)
	return u, err
}

// AdminIdentity is how a member signs in: the identity provider and its opaque subject, which is what
// an administrator needs to find the person in the provider's console. It holds no email address; the
// platform does not store one.
type AdminIdentity struct {
	Issuer  string `json:"issuer"`
	Subject string `json:"subject"`
}

// AdminIdentities lists the sign-in identities of an account.
func (s *Store) AdminIdentities(ctx context.Context, userID string) ([]AdminIdentity, error) {
	rows, err := s.Pool.Query(ctx, `SELECT issuer,subject FROM auth_identities WHERE user_id=$1 ORDER BY issuer,subject`, userID)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminIdentity, error) {
		var i AdminIdentity
		return i, row.Scan(&i.Issuer, &i.Subject)
	})
	if ids == nil && err == nil {
		ids = []AdminIdentity{}
	}
	return ids, err
}
