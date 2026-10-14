package httpapi

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/identity"
	"hiyall/services/api/internal/realtime"
	"hiyall/services/api/internal/store"
)

const sam = store.SamID
const onboardingMessage = "Finish setting up your profile to continue."

type onboardingHarness struct {
	t       *testing.T
	ctx     context.Context
	db      *store.Store
	api     *API
	handler http.Handler
}

type response struct {
	status  int
	data    map[string]any
	code    string
	message string
	header  http.Header
}

func connectTestDB(t *testing.T) (context.Context, *store.Store) {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "hiyall_test" {
		t.Fatal("integration tests require database named hiyall_test")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions,blocks,outbox_events CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	return ctx, db
}

// newOnboardingHarness serves the API with local development sessions over a freshly seeded database.
func newOnboardingHarness(t *testing.T) *onboardingHarness {
	ctx, db := connectTestDB(t)
	api := New(db, db.VerifyDevSession, true, "")
	return &onboardingHarness{t, ctx, db, api, api.Handler()}
}

func serve(t *testing.T, handler http.Handler, method, path, token string, headers map[string]string, body string) response {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.RemoteAddr = "127.0.0.1:44001"
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	var envelope struct {
		Data  map[string]any    `json:"data"`
		Error map[string]string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("%s %s: %d %s", method, path, rec.Code, rec.Body.String())
	}
	return response{rec.Code, envelope.Data, envelope.Error["code"], envelope.Error["message"], rec.Header()}
}

func (h *onboardingHarness) call(method, path, token, body string) response {
	h.t.Helper()
	return serve(h.t, h.handler, method, path, token, nil, body)
}

// rawCall returns a response body as text, for checks that nothing was disclosed.
func (h *onboardingHarness) rawCall(method, path, token string) string {
	h.t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(""))
	req.RemoteAddr = "127.0.0.1:44001"
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	if rec.Code != 200 {
		h.t.Fatalf("%s %s: %d %s", method, path, rec.Code, rec.Body.String())
	}
	return rec.Body.String()
}

func (h *onboardingHarness) expect(got response, status int, code string) response {
	h.t.Helper()
	if got.status != status || got.code != code {
		h.t.Fatalf("got %d %q (%s), want %d %q; data %v", got.status, got.code, got.message, status, code, got.data)
	}
	return got
}

func (h *onboardingHarness) login(userID string) string {
	h.t.Helper()
	got := h.expect(h.call("POST", "/dev/session", "", `{"userId":"`+userID+`"}`), 200, "")
	return got.data["accessToken"].(string)
}

func (h *onboardingHarness) onboardingRow(userID string) (declared, accepted, completed *time.Time, terms *string) {
	h.t.Helper()
	err := h.db.Pool.QueryRow(h.ctx, `SELECT age_declared_at,terms_accepted_at,completed_at,terms_version FROM onboarding WHERE user_id=$1`, userID).Scan(&declared, &accepted, &completed, &terms)
	if err != nil {
		h.t.Fatal(err)
	}
	return
}

// memberBirthDate is an adult (25), minorBirthDate a 15 year old, underageBirthDate is 12 years old and
// is refused.
func memberBirthDate() string   { return time.Now().UTC().AddDate(-25, 0, 0).Format(time.DateOnly) }
func minorBirthDate() string    { return time.Now().UTC().AddDate(-15, 0, 0).Format(time.DateOnly) }
func underageBirthDate() string { return time.Now().UTC().AddDate(-12, 0, 0).Format(time.DateOnly) }

// birthdayToday is the birth date of someone who turns `years` today; the leap day
// is clamped so the answer is the same every day of the year. turnsTomorrow is the
// date of someone who turns `years` tomorrow, so is still one year younger today.
func birthdayToday(years int) string {
	now := time.Now().UTC()
	day := now.Day()
	if now.Month() == time.February && day == 29 {
		day = 28
	}
	return time.Date(now.Year()-years, now.Month(), day, 0, 0, 0, 0, time.UTC).Format(time.DateOnly)
}
func turnsTomorrow(years int) string {
	tomorrow := time.Now().UTC().AddDate(0, 0, 1)
	return time.Date(tomorrow.Year()-years, tomorrow.Month(), tomorrow.Day(), 0, 0, 0, 0, time.UTC).Format(time.DateOnly)
}

func completeBody(birth, terms string) string {
	return `{"birthDate":"` + birth + `","termsVersion":"` + terms + `"}`
}

