package httpapi

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

	"golang.org/x/time/rate"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/ratelimit"
)

var (
	rateLimitRejections = metrics.NewCounter("hiyall_rate_limit_rejections_total", "Requests refused by a rate limiter.", "limiter")
	rateLimitErrors     = metrics.NewCounter("hiyall_rate_limit_backend_errors_total", "Shared rate limiter calls that failed; the request was let through.", "limiter")
)

// keyedLimiter is a per-key token bucket. By default it lives in this process's memory (see
// ratelimit.Memory, bounded, evicting the longest idle key), so N nodes multiply the limit by N; with
// RATE_LIMIT_BACKEND=postgres the user-keyed limiters share one bucket per key through the database
// (API.UseSharedRateLimits). The address limiter and the instance budget always stay in memory: they
// are backstops that must not cost a database write per request.
type keyedLimiter struct {
	name    string
	limit   rate.Limit
	burst   int
	backend ratelimit.Limiter
	// lastWarn throttles the log line for backend errors to one per half minute.
	lastWarn atomic.Int64
}

func newKeyedLimiter(limit rate.Limit, burst, max int) *keyedLimiter {
	return &keyedLimiter{name: "unnamed", limit: limit, burst: burst, backend: ratelimit.NewMemory(limit, burst, max)}
}

// take decides one request. A shared backend that cannot be reached lets the request through: the
// database being down fails the request anyway, and a limiter must not become the outage.
func (k *keyedLimiter) take(key string) ratelimit.Decision {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	d, err := k.backend.Allow(ctx, key)
	if err != nil {
		rateLimitErrors.Inc(k.name)
		if last, now := k.lastWarn.Load(), time.Now().Unix(); now >= last+30 && k.lastWarn.CompareAndSwap(last, now) {
			slog.Warn("rate limiter backend failed; letting requests through", "limiter", k.name, "reason", scrubURLs(err.Error()))
		}
		return ratelimit.Decision{Allowed: true}
	}
	if !d.Allowed {
		rateLimitRejections.Inc(k.name)
	}
	return d
}

func (k *keyedLimiter) allow(key string) bool { return k.take(key).Allowed }

func (k *keyedLimiter) reset(key string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = k.backend.Reset(ctx, key)
}

// limiters lists every keyed limiter by the name used for its metrics label and, with the shared
// backend, its bucket prefix. A limiter added to API but not listed here still works (in memory, label
// "unnamed"); add it here to have it counted and shared. Names are stored in the database: never
// rename one without accepting that its buckets restart full.
func (a *API) limiters() map[string]*keyedLimiter {
	return map[string]*keyedLimiter{
		"clients": a.clients, "auth_clients": a.authClients, "search": a.search, "graph": a.graph, "messages": a.messages, "aux_messages": a.auxMessages, "reports": a.reports,
		"uploads": a.uploads, "blob_slots": a.blobSlots, "blob_urls": a.blobURLs, "content": a.content,
		"lists": a.lists, "locations": a.locations, "first_chats": a.firstChats,
		"profile_edits": a.profileEdits, "media_complete": a.mediaComplete,
		"chat_devices": a.chatDevices, "chat_keys": a.chatKeys, "chat_inbox": a.chatInbox, "visit_writes": a.visitWrites,
	}
}

// nameLimiters labels the limiters for metrics; New calls it.
func (a *API) nameLimiters() {
	for name, l := range a.limiters() {
		if l != nil {
			l.name = name
		}
		rateLimitErrors.Preset(name) // an alert on the first failure after a restart needs the series to exist at zero
	}
}

// memoryOnlyLimiters stay per node whatever the backend. "clients" is the per-address flood guard,
// which would cost a database write for every request (the busiest path in the API) to defend the
// database; behind N nodes it is N times the limit, which is still a bound, and the proxy in front is
// where a real per-address limit belongs.
var memoryOnlyLimiters = map[string]bool{"clients": true, "auth_clients": true, "visit_writes": true}

// UseSharedRateLimits moves the per-account limiters (everything but memoryOnlyLimiters) to the
// database, so that N nodes enforce one limit. db is normally the Store's pool. Call it before serving
// (RATE_LIMIT_BACKEND=postgres); with the default, nothing changes.
func (a *API) UseSharedRateLimits(db ratelimit.DB) {
	for name, l := range a.limiters() {
		if l != nil && !memoryOnlyLimiters[name] {
			l.backend = ratelimit.NewPostgres(db, name, l.limit, l.burst)
		}
	}
}
