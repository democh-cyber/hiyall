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
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"hiyall/services/api/internal/metrics"
)

// untrustedForwarding counts requests that carry a forwarding header (X-Forwarded-For, Forwarded, the
// configured CLIENT_IP_HEADER, or the well-known single-address headers) from a peer that is NOT a trusted
// proxy. Behind a real proxy with a wrong TRUSTED_PROXY_CIDRS this is every request: all clients then
// share the proxy's rate-limit bucket. A direct listener sees the odd client that sends the header itself.
var untrustedForwarding = metrics.NewCounter("hiyall_untrusted_forwarding_total", "Requests with a forwarding header from a peer that is not a trusted proxy (a wrong TRUSTED_PROXY_CIDRS looks like this).")

// WarnEvery is how often the untrusted-forwarding warning is logged: once a minute, however many requests.
const WarnEvery = time.Minute

// DebugRequests is how many requests DEBUG_LOG_PEER logs before it stops.
const DebugRequests = 20

// forwardingHeaders are looked for besides the configured header, to notice a proxy in front.
var forwardingHeaders = []string{"X-Forwarded-For", "Forwarded", "X-Real-Ip", "Fly-Client-Ip", "Cf-Connecting-Ip", "True-Client-Ip"}

// Resolver picks the client address for a request. The zero value (and nil) trusts nobody and always
// answers the direct peer.
type Resolver struct {
	trusted []netip.Prefix
	header  string
	diag    *diagnostics
}

// diagnostics is the state of the operator-facing log lines (shared by copies of a Resolver).
type diagnostics struct {
	debug     bool
	debugLeft atomic.Int32
	first     sync.Once
	lastWarn  atomic.Int64 // unix nanoseconds of the last warning
	now       func() time.Time
}

// New builds a resolver. header may be empty.
func New(trusted []netip.Prefix, header string) *Resolver {
	d := &diagnostics{now: time.Now}
	return &Resolver{trusted: append([]netip.Prefix(nil), trusted...), header: http.CanonicalHeaderKey(strings.TrimSpace(header)), diag: d}
}

// WithDebug turns DEBUG_LOG_PEER on: the peer and the forwarding headers of the first DebugRequests requests
// are logged, so an operator can read the proxy's address from the log and set TRUSTED_PROXY_CIDRS. It is a
// temporary aid, not a setting to leave on. It returns r.
func (r *Resolver) WithDebug(on bool) *Resolver {
	if r != nil && r.diag != nil {
		r.diag.debug = on
		r.diag.debugLeft.Store(DebugRequests)
	}
	return r
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
	client := r.resolve(req, peer)
	r.observe(req, peer, client)
	return client
}

func (r *Resolver) resolve(req *http.Request, peer netip.Addr) string {
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

// forwarded lists which forwarding headers the request carries (names only, never values).
func (r *Resolver) forwarded(req *http.Request) []string {
	var names []string
	seen := map[string]bool{}
	add := func(name string) {
		name = http.CanonicalHeaderKey(name)
		if name != "" && !seen[name] && len(req.Header.Values(name)) > 0 {
			seen[name] = true
			names = append(names, name)
		}
	}
	if r != nil {
		add(r.header)
	}
	for _, h := range forwardingHeaders {
		add(h)
	}
	return names
}

// observe writes the operator-facing diagnostics for one request: the first request after start (peer and
// resolved client), a warning at most once a minute when forwarding headers arrive from an untrusted peer,
// and, with DEBUG_LOG_PEER, the peer and forwarding header names and values of the first requests. Header
// values are only ever logged under DEBUG_LOG_PEER and are limited to the forwarding headers.
func (r *Resolver) observe(req *http.Request, peer netip.Addr, client string) {
	if r == nil || r.diag == nil {
		return
	}
	d := r.diag
	trusted := r.Trusted(peer)
	names := r.forwarded(req)
	d.first.Do(func() {
		slog.Info("client address: first request", "peer", peer.String(), "peerTrusted", trusted, "client", client, "forwardingHeaders", names,
			"hint", "if peerTrusted is false and forwardingHeaders is not empty, add the peer to TRUSTED_PROXY_CIDRS")
	})
	if !trusted && len(names) > 0 {
		untrustedForwarding.Inc()
		now := d.now().UnixNano()
		last := d.lastWarn.Load()
		if (last == 0 || now-last >= int64(WarnEvery)) && d.lastWarn.CompareAndSwap(last, now) {
			slog.Warn("forwarding header from a peer that is not a trusted proxy: the header is ignored and the peer is used as the client; behind a proxy this puts every client in one rate-limit bucket (set TRUSTED_PROXY_CIDRS to the proxy's addresses)",
				"peer", peer.String(), "forwardingHeaders", names)
		}
	}
	if d.debug && d.debugLeft.Add(-1) >= 0 {
		values := map[string][]string{}
		for _, n := range names {
			values[n] = req.Header.Values(n)
		}
		slog.Info("DEBUG_LOG_PEER", "peer", peer.String(), "peerTrusted", trusted, "client", client, "headers", values)
	}
}
