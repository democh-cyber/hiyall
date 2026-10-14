// Package clientip finds the address of the client behind a reverse proxy without trusting what the
// client itself claims.
//
// Forwarded headers are read only when the direct peer (the TCP connection) is a trusted proxy, listed in
// TRUSTED_PROXY_CIDRS. Then the address is, in order:
//
//  1. the single-address header the proxy sets and overwrites (CLIENT_IP_HEADER, for example
//     Fly-Client-IP or CF-Connecting-IP), when one is configured and holds a valid address;
//  2. otherwise the rightmost X-Forwarded-For hop that is not itself a trusted proxy. Every proxy appends
//     the address it received the connection from, so hops to the right of the first untrusted one were
//     written by our own proxies and hops to its left are whatever the client sent.
//
// A request whose peer is not trusted is keyed by the peer whatever headers it carries, so a client that
// reaches the server directly cannot pick its own rate-limit bucket.
package clientip

import (
	"errors"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// Resolver picks the client address for a request. The zero value (and nil) trusts nobody and always
// answers the direct peer.
type Resolver struct {
	trusted []netip.Prefix
	header  string
}

// New builds a resolver. header may be empty.
func New(trusted []netip.Prefix, header string) *Resolver {
	return &Resolver{trusted: append([]netip.Prefix(nil), trusted...), header: http.CanonicalHeaderKey(strings.TrimSpace(header))}
}

// ParseCIDRs reads a comma-separated list of CIDR blocks; a bare address is a single-host block.
// Empty items are ignored, so "" is an empty list.
func ParseCIDRs(list string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, item := range strings.Split(list, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if p, err := netip.ParsePrefix(item); err == nil {
			out = append(out, p.Masked())
			continue
		}
		a, err := netip.ParseAddr(item)
		if err != nil {
			return nil, errors.New("invalid CIDR or address: " + item)
		}
		a = a.Unmap()
		out = append(out, netip.PrefixFrom(a, a.BitLen()))
	}
	return out, nil
}

// Enabled reports whether any proxy is trusted, i.e. whether forwarded headers are ever read.
func (r *Resolver) Enabled() bool { return r != nil && len(r.trusted) > 0 }

// Header is the configured single-address header, or "".
func (r *Resolver) Header() string {
	if r == nil {
		return ""
	}
	return r.header
}

// Trusted reports whether addr belongs to a trusted proxy.
func (r *Resolver) Trusted(addr netip.Addr) bool {
	if r == nil || !addr.IsValid() {
		return false
	}
	addr = addr.Unmap()
	for _, p := range r.trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// ClientIP is the client's address as text (IPv4-mapped IPv6 unmapped). When the peer cannot be parsed
// (a test or a unix socket) the raw RemoteAddr is returned.
func (r *Resolver) ClientIP(req *http.Request) string {
	peer, ok := Peer(req)
	if !ok {
		return req.RemoteAddr
	}
	if !r.Trusted(peer) {
		return peer.String()
	}
	if r.header != "" {
		if a, ok := parseHop(req.Header.Get(r.header)); ok {
			return a.String()
		}
	}
	// Several X-Forwarded-For lines are one list, in order.
	hops := strings.Split(strings.Join(req.Header.Values("X-Forwarded-For"), ","), ",")
	last := peer
	for i := len(hops) - 1; i >= 0; i-- {
		a, ok := parseHop(hops[i])
		if !ok {
			// Garbage left of our own proxies: nothing further left can be believed either.
			break
		}
		if !r.Trusted(a) {
			return a.String()
		}
		last = a
	}
	// Every hop was one of ours (an internal caller), or the list was empty or broken: the leftmost
	// trusted address we could verify.
	return last.String()
}

// Peer is the direct TCP peer of req.
func Peer(req *http.Request) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		host = req.RemoteAddr
	}
	a, err := netip.ParseAddr(strings.Trim(host, "[]"))
	if err != nil {
		return netip.Addr{}, false
	}
	return a.Unmap(), true
}

// parseHop reads one forwarded address: a bare IPv4 or IPv6 address, or one with a port.
func parseHop(s string) (netip.Addr, bool) {
	s = strings.TrimSpace(s)
	if s == "" || len(s) > 64 {
		return netip.Addr{}, false
	}
	if a, err := netip.ParseAddr(s); err == nil {
		return a.Unmap(), true
	}
	if ap, err := netip.ParseAddrPort(s); err == nil {
		return ap.Addr().Unmap(), true
	}
	return netip.Addr{}, false
}
