package httpapi

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// keyedLimiter is a bounded per-key token bucket for one instance. When the table
// is full, idle keys are swept and then the least recently used key is evicted,
// so a flood of new keys can never lock out existing clients. A scaled deployment
// still needs distributed enforcement in front of this.
type keyedLimiter struct {
	mu      sync.Mutex
	limit   rate.Limit
	burst   int
	max     int
	entries map[string]*bucket
}

type bucket struct {
	limiter *rate.Limiter
	touched time.Time
}

func newKeyedLimiter(limit rate.Limit, burst, max int) *keyedLimiter {
	return &keyedLimiter{limit: limit, burst: burst, max: max, entries: map[string]*bucket{}}
}

func (k *keyedLimiter) allow(key string) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	now := time.Now()
	b := k.entries[key]
	if b == nil {
		if len(k.entries) >= k.max {
			k.evict(now)
		}
		b = &bucket{limiter: rate.NewLimiter(k.limit, k.burst)}
		k.entries[key] = b
	}
	b.touched = now
	return b.limiter.Allow()
}

func (k *keyedLimiter) evict(now time.Time) {
	oldest := ""
	for key, b := range k.entries {
		if now.Sub(b.touched) > 10*time.Minute {
			delete(k.entries, key)
		} else if oldest == "" || b.touched.Before(k.entries[oldest].touched) {
			oldest = key
		}
	}
	if len(k.entries) >= k.max && oldest != "" {
		delete(k.entries, oldest)
	}
}

func (k *keyedLimiter) reset(key string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.entries, key)
}
