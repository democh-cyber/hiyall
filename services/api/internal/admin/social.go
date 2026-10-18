package admin

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"hiyall/services/api/internal/domain"
)

// The notice board and the support inbox (docs/security/15-admin-console.md, docs/api/27-stories-notices-support.md).
//
//	GET  notices, support/threads                    viewer
//	GET  support/threads/{id}                        viewer (the thread's text: audited before it is read)
//	POST notices, PUT notices/{id}, POST notices/{id}/unpublish   admin (a reason, audited in the same transaction)
//	POST support/threads/{id}/reply|close|reopen|assign           moderator (audited in the same transaction)
//
// Support messages are plaintext the member knew staff would read; the console never shows more about the member
// than a case does (username, display name, age band, account status).
func (s *Server) routeSocial() {
	s.handle("GET", "/admin/v1/notices", RoleViewer, s.listNotices)
	s.handle("POST", "/admin/v1/notices", RoleAdmin, s.createNotice)
	s.handle("PUT", "/admin/v1/notices/{id}", RoleAdmin, s.updateNotice)
	s.handle("POST", "/admin/v1/notices/{id}/unpublish", RoleAdmin, s.unpublishNotice)

	s.handle("GET", "/admin/v1/support/threads", RoleViewer, s.listSupportThreads)
	s.handle("GET", "/admin/v1/support/threads/{id}", RoleViewer, s.getSupportThread)
	s.handle("POST", "/admin/v1/support/threads/{id}/reply", RoleModerator, s.replySupport)
	s.handle("POST", "/admin/v1/support/threads/{id}/close", RoleModerator, s.closeSupport)
	s.handle("POST", "/admin/v1/support/threads/{id}/reopen", RoleModerator, s.reopenSupport)
	s.handle("POST", "/admin/v1/support/threads/{id}/assign", RoleModerator, s.assignSupport)
}

// auditTx appends an audit entry inside the transaction of the action it records.
func auditTx(ctx context.Context, tx pgx.Tx, p *Principal, action, targetType, targetID, reason string, detail map[string]any) error {
	id := p.Operator.ID
	return insertAudit(ctx, tx, AuditEntry{OperatorID: &id, Actor: p.Operator.Email, Action: action, TargetType: targetType, TargetID: targetID, Reason: reason, IP: p.IP, Detail: detail})
}

// ---- Notices.

// NoticeRecord is a notice as the console lists it.
type NoticeRecord struct {
	NoticeID      string     `json:"noticeId"`
	Category      string     `json:"category"`
	Title         string     `json:"title"`
	Body          string     `json:"body"`
	Audience      string     `json:"audience"`
	Locale        string     `json:"locale"`
	Pinned        bool       `json:"pinned"`
	PublishedAt   time.Time  `json:"publishedAt"`
	ExpiresAt     *time.Time `json:"expiresAt"`
	UnpublishedAt *time.Time `json:"unpublishedAt"`
	CreatedBy     string     `json:"createdBy"`
	UpdatedAt     time.Time  `json:"updatedAt"`
	// Status is live, scheduled (published_at in the future), ended (expired) or unpublished.
	Status string `json:"status"`
}

const noticeSelect = `SELECT n.notice_id::text,n.category,n.title,n.body,n.audience,n.locale,n.pinned,n.published_at,n.expires_at,n.unpublished_at,o.display_name,n.updated_at,
 CASE WHEN n.unpublished_at IS NOT NULL THEN 'unpublished' WHEN n.published_at>now() THEN 'scheduled' WHEN n.expires_at IS NOT NULL AND n.expires_at<=now() THEN 'ended' ELSE 'live' END AS status
 FROM notices n JOIN operators o ON o.operator_id=n.created_by`

func scanNoticeRecord(row pgx.CollectableRow) (NoticeRecord, error) {
	var n NoticeRecord
	err := row.Scan(&n.NoticeID, &n.Category, &n.Title, &n.Body, &n.Audience, &n.Locale, &n.Pinned, &n.PublishedAt, &n.ExpiresAt, &n.UnpublishedAt, &n.CreatedBy, &n.UpdatedAt, &n.Status)
	return n, err
}

