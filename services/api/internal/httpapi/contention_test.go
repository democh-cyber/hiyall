package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"hiyall/services/api/internal/metrics"
)

// A lock timeout, a statement timeout or cancel, a deadlock and a serialization failure are the database asking
// to try again: 503 TEMPORARILY_UNAVAILABLE with Retry-After, counted, and not an error report. Anything else
// from the database is still a 500.
func TestDatabaseContentionAnswers503WithRetryAfter(t *testing.T) {
	a := &API{}
	for _, code := range []string{"55P03", "57014", "40P01", "40001"} {
		for _, authPath := range []bool{false, true} {
			w := httptest.NewRecorder()
			r := httptest.NewRequest("GET", "/v1/feed", nil)
			err := fmt.Errorf("feed: %w", &pgconn.PgError{Code: code, Message: "canceling statement"})
			if authPath {
				a.authFailure(w, r, err)
			} else {
				a.error(w, r, err)
			}
			var body struct {
				Error map[string]string `json:"error"`
			}
			_ = json.Unmarshal(w.Body.Bytes(), &body)
			if w.Code != 503 || body.Error["code"] != "TEMPORARILY_UNAVAILABLE" || w.Header().Get("Retry-After") != "1" {
				t.Errorf("%s (auth %v): %d %v retry-after %q", code, authPath, w.Code, body.Error, w.Header().Get("Retry-After"))
			}
			if strings.Contains(w.Body.String(), "canceling statement") {
				t.Errorf("%s: the database message reached the client: %s", code, w.Body.String())
			}
		}
	}
	var out bytes.Buffer
	if _, err := metrics.Default.WriteTo(&out); err != nil {
		t.Fatal(err)
	}
	for _, code := range []string{"55P03", "57014", "40P01", "40001"} {
		if !strings.Contains(out.String(), `hiyall_db_contention_total{code="`+code+`"}`) {
			t.Errorf("no hiyall_db_contention_total series for %s", code)
		}
	}
	// Other database errors stay 500.
	w := httptest.NewRecorder()
	a.error(w, httptest.NewRequest("GET", "/v1/feed", nil), &pgconn.PgError{Code: "XX000"})
	if w.Code != 500 || w.Header().Get("Retry-After") != "" {
		t.Errorf("internal error: %d retry-after %q", w.Code, w.Header().Get("Retry-After"))
	}
	w = httptest.NewRecorder()
	a.authFailure(w, httptest.NewRequest("GET", "/v1/feed", nil), errors.New("keys down"))
	if w.Code != 503 || w.Header().Get("Retry-After") != "" {
		t.Errorf("auth outage: %d retry-after %q", w.Code, w.Header().Get("Retry-After"))
	}
}
