package httpapi

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math"
	"mime"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/time/rate"
	"hiyall/services/api/internal/appcheck"
	"hiyall/services/api/internal/clientip"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/realtime"
	"hiyall/services/api/internal/store"
)

type Verify func(context.Context, string) (store.Principal, error)
type API struct {
	Store     *store.Store
	Verify    Verify
	DevAuth   bool
	Origin    string
	cursorKey [32]byte
	// cursorKeyPrevious are older cursor keys still accepted for verification (CURSOR_KEY_PREVIOUS), so a
	// key rotation does not invalidate cursors already handed out. Signing always uses cursorKey.
	cursorKeyPrevious [][32]byte
	// ClientIP decides which address a request is limited under, trusting forwarded headers only from the
	// configured proxies (clientip). Nil: the direct peer.
	ClientIP *clientip.Resolver
	// minClient is the oldest app version served per platform (android, ios, web); see upgrade.go.
	minClient map[string][3]int
	budget    *rate.Limiter
	clients   *keyedLimiter
	search    *keyedLimiter
	graph     *keyedLimiter
	messages  *keyedLimiter
	// auxMessages is the stricter budget for reactions, per sender and conversation: a burst of 60,
	// refilling one every 10 seconds (60 per 10 minutes sustained). A reaction also takes a token from
	// messages, so it can never be a way around the normal send limit.
	auxMessages *keyedLimiter
	// profileEdits bounds profile and privacy PATCHes per account (the username cooldown does the rest);
	// mediaComplete bounds POST /v1/media/{id}/complete, the CPU-heavy image decode, per account.
	profileEdits  *keyedLimiter
	mediaComplete *keyedLimiter
	reports       *keyedLimiter
	uploads       *keyedLimiter
	// blobSlots bounds encrypted-attachment upload slots, completions and deletes per account;
	// blobURLs bounds download URLs (opening a chat with many photos asks for many).
	blobSlots *keyedLimiter
	blobURLs  *keyedLimiter
	content   *keyedLimiter
	// lists bounds reads of the member-only lists (visitors, own stories, story viewers): a burst of
	// 30, then two a second, so pulling to refresh and paging never trips it but a loop does.
	lists *keyedLimiter
	// locations bounds how often one account can move its shared point: a burst
	// of 3, then one change every 2 minutes.
	locations *keyedLimiter
	// firstChats bounds how many conversations an account can open with people it has never
	// exchanged a message with: a burst of 10, then one a minute. Messaging is open to everyone
	// who is not blocked or in the other age band, so this is what limits unsolicited contact.
	firstChats *keyedLimiter
	// chatDevices bounds device registration, the device list and revoking; chatKeys bounds key
	// uploads and counts; chatInbox bounds inbox reads and acks. All are per account (every device
	// of the account shares them), generous for a phone polling every few seconds.
	chatDevices, chatKeys, chatInbox *keyedLimiter
	// visitWrites lets a viewer's visit to one profile reach the database once an hour (key: viewer and
	// profile). It is per node, in memory (memoryOnlyLimiters): a database write to avoid a database write
	// would defeat it.
	visitWrites *keyedLimiter
	// mediaSlots bounds concurrent photo processing on this node.
	mediaSlots chan struct{}
	// safe is the evidence store, hold length and export slots (safety_state.go).
	safe safetyState
	// Media is optional; without it photo uploads answer 503.
	Media media.Store
	// Scanner inspects every non-encrypted upload before it can be shown (docs/security/16-csam-and-illegal-content.md).
	// Nil is the same as media.None: nothing is flagged. cmd/api sets it from the SCAN_* configuration.
	Scanner media.Scanner
	// Apple revokes Sign in with Apple tokens when an account is deleted. Nil (unconfigured) is a no-op with a warning.
	Apple AppleRevoker
	// ChatMedia is the separate bucket for end-to-end encrypted chat attachments; without it the
	// attachment routes answer 503 CHAT_MEDIA_UNAVAILABLE. It only ever holds ciphertext.
	ChatMedia media.Store
	// Entitlements resolves a member's limits (docs/architecture/11-plans-and-entitlements.md). Nil means
	// everyone is on the Free plan, which is the only plan today; tests replace it to try other tiers.
	Entitlements func(ctx context.Context, userID string) domain.Entitlements
	// RT and Push are optional; without them clients fall back to polling.
	RT   *realtime.Hub
	Push *push.Dispatcher
	// heartbeat is how often a realtime connection is pinged and its session checked.
	heartbeat time.Duration
	// Reporter receives panics and unexpected 500s (ops.go); the default does nothing.
	Reporter ErrorReporter
	// SpacesEvents allows creating event and moment spaces (SPACES_EVENTS_ENABLED). Off for V1: only
	// communities can be created; existing events and moments stay readable.
	SpacesEvents bool
	// Migrations are the migration files this release needs applied; /readyz refuses while the
	// database is behind. Empty disables the check.
	Migrations []string
	ready      readyCache
	routes     routeSet
	// AppCheck verifies the X-Firebase-AppCheck token (appcheck.go); AppCheckMode says what to do with the answer.
	// Nil or appcheck.Off: nothing is checked.
	AppCheck     AppCheckVerifier
	AppCheckMode appcheck.Mode
}

