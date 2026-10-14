package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"

	"hiyall/services/api/internal/clientip"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// ---- Client address behind a proxy (S1) -------------------------------------------------------------------

func addressAPI(t *testing.T, cidrs, header string) *API {
	t.Helper()
	a := New(nil, nil, false, "")
	prefixes, err := clientip.ParseCIDRs(cidrs)
	if err != nil {
		t.Fatal(err)
	}
	a.ClientIP = clientip.New(prefixes, header)
	return a
}

func fromPeer(peer string, headers map[string]string) *http.Request {
	r := httptest.NewRequest("GET", "/v1/me/profile", nil)
	r.RemoteAddr = peer
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	return r
}

func TestClientAddressTrustsForwardedHeadersOnlyFromTrustedProxies(t *testing.T) {
	a := addressAPI(t, "10.0.0.0/8", "")
	for name, tc := range map[string]struct {
		r    *http.Request
		want string
	}{
		"direct client":                      {fromPeer("198.51.100.7:1234", nil), "198.51.100.7"},
		"direct client spoofing":             {fromPeer("198.51.100.7:1234", map[string]string{"X-Forwarded-For": "1.2.3.4", "Fly-Client-IP": "5.6.7.8"}), "198.51.100.7"},
		"proxy forwards the client":          {fromPeer("10.1.2.3:80", map[string]string{"X-Forwarded-For": "203.0.113.50"}), "203.0.113.50"},
		"proxy, client prepended a fake hop": {fromPeer("10.1.2.3:80", map[string]string{"X-Forwarded-For": "1.2.3.4, 203.0.113.50"}), "203.0.113.50"},
		"proxy without header":               {fromPeer("10.1.2.3:80", nil), "10.1.2.3"},
	} {
		if got := a.clientAddress(tc.r); got != tc.want {
			t.Errorf("%s: %q, want %q", name, got, tc.want)
		}
	}
	// With a header configured, a trusted proxy's header wins and an untrusted peer's is ignored.
	a = addressAPI(t, "10.0.0.0/8", "Fly-Client-IP")
	if got := a.clientAddress(fromPeer("10.9.9.9:1", map[string]string{"Fly-Client-IP": "203.0.113.9", "X-Forwarded-For": "1.1.1.1"})); got != "203.0.113.9" {
		t.Errorf("header: %q", got)
	}
	if got := a.clientAddress(fromPeer("192.0.2.1:1", map[string]string{"Fly-Client-IP": "203.0.113.9"})); got != "192.0.2.1" {
		t.Errorf("spoofed header from an untrusted peer: %q", got)
	}
	// Without any configuration (the default and every older test) the peer is the client.
	if got := New(nil, nil, false, "").clientAddress(fromPeer("10.1.2.3:80", map[string]string{"X-Forwarded-For": "203.0.113.50"})); got != "10.1.2.3" {
		t.Errorf("unconfigured: %q", got)
	}
}

