package admin

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"golang.org/x/time/rate"

	"hiyall/services/api/internal/clientip"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/logscrub"
)

// Server is the console's HTTP surface: JSON under /admin/v1 and the built single page app everywhere
// else. It shares no handler, limiter or key with the public API.
type Server struct {
	svc    *Service
	cfg    Config
	mux    *http.ServeMux
	routes []Route

	limitMu  sync.Mutex
	limiters map[string]*rate.Limiter
	// ips resolves the client address behind the trusted proxies (ADMIN_TRUSTED_PROXY_CIDRS).
	ips *clientip.Resolver
}

// Route describes one JSON route and the lowest role that may call it. Public routes need no session.
// Tests walk Routes() to prove every route enforces its role.
type Route struct {
	Method, Path string
	Min          Role // "" for public
}

// Routes lists every JSON route that has been registered.
func (s *Server) Routes() []Route { return append([]Route(nil), s.routes...) }

type requestIDKey struct{}

const (
	cookieName       = "hiyall_admin"
	secureCookieName = "__Host-hiyall_admin"
	csrfHeader       = "X-CSRF-Token"
	maxBody          = 16 << 10
)

// NewServer wires the routes. The static directory may be missing; the API still works and the root says why.
func NewServer(svc *Service, cfg Config) *Server {
	s := &Server{svc: svc, cfg: cfg, mux: http.NewServeMux(), limiters: map[string]*rate.Limiter{}}
	if cfg.TrustProxy {
		s.ips = clientip.New(cfg.TrustedProxies, cfg.ClientIPHeader)
	}
	s.routeAPI()
	return s
}

// Handler is the full console handler with the security envelope around it.
func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := uuid.Must(uuid.NewV7()).String()
		r = r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id))
		s.securityHeaders(w, r)
		w.Header().Set("X-Request-Id", id)
		if !s.hostAllowed(r.Host) {
			http.Error(w, "unknown host", http.StatusMisdirectedRequest)
			return
		}
		if s.cfg.TrustProxy && !strings.EqualFold(lastForwarded(r.Header.Get("X-Forwarded-Proto")), "https") {
			// TLS must terminate in front of the console; plain HTTP never carries a credential here.
			http.Error(w, "HTTPS required", http.StatusBadRequest)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/admin/v1/") || r.URL.Path == "/admin/v1" {
			w.Header().Set("Cache-Control", "no-store")
			s.mux.ServeHTTP(w, r)
			return
		}
		s.static(w, r)
	})
}

// securityHeaders are set on every response, static or JSON. The CSP allows only same-origin scripts,
// styles and connections: the built console has no inline script or style.
func (s *Server) securityHeaders(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()")
	h.Set("X-Robots-Tag", "noindex, nofollow")
	if s.secure(r) {
		h.Set("Strict-Transport-Security", "max-age=31536000")
	}
	// No CORS headers are ever sent: the console answers its own origin only.
}

func (s *Server) secure(r *http.Request) bool { return s.cfg.SecureCookies || r.TLS != nil }

func (s *Server) hostAllowed(host string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.ToLower(strings.Trim(host, "[]"))
	for _, allowed := range s.cfg.AllowedHosts {
		if host == strings.Trim(allowed, "[]") {
			return true
		}
	}
	return false
}

func lastForwarded(v string) string {
	parts := strings.Split(v, ",")
	return strings.TrimSpace(parts[len(parts)-1])
}

