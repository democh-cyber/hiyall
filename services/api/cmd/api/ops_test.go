package main

import (
	"bytes"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthcheckExitCodes(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) })
	srv := httptest.NewServer(mux)
	defer srv.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	t.Setenv("LISTEN_ADDR", "0.0.0.0:"+port) // the unspecified address is reached through loopback
	var out bytes.Buffer
	if code := healthcheck(nil, &out); code != 0 {
		t.Fatalf("liveness: %d %s", code, out.String())
	}
	if code := healthcheck([]string{"-ready"}, &out); code != 1 || !strings.Contains(out.String(), "503") {
		t.Fatalf("readiness 503 must fail the check: %d %s", code, out.String())
	}
	if code := healthcheck([]string{"-bogus"}, &out); code != 2 {
		t.Fatalf("bad flag: %d", code)
	}
	srv.Close()
	if code := healthcheck(nil, &out); code != 1 {
		t.Fatalf("a dead server must be unhealthy, got %d", code)
	}
}
