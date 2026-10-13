package httpapi

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/ratelimit"
)

func TestKeyedLimiterIsolatesKeysAndNeverLocksOut(t *testing.T) {
	k := newKeyedLimiter(rate.Every(time.Hour), 2, 3)
	if !k.allow("a") || !k.allow("a") || k.allow("a") {
		t.Fatal("burst not enforced per key")
	}
	if !k.allow("b") {
		t.Fatal("one key exhausted another key's budget")
	}
	// Flooding with new keys evicts old entries instead of refusing everyone.
	for i := 0; i < 100; i++ {
		if !k.allow(fmt.Sprintf("flood-%d", i)) {
			t.Fatalf("new key %d refused when table was full", i)
		}
	}
	if n := k.backend.(*ratelimit.Memory).Len(); n > 3 {
		t.Fatalf("table grew to %d entries", n)
	}
	if !k.allow("legit") {
		t.Fatal("legitimate client locked out by a key flood")
	}
	k.reset("a")
	if !k.allow("a") {
		t.Fatal("reset did not restore the budget")
	}
}

type failingLimiter struct{}

func (failingLimiter) Allow(context.Context, string) (ratelimit.Decision, error) {
	return ratelimit.Decision{}, errors.New("database unavailable")
}
func (failingLimiter) Reset(context.Context, string) error { return errors.New("database unavailable") }

func TestKeyedLimiterFailsOpenAndCountsErrorsAndRejections(t *testing.T) {
	k := newKeyedLimiter(rate.Every(time.Hour), 1, 10)
	k.name = "unit_limiter"
	k.allow("a")
	if k.allow("a") {
		t.Fatal("not limited")
	}
	k.backend = failingLimiter{}
	if !k.allow("a") || !k.take("a").Allowed {
		t.Fatal("a failing shared backend must let requests through")
	}
	var sb strings.Builder
	metrics.Default.WriteTo(&sb)
	out := sb.String()
	if !strings.Contains(out, `hiyall_rate_limit_rejections_total{limiter="unit_limiter"} 1`) || !strings.Contains(out, `hiyall_rate_limit_backend_errors_total{limiter="unit_limiter"} 2`) {
		t.Fatalf("limiter metrics missing:\n%s", out)
	}
}
