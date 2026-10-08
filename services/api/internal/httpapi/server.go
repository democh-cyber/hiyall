package httpapi

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"golang.org/x/time/rate"
	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/push"
	"kairova/services/api/internal/realtime"
	"kairova/services/api/internal/store"
)

type Verify func(context.Context, string) (store.Principal, error)
type API struct {
	Store     *store.Store
	Verify    Verify
	DevAuth   bool
	Origin    string
	cursorKey [32]byte
	budget    *rate.Limiter
	clients   *keyedLimiter
	search    *keyedLimiter
	graph     *keyedLimiter
	messages  *keyedLimiter
	reports   *keyedLimiter
	// RT and Push are optional; without them clients fall back to polling.
	RT   *realtime.Hub
	Push *push.Dispatcher
}

func New(s *store.Store, verify Verify, dev bool, origin string) *API {
	a := &API{Store: s, Verify: verify, DevAuth: dev, Origin: origin,
		// The instance budget is a backstop; each client address gets its own bucket.
		budget:   rate.NewLimiter(2000, 4000),
		clients:  newKeyedLimiter(50, 100, 16384),
		search:   newKeyedLimiter(rate.Every(2*time.Second), 10, 4096),
		graph:    newKeyedLimiter(rate.Every(2*time.Second), 20, 4096),
		messages: newKeyedLimiter(5, 40, 4096),
		reports:  newKeyedLimiter(rate.Every(time.Minute), 10, 4096),
	}
	if _, err := rand.Read(a.cursorKey[:]); err != nil {
		panic(err)
	}
	return a
}

type requestIDKey struct{}
type responseStatus struct {
	http.ResponseWriter
	status int
}

func (w *responseStatus) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
// Unwrap and Hijack let the WebSocket upgrade reach the underlying connection.
func (w *responseStatus) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *responseStatus) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, rw, err := http.NewResponseController(w.ResponseWriter).Hijack()
	if err == nil && w.status == 0 {
		w.status = http.StatusSwitchingProtocols
	}
	return conn, rw, err
}
func (w *responseStatus) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	return w.ResponseWriter.Write(data)
}

func (a *API) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		response := &responseStatus{ResponseWriter: w}
		w = response
		id := uuid.NewString()
		defer func() {
			slog.Info("request completed", "requestId", id, "status", response.status, "durationMs", time.Since(start).Milliseconds())
		}()
		if r.URL.Path == "/v1/realtime" {
			a.realtimeGateway(w, r)
			return
		}
		deadline, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		r = r.WithContext(deadline)
		r = r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id))
		w.Header().Set("X-Request-Id", id)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		defer func() {
			if recover() != nil {
				slog.Error("request panic", "requestId", id)
				a.failure(w, r, 500, "INTERNAL", "Something went wrong")
			}
		}()
		origin := r.Header.Get("Origin")
		if origin != "" {
			allowed := origin == a.Origin && a.Origin != "" || a.DevAuth && (origin == "http://127.0.0.1:49321" || origin == "http://localhost:49321")
			if !allowed {
				a.failure(w, r, 403, "ORIGIN_DENIED", "Origin is not allowed")
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, If-Match")
			w.Header().Set("Access-Control-Allow-Methods", "GET, PATCH, POST, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Expose-Headers", "ETag, X-Request-Id")
			if r.Method == "OPTIONS" {
				w.WriteHeader(204)
				return
			}
		}
		if r.URL.Path == "/health/live" && r.Method == "GET" {
			a.ok(w, r, map[string]string{"status": "ok"})
			return
		}
		if r.URL.Path == "/health/ready" && r.Method == "GET" {
			ctx, cancel := context.WithTimeout(r.Context(), time.Second)
			defer cancel()
			if a.Store.Pool.Ping(ctx) != nil {
				a.failure(w, r, 503, "NOT_READY", "Database unavailable")
				return
			}
			a.ok(w, r, map[string]string{"status": "ready"})
			return
		}
		if !a.budget.Allow() || !a.clients.allow(clientAddress(r)) {
			w.Header().Set("Retry-After", "1")
			a.failure(w, r, 429, "RATE_LIMITED", "Try again shortly")
			return
		}
		if a.DevAuth && r.URL.Path == "/dev/session" && r.Method == "POST" {
			a.devSession(w, r)
			return
		}
		raw := r.Header.Get("Authorization")
		if !strings.HasPrefix(raw, "Bearer ") || len(raw) > 16384 {
			a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in to continue")
			return
		}
		p, err := a.Verify(r.Context(), strings.TrimPrefix(raw, "Bearer "))
		if err != nil {
			if errors.Is(err, domain.ErrUnauthorized) {
				a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in to continue")
			} else {
				a.failure(w, r, 503, "AUTH_UNAVAILABLE", "Authentication is temporarily unavailable")
			}
			return
		}
		a.route(w, r, p)
	})
}

