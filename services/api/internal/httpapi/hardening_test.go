package httpapi

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// patch sends a PATCH with If-Match, which h.send does not set.
func (h *socialHarness) patch(actor, path, version, body string) reply {
	h.t.Helper()
	r := httptest.NewRequest("PATCH", path, strings.NewReader(body))
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
	return reply{w.Code, out.Data, out.Error["code"]}
}

// NUL (which PostgreSQL text and jsonb cannot store) and other control characters in any
// free-text field are a 422, never a 500; line breaks stay allowed where text may span lines.
func TestControlCharactersInTextAreRefused(t *testing.T) {
	h := newSocialHarness(t)
	h.place(cara, bengaluru.Latitude, bengaluru.Longitude)
	post := h.post(cara, "public", "hello")
	for _, bad := range []string{"a\u0000b", "a\u0007b", "\u001b[31m"} {
		raw, _ := json.Marshal(bad)
		value := string(raw)
		for _, field := range []string{"bio", "displayName", "headline", "quote", "currentVibe", "pronouns", "profession"} {
			h.expect(h.patch(cara, "/v1/me/profile", "1", `{"`+field+`":`+value+`}`), 422, "VALIDATION")
		}
		h.expect(h.patch(cara, "/v1/me/profile", "1", `{"interests":[`+value+`]}`), 422, "VALIDATION")
		for _, c := range []struct {
			method, path string
			body         map[string]any
		}{
			{"POST", "/v1/posts", map[string]any{"body": bad, "audience": "public"}},
			{"POST", "/v1/posts/" + post + "/comments", map[string]any{"body": bad}},
			{"POST", "/v1/stories", map[string]any{"body": bad, "audience": "public"}},
			{"POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": dev, "reasonCode": "spam", "description": bad}},
			{"POST", "/v1/discovery/search", map[string]any{"vibe": bad}},
			{"POST", "/v1/discovery/search", map[string]any{"interests": []string{bad}}},
			{"POST", "/v1/discover/nearby", map[string]any{"vibe": bad}},
			{"POST", "/v1/discover/nearby", map[string]any{"interests": []string{bad}}},
			{"POST", "/v1/spaces", map[string]any{"kind": "community", "title": bad, "visibility": "public", "capacity": 10}},
		} {
			h.api.content.reset(cara)
			h.api.search.reset(cara)
			h.api.reports.reset(cara)
			if got := h.send(cara, c.method, c.path, c.body); got.status != 422 || got.code != "VALIDATION" {
				t.Fatalf("%s %s with %q: %d %s", c.method, c.path, bad, got.status, got.code)
			}
		}
		device := newTestDevice(cara).registration()
		device["displayName"] = bad
		h.expect(h.send(cara, "POST", "/v1/devices", device), 422, "VALIDATION")
	}
	// Multi-line text is still fine.
	h.expect(h.patch(cara, "/v1/me/profile", "1", `{"bio":"line one\nline two\tend"}`), 200, "")
	h.api.content.reset(cara)
	h.expect(h.send(cara, "POST", "/v1/posts", map[string]any{"body": "one\r\ntwo", "audience": "public"}), 201, "")
	// A profile time zone must be a place: "Local" (the server's own zone) is refused, UTC is fine.
	h.expect(h.patch(cara, "/v1/me/profile", "2", `{"timezone":"Local"}`), 422, "VALIDATION")
	h.expect(h.patch(cara, "/v1/me/profile", "2", `{"timezone":"UTC"}`), 200, "")
}

// Text the database still refuses (SQLSTATE 22021 / 22P05) is the caller's input: 422, not 500.
// Any other failure is a 500 whose log line carries the cause and the route pattern, never the raw path.
func TestDatabaseTextErrorsAre422AndFailuresAreLogged(t *testing.T) {
	a := New(nil, nil, false, "")
	for _, code := range []string{"22021", "22P05"} {
		w := httptest.NewRecorder()
		a.error(w, httptest.NewRequest("POST", "/v1/posts", nil), &pgconn.PgError{Code: code, Message: "invalid byte sequence"})
		if w.Code != 422 || !strings.Contains(w.Body.String(), `"VALIDATION"`) {
			t.Fatalf("%s -> %d %s", code, w.Code, w.Body)
		}
	}
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	w := httptest.NewRecorder()
	a.error(w, httptest.NewRequest("GET", "/v1/feed", nil), &pgconn.PgError{Code: "XX000", Message: "boom in the planner"})
	if w.Code != 500 || !strings.Contains(logs.String(), "boom in the planner") || !strings.Contains(logs.String(), `"route":"/v1/feed"`) {
		t.Fatalf("500 log %d %s", w.Code, logs.String())
	}
}

