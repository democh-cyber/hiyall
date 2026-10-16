package admin

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Content preview and quarantine cases (docs/security/15-admin-console.md, docs/security/16-csam-and-illegal-content.md).
//
// Reported public items (posts, comments, stories, spaces and their entries, a reported member's avatar)
// can be read by moderators and administrators after typing a reason; every such view is audited before
// anything is returned, and so is every photo the console proxies. Photos are fetched by the console from
// object storage with its own read-only token and streamed to the browser through /admin/v1/media: the
// browser never gets a storage URL, and the stream URL carries a two minute token bound to the operator,
// the photo and the report or case it was issued for. Quarantined uploads can be read only by
// administrators, and by default the console serves a small, heavily blurred derivative made on the server
// (media.BlurredPreview): the original pixels reach the browser only after the audited reveal call, which
// issues a second token that is good for one minute and for the full image only. Private chats have no
// preview at all.

const (
	mediaTokenTTL  = 2 * time.Minute
	revealTokenTTL = time.Minute
)

// Variants of a quarantined photo a token may ask for.
const (
	variantBlur = "blur" // the default: small and blurred, made on the server
	variantFull = "full" // the processed original, only after the audited reveal
)

type mediaToken struct {
	Scope   string `json:"s"` // "report" or "case"
	Op      string `json:"o"`
	Ref     string `json:"r"` // report id or case id
	Media   string `json:"m"`
	Variant string `json:"v,omitempty"` // case tokens: variantBlur or variantFull
	Exp     int64  `json:"e"`
}

func (s *Server) signMediaToken(t mediaToken) string {
	ttl := mediaTokenTTL
	if t.Variant == variantFull {
		ttl = revealTokenTTL
	}
	t.Exp = s.svc.Now().Add(ttl).Unix()
	raw, _ := json.Marshal(t)
	m := hmac.New(sha256.New, s.svc.keys.derive("media"))
	m.Write(raw)
	return base64.RawURLEncoding.EncodeToString(raw) + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *Server) openMediaToken(raw string) (mediaToken, bool) {
	var t mediaToken
	body, sig, ok := strings.Cut(raw, ".")
	if !ok || len(raw) > 1024 {
		return t, false
	}
	b, e1 := base64.RawURLEncoding.DecodeString(body)
	g, e2 := base64.RawURLEncoding.DecodeString(sig)
	m := hmac.New(sha256.New, s.svc.keys.derive("media"))
	m.Write(b)
	if e1 != nil || e2 != nil || !hmac.Equal(g, m.Sum(nil)) || json.Unmarshal(b, &t) != nil {
		return t, false
	}
	return t, t.Exp > s.svc.Now().Unix()
}

func (s *Server) mediaURL(t mediaToken) string {
	return "/admin/v1/media/" + t.Media + "?t=" + url.QueryEscape(s.signMediaToken(t))
}

var errMediaUnavailable = &domain.PolicyError{Status: 503, Code: "MEDIA_UNAVAILABLE", Message: "The console has no access to photo storage (ADMIN_MEDIA_*)"}

// routeContent registers the content routes; routeAPI calls it.
func (s *Server) routeContent() {
	s.handle("POST", "/admin/v1/reports/{id}/content", RoleModerator, s.reportContent)
	s.handle("GET", "/admin/v1/media/{id}", RoleModerator, s.streamMedia)
	s.handle("GET", "/admin/v1/content-cases", RoleModerator, s.listContentCases)
	s.handle("GET", "/admin/v1/content-cases/{id}", RoleModerator, s.getContentCase)
	s.handle("POST", "/admin/v1/content-cases/{id}/view", RoleAdmin, s.viewContentCase)
	s.handle("POST", "/admin/v1/content-cases/{id}/reveal", RoleAdmin, s.revealContentCase)
	s.handle("POST", "/admin/v1/content-cases/{id}/resolve", RoleAdmin, s.resolveContentCase)
	s.handle("POST", "/admin/v1/holds/{id}/release", RoleAdmin, s.releaseHold)
	// Two-person control (approvals.go): a second administrator approves what the first proposed.
	s.handle("GET", "/admin/v1/approvals", RoleAdmin, s.listApprovals)
	s.handle("GET", "/admin/v1/content-cases/{id}/proposals", RoleAdmin, s.listCaseProposals)
	s.handle("POST", "/admin/v1/content-cases/{id}/proposals", RoleAdmin, s.proposeEvidenceStep)
	s.handle("POST", "/admin/v1/approvals/{id}/approve", RoleAdmin, s.approveEvidenceStep)
	s.handle("POST", "/admin/v1/approvals/{id}/reject", RoleAdmin, s.rejectEvidenceStep)
	s.handle("POST", "/admin/v1/approvals/{id}/withdraw", RoleAdmin, s.withdrawEvidenceStep)
}