func TestSeededFixturesAndSamOnboarding(t *testing.T) {
	h := newOnboardingHarness(t)
	for _, tc := range []struct {
		id        string
		completed bool
		username  string
	}{{alice, true, "anjali"}, {bob, true, "niko"}, {sam, false, "member_0000000000a1"}} {
		token := h.login(tc.id)
		got := h.expect(h.call("GET", "/v1/me/onboarding", token, ""), 200, "").data
		if got["completed"] != tc.completed || got["termsVersion"] != "2026-10-01" {
			t.Fatalf("%s onboarding %v", tc.username, got)
		}
		if (got["completedAt"] != nil) != tc.completed {
			t.Fatalf("%s completedAt %v", tc.username, got["completedAt"])
		}
		profile := h.expect(h.call("GET", "/v1/me/profile", token, ""), 200, "").data
		if profile["username"] != tc.username {
			t.Fatalf("username %v", profile["username"])
		}
		feed := h.call("GET", "/v1/feed", token, "")
		if tc.completed {
			h.expect(feed, 200, "")
		} else {
			h.expect(feed, 403, "ONBOARDING_REQUIRED")
			if profile["displayName"] != "Hiyall member" {
				t.Fatalf("Sam display name %v", profile["displayName"])
			}
		}
	}
	// Seeding again is a no-op for every fixture: Sam stays incomplete, others stay complete.
	declared, _, completed, terms := h.onboardingRow(sam)
	if declared != nil || completed != nil || terms != nil {
		t.Fatalf("Sam row %v %v %v", declared, completed, terms)
	}
	var created time.Time
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT created_at FROM onboarding WHERE user_id=$1`, sam).Scan(&created); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := h.db.Seed(h.ctx); err != nil {
			t.Fatal(err)
		}
	}
	var again time.Time
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT created_at FROM onboarding WHERE user_id=$1`, sam).Scan(&again); err != nil || !again.Equal(created) {
		t.Fatalf("Seed rewrote Sam's row: %v %v", again, err)
	}
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM onboarding WHERE completed_at IS NULL`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("%d incomplete rows after reseeding (err %v), want only Sam", n, err)
	}
	// Once Sam finishes, Seed must not take it back; a missing row is restored as incomplete, never complete.
	h.mustExec(`UPDATE onboarding SET completed_at=now(),terms_version='2026-10-01' WHERE user_id=$1`, sam)
	if err := h.db.Seed(h.ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, completed, _ = h.onboardingRow(sam); completed == nil {
		t.Fatal("Seed un-completed Sam")
	}
	h.mustExec(`DELETE FROM onboarding WHERE user_id=$1`, sam)
	if err := h.db.Seed(h.ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, completed, _ = h.onboardingRow(sam); completed != nil {
		t.Fatal("Seed completed a restored Sam row")
	}
}

func (h *onboardingHarness) mustExec(sql string, args ...any) {
	h.t.Helper()
	if _, err := h.db.Pool.Exec(h.ctx, sql, args...); err != nil {
		h.t.Fatal(err)
	}
}

// Every route outside the allow-list answers 403 before its handler runs, including unknown paths and
// wrong methods; the allow-list itself stays reachable. The same requests are not gated once onboarded.
func TestOnboardingGateIsCentral(t *testing.T) {
	h := newOnboardingHarness(t)
	samToken, anjaliToken := h.login(sam), h.login(alice)
	gated := [][2]string{
		{"GET", "/v1/feed"}, {"POST", "/v1/posts"}, {"POST", "/v1/discovery/search"}, {"GET", "/v1/notifications"},
		{"GET", "/v1/notifications/unread-count"}, {"GET", "/v1/conversations"}, {"POST", "/v1/conversations"}, {"POST", "/v1/devices"},
		{"GET", "/v1/me/devices"}, {"GET", "/v1/spaces"}, {"POST", "/v1/spaces"}, {"GET", "/v1/me/blocked"}, {"GET", "/v1/me/muted"},
		{"POST", "/v1/reports"}, {"GET", "/v1/me/friends"}, {"GET", "/v1/me/followers"}, {"GET", "/v1/me/following"},
		{"GET", "/v1/users/" + bob + "/profile"}, {"POST", "/v1/users/" + bob + "/follow"}, {"POST", "/v1/users/" + bob + "/block"},
		{"POST", "/v1/users/" + bob + "/friend-requests"}, {"GET", "/v1/stories"},
		// Method and path matter: only the listed combinations are open.
		{"DELETE", "/v1/me/profile"}, {"PUT", "/v1/me/privacy"}, {"POST", "/v1/me/profile"}, {"POST", "/v1/me/onboarding"},
		{"GET", "/v1/me/onboarding/complete"}, {"POST", "/v1/usernames/sam_k/availability"}, {"GET", "/v1/usernames/sam_k"},
		{"GET", "/v1/usernames//availability"}, {"GET", "/v1/usernames/a/b/availability"}, {"GET", "/v1/me/profile/"},
		{"GET", "/v1//me/profile"}, {"GET", "/v1/unknown"}, {"GET", "/anything"},
	}
	for _, route := range gated {
		got := h.call(route[0], route[1], samToken, "")
		if got.status != 403 || got.code != "ONBOARDING_REQUIRED" || got.message != onboardingMessage {
			t.Fatalf("%s %s: %d %q %q, want 403 ONBOARDING_REQUIRED", route[0], route[1], got.status, got.code, got.message)
		}
		if after := h.call(route[0], route[1], anjaliToken, ""); after.code == "ONBOARDING_REQUIRED" {
			t.Fatalf("%s %s gated an onboarded account", route[0], route[1])
		}
	}
	open := []struct {
		method, path, body string
		status             int
		code               string
	}{
		{"GET", "/v1/me/profile", "", 200, ""},
		{"GET", "/v1/me/privacy", "", 200, ""},
		{"PATCH", "/v1/me/profile", `{"bio":"x"}`, 428, "PRECONDITION_REQUIRED"},
		{"PATCH", "/v1/me/privacy", `{"readReceipts":true}`, 428, "PRECONDITION_REQUIRED"},
		{"GET", "/v1/me/onboarding", "", 200, ""},
		{"POST", "/v1/me/onboarding/complete", `{}`, 422, "VALIDATION"},
		{"GET", "/v1/usernames/free_name/availability", "", 200, ""},
		{"GET", "/v1/auth/sessions", "", 200, ""},
		{"POST", "/v1/auth/sessions/revoke-others", "", 200, ""},
		{"DELETE", "/v1/auth/sessions/" + uuidNil, "", 404, "NOT_FOUND"},
	}
	for _, route := range open {
		h.expect(h.call(route.method, route.path, samToken, route.body), route.status, route.code)
	}
	h.expect(h.call("POST", "/v1/auth/logout", samToken, ""), 200, "")
	h.expect(h.call("GET", "/v1/me/profile", samToken, ""), 401, "UNAUTHENTICATED")
	h.expect(h.call("GET", "/v1/me/onboarding", "", ""), 401, "UNAUTHENTICATED")
}

const uuidNil = "00000000-0000-0000-0000-000000000000"

func TestOnboardingBlocksRealtimeUntilComplete(t *testing.T) {
	h := newOnboardingHarness(t)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	h.api.RT = realtime.NewHub(realtime.NewLocalBus(), 2, 100)
	go h.api.RT.Run(ctx, func(int) time.Duration { return 10 * time.Millisecond })
	server := httptest.NewServer(h.api.Handler())
	t.Cleanup(server.Close)
	samToken, anjaliToken := h.login(sam), h.login(alice)
	if _, resp, err := dial(t, server, samToken); err == nil || resp == nil || resp.StatusCode != 403 {
		t.Fatalf("an account that has not onboarded opened a socket: %v %v", resp, err)
	} else {
		var body struct{ Error map[string]string }
		raw, _ := io.ReadAll(resp.Body)
		if json.Unmarshal(raw, &body) != nil || body.Error["code"] != "ONBOARDING_REQUIRED" || body.Error["message"] != onboardingMessage {
			t.Fatalf("socket refusal %s", raw)
		}
	}
	if h.api.RT.Count() != 0 {
		t.Fatal("a refused socket was registered")
	}
	if _, _, err := dial(t, server, anjaliToken); err != nil {
		t.Fatalf("an onboarded account cannot connect: %v", err)
	}
	// Finishing onboarding opens the socket for the very same token.
	h.finishProfile(samToken, "sam_k", "Sam")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", samToken, completeBody(memberBirthDate(), "2026-10-01")), 200, "")
	if _, _, err := dial(t, server, samToken); err != nil {
		t.Fatalf("a completed account cannot connect: %v", err)
	}
}

func (h *onboardingHarness) finishProfile(token, username, name string) {
	h.t.Helper()
	got := serve(h.t, h.handler, "PATCH", "/v1/me/profile", token, map[string]string{"If-Match": `"1"`}, `{"username":"`+username+`","displayName":"`+name+`"}`)
	h.expect(got, 200, "")
}

func TestCompletingOnboarding(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(sam)
	complete := func(body string) response { return h.call("POST", "/v1/me/onboarding/complete", token, body) }
	terms := "2026-10-01"

	// The profile still carries its provisioning defaults.
	got := h.expect(complete(completeBody(memberBirthDate(), terms)), 422, "PROFILE_INCOMPLETE")
	if got.message != "Choose a name and username first." {
		t.Fatalf("message %q", got.message)
	}
	// Choosing only a username, or only a name, is still incomplete.
	update := func(version, patch string) response {
		return serve(t, h.handler, "PATCH", "/v1/me/profile", token, map[string]string{"If-Match": version}, patch)
	}
	h.expect(update(`"1"`, `{"username":"sam_k"}`), 200, "")
	h.expect(complete(completeBody(memberBirthDate(), terms)), 422, "PROFILE_INCOMPLETE")
	h.expect(update(`"2"`, `{"username":"member_0123456789ab"}`), 422, "VALIDATION")
	h.expect(update(`"2"`, `{"displayName":"Hiyall member"}`), 200, "")
	h.expect(complete(completeBody(memberBirthDate(), terms)), 422, "PROFILE_INCOMPLETE")
	h.expect(update(`"3"`, `{"displayName":"   "}`), 200, "")
	h.expect(complete(completeBody(memberBirthDate(), terms)), 422, "PROFILE_INCOMPLETE")
	h.expect(update(`"4"`, `{"displayName":"Sam"}`), 200, "")

	// Request validation comes first and never touches the account.
	for name, body := range map[string]string{
		"wrong terms":      completeBody(memberBirthDate(), "2025-01-01"),
		"old terms":        completeBody(memberBirthDate(), "legacy"),
		"future date":      completeBody(time.Now().UTC().AddDate(0, 0, 2).Format(time.DateOnly), terms),
		"before 1900":      completeBody("1899-12-31", terms),
		"impossible date":  completeBody("2001-02-29", terms),
		"slash date":       completeBody("12/04/1990", terms),
		"timestamp":        completeBody("1990-04-12T00:00:00Z", terms),
		"missing terms":    `{"birthDate":"1990-04-12"}`,
		"missing date":     `{"termsVersion":"2026-10-01"}`,
		"empty object":     `{}`,
		"extra field":      `{"birthDate":"1990-04-12","termsVersion":"2026-10-01","age":30}`,
		"numeric date":     `{"birthDate":19900412,"termsVersion":"2026-10-01"}`,
		"duplicate key":    `{"birthDate":"1990-04-12","birthDate":"1990-04-13","termsVersion":"2026-10-01"}`,
		"not an object":    `[]`,
		"trailing garbage": completeBody(memberBirthDate(), terms) + `{}`,
	} {
		if got := complete(body); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("%s: %d %q", name, got.status, got.code)
		}
	}
	// None of those changed anything, so a valid request now completes the account.
	if _, _, completed, _ := h.onboardingRow(sam); completed != nil {
		t.Fatal("a refused request completed the account")
	}
	h.expect(complete(completeBody("1990-04-12", terms)), 200, "")
}

func TestUnderageCompletionIsRefusedAndNothingIsStored(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(sam)
	h.finishProfile(token, "sam_k", "Sam")
	var outbox int
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM outbox_events`).Scan(&outbox)
	for _, birth := range []string{underageBirthDate(), time.Now().UTC().Format(time.DateOnly), turnsTomorrow(13)} {
		got := h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(birth, "2026-10-01")), 403, "AGE_REQUIREMENT_NOT_MET")
		if got.message != "Hiyall is for people 13 and over." {
			t.Fatalf("message %q", got.message)
		}
	}
	declared, accepted, completed, terms := h.onboardingRow(sam)
	if declared != nil || accepted != nil || completed != nil || terms != nil {
		t.Fatalf("a refused declaration left a trace: %v %v %v %v", declared, accepted, completed, terms)
	}
	var after int
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM outbox_events`).Scan(&after)
	var events int
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM outbox_events WHERE event_type='onboarding.completed'`).Scan(&events)
	if events != 0 || after != outbox {
		t.Fatalf("refused completion wrote events: %d new, %d completion", after-outbox, events)
	}
	h.expect(h.call("GET", "/v1/feed", token, ""), 403, "ONBOARDING_REQUIRED")
	// Age is the only thing checked: a date that makes the person 13 today for the same account then succeeds.
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(birthdayToday(13), "2026-10-01")), 200, "")
}