// Every timestamp in a response is UTC with a Z suffix, even when the server's own zone is not
// UTC. The test re-runs itself with TZ=Asia/Kolkata, since the zone is read once at start.
func TestTimestampsAreUTCWhateverTheServerZone(t *testing.T) {
	if os.Getenv("HIYALL_TZ_CHILD") == "" {
		if os.Getenv("TEST_DATABASE_URL") == "" {
			t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
		}
		cmd := exec.Command(os.Args[0], "-test.run=^TestTimestampsAreUTCWhateverTheServerZone$", "-test.count=1", "-test.v")
		cmd.Env = append(os.Environ(), "TZ=Asia/Kolkata", "HIYALL_TZ_CHILD=1")
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), "--- PASS: TestTimestampsAreUTCWhateverTheServerZone") {
			t.Fatalf("run with TZ=Asia/Kolkata: %v\n%s", err, out)
		}
		return
	}
	if _, offset := time.Now().Zone(); offset != 19800 {
		t.Fatalf("child runs in offset %d, want Asia/Kolkata", offset)
	}
	h := newSocialHarness(t)
	if _, err := h.db.CreateDevSession(h.ctx, cara, "tz-token-0000000000001", "web"); err != nil {
		t.Fatal(err)
	}
	h.ok(dev, "POST", "/v1/users/"+cara+"/follow")
	h.post(cara, "public", "hello in UTC")
	h.register(cara)
	makeSpace(h, cara, "event", "public", 10, nil)
	h.expect(h.send(cara, "POST", "/v1/conversations", map[string]string{"userId": dev}), 200, "")
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": eli, "reasonCode": "spam"}), 201, "")
	stamp := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T`)
	var walk func(path string, v any)
	walk = func(path string, v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, e := range x {
				walk(path+"."+k, e)
			}
		case []any:
			for i, e := range x {
				walk(path+"["+strconv.Itoa(i)+"]", e)
			}
		case string:
			if stamp.MatchString(x) && !strings.HasSuffix(x, "Z") {
				t.Errorf("%s = %s is not UTC", path, x)
			}
		}
	}
	reads := []string{"/v1/auth/sessions", "/v1/me/profile", "/v1/me/privacy", "/v1/notifications", "/v1/feed", "/v1/spaces?kind=event", "/v1/conversations", "/v1/me/devices", "/v1/me/reports", "/v1/me/onboarding"}
	for _, path := range reads {
		status, _, raw := h.full(cara, "GET", path, "", "")
		var body any
		if status != 200 || json.Unmarshal(raw, &body) != nil {
			t.Fatalf("GET %s -> %d %s", path, status, raw)
		}
		walk(path, body)
	}
	// A time taken from the request is echoed in UTC too.
	status, _, raw := h.full(cara, "POST", "/v1/users/"+dev+"/mute", "application/json", `{"until":"`+time.Now().Add(time.Hour).In(time.FixedZone("IST", 19800)).Format(time.RFC3339)+`"}`)
	var body any
	if status != 200 || json.Unmarshal(raw, &body) != nil {
		t.Fatalf("mute %d %s", status, raw)
	}
	walk("mute", body)
	status, _, raw = h.full(cara, "GET", "/v1/me/muted", "", "")
	_ = json.Unmarshal(raw, &body)
	walk("muted", body)
}

// Retry-After says when a refusal lifts: the rest of a 7-day friend-request cooldown, the
// claimer's key budget, and spaces' write limit; never a flat hour.
func TestRetryAfterIsTheTimeLeft(t *testing.T) {
	h := newSocialHarness(t)
	h.ok(cara, "POST", "/v1/users/"+dev+"/friend-requests")
	request := items(h.ok(dev, "GET", "/v1/me/friend-requests"))[0]["requestId"].(string)
	h.ok(dev, "POST", "/v1/friend-requests/"+request+"/decline")
	h.exec(`UPDATE friendships SET responded_at=now()-interval '2 days' WHERE requested_by=$1`, cara)
	h.api.graph.reset(cara)
	status, header, raw := h.full(cara, "POST", "/v1/users/"+dev+"/friend-requests", "", "")
	left, _ := strconv.Atoi(header.Get("Retry-After"))
	if status != 429 || !strings.Contains(string(raw), "REQUEST_COOLDOWN") || left < 5*24*3600-60 || left > 5*24*3600 {
		t.Fatalf("cooldown %d Retry-After %q", status, header.Get("Retry-After"))
	}
	// The pair key budget lifts when the oldest claim of the hour ages out.
	d := h.register(alice)
	h.expect(h.send(alice, "POST", "/v1/devices/"+d.id+"/keys", map[string]any{"fallbackKey": d.oneTimeKey("fb")}), 200, "")
	h.exec(`INSERT INTO key_claims(claimer_id,device_id,one_time,claimed_at) SELECT $1,$2,false,now()-interval '50 minutes' FROM generate_series(1,10)`, bob, d.id)
	h.api.graph.reset(bob)
	status, header, _ = h.full(bob, "POST", "/v1/users/"+alice+"/devices/"+d.id+"/claim", "", "")
	left, _ = strconv.Atoi(header.Get("Retry-After"))
	if status != 429 || left < 590 || left > 601 {
		t.Fatalf("claims %d Retry-After %q", status, header.Get("Retry-After"))
	}
	// Spaces' write limit sends Retry-After like every other limit.
	for i := 0; ; i++ {
		status, header, _ = h.full(cara, "DELETE", "/v1/spaces/019a4000-0000-7000-8000-00000000beef/membership", "", "")
		if status == 429 {
			break
		}
		if i > 40 {
			t.Fatal("spaces write limit never reached")
		}
	}
	if header.Get("Retry-After") != "1" {
		t.Fatalf("spaces 429 Retry-After %q", header.Get("Retry-After"))
	}
}

// Refusals of /v1/realtime carry the request id and the standard headers like every other route.
func TestRealtimeRefusalsCarryRequestIDAndHeaders(t *testing.T) {
	h := newSocialHarness(t)
	server, _ := withRealtime(t, h)
	resp, err := http.Get(server.URL + "/v1/realtime")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body struct {
		Meta struct {
			RequestID string `json:"requestId"`
		} `json:"meta"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	id := resp.Header.Get("X-Request-Id")
	if resp.StatusCode != 401 || id == "" || body.Meta.RequestID != id || resp.Header.Get("Cache-Control") != "no-store" || resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("%d id %q body %q headers %v", resp.StatusCode, id, body.Meta.RequestID, resp.Header)
	}
	// The upgrade itself still works.
	if _, _, err := dial(t, server, cara); err != nil {
		t.Fatal(err)
	}
}