func New(s *store.Store, verify Verify, dev bool, origin string) *API {
	a := &API{Store: s, Verify: verify, DevAuth: dev, Origin: origin,
		// The instance budget is a backstop; each client address gets its own bucket.
		budget:      rate.NewLimiter(2000, 4000),
		clients:     newKeyedLimiter(50, 100, addressLimiterKeys),
		search:      newKeyedLimiter(rate.Every(2*time.Second), 10, accountLimiterKeys),
		graph:       newKeyedLimiter(rate.Every(2*time.Second), 20, accountLimiterKeys),
		messages:    newKeyedLimiter(5, 40, accountLimiterKeys),
		auxMessages: newKeyedLimiter(rate.Every(10*time.Second), 60, accountLimiterKeys),
		// A burst of 30 edits, then one every 3 seconds (20 a minute).
		profileEdits: newKeyedLimiter(rate.Every(3*time.Second), 30, accountLimiterKeys),
		// A burst of 30 photo completions, then one every 2 seconds, like upload slots.
		mediaComplete: newKeyedLimiter(rate.Every(2*time.Second), 30, accountLimiterKeys),
		reports:       newKeyedLimiter(rate.Every(time.Minute), 10, accountLimiterKeys),
		uploads:       newKeyedLimiter(rate.Every(2*time.Second), 30, accountLimiterKeys),
		blobSlots:     newKeyedLimiter(rate.Every(500*time.Millisecond), 60, accountLimiterKeys),
		blobURLs:      newKeyedLimiter(10, 60, accountLimiterKeys),
		content:       newKeyedLimiter(1, 30, accountLimiterKeys),
		lists:         newKeyedLimiter(2, 30, accountLimiterKeys),
		locations:     newKeyedLimiter(rate.Every(2*time.Minute), 3, accountLimiterKeys),
		firstChats:    newKeyedLimiter(rate.Every(time.Minute), 10, accountLimiterKeys),
		chatDevices:   newKeyedLimiter(rate.Every(2*time.Second), 20, 4096),
		chatKeys:      newKeyedLimiter(2, 30, 4096),
		chatInbox:     newKeyedLimiter(5, 60, 4096),
		visitWrites:   newKeyedLimiter(rate.Every(time.Hour), 1, 65536),
		mediaSlots:    make(chan struct{}, 2),
		heartbeat:     pingEvery,
	}
	if _, err := rand.Read(a.cursorKey[:]); err != nil {
		panic(err)
	}
	a.Reporter = NoopReporter{}
	a.minClient = map[string][3]int{}
	a.nameLimiters()
	a.registerMetrics()
	return a
}

