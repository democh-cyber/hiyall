package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

var wildcard = regexp.MustCompile(`\{[A-Za-z]+\}`)

// servedButNotDocumented are routes the router serves that the OpenAPI document leaves out on purpose: the
// WebSocket upgrade (documented in docs/api/04) and the probe aliases of /health/live and /health/ready.
var servedButNotDocumented = map[string]string{
	"GET /v1/realtime": "WebSocket upgrade, documented in docs/api/04-api-specification.md",
	"GET /healthz":     "alias of /health/live",
	"GET /readyz":      "alias of /health/ready",
}

func loadOpenAPI(t *testing.T) map[string]map[string]json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile("../../../../docs/api/openapi-foundation.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Paths map[string]map[string]json.RawMessage `json:"paths"`
	}
	if err = json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	return spec.Paths
}

// The route table and docs/api/openapi-foundation.json (built by scripts/build_foundation_contract.py) must
// describe the same routes: chat and realtime included. A route added, renamed or dropped on one side fails here.
func TestRoutesMatchOpenAPI(t *testing.T) {
	documented := map[string]bool{}
	for path, ops := range loadOpenAPI(t) {
		for method := range ops {
			documented[strings.ToUpper(method)+" "+wildcard.ReplaceAllString(path, "{}")] = true
		}
	}
	served := map[string]bool{}
	for _, row := range routes {
		if row.Method == "" {
			continue // the 405 answer for a path that already has rows
		}
		key := row.Method + " " + wildcard.ReplaceAllString(row.Pattern, "{}")
		if served[key] {
			t.Errorf("route %s is in the table twice", key)
		}
		served[key] = true
	}
	var problems []string
	for key := range served {
		if !documented[key] && servedButNotDocumented[key] == "" {
			problems = append(problems, "served but not in openapi-foundation.json (scripts/build_foundation_contract.py): "+key)
		}
	}
	for key := range documented {
		if !served[key] {
			problems = append(problems, "documented but not in the route table (router.go): "+key)
		}
	}
	for key := range servedButNotDocumented {
		if documented[key] {
			problems = append(problems, "now documented, drop it from servedButNotDocumented: "+key)
		}
		if !served[key] {
			problems = append(problems, "servedButNotDocumented names a route the table lacks: "+key)
		}
	}
	sort.Strings(problems)
	for _, p := range problems {
		t.Error(p)
	}
	if len(served) < 100 {
		t.Fatalf("only %d routes in the table", len(served))
	}
}

// Every row is servable: a handler for member routes, none for the ones served before authentication, a valid
// pattern for the ServeMux (building the router panics on a conflict), and every {...Id} wildcard named so the
// id check can find it.
func TestRouteTableIsWellFormed(t *testing.T) {
	for _, row := range routes {
		if (row.Handler == nil) != (row.Stage != stageMember) {
			t.Errorf("%s %s: a handler belongs exactly on member routes", row.Method, row.Pattern)
		}
		if row.Stage != stageMember && (row.Access != 0 || row.Limit != nil) {
			t.Errorf("%s %s: access and limits only apply to member routes", row.Method, row.Pattern)
		}
		for _, seg := range strings.Split(row.Pattern, "/") {
			if strings.HasPrefix(seg, "{") && !strings.HasSuffix(seg, "Id}") && seg != "{username}" {
				t.Errorf("%s: wildcard %s is neither an id (…Id) nor {username}", row.Pattern, seg)
			}
		}
	}
	newRouter(routes) // panics on a conflicting pattern
}