// The per-address limiter really keys on the resolved address: behind a trusted proxy two clients get their
// own buckets, and a direct caller cannot dodge its bucket by rotating a forged header.
func TestAddressLimiterUsesTheResolvedClient(t *testing.T) {
	run := func(a *API, peer string, forwarded func(i int) string, n int) (limited int) {
		h := a.Handler()
		for i := 0; i < n; i++ {
			r := httptest.NewRequest("GET", "/v1/me/profile", nil)
			r.RemoteAddr = peer
			if f := forwarded(i); f != "" {
				r.Header.Set("X-Forwarded-For", f)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code == 429 {
				limited++
			}
		}
		return limited
	}
	// The limiter allows a burst of 100 and 50 a second: 400 quick requests from one bucket must trip it.
	a := addressAPI(t, "10.0.0.0/8", "")
	if run(a, "198.51.100.7:1", func(i int) string { return fmt.Sprintf("9.9.%d.%d", i/250, i%250) }, 400) == 0 {
		t.Fatal("rotating X-Forwarded-For from an untrusted peer escaped the per-address limit")
	}
	// Behind the proxy, 400 requests spread over 8 clients (50 each) stay under every bucket.
	a = addressAPI(t, "10.0.0.0/8", "")
	if n := run(a, "10.0.0.2:1", func(i int) string { return fmt.Sprintf("203.0.113.%d", i%8+1) }, 400); n != 0 {
		t.Fatalf("%d requests from 8 different clients behind the proxy were limited together", n)
	}
	// And one client behind the proxy is limited on its own.
	a = addressAPI(t, "10.0.0.0/8", "")
	if run(a, "10.0.0.2:1", func(int) string { return "203.0.113.1" }, 400) == 0 {
		t.Fatal("one abusive client behind the proxy was never limited")
	}
}

// ---- Cursor keys (S5) -------------------------------------------------------------------------------------

func TestCursorKeysAgreeAcrossNodesAndRotate(t *testing.T) {
	keyA, keyB := make([]byte, 32), make([]byte, 32)
	for i := range keyA {
		keyA[i], keyB[i] = byte(i+1), byte(100+i)
	}
	data := []byte(`{"u":"x"}`)
	node1, node2, node3 := New(nil, nil, false, ""), New(nil, nil, false, ""), New(nil, nil, false, "")
	node1.SetCursorKeys(keyA)
	node2.SetCursorKeys(keyA)
	node3.SetCursorKeys(keyB, keyA) // rotated: signs with B, still accepts A
	random := New(nil, nil, false, "")
	sig := node1.cursorMAC("", data)
	if !node2.cursorSigValid(sig, "", data) {
		t.Fatal("two nodes with the same CURSOR_KEY disagree")
	}
	if !node3.cursorSigValid(sig, "", data) {
		t.Fatal("a cursor signed with CURSOR_KEY_PREVIOUS was refused")
	}
	if node1.cursorSigValid(node3.cursorMAC("", data), "", data) {
		t.Fatal("a node that has not rotated yet accepted the new key")
	}
	if random.cursorSigValid(sig, "", data) || node2.cursorSigValid(sig, "other\x00", data) || node2.cursorSigValid(sig, "", []byte(`{"u":"y"}`)) {
		t.Fatal("accepted a signature from the wrong key, prefix or data")
	}
	// Dropping the previous key ends acceptance.
	node3.SetCursorKeys(keyB)
	if node3.cursorSigValid(sig, "", data) {
		t.Fatal("previous key still accepted after it was removed")
	}
	// The real session cursor: signed by one node, read by another.
	signed := node1.sign(cursor{UserID: "u", ID: uuid.NewString(), Before: time.Now(), Exp: time.Now().Add(time.Minute).Unix()})
	if !strings.Contains(signed, ".") {
		t.Fatal(signed)
	}
}

// ---- Minimum client version (O6) --------------------------------------------------------------------------

func TestUpgradeRequiredForOldClients(t *testing.T) {
	a := New(nil, func(context.Context, string) (store.Principal, error) {
		return store.Principal{}, domain.ErrUnauthorized
	}, false, "")
	a.SetMinClientVersions(map[string]string{"android": "1.4.0", "ios": "2.0.0", "web": ""})
	h := a.Handler()
	call := func(method, path, platform, version string) (int, string) {
		r := httptest.NewRequest(method, path, nil)
		r.RemoteAddr = "127.0.0.1:1"
		if platform != "" {
			r.Header.Set("X-Client-Platform", platform)
		}
		if version != "" {
			r.Header.Set("X-Client-Version", version)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		var body struct {
			Error map[string]string `json:"error"`
			Meta  map[string]any    `json:"meta"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &body)
		if w.Code == 426 && (body.Meta["requestId"] == nil || w.Header().Get("X-Request-Id") == "") {
			t.Errorf("426 without the standard envelope: %s", w.Body)
		}
		return w.Code, body.Error["code"]
	}
	for name, tc := range map[string]struct {
		method, path, platform, version string
		status                          int
		code                            string
	}{
		"old android":                  {"GET", "/v1/me/profile", "android", "1.3.9", 426, "UPGRADE_REQUIRED"},
		"android exactly the minimum":  {"GET", "/v1/me/profile", "android", "1.4.0", 401, "UNAUTHENTICATED"},
		"newer android":                {"GET", "/v1/me/profile", "android", "1.10.0", 401, "UNAUTHENTICATED"},
		"build suffix":                 {"GET", "/v1/me/profile", "android", "1.4.0-beta.2+77", 401, "UNAUTHENTICATED"},
		"no version at all":            {"GET", "/v1/me/profile", "android", "", 426, "UPGRADE_REQUIRED"},
		"garbage version":              {"GET", "/v1/me/profile", "android", "latest", 426, "UPGRADE_REQUIRED"},
		"old ios":                      {"POST", "/v1/conversations", "ios", "1.9.9", 426, "UPGRADE_REQUIRED"},
		"platform is case-insensitive": {"GET", "/v1/me/profile", "ANDROID", "1.0.0", 426, "UPGRADE_REQUIRED"},
		"web has no minimum":           {"GET", "/v1/me/profile", "web", "0.0.1", 401, "UNAUTHENTICATED"},
		"unknown platform":             {"GET", "/v1/me/profile", "toaster", "0.0.1", 401, "UNAUTHENTICATED"},
		"no platform":                  {"GET", "/v1/me/profile", "", "", 401, "UNAUTHENTICATED"},
		"health is exempt":             {"GET", "/healthz", "android", "0.1.0", 200, ""},
		"ready is exempt":              {"GET", "/readyz", "android", "0.1.0", 503, "NOT_READY"},
		"logout is exempt":             {"POST", "/v1/auth/logout", "android", "0.1.0", 401, "UNAUTHENTICATED"},
		"legal is exempt":              {"GET", "/v1/legal/terms", "ios", "0.1.0", 401, "UNAUTHENTICATED"},
	} {
		status, code := call(tc.method, tc.path, tc.platform, tc.version)
		if status != tc.status || code != tc.code {
			t.Errorf("%s: %d %q, want %d %q", name, status, code, tc.status, tc.code)
		}
	}
	// Off by default: nothing is refused when no minimum is configured.
	off := New(nil, func(context.Context, string) (store.Principal, error) {
		return store.Principal{}, domain.ErrUnauthorized
	}, false, "").Handler()
	r := httptest.NewRequest("GET", "/v1/me/profile", nil)
	r.Header.Set("X-Client-Platform", "android")
	r.RemoteAddr = "127.0.0.1:1"
	w := httptest.NewRecorder()
	off.ServeHTTP(w, r)
	if w.Code == 426 {
		t.Fatal("426 without a configured minimum")
	}
}

func TestClientVersionHeaderIsAllowedByCORS(t *testing.T) {
	h := New(nil, nil, true, "").Handler()
	req := httptest.NewRequest(http.MethodOptions, "/v1/me/profile", nil)
	req.Header.Set("Origin", "http://127.0.0.1:49321")
	req.Header.Set("Access-Control-Request-Method", "GET")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if !strings.Contains(strings.ToLower(rec.Header().Get("Access-Control-Allow-Headers")), "x-client-version") {
		t.Fatalf("X-Client-Version not allowed: %q", rec.Header().Get("Access-Control-Allow-Headers"))
	}
}

// ---- Photo completion (S11) -------------------------------------------------------------------------------

func TestPhotoCompletionHasItsOwnDeadlineAndLimiter(t *testing.T) {
	for _, tc := range []struct {
		method, path string
		want         time.Duration
	}{
		{"POST", "/v1/media/" + uuid.NewString() + "/complete", 30 * time.Second},
		{"GET", "/v1/media/" + uuid.NewString() + "/complete", 10 * time.Second},
		{"POST", "/v1/media/uploads", 10 * time.Second},
		{"POST", "/v1/media/not-an-id/complete", 10 * time.Second},
		{"POST", "/v1/posts", 10 * time.Second},
	} {
		if got := requestDeadline(httptest.NewRequest(tc.method, tc.path, nil)); got != tc.want {
			t.Errorf("%s %s: %v, want %v", tc.method, tc.path, got, tc.want)
		}
	}
	if media.MaxPixels != 20_000_000 {
		t.Fatalf("MaxPixels = %d", media.MaxPixels)
	}
	h := newSocialHarness(t)
	withMedia(h)
	limited, other := 0, 0
	for i := 0; i < 40; i++ {
		switch got := h.call(alice, "POST", "/v1/media/"+uuid.NewString()+"/complete"); got.status {
		case 429:
			limited++
		case 404:
			other++
		default:
			t.Fatalf("unexpected %d %s", got.status, got.code)
		}
	}
	if limited == 0 || other < 20 {
		t.Fatalf("%d limited, %d answered: the per-account completion limiter is off or too tight", limited, other)
	}
	// Another account is unaffected, and so is every other route of the limited one.
	h.expect(h.call(cara, "POST", "/v1/media/"+uuid.NewString()+"/complete"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1/me/profile"), 200, "")
}

// ---- Profile edits and the username cooldown (S8) ---------------------------------------------------------

func rawPatch(h *socialHarness, actor, version, body string) (int, http.Header, map[string]any) {
	h.t.Helper()
	r := httptest.NewRequest("PATCH", "/v1/me/profile", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("If-Match", `"`+version+`"`)
	r.RemoteAddr = "127.0.0.1:50000"
	r.Header.Set("Authorization", "Bearer "+actor)
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	var out struct {
		Data  map[string]any    `json:"data"`
		Error map[string]string `json:"error"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	if out.Data == nil {
		out.Data = map[string]any{"code": out.Error["code"]}
	}
	return w.Code, w.Header(), out.Data
}

func profileVersion(h *socialHarness, actor string) string {
	h.t.Helper()
	return h.ok(actor, "GET", "/v1/me/profile")["version"].(string)
}

func TestUsernameChangeStartsAThirtyDayCooldown(t *testing.T) {
	h := newSocialHarness(t)
	// The first real name chosen over the generated one is free and starts no cooldown.
	fresh := "019a4000-0000-7000-8000-00000000b0b1"
	h.user(fresh, domain.PlaceholderUsername(fresh))
	status, _, data := rawPatch(h, fresh, profileVersion(h, fresh), `{"username":"first_pick"}`)
	if status != 200 {
		t.Fatalf("choosing the first name: %d %v", status, data)
	}
	var stamped *time.Time
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT username_changed_at FROM profiles WHERE user_id=$1`, fresh).Scan(&stamped); err != nil || stamped != nil {
		t.Fatalf("the first name started the cooldown: %v %v", stamped, err)
	}
	// Changing it is allowed once, then it is locked.
	if status, _, data = rawPatch(h, fresh, profileVersion(h, fresh), `{"username":"second_pick"}`); status != 200 {
		t.Fatalf("first rename: %d %v", status, data)
	}
	status, header, data := rawPatch(h, fresh, profileVersion(h, fresh), `{"username":"third_pick"}`)
	if status != 429 || data["code"] != "USERNAME_COOLDOWN" {
		t.Fatalf("second rename inside the cooldown: %d %v", status, data)
	}
	var retry int
	fmt.Sscan(header.Get("Retry-After"), &retry)
	if days := float64(retry) / 86400; days < 29.9 || days > 30.1 {
		t.Fatalf("Retry-After %q is %.2f days, want about 30", header.Get("Retry-After"), days)
	}
	// Other edits are not blocked, and keeping the same username is not a rename.
	if status, _, data = rawPatch(h, fresh, profileVersion(h, fresh), `{"bio":"hello","username":"second_pick"}`); status != 200 {
		t.Fatalf("edit during the cooldown: %d %v", status, data)
	}
	// After 30 days it is open again.
	h.exec(`UPDATE profiles SET username_changed_at=now()-interval '31 days' WHERE user_id=$1`, fresh)
	if status, _, data = rawPatch(h, fresh, profileVersion(h, fresh), `{"username":"third_pick"}`); status != 200 {
		t.Fatalf("rename after the cooldown: %d %v", status, data)
	}
	// A name somebody has is 409 USERNAME_TAKEN (by constraint name), and a refused rename starts nothing.
	h.exec(`UPDATE profiles SET username_changed_at=NULL WHERE user_id=$1`, fresh)
	status, _, data = rawPatch(h, fresh, profileVersion(h, fresh), `{"username":"dev_k"}`)
	if status != 409 || data["code"] != "USERNAME_TAKEN" {
		t.Fatalf("taken name: %d %v", status, data)
	}
	var again *time.Time
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT username_changed_at FROM profiles WHERE user_id=$1`, fresh).Scan(&again); err != nil || again != nil {
		t.Fatalf("a refused rename started the cooldown: %v %v", again, err)
	}
}

func TestProfileEditsAreRateLimitedPerAccount(t *testing.T) {
	h := newSocialHarness(t)
	limited := 0
	for i := 0; i < 60; i++ {
		// A stale version is a 412 after the limiter has let the request in; 429 is the limiter itself.
		status, header, _ := rawPatch(h, alice, "9999", `{"bio":"x"}`)
		switch status {
		case 412:
		case 429:
			limited++
			if header.Get("Retry-After") == "" {
				t.Fatal("429 without Retry-After")
			}
		default:
			t.Fatalf("status %d", status)
		}
	}
	if limited == 0 || limited > 40 {
		t.Fatalf("%d of 60 edits limited", limited)
	}
	// Privacy edits share the budget; another account has its own.
	r := httptest.NewRequest("PATCH", "/v1/me/privacy", strings.NewReader(`{}`))
	r.Header.Set("If-Match", `"1"`)
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = "127.0.0.1:50000"
	r.Header.Set("Authorization", "Bearer "+alice)
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	if w.Code != 429 {
		t.Fatalf("privacy PATCH not limited: %d", w.Code)
	}
	if status, _, _ := rawPatch(h, cara, "9999", `{"bio":"x"}`); status != 412 {
		t.Fatalf("another account was limited: %d", status)
	}
}

// ---- Session fast path (S4) -------------------------------------------------------------------------------

func TestSessionFastPathReadsOnlyAndKeepsEverySemantic(t *testing.T) {
	h := newSocialHarness(t)
	trace := &statements{}
	db, err := store.New(h.ctx, os.Getenv("TEST_DATABASE_URL"), store.WithQueryTracer(trace))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	const issuer, subject, sid = "https://identity.example", "fast-path-subject", "fast-path-sid"
	expiry := time.Now().Add(time.Hour)
	first, err := db.ResolveOIDC(h.ctx, issuer, subject, sid, expiry)
	if err != nil || first.UserID == "" || first.Onboarded || first.PendingDeletion {
		t.Fatalf("first sign-in: %+v %v", first, err)
	}
	statementsFor := func(f func()) []string {
		trace.reset()
		f()
		trace.mu.Lock()
		defer trace.mu.Unlock()
		return append([]string(nil), trace.sql...)
	}
	resolve := func(exp time.Time) store.Principal {
		t.Helper()
		p, err := db.ResolveOIDC(h.ctx, issuer, subject, sid, exp)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}

	// A live, recently seen session: exactly one read, no transaction, no lock, no write.
	var p store.Principal
	got := statementsFor(func() { p = resolve(expiry) })
	if p != first {
		t.Fatalf("principal changed: %+v vs %+v", p, first)
	}
	if len(got) != 1 || !strings.HasPrefix(strings.TrimSpace(got[0]), "SELECT") {
		t.Fatalf("fast path sent %d statements: %q", len(got), got)
	}
	for _, banned := range []string{"FOR UPDATE", "pg_advisory", "INSERT", "UPDATE", "begin", "BEGIN"} {
		if strings.Contains(got[0], banned) {
			t.Fatalf("fast path statement contains %q: %s", banned, got[0])
		}
	}

	// A stale last_seen_at is written once (a second statement), then it is a single read again.
	h.exec(`UPDATE sessions SET last_seen_at=now()-interval '5 minutes' WHERE session_id=$1`, first.SessionID)
	if got = statementsFor(func() { resolve(expiry) }); len(got) != 2 || !strings.Contains(got[1], "UPDATE sessions") {
		t.Fatalf("stale session: %q", got)
	}
	var stale bool
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT last_seen_at<now()-interval '1 minute' FROM sessions WHERE session_id=$1`, first.SessionID).Scan(&stale); err != nil || stale {
		t.Fatalf("last_seen_at not refreshed: %v %v", stale, err)
	}
	if got = statementsFor(func() { resolve(expiry) }); len(got) != 1 {
		t.Fatalf("refreshed session still wrote: %q", got)
	}

	// A token that outlives the session extends it, never shortens it.
	later := expiry.Add(2 * time.Hour)
	if got = statementsFor(func() { resolve(later) }); len(got) != 2 {
		t.Fatalf("extension: %q", got)
	}
	var stored time.Time
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT expires_at FROM sessions WHERE session_id=$1`, first.SessionID).Scan(&stored)
	if stored.Before(later.Add(-time.Second)) {
		t.Fatalf("expiry %v not extended to %v", stored, later)
	}
	resolve(expiry.Add(-30 * time.Minute))
	var kept time.Time
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT expires_at FROM sessions WHERE session_id=$1`, first.SessionID).Scan(&kept)
	if kept.Before(stored.Add(-time.Second)) {
		t.Fatal("an older token shortened the session")
	}

	// Onboarding and pending deletion are read live.
	h.exec(`INSERT INTO onboarding(user_id,completed_at,terms_version) VALUES($1,now(),'x') ON CONFLICT(user_id) DO UPDATE SET completed_at=now()`, first.UserID)
	if p = resolve(expiry); !p.Onboarded || p.PendingDeletion {
		t.Fatalf("onboarding not read: %+v", p)
	}
	h.exec(`UPDATE users SET status='pending_deletion',deletion_due_at=now()+interval '30 days',deletion_scheduled_at=now() WHERE user_id=$1`, first.UserID)
	if p = resolve(expiry); !p.PendingDeletion {
		t.Fatalf("pending deletion not read: %+v", p)
	}
	// Any other account state is refused, for a live session too.
	for _, status := range []string{"deleting", "suspended", "banned", "deactivated"} {
		h.exec(`UPDATE users SET status=$2 WHERE user_id=$1`, first.UserID, status)
		if _, err = db.ResolveOIDC(h.ctx, issuer, subject, sid, expiry); !errors.Is(err, domain.ErrUnauthorized) {
			t.Fatalf("status %s: %v", status, err)
		}
	}
	h.exec(`UPDATE users SET status='active',deletion_due_at=NULL,deletion_scheduled_at=NULL WHERE user_id=$1`, first.UserID)
	resolve(expiry)

	// Another subject cannot ride this session id, and a revoked session is never recreated.
	if _, err = db.ResolveOIDC(h.ctx, issuer, "someone-else", sid, expiry); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("another subject used the session: %v", err)
	}
	if err = db.RevokeSession(h.ctx, first, first.SessionID); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err = db.ResolveOIDC(h.ctx, issuer, subject, sid, expiry); !errors.Is(err, domain.ErrUnauthorized) {
			t.Fatalf("revoked session resolved: %v", err)
		}
	}
	var revoked bool
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT revoked_at IS NOT NULL FROM sessions WHERE session_id=$1`, first.SessionID).Scan(&revoked)
	if !revoked {
		t.Fatal("revocation undone")
	}

	// An expired session row is renewed by a valid token through the transaction path, as before.
	h.exec(`UPDATE sessions SET revoked_at=NULL,expires_at=now()-interval '1 minute' WHERE session_id=$1`, first.SessionID)
	if p = resolve(time.Now().Add(time.Hour)); p.SessionID != first.SessionID {
		t.Fatalf("expired session not renewed: %+v", p)
	}
}

// Many requests of one session at once: nobody blocks, nobody fails.
func TestSessionFastPathUnderConcurrency(t *testing.T) {
	h := newSocialHarness(t)
	const issuer, subject, sid = "https://identity.example", "concurrent-subject", "concurrent-sid"
	expiry := time.Now().Add(time.Hour)
	if _, err := h.db.ResolveOIDC(h.ctx, issuer, subject, sid, expiry); err != nil {
		t.Fatal(err)
	}
	h.exec(`UPDATE sessions SET last_seen_at=now()-interval '5 minutes' WHERE external_sid=$1`, sid)
	var wg sync.WaitGroup
	errs := make(chan error, 64)
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := h.db.ResolveOIDC(h.ctx, issuer, subject, sid, expiry)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
}

// ---- Connection settings (D4) -----------------------------------------------------------------------------

func TestConnectionTimeoutsAndPoolSize(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	show := func(db *store.Store, name string) string {
		var v string
		if err := db.Pool.QueryRow(ctx, `SELECT current_setting($1)`, name).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	def, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer def.Pool.Close()
	if show(def, "statement_timeout") != "5s" || show(def, "lock_timeout") != "3s" || show(def, "idle_in_transaction_session_timeout") != "15s" || show(def, "TimeZone") != "UTC" {
		t.Fatalf("defaults: %s %s %s", show(def, "statement_timeout"), show(def, "lock_timeout"), show(def, "idle_in_transaction_session_timeout"))
	}
	if def.Pool.Config().MaxConns != 20 {
		t.Fatalf("default pool %d", def.Pool.Config().MaxConns)
	}
	sized, err := store.New(ctx, dsn, store.WithMaxConns(7))
	if err != nil {
		t.Fatal(err)
	}
	defer sized.Pool.Close()
	if sized.Pool.Config().MaxConns != 7 {
		t.Fatalf("DB_MAX_CONNS ignored: %d", sized.Pool.Config().MaxConns)
	}
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	fromDSN, err := store.New(ctx, dsn+sep+"pool_max_conns=3", store.WithMaxConns(7))
	if err != nil {
		t.Fatal(err)
	}
	defer fromDSN.Pool.Close()
	if fromDSN.Pool.Config().MaxConns != 3 {
		t.Fatalf("pool_max_conns in the DSN must win: %d", fromDSN.Pool.Config().MaxConns)
	}
	maint, err := def.NewMaintenance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer maint.Pool.Close()
	if show(maint, "statement_timeout") != "2min" || maint.Pool.Config().MaxConns != 4 {
		t.Fatalf("maintenance pool: %s, %d conns", show(maint, "statement_timeout"), maint.Pool.Config().MaxConns)
	}

	// The limits actually bite.
	tight, err := store.New(ctx, dsn, store.WithTimeouts(store.Timeouts{Statement: 300 * time.Millisecond, Lock: 200 * time.Millisecond, IdleInTransaction: 300 * time.Millisecond}))
	if err != nil {
		t.Fatal(err)
	}
	defer tight.Pool.Close()
	code := func(err error) string {
		var pe *pgconn.PgError
		if errors.As(err, &pe) {
			return pe.Code
		}
		return fmt.Sprint(err)
	}
	if _, err = tight.Pool.Exec(ctx, `SELECT pg_sleep(3)`); code(err) != "57014" {
		t.Fatalf("statement_timeout did not cancel a slow statement: %v", err)
	}
	holder, err := def.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Rollback(ctx)
	if _, err = holder.Exec(ctx, `LOCK TABLE rate_limits IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	if _, err = tight.Pool.Exec(ctx, `SELECT count(*) FROM rate_limits`); code(err) != "55P03" {
		t.Fatalf("lock_timeout did not end a lock wait: %v", err)
	}
	_ = holder.Rollback(ctx)
	tx, err := tight.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SELECT 1`); err != nil {
		t.Fatal(err)
	}
	time.Sleep(700 * time.Millisecond)
	if _, err = tx.Exec(ctx, `SELECT 1`); err == nil {
		t.Fatal("an idle open transaction survived idle_in_transaction_session_timeout")
	}
	_ = tx.Rollback(ctx)
}

// ---- Media cleanup order (D3) -----------------------------------------------------------------------------

// flakyObjects is an object store whose deletes can fail for chosen keys.
type flakyObjects struct {
	*media.Memory
	mu   sync.Mutex
	fail map[string]bool // substring of a key -> delete fails
	log  []string
}

func (f *flakyObjects) Delete(ctx context.Context, keys ...string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, k := range keys {
		for bad := range f.fail {
			if f.fail[bad] && strings.Contains(k, bad) {
				return errors.New(`Delete "https://bucket.example/` + k + `?X-Amz-Signature=secret": storage unavailable`)
			}
		}
	}
	f.log = append(f.log, keys...)
	return f.Memory.Delete(ctx, keys...)
}

// mediaRows inserts n photo rows of a member with objects in the store; the first `failing` carry a marker in
// their keys. Rows are ready and marked deleted, so the cleanup owes their objects.
func mediaRows(h *socialHarness, objects *media.Memory, owner string, n int, marker string, failing int) []string {
	h.t.Helper()
	var ids []string
	for i := 0; i < n; i++ {
		id := uuid.NewString()
		prefix := "media/" + id
		if i < failing {
			prefix = "media/" + marker + "-" + id
		}
		full, thumb, orig := prefix+"/full.jpg", prefix+"/thumb.jpg", "uploads/"+id
		for _, k := range []string{full, thumb, orig} {
			_ = objects.Put(h.ctx, k, []byte("x"), "image/jpeg")
		}
		variants, _ := json.Marshal(map[string]string{"full": full, "thumb": thumb})
		h.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,variants,attached,expires_at,deleted_at)
 VALUES($1,$2,'post','deleted','image/jpeg',1,1,$3,$4,false,now()-interval '1 hour',now()-interval '1 minute'*$5::int)`, id, owner, orig, variants, n-i)
		ids = append(ids, id)
	}
	return ids
}

func TestMediaCleanupDeletesObjectsBeforeClearingRowsAndSurvivesFailures(t *testing.T) {
	h := newSocialHarness(t)
	mem := media.NewMemory()
	objects := &flakyObjects{Memory: mem, fail: map[string]bool{"BAD": true}}
	// 60 rows: more than one chunk, the three oldest (ordered first) can never be deleted.
	ids := mediaRows(h, mem, alice, 60, "BAD", 3)
	finished, err := h.db.PurgeMedia(h.ctx, objects, 5000)
	if err == nil {
		t.Fatal("failures were not reported")
	}
	if strings.Contains(err.Error(), "Signature") || strings.Contains(err.Error(), "https://") {
		t.Fatalf("the error leaks a URL: %v", err)
	}
	if finished != 57 {
		t.Fatalf("finished %d rows, want the 57 that could be: a failing row held the others back", finished)
	}
	for i, id := range ids {
		var variants *string
		var status string
		if err = h.db.Pool.QueryRow(h.ctx, `SELECT status,variants::text FROM media_assets WHERE media_id=$1`, id).Scan(&status, &variants); err != nil {
			t.Fatal(err)
		}
		has := mem.Has("media/" + id + "/full.jpg")
		if i < 3 {
			if variants == nil || !mem.Has("media/BAD-"+id+"/full.jpg") {
				t.Fatalf("row %d: failed deletion must keep its keys and its objects (variants %v)", i, variants)
			}
			continue
		}
		if variants != nil || has || mem.Has("uploads/"+id) {
			t.Fatalf("row %d: finished row kept keys %v or objects", i, variants)
		}
	}
	// A later run, with storage healthy again, finishes the rest and only the rest.
	objects.mu.Lock()
	objects.fail = nil
	objects.log = nil
	objects.mu.Unlock()
	finished, err = h.db.PurgeMedia(h.ctx, objects, 5000)
	if err != nil || finished != 3 || len(objects.log) != 9 {
		t.Fatalf("retry: finished %d, %d keys deleted, %v", finished, len(objects.log), err)
	}
	if finished, err = h.db.PurgeMedia(h.ctx, objects, 5000); err != nil || finished != 0 {
		t.Fatalf("nothing should be left: %d %v", finished, err)
	}
	for _, k := range mem.Keys() {
		t.Fatalf("object %s remains", k)
	}
}

func TestMediaCleanupSkipsLockedRowsAndExpiredUploads(t *testing.T) {
	h := newSocialHarness(t)
	mem := media.NewMemory()
	ids := mediaRows(h, mem, alice, 3, "", 0)
	// An abandoned, never-completed upload past its expiry also owes its original object.
	abandoned := uuid.NewString()
	_ = mem.Put(h.ctx, "uploads/"+abandoned, []byte("x"), "image/jpeg")
	h.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,attached,expires_at) VALUES($1,$2,'post','pending','image/jpeg',1,1,$3,false,now()-interval '1 hour')`, abandoned, alice, "uploads/"+abandoned)
	// A live, attached photo and an unexpired upload are never touched.
	live := uuid.NewString()
	_ = mem.Put(h.ctx, "uploads/"+live, []byte("x"), "image/jpeg")
	h.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,attached,expires_at) VALUES($1,$2,'post','pending','image/jpeg',1,1,$3,false,now()+interval '1 hour')`, live, alice, "uploads/"+live)

	// Another node holds one row: SKIP LOCKED leaves it for later instead of waiting.
	other, err := h.db.Pool.Begin(h.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Rollback(h.ctx)
	if _, err = other.Exec(h.ctx, `SELECT 1 FROM media_assets WHERE media_id=$1 FOR UPDATE`, ids[0]); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var finished int64
	go func() {
		defer close(done)
		finished, err = h.db.PurgeMedia(h.ctx, mem, 5000)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("PurgeMedia waited for a row another node holds")
	}
	if err != nil || finished != 3 {
		t.Fatalf("finished %d, %v (want 2 deleted photos and the abandoned upload)", finished, err)
	}
	if !mem.Has("media/"+ids[0]+"/full.jpg") || !mem.Has("uploads/"+live) || mem.Has("uploads/"+abandoned) {
		t.Fatalf("wrong objects removed: %v", mem.Keys())
	}
	_ = other.Rollback(h.ctx)
	if finished, err = h.db.PurgeMedia(h.ctx, mem, 5000); err != nil || finished != 1 || mem.Has("media/"+ids[0]+"/full.jpg") {
		t.Fatalf("the skipped row was not picked up later: %d %v", finished, err)
	}
	var status string
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT status FROM media_assets WHERE media_id=$1`, abandoned).Scan(&status); err != nil || status != "deleted" {
		t.Fatalf("abandoned upload is %s (%v)", status, err)
	}
}