// 13 is the floor and nothing else about age is checked: someone who turns 13 today, a teenager and an
// adult all complete, and someone who turns 13 tomorrow does not.
func TestMinimumAgeBoundaryAndAnyOlderAgeIsAccepted(t *testing.T) {
	for _, tc := range []struct {
		name, birth string
		want        int
		code        string
	}{
		{"turns 13 tomorrow", turnsTomorrow(13), 403, "AGE_REQUIREMENT_NOT_MET"},
		{"turns 13 today", birthdayToday(13), 200, ""},
		{"turned 13 yesterday", time.Now().UTC().AddDate(-13, 0, -1).Format(time.DateOnly), 200, ""},
		{"seventeen", birthdayToday(17), 200, ""},
		{"eighteen", birthdayToday(18), 200, ""},
		{"adult", "1987-06-23", 200, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newOnboardingHarness(t)
			token := h.login(sam)
			h.finishProfile(token, "sam_k", "Sam")
			h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(tc.birth, "2026-10-01")), tc.want, tc.code)
		})
	}
}

func TestHappyPathCompletionUnlocksTheAppAndKeepsTheBirthDatePrivate(t *testing.T) {
	h := newOnboardingHarness(t)
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previous) })

	token := h.login(sam)
	h.expect(h.call("GET", "/v1/feed", token, ""), 403, "ONBOARDING_REQUIRED")
	h.finishProfile(token, "sam_k", "Sam")
	const birth = "1987-06-23"
	got := h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(birth, "2026-10-01")), 200, "").data
	if got["completed"] != true || got["termsVersion"] != "2026-10-01" || len(got) != 3 {
		t.Fatalf("completion body %v", got)
	}
	completedAt, ok := got["completedAt"].(string)
	if !ok {
		t.Fatalf("completedAt %v", got["completedAt"])
	}
	stamp, err := time.Parse(time.RFC3339Nano, completedAt)
	if err != nil || time.Since(stamp) > time.Minute || time.Until(stamp) > time.Minute {
		t.Fatalf("completedAt %q: %v", completedAt, err)
	}

	// The same token now reaches everything.
	h.expect(h.call("GET", "/v1/feed", token, ""), 200, "")
	h.expect(h.call("GET", "/v1/notifications/unread-count", token, ""), 200, "")
	state := h.expect(h.call("GET", "/v1/me/onboarding", token, ""), 200, "").data
	if state["completed"] != true || state["completedAt"] != completedAt {
		t.Fatalf("state %v", state)
	}
	declared, accepted, completed, terms := h.onboardingRow(sam)
	if declared == nil || accepted == nil || completed == nil || terms == nil || *terms != "2026-10-01" {
		t.Fatalf("row %v %v %v %v", declared, accepted, completed, terms)
	}
	// A new session for the same account is onboarded as well.
	h.expect(h.call("GET", "/v1/feed", h.login(sam), ""), 200, "")

	// Idempotent: a repeat answers the same body, changes nothing and writes nothing else.
	again := h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody("1990-01-02", "2026-10-01")), 200, "").data
	if again["completedAt"] != completedAt || again["completed"] != true || again["termsVersion"] != "2026-10-01" {
		t.Fatalf("repeat %v", again)
	}
	if _, _, second, _ := h.onboardingRow(sam); !second.Equal(*completed) {
		t.Fatal("completing twice moved completed_at")
	}
	var events int
	// No outbox rows are written any more (audit D5).
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM outbox_events WHERE event_type='onboarding.completed' AND aggregate_id=$1`, sam).Scan(&events); err != nil || events != 0 {
		t.Fatalf("%d completion events (%v), want none", events, err)
	}
	// Even a repeat has to be a well-formed request, and an under-13 date is still refused for a completed account.
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, `{}`), 422, "VALIDATION")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(underageBirthDate(), "2026-10-01")), 403, "AGE_REQUIREMENT_NOT_MET")

	// The first stored birth date is final: the repeat above, with another valid date, changed nothing.
	var stored string
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT birth_date::text FROM member_ages WHERE user_id=$1`, sam).Scan(&stored); err != nil || stored != birth {
		t.Fatalf("stored birth date %q (%v), want the first one, %s", stored, err, birth)
	}

	// The birth date is kept privately and nowhere else: in no table except member_ages, no event,
	// no response and no log line. The date sent in the repeat was ignored, so it exists nowhere.
	tables, err := h.db.Pool.Query(h.ctx, `SELECT tablename FROM pg_tables WHERE schemaname='public'`)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for tables.Next() {
		var name string
		if err = tables.Scan(&name); err != nil {
			t.Fatal(err)
		}
		names = append(names, name)
	}
	tables.Close()
	for _, name := range names {
		for _, date := range []string{birth, "1990-01-02"} {
			var hits int
			query := fmt.Sprintf(`SELECT count(*) FROM %s t WHERE t::text LIKE $1`, pgx.Identifier{name}.Sanitize())
			if err = h.db.Pool.QueryRow(h.ctx, query, "%"+date+"%").Scan(&hits); err != nil {
				t.Fatal(err)
			}
			want := 0
			if name == "member_ages" && date == birth {
				want = 1
			}
			if hits != want {
				t.Fatalf("%s found %d times in %s, want %d", date, hits, name, want)
			}
		}
	}
	if strings.Contains(logs.String(), birth) || strings.Contains(logs.String(), "1990-01-02") {
		t.Fatalf("a birth date was logged: %s", logs.String())
	}
	// No response says how old the member is: not the owner's own, not what others see.
	anjali := h.login(alice)
	// (Whole years of age are shown on another member's profile, the one route that may; see the age profile tests.)
	for _, call := range []struct {
		token, path string
		wholeYears  bool
	}{
		{token, "/v1/me/profile", false}, {token, "/v1/me/privacy", false}, {token, "/v1/me/onboarding", false}, {anjali, "/v1/users/" + sam + "/profile", true},
	} {
		raw := h.rawCall("GET", call.path, call.token)
		if leak := ageDisclosure(raw, call.wholeYears, birth, "1987"); leak != "" {
			t.Fatalf("%s shows %q: %s", call.path, leak, raw)
		}
	}
}