// The onboarding and deletion exemptions are read from the table. These are the lists the routes must keep.
func TestExemptionsFromTable(t *testing.T) {
	const id = "019a4000-0000-7000-8000-000000000002"
	onboarding := map[string]bool{
		"GET /v1/me/profile": true, "PATCH /v1/me/profile": true, "GET /v1/me/privacy": true, "PATCH /v1/me/privacy": true,
		"GET /v1/me/deletion": true, "POST /v1/me/deletion": true, "DELETE /v1/me/deletion": true,
		"GET /v1/me/onboarding": true, "POST /v1/me/onboarding/age": true, "POST /v1/me/onboarding/complete": true,
		"GET /v1/usernames/sam_k/availability": true,
		"POST /v1/auth/logout":                 true, "GET /v1/auth/sessions": true, "POST /v1/auth/sessions/revoke-others": true, "DELETE /v1/auth/sessions/" + id: true,
	}
	pending := map[string]bool{
		"GET /v1/me/deletion": true, "DELETE /v1/me/deletion": true,
		"POST /v1/auth/logout": true, "POST /v1/auth/sessions/revoke-others": true, "DELETE /v1/auth/sessions/" + id: true,
	}
	for _, row := range routes {
		if row.Stage != stageMember || row.Method == "" {
			continue
		}
		path := wildcard.ReplaceAllStringFunc(row.Pattern, func(w string) string {
			if w == "{username}" {
				return "sam_k"
			}
			return id
		})
		key := row.Method + " " + path
		if got := onboardingExempt(row.Method, path); got != onboarding[key] {
			t.Errorf("onboardingExempt(%s) = %v, want %v", key, got, onboarding[key])
		}
		if got := pendingDeletionAllowed(row.Method, path); got != pending[key] {
			t.Errorf("pendingDeletionAllowed(%s) = %v, want %v", key, got, pending[key])
		}
		delete(onboarding, key)
		delete(pending, key)
	}
	for key := range onboarding {
		t.Errorf("onboarding exemption %q names no route", key)
	}
	for key := range pending {
		t.Errorf("deletion exemption %q names no route", key)
	}
	// Paths that no row serves keep the exemptions they had: a 404, not a refusal that hides which paths exist.
	if !onboardingExempt("GET", "/v1/auth/unknown") || onboardingExempt("GET", "/v1/me/unknown") {
		t.Error("unmatched exemptions changed")
	}
	if onboardingExempt("HEAD", "/v1/me/profile") || onboardingExempt("PUT", "/v1/me/profile") {
		t.Error("only GET and PATCH of the profile are exempt")
	}
}

// Unknown paths and wrong methods answer 404 NOT_FOUND "Endpoint unavailable" for members; the two routes that
// always answered 405 still do; HEAD is not served as GET; the ServeMux never redirects.
func TestRouterAnswers(t *testing.T) {
	h := newSocialHarness(t)
	h.expect(h.call(alice, "GET", "/v1/nothing"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/me/profile"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "HEAD", "/v1/me/profile"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1/me/profile/"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1//me/profile"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/me/location"), 405, "METHOD_NOT_ALLOWED")
	h.expect(h.call(alice, "HEAD", "/v1/me/location"), 405, "METHOD_NOT_ALLOWED")
	h.expect(h.call(alice, "PATCH", "/v1/me/nearby"), 405, "METHOD_NOT_ALLOWED")
	h.expect(h.call(alice, "DELETE", "/v1/spaces"), 405, "METHOD_NOT_ALLOWED")
	// A malformed id is a 404 with the message of its family.
	for path, message := range map[string]string{
		"/v1/users/zzz/profile": badMember, "/v1/spaces/zzz": badSpace, "/v1/posts/zzz": "Endpoint unavailable",
		"/v1/spaces/" + bob + "/members/zzz": "Endpoint unavailable",
	} {
		w := h.rawEnvelope(alice, "GET", path)
		if w.status != 404 || w.message != message {
			t.Errorf("GET %s: %d %q, want 404 %q", path, w.status, w.message, message)
		}
	}
	w := h.rawEnvelope(alice, "DELETE", "/v1/auth/sessions/zzz")
	if w.status != 404 || w.message != badSession {
		t.Errorf("session: %d %q", w.status, w.message)
	}
}

type envelopeReply struct {
	status  int
	message string
}

func (h *socialHarness) rawEnvelope(actor, method, path string) envelopeReply {
	h.t.Helper()
	r := newTestRequest(method, path, actor)
	w := newRecorder()
	h.api.Handler().ServeHTTP(w, r)
	var body struct {
		Error map[string]string `json:"error"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	return envelopeReply{w.Code, body.Error["message"]}
}

func newTestRequest(method, path, token string) *http.Request {
	r := httptest.NewRequest(method, path, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = "127.0.0.1:50000"
	return r
}

func newRecorder() *httptest.ResponseRecorder { return httptest.NewRecorder() }