// SetCursorKeys installs the keys that sign and verify list cursors (CURSOR_KEY, CURSOR_KEY_PREVIOUS):
// every node with the same keys accepts the others' cursors, across restarts too. Without it New's random
// per-process key is used, which is right for development and tests only.
func (a *API) SetCursorKeys(current []byte, previous ...[]byte) {
	if len(current) == 32 {
		copy(a.cursorKey[:], current)
	}
	a.cursorKeyPrevious = nil
	for _, key := range previous {
		if len(key) == 32 {
			var k [32]byte
			copy(k[:], key)
			a.cursorKeyPrevious = append(a.cursorKeyPrevious, k)
		}
	}
}

// Per-limiter key caps. User-keyed limiters evict the longest idle key past the cap, which resets that
// key's bucket, so the cap must exceed the accounts active within a bucket's refill time: production shares
// these through Postgres (RATE_LIMIT_BACKEND=postgres, required there) and these only bound development
// and tests. The address limiter always stays in memory.
const (
	accountLimiterKeys = 32768
	addressLimiterKeys = 65536
)

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
		pattern := routePattern(r.URL.Path)
		httpInFlight.Inc()
		// The access log and the metrics carry the method, the route pattern, the status and the timing,
		// never the query string (presigned URLs, tokens), headers or bodies.
		defer func() {
			httpInFlight.Dec()
			route := a.routes.label(pattern, response.status)
			httpRequests.Inc(methodLabel(r.Method), route, statusClass(response.status))
			if pattern != "/v1/realtime" {
				httpDuration.Observe(time.Since(start).Seconds(), route)
			}
			slog.Info("request completed", "requestId", id, "method", r.Method, "route", route, "status", response.status, "durationMs", time.Since(start).Milliseconds())
		}()
		defer func() {
			if rec := recover(); rec != nil {
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				a.panicked(w, r, id, pattern, rec, response.status != 0)
			}
		}()
		r = r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id))
		w.Header().Set("X-Request-Id", id)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		// The socket is long-lived, so it skips the request deadline below; its refusals
		// still carry the request id and the standard headers.
		if r.URL.Path == "/v1/realtime" {
			if !a.checkAppCheck(w, r) {
				return
			}
			a.realtimeGateway(w, r)
			return
		}
		deadline, cancel := context.WithTimeout(r.Context(), requestDeadline(r))
		defer cancel()
		if requestDeadline(r) > serverWriteTimeout {
			// The server's write timeout would cut the answer to a slow request off; this route outlives it.
			_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(requestDeadline(r) + 5*time.Second))
		}
		r = r.WithContext(deadline)
		origin := r.Header.Get("Origin")
		if origin != "" {
			allowed := origin == a.Origin && a.Origin != "" || a.DevAuth && (origin == "http://127.0.0.1:49321" || origin == "http://localhost:49321")
			if !allowed {
				a.failure(w, r, 403, "ORIGIN_DENIED", "Origin is not allowed")
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, If-Match, Idempotency-Key, X-Client-Platform, X-Client-Version, X-Firebase-AppCheck")
			w.Header().Set("Access-Control-Allow-Methods", "GET, PUT, PATCH, POST, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Expose-Headers", "ETag, X-Request-Id")
			if r.Method == "OPTIONS" {
				w.WriteHeader(204)
				return
			}
		}
		// Probes (/healthz, /readyz and the older /health/live, /health/ready) answer before rate
		// limiting and authentication, so a busy or throttled node still reports itself.
		if a.health(w, r) {
			return
		}
		if !a.budget.Allow() || !a.clients.allow(a.clientAddress(r)) {
			w.Header().Set("Retry-After", "1")
			a.failure(w, r, 429, "RATE_LIMITED", "Try again shortly")
			return
		}
		if a.upgradeRequired(r) {
			a.failure(w, r, 426, "UPGRADE_REQUIRED", "Update Hiyall to keep using it")
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
		if !a.checkAppCheck(w, r) {
			return
		}
		p, err := a.Verify(r.Context(), strings.TrimPrefix(raw, "Bearer "))
		if err != nil {
			a.authFailure(w, r, err)
			return
		}
		a.route(w, r, p)
	})
}

// clientAddress is the address a request is limited under: the direct peer, unless that peer is one of
// the configured trusted proxies (TRUSTED_PROXY_CIDRS), in which case the proxy's own header or the
// rightmost untrusted X-Forwarded-For hop (see clientip). A request from anyone else is keyed by its peer
// whatever headers it sends.
func (a *API) clientAddress(r *http.Request) string { return a.ClientIP.ClientIP(r) }

