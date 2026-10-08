package httpapi

import (
	"fmt"
	"testing"
	"time"

	"golang.org/x/time/rate"
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
	if len(k.entries) > 3 {
		t.Fatalf("table grew to %d entries", len(k.entries))
	}
	if !k.allow("legit") {
		t.Fatal("legitimate client locked out by a key flood")
	}
	k.reset("a")
	if !k.allow("a") {
		t.Fatal("reset did not restore the budget")
	}
}
