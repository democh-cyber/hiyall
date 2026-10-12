package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/realtime"
)

// quietFrom is true when user $r has muted or restricted user $a. Callers
// substitute the parameter names.
func quietFrom(r, a string) string {
	return `EXISTS(SELECT 1 FROM user_controls qc WHERE qc.actor_id=` + r + ` AND qc.target_id=` + a + ` AND (qc.until IS NULL OR qc.until>now()))`
}

// restrictedPair is true when either user restricted the other. Receipts and
// typing are reciprocal, so a restriction turns them off both ways.
func restrictedPair(a, b string) string {
	return `EXISTS(SELECT 1 FROM user_controls rc WHERE rc.control='restrict' AND ((rc.actor_id=` + a + ` AND rc.target_id=` + b + `) OR (rc.actor_id=` + b + ` AND rc.target_id=` + a + `)))`
}

// Quiet reports whether recipient has muted or restricted actor, so pushes
// from actor's actions should be skipped.
func (s *Store) Quiet(ctx context.Context, recipient, actor string) (bool, error) {
	var quiet bool
	err := s.Pool.QueryRow(ctx, `SELECT `+quietFrom("$1::uuid", "$2::uuid"), recipient, actor).Scan(&quiet)
	return quiet, err
}

// bandBarredSQL is the age-band half of interaction_barred (migration 0017): true while
// age-band isolation is on and a and b are in different bands. Blocks are not part of it.
func bandBarredSQL(a, b string) string {
	return `(age_isolation_enabled() AND age_band(` + a + `)<>age_band(` + b + `))`
}

// knownToSQL is true when viewer may see who subject is in their own safety lists and
// reports: subject has finished onboarding and is in viewer's age band. A block in either
// direction does not hide them (the blocked list shows blocked members too), but another
// age band or an unfinished account does, exactly like their profile.
func knownToSQL(viewer, subject string) string {
	return `(` + memberSQL(subject) + ` AND NOT ` + bandBarredSQL(viewer, subject) + `)`
}

// SetControl adds or removes the actor's mute or restrict on target. Restrict
// has no expiry; mute may. A target in the other age band or that has not finished
// onboarding is missing (404), like their profile; removing a control always works.
func (s *Store) SetControl(ctx context.Context, actor, target, control string, on bool, until *time.Time) error {
	if err := noSelf(actor, target); err != nil {
		return err
	}
	if !on {
		_, err := s.Pool.Exec(ctx, `DELETE FROM user_controls WHERE actor_id=$1 AND target_id=$2 AND control=$3`, actor, target, control)
		return err
	}
	if control == "restrict" {
		until = nil
	}
	tag, err := s.Pool.Exec(ctx, `INSERT INTO user_controls(actor_id,target_id,control,until)
 SELECT $1,u.user_id,$3,$4 FROM users u WHERE u.user_id=$2 AND `+knownToSQL("$1::uuid", "u.user_id")+`
 ON CONFLICT (actor_id,target_id,control) DO UPDATE SET until=excluded.until`, actor, target, control, until)
	if err == nil && tag.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return err
}

// mutedForever stands in for an open-ended mute. Postgres 'infinity' has no
// time.Time equivalent, so a far-future date keeps scans and JSON simple.
var mutedForever = time.Date(9999, 12, 31, 0, 0, 0, 0, time.UTC)

// SetConversationMute mutes the caller's side of a conversation until a time,
// indefinitely (until nil, on), or clears it (on false).
func (s *Store) SetConversationMute(ctx context.Context, user, conversationID string, on bool, until *time.Time) error {
	var value any
	if on {
		value = mutedForever
		if until != nil {
			value = *until
		}
	}
	tag, err := s.Pool.Exec(ctx, `UPDATE conversation_members SET muted_until=$3::timestamptz WHERE user_id=$1 AND conversation_id=$2`, user, conversationID, value)
	if err == nil && tag.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return err
}