func (s *Server) listNotices(w http.ResponseWriter, r *http.Request, p *Principal) {
	q := r.URL.Query()
	status := q.Get("status")
	if status == "" {
		status = "all"
	}
	if status != "all" && status != "live" && status != "scheduled" && status != "ended" && status != "unpublished" {
		s.fail(w, r, &domain.ValidationError{Field: "status", Message: "must be all, live, scheduled, ended or unpublished"})
		return
	}
	limit, err := limitParam(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	filter := filterKey(status)
	var at *time.Time
	after := "00000000-0000-0000-0000-000000000000"
	if raw := q.Get("cursor"); raw != "" {
		c, ok := s.openCursor(raw, "notices", p.Operator.ID, filter)
		if !ok || !domain.IsID(c.ID) {
			s.failure(w, r, 422, "INVALID_CURSOR", "Reload the list")
			return
		}
		t := c.At
		at, after = &t, c.ID
	}
	rows, err := s.svc.Pool.Query(r.Context(), `SELECT * FROM (`+noticeSelect+`) x WHERE ($1='all' OR x.status=$1)
 AND ($2::timestamptz IS NULL OR (x.published_at,x.notice_id)<($2,$3)) ORDER BY x.published_at DESC,x.notice_id DESC LIMIT $4`, status, at, after, limit+1)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	items, err := pgx.CollectRows(rows, scanNoticeRecord)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var next any
	if len(items) > limit {
		items = items[:limit]
		last := items[limit-1]
		next = s.signCursor(cursor{Kind: "notices", Op: p.Operator.ID, Filter: filter, At: last.PublishedAt, ID: last.NoticeID})
	}
	if items == nil {
		items = []NoticeRecord{}
	}
	s.ok(w, r, map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil})
}

type noticeBody struct {
	domain.NewNotice
	Reason string `json:"reason"`
}

func (s *Server) readNotice(w http.ResponseWriter, r *http.Request) (noticeBody, string, bool) {
	var b noticeBody
	if err := decode(w, r, &b); err != nil {
		s.fail(w, r, err)
		return b, "", false
	}
	reason, err := Reason(b.Reason)
	if err != nil {
		s.fail(w, r, err)
		return b, "", false
	}
	if err = b.NewNotice.Validate(s.svc.Now()); err != nil {
		s.fail(w, r, err)
		return b, "", false
	}
	return b, reason, true
}

func noticeDetail(n domain.NewNotice) map[string]any {
	return map[string]any{"category": n.Category, "audience": n.Audience, "locale": n.Locale, "pinned": n.Pinned, "title": n.Title}
}

func (s *Server) createNotice(w http.ResponseWriter, r *http.Request, p *Principal) {
	b, reason, ok := s.readNotice(w, r)
	if !ok {
		return
	}
	id := newUUID()
	err := s.svc.inTx(r.Context(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(r.Context(), `INSERT INTO notices(notice_id,category,title,body,audience,locale,pinned,published_at,expires_at,created_by,updated_by)
 VALUES($1,$2,$3,$4,$5,$6,$7,coalesce($8,now()),$9,$10,$10)`, id, b.Category, b.Title, b.Body, b.Audience, b.Locale, b.Pinned, b.PublishedAt, b.ExpiresAt, p.Operator.ID); err != nil {
			return err
		}
		return auditTx(r.Context(), tx, p, "notice_publish", "notice", id, reason, noticeDetail(b.NewNotice))
	})
	s.respondNotice(w, r, id, err, http.StatusCreated)
}

