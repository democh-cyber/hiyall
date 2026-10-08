package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"
)

const alice = "019a4000-0000-7000-8000-000000000001"
const bob = "019a4000-0000-7000-8000-000000000002"

func TestAPIIntegration(t *testing.T) {
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
	// The test owns a dedicated database; never set this to the development or production DB.
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "kairova_test" {
		t.Fatal("integration tests require database named kairova_test")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions,blocks,outbox_events CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	api := New(db, db.VerifyDevSession, true, "")
	handler := api.Handler()
	call := func(method, path, token, version, body string) (int, map[string]any) {
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		req.RemoteAddr = "127.0.0.1:44001"
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if version != "" {
			req.Header.Set("If-Match", version)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		var value map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &value); err != nil {
			t.Fatal(rec.Body.String())
		}
		return rec.Code, value
	}
	expect := func(status, expected int) {
		t.Helper()
		if status != expected {
			t.Fatalf("status %d, want %d", status, expected)
		}
	}
	status, _ := call("GET", "/v1/me/profile", "", "", "")
	expect(status, 401)
	status, result := call("POST", "/dev/session", "", "", `{"userId":"`+alice+`"}`)
	expect(status, 200)
	tokenA := result["data"].(map[string]any)["accessToken"].(string)
	status, result = call("POST", "/dev/session", "", "", `{"userId":"`+bob+`"}`)
	expect(status, 200)
	tokenB := result["data"].(map[string]any)["accessToken"].(string)
	sidB := result["data"].(map[string]any)["sessionId"].(string)
	// A friends-only profile is a locked card: identity and relationship, nothing else.
	status, result = call("GET", "/v1/users/"+bob+"/profile", tokenA, "", "")
	expect(status, 200)
	locked := result["data"].(map[string]any)
	if locked["locked"] != true || locked["username"] != "niko" {
		t.Fatalf("locked card missing: %v", locked)
	}
	for _, field := range []string{"bio", "headline", "quote", "socialStats", "interests", "languages", "country"} {
		if _, exists := locked[field]; exists {
			t.Fatalf("locked card disclosed %s", field)
		}
	}
	status, _ = call("PATCH", "/v1/me/profile", tokenA, "", `{"bio":"hello"}`)
	expect(status, 428)
	status, _ = call("PATCH", "/v1/me/profile", tokenA, `"1"`, `{"userId":"`+bob+`"}`)
	expect(status, 422)
	status, _ = call("PATCH", "/v1/me/profile", tokenA, `"1"`, `{"bio":"first","bio":"second"}`)
	expect(status, 422)
	status, _ = call("PATCH", "/v1/me/profile", tokenA, `"1"`, `{"bio":"one"}`)
	expect(status, 200)
	status, _ = call("PATCH", "/v1/me/profile", tokenA, `"1"`, `{"bio":"lost update"}`)
	expect(status, 412)
	status, _ = call("PATCH", "/v1/me/profile", tokenB, `"1"`, `{"profileAudience":"public","profession":"Private profession","headline":"A quiet corner","quote":"Quiet curiosity","interests":["Reading"],"currentVibe":"Reading a book","languages":[{"code":"ko","level":"basic"}],"profileAccent":"violet","profilePattern":"orbit","country":"IN","city":"private city","region":"private region"}`)
	expect(status, 200)
	status, result = call("GET", "/v1/users/"+bob+"/profile", tokenA, "", "")
	expect(status, 200)
	if _, ok := result["data"].(map[string]any)["profession"]; ok {
		t.Fatal("private field disclosed")
	}
	privateProjection := result["data"].(map[string]any)
	for _, field := range []string{"socialStats", "interests", "currentVibe", "languages", "email", "phone", "birthYear", "coin", "createdAt", "updatedAt", "uid", "lastLoginTime"} {
		if _, exists := privateProjection[field]; exists {
			t.Fatalf("private field disclosed: %s", field)
		}
	}
	if privateProjection["headline"] != "A quiet corner" {
		t.Fatal("headline missing")
	}

	status, _ = call("PATCH", "/v1/me/privacy", tokenB, `"2"`, `{"fieldAudiences":{"profession":"everyone","interests":"everyone","vibe":"everyone","languages":"everyone","location":"everyone"}}`)
	expect(status, 200)
	status, result = call("GET", "/v1/users/"+bob+"/profile", tokenA, "", "")
	expect(status, 200)
	if result["data"].(map[string]any)["profession"] != "Private profession" {
		t.Fatal("public field missing")
	}
	publicProjection := result["data"].(map[string]any)
	if publicProjection["currentVibe"] != "Reading a book" || len(publicProjection["interests"].([]any)) != 1 {
		t.Fatal("public expressive fields missing")
	}
	language := publicProjection["languages"].([]any)[0].(map[string]any)
	if language["code"] != "ko" || language["level"] != "basic" {
		t.Fatal("language proficiency lost")
	}
	// A stored account/private canary must never enter the visitor allowlist.
	if _, err := db.Pool.Exec(ctx, `UPDATE profiles SET data=data || '{"email":"private@example.test","phone":"secret","uid":"provider-subject","coin":900,"birthYear":2004,"lastLoginTime":"private"}'::jsonb WHERE user_id=$1`, bob); err != nil {
		t.Fatal(err)
	}
	status, result = call("GET", "/v1/users/"+bob+"/profile", tokenA, "", "")
	expect(status, 200)
	for _, field := range []string{"email", "phone", "uid", "coin", "birthYear", "lastLoginTime", "createdAt", "version", "sessions", "city", "region"} {
		if _, exists := result["data"].(map[string]any)[field]; exists {
			t.Fatalf("account canary disclosed: %s", field)
		}
	}
	status, _ = call("PATCH", "/v1/me/privacy", tokenB, `"3"`, `{"fieldAudiences":{"vibe":"friends","interests":"nobody","languages":"followers"}}`)
	expect(status, 200)
	status, result = call("GET", "/v1/users/"+bob+"/profile", tokenA, "", "")
	expect(status, 200)
	for _, field := range []string{"currentVibe", "interests", "languages"} {
		if _, exists := result["data"].(map[string]any)[field]; exists {
			t.Fatalf("restricted field disclosed: %s", field)
		}
	}

	status, _ = call("POST", "/v1/users/"+alice+"/block", tokenB, "", "")
	expect(status, 200)
	status, _ = call("GET", "/v1/users/"+bob+"/profile", tokenA, "", "")
	expect(status, 404)
	status, _ = call("DELETE", "/v1/auth/sessions/"+sidB, tokenA, "", "")
	expect(status, 404)
	// Competing writes must commit once, with exactly one outbox event.
	var before, after int
	_ = db.Pool.QueryRow(ctx, "SELECT count(*) FROM outbox_events").Scan(&before)
	var wg sync.WaitGroup
	statuses := make(chan int, 2)
	for _, bio := range []string{"race-a", "race-b"} {
		wg.Add(1)
		go func(value string) {
			defer wg.Done()
			status, _ := call("PATCH", "/v1/me/profile", tokenA, `"2"`, `{"bio":"`+value+`"}`)
			statuses <- status
		}(bio)
	}
	wg.Wait()
	close(statuses)
	wins, conflicts := 0, 0
	for status := range statuses {
		if status == 200 {
			wins++
		}
		if status == 412 {
			conflicts++
		}
	}
	if wins != 1 || conflicts != 1 {
		t.Fatalf("race outcomes %d/%d", wins, conflicts)
	}
	_ = db.Pool.QueryRow(ctx, "SELECT count(*) FROM outbox_events").Scan(&after)
	if after-before != 1 {
		t.Fatal("outbox not atomic")
	}
	status, _ = call("POST", "/v1/auth/logout", tokenB, "", "")
	expect(status, 200)
	status, _ = call("GET", "/v1/me/profile", tokenB, "", "")
	expect(status, 401)
	status, _ = call("GET", "/v1/users/not-a-uuid/profile", tokenA, "", "")
	expect(status, 404)
	status, _ = call("GET", "/v1/auth/sessions?limit=51", tokenA, "", "")
	expect(status, 422)

	// Revoked OIDC sid cannot be recreated by a still-valid access token.
	oidcPrincipal, err := db.ResolveOIDC(ctx, "https://identity.example", "test-subject", "test-device", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err = db.RevokeSession(ctx, oidcPrincipal, oidcPrincipal.SessionID); err != nil {
		t.Fatal(err)
	}
	if _, err = db.ResolveOIDC(ctx, "https://identity.example", "test-subject", "test-device", time.Now().Add(time.Minute)); !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("revoked OIDC sid resurrected: %v", err)
	}
	var duplicateClocks int
	if err = db.Pool.QueryRow(ctx, `SELECT count(*) FROM (SELECT aggregate_id,aggregate_version FROM outbox_events GROUP BY aggregate_id,aggregate_version HAVING count(*)>1) d`).Scan(&duplicateClocks); err != nil || duplicateClocks != 0 {
		t.Fatalf("outbox order: %d %v", duplicateClocks, err)
	}
	// Issue enough sessions for a cursor, then verify it cannot cross account boundaries.
	_, _ = db.CreateDevSession(ctx, alice, "extra-token")
	status, result = call("GET", "/v1/auth/sessions?limit=1", tokenA, "", "")
	expect(status, 200)
	cursor := result["data"].(map[string]any)["nextCursor"].(string)
	_, _ = db.CreateDevSession(ctx, bob, "fresh-bob")
	status, _ = call("GET", "/v1/auth/sessions?cursor="+cursor, "fresh-bob", "", "")
	expect(status, 422)
	status, _ = call("GET", "/v1/auth/sessions?cursor="+cursor, tokenA, "", "")
	expect(status, 200)
	req := httptest.NewRequest(http.MethodPost, "/dev/session", bytes.NewBufferString(`{"userId":"`+alice+`"}`))
	req.RemoteAddr = "192.0.2.1:5555"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	expect(rec.Code, 403)
}
