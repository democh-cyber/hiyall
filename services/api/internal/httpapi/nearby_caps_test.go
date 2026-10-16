package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/time/rate"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Round-3 audit API-3 / DB-2: the per-address limits key an IPv6 client on its /64, the Nearby address cap counts
// accounts, and the instance budget is spent by unauthenticated requests only.

func serveFrom(h http.Handler, remote, method, target, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.RemoteAddr = remote
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func errorCode(rec *httptest.ResponseRecorder) string {
	var body struct {
		Error map[string]string `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	return body.Error["code"]
}

func TestAddressLimiterKeysAnIPv6ClientOnItsSlash64(t *testing.T) {
	a := New(nil, opsUnauthenticated, false, "")
	h := a.Handler()
	limited := 0
	for i := 0; i < 160; i++ {
		// One customer rotating through its /64: every request is a new address.
		if serveFrom(h, fmt.Sprintf("[2001:db8:aaaa:1::%x]:5000", i+1), "GET", "/v1/me/profile", "", "").Code == 429 {
			limited++
		}
	}
	if limited < 40 {
		t.Fatalf("rotating through one /64 was limited %d times in 160 requests; the bucket is the address, not the /64", limited)
	}
	// Different /64s (different customers) each have their own bucket.
	for i := 0; i < 160; i++ {
		if rec := serveFrom(h, fmt.Sprintf("[2001:db8:bbbb:%x::1]:5000", i+1), "GET", "/v1/me/profile", "", ""); rec.Code == 429 {
			t.Fatalf("customer %d was limited by another customer's traffic", i)
		}
	}
	// IPv4 stays keyed by the address.
	for i := 0; i < 160; i++ {
		if rec := serveFrom(h, fmt.Sprintf("198.51.100.%d:5000", i%250+1), "GET", "/v1/me/profile", "", ""); rec.Code == 429 {
			t.Fatalf("an IPv4 client was limited at request %d", i)
		}
	}
}

func TestInstanceBudgetIsSpentByUnauthenticatedRequestsOnly(t *testing.T) {
	a := New(nil, func(_ context.Context, token string) (store.Principal, error) {
		if token == "good" {
			return store.Principal{UserID: "u", SessionID: "s", Onboarded: true}, nil
		}
		return store.Principal{}, domain.ErrUnauthorized
	}, false, "")
	h := a.Handler()
	// A bucket that never refills and is already spent: the real one refills 2,000 a second, which made the
	// assertions below depend on how fast the machine runs (the race detector slows requests enough to refill).
	a.budget = rate.NewLimiter(0, 1)
	a.budget.Allow()
	// Anonymous traffic is refused while the budget is spent ...
	if rec := serveFrom(h, "203.0.113.9:1", "GET", "/v1/nothing-here", "", ""); rec.Code != 429 {
		t.Fatalf("anonymous with the budget spent: %d, want 429", rec.Code)
	}
	// ... a token that does not verify is charged to it too ...
	if rec := serveFrom(h, "203.0.113.10:1", "GET", "/v1/nothing-here", "forged", ""); rec.Code != 429 {
		t.Fatalf("an unverifiable token with the budget spent: %d, want 429", rec.Code)
	}
	// ... and a signed-in member is not affected: the request reaches the router (an unknown path is 404).
	if rec := serveFrom(h, "203.0.113.11:1", "GET", "/v1/nothing-here", "good", ""); rec.Code == 429 || rec.Code == 401 {
		t.Fatalf("a signed-in member was refused with the budget spent: %d", rec.Code)
	}
}

// An account is counted once per address and day; the cap counts accounts, and an IPv6 /64 is one address.
func TestNearbyAddressCapCountsAccountsPerSlash64(t *testing.T) {
	h := newSocialHarness(t)
	h.withCaps(func(e *domain.Entitlements) { e.NearbyQueriesPerDay = 500 })
	h.exec(`DELETE FROM nearby_probe_centres`)
	h.api.SetNearbyAccountsPerAddress(2)
	t.Cleanup(func() { h.api.SetNearbyAccountsPerAddress(0) })
	for _, id := range []string{alice, bob, cara} {
		h.place(id, bengaluru.Latitude, bengaluru.Longitude)
	}
	search := func(actor, remote string, km int) reply {
		h.api.search.reset(actor)
		rec := serveFrom(h.api.Handler(), remote, "POST", "/v1/discover/nearby", actor, fmt.Sprintf(`{"radiusKm":%d}`, km))
		return reply{status: rec.Code, code: errorCode(rec)}
	}
	// Two accounts from two different addresses of one /64 use the allowance; a third is refused.
	h.expect(search(alice, "[2001:db8:7:7::1]:1", 5), 200, "")
	h.expect(search(bob, "[2001:db8:7:7:abcd::2]:1", 5), 200, "")
	h.expect(search(cara, "[2001:db8:7:7:ffff::3]:1", 5), 429, "DAILY_LIMIT")
	// An account already counted searches on, from any of the /64's addresses and with other radii.
	h.expect(search(alice, "[2001:db8:7:7::9]:1", 10), 200, "")
	// Another /64 and an IPv4 address have their own count.
	h.expect(search(cara, "[2001:db8:7:8::1]:1", 5), 200, "")
	h.expect(search(cara, "198.51.100.5:1", 5), 200, "")
}