// An account is never reported as purged while its photo objects remain.
func TestAccountPurgeIsNotDrainedWhileMediaObjectsRemain(t *testing.T) {
	w := newPurgeWorld(t)
	w.scheduled(xan, "xan")
	w.expire(xan)
	del := &fakeDeleter{}
	objects := &flakyObjects{Memory: w.mem, fail: map[string]bool{"media/": true}}
	for run := 0; run < 3; run++ {
		if _, err := w.db.PurgeDeletedAccounts(w.ctx, del, 10); err != nil {
			t.Fatal(err)
		}
		if _, err := w.db.PurgeMedia(w.ctx, objects, 5000); err == nil {
			t.Fatal("storage failure not reported")
		}
		if _, err := w.db.PurgeChatBlobs(w.ctx, w.chat, 5000); err != nil {
			t.Fatal(err)
		}
		if got := w.status(xan); got == "deleted" {
			t.Fatal("the account was reported purged while its photo objects remain")
		}
	}
	remaining := 0
	for _, key := range w.xanMedia {
		if w.mem.Has(key) {
			remaining++
		}
	}
	if remaining == 0 {
		t.Fatal("the test world had no photo objects to protect")
	}
	objects.mu.Lock()
	objects.fail = nil
	objects.mu.Unlock()
	w.purgeUntilDone(del)
	for _, key := range w.xanMedia {
		if w.mem.Has(key) {
			t.Fatalf("object %s survived the purge", key)
		}
	}
}