func TestUsernameAvailability(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(sam)
	check := func(name string) response {
		t.Helper()
		return h.call("GET", "/v1/usernames/"+name+"/availability", token, "")
	}
	available := func(name string, want bool) {
		t.Helper()
		got := h.expect(check(name), 200, "").data
		if len(got) != 1 || got["available"] != want {
			t.Fatalf("%s: %v, want available=%v", name, got, want)
		}
	}
	available("fresh_name", true)
	available("anjali", false)
	available("niko", false)
	available("member_0123456789ab", false)
	// Placeholder handles are never offered, even the caller's own.
	available("member_0000000000a1", false)
	for _, bad := range []string{"ab", "UPPER", "has-dash", strings.Repeat("a", 31), "caf%C3%A9"} {
		h.expect(check(bad), 422, "VALIDATION")
	}
	// A name is taken regardless of who holds it, and the caller's own name stays available.
	h.api.search.reset(sam)
	h.finishProfile(token, "sam_k", "Sam")
	h.expect(h.call("GET", "/v1/usernames/sam_k/availability", token, ""), 200, "")
	got := h.call("GET", "/v1/usernames/sam_k/availability", h.login(alice), "")
	if got.data["available"] != false {
		t.Fatalf("another account's name offered: %v", got.data)
	}
	got = h.call("GET", "/v1/usernames/sam_k/availability", token, "")
	if got.data["available"] != true {
		t.Fatalf("own name unavailable: %v", got.data)
	}
	// Anonymous callers learn nothing.
	h.expect(h.call("GET", "/v1/usernames/fresh_name/availability", "", ""), 401, "UNAUTHENTICATED")
}

