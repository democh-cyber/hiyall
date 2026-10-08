package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"kairova/services/api/internal/store"
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
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "kairova_test" {
		t.Fatal("integration tests require database named kairova_test")
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
