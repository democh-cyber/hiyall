package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"hiyall/services/api/internal/domain"
)

// The notice board and in-app support, member side (docs/api/27-stories-notices-support.md). The console's side
// (publishing, replying) is internal/admin.

// noticeLive is the condition for a notice a member may be shown: published, not unpublished, not expired, for their
// age band and in their language. $1 is the member, $2 their language (a lower-case primary subtag, or ”).
const noticeLive = `n.unpublished_at IS NULL AND n.published_at<=now() AND (n.expires_at IS NULL OR n.expires_at>now())
 AND (n.audience='all' OR (n.audience='minors' AND age_band($1)='minor') OR (n.audience='adults' AND age_band($1)<>'minor'))
 AND (n.locale='' OR split_part(lower(n.locale),'-',1)=$2)`

// NoticeLocale reduces a language tag from the client (en, pt-BR, hi_IN) to the lower-case primary subtag notices are
// matched on; anything that is not a language tag is "".
func NoticeLocale(tag string) string {
	tag = strings.ToLower(strings.TrimSpace(tag))
	if i := strings.IndexAny(tag, "-_"); i >= 0 {
		tag = tag[:i]
	}
	if len(tag) < 2 || len(tag) > 3 || strings.Trim(tag, "abcdefghijklmnopqrstuvwxyz") != "" {
		return ""
	}
	return tag
}

const noticeColumns = `n.notice_id::text,n.category,n.title,n.body,n.pinned,n.published_at,n.expires_at,
 n.published_at>coalesce(ns.seen_at,(SELECT created_at FROM users WHERE user_id=$1))`

func scanNotice(row pgx.CollectableRow) (domain.Notice, error) {
	var n domain.Notice
	return n, row.Scan(&n.NoticeID, &n.Category, &n.Title, &n.Body, &n.Pinned, &n.PublishedAt, &n.ExpiresAt, &n.Unread)
}

// ListNotices pages the notices the member may read, newest first.
func (s *Store) ListNotices(ctx context.Context, viewer, locale string, before *time.Time, beforeID string, limit int) ([]domain.Notice, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+noticeColumns+` FROM notices n LEFT JOIN notice_seen ns ON ns.user_id=$1
 WHERE `+noticeLive+` AND ($3::timestamptz IS NULL OR (n.published_at,n.notice_id)<($3,$4::uuid))
 ORDER BY n.published_at DESC,n.notice_id DESC LIMIT $5`, viewer, NoticeLocale(locale), before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, scanNotice)
	if items == nil && err == nil {
		items = []domain.Notice{}
	}
	return items, err
}

// NoticeSummary is what the Home banner and the unread dot need: how many notices the member has not seen (up to
// BadgeCap) and the live pinned ones (at most 3, safety first).
type NoticeSummary struct {
	UnreadCount int             `json:"unreadCount"`
	UnreadMore  bool            `json:"unreadMore"`
	Pinned      []domain.Notice `json:"pinned"`
}

// NoticeSummary reads the summary for a member.
func (s *Store) NoticeSummary(ctx context.Context, viewer, locale string) (NoticeSummary, error) {
	sum := NoticeSummary{Pinned: []domain.Notice{}}
	lang := NoticeLocale(locale)
	err := s.Pool.QueryRow(ctx, `SELECT count(*)::int FROM (SELECT 1 FROM notices n WHERE `+noticeLive+`
 AND n.published_at>coalesce((SELECT seen_at FROM notice_seen WHERE user_id=$1),(SELECT created_at FROM users WHERE user_id=$1)) LIMIT $3) x`, viewer, lang, BadgeCap+1).Scan(&sum.UnreadCount)
	if err != nil {
		return sum, err
	}
	if sum.UnreadCount > BadgeCap {
		sum.UnreadCount, sum.UnreadMore = BadgeCap, true
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+noticeColumns+` FROM notices n LEFT JOIN notice_seen ns ON ns.user_id=$1
 WHERE `+noticeLive+` AND n.pinned ORDER BY (n.category='safety') DESC,n.published_at DESC,n.notice_id DESC LIMIT 3`, viewer, lang)
	if err != nil {
		return sum, err
	}
	pinned, err := pgx.CollectRows(rows, scanNotice)
	if pinned != nil {
		sum.Pinned = pinned
	}
	return sum, err
}