func TestUsernameAvailabilityIsRateLimitedPerAccount(t *testing.T) {
	h := newOnboardingHarness(t)
	token, other := h.login(sam), h.login(alice)
	limited := 0
	for i := 0; i < 15; i++ {
		got := h.call("GET", "/v1/usernames/fresh_name/availability", token, "")
		switch got.status {
		case 200:
		case 429:
			limited++
			if got.code != "RATE_LIMITED" || got.header.Get("Retry-After") == "" {
				t.Fatalf("limit response %d %q %q", got.status, got.code, got.header.Get("Retry-After"))
			}
		default:
			t.Fatalf("status %d", got.status)
		}
	}
	if limited == 0 {
		t.Fatal("no rate limit applied")
	}
	// The budget is per account, so another person is unaffected.
	h.expect(h.call("GET", "/v1/usernames/fresh_name/availability", other, ""), 200, "")
}

func TestPlaceholderUsernameCannotBeClaimedThroughProfileEdits(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(sam)
	patch := func(version, body string) response {
		return serve(t, h.handler, "PATCH", "/v1/me/profile", token, map[string]string{"If-Match": version}, body)
	}
	h.expect(patch(`"1"`, `{"username":"member_0123456789ab"}`), 422, "VALIDATION")
	// Resending the current placeholder is not a claim.
	h.expect(patch(`"1"`, `{"username":"member_0000000000a1","displayName":"Sam"}`), 200, "")
	h.expect(patch(`"2"`, `{"username":"member_sam"}`), 200, "")
}

