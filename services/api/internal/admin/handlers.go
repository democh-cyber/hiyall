package admin

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Role matrix (every route checks it server side, in Server.handle):
//
//	login                                   no session
//	logout, me, password                    any signed-in operator
//	GET  reports, reports/{id}, users/{id}  viewer
//	POST reports/{id}/resolve, users/{id}/restore   moderator
//	GET  audit, operators; POST operator disable, enable, role   admin
//	GET  users/{id}?identity=true           admin (audited separately)
//	POST reports/{id}/content, GET media/{id}, GET content-cases(/{id})   moderator (content.go)
//	POST content-cases/{id}/view|reveal|resolve   admin (quarantined uploads)
func (s *Server) routeAPI() {
	s.handle("POST", "/admin/v1/login", "", s.login)
	s.handle("POST", "/admin/v1/logout", RoleViewer, s.logout)
	s.handle("GET", "/admin/v1/me", RoleViewer, s.me)
	s.handle("POST", "/admin/v1/me/password", RoleViewer, s.changePassword)

	s.handle("GET", "/admin/v1/reports", RoleViewer, s.listReports)
	s.handle("GET", "/admin/v1/reports/{id}", RoleViewer, s.getReport)
	s.handle("POST", "/admin/v1/reports/{id}/resolve", RoleModerator, s.resolveReport)
	s.handle("GET", "/admin/v1/users/{id}", RoleViewer, s.getUser)
	s.handle("POST", "/admin/v1/users/{id}/restore", RoleModerator, s.restoreUser)

	s.routeContent()

	s.handle("GET", "/admin/v1/audit", RoleAdmin, s.listAudit)
	s.handle("GET", "/admin/v1/operators", RoleAdmin, s.listOperators)
	s.handle("POST", "/admin/v1/operators/{id}/disable", RoleAdmin, s.disableOperator)
	s.handle("POST", "/admin/v1/operators/{id}/enable", RoleAdmin, s.enableOperator)
	s.handle("POST", "/admin/v1/operators/{id}/role", RoleAdmin, s.setOperatorRole)

	// Anything else under /admin/v1 is a JSON 404, whatever the method.
	s.mux.HandleFunc("/admin/v1/", func(w http.ResponseWriter, r *http.Request) {
		s.failure(w, r, 404, "NOT_FOUND", "Endpoint unavailable")
	})
}

func (s *Server) sessionView(p *Principal) map[string]any {
	return map[string]any{"operator": p.Operator, "csrfToken": p.CSRF, "expiresAt": p.ExpiresAt}
}

func (s *Server) login(w http.ResponseWriter, r *http.Request, _ *Principal) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	sess, err := s.svc.Login(r.Context(), body.Email, body.Password, body.Code, s.clientIP(r))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.setCookie(w, r, sess.Token, sess.ExpiresAt)
	s.ok(w, r, map[string]any{"operator": sess.Operator, "csrfToken": sess.CSRF, "expiresAt": sess.ExpiresAt})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request, p *Principal) {
	if err := s.svc.Logout(r.Context(), p); err != nil {
		s.fail(w, r, err)
		return
	}
	s.setCookie(w, r, "", p.ExpiresAt)
	s.ok(w, r, map[string]bool{"signedOut": true})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.ok(w, r, s.sessionView(p))
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request, p *Principal) {
	var body struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	if err := s.svc.ChangePassword(r.Context(), p, body.Current, body.New, s.clientIP(r)); err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]bool{"changed": true})
}

// audited appends the audit entry of a read before the read runs. If the entry cannot be written
// nothing is returned: a read that cannot be recorded does not happen.
func (s *Server) audited(ctx context.Context, p *Principal, action, targetType, targetID string, detail map[string]any) error {
	id := p.Operator.ID
	return insertAudit(ctx, s.svc.Pool, AuditEntry{OperatorID: &id, Actor: p.Operator.Email, Action: action, TargetType: targetType, TargetID: targetID, IP: p.IP, Detail: detail})
}