// MarkNoticesSeen moves the member's pointer to now: everything published so far is read. No notice is tracked
// individually and nothing about what was opened is kept.
func (s *Store) MarkNoticesSeen(ctx context.Context, viewer string) error {
	_, err := s.Pool.Exec(ctx, `INSERT INTO notice_seen(user_id,seen_at) VALUES($1,now()) ON CONFLICT (user_id) DO UPDATE SET seen_at=now()`, viewer)
	return err
}

// ---- Support, member side.

func scanThread(row pgx.CollectableRow) (domain.SupportThread, error) {
	var t domain.SupportThread
	err := row.Scan(&t.ThreadID, &t.Category, &t.Status, &t.CreatedAt, &t.LastMessageAt, &t.Unread, &t.LastAuthor, &t.Preview)
	return t, err
}

const threadColumns = `t.thread_id::text,t.category,t.status,t.created_at,t.last_message_at,(t.last_author='staff' AND t.last_message_at>t.member_read_at),t.last_author,
 coalesce((SELECT left(m.body,140) FROM support_messages m WHERE m.thread_id=t.thread_id ORDER BY m.created_at DESC,m.message_id DESC LIMIT 1),'')`

// SupportThreads pages the member's threads, most recent activity first.
func (s *Store) SupportThreads(ctx context.Context, viewer string, before *time.Time, beforeID string, limit int) ([]domain.SupportThread, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+threadColumns+` FROM support_threads t WHERE t.user_id=$1
 AND ($2::timestamptz IS NULL OR (t.last_message_at,t.thread_id)<($2,$3::uuid)) ORDER BY t.last_message_at DESC,t.thread_id DESC LIMIT $4`, viewer, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, scanThread)
	if items == nil && err == nil {
		items = []domain.SupportThread{}
	}
	return items, err
}

// SupportUnread counts the threads where staff wrote last and the member has not opened since (up to BadgeCap).
func (s *Store) SupportUnread(ctx context.Context, viewer string) (int, error) {
	var n int
	err := s.Pool.QueryRow(ctx, `SELECT count(*)::int FROM (SELECT 1 FROM support_threads WHERE user_id=$1 AND last_author='staff' AND last_message_at>member_read_at LIMIT $2) x`, viewer, BadgeCap).Scan(&n)
	return n, err
}

// SupportThread returns one of the member's threads.
func (s *Store) SupportThread(ctx context.Context, viewer, id string) (domain.SupportThread, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+threadColumns+` FROM support_threads t WHERE t.user_id=$1 AND t.thread_id=$2`, viewer, id)
	if err != nil {
		return domain.SupportThread{}, err
	}
	t, err := pgx.CollectOneRow(rows, scanThread)
	return t, mapped(err)
}

// SupportMessages pages a thread's messages, oldest first. A staff member is never named.
func (s *Store) SupportMessages(ctx context.Context, viewer, thread string, after *time.Time, afterID string, limit int) ([]domain.SupportMessage, error) {
	rows, err := s.Pool.Query(ctx, `SELECT m.message_id::text,m.author,m.body,m.created_at FROM support_messages m JOIN support_threads t ON t.thread_id=m.thread_id
 WHERE t.user_id=$1 AND t.thread_id=$2 AND ($3::timestamptz IS NULL OR (m.created_at,m.message_id)>($3,$4::uuid)) ORDER BY m.created_at,m.message_id LIMIT $5`, viewer, thread, after, afterID, limit)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.SupportMessage, error) {
		var m domain.SupportMessage
		return m, row.Scan(&m.MessageID, &m.Author, &m.Body, &m.CreatedAt)
	})
	if items == nil && err == nil {
		items = []domain.SupportMessage{}
	}
	return items, err
}