func TestPreflightForOnboardingRoutesAddsNoNewExposure(t *testing.T) {
	handler := New(nil, nil, true, "").Handler()
	for _, route := range [][2]string{{"POST", "/v1/me/onboarding/complete"}, {"GET", "/v1/me/onboarding"}, {"GET", "/v1/usernames/sam_k/availability"}} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodOptions, route[1], nil)
		req.Header.Set("Origin", "http://127.0.0.1:49321")
		req.Header.Set("Access-Control-Request-Method", route[0])
		req.Header.Set("Access-Control-Request-Headers", "authorization, content-type")
		handler.ServeHTTP(rec, req)
		allowed := strings.ToLower(rec.Header().Get("Access-Control-Allow-Headers"))
		if rec.Code != 204 || !strings.Contains(allowed, "authorization") || !strings.Contains(allowed, "content-type") || !strings.Contains(rec.Header().Get("Access-Control-Allow-Methods"), route[0]) {
			t.Fatalf("%s %s preflight: %d %v", route[0], route[1], rec.Code, rec.Header())
		}
		if expose := rec.Header().Get("Access-Control-Expose-Headers"); expose != "ETag, X-Request-Id" {
			t.Fatalf("exposed headers changed: %q", expose)
		}
	}
}

// The migration backfills a complete row for every existing account and starts later ones incomplete.
// It runs in a scratch schema inside a rolled-back transaction, so no real table is touched. 0015 predates the
// rename of adult_declared_at to age_declared_at (0016), so its own column name is used here.
func TestMigrationBackfillsExistingAccountsAsComplete(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0015_onboarding.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch`,
		`SET LOCAL search_path = migration_scratch`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY, status text NOT NULL DEFAULT 'active')`,
		`INSERT INTO users(user_id,status) VALUES ('019a4000-0000-7000-8000-000000000a01','active'),('019a4000-0000-7000-8000-000000000a02','suspended'),('019a4000-0000-7000-8000-000000000a03','deleted')`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("migration: %v", err)
	}
	var total, complete, legacy, declared int
	if err = tx.QueryRow(ctx, `SELECT count(*),count(completed_at),count(*) FILTER (WHERE terms_version='legacy'),count(adult_declared_at) FROM onboarding`).Scan(&total, &complete, &legacy, &declared); err != nil {
		t.Fatal(err)
	}
	if total != 3 || complete != 3 || legacy != 3 || declared != 0 {
		t.Fatalf("backfill: %d rows, %d complete, %d legacy, %d declarations", total, complete, legacy, declared)
	}
	// An account added afterwards has no implicit row and a new row starts incomplete.
	if _, err = tx.Exec(ctx, `INSERT INTO users(user_id) VALUES('019a4000-0000-7000-8000-000000000a04'); INSERT INTO onboarding(user_id) VALUES('019a4000-0000-7000-8000-000000000a04')`); err != nil {
		t.Fatal(err)
	}
	var open int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM onboarding WHERE completed_at IS NULL AND created_at IS NOT NULL`).Scan(&open); err != nil || open != 1 {
		t.Fatalf("%d incomplete new rows (%v)", open, err)
	}
	// One row per account, tied to users.
	if _, err = tx.Exec(ctx, `INSERT INTO onboarding(user_id) VALUES('019a4000-0000-7000-8000-000000000a04')`); err == nil {
		t.Fatal("a second onboarding row was accepted")
	}
	_ = tx.Rollback(ctx)
	var exists bool
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch.onboarding') IS NOT NULL`).Scan(&exists); err != nil || exists {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}

