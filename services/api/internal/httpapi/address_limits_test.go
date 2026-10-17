package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/time/rate"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/realtime"
	"hiyall/services/api/internal/store"
)

// Round-4 N-8 / N-9: behind carrier-grade NAT or a campus thousands of signed-in members share one address. The strict
// per-address bucket (50 a second) is for requests without a token and for tokens that fail verification; a request that
// carries a valid token is held to a generous per-address flood backstop (500 a second) and a separate instance budget
// (8000 a second), and is otherwise limited per account.

func limitsAPI(t *testing.T) (*API, http.Handler) {
	t.Helper()
	opsCaptureLogs(t)
	a := New(nil, func(_ context.Context, token string) (store.Principal, error) {
		if token == "good" {
			return store.Principal{UserID: "u-good", SessionID: "s-good", Onboarded: true}, nil
		}
		return store.Principal{}, domain.ErrUnauthorized
	}, false, "")
	return a, a.Handler()
}

// call sends one request from one address; "good" is a valid token, "bad" a refused one, "" none.
func call(h http.Handler, method, path, token, address string) int {
	req := httptest.NewRequest(method, path, strings.NewReader(""))
	req.RemoteAddr = address + ":5000"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code
}

const sharedAddress = "198.51.100.77" // a carrier's NAT: many members behind one address

func TestAuthenticatedTrafficIsNotChargedToTheStrictAddressBucket(t *testing.T) {
	a, h := limitsAPI(t)
	// 600 requests with a valid token in a burst: past the strict bucket's 100 and well inside the backstop's 1000.
	for i := 0; i < 600; i++ {
		if code := call(h, "GET", "/v1/nothing", "good", sharedAddress); code == 429 {
			t.Fatalf("request %d of signed-in members behind one address was rate limited", i)
		}
	}
	// The strict bucket is untouched: anonymous callers from the same address still get their whole burst.
	anonymous := 0
	for i := 0; i < 100; i++ {
		if call(h, "GET", "/v1/nothing", "", sharedAddress) == 401 {
			anonymous++
		}
	}
	if anonymous != 100 {
		t.Fatalf("anonymous requests answered 401: %d of 100 (the strict bucket was drained by signed-in traffic)", anonymous)
	}
	// And then it limits them, as before.
	if code := call(h, "GET", "/v1/nothing", "", sharedAddress); code != 429 {
		t.Fatalf("the 101st anonymous request: %d", code)
	}
	// While signed-in members from the same address are still served.
	if code := call(h, "GET", "/v1/nothing", "good", sharedAddress); code == 429 {
		t.Fatal("a signed-in member was refused because anonymous traffic from their address was")
	}
	_ = a
}

func TestAddressFloodBackstopAndAuthenticatedBudgetStillApply(t *testing.T) {
	a, h := limitsAPI(t)
	// The per-address backstop for tokens (500 a second, burst 1000 in production; small here).
	a.authClients = newKeyedLimiter(1, 3, 100)
	got := []int{}
	for i := 0; i < 5; i++ {
		got = append(got, call(h, "GET", "/v1/nothing", "good", "203.0.113.1"))
	}
	if got[0] == 429 || got[2] == 429 || got[3] != 429 || got[4] != 429 {
		t.Fatalf("the signed-in flood backstop: %v", got)
	}
	// Another address is not affected.
	if code := call(h, "GET", "/v1/nothing", "good", "203.0.113.2"); code == 429 {
		t.Fatal("the backstop is not per address")
	}
	// The authenticated instance budget is its own: exhausting it refuses tokens, not anonymous requests, and the other
	// way round.
	a2, h2 := limitsAPI(t)
	a2.authBudget = rate.NewLimiter(1, 2)
	codes := []int{}
	for i := 0; i < 4; i++ {
		codes = append(codes, call(h2, "GET", "/v1/nothing", "good", "203.0.113.3"))
	}
	if codes[0] == 429 || codes[1] == 429 || codes[2] != 429 {
		t.Fatalf("the authenticated instance budget: %v", codes)
	}
	if code := call(h2, "GET", "/v1/nothing", "", "203.0.113.4"); code != 401 {
		t.Fatalf("anonymous traffic was refused by the authenticated budget: %d", code)
	}
	a3, h3 := limitsAPI(t)
	a3.budget = rate.NewLimiter(1, 1)
	call(h3, "GET", "/v1/nothing", "", "203.0.113.5")
	if code := call(h3, "GET", "/v1/nothing", "", "203.0.113.6"); code != 429 {
		t.Fatalf("the anonymous instance budget: %d", code)
	}
	if code := call(h3, "GET", "/v1/nothing", "good", "203.0.113.7"); code == 429 {
		t.Fatal("a signed-in request was refused because anonymous traffic used up its own budget")
	}
}