func (s *Server) updateNotice(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	b, reason, ok := s.readNotice(w, r)
	if !ok {
		return
	}
	err := s.svc.inTx(r.Context(), func(tx pgx.Tx) error {
		tag, err := tx.Exec(r.Context(), `UPDATE notices SET category=$2,title=$3,body=$4,audience=$5,locale=$6,pinned=$7,published_at=coalesce($8,published_at),expires_at=$9,updated_by=$10,updated_at=now()
 WHERE notice_id=$1 AND unpublished_at IS NULL`, id, b.Category, b.Title, b.Body, b.Audience, b.Locale, b.Pinned, b.PublishedAt, b.ExpiresAt, p.Operator.ID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		return auditTx(r.Context(), tx, p, "notice_edit", "notice", id, reason, noticeDetail(b.NewNotice))
	})
	s.respondNotice(w, r, id, err, http.StatusOK)
}

func (s *Server) unpublishNotice(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body struct {
		Reason string `json:"reason"`
	}
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	reason, err := Reason(body.Reason)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	err = s.svc.inTx(r.Context(), func(tx pgx.Tx) error {
		var title string
		if err := tx.QueryRow(r.Context(), `UPDATE notices SET unpublished_at=now(),updated_by=$2,updated_at=now() WHERE notice_id=$1 AND unpublished_at IS NULL RETURNING title`, id, p.Operator.ID).Scan(&title); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return domain.ErrNotFound
			}
			return err
		}
		return auditTx(r.Context(), tx, p, "notice_unpublish", "notice", id, reason, map[string]any{"title": title})
	})
	s.respondNotice(w, r, id, err, http.StatusOK)
}