// ---- Firebase mode wired through the HTTP layer ----

type firebaseHarness struct {
	*onboardingHarness
	key *rsa.PrivateKey
}

const firebaseTestProject = "hiyall-test"
const firebaseTestOrigin = "https://app.example"

func newFirebaseHarness(t *testing.T) *firebaseHarness {
	t.Helper()
	ctx, db := connectTestDB(t)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	verifier := identity.NewFirebaseWithKeys(firebaseTestProject, &oidc.StaticKeySet{PublicKeys: []crypto.PublicKey{&key.PublicKey}}, db)
	api := New(db, verifier.Verify, false, firebaseTestOrigin)
	return &firebaseHarness{&onboardingHarness{t, ctx, db, api, api.Handler()}, key}
}

type idToken struct {
	sub, provider string
	verified      bool
	authTime      int64
	audience      string
}

func (f *firebaseHarness) token(c idToken) string {
	f.t.Helper()
	if c.audience == "" {
		c.audience = firebaseTestProject
	}
	if c.authTime == 0 {
		c.authTime = time.Now().Add(-time.Minute).Unix()
	}
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "kid": "k1", "typ": "JWT"})
	body, _ := json.Marshal(map[string]any{
		"iss": "https://securetoken.google.com/" + firebaseTestProject, "aud": c.audience, "sub": c.sub, "user_id": c.sub,
		"iat": time.Now().Unix(), "exp": time.Now().Add(time.Hour).Unix(), "auth_time": c.authTime,
		"email": c.sub + "@example.test", "email_verified": c.verified,
		"firebase": map[string]any{"sign_in_provider": c.provider},
	})
	raw := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(raw))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, digest[:])
	if err != nil {
		f.t.Fatal(err)
	}
	return raw + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func (f *firebaseHarness) accounts(subject string) (users, identities int) {
	f.t.Helper()
	if err := f.db.Pool.QueryRow(f.ctx, `SELECT count(*) FROM users`).Scan(&users); err != nil {
		f.t.Fatal(err)
	}
	if err := f.db.Pool.QueryRow(f.ctx, `SELECT count(*) FROM auth_identities WHERE subject=$1`, subject).Scan(&identities); err != nil {
		f.t.Fatal(err)
	}
	return
}

func TestFirebaseSignInProvisionsAnIncompleteAccountThatIsGated(t *testing.T) {
	f := newFirebaseHarness(t)
	authTime := time.Now().Add(-5 * time.Minute).Unix()
	token := f.token(idToken{sub: "google-uid-1", provider: "google.com", authTime: authTime})
	users, _ := f.accounts("google-uid-1")

	state := f.expect(f.call("GET", "/v1/me/onboarding", token, ""), 200, "").data
	if state["completed"] != false || state["completedAt"] != nil || state["termsVersion"] != "2026-10-01" {
		t.Fatalf("new account state %v", state)
	}
	after, identities := f.accounts("google-uid-1")
	if after != users+1 || identities != 1 {
		t.Fatalf("users %d→%d, identities %d", users, after, identities)
	}
	var username, name string
	var open bool
	err := f.db.Pool.QueryRow(f.ctx, `SELECT p.username,p.data->>'displayName',o.completed_at IS NULL AND o.terms_version IS NULL AND o.age_declared_at IS NULL
 FROM auth_identities a JOIN profiles p USING(user_id) JOIN onboarding o USING(user_id) WHERE a.issuer=$1 AND a.subject='google-uid-1'`, "https://securetoken.google.com/"+firebaseTestProject).Scan(&username, &name, &open)
	if err != nil || !open || !strings.HasPrefix(username, "member_") || len(username) != 19 || name != "Hiyall member" {
		t.Fatalf("provisioned %q %q open=%v (%v)", username, name, open, err)
	}

	// Locked out of everything except the allow-list.
	for _, route := range [][2]string{{"GET", "/v1/feed"}, {"POST", "/v1/discovery/search"}, {"GET", "/v1/notifications"}, {"GET", "/v1/spaces"}} {
		f.expect(f.call(route[0], route[1], token, "{}"), 403, "ONBOARDING_REQUIRED")
	}
	f.expect(f.call("GET", "/v1/me/profile", token, ""), 200, "")
	f.expect(f.call("GET", "/v1/me/privacy", token, ""), 200, "")
	f.expect(f.call("GET", "/v1/usernames/sam_k/availability", token, ""), 200, "")
	f.expect(f.call("POST", "/v1/me/onboarding/complete", token, completeBody(memberBirthDate(), "2026-10-01")), 422, "PROFILE_INCOMPLETE")

	f.finishProfile(token, "google_sam", "Sam")
	f.expect(f.call("POST", "/v1/me/onboarding/complete", token, completeBody(memberBirthDate(), "2026-10-01")), 200, "")
	f.expect(f.call("GET", "/v1/feed", token, ""), 200, "")
	// Discovery opens with onboarding: there is no eligibility row to wait for, and none is written.
	f.expect(f.call("POST", "/v1/discovery/search", token, "{}"), 200, "")
	var eligibility int
	if err = f.db.Pool.QueryRow(f.ctx, `SELECT count(*) FROM discovery_eligibility`).Scan(&eligibility); err != nil || eligibility != 0 {
		t.Fatalf("eligibility rows %d (%v)", eligibility, err)
	}

	// One session per sign-in: refreshes reuse it, a new sign-in makes another, and revocation sticks.
	sessions := func(tok string) int {
		t.Helper()
		return len(f.expect(f.call("GET", "/v1/auth/sessions", tok, ""), 200, "").data["items"].([]any))
	}
	if n := sessions(token); n != 1 {
		t.Fatalf("%d sessions after one sign-in", n)
	}
	refreshed := f.token(idToken{sub: "google-uid-1", provider: "google.com", authTime: authTime})
	if n := sessions(refreshed); n != 1 {
		t.Fatalf("%d sessions after a token refresh", n)
	}
	second := f.token(idToken{sub: "google-uid-1", provider: "google.com", authTime: authTime + 120})
	if n := sessions(second); n != 2 {
		t.Fatalf("%d sessions after signing in again", n)
	}
	f.expect(f.call("POST", "/v1/auth/logout", token, ""), 200, "")
	f.expect(f.call("GET", "/v1/me/profile", refreshed, ""), 401, "UNAUTHENTICATED")
	f.expect(f.call("GET", "/v1/me/profile", second, ""), 200, "")
}