func TestATokenThatFailsVerificationIsChargedToTheStrictLimits(t *testing.T) {
	a, h := limitsAPI(t)
	// Token guessing from one address is held to the anonymous per-address limit: the burst of 100 (each also costs the
	// token's own admission), then 429 instead of 401.
	refused, limited := 0, 0
	for i := 0; i < 160; i++ {
		switch call(h, "GET", "/v1/nothing", "bad", "192.0.2.50") {
		case 401:
			refused++
		case 429:
			limited++
		}
	}
	if refused < 90 || refused > 110 || limited == 0 {
		t.Fatalf("401s %d, 429s %d: failed tokens are not held to the strict per-address bucket", refused, limited)
	}
	// A valid token from that address is still served: the strict bucket is not what it is held to.
	if code := call(h, "GET", "/v1/nothing", "good", "192.0.2.50"); code == 429 {
		t.Fatal("a valid token was refused because the same address guessed tokens")
	}
	// The unauthenticated instance budget is charged by failed tokens, like anonymous requests.
	a.budget = rate.NewLimiter(1, 2)
	codes := []int{}
	for i := 0; i < 4; i++ {
		codes = append(codes, call(h, "GET", "/v1/nothing", "bad", "192.0.2."+string(rune('1'+i))+"0"))
	}
	if codes[0] != 401 || codes[1] != 401 || codes[2] != 429 {
		t.Fatalf("failed tokens and the instance budget: %v", codes)
	}
}

// /v1/realtime charges a failed verification like HTTP does.
func TestRealtimeChargesTheBudgetForAFailedVerification(t *testing.T) {
	a, h := limitsAPI(t)
	a.RT = realtime.NewHub(realtime.NewLocalBus(), 2, 100)
	a.budget = rate.NewLimiter(1, 2)
	codes := []int{}
	for i := 0; i < 4; i++ {
		codes = append(codes, call(h, "GET", "/v1/realtime", "bad", "192.0.2.90"))
	}
	if codes[0] != 401 || codes[1] != 401 || codes[2] != 429 || codes[3] != 429 {
		t.Fatalf("realtime with a failing token: %v (a flood of bad tokens must run into the budget)", codes)
	}
	// A valid token reaches the upgrade (400: this is not a WebSocket request) and is not charged to that budget.
	if code := call(h, "GET", "/v1/realtime", "good", "192.0.2.91"); code == 429 {
		t.Fatal("a valid token was refused by the unauthenticated budget")
	}
}

func TestNearbyAccountsPerAddressDefaultsTo500(t *testing.T) {
	a := New(nil, nil, false, "")
	if a.nearbyAccountsPerAddress() != 500 || domain.DefaultNearbyAccountsPerAddress != 500 {
		t.Fatalf("default %d", a.nearbyAccountsPerAddress())
	}
	a.SetNearbyAccountsPerAddress(900)
	if a.nearbyAccountsPerAddress() != 900 {
		t.Fatal("the setting is ignored")
	}
}