func (s *Server) respondNotice(w http.ResponseWriter, r *http.Request, id string, err error, status int) {
	if err != nil {
		s.fail(w, r, err)
		return
	}
	rows, err := s.svc.Pool.Query(r.Context(), noticeSelect+` WHERE n.notice_id=$1`, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	n, err := pgx.CollectOneRow(rows, scanNoticeRecord)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.write(w, r, status, map[string]any{"success": true, "data": n})
}

// ---- Support inbox.

// SupportMember is what the console shows of the member behind a thread.
type SupportMember struct {
	UserID      string `json:"userId"`
	Username    string `json:"username"`
	DisplayName string `json:"displayName"`
	AgeBand     string `json:"ageBand"`
	Status      string `json:"status"`
}

// SupportThreadRecord is one thread in the inbox. It carries no message text: reading a thread is its own audited call.
type SupportThreadRecord struct {
	ThreadID      string        `json:"threadId"`
	Category      string        `json:"category"`
	Status        string        `json:"status"`
	Member        SupportMember `json:"member"`
	AssignedTo    *string       `json:"assignedTo"`
	AssignedToMe  bool          `json:"assignedToMe"`
	CreatedAt     time.Time     `json:"createdAt"`
	LastMessageAt time.Time     `json:"lastMessageAt"`
	LastAuthor    string        `json:"lastAuthor"`
	MessageCount  int           `json:"messageCount"`
}

// SupportMessageRecord is one message of a thread as staff read it.
type SupportMessageRecord struct {
	MessageID string    `json:"messageId"`
	Author    string    `json:"author"`
	Operator  *string   `json:"operator"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"createdAt"`
}

const supportSelect = `SELECT t.thread_id::text,t.category,t.status,u.user_id::text,coalesce(p.username,''),coalesce(p.data->>'displayName',''),age_band(u.user_id),u.status,
 ao.display_name,t.assigned_to IS NOT NULL AND t.assigned_to=$1,t.created_at,t.last_message_at,t.last_author,(SELECT count(*) FROM support_messages m WHERE m.thread_id=t.thread_id)::int
 FROM support_threads t JOIN users u ON u.user_id=t.user_id LEFT JOIN profiles p ON p.user_id=t.user_id LEFT JOIN operators ao ON ao.operator_id=t.assigned_to`

func scanSupportThread(row pgx.CollectableRow) (SupportThreadRecord, error) {
	var t SupportThreadRecord
	err := row.Scan(&t.ThreadID, &t.Category, &t.Status, &t.Member.UserID, &t.Member.Username, &t.Member.DisplayName, &t.Member.AgeBand, &t.Member.Status,
		&t.AssignedTo, &t.AssignedToMe, &t.CreatedAt, &t.LastMessageAt, &t.LastAuthor, &t.MessageCount)
	return t, err
}

func (s *Server) listSupportThreads(w http.ResponseWriter, r *http.Request, p *Principal) {
	q := r.URL.Query()
	status := q.Get("status")
	if status == "" {
		status = "open"
	}
	if status != "open" && status != "closed" && status != "all" {
		s.fail(w, r, &domain.ValidationError{Field: "status", Message: "must be open, closed or all"})
		return
	}
	category := q.Get("category")
	if category != "" {
		if _, err := domain.ParseSupportCategory(category); err != nil {
			s.fail(w, r, err)
			return
		}
	}
	waiting := q.Get("waiting") == "true"
	assigned := q.Get("assigned")
	if assigned != "" && assigned != "me" && assigned != "none" {
		s.fail(w, r, &domain.ValidationError{Field: "assigned", Message: "must be me or none"})
		return
	}
	// oldest (default for the work queue) lists the thread that has waited longest first; newest the latest activity.
	sortOldest := q.Get("sort") != "newest"
	limit, err := limitParam(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	filter := filterKey(status, category, strconv.FormatBool(waiting), assigned, strconv.FormatBool(sortOldest))
	var at *time.Time
	after := "00000000-0000-0000-0000-000000000000"
	if raw := q.Get("cursor"); raw != "" {
		c, ok := s.openCursor(raw, "support", p.Operator.ID, filter)
		if !ok || !domain.IsID(c.ID) {
			s.failure(w, r, 422, "INVALID_CURSOR", "Reload the inbox")
			return
		}
		t := c.At
		at, after = &t, c.ID
	}
	cmp, order := "<", "DESC"
	if sortOldest {
		cmp, order = ">", "ASC"
	}
	rows, err := s.svc.Pool.Query(r.Context(), supportSelect+` WHERE ($2='all' OR t.status=$2) AND ($3='' OR t.category=$3) AND (NOT $4 OR (t.last_author='member' AND t.status='open'))
 AND ($5='' OR ($5='me' AND t.assigned_to=$1) OR ($5='none' AND t.assigned_to IS NULL))
 AND ($6::timestamptz IS NULL OR (t.last_message_at,t.thread_id)`+cmp+`($6,$7::uuid)) ORDER BY t.last_message_at `+order+`,t.thread_id `+order+` LIMIT $8`,
		p.Operator.ID, status, category, waiting, assigned, at, after, limit+1)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	items, err := pgx.CollectRows(rows, scanSupportThread)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var next any
	if len(items) > limit {
		items = items[:limit]
		last := items[limit-1]
		next = s.signCursor(cursor{Kind: "support", Op: p.Operator.ID, Filter: filter, At: last.LastMessageAt, ID: last.ThreadID})
	}
	if items == nil {
		items = []SupportThreadRecord{}
	}
	s.ok(w, r, map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil})
}

func (s *Server) supportThread(ctx context.Context, q interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, operator, id string) (SupportThreadRecord, error) {
	rows, err := q.Query(ctx, supportSelect+` WHERE t.thread_id=$2`, operator, id)
	if err != nil {
		return SupportThreadRecord{}, err
	}
	t, err := pgx.CollectOneRow(rows, scanSupportThread)
	if errors.Is(err, pgx.ErrNoRows) {
		err = domain.ErrNotFound
	}
	return t, err
}

// getSupportThread reads a thread's text. The view is audited first, and a thread that cannot be audited is not read.
func (s *Server) getSupportThread(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	ctx := r.Context()
	thread, err := s.supportThread(ctx, s.svc.Pool, p.Operator.ID, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err = s.audited(ctx, p, "support_thread_view", "support_thread", id, map[string]any{"category": thread.Category}); err != nil {
		s.fail(w, r, err)
		return
	}
	rows, err := s.svc.Pool.Query(ctx, `SELECT m.message_id::text,m.author,o.display_name,m.body,m.created_at FROM support_messages m LEFT JOIN operators o ON o.operator_id=m.operator_id
 WHERE m.thread_id=$1 ORDER BY m.created_at,m.message_id LIMIT 500`, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	msgs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (SupportMessageRecord, error) {
		var m SupportMessageRecord
		return m, row.Scan(&m.MessageID, &m.Author, &m.Operator, &m.Body, &m.CreatedAt)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if msgs == nil {
		msgs = []SupportMessageRecord{}
	}
	s.ok(w, r, map[string]any{"thread": thread, "messages": msgs})
}

func (s *Server) replySupport(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var in struct {
		Body string `json:"body"`
	}
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if err := decode(w, r, &in); err != nil {
		s.fail(w, r, err)
		return
	}
	body, err := domain.ParseSupportBody(in.Body)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var msg SupportMessageRecord
	err = s.svc.inTx(r.Context(), func(tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(r.Context(), `SELECT status FROM support_threads WHERE thread_id=$1 FOR UPDATE`, id).Scan(&status); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return domain.ErrNotFound
			}
			return err
		}
		if status != "open" {
			return domain.ErrSupportThreadClosed
		}
		msg = SupportMessageRecord{MessageID: newUUID(), Author: "staff", Body: body}
		name := p.Operator.DisplayName
		msg.Operator = &name
		if err := tx.QueryRow(r.Context(), `INSERT INTO support_messages(message_id,thread_id,author,operator_id,body) VALUES($1,$2,'staff',$3,$4) RETURNING created_at`, msg.MessageID, id, p.Operator.ID, body).Scan(&msg.CreatedAt); err != nil {
			return err
		}
		// The member's own pointer is left alone: this message is unread for them until they open the thread. The
		// API sends the content-free push from support_messages.pushed_at IS NULL.
		if _, err := tx.Exec(r.Context(), `UPDATE support_threads SET last_message_at=$2,last_author='staff',assigned_to=coalesce(assigned_to,$3) WHERE thread_id=$1`, id, msg.CreatedAt, p.Operator.ID); err != nil {
			return err
		}
		return auditTx(r.Context(), tx, p, "support_reply", "support_thread", id, "", map[string]any{"messageId": msg.MessageID, "length": len([]rune(body))})
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.write(w, r, http.StatusCreated, map[string]any{"success": true, "data": msg})
}

func (s *Server) closeSupport(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.setSupportStatus(w, r, p, "closed")
}

func (s *Server) reopenSupport(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.setSupportStatus(w, r, p, "open")
}

func (s *Server) setSupportStatus(w http.ResponseWriter, r *http.Request, p *Principal, to string) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	from, action := "open", "support_close"
	if to == "open" {
		from, action = "closed", "support_reopen"
	}
	err := s.svc.inTx(r.Context(), func(tx pgx.Tx) error {
		var tag pgconn.CommandTag
		var err error
		if to == "closed" {
			tag, err = tx.Exec(r.Context(), `UPDATE support_threads SET status='closed',closed_at=now() WHERE thread_id=$1 AND status=$2`, id, from)
		} else {
			tag, err = tx.Exec(r.Context(), `UPDATE support_threads SET status='open',closed_at=NULL WHERE thread_id=$1 AND status=$2`, id, from)
		}
		if err != nil {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "23505" {
				return domain.ErrSupportThreadOpen
			}
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		return auditTx(r.Context(), tx, p, action, "support_thread", id, "", nil)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	thread, err := s.supportThread(r.Context(), s.svc.Pool, p.Operator.ID, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, thread)
}

// assignSupport sets or clears the thread's owner: {"assignTo":"me"} or {"assignTo":null}.
func (s *Server) assignSupport(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var in struct {
		AssignTo *string `json:"assignTo"`
	}
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if err := decode(w, r, &in); err != nil {
		s.fail(w, r, err)
		return
	}
	var to any
	if in.AssignTo != nil {
		if *in.AssignTo != "me" {
			s.fail(w, r, &domain.ValidationError{Field: "assignTo", Message: "must be me or null"})
			return
		}
		to = p.Operator.ID
	}
	err := s.svc.inTx(r.Context(), func(tx pgx.Tx) error {
		tag, err := tx.Exec(r.Context(), `UPDATE support_threads SET assigned_to=$2 WHERE thread_id=$1`, id, to)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		return auditTx(r.Context(), tx, p, "support_assign", "support_thread", id, "", map[string]any{"assigned": in.AssignTo != nil})
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	thread, err := s.supportThread(r.Context(), s.svc.Pool, p.Operator.ID, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, thread)
}

func newUUID() string { return uuid.Must(uuid.NewV7()).String() }