func TestFirebaseUnverifiedPasswordIsRefusedWithoutProvisioning(t *testing.T) {
	f := newFirebaseHarness(t)
	users, _ := f.accounts("pw-uid-1")
	unverified := f.token(idToken{sub: "pw-uid-1", provider: "password", verified: false})
	cors := map[string]string{"Origin": firebaseTestOrigin}
	for _, path := range []string{"/v1/me/profile", "/v1/me/onboarding", "/v1/feed"} {
		got := serve(t, f.handler, "GET", path, unverified, cors, "")
		if got.status != 403 || got.code != "EMAIL_NOT_VERIFIED" || got.message != "Verify your email to continue." {
			t.Fatalf("%s: %d %q %q", path, got.status, got.code, got.message)
		}
		// The browser must be able to read the refusal.
		if got.header.Get("Access-Control-Allow-Origin") != firebaseTestOrigin {
			t.Fatalf("%s: refusal is hidden from the web client: %v", path, got.header)
		}
	}
	after, identities := f.accounts("pw-uid-1")
	if after != users || identities != 0 {
		t.Fatalf("an unverified sign-up provisioned an account: users %d→%d, identities %d", users, after, identities)
	}
	var sessions int
	if err := f.db.Pool.QueryRow(f.ctx, `SELECT count(*) FROM sessions WHERE issuer LIKE 'https://securetoken.google.com/%'`).Scan(&sessions); err != nil || sessions != 0 {
		t.Fatalf("%d sessions for an unverified account (%v)", sessions, err)
	}
	// The realtime route says the same thing.
	if f.api.RT == nil {
		f.api.RT = realtime.NewHub(realtime.NewLocalBus(), 2, 10)
	}
	got := serve(t, f.handler, "GET", "/v1/realtime", unverified, nil, "")
	if got.status != 403 || got.code != "EMAIL_NOT_VERIFIED" {
		t.Fatalf("realtime: %d %q", got.status, got.code)
	}

	// Once the address is verified the same person signs in and an account appears.
	verified := f.token(idToken{sub: "pw-uid-1", provider: "password", verified: true})
	f.expect(f.call("GET", "/v1/me/onboarding", verified, ""), 200, "")
	if after, identities = f.accounts("pw-uid-1"); after != users+1 || identities != 1 {
		t.Fatalf("users %d→%d, identities %d", users, after, identities)
	}

	// Social providers vouch for the address; anonymous and mismatched tokens are plain 401s.
	f.expect(f.call("GET", "/v1/me/onboarding", f.token(idToken{sub: "apple-uid", provider: "apple.com", verified: false}), ""), 200, "")
	for _, tc := range []idToken{
		{sub: "anon-uid", provider: "anonymous"},
		{sub: "custom-uid", provider: "custom"},
		{sub: "audience-uid", provider: "google.com", audience: "another-project"},
		{sub: "future-uid", provider: "google.com", authTime: time.Now().Add(time.Hour).Unix()},
	} {
		f.expect(f.call("GET", "/v1/me/onboarding", f.token(tc), ""), 401, "UNAUTHENTICATED")
		if _, ids := f.accounts(tc.sub); ids != 0 {
			t.Fatalf("%s token provisioned an account", tc.provider)
		}
	}
}