// MarkSupportRead moves the member's pointer of a thread to now.
func (s *Store) MarkSupportRead(ctx context.Context, viewer, thread string) error {
	tag, err := s.Pool.Exec(ctx, `UPDATE support_threads SET member_read_at=now() WHERE user_id=$1 AND thread_id=$2`, viewer, thread)
	if err == nil && tag.RowsAffected() == 0 {
		err = domain.ErrNotFound
	}
	return err
}

func isUnique(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

// CreateSupportThread opens a thread with its first message. A member may have one open thread per category
// (409 SUPPORT_THREAD_OPEN) and send SupportMessagesPerDay messages a day, the first of a thread included.
func (s *Store) CreateSupportThread(ctx context.Context, viewer, category, body string, e domain.Entitlements) (string, error) {
	id := newID()
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := capDaily(ctx, tx, viewer, domain.DailySupportMessages, e.SupportMessagesPerDay); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO support_threads(thread_id,user_id,category) VALUES($1,$2,$3)`, id, viewer, category); err != nil {
			if isUnique(err) {
				return domain.ErrSupportThreadOpen
			}
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO support_messages(message_id,thread_id,author,body) VALUES($1,$2,'member',$3)`, newID(), id, body)
		return err
	})
	return id, err
}

// AddSupportMessage appends the member's message to one of their open threads.
func (s *Store) AddSupportMessage(ctx context.Context, viewer, thread, body string, e domain.Entitlements) (domain.SupportMessage, error) {
	var m domain.SupportMessage
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM support_threads WHERE thread_id=$1 AND user_id=$2 FOR UPDATE`, thread, viewer).Scan(&status); err != nil {
			return mapped(err)
		}
		if status != "open" {
			return domain.ErrSupportThreadClosed
		}
		if err := capDaily(ctx, tx, viewer, domain.DailySupportMessages, e.SupportMessagesPerDay); err != nil {
			return err
		}
		m = domain.SupportMessage{MessageID: newID(), Author: "member", Body: body}
		if err := tx.QueryRow(ctx, `INSERT INTO support_messages(message_id,thread_id,author,body) VALUES($1,$2,'member',$3) RETURNING created_at`, m.MessageID, thread, body).Scan(&m.CreatedAt); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE support_threads SET last_message_at=$2,last_author='member',member_read_at=$2 WHERE thread_id=$1`, thread, m.CreatedAt)
		return err
	})
	return m, err
}

// CloseSupportThread lets the member close their own thread (staff can reopen it).
func (s *Store) CloseSupportThread(ctx context.Context, viewer, thread string) error {
	tag, err := s.Pool.Exec(ctx, `UPDATE support_threads SET status='closed',closed_at=now() WHERE thread_id=$1 AND user_id=$2 AND status='open'`, thread, viewer)
	if err == nil && tag.RowsAffected() == 0 {
		err = domain.ErrNotFound
	}
	return err
}

// SupportRetention is how long a closed thread is kept: 365 days after it closed.
const SupportRetention = 365 * 24 * time.Hour

// PurgeSupportThreads deletes threads that closed more than retain ago, with their messages (cascade), at most
// batch per call. The maintenance loop runs it with SupportRetention.
func (s *Store) PurgeSupportThreads(ctx context.Context, retain time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM support_threads WHERE thread_id IN (SELECT thread_id FROM support_threads WHERE status='closed' AND closed_at<now()-$1::interval ORDER BY closed_at LIMIT $2)`, retain, batch)
	return tag.RowsAffected(), err
}

// ClaimSupportPushes takes up to limit staff messages whose push has not been sent and marks them sent, returning
// the members to wake (one entry per member). Several API nodes can call it at once: each message goes to one.
func (s *Store) ClaimSupportPushes(ctx context.Context, limit int) ([]string, error) {
	rows, err := s.Pool.Query(ctx, `WITH due AS (SELECT message_id FROM support_messages WHERE author='staff' AND pushed_at IS NULL ORDER BY created_at LIMIT $1 FOR UPDATE SKIP LOCKED),
 mark AS (UPDATE support_messages m SET pushed_at=now() FROM due WHERE m.message_id=due.message_id RETURNING m.thread_id)
 SELECT DISTINCT t.user_id::text FROM mark JOIN support_threads t ON t.thread_id=mark.thread_id`, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}