func (s *Server) listReports(w http.ResponseWriter, r *http.Request, p *Principal) {
	q := r.URL.Query()
	status := q.Get("status")
	if status == "" {
		status = "open"
	}
	if status != "open" && status != "actioned" && status != "dismissed" && status != "all" {
		s.fail(w, r, &domain.ValidationError{Field: "status", Message: "must be open, actioned, dismissed or all"})
		return
	}
	severity := q.Get("severity")
	if severity != "" && severity != "high" && severity != "normal" {
		s.fail(w, r, &domain.ValidationError{Field: "severity", Message: "must be high or normal"})
		return
	}
	minor := q.Get("minor") == "true"
	if v := q.Get("minor"); v != "" && v != "true" && v != "false" {
		s.fail(w, r, &domain.ValidationError{Field: "minor", Message: "must be true or false"})
		return
	}
	subject := q.Get("subject")
	if subject != "" && !domain.IsID(subject) {
		s.fail(w, r, &domain.ValidationError{Field: "subject", Message: "must be a member id"})
		return
	}
	limit, err := limitParam(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	filter := filterKey(status, severity, strconv.FormatBool(minor), subject)
	query := store.AdminReportQuery{Status: status, Severity: severity, MinorOnly: minor, Subject: subject, Limit: limit}
	if raw := q.Get("cursor"); raw != "" {
		c, ok := s.openCursor(raw, "reports", p.Operator.ID, filter)
		if !ok || !domain.IsID(c.ID) {
			s.failure(w, r, 422, "INVALID_CURSOR", "Reload the queue")
			return
		}
		query.After = &store.AdminReportKey{MinorRank: c.MR, SevRank: c.SR, At: c.At, ID: c.ID}
	}
	rows, err := s.svc.Store.AdminReports(r.Context(), query)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var next any
	if len(rows) > limit {
		rows = rows[:limit]
		last := rows[len(rows)-1]
		next = s.signCursor(cursor{Kind: "reports", Op: p.Operator.ID, Filter: filter, MR: last.MinorRank, SR: last.SevRank, At: last.CreatedAt, ID: last.ReportID})
	}
	s.ok(w, r, map[string]any{"items": rows, "nextCursor": next, "hasMore": next != nil})
}

func (s *Server) getReport(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if err := s.audited(r.Context(), p, "case_view", "report", id, nil); err != nil {
		s.fail(w, r, err)
		return
	}
	c, err := s.svc.Store.AdminCase(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, c)
}

type actionBody struct {
	Action  string `json:"action"`
	Reason  string `json:"reason"`
	Confirm bool   `json:"confirm"`
}

func (s *Server) resolveReport(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body actionBody
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	reason, err := Reason(body.Reason)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if body.Action != "dismiss" && body.Action != "warn" && body.Action != "suspend" {
		s.fail(w, r, &domain.ValidationError{Field: "action", Message: "must be dismiss, warn or suspend"})
		return
	}
	// Suspending cuts a person off at once, so the request must say it was confirmed.
	if body.Action == "suspend" && !body.Confirm {
		s.fail(w, r, &domain.ValidationError{Field: "confirm", Message: "suspending needs confirm: true"})
		return
	}
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	hook := func(ctx context.Context, tx pgx.Tx, subject string) error {
		opID := p.Operator.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &opID, Actor: p.Operator.Email, Action: "report_" + body.Action, TargetType: "report", TargetID: id,
			Reason: reason, IP: p.IP, Detail: map[string]any{"subjectId": subject}})
	}
	// The same store method the moderate CLI calls: one implementation of resolve, with the audit entry in its transaction.
	if err = s.svc.Store.ResolveReportWith(r.Context(), id, p.Operator.Email, body.Action, reason, hook); err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"reportId": id, "action": body.Action})
}

func (s *Server) getUser(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	identity := r.URL.Query().Get("identity") == "true"
	if identity && !p.Operator.Role.Allows(RoleAdmin) {
		s.fail(w, r, ErrForbidden)
		return
	}
	if err := s.audited(r.Context(), p, "user_view", "user", id, nil); err != nil {
		s.fail(w, r, err)
		return
	}
	u, err := s.svc.Store.AdminUser(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := map[string]any{"user": u}
	if identity {
		if err = s.audited(r.Context(), p, "user_identity_view", "user", id, nil); err != nil {
			s.fail(w, r, err)
			return
		}
		if out["identities"], err = s.svc.Store.AdminIdentities(r.Context(), id); err != nil {
			s.fail(w, r, err)
			return
		}
	}
	s.ok(w, r, out)
}

func (s *Server) restoreUser(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body struct {
		Reason string `json:"reason"`
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
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	hook := func(ctx context.Context, tx pgx.Tx, subject string) error {
		opID := p.Operator.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &opID, Actor: p.Operator.Email, Action: "user_restore", TargetType: "user", TargetID: subject, Reason: reason, IP: p.IP})
	}
	err = s.svc.Store.RestoreUserWith(r.Context(), id, p.Operator.Email, reason, hook)
	if errors.Is(err, domain.ErrNotFound) {
		// Tell "no such member" from "not suspended".
		if _, e := s.svc.Store.AdminUser(r.Context(), id); e == nil {
			err = &domain.PolicyError{Status: 409, Code: "NOT_SUSPENDED", Message: "This account is not suspended"}
		}
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"userId": id, "status": "active"})
}

