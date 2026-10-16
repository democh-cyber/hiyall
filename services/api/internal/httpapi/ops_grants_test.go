package httpapi

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// /readyz includes the grants check (round-3 audit DB-NEW-1): a database whose grants are behind the release turns
// readiness red once the gap has lasted a full check interval (a release runs grants.sql moments after the
// migrations, and a node must not drop out in between), the answer is cached for the interval, and a check that
// cannot be answered keeps the previous verdict.
func TestReadinessIncludesGrants(t *testing.T) {
	db := opsDB(t)
	a := New(db, opsUnauthenticated, false, "")
	h := a.Handler()
	var problems atomic.Value
	var fail atomic.Bool
	var calls atomic.Int32
	problems.Store([]string(nil))
	a.GrantsCheck = func(context.Context) ([]string, error) {
		calls.Add(1)
		if fail.Load() {
			return nil, errors.New("catalogue unavailable")
		}
		return problems.Load().([]string), nil
	}
	a.grants.ttl = 50 * time.Millisecond
	ready := func() int {
		a.ready = readyCache{} // the two second readiness cache is not what is tested
		return opsServe(h, "GET", "/readyz", "", "").Code
	}
	if c := ready(); c != 200 {
		t.Fatalf("complete grants: %d", c)
	}
	if ready(); calls.Load() != 1 {
		t.Fatalf("the grants check ran %d times within its interval, want 1", calls.Load())
	}
	// A gap: tolerated for one interval, then red.
	problems.Store([]string{"hiyall_api has no SELECT on: widgets"})
	time.Sleep(60 * time.Millisecond)
	if c := ready(); c != 200 {
		t.Fatalf("first sight of a gap must not drop the node yet: %d", c)
	}
	time.Sleep(60 * time.Millisecond)
	a.ready = readyCache{}
	rec := opsServe(h, "GET", "/readyz", "", "")
	if rec.Code != 503 || opsEnvelope(t, rec)["error"].(map[string]any)["code"] != "NOT_READY" {
		t.Fatalf("a gap that lasted an interval: %d %s", rec.Code, rec.Body.String())
	}
	if body := rec.Body.String(); strings.Contains(body, "widgets") {
		t.Fatalf("the probe must not name tables: %s", body)
	}
	// Liveness is not touched.
	if rec := opsServe(h, "GET", "/healthz", "", ""); rec.Code != 200 {
		t.Fatalf("liveness: %d", rec.Code)
	}
	// An unanswerable check keeps the verdict (still red), and the repaired database recovers.
	fail.Store(true)
	time.Sleep(60 * time.Millisecond)
	if c := ready(); c != 503 {
		t.Fatalf("a failed check flipped the verdict: %d", c)
	}
	fail.Store(false)
	problems.Store([]string(nil))
	time.Sleep(60 * time.Millisecond)
	if c := ready(); c != 200 {
		t.Fatalf("after grants.sql: %d", c)
	}
}
