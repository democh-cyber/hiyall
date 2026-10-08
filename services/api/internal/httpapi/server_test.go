package httpapi

import (
	"context"
	"errors"
	"kairova/services/api/internal/domain"
	"kairova/services/api/internal/store"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAuthenticationErrorsDoNotMaskOutagesAsExpiredSessions(t *testing.T) {
	for _, tc := range []struct {
		err    error
		status int
	}{{domain.ErrUnauthorized, 401}, {errors.New("database unavailable"), 503}} {
		api := New(nil, func(context.Context, string) (store.Principal, error) { return store.Principal{}, tc.err }, false, "")
		req := httptest.NewRequest("GET", "/v1/me/profile", nil)
		req.Header.Set("Authorization", "Bearer test-only")
		recorder := httptest.NewRecorder()
		api.Handler().ServeHTTP(recorder, req)
		if recorder.Code != tc.status {
			t.Fatalf("status %d, want %d", recorder.Code, tc.status)
		}
	}
}

func TestMalformedJSONIsAClientError(t *testing.T) {
	for _, body := range []string{`{1:2}`, `{"bio"`, `{"bio":"a"} {}`, `[]`, `{"bio":"a","bio":"b"}`} {
		r := httptest.NewRequest("PATCH", "/v1/me/profile", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		_, err := decode(httptest.NewRecorder(), r)
		var validation *domain.ValidationError
		if !errors.As(err, &validation) {
			t.Fatalf("%s: got %v, want a validation error", body, err)
		}
	}
}

func TestOneClientCannotExhaustAnotherClientsBudget(t *testing.T) {
	api := New(nil, func(context.Context, string) (store.Principal, error) {
		return store.Principal{}, domain.ErrUnauthorized
	}, false, "")
	handler := api.Handler()
	call := func(addr string) int {
		req := httptest.NewRequest("GET", "/v1/me/profile", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec.Code
	}
	limited := 0
	for i := 0; i < 300; i++ {
		if call("203.0.113.9:4000") == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("a single anonymous client was never limited")
	}
	if got := call("198.51.100.7:4000"); got != 401 {
		t.Fatalf("another client got %d after the flood, want 401", got)
	}
}