// clientAddress is the direct peer. Behind a proxy, configure the proxy to limit
// per real client; forwarded headers are not trusted here.
func clientAddress(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (a *API) ok(w http.ResponseWriter, r *http.Request, data any) {
	a.write(w, r, 200, map[string]any{"success": true, "data": data})
}
func (a *API) write(w http.ResponseWriter, r *http.Request, status int, body map[string]any) {
	body["meta"] = map[string]any{"requestId": r.Context().Value(requestIDKey{}), "serverTime": time.Now().UTC()}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
func (a *API) failure(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	a.write(w, r, status, map[string]any{"success": false, "error": map[string]string{"code": code, "message": message}})
}
func (a *API) error(w http.ResponseWriter, r *http.Request, err error) {
	var validation *domain.ValidationError
	var policy *domain.PolicyError
	switch {
	case errors.As(err, &validation):
		a.failure(w, r, 422, "VALIDATION", validation.Error())
	case errors.Is(err, domain.ErrNotFound):
		a.failure(w, r, 404, "NOT_FOUND", "This resource is unavailable")
	case errors.Is(err, domain.ErrConflict):
		a.failure(w, r, 412, "VERSION_CONFLICT", "Settings changed. Reload before saving.")
	case errors.Is(err, domain.ErrUsernameTaken):
		a.failure(w, r, 409, "USERNAME_TAKEN", "This username is taken")
	case errors.As(err, &policy):
		if policy.Status == 429 {
			w.Header().Set("Retry-After", "3600")
		}
		a.failure(w, r, policy.Status, policy.Code, policy.Message)
	case errors.Is(err, domain.ErrUnauthorized):
		a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in to continue")
	default:
		slog.Error("request failed", "requestId", r.Context().Value(requestIDKey{}))
		a.failure(w, r, 500, "INTERNAL", "Something went wrong")
	}
}

// Reject duplicate keys as well as trailing JSON and unknown properties in domain validation.
func decode(w http.ResponseWriter, r *http.Request) (map[string]json.RawMessage, error) {
	// JSON is UTF-8 by definition; a charset parameter is accepted only if it says so.
	media, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" || (params["charset"] != "" && !strings.EqualFold(params["charset"], "utf-8")) {
		return nil, &domain.ValidationError{Field: "body", Message: "use application/json"}
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return nil, &domain.ValidationError{Field: "body", Message: "must be a JSON object"}
	}
	result := map[string]json.RawMessage{}
	for d.More() {
		key, e := d.Token()
		name, ok := key.(string)
		if e != nil || !ok {
			return nil, &domain.ValidationError{Field: "body", Message: "invalid JSON"}
		}
		if _, exists := result[name]; exists {
			return nil, &domain.ValidationError{Field: name, Message: "duplicate key"}
		}
		var value json.RawMessage
		if e = d.Decode(&value); e != nil {
			return nil, &domain.ValidationError{Field: "body", Message: "invalid JSON"}
		}
		result[name] = value
	}
	if _, err = d.Token(); err != nil {
		return nil, &domain.ValidationError{Field: "body", Message: "invalid JSON"}
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, &domain.ValidationError{Field: "body", Message: "unexpected trailing data"}
	}
	return result, nil
}
func version(w http.ResponseWriter, r *http.Request) (int64, bool) {
	raw := r.Header.Get("If-Match")
	if raw == "" {
		return 0, false
	}
	if len(raw) < 3 || raw[0] != '"' || raw[len(raw)-1] != '"' {
		return 0, false
	}
	v, e := strconv.ParseInt(raw[1:len(raw)-1], 10, 64)
	return v, e == nil && v > 0
}
func (a *API) devSession(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		a.failure(w, r, 403, "LOCAL_ONLY", "Development login is local only")
		return
	}
	body, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return
	}
	var id string
	if len(body) != 1 || json.Unmarshal(body["userId"], &id) != nil || (id != "019a4000-0000-7000-8000-000000000001" && id != "019a4000-0000-7000-8000-000000000002") {
		a.failure(w, r, 422, "VALIDATION", "Select a development account")
		return
	}
	bytes := make([]byte, 32)
	if _, err = rand.Read(bytes); err != nil {
		a.error(w, r, err)
		return
	}
	token := base64.RawURLEncoding.EncodeToString(bytes)
	p, err := a.Store.CreateDevSession(r.Context(), id, token)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"accessToken": token, "userId": p.UserID, "sessionId": p.SessionID, "expiresIn": 1800})
}
func (a *API) route(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	path := r.URL.Path
	if path == "/v1/discovery/search" && r.Method == "POST" {
		a.searchPeople(w, r, p)
		return
	}
	if path == "/v1/me/profile" || path == "/v1/me/privacy" {
		if r.Method == "GET" {
			if path == "/v1/me/profile" {
				value, err := a.Store.GetProfile(ctx, p.UserID)
				if err != nil {
					a.error(w, r, err)
					return
				}
				w.Header().Set("ETag", strconv.Quote(value.Version))
				a.ok(w, r, value)
			} else {
				value, err := a.Store.GetPrivacy(ctx, p.UserID)
				if err != nil {
					a.error(w, r, err)
					return
				}
				w.Header().Set("ETag", strconv.Quote(value.Version))
				a.ok(w, r, value)
			}
			return
		}
		if r.Method == "PATCH" {
			v, ok := version(w, r)
			if !ok {
				a.failure(w, r, 428, "PRECONDITION_REQUIRED", "A quoted If-Match version is required")
				return
			}
			body, err := decode(w, r)
			if err != nil {
				a.error(w, r, err)
				return
			}
			if path == "/v1/me/profile" {
				value, err := a.Store.UpdateProfile(ctx, p.UserID, v, body)
				if err != nil {
					a.error(w, r, err)
					return
				}
				w.Header().Set("ETag", strconv.Quote(value.Version))
				a.ok(w, r, value)
			} else {
				value, err := a.Store.UpdatePrivacy(ctx, p.UserID, v, body)
				if err != nil {
					a.error(w, r, err)
					return
				}
				w.Header().Set("ETag", strconv.Quote(value.Version))
				a.ok(w, r, value)
			}
			return
		}
	}
	if path == "/v1/auth/logout" && r.Method == "POST" {
		if err := a.Store.RevokeSession(ctx, p, p.SessionID); err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, map[string]bool{"revoked": true})
		return
	}
	if path == "/v1/auth/sessions" && r.Method == "GET" {
		a.sessions(w, r, p)
		return
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 4 && parts[0] == "v1" && parts[1] == "users" {
		if _, err := uuid.Parse(parts[2]); err != nil {
			a.failure(w, r, 404, "NOT_FOUND", "This resource is unavailable")
			return
		}
		if parts[3] == "profile" && r.Method == "GET" {
			value, err := a.Store.VisibleProfile(ctx, p.UserID, parts[2])
			if err != nil {
				a.error(w, r, err)
				return
			}
			a.ok(w, r, value)
			return
		}
		if parts[3] == "block" && (r.Method == "POST" || r.Method == "DELETE") {
			err := a.Store.SetBlock(ctx, p.UserID, parts[2], r.Method == "POST")
			if err != nil {
				a.error(w, r, err)
				return
			}
			a.ok(w, r, map[string]bool{"blocked": r.Method == "POST"})
			return
		}
	}
	if len(parts) == 4 && parts[0] == "v1" && parts[1] == "auth" && parts[2] == "sessions" && r.Method == "DELETE" {
		if _, err := uuid.Parse(parts[3]); err != nil {
			a.failure(w, r, 404, "NOT_FOUND", "Session unavailable")
			return
		}
		if err := a.Store.RevokeSession(ctx, p, parts[3]); err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, map[string]bool{"revoked": true})
		return
	}
	if a.chatRoute(w, r, p, parts) || a.socialRoute(w, r, p, parts) || a.safetyRoute(w, r, p, parts) {
		return
	}
	a.failure(w, r, 404, "NOT_FOUND", "Endpoint unavailable")
}