func (s *Server) listAudit(w http.ResponseWriter, r *http.Request, p *Principal) {
	q := r.URL.Query()
	limit, err := limitParam(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	f := AuditFilter{OperatorID: q.Get("operator"), Action: q.Get("action"), TargetID: q.Get("target"), Limit: limit}
	if f.OperatorID != "" && !domain.IsID(f.OperatorID) {
		s.fail(w, r, &domain.ValidationError{Field: "operator", Message: "must be an operator id"})
		return
	}
	if len(f.Action) > 64 || len(f.TargetID) > 128 {
		s.fail(w, r, &domain.ValidationError{Field: "filter", Message: "too long"})
		return
	}
	filter := filterKey(f.OperatorID, f.Action, f.TargetID)
	first := true
	if raw := q.Get("cursor"); raw != "" {
		c, ok := s.openCursor(raw, "audit", p.Operator.ID, filter)
		if !ok || c.Seq < 1 {
			s.failure(w, r, 422, "INVALID_CURSOR", "Reload the audit log")
			return
		}
		f.Before, first = c.Seq, false
	}
	if first { // reading the log is itself recorded, once per visit rather than once per page
		if err = s.audited(r.Context(), p, "audit_view", "audit", "", nil); err != nil {
			s.fail(w, r, err)
			return
		}
	}
	recs, err := s.svc.ListAudit(r.Context(), f)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var next any
	if len(recs) > limit {
		recs = recs[:limit]
		next = s.signCursor(cursor{Kind: "audit", Op: p.Operator.ID, Filter: filter, Seq: recs[len(recs)-1].AuditID})
	}
	s.ok(w, r, map[string]any{"items": recs, "nextCursor": next, "hasMore": next != nil})
}

func (s *Server) listOperators(w http.ResponseWriter, r *http.Request, p *Principal) {
	ops, err := s.svc.ListOperators(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"items": ops})
}

// operatorChange is the shared shape of the three operator management routes: a reason, a target id,
// and one Service call made as the signed-in operator.
func (s *Server) operatorChange(w http.ResponseWriter, r *http.Request, p *Principal, reasonText string, run func(actor Actor, id, reason string) (Operator, error)) {
	reason, err := Reason(reasonText)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	op := p.Operator
	updated, err := run(Actor{Operator: &op, IP: p.IP}, id, reason)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"operator": updated})
}

type reasonBody struct {
	Reason string `json:"reason"`
}

func (s *Server) disableOperator(w http.ResponseWriter, r *http.Request, p *Principal) {
	var body reasonBody
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	s.operatorChange(w, r, p, body.Reason, func(a Actor, id, reason string) (Operator, error) {
		return s.svc.SetDisabled(r.Context(), a, id, true, reason, true)
	})
}

func (s *Server) enableOperator(w http.ResponseWriter, r *http.Request, p *Principal) {
	var body reasonBody
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	s.operatorChange(w, r, p, body.Reason, func(a Actor, id, reason string) (Operator, error) {
		return s.svc.SetDisabled(r.Context(), a, id, false, reason, true)
	})
}

func (s *Server) setOperatorRole(w http.ResponseWriter, r *http.Request, p *Principal) {
	var body struct {
		Role   string `json:"role"`
		Reason string `json:"reason"`
	}
	if err := decode(w, r, &body); err != nil {
		s.fail(w, r, err)
		return
	}
	role, ok := ParseRole(body.Role)
	if !ok {
		s.fail(w, r, &domain.ValidationError{Field: "role", Message: "must be viewer, moderator or admin"})
		return
	}
	s.operatorChange(w, r, p, body.Reason, func(a Actor, id, reason string) (Operator, error) {
		return s.svc.SetRole(r.Context(), a, id, role, reason)
	})
}
