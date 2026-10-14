package clientip

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func request(peer string, headers map[string][]string) *http.Request {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = peer
	for k, values := range headers {
		for _, v := range values {
			r.Header.Add(k, v)
		}
	}
	return r
}

func TestParseCIDRs(t *testing.T) {
	got, err := ParseCIDRs(" 10.0.0.0/8, 172.16.0.0/12 ,fdaa::/16,203.0.113.7,,")
	if err != nil || len(got) != 4 || got[3].String() != "203.0.113.7/32" {
		t.Fatalf("%v %v", got, err)
	}
	if got, err := ParseCIDRs(""); err != nil || len(got) != 0 {
		t.Fatalf("empty: %v %v", got, err)
	}
	for _, bad := range []string{"10.0.0.0/33", "nonsense", "10.0.0.0/8;1.2.3.4"} {
		if _, err := ParseCIDRs(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}

func TestUntrustedPeersAreNeverBelieved(t *testing.T) {
	trusted, _ := ParseCIDRs("10.0.0.0/8")
	for name, r := range map[string]*Resolver{"nil": nil, "nobody trusted": New(nil, "Fly-Client-IP"), "proxy configured": New(trusted, "Fly-Client-IP")} {
		// A client connecting directly and lying in every header keeps its own address.
		req := request("198.51.100.20:4000", map[string][]string{"X-Forwarded-For": {"1.1.1.1, 10.0.0.9"}, "Fly-Client-Ip": {"8.8.8.8"}})
		if got := r.ClientIP(req); got != "198.51.100.20" {
			t.Fatalf("%s: spoofed headers from an untrusted peer gave %q", name, got)
		}
	}
}

func TestRightmostUntrustedHop(t *testing.T) {
	trusted, _ := ParseCIDRs("10.0.0.0/8, fdaa::/16")
	r := New(trusted, "")
	cases := []struct {
		name, peer string
		xff        []string
		want       string
	}{
		{"one proxy", "10.0.0.2:1", []string{"203.0.113.5"}, "203.0.113.5"},
		// The client prepended a fake address; the proxy appended the real one.
		{"client spoofs left", "10.0.0.2:1", []string{"1.2.3.4, 203.0.113.5"}, "203.0.113.5"},
		{"two of our proxies", "10.0.0.2:1", []string{"9.9.9.9, 203.0.113.5, 10.0.0.3"}, "203.0.113.5"},
		{"split header lines", "10.0.0.2:1", []string{"9.9.9.9", "203.0.113.5, 10.0.0.3"}, "203.0.113.5"},
		{"ipv6 peer and hop", "[fdaa::1]:1", []string{"2001:db8::7"}, "2001:db8::7"},
		{"mapped v4", "[::ffff:10.0.0.2]:1", []string{"::ffff:203.0.113.5"}, "203.0.113.5"},
		{"hop with port", "10.0.0.2:1", []string{"203.0.113.5:5555"}, "203.0.113.5"},
		{"no header", "10.0.0.2:1", nil, "10.0.0.2"},
		{"garbage only", "10.0.0.2:1", []string{"not-an-ip"}, "10.0.0.2"},
		{"garbage left of real", "10.0.0.2:1", []string{"not-an-ip, 203.0.113.5"}, "203.0.113.5"},
		{"all internal", "10.0.0.2:1", []string{"10.1.1.1, 10.0.0.3"}, "10.1.1.1"},
	}
	for _, c := range cases {
		if got := r.ClientIP(request(c.peer, map[string][]string{"X-Forwarded-For": c.xff})); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestClientIPHeaderFromTrustedPeer(t *testing.T) {
	trusted, _ := ParseCIDRs("172.16.0.0/12")
	r := New(trusted, "fly-client-ip")
	if r.Header() != "Fly-Client-Ip" {
		t.Fatalf("header %q", r.Header())
	}
	req := request("172.16.5.5:1", map[string][]string{"Fly-Client-IP": {"203.0.113.9"}, "X-Forwarded-For": {"1.2.3.4"}})
	if got := r.ClientIP(req); got != "203.0.113.9" {
		t.Fatalf("got %q", got)
	}
	// An invalid header value falls back to X-Forwarded-For.
	req = request("172.16.5.5:1", map[string][]string{"Fly-Client-IP": {"bogus"}, "X-Forwarded-For": {"203.0.113.10"}})
	if got := r.ClientIP(req); got != "203.0.113.10" {
		t.Fatalf("fallback got %q", got)
	}
	if !r.Enabled() || New(nil, "").Enabled() {
		t.Fatal("Enabled")
	}
}

func TestUnparsablePeer(t *testing.T) {
	req := request("@", nil)
	if got := New(nil, "").ClientIP(req); got != "@" {
		t.Fatalf("got %q", got)
	}
}
