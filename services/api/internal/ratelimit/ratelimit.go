// Package ratelimit is the token-bucket limiter behind the API's per-account limits, with two
// interchangeable backends: Memory (per node, the default) and Postgres (shared by every node).
//
// Both implement the same semantics: a key starts with a full bucket of `burst` tokens, refills at
// `limit` tokens per second up to `burst`, and each request takes one token; a request that finds less
// than one token is refused without taking anything and told how long until one is available.
package ratelimit

import (
	"container/list"
	"context"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Decision is the outcome of one request.
type Decision struct {
	Allowed bool
	// RetryAfter is how long until a token is available; zero when Allowed.
	RetryAfter time.Duration
}

// Limiter decides requests per key. Implementations are safe for concurrent use.
type Limiter interface {
	Allow(ctx context.Context, key string) (Decision, error)
	// Reset gives the key a full bucket again (tests and administrative overrides).
	Reset(ctx context.Context, key string) error
}

// Memory is a bounded per-key token bucket for one process. When the table is full the least recently
// used key (the longest idle one) is evicted, so a flood of new keys can never lock out clients that
// are active.
type Memory struct {
	mu      sync.Mutex
	limit   rate.Limit
	burst   int
	max     int
	entries map[string]*bucket
	// lru holds buckets most recently used first, so eviction is O(1) instead of a scan of the table.
	lru *list.List
}

type bucket struct {
	key     string
	limiter *rate.Limiter
	touched time.Time
	elem    *list.Element
}

// NewMemory returns a limiter keeping at most max keys.
func NewMemory(limit rate.Limit, burst, max int) *Memory {
	return &Memory{limit: limit, burst: burst, max: max, entries: map[string]*bucket{}, lru: list.New()}
}

// Allow implements Limiter; it never fails.
func (m *Memory) Allow(_ context.Context, key string) (Decision, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	b := m.entries[key]
	if b == nil {
		for len(m.entries) >= m.max && m.max > 0 {
			m.evict()
		}
		b = &bucket{key: key, limiter: rate.NewLimiter(m.limit, m.burst)}
		b.elem = m.lru.PushFront(b)
		m.entries[key] = b
	} else {
		m.lru.MoveToFront(b.elem)
	}
	b.touched = now
	r := b.limiter.ReserveN(now, 1)
	if !r.OK() {
		return Decision{RetryAfter: time.Duration(float64(time.Second) / float64(m.limit))}, nil
	}
	if delay := r.DelayFrom(now); delay > 0 {
		r.CancelAt(now)
		return Decision{RetryAfter: delay}, nil
	}
	return Decision{Allowed: true}, nil
}

// evict removes the least recently used key, which is also the longest idle one.
func (m *Memory) evict() {
	back := m.lru.Back()
	if back == nil {
		return
	}
	b := back.Value.(*bucket)
	m.lru.Remove(back)
	delete(m.entries, b.key)
}

// Reset implements Limiter.
func (m *Memory) Reset(_ context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if b := m.entries[key]; b != nil {
		m.lru.Remove(b.elem)
		delete(m.entries, key)
	}
	return nil
}

// Len is the number of tracked keys.
func (m *Memory) Len() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.entries)
}
