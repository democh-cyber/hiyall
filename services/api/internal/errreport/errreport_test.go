package errreport

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime/debug"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/httpapi"
)

func TestParseDSN(t *testing.T) {
	d, err := ParseDSN("https://abc123@o1.ingest.example.io/4500")
	if err != nil || d.Key != "abc123" || d.Endpoint != "https://o1.ingest.example.io/api/4500/envelope/" {
		t.Fatalf("%+v %v", d, err)
	}
	d, err = ParseDSN("https://k@host.example/sentry/77")
	if err != nil || d.Endpoint != "https://host.example/sentry/api/77/envelope/" {
		t.Fatalf("%+v %v", d, err)
	}
	for _, bad := range []string{"", "nonsense", "ftp://k@h/1", "https://h/1", "https://k@h/", "https://k@h/abc"} {
		if _, err := ParseDSN(bad); err == nil {
			t.Fatalf("%q accepted", bad)
		} else if strings.Contains(err.Error(), bad) && bad != "" {
			t.Fatal("error echoes the DSN")
		}
	}
}

func TestScrubRemovesSecrets(t *testing.T) {
	in := "GET https://bucket.r2.example/photo.jpg?X-Amz-Signature=abcdef&X-Amz-Credential=k failed for ana@example.com " +
		"with Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln user 019a4000-0000-7000-8000-000000000001 " +
		"ERROR duplicate key value violates unique constraint: Key (email)=(ana@example.com) password=hunter2"
	out := Scrub(in)
	for _, leak := range []string{"X-Amz", "abcdef", "ana@example.com", "eyJ", "019a4000", "hunter2", "r2.example"} {
		if strings.Contains(out, leak) {
			t.Fatalf("%q leaked: %s", leak, out)
		}
	}
	if !strings.Contains(out, "[url]") || !strings.Contains(out, "(email)=([value])") {
		t.Fatal(out)
	}
	if long := Scrub(strings.Repeat("x", 1000)); len(long) > 310 {
		t.Fatalf("not cut: %d", len(long))
	}
}

func TestParseStackKeepsPositionsNotArguments(t *testing.T) {
	frames := ParseStack(debug.Stack())
	if len(frames) == 0 {
		t.Fatal("no frames")
	}
	found := false
	for _, f := range frames {
		if strings.HasSuffix(f.Function, "TestParseStackKeepsPositionsNotArguments") && strings.HasSuffix(f.Filename, "errreport_test.go") && f.Lineno > 0 {
			found = true
		}
		if strings.Contains(f.Function, "(") || strings.Contains(f.Filename, "+0x") {
			t.Fatalf("raw text kept: %+v", f)
		}
	}
	if !found {
		t.Fatalf("test frame missing: %+v", frames)
	}
	// Oldest first: the innermost call (this test) is last.
	if !strings.Contains(frames[len(frames)-1].Function, "ParseStack") && !strings.Contains(frames[len(frames)-1].Function, "Stack") {
		t.Logf("last frame %s", frames[len(frames)-1].Function)
	}
}

func TestReportSendsOnlyScrubbedFields(t *testing.T) {
	got := make(chan string, 1)
	auth := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got <- string(b)
		auth <- r.Header.Get("X-Sentry-Auth")
		w.WriteHeader(200)
	}))
	defer srv.Close()
	dsn := strings.Replace(srv.URL, "http://", "http://projkey@", 1) + "/42"
	r, err := New(Options{DSN: dsn, Environment: "production", Release: "abc", HTTPClient: srv.Client()})
	if err != nil {
		t.Fatal(err)
	}
	r.Report(context.Background(), httpapi.ErrorReport{
		RequestID: "req-1", Method: "POST", Route: "/v1/conversations/:id/messages",
		Err:   errors.New(`Post "https://x.example/p?sig=secret": dial failed for ana@example.com`),
		Stack: debug.Stack(),
	})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	r.Flush(ctx)
	body := <-got
	if !strings.Contains(<-auth, "sentry_key=projkey") {
		t.Fatal("auth header")
	}
	for _, leak := range []string{"secret", "ana@example.com", "x.example", "Authorization", "Cookie"} {
		if strings.Contains(body, leak) {
			t.Fatalf("%q leaked: %s", leak, body)
		}
	}
	for _, want := range []string{`"route":"/v1/conversations/:id/messages"`, `"request_id":"req-1"`, `"environment":"production"`, `"release":"abc"`, `"type":"event"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %s in %s", want, body)
		}
	}
	if strings.Contains(body, `"request":`) || strings.Contains(body, `"user":`) {
		t.Fatalf("request or user attached: %s", body)
	}
}

func TestReportNeverBlocksWhenTheQueueIsFull(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer srv.Close()
	r, err := New(Options{DSN: strings.Replace(srv.URL, "http://", "http://k@", 1) + "/1", Queue: 2, HTTPClient: &http.Client{Timeout: 5 * time.Second}})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			r.Report(context.Background(), httpapi.ErrorReport{Route: "/x", Panic: "boom"})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Report blocked")
	}
	if r.Dropped() == 0 {
		t.Fatal("expected drops")
	}
	close(release)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	r.Flush(ctx)
}

func TestPanicIsFatalAndTransportFailureIsQuiet(t *testing.T) {
	r, err := New(Options{DSN: "http://k@127.0.0.1:1/1", HTTPClient: &http.Client{Timeout: 200 * time.Millisecond}})
	if err != nil {
		t.Fatal(err)
	}
	body, _ := r.envelope(httpapi.ErrorReport{Panic: "index out of range"}, time.Now())
	if !strings.Contains(string(body), `"level":"fatal"`) {
		t.Fatal(string(body))
	}
	r.Report(context.Background(), httpapi.ErrorReport{Panic: "x"})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	r.Flush(ctx)
}