// clientIP is the direct peer, or, behind trusted proxies (ADMIN_TRUST_PROXY=true with
// ADMIN_TRUSTED_PROXY_CIDRS), the address clientip finds: the proxy's single-address header, else the rightmost
// X-Forwarded-For hop that is not one of the proxies. Forwarded headers from any other peer are ignored, so
// nobody can choose the address their lockout and audit entries are recorded under.
func (s *Server) clientIP(r *http.Request) string {
	if s.ips != nil {
		return s.ips.ClientIP(r)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// static serves the built console, falling back to index.html for client side routes.
func (s *Server) static(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	root, err := os.OpenRoot(s.cfg.StaticDir)
	if err != nil {
		http.Error(w, "The console is not built. Run npm --prefix apps/admin run build.", http.StatusServiceUnavailable)
		return
	}
	defer root.Close()
	name := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if name == "" {
		name = "index.html"
	}
	f, err := root.Open(name)
	if err == nil {
		info, e := f.Stat()
		if e != nil || info.IsDir() || !info.Mode().IsRegular() {
			f.Close()
			err = errors.New("not a file")
		}
	}
	if err != nil {
		if path.Ext(name) != "" { // a missing asset is a 404, not the app
			http.NotFound(w, r)
			return
		}
		name = "index.html"
		if f, err = root.Open(name); err != nil {
			http.Error(w, "The console is not built. Run npm --prefix apps/admin run build.", http.StatusServiceUnavailable)
			return
		}
	}
	defer f.Close()
	info, _ := f.Stat()
	if ct := mime.TypeByExtension(path.Ext(name)); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	if strings.HasPrefix(name, "assets/") {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "no-store")
	}
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// ---- envelope, shaped exactly like the public API's: {success, data|error, meta}.

func (s *Server) write(w http.ResponseWriter, r *http.Request, status int, body map[string]any) {
	body["meta"] = map[string]any{"requestId": r.Context().Value(requestIDKey{}), "serverTime": time.Now().UTC()}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *Server) ok(w http.ResponseWriter, r *http.Request, data any) {
	s.write(w, r, http.StatusOK, map[string]any{"success": true, "data": data})
}

func (s *Server) failure(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	s.write(w, r, status, map[string]any{"success": false, "error": map[string]string{"code": code, "message": message}})
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	var validation *domain.ValidationError
	var policy *domain.PolicyError
	switch {
	case errors.As(err, &validation):
		s.failure(w, r, 422, "VALIDATION", validation.Error())
	case errors.Is(err, domain.ErrNotFound):
		s.failure(w, r, 404, "NOT_FOUND", "This resource is unavailable")
	case errors.As(err, &policy):
		var retry *domain.RetryError
		if policy.Status == 429 && errors.As(err, &retry) {
			w.Header().Set("Retry-After", strconv.FormatInt(max(1, int64(math.Ceil(retry.After.Seconds()))), 10))
		}
		s.failure(w, r, policy.Status, policy.Code, policy.Message)
	default:
		slog.Error("admin request failed", "requestId", r.Context().Value(requestIDKey{}), "method", r.Method, "route", adminRoute(r.URL.Path), "reason", logscrub.Err(err))
		s.failure(w, r, 500, "INTERNAL", "Something went wrong")
	}
}

// ---- routing and the per-request checks every route shares.

type handlerFunc func(w http.ResponseWriter, r *http.Request, p *Principal)

// handle registers a route. min is the lowest role allowed, or "" for a route that needs no session
// (login only). The role is checked here, server side, before the handler runs, and every non-GET route
// also needs a CSRF token and a same-origin request.
func (s *Server) handle(method, pattern string, min Role, fn handlerFunc) {
	s.routes = append(s.routes, Route{Method: method, Path: pattern, Min: min})
	mutating := method != http.MethodGet && method != http.MethodHead
	s.mux.HandleFunc(method+" "+pattern, func(w http.ResponseWriter, r *http.Request) {
		if mutating && !sameOrigin(r) {
			s.fail(w, r, ErrCSRF)
			return
		}
		var p *Principal
		if min != "" {
			var err error
			if p, err = s.principal(r); err != nil {
				s.fail(w, r, err)
				return
			}
			if !p.Operator.Role.Allows(min) {
				s.fail(w, r, ErrForbidden)
				return
			}
			if mutating && !hmac.Equal([]byte(r.Header.Get(csrfHeader)), []byte(p.CSRF)) {
				s.fail(w, r, ErrCSRF)
				return
			}
			if !s.allow(p.Operator.ID) {
				w.Header().Set("Retry-After", "1")
				s.failure(w, r, 429, "RATE_LIMITED", "Slow down")
				return
			}
		}
		fn(w, r, p)
	})
}

// sameOrigin refuses cross-site requests: an Origin header, when the browser sends one, must be this
// host, and a browser that says the request is cross-site is refused whatever it sends.
func sameOrigin(r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	return err == nil && u.Host != "" && strings.EqualFold(u.Host, r.Host)
}

func (s *Server) cookie(r *http.Request) string {
	name := cookieName
	if s.secure(r) {
		name = secureCookieName
	}
	c, err := r.Cookie(name)
	if err != nil {
		return ""
	}
	return c.Value
}

func (s *Server) principal(r *http.Request) (*Principal, error) {
	p, err := s.svc.Authenticate(r.Context(), s.cookie(r))
	if err != nil {
		return nil, err
	}
	p.IP = TruncateIP(s.clientIP(r))
	return p, nil
}

func (s *Server) setCookie(w http.ResponseWriter, r *http.Request, value string, expires time.Time) {
	c := &http.Cookie{Name: cookieName, Value: value, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, Expires: expires}
	if s.secure(r) {
		c.Name, c.Secure = secureCookieName, true
	}
	if value == "" {
		c.MaxAge = -1
	}
	http.SetCookie(w, c)
}

// allow is a per operator token bucket: 20 requests a second with a burst of 60 is far above a person
// working a queue and far below a script paging every case.
func (s *Server) allow(operator string) bool {
	s.limitMu.Lock()
	defer s.limitMu.Unlock()
	l, ok := s.limiters[operator]
	if !ok {
		if len(s.limiters) > 1024 {
			s.limiters = map[string]*rate.Limiter{}
		}
		l = rate.NewLimiter(20, 60)
		s.limiters[operator] = l
	}
	return l.Allow()
}

// decode reads a small JSON object body, refusing other content types, unknown fields and trailing data.
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	media, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" || (params["charset"] != "" && !strings.EqualFold(params["charset"], "utf-8")) {
		return &domain.ValidationError{Field: "body", Message: "use application/json"}
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	d.DisallowUnknownFields()
	if err = d.Decode(v); err != nil {
		return &domain.ValidationError{Field: "body", Message: "must be a JSON object with the documented fields"}
	}
	if _, err = d.Token(); err != io.EOF {
		return &domain.ValidationError{Field: "body", Message: "must be a single JSON object"}
	}
	return nil
}

// ---- signed cursors. The key derives from ADMIN_DATA_KEY, so every node accepts the same cursors, and
// a cursor is bound to the operator and the filters it was issued for.

type cursor struct {
	Kind   string    `json:"k"`
	Op     string    `json:"o"`
	Filter string    `json:"f"`
	MR     int       `json:"m,omitempty"`
	SR     int       `json:"s,omitempty"`
	At     time.Time `json:"a,omitempty"`
	ID     string    `json:"i,omitempty"`
	Seq    int64     `json:"n,omitempty"`
	Exp    int64     `json:"e"`
}

func (s *Server) signCursor(c cursor) string {
	c.Exp = s.svc.Now().Add(15 * time.Minute).Unix()
	raw, _ := json.Marshal(c)
	m := hmac.New(sha256.New, s.svc.keys.derive("cursor"))
	m.Write(raw)
	return base64.RawURLEncoding.EncodeToString(raw) + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *Server) openCursor(raw, kind, operator, filter string) (cursor, bool) {
	var c cursor
	body, sig, ok := strings.Cut(raw, ".")
	if !ok || len(raw) > 2048 {
		return c, false
	}
	b, e1 := base64.RawURLEncoding.DecodeString(body)
	g, e2 := base64.RawURLEncoding.DecodeString(sig)
	m := hmac.New(sha256.New, s.svc.keys.derive("cursor"))
	m.Write(b)
	if e1 != nil || e2 != nil || !hmac.Equal(g, m.Sum(nil)) || json.Unmarshal(b, &c) != nil {
		return c, false
	}
	return c, c.Kind == kind && c.Op == operator && c.Filter == filter && c.Exp > s.svc.Now().Unix()
}

func filterKey(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return base64.RawURLEncoding.EncodeToString(sum[:6])
}

func limitParam(r *http.Request) (int, error) {
	v := r.URL.Query().Get("limit")
	if v == "" {
		return 25, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 50 {
		return 0, &domain.ValidationError{Field: "limit", Message: "must be 1–50"}
	}
	return n, nil
}