// ListControls pages the caller's blocked, muted or restricted accounts,
// newest first. Expired mutes are omitted, and so are muted or restricted accounts the
// caller may not know (knownToSQL); the blocked list shows every block, so it can be undone.
func (s *Store) ListControls(ctx context.Context, actor, kind string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.Control, error) {
	var source string
	switch kind {
	case "blocked":
		source = `SELECT blocked_id AS target_id,created_at,NULL::timestamptz AS until FROM blocks WHERE blocker_id=$1`
	case "muted", "restricted":
		control := map[string]string{"muted": "mute", "restricted": "restrict"}[kind]
		source = `SELECT target_id,created_at,until FROM user_controls WHERE actor_id=$1 AND control='` + control + `' AND (until IS NULL OR until>now()) AND ` + knownToSQL("$1::uuid", "target_id")
	default:
		return nil, domain.ErrNotFound
	}
	rows, err := s.Pool.Query(ctx, `SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,c.created_at,c.until
 FROM (`+source+`) c
 JOIN profiles p ON p.user_id=c.target_id`+avatarJoin("av", "p")+`
 JOIN users u ON u.user_id=c.target_id AND u.status='active'
 WHERE ($2::timestamptz IS NULL OR (c.created_at,c.target_id)<($2,$3::uuid))
 ORDER BY c.created_at DESC,c.target_id DESC LIMIT $4`, actor, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Control, error) {
		var c domain.Control
		var avatar *string
		err := row.Scan(&c.User.UserID, &c.User.Username, &c.User.DisplayName, &avatar, &c.Since, &c.Until)
		c.User.AvatarURL = avatarURL(sign, avatar)
		return c, err
	})
}

// CreateReport records a report. Reporting the same target again while the
// first report is open returns that report with created=false.
func (s *Store) CreateReport(ctx context.Context, reporter string, r domain.NewReport) (domain.Report, bool, error) {
	var subject, conversation string
	var err error
	switch r.TargetType {
	case "user":
		if err = noSelf(reporter, r.TargetID); err != nil {
			return domain.Report{}, false, err
		}
		err = s.Pool.QueryRow(ctx, `SELECT user_id::text FROM users WHERE user_id=$1 AND status<>'deleted'`, r.TargetID).Scan(&subject)
	case "conversation":
		conversation = r.TargetID
		err = s.Pool.QueryRow(ctx, `SELECT peer_id::text FROM conversation_members WHERE user_id=$1 AND conversation_id=$2`, reporter, r.TargetID).Scan(&subject)
	case "message":
		err = s.Pool.QueryRow(ctx, `SELECT cm.peer_id::text,m.conversation_id::text FROM messages m
 JOIN conversation_members cm ON cm.conversation_id=m.conversation_id AND cm.user_id=$1
 WHERE m.message_id=$2`, reporter, r.TargetID).Scan(&subject, &conversation)
	// Public content: the reporter must be able to see it; the subject is its author.
	case "post":
		err = s.Pool.QueryRow(ctx, `SELECT p.author_id::text FROM posts p WHERE p.post_id=$2 AND p.deleted_at IS NULL AND `+visibleTo("p.author_id", "p.audience"), reporter, r.TargetID).Scan(&subject)
	case "comment":
		err = s.Pool.QueryRow(ctx, `SELECT c.author_id::text FROM comments c JOIN posts p ON p.post_id=c.post_id
 WHERE c.comment_id=$2 AND c.deleted_at IS NULL AND (NOT c.hidden OR c.author_id=$1) AND p.deleted_at IS NULL AND `+visibleTo("p.author_id", "p.audience"), reporter, r.TargetID).Scan(&subject)
	case "space":
		x, e := s.Space(ctx, reporter, r.TargetID, nil)
		err = e
		subject = x.Owner.UserID
	case "space_entry":
		var spaceID string
		err = s.Pool.QueryRow(ctx, `SELECT space_id::text,author_id::text FROM space_entries WHERE entry_id=$1 AND deleted_at IS NULL AND `+memberSQL("author_id"), r.TargetID).Scan(&spaceID, &subject)
		if err == nil {
			x, e := s.Space(ctx, reporter, spaceID, nil)
			err = e
			if err == nil && x.MyState != "active" {
				err = domain.ErrNotFound
			}
			if err == nil {
				var blocked bool
				err = s.Pool.QueryRow(ctx, `SELECT NOT (`+unblockedSQL("$1::uuid", "$2::uuid")+`)`, reporter, subject).Scan(&blocked)
				if blocked {
					err = domain.ErrNotFound
				}
			}
		}
	case "story":
		err = s.Pool.QueryRow(ctx, `SELECT st.author_id::text FROM stories st WHERE st.story_id=$2 AND st.deleted_at IS NULL AND `+visibleTo("st.author_id", "st.audience"), reporter, r.TargetID).Scan(&subject)
	}
	if err == nil && subject == reporter {
		err = noSelf(reporter, subject)
	}
	if err != nil {
		return domain.Report{}, false, mapped(err)
	}
	var evidence any
	if len(r.Evidence) > 0 {
		ids := make([]string, len(r.Evidence))
		for i, e := range r.Evidence {
			ids[i] = e.MessageID
		}
		// Sender and time come from the relay's records, not the client.
		rows, err := s.Pool.Query(ctx, `SELECT message_id::text,sender_id::text,created_at FROM messages WHERE conversation_id=$1 AND message_id=ANY($2::uuid[])`, conversation, ids)
		if err != nil {
			return domain.Report{}, false, err
		}
		type meta struct {
			sender string
			at     time.Time
		}
		known := map[string]meta{}
		for rows.Next() {
			var id string
			var m meta
			if err = rows.Scan(&id, &m.sender, &m.at); err != nil {
				rows.Close()
				return domain.Report{}, false, err
			}
			known[id] = m
		}
		rows.Close()
		if len(known) != len(ids) {
			return domain.Report{}, false, &domain.ValidationError{Field: "evidence", Message: "messages must belong to the reported chat"}
		}
		for i := range r.Evidence {
			m := known[r.Evidence[i].MessageID]
			r.Evidence[i].FromMe, r.Evidence[i].SentAt = m.sender == reporter, m.at
		}
		data, _ := json.Marshal(r.Evidence)
		evidence = data
	}
	var description any
	if r.Description != "" {
		description = r.Description
	}
	report := domain.Report{TargetType: r.TargetType, TargetID: r.TargetID, ReasonCode: r.ReasonCode, Status: "open"}
	created := false
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `INSERT INTO reports(report_id,reporter_id,target_type,target_id,subject_id,reason_code,description,evidence,disclosure_consent,severity)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
 ON CONFLICT (reporter_id,target_type,target_id) WHERE status='open' DO NOTHING
 RETURNING report_id::text,created_at`, newID(), reporter, r.TargetType, r.TargetID, subject, r.ReasonCode, description, evidence, r.DisclosureConsent, r.Severity()).
			Scan(&report.ReportID, &report.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // the earlier open report stands, with its own evidence
		}
		if err != nil {
			return err
		}
		created = true
		// Shared images are held against deletion for as long as the report keeps them.
		return holdEvidenceBlobs(ctx, tx, report.ReportID, conversation, r.Evidence)
	})
	if err == nil && !created {
		err = s.Pool.QueryRow(ctx, `SELECT report_id::text,reason_code,created_at FROM reports WHERE reporter_id=$1 AND target_type=$2 AND target_id=$3 AND status='open'`,
			reporter, r.TargetType, r.TargetID).Scan(&report.ReportID, &report.ReasonCode, &report.CreatedAt)
	}
	if err != nil {
		return domain.Report{}, false, err
	}
	// The subject's name is shown only when the reporter may know who they are (knownToSQL).
	err = s.Pool.QueryRow(ctx, `SELECT p.user_id::text,`+reportSubjectName+` FROM profiles p WHERE p.user_id=$2`, reporter, subject).
		Scan(&report.Subject.UserID, &report.Subject.Username, &report.Subject.DisplayName)
	return report, created, mapped(err)
}