// ---- Outbox retention (D5) ---------------------------------------------------------------------------------

func TestOutboxIsNotWrittenAndOldRowsArePurged(t *testing.T) {
	h := newSocialHarness(t)
	count := func() int {
		var n int
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM outbox_events`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	var version int64
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT aggregate_version FROM users WHERE user_id=$1`, alice).Scan(&version)
	v := profileVersion(h, alice)
	h.expect(h.patch(alice, "/v1/me/profile", v, `{"bio":"no event"}`), 200, "")
	h.expect(h.send(alice, "POST", "/v1/users/"+cara+"/block", nil), 200, "")
	h.expect(h.call(alice, "DELETE", "/v1/users/"+cara+"/block"), 200, "")
	var after int64
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT aggregate_version FROM users WHERE user_id=$1`, alice).Scan(&after)
	if count() != 0 || after != version {
		t.Fatalf("profile and block writes produced %d outbox rows and moved aggregate_version %d -> %d", count(), version, after)
	}
	for i, age := range []string{"8 days", "6 days", "10 days"} {
		h.exec(`INSERT INTO outbox_events(event_id,aggregate_type,aggregate_id,aggregate_version,event_type,occurred_at) VALUES(gen_random_uuid(),'user',$1,$2,'profile.updated',now()-$3::interval)`, alice, 100+i, age)
	}
	n, err := h.db.PurgeOutbox(h.ctx, 7*24*time.Hour, 1)
	if err != nil || n != 1 || count() != 2 {
		t.Fatalf("batch of 1: %d %v, %d left", n, err, count())
	}
	if n, err = h.db.PurgeOutbox(h.ctx, 7*24*time.Hour, 100); err != nil || n != 1 || count() != 1 {
		t.Fatalf("rest: %d %v, %d left", n, err, count())
	}
}
