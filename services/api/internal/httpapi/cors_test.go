package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The web client sends X-Client-Platform on every request and uses PUT for
// space membership, status and edits; a preflight that omits either blocks it.
func TestPreflightAllowsClientHeaderAndPut(t *testing.T) {
	h := New(nil, nil, true, "").Handler()
	req := httptest.NewRequest(http.MethodOptions, "/v1/spaces/x/membership", nil)
	req.Header.Set("Origin", "http://127.0.0.1:49321")
	req.Header.Set("Access-Control-Request-Method", "PUT")
	req.Header.Set("Access-Control-Request-Headers", "x-client-platform")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("preflight status = %d", rec.Code)
	}
	headers := strings.ToLower(rec.Header().Get("Access-Control-Allow-Headers"))
	if !strings.Contains(headers, "x-client-platform") {
		t.Fatalf("allowed headers = %q", headers)
	}
	methods := rec.Header().Get("Access-Control-Allow-Methods")
	if !strings.Contains(methods, "PUT") {
		t.Fatalf("allowed methods = %q", methods)
	}
}

func TestPreflightRejectsUnknownOrigin(t *testing.T) {
	h := New(nil, nil, true, "").Handler()
	req := httptest.NewRequest(http.MethodOptions, "/v1/me/profile", nil)
	req.Header.Set("Origin", "https://example.com")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("unknown origin status = %d", rec.Code)
	}
}
