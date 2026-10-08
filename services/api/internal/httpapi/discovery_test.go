package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
)

func TestDiscoverySearchSecurityAndPagination(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Pool.Close()
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "kairova_test" {
		t.Fatal("requires dedicated kairova_test database")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions,blocks,outbox_events CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := db.Pool.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	api := New(db, func(_ context.Context, token string) (store.Principal, error) {
		if token == alice || token == bob {
			return store.Principal{UserID: token}, nil
		}
		return store.Principal{}, domain.ErrUnauthorized
	}, false, "")
	call := func(actor, body string) (int, map[string]any) {
		t.Helper()
		r := httptest.NewRequest("POST", "/v1/discovery/search", bytes.NewBufferString(body))
		r.Header.Set("Content-Type", "application/json")
		if actor != "" {
			r.Header.Set("Authorization", "Bearer "+actor)
		}
		w := httptest.NewRecorder()
		api.Handler().ServeHTTP(w, r)
		var result map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(w.Body.String())
		}
		return w.Code, result
	}
	search := func(body string) map[string]any {
		t.Helper()
		api.search.reset(alice)
		status, value := call(alice, body)
		if status != 200 {
			t.Fatalf("status=%d response=%v", status, value)
		}
		return value["data"].(map[string]any)
	}
	expectCount := func(body string, n int) {
		t.Helper()
		data := search(body)
		if len(data["items"].([]any)) != n {
			t.Fatalf("filter %s: got %v want %d", body, data, n)
		}
	}
	if status, _ := call("", "{}"); status != 401 {
		t.Fatal("anonymous search allowed")
	}
	if status, _ := call(alice, "{}"); status != 403 {
		t.Fatal("unknown-age viewer allowed")
	}
	exec(`INSERT INTO discovery_eligibility(user_id,age_group,confirmed_at,valid_until) VALUES($1,'adult',now()-interval '1 day',now()+interval '1 day')`, alice)
	exec(`UPDATE profiles SET data=data || '{"displayName":"A public person","headline":"A quiet hello","interests":["Music","Books"],"currentVibe":"Chill","languages":[{"code":"ko","level":"basic"},"en"],"country":"IN","email":"private@example.test","phone":"private","birthYear":2004,"city":"private city","coin":999}'::jsonb WHERE user_id=$1`, bob)
	exec(`UPDATE privacy_settings SET data=data || '{"profileAudience":"public","discoverable":true,"fieldAudiences":{"interests":"everyone","languages":"everyone","vibe":"everyone","location":"everyone"}}'::jsonb WHERE user_id=$1`, bob)
	expectCount("{}", 0) // public and opted-in is insufficient without adult eligibility
	exec(`INSERT INTO discovery_eligibility(user_id,age_group,confirmed_at,valid_until) VALUES($1,'minor',now()-interval '1 day',now()+interval '1 day')`, bob)
	expectCount("{}", 0)
	exec(`UPDATE discovery_eligibility SET age_group='adult' WHERE user_id=$1`, bob)
	expectCount(`{"interests":["music","Nonmatch"],"languages":["ko"],"vibe":"chill","country":"IN"}`, 1)
	expectCount(`{"interests":["No match"]}`, 0)
	expectCount(`{"languages":["es"]}`, 0)
	expectCount(`{"country":"PH"}`, 0)
	expectCount(`{"vibe":"Active"}`, 0)
	data := search("{}")
	item := data["items"].([]any)[0].(map[string]any)
	for _, key := range []string{"email", "phone", "birthYear", "coin", "city", "region", "uid", "version", "createdAt", "lastSeenAt", "age_group", "confirmed_at"} {
		if _, ok := item[key]; ok {
			t.Fatalf("private field %s leaked", key)
		}
	}
	for _, pair := range [][2]string{{"interests", `{"interests":["music"]}`}, {"languages", `{"languages":["ko"]}`}, {"vibe", `{"vibe":"Chill"}`}, {"location", `{"country":"IN"}`}} {
		exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],'"nobody"') WHERE user_id=$1`, bob, pair[0])
		expectCount(pair[1], 0)
	}
	item = search("{}")["items"].([]any)[0].(map[string]any)
	for _, key := range []string{"interests", "languages", "currentVibe", "country"} {
		if _, ok := item[key]; ok {
			t.Fatalf("revoked %s field leaked", key)
		}
	}
	exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{discoverable}','false') WHERE user_id=$1`, bob)
	expectCount("{}", 0)
	exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{discoverable}','true') WHERE user_id=$1`, bob)
	exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{profileAudience}','"friends"') WHERE user_id=$1`, bob)
	expectCount("{}", 0)
	exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{profileAudience}','"public"') WHERE user_id=$1`, bob)
	for _, pair := range [][2]string{{alice, bob}, {bob, alice}} {
		exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, pair[0], pair[1])
		expectCount("{}", 0)
		exec(`DELETE FROM blocks WHERE blocker_id=$1 AND blocked_id=$2`, pair[0], pair[1])
	}
	exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, bob)
	expectCount("{}", 0)
	exec(`UPDATE users SET status='active' WHERE user_id=$1`, bob)
	exec(`UPDATE discovery_eligibility SET confirmed_at=now()-interval '2 days',valid_until=now()-interval '1 day' WHERE user_id=$1`, bob)
	expectCount("{}", 0)
	exec(`UPDATE discovery_eligibility SET valid_until=now()+interval '1 day' WHERE user_id=$1`, bob)
	// Enough strictly test-only eligible adults for a bounded, deterministic page.
	for i := 3; i <= 25; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", i)
		exec(`INSERT INTO users(user_id) VALUES($1)`, id)
		exec(`INSERT INTO profiles(user_id,username,data) VALUES($1,$2,'{"displayName":"Test person"}')`, id, fmt.Sprintf("test_person_%d", i))
		exec(`INSERT INTO privacy_settings(user_id,data) VALUES($1,'{"profileAudience":"public","discoverable":true}')`, id)
		exec(`INSERT INTO discovery_eligibility(user_id,age_group,confirmed_at,valid_until) VALUES($1,'adult',now()-interval '1 day',now()+interval '1 day')`, id)
	}
	first := search("{}")
	if len(first["items"].([]any)) != 20 || first["nextCursor"] == nil {
		t.Fatal("missing bounded page")
	}
	next := first["nextCursor"].(string)
	body, _ := json.Marshal(map[string]any{"cursor": next})
	second := search(string(body))
	if len(second["items"].([]any)) != 4 || second["nextCursor"] != nil {
		t.Fatalf("wrong second page %v", second)
	}
	seen := map[string]bool{}
	for _, page := range []map[string]any{first, second} {
		for _, value := range page["items"].([]any) {
			id := value.(map[string]any)["userId"].(string)
			if seen[id] || id == alice {
				t.Fatal("duplicate/self result")
			}
			seen[id] = true
		}
	}
	for _, bad := range []map[string]any{{"cursor": next, "country": "IN"}, {"cursor": next + "tamper"}, {"email": "private@example.test"}, {"minAge": 12}, {"gender": "men"}, {"interests": nil}, {"languages": []string{"en", "EN"}}} {
		api.search.reset(alice)
		body, _ := json.Marshal(bad)
		if status, _ := call(alice, string(body)); status != 422 {
			t.Fatalf("invalid search allowed: %v status %d", bad, status)
		}
	}
	if status, _ := call(bob, string(body)); status != 422 {
		t.Fatal("invalid body not rejected")
	}
	cross, _ := json.Marshal(map[string]any{"cursor": next})
	if status, _ := call(bob, string(cross)); status != 422 {
		t.Fatal("cross-principal cursor accepted")
	}
	expired := api.peopleSign(peopleCursor{User: alice, Query: "irrelevant", After: bob, Exp: time.Now().Add(-time.Minute).Unix(), Page: 1})
	expiredBody, _ := json.Marshal(map[string]any{"cursor": expired})
	if status, _ := call(alice, string(expiredBody)); status != 422 {
		t.Fatal("expired cursor accepted")
	}
	// Every page re-authorizes; revoking the next candidate removes it immediately.
	exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{discoverable}','false') WHERE user_id='019a4000-0000-7000-8000-000000000025'`)
	expectCount(string(cross), 3)
	exec(`UPDATE discovery_eligibility SET age_group='minor' WHERE user_id=$1`, alice)
	if status, _ := call(alice, "{}"); status != 403 {
		t.Fatal("revoked viewer eligibility ignored")
	}
	// The consumer profile cannot assign its own age assurance.
	patch := map[string]json.RawMessage{"adultEligible": json.RawMessage("true")}
	if domain.ValidateProfilePatch(patch) == nil {
		t.Fatal("client eligibility assignment accepted")
	}
	api.search.reset(alice)
	for i := 0; i < 10; i++ {
		if !api.allowSearch(alice) {
			t.Fatal("unexpected rate limit")
		}
	}
	if api.allowSearch(alice) {
		t.Fatal("search burst unbounded")
	}
}