// serverWriteTimeout is http.Server.WriteTimeout in cmd/api: a handler that outlives it must extend its
// own write deadline.
const serverWriteTimeout = 15 * time.Second

// requestDeadline is how long a request may run: 10 seconds, except finishing a photo upload, which
// downloads, decodes and re-encodes an image and is allowed 30 (audit S11).
func requestDeadline(r *http.Request) time.Duration {
	if isMediaComplete(r.Method, r.URL.Path) {
		return 30 * time.Second
	}
	return 10 * time.Second
}

// isMediaComplete is POST /v1/media/{id}/complete.
func isMediaComplete(method, path string) bool {
	if method != http.MethodPost {
		return false
	}
	rest, ok := strings.CutPrefix(path, "/v1/media/")
	if !ok {
		return false
	}
	id, tail, found := strings.Cut(rest, "/")
	return found && tail == "complete" && isID(id)
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
		// A refusal that knows when it lifts says so; one that lifts only when the caller acts
		// (closing a space) sends no Retry-After.
		var retry *domain.RetryError
		if policy.Status == 429 && errors.As(err, &retry) {
			w.Header().Set("Retry-After", strconv.FormatInt(max(1, int64(math.Ceil(retry.After.Seconds()))), 10))
		}
		a.failure(w, r, policy.Status, policy.Code, policy.Message)
	case errors.Is(err, domain.ErrUnauthorized):
		a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in to continue")
	case foreignKeyViolation(err):
		// Ids come from the caller: one that names nothing is missing, not a server fault.
		a.failure(w, r, 404, "NOT_FOUND", "This resource is unavailable")
	case invalidText(err):
		a.failure(w, r, 422, "VALIDATION", "Text contains characters that cannot be stored")
	case store.ContentionCode(err) != "":
		a.contended(w, r, err)
	default:
		// The cause is logged for diagnosis: database and Go errors name the failing operation,
		// never a request body, credential, birth date or position.
		slog.Error("request failed", "requestId", r.Context().Value(requestIDKey{}), "method", r.Method, "route", routePattern(r.URL.Path), "reason", scrubURLs(err.Error()))
		id, _ := r.Context().Value(requestIDKey{}).(string)
		a.report(r.Context(), ErrorReport{RequestID: id, Method: r.Method, Route: routePattern(r.URL.Path), Err: err})
		a.failure(w, r, 500, "INTERNAL", "Something went wrong")
	}
}

// invalidText is PostgreSQL refusing text it cannot store (a NUL byte, an invalid or
// untranslatable sequence) that slipped past validation: the caller's input, so 422.
func invalidText(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && (pe.Code == "22021" || pe.Code == "22P05")
}

func foreignKeyViolation(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23503"
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
	if len(body) != 1 || json.Unmarshal(body["userId"], &id) != nil || (id != "019a4000-0000-7000-8000-000000000001" && id != "019a4000-0000-7000-8000-000000000002" && id != store.SamID && id != store.KaiID) {
		a.failure(w, r, 422, "VALIDATION", "Select a development account")
		return
	}
	bytes := make([]byte, 32)
	if _, err = rand.Read(bytes); err != nil {
		a.error(w, r, err)
		return
	}
	token := base64.RawURLEncoding.EncodeToString(bytes)
	p, err := a.Store.CreateDevSession(r.Context(), id, token, r.Header.Get("X-Client-Platform"))
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"accessToken": token, "userId": p.UserID, "sessionId": p.SessionID, "expiresIn": 1800})
}

type cursor struct {
	UserID string    `json:"u"`
	ID     string    `json:"i"`
	Before time.Time `json:"b"`
	Exp    int64     `json:"e"`
}

func (a *API) sign(c cursor) string { return sealCursor(a, "", c) }
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
		var c cursor
		if !openCursor(a, "", raw, &c) || c.UserID != p.UserID || c.Exp <= time.Now().Unix() || !isID(c.ID) {
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