// reportSubjectName is the subject's username and display name for reporter $1 and profile
// row p, or two empty strings when the reporter may not know who the subject is: a report
// against a member in the other age band, or not onboarded, is accepted but names nobody.
var reportSubjectName = `CASE WHEN ` + knownToSQL("$1::uuid", "p.user_id") + ` THEN p.username ELSE '' END,
 CASE WHEN ` + knownToSQL("$1::uuid", "p.user_id") + ` THEN coalesce(p.data->>'displayName','') ELSE '' END`

// ListReports pages the caller's own reports and their status. Subjects the caller may not
// know are listed without a name (see reportSubjectName).
func (s *Store) ListReports(ctx context.Context, reporter string, before *time.Time, beforeID string, limit int) ([]domain.Report, error) {
	rows, err := s.Pool.Query(ctx, `SELECT r.report_id::text,r.target_type,r.target_id::text,p.user_id::text,`+reportSubjectName+`,r.reason_code,r.status,r.created_at,r.resolved_at
 FROM reports r JOIN profiles p ON p.user_id=r.subject_id
 WHERE r.reporter_id=$1 AND ($2::timestamptz IS NULL OR (r.created_at,r.report_id)<($2,$3::uuid))
 ORDER BY r.created_at DESC,r.report_id DESC LIMIT $4`, reporter, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Report, error) {
		var r domain.Report
		return r, row.Scan(&r.ReportID, &r.TargetType, &r.TargetID, &r.Subject.UserID, &r.Subject.Username, &r.Subject.DisplayName, &r.ReasonCode, &r.Status, &r.CreatedAt, &r.ResolvedAt)
	})
}