type cursor struct {
	UserID string    `json:"u"`
	ID     string    `json:"i"`
	Before time.Time `json:"b"`
	Exp    int64     `json:"e"`
}

func (a *API) sign(c cursor) string {
	bytes, _ := json.Marshal(c)
	mac := hmac.New(sha256.New, a.cursorKey[:])
	mac.Write(bytes)
	return base64.RawURLEncoding.EncodeToString(bytes) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
func (a *API) sessions(w http.ResponseWriter, r *http.Request, p store.Principal) {
	limit := 20
	if value := r.URL.Query().Get("limit"); value != "" {
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 50 {
			a.failure(w, r, 422, "VALIDATION", "limit must be 1–50")
			return
		}
		limit = n
	}
	var before *time.Time
	id := uuid.Nil.String()
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		parts := strings.Split(raw, ".")
		valid := len(raw) < 2048 && len(parts) == 2
		var c cursor
		if valid {
			bytes, e := base64.RawURLEncoding.DecodeString(parts[0])
			sig, e2 := base64.RawURLEncoding.DecodeString(parts[1])
			mac := hmac.New(sha256.New, a.cursorKey[:])
			mac.Write(bytes)
			valid = e == nil && e2 == nil && hmac.Equal(sig, mac.Sum(nil)) && json.Unmarshal(bytes, &c) == nil && c.UserID == p.UserID && c.Exp > time.Now().Unix()
			_, e = uuid.Parse(c.ID)
			valid = valid && e == nil
		}
		if !valid {
			a.failure(w, r, 422, "INVALID_CURSOR", "Reload your sessions")
			return
		}
		before = &c.Before
		id = c.ID
	}
	items, err := a.Store.ListSessions(r.Context(), p, limit+1, before, id)
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(items) > limit {
		items = items[:limit]
		last := items[len(items)-1]
		next = a.sign(cursor{p.UserID, last.SessionID, last.CreatedAt, time.Now().Add(15 * time.Minute).Unix()})
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil})
}
