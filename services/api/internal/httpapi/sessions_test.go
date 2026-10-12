package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

func TestSessionsListLiveOnlyRevokeOthersAndThrottleWrites(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Pool.Close()
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "hiyall_test" {
		t.Fatal("integration tests require database named hiyall_test")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	handler := New(db, db.VerifyDevSession, true, "").Handler()
	call := func(method, path, token, platform string, body string) (int, map[string]any) {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		req.RemoteAddr = "127.0.0.1:44001"
		req.Header.Set("Content-Type", "application/json")
		if platform != "" {
			req.Header.Set("X-Client-Platform", platform)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		var value struct {
			Data map[string]any `json:"data"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &value)
		return rec.Code, value.Data
	}
	login := func(platform string) string {
		status, data := call("POST", "/dev/session", "", platform, `{"userId":"`+alice+`"}`)
		if status != 200 {
			t.Fatalf("login %d", status)
		}
		return data["accessToken"].(string)
	}
	phone, laptop, tablet := login("android"), login("web"), login("smart-fridge")
	_, _ = call("POST", "/dev/session", "", "ios", `{"userId":"`+bob+`"}`)

	sessions := func(token string) []map[string]any {
		t.Helper()
		status, data := call("GET", "/v1/auth/sessions", token, "", "")
		if status != 200 {
			t.Fatalf("sessions %d", status)
		}
		return items(data)
	}
	list := sessions(phone)
	platforms := map[string]bool{}
	for _, s := range list {
		platforms[s["platform"].(string)] = true
	}
	if len(list) != 3 || !platforms["android"] || !platforms["web"] || !platforms["unknown"] {
		t.Fatalf("sessions %v", list)
	}

	// Signing out the laptop removes it from the list, not just marks it.
	var laptopID string
	for _, s := range sessions(laptop) {
		if s["current"] == true {
			laptopID = s["sessionId"].(string)
		}
	}
	if status, _ := call("DELETE", "/v1/auth/sessions/"+laptopID, phone, "", ""); status != 200 {
		t.Fatalf("revoke %d", status)
	}
	if len(sessions(phone)) != 2 {
		t.Fatal("revoked session still listed")
	}
	status, data := call("POST", "/v1/auth/sessions/revoke-others", phone, "", "")
	if status != 200 || data["revoked"] != float64(1) {
		t.Fatalf("revoke others %d %v", status, data)
	}
	if status, _ := call("GET", "/v1/me/profile", tablet, "", ""); status != 401 {
		t.Fatalf("other session still works: %d", status)
	}
	if list := sessions(phone); len(list) != 1 || list[0]["current"] != true {
		t.Fatalf("after revoke-others %v", list)
	}
	// Bob's session was untouched.
	var bobLive int
	if err = db.Pool.QueryRow(ctx, `SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, bob).Scan(&bobLive); err != nil || bobLive != 1 {
		t.Fatalf("bob sessions %d %v", bobLive, err)
	}

	// Authenticating reads the session; last_seen_at moves at most once a minute.
	seen := func() time.Time {
		var at time.Time
		_ = db.Pool.QueryRow(ctx, `SELECT last_seen_at FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, alice).Scan(&at)
		return at
	}
	recent := time.Now().Add(-30 * time.Second).UTC().Truncate(time.Microsecond)
	_, _ = db.Pool.Exec(ctx, `UPDATE sessions SET last_seen_at=$2 WHERE user_id=$1`, alice, recent)
	call("GET", "/v1/me/profile", phone, "", "")
	if !seen().Equal(recent) {
		t.Fatal("last_seen_at written within a minute")
	}
	_, _ = db.Pool.Exec(ctx, `UPDATE sessions SET last_seen_at=now()-interval '2 minutes' WHERE user_id=$1`, alice)
	call("GET", "/v1/me/profile", phone, "", "")
	if time.Since(seen()) > 5*time.Second {
		t.Fatal("stale last_seen_at not refreshed")
	}

	// Expired sessions are purged after the retention window, in batches.
	_, _ = db.Pool.Exec(ctx, `UPDATE sessions SET expires_at=now()-interval '40 days' WHERE revoked_at IS NOT NULL`)
	n, err := db.PurgeSessions(ctx, 30*24*time.Hour, 1)
	if err != nil || n != 1 {
		t.Fatalf("purge %d %v", n, err)
	}
	n, _ = db.PurgeSessions(ctx, 30*24*time.Hour, 100)
	if n != 1 {
		t.Fatalf("second purge %d", n)
	}
}

// A Firebase session is sub plus auth_time, and a refresh token keeps minting ID tokens for
// it, so a session whose last token has expired is still signed in: listing, revoking and
// purging must treat it as live, and a revoked one must never come back.
func TestProviderSessionsStayRevokedWhileTheirTokensRefresh(t *testing.T) {
	h := newSocialHarness(t)
	ctx := h.ctx
	const issuer = "https://securetoken.google.com/hiyall-test"
	resolve := func(sub string, authTime int64) (store.Principal, error) {
		return h.db.ResolveOIDC(ctx, issuer, sub, "fb:"+sub+":"+strconv.FormatInt(authTime, 10), time.Now().Add(time.Hour))
	}
	list := func(p store.Principal) []store.Session {
		t.Helper()
		got, err := h.db.ListSessions(ctx, p, 50, nil, uuid.Nil.String())
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	now := time.Now().Unix()
	idle, err := resolve("sub-a", now-7200)
	if err != nil {
		t.Fatal(err)
	}
	current, err := resolve("sub-a", now-3600)
	if err != nil {
		t.Fatal(err)
	}
	// The idle device's last ID token expired an hour ago; it is still signed in and listed.
	h.exec(`UPDATE sessions SET expires_at=now()-interval '1 hour',last_seen_at=now()-interval '2 hours' WHERE session_id=$1`, idle.SessionID)
	if got := list(current); len(got) != 2 {
		t.Fatalf("sessions %v", got)
	}
	// Sign out everywhere else reaches it, and its refreshed token cannot revive it.
	if n, err := h.db.RevokeOtherSessions(ctx, current); err != nil || n != 1 {
		t.Fatalf("revoke others %d %v", n, err)
	}
	if _, err = resolve("sub-a", now-7200); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("revoked idle session revived: %v", err)
	}
	// A sign-in from before the watermark that the server never saw is refused too.
	if _, err = resolve("sub-a", now-60); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("earlier sign-in accepted after sign-out everywhere else: %v", err)
	}
	// The device that signed the others out keeps its session, and a new sign-in works.
	if again, err := resolve("sub-a", now-3600); err != nil || again.SessionID != current.SessionID {
		t.Fatalf("current session %v %v", again, err)
	}
	if _, err = resolve("sub-a", time.Now().Unix()+2); err != nil {
		t.Fatalf("new sign-in refused: %v", err)
	}
	if got := list(current); len(got) != 2 {
		t.Fatalf("after revoke-others %v", got)
	}

	// A revoked provider session is a tombstone the purge never deletes.
	gone, err := resolve("sub-b", now-100)
	if err != nil {
		t.Fatal(err)
	}
	if err = h.db.RevokeSession(ctx, gone, gone.SessionID); err != nil {
		t.Fatal(err)
	}
	h.exec(`UPDATE sessions SET expires_at=now()-interval '500 days',last_seen_at=now()-interval '500 days' WHERE session_id=$1`, gone.SessionID)
	// Purged: an expired development session, and a provider session never revoked and unused for over 400 days.
	dev, err := h.db.CreateDevSession(ctx, alice, "dev-token-purge", "web")
	if err != nil {
		t.Fatal(err)
	}
	h.exec(`UPDATE sessions SET expires_at=now()-interval '40 days' WHERE session_id=$1`, dev.SessionID)
	stale, err := resolve("sub-c", now-100)
	if err != nil {
		t.Fatal(err)
	}
	h.exec(`UPDATE sessions SET expires_at=now()-interval '401 days',last_seen_at=now()-interval '401 days' WHERE session_id=$1`, stale.SessionID)
	// Kept: a provider session that expired long ago but was used recently.
	h.exec(`UPDATE sessions SET expires_at=now()-interval '40 days' WHERE session_id=$1`, idle.SessionID)
	if n, err := h.db.PurgeSessions(ctx, 30*24*time.Hour, 100); err != nil || n != 2 {
		t.Fatalf("purged %d %v", n, err)
	}
	var left int
	if err = h.db.Pool.QueryRow(ctx, `SELECT count(*) FROM sessions WHERE session_id=ANY($1::uuid[])`, []string{gone.SessionID, idle.SessionID, dev.SessionID, stale.SessionID}).Scan(&left); err != nil || left != 2 {
		t.Fatalf("rows left %d %v", left, err)
	}
	if _, err = resolve("sub-b", now-100); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("revoked sid recreated after purge: %v", err)
	}
	// A provider session not used for over 30 days is no longer listed.
	h.exec(`UPDATE sessions SET last_seen_at=now()-interval '31 days',expires_at=now()-interval '31 days' WHERE user_id=$1 AND session_id<>$2`, current.UserID, current.SessionID)
	if got := list(current); len(got) != 1 || !got[0].Current {
		t.Fatalf("stale sessions listed %v", got)
	}
}
