package main

import (
	"bytes"
	"net"
	"testing"
)

func TestHealthcheckConnectsToTheConsoleAddress(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	var stderr bytes.Buffer
	if code := healthcheck(func(k string) string {
		if k == "ADMIN_ADDR" {
			return ln.Addr().String()
		}
		return ""
	}, &stderr); code != 0 {
		t.Fatalf("code %d, stderr %q", code, stderr.String())
	}
}

func TestHealthcheckFailsWhenNothingListens(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close() // now nothing listens there
	var stderr bytes.Buffer
	if code := healthcheck(func(k string) string {
		if k == "ADMIN_ADDR" {
			return addr
		}
		return ""
	}, &stderr); code != 1 {
		t.Fatalf("want exit 1, got %d", code)
	}
}

func TestHealthcheckRejectsAnInvalidAddress(t *testing.T) {
	var stderr bytes.Buffer
	if code := healthcheck(func(k string) string { return map[string]string{"ADMIN_ADDR": "nonsense"}[k] }, &stderr); code != 2 {
		t.Fatalf("want exit 2, got %d", code)
	}
}