type previewMedia struct {
	store.AdminMediaRef
	URL string `json:"url"`
}

// reportContent returns the reported item. It is a POST because it carries the operator's reason, which
// is written to the audit log first: a view that cannot be recorded does not happen.
func (s *Server) reportContent(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body reasonBody
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
	if err = s.auditedWithReason(r.Context(), p, "report_content_view", "report", id, reason, nil); err != nil {
		s.fail(w, r, err)
		return
	}
	c, err := s.svc.Store.ReportedContent(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	media := make([]previewMedia, 0, len(c.Media))
	for _, m := range c.Media {
		item := previewMedia{AdminMediaRef: m}
		if s.svc.Media != nil {
			item.URL = s.mediaURL(mediaToken{Scope: "report", Op: p.Operator.ID, Ref: id, Media: m.MediaID})
		}
		media = append(media, item)
	}
	s.ok(w, r, map[string]any{"content": c, "media": media, "mediaAvailable": s.svc.Media != nil})
}

// auditedWithReason is audited for reads that carry a reason.
func (s *Server) auditedWithReason(ctx context.Context, p *Principal, action, targetType, targetID, reason string, detail map[string]any) error {
	id := p.Operator.ID
	return insertAudit(ctx, s.svc.Pool, AuditEntry{OperatorID: &id, Actor: p.Operator.Email, Action: action, TargetType: targetType, TargetID: targetID, Reason: reason, IP: p.IP, Detail: detail})
}

// streamMedia proxies one photo. The token says what it was issued for; the audit entry is written before
// a byte is fetched.
func (s *Server) streamMedia(w http.ResponseWriter, r *http.Request, p *Principal) {
	mediaID := r.PathValue("id")
	t, ok := s.openMediaToken(r.URL.Query().Get("t"))
	if !ok || t.Op != p.Operator.ID || t.Media != mediaID || !domain.IsID(mediaID) {
		s.fail(w, r, &domain.ValidationError{Field: "t", Message: "this link has expired; open the item again"})
		return
	}
	var key, action, variant string
	var err error
	var reader media.Store
	switch t.Scope {
	case "report":
		reader = s.svc.Media
		action = "content_media_fetch"
		if reader != nil {
			key, err = s.svc.Store.ReadyMediaKey(r.Context(), mediaID)
		}
	case "case":
		if !p.Operator.Role.Allows(RoleAdmin) { // the token was issued to an administrator; roles are checked again
			s.fail(w, r, ErrForbidden)
			return
		}
		reader = s.svc.evidenceReader()
		action = "quarantine_media_fetch"
		variant = t.Variant
		if variant != variantFull {
			variant = variantBlur
		}
		var held string
		if held, key, err = s.svc.Store.HeldCaseKey(r.Context(), t.Ref); err == nil && held != mediaID {
			err = domain.ErrNotFound
		}
	default:
		err = domain.ErrNotFound
	}
	if reader == nil {
		s.fail(w, r, errMediaUnavailable)
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	detail := map[string]any{"ref": t.Ref}
	if variant != "" {
		detail["variant"] = variant
	}
	if err = s.audited(r.Context(), p, action, "media", mediaID, detail); err != nil {
		s.fail(w, r, err)
		return
	}
	data, err := reader.Get(r.Context(), key, media.MaxUploadBytes)
	if err != nil {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if variant == variantBlur {
		// The console never sends the original unless the administrator revealed it: shrink and blur here.
		if data, err = media.BlurredPreview(data); err != nil {
			s.fail(w, r, domain.ErrNotFound)
			return
		}
	}
	h := w.Header()
	h.Set("Content-Type", "image/jpeg")
	h.Set("Content-Disposition", "inline")
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) listContentCases(w http.ResponseWriter, r *http.Request, p *Principal) {
	q := r.URL.Query()
	status := q.Get("status")
	if status != "" && status != "pending" && status != "open" && status != "confirmed" && status != "cleared" && status != "reported" {
		s.fail(w, r, &domain.ValidationError{Field: "status", Message: "must be pending, open, confirmed, cleared or reported"})
		return
	}
	limit, err := limitParam(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	filter := filterKey(status)
	var at *time.Time
	var id string
	if raw := q.Get("cursor"); raw != "" {
		c, ok := s.openCursor(raw, "cases", p.Operator.ID, filter)
		if !ok || !domain.IsID(c.ID) {
			s.failure(w, r, 422, "INVALID_CURSOR", "Reload the cases")
			return
		}
		at, id = &c.At, c.ID
	}
	cases, err := s.svc.Store.AdminContentCases(r.Context(), status, limit, at, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var next any
	if len(cases) > limit {
		cases = cases[:limit]
		last := cases[len(cases)-1]
		next = s.signCursor(cursor{Kind: "cases", Op: p.Operator.ID, Filter: filter, At: last.CreatedAt, ID: last.CaseID})
	}
	s.ok(w, r, map[string]any{"items": cases, "nextCursor": next, "hasMore": next != nil})
}

func (s *Server) getContentCase(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	if !domain.IsID(id) {
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	if err := s.audited(r.Context(), p, "content_case_view", "content_case", id, nil); err != nil {
		s.fail(w, r, err)
		return
	}
	c, err := s.svc.Store.AdminContentCase(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"case": c, "mediaAvailable": s.svc.Media != nil})
}

// viewContentCase issues the link to the blurred preview of the quarantined photo. The blur is made on the
// server; the explicit reveal is a separate audited step that issues a second, one minute link to the original.
func (s *Server) viewContentCase(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body reasonBody
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
	if s.svc.evidenceReader() == nil {
		s.fail(w, r, errMediaUnavailable)
		return
	}
	mediaID, _, err := s.svc.Store.HeldCaseKey(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err = s.auditedWithReason(r.Context(), p, "quarantine_media_view", "content_case", id, reason, nil); err != nil {
		s.fail(w, r, err)
		return
	}
	// The link serves the blurred derivative only (variant blur); the original needs the reveal below.
	s.ok(w, r, map[string]any{"url": s.mediaURL(mediaToken{Scope: "case", Op: p.Operator.ID, Ref: id, Media: mediaID, Variant: variantBlur}), "blurred": true})
}

// revealContentCase records that the administrator chose to see the quarantined photo unblurred, and returns
// the second link, good for one minute and for the full image of this case only.
func (s *Server) revealContentCase(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body reasonBody
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
	if s.svc.evidenceReader() == nil {
		s.fail(w, r, errMediaUnavailable)
		return
	}
	mediaID, _, err := s.svc.Store.HeldCaseKey(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err = s.auditedWithReason(r.Context(), p, "quarantine_media_reveal", "content_case", id, reason, nil); err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"revealed": true, "url": s.mediaURL(mediaToken{Scope: "case", Op: p.Operator.ID, Ref: id, Media: mediaID, Variant: variantFull}), "expiresInSeconds": int(revealTokenTTL.Seconds())})
}

func (s *Server) resolveContentCase(w http.ResponseWriter, r *http.Request, p *Principal) {
	id := r.PathValue("id")
	var body struct {
		Action          string `json:"action"`
		Reason          string `json:"reason"`
		ReportReference string `json:"reportReference"`
		LegalHold       *bool  `json:"legalHold"`
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
	ref := strings.TrimSpace(body.ReportReference)
	switch {
	case body.Action != "confirm" && body.Action != "clear" && body.Action != "reported":
		s.fail(w, r, &domain.ValidationError{Field: "action", Message: "must be confirm, clear or reported"})
		return
	case body.Action == "reported" && (ref == "" || len(ref) > 200):
		s.fail(w, r, &domain.ValidationError{Field: "reportReference", Message: "record the NCMEC report number or the authority's reference (up to 200 characters)"})
		return
	case !domain.IsID(id):
		s.fail(w, r, domain.ErrNotFound)
		return
	}
	hook := func(ctx context.Context, tx pgx.Tx, subject string) error {
		opID := p.Operator.ID
		return insertAudit(ctx, tx, AuditEntry{OperatorID: &opID, Actor: p.Operator.Email, Action: "content_case_" + body.Action, TargetType: "content_case", TargetID: id,
			Reason: reason, IP: p.IP, Detail: map[string]any{"subjectId": subject, "reportReference": ref}})
	}
	err = s.svc.Store.ResolveContentCase(r.Context(), id, store.ContentCaseStep{Action: body.Action, OperatorID: p.Operator.ID, Note: reason, ReportReference: ref, LegalHold: body.LegalHold}, hook)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.ok(w, r, map[string]any{"caseId": id, "action": body.Action})
}

// releaseHold used to lift an evidence hold on one administrator's word. It now answers 409 APPROVAL_REQUIRED:
// releasing a hold is a proposal (POST /admin/v1/content-cases/{id}/proposals, kind "release") that a different
// administrator approves (approvals.go). The route stays so an old client gets a clear answer, not a 404.
func (s *Server) releaseHold(w http.ResponseWriter, r *http.Request, p *Principal) {
	s.fail(w, r, store.ErrApprovalRequired)
}