// QueuedReport is the operator's view of an open report.
type QueuedReport struct {
	ReportID, TargetType, TargetID, Reporter, Subject, SubjectName string
	ReasonCode, Severity, Description                              string
	Evidence                                                       []domain.Evidence
	// Blobs are the encrypted images held for this report: ids, sizes and hashes, never keys.
	Blobs        []domain.BlobInfo
	PriorReports int
	CreatedAt    time.Time
}

// ReportQueue lists open reports, high severity first, then oldest first.
func (s *Store) ReportQueue(ctx context.Context, limit int) ([]QueuedReport, error) {
	rows, err := s.Pool.Query(ctx, `SELECT r.report_id::text,r.target_type,r.target_id::text,r.reporter_id::text,r.subject_id::text,p.username,
 r.reason_code,r.severity,coalesce(r.description,''),r.evidence,
 (SELECT count(*) FROM reports o WHERE o.subject_id=r.subject_id AND o.report_id<>r.report_id)::int,r.created_at
 FROM reports r JOIN profiles p ON p.user_id=r.subject_id
 WHERE r.status='open' ORDER BY r.severity='high' DESC,r.created_at LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	queue, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (QueuedReport, error) {
		var q QueuedReport
		var evidence []byte
		err := row.Scan(&q.ReportID, &q.TargetType, &q.TargetID, &q.Reporter, &q.Subject, &q.SubjectName, &q.ReasonCode, &q.Severity, &q.Description, &evidence, &q.PriorReports, &q.CreatedAt)
		if err == nil && evidence != nil {
			err = json.Unmarshal(evidence, &q.Evidence)
		}
		return q, err
	})
	for i := range queue {
		if err == nil {
			queue[i].Blobs, err = s.HeldBlobs(ctx, queue[i].ReportID)
		}
	}
	return queue, err
}

// ResolveReport closes an open report with an operator action. Suspend
// deactivates the subject and revokes their sessions in the same transaction.
func (s *Store) ResolveReport(ctx context.Context, reportID, operator, action, note string) error {
	if action != "dismiss" && action != "warn" && action != "suspend" {
		return &domain.ValidationError{Field: "action", Message: "must be dismiss, warn or suspend"}
	}
	return s.inTx(ctx, func(tx pgx.Tx) error {
		status := map[string]string{"dismiss": "dismissed", "warn": "actioned", "suspend": "actioned"}[action]
		var subject string
		err := tx.QueryRow(ctx, `UPDATE reports SET status=$2,resolved_at=now(),resolution_code=$3 WHERE report_id=$1 AND status='open' RETURNING subject_id::text`, reportID, status, action).Scan(&subject)
		if err != nil {
			return mapped(err)
		}
		if _, err = tx.Exec(ctx, `INSERT INTO moderation_actions(action_id,report_id,actor,subject_id,action_type,note) VALUES($1,$2,$3,$4,$5,nullif($6,''))`, newID(), reportID, operator, subject, action, note); err != nil {
			return err
		}
		if action == "suspend" {
			return suspend(ctx, tx, subject)
		}
		return nil
	})
}

// suspend deactivates the account and revokes every session. The realtime notice is sent on
// commit (NOTIFY is transactional), so every API node listening on the bus ends the account's
// live connections even though the moderation tool is a separate process.
func suspend(ctx context.Context, tx pgx.Tx, user string) error {
	if _, err := tx.Exec(ctx, `UPDATE users SET status='suspended' WHERE user_id=$1 AND status='active'`, user); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at=coalesce(revoked_at,now()) WHERE user_id=$1`, user); err != nil {
		return err
	}
	notice, _ := json.Marshal(realtime.DisconnectEvent(user))
	_, err := tx.Exec(ctx, `SELECT pg_notify($1,$2)`, realtime.Channel, string(notice))
	return err
}

// RestoreUser lifts a suspension, recording who did it and why.
func (s *Store) RestoreUser(ctx context.Context, user, operator, note string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE users SET status='active' WHERE user_id=$1 AND status='suspended'`, user)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		_, err = tx.Exec(ctx, `INSERT INTO moderation_actions(action_id,actor,subject_id,action_type,note) VALUES($1,$2,$3,'restore',nullif($4,''))`, newID(), operator, user, note)
		return err
	})
}
