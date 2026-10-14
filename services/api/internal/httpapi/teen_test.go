package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// withCaps makes every member's entitlements the Free ones with changes, so a test can reach a daily cap
// without making hundreds of requests.
func (h *socialHarness) withCaps(change func(*domain.Entitlements)) {
	h.api.Entitlements = func(context.Context, string) domain.Entitlements {
		e := domain.Free()
		change(&e)
		return e
	}
}

// patchPrivacy sends PATCH /v1/me/privacy with the member's current version.
func (h *socialHarness) patchPrivacy(id, body string) (int, string) {
	h.t.Helper()
	p, err := h.db.GetPrivacy(h.ctx, id)
	if err != nil {
		h.t.Fatal(err)
	}
	r := httptest.NewRequest("PATCH", "/v1/me/privacy", bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("If-Match", `"`+p.Version+`"`)
	r.Header.Set("Authorization", "Bearer "+id)
	r.RemoteAddr = "127.0.0.1:50000"
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	var env struct {
		Error map[string]string `json:"error"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &env)
	return w.Code, env.Error["code"]
}

func (h *onboardingHarness) count(sql string, args ...any) int {
	h.t.Helper()
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, sql, args...).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

func (h *socialHarness) count(sql string, args ...any) int {
	h.t.Helper()
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, sql, args...).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

func TestNearbyIsOffByDefaultAndSwitchingItOffDeletesThePoint(t *testing.T) {
	h := newSocialHarness(t)
	state := h.ok(alice, "GET", "/v1/me/nearby")
	if state["visible"] != false || state["sharing"] != false || state["minor"] != false || state["updatedAt"] != nil {
		t.Fatalf("a new member's Nearby state is %v", state)
	}
	// Without the switch no location is accepted, and Nearby is closed to the caller (you must be in it to see it).
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.97, 77.59)), 409, "NEARBY_OFF")
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{}), 409, "NEARBY_OFF")
	if h.count(`SELECT count(*) FROM user_locations`) != 0 {
		t.Fatal("a point was stored for a member who is not in Nearby")
	}
	// The switch stores no location.
	on := h.ok(alice, "PUT", "/v1/me/nearby")
	if on["visible"] != true || on["sharing"] != false || h.count(`SELECT count(*) FROM user_locations`) != 0 {
		t.Fatalf("switching on: %v", on)
	}
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{}), 409, "LOCATION_NOT_SHARED")
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.97, 77.59)), 200, "")
	h.north(bob, 0.01)
	h.api.search.reset(alice)
	users, _ := h.nearbyOK(alice, map[string]any{})
	same(t, users, bob)
	// bob sees alice only because both are in Nearby.
	users, _ = h.nearbyOK(bob, map[string]any{})
	same(t, users, alice)
	// Switching off deletes the point at once and the member leaves everyone's results.
	h.api.locations.reset(alice)
	off := h.ok(alice, "DELETE", "/v1/me/nearby")
	if off["visible"] != false || off["sharing"] != false {
		t.Fatalf("switching off: %v", off)
	}
	if h.count(`SELECT count(*) FROM user_locations WHERE user_id=$1`, alice) != 0 {
		t.Fatal("the stored point survived switching off")
	}
	users, _ = h.nearbyOK(bob, map[string]any{})
	same(t, users)
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{}), 409, "NEARBY_OFF")
	// Idempotent.
	h.ok(alice, "DELETE", "/v1/me/nearby")
	h.expect(h.send(alice, "PATCH", "/v1/me/nearby", nil), 405, "METHOD_NOT_ALLOWED")
}

// A stored point of a member who is not visible is never listed, whatever put it there.
func TestHiddenMembersAreNeverListedEvenWithAStoredPoint(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.north(bob, 0.01)
	h.north(cara, 0.01)
	h.exec(`UPDATE nearby_prefs SET visible=false WHERE user_id=$1`, bob)
	users, _ := h.nearbyOK(alice, map[string]any{})
	same(t, users, cara)
}

func TestMinorsStartOffAndTheirStateSaysSo(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	st := h.ok(dev, "GET", "/v1/me/nearby")
	if st["visible"] != false || st["minor"] != true {
		t.Fatalf("a minor's Nearby state is %v", st)
	}
}

// The attack in the audit: move a spoofed centre around and shrink the radius until a member's cell shows.
func TestNearbyBinarySearchCannotResolveBelowTheBucket(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	// No radius under 5 km exists to shrink.
	for _, km := range []int{1, 2, 3, 4} {
		h.api.search.reset(alice)
		got, _, _ := h.nearbyList(alice, radius(km))
		h.expect(got, 422, "VALIDATION")
	}
	// A member 0.4, 1.9 and 4.8 km away all show as "within 5 km": the three cannot be told apart.
	for i, dLat := range []float64{0.0036, 0.017, 0.043} {
		h.north(bob, dLat)
		_, buckets := h.nearbyOK(alice, radius(5))
		if fmt.Sprint(buckets) != "[5]" {
			t.Fatalf("case %d: buckets %v", i, buckets)
		}
	}
	// And one just outside is absent from radius 5 and present at 10; the answer changes only at the bucket edge.
	h.north(bob, 0.06) // 6.7 km
	users, _ := h.nearbyOK(alice, radius(5))
	same(t, users)
	users, buckets := h.nearbyOK(alice, radius(10))
	same(t, users, bob)
	if fmt.Sprint(buckets) != "[10]" {
		t.Fatalf("buckets %v", buckets)
	}
	// Walking the spoofed centre needs location changes, and only 5 a day are accepted.
	h.visible(cara)
	h.fresh(cara)
	accepted := 0
	for i := 0; i < 8; i++ {
		h.api.locations.reset(cara)
		got := h.send(cara, "PUT", "/v1/me/location", putLocation(12.97+float64(i)*0.05, 77.59))
		if got.status == 200 {
			accepted++
			continue
		}
		h.expect(got, 429, "DAILY_LIMIT")
		break
	}
	if accepted != 5 {
		t.Fatalf("%d location changes accepted in a day, want 5", accepted)
	}
	// Writing the same cell again is not a change.
	h.api.locations.reset(cara)
	h.expect(h.send(cara, "PUT", "/v1/me/location", putLocation(12.97+4*0.05, 77.59)), 200, "")
}

func TestImplausibleLocationJumpsAreRefused(t *testing.T) {
	h := newSocialHarness(t)
	h.visible(alice)
	h.fresh(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.97, 77.59)), 200, "") // Bengaluru
	h.api.locations.reset(alice)
	got := h.send(alice, "PUT", "/v1/me/location", putLocation(28.61, 77.21)) // Delhi, 1,750 km in seconds
	h.expect(got, 422, "LOCATION_IMPLAUSIBLE")
	if h.storedPoint(alice) != "12.97,77.59" {
		t.Fatalf("a refused jump moved the point: %s", h.storedPoint(alice))
	}
	// A refused jump is not a change: the day's count did not move.
	if n := h.count(`SELECT n FROM member_daily_counts WHERE user_id=$1 AND kind='location_change'`, alice); n != 1 {
		t.Fatalf("change count %d", n)
	}
	// A few hours later the same trip is a flight.
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '3 hours' WHERE user_id=$1`, alice)
	h.api.locations.reset(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(28.61, 77.21)), 200, "")
}

func TestDailyOffsetIsStoredRotatesAndMovesTheStoredPoint(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`INSERT INTO nearby_prefs(user_id,visible) VALUES($1,true),($2,true)`, alice, dev)
	h.ageAt(dev, 15)
	read := func(id string) (day string, north, east float64) {
		t.Helper()
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT offset_day::text,offset_north_km,offset_east_km FROM nearby_prefs WHERE user_id=$1`, id).Scan(&day, &north, &east); err != nil {
			t.Fatal(err)
		}
		return
	}
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "")
	day, n1, e1 := read(alice)
	if day != time.Now().UTC().Format(time.DateOnly) || n1*n1+e1*e1 > 2.0*2.0+1e-9 {
		t.Fatalf("offset day %s, %v km north %v km east", day, n1, e1)
	}
	// The stored point is the rounded point of (true + offset): within the offset plus the grid of the true one.
	var lat, lon float64
	_ = h.db.Pool.QueryRow(h.ctx, `SELECT latitude,longitude FROM user_locations WHERE user_id=$1`, alice).Scan(&lat, &lon)
	if d := domain.HaversineKm(domain.Location{Latitude: 12.97, Longitude: 77.59}, domain.Location{Latitude: lat, Longitude: lon}); d > 2.0+1.6 {
		t.Fatalf("stored point is %v km from the rounded true point", d)
	}
	// The same day the offset is kept, so two writes agree.
	h.api.locations.reset(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "")
	if _, n2, e2 := read(alice); n2 != n1 || e2 != e1 {
		t.Fatal("the offset changed within the day")
	}
	// A new day gets a new offset.
	changed := false
	for i := 0; i < 5 && !changed; i++ {
		h.exec(`UPDATE nearby_prefs SET offset_day=offset_day-1 WHERE user_id=$1`, alice)
		h.api.locations.reset(alice)
		h.fresh(alice)
		h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "")
		day, n2, e2 := read(alice)
		if day != time.Now().UTC().Format(time.DateOnly) {
			t.Fatalf("offset day %s was not rotated to today", day)
		}
		changed = n2 != n1 || e2 != e1
	}
	if !changed {
		t.Fatal("the offset never changed across days")
	}
	// A minor's offset is larger and its point is on the coarse grid.
	h.expect(h.send(dev, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "")
	_, n, e := read(dev)
	if n*n+e*e > 5.0*5.0+1e-9 {
		t.Fatalf("a minor's offset is %v,%v", n, e)
	}
	if h.count(`SELECT count(*) FROM user_locations WHERE user_id=$1 AND abs(latitude*10-round(latitude*10))<1e-9 AND abs(longitude*10-round(longitude*10))<1e-9`, dev) != 1 {
		t.Fatal("a minor's point is off the 0.1 grid")
	}
}

func TestDailyCapsOnSearchPagesNearbyQueriesAndProfileViews(t *testing.T) {
	h := newSocialHarness(t)
	h.withCaps(func(e *domain.Entitlements) {
		e.SearchPagesPerDay, e.NearbyQueriesPerDay, e.ProfileViewsPerDay = 3, 2, 2
	})
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.north(bob, 0.01)
	retry := func(name string, send func() (int, string, string)) {
		t.Helper()
		status, code, header := send()
		if status != 429 || code != "DAILY_LIMIT" {
			t.Fatalf("%s: %d %q", name, status, code)
		}
		if header == "" || header == "0" {
			t.Fatalf("%s: no Retry-After", name)
		}
	}
	post := func(path string, body any) func() (int, string, string) {
		return func() (int, string, string) {
			h.api.search.reset(alice)
			raw, _ := json.Marshal(body)
			r := httptest.NewRequest("POST", path, bytes.NewReader(raw))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+alice)
			r.RemoteAddr = "127.0.0.1:50000"
			w := httptest.NewRecorder()
			h.api.Handler().ServeHTTP(w, r)
			var env struct {
				Error map[string]string `json:"error"`
			}
			_ = json.Unmarshal(w.Body.Bytes(), &env)
			return w.Code, env.Error["code"], w.Header().Get("Retry-After")
		}
	}
	for i := 0; i < 3; i++ {
		h.api.search.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/discovery/search", map[string]any{}), 200, "")
	}
	retry("fourth search page", post("/v1/discovery/search", map[string]any{}))
	for i := 0; i < 2; i++ {
		h.nearbyOK(alice, map[string]any{})
	}
	retry("third nearby query", post("/v1/discover/nearby", map[string]any{}))
	for i := 0; i < 2; i++ {
		h.ok(alice, "GET", "/v1/users/"+bob+"/profile")
	}
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/profile"), 429, "DAILY_LIMIT")
	// Your own profile is free, and a counter is per member and per day.
	h.ok(alice, "GET", "/v1/users/"+alice+"/profile")
	h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	h.exec(`UPDATE member_daily_counts SET day=day-1 WHERE user_id=$1`, alice)
	h.ok(alice, "GET", "/v1/users/"+bob+"/profile")
	if n := h.count(`SELECT count(*) FROM member_daily_counts WHERE day<(now() AT TIME ZONE 'UTC')::date`); n == 0 {
		t.Fatal("setup")
	}
	if purged, err := h.db.PurgeDailyCounts(h.ctx, 0, 100); err != nil || purged == 0 {
		t.Fatalf("purge %d %v", purged, err)
	}
}

func TestProfileVisitRowsAreWrittenOncePerViewerAndProfile(t *testing.T) {
	h := newSocialHarness(t)
	for i := 0; i < 5; i++ {
		h.ok(alice, "GET", "/v1/users/"+bob+"/profile")
	}
	if n := h.count(`SELECT count(*) FROM profile_visits WHERE profile_id=$1 AND visitor_id=$2`, bob, alice); n != 1 {
		t.Fatalf("%d visit rows", n)
	}
	if h.api.visitWrites.allow(alice + ">" + bob) {
		t.Fatal("a second visit write within the hour was allowed")
	}
	if !h.api.visitWrites.allow(alice + ">" + cara) {
		t.Fatal("the limiter is per viewer and profile")
	}
	if memoryOnly := memoryOnlyLimiters["visit_writes"]; !memoryOnly {
		t.Fatal("visit writes must stay in memory")
	}
}

func TestDailyCapsOnFollowsFriendRequestsCommentsSpacesAndEntries(t *testing.T) {
	h := newSocialHarness(t)
	h.withCaps(func(e *domain.Entitlements) {
		e.FollowsPerDay, e.FriendRequestsPerDay, e.CommentsPerDay, e.SpacesPerDay, e.SpaceEntriesPerDay = 2, 2, 2, 1, 2
	})
	h.api.graph.reset(alice)
	reset := func() { h.api.graph.reset(alice); h.api.content.reset(alice) }
	// Follows: the third new follow is refused, and an idempotent repeat costs nothing.
	for _, id := range []string{bob, cara} {
		reset()
		h.ok(alice, "POST", "/v1/users/"+id+"/follow")
	}
	reset()
	h.ok(alice, "POST", "/v1/users/"+cara+"/follow")
	reset()
	h.expect(h.call(alice, "POST", "/v1/users/"+dev+"/follow"), 429, "DAILY_LIMIT")
	// Unfollowing does not give it back.
	reset()
	h.ok(alice, "DELETE", "/v1/users/"+bob+"/follow")
	reset()
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/follow"), 429, "DAILY_LIMIT")

	// Friend requests: cancel and resend is two requests against the day, not a free loop.
	reqID := func(target string) string {
		reset()
		return h.expect(h.call(alice, "POST", "/v1/users/"+target+"/friend-requests"), 200, "").data["requestId"].(string)
	}
	first := reqID(eli)
	reset()
	h.ok(alice, "DELETE", "/v1/friend-requests/"+first)
	second := reqID(eli)
	reset()
	h.ok(alice, "DELETE", "/v1/friend-requests/"+second)
	reset()
	h.expect(h.call(alice, "POST", "/v1/users/"+eli+"/friend-requests"), 429, "DAILY_LIMIT")

	// Comments.
	h.policy(bob, "commentsFrom", "everyone")
	post := h.expect(h.send(bob, "POST", "/v1/posts", map[string]any{"body": "hello", "audience": "public", "mediaIds": []string{}}), 201, "").data["postId"].(string)
	for i := 0; i < 2; i++ {
		reset()
		h.expect(h.send(alice, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": fmt.Sprint("hi ", i)}), 201, "")
	}
	reset()
	h.expect(h.send(alice, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": "one more"}), 429, "DAILY_LIMIT")

	// Spaces and their entries.
	reset()
	space := h.expect(h.send(alice, "POST", "/v1/spaces", map[string]any{"kind": "community", "title": "Books", "visibility": "public", "capacity": 10}), 201, "").data["spaceId"].(string)
	reset()
	h.expect(h.send(alice, "POST", "/v1/spaces", map[string]any{"kind": "community", "title": "Films", "visibility": "public", "capacity": 10}), 429, "DAILY_LIMIT")
	for i := 0; i < 2; i++ {
		reset()
		h.expect(h.send(alice, "POST", "/v1/spaces/"+space+"/entries", map[string]any{"body": fmt.Sprint("entry ", i)}), 201, "")
	}
	reset()
	h.expect(h.send(alice, "POST", "/v1/spaces/"+space+"/entries", map[string]any{"body": "too many"}), 429, "DAILY_LIMIT")
	// A refused action wrote nothing.
	if n := h.count(`SELECT count(*) FROM space_entries WHERE author_id=$1`, alice); n != 2 {
		t.Fatalf("%d entries", n)
	}
	// The next UTC day starts the counters again.
	h.exec(`UPDATE member_daily_counts SET day=day-1 WHERE user_id=$1`, alice)
	reset()
	h.ok(alice, "POST", "/v1/users/"+dev+"/follow")
}

func TestFreeDailyCapsAreTheDocumentedNumbers(t *testing.T) {
	h := newSocialHarness(t)
	e := h.api.entitlementsFor(h.ctx, alice)
	if e.FollowsPerDay != 200 || e.FriendRequestsPerDay != 50 || e.CommentsPerDay != 300 || e.SpacesPerDay != 3 || e.SpaceEntriesPerDay != 100 {
		t.Fatalf("%+v", e)
	}
}

// A declined request cannot be asked again for 7 days, and cancelling does not reopen it.
func TestDeclineCooldownSurvivesCancelAndResend(t *testing.T) {
	h := newSocialHarness(t)
	id := h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/friend-requests"), 200, "").data["requestId"].(string)
	h.ok(bob, "POST", "/v1/friend-requests/"+id+"/decline")
	h.api.graph.reset(alice)
	got := h.call(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	h.expect(got, 429, "REQUEST_COOLDOWN")
	// The declined request cannot be cancelled into a fresh start.
	h.api.graph.reset(alice)
	if got = h.call(alice, "DELETE", "/v1/friend-requests/"+id); got.status != 404 {
		t.Fatalf("cancelling a declined request answered %d", got.status)
	}
	h.api.graph.reset(alice)
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/friend-requests"), 429, "REQUEST_COOLDOWN")
	// After the 7 days it can be asked again.
	h.exec(`UPDATE friendships SET responded_at=now()-interval '8 days' WHERE friendship_id=$1`, id)
	h.api.graph.reset(alice)
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/friend-requests"), 200, "")
}

func TestMinorPrivacyDefaultsAreLockedAndAdultsAreFree(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	h.ageAt(cara, 30)
	for _, body := range []string{
		`{"onlineAudience":"everyone"}`, `{"onlineAudience":"friends"}`, `{"locationAudience":"followers"}`,
		`{"fieldAudiences":{"location":"everyone"}}`, `{"fieldAudiences":{"connections":"followers"}}`, `{"fieldAudiences":{"connections":"everyone"}}`,
	} {
		if status, code := h.patchPrivacy(dev, body); status != 422 || code != "MINOR_SETTING_LOCKED" {
			t.Fatalf("minor %s: %d %q", body, status, code)
		}
		if status, code := h.patchPrivacy(cara, body); status != 200 {
			t.Fatalf("adult %s: %d %q", body, status, code)
		}
	}
	for _, body := range []string{`{"onlineAudience":"nobody"}`, `{"messagesFrom":"friends"}`, `{"fieldAudiences":{"connections":"nobody"}}`, `{"discoverable":false}`} {
		if status, code := h.patchPrivacy(dev, body); status != 200 {
			t.Fatalf("minor %s: %d %q", body, status, code)
		}
	}
	// Turning 18 unlocks it.
	h.ageAt(dev, 18)
	if status, code := h.patchPrivacy(dev, `{"onlineAudience":"everyone"}`); status != 200 {
		t.Fatalf("an adult now: %d %q", status, code)
	}
}

func TestAdultFiltersNeverNarrowMinorCandidatesWhenIsolationIsOff(t *testing.T) {
	h := newSocialHarnessWith(t, store.WithAgeBandIsolation(false))
	h.ageAt(cara, 30)
	h.ageAt(dev, 15)
	h.ageAt(eli, 40)
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{gender}','"woman"') WHERE user_id IN ($1,$2)`, dev, cara)
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{gender}','"man"') WHERE user_id=$1`, eli)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.ageAt(alice, 35)
	h.north(dev, 0.01)
	h.north(cara, 0.01)
	h.north(eli, 0.01)
	// dev is a minor: an age range of 28-32 or a gender of "man" does not remove them.
	s, n := h.both(alice, map[string]any{"ageMin": 28, "ageMax": 32})
	if !slicesContain(s, dev) || !slicesContain(n, dev) || !slicesContain(s, cara) || slicesContain(s, eli) || slicesContain(n, eli) {
		t.Fatalf("age filter: search %v nearby %v", s, n)
	}
	s, n = h.both(alice, map[string]any{"gender": "man"})
	if !slicesContain(s, dev) || !slicesContain(n, dev) || !slicesContain(s, eli) || slicesContain(s, cara) {
		t.Fatalf("gender filter: search %v nearby %v", s, n)
	}
}

func TestDisplayNameAndPostTextRules(t *testing.T) {
	h := newOnboardingHarness(t)
	token := h.login(alice)
	version := func() string {
		return h.expect(h.call("GET", "/v1/me/profile", token, ""), 200, "").data["version"].(string)
	}
	for _, name := range []string{"Ann\u202Ebob", "Ann\u200Bbob", "Ann\u2066bob", "Ann\u0085bob", "\uFEFFAnn", "Ann\uE000", "A\u0301\u0302\u0303\u0304\u0305\u0306\u0307nn"} {
		raw, _ := json.Marshal(map[string]string{"displayName": name})
		h.expect(h.patchProfile(token, version(), string(raw)), 422, "VALIDATION")
	}
	// NFC: the decomposed form is stored composed. A ZWJ family emoji is kept.
	got := h.expect(h.patchProfile(token, version(), `{"displayName":"Café 👨\u200D👩\u200D👧"}`), 200, "").data
	if got["displayName"] != "Café 👨\u200D👩\u200D👧" {
		t.Fatalf("stored %q", got["displayName"])
	}
	h.expect(h.call("POST", "/v1/posts", token, `{"body":"hi\u202Ethere","audience":"public","mediaIds":[]}`), 422, "VALIDATION")
	h.expect(h.call("POST", "/v1/posts", token, `{"body":"Café","audience":"public","mediaIds":[]}`), 201, "")
}

func TestAgeGateRecordsTheRefusalAndCoolsDownTheIdentity(t *testing.T) {
	h := newOnboardingHarness(t)
	h.mustExec(`DELETE FROM age_gate_refusals`)
	h.mustExec(`INSERT INTO auth_identities(issuer,subject,user_id) VALUES('test-issuer','age-gate-subject',$1) ON CONFLICT DO NOTHING`, sam)
	token := h.login(sam)
	young := time.Now().UTC().AddDate(-12, 0, -1).Format(time.DateOnly)
	adult := memberBirthDate()
	h.finishProfile(token, "sam_k", "Sam")
	// An adult date is accepted by the age step, and nothing is stored by it.
	h.expect(h.call("POST", "/v1/me/onboarding/age", token, `{"birthDate":"`+adult+`"}`), 200, "")
	if n := h.count(`SELECT count(*) FROM member_ages WHERE user_id=$1`, sam); n != 0 {
		t.Fatal("the age step stored a birth date")
	}
	// A date under 13 is refused and recorded against the identity, with no date in the table.
	h.expect(h.call("POST", "/v1/me/onboarding/age", token, `{"birthDate":"`+young+`"}`), 403, "AGE_REQUIREMENT_NOT_MET")
	var issuer, subject string
	var refusals int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT issuer,subject,refusals FROM age_gate_refusals`).Scan(&issuer, &subject, &refusals); err != nil || issuer != "test-issuer" || subject != "age-gate-subject" || refusals != 1 {
		t.Fatalf("refusal row %q %q %d (%v)", issuer, subject, refusals, err)
	}
	// Picking another date does not get past it: the identity is refused for 7 days, whatever the date.
	h.expect(h.call("POST", "/v1/me/onboarding/age", token, `{"birthDate":"`+adult+`"}`), 403, "AGE_GATE_COOLDOWN")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(adult, "2026-10-01")), 403, "AGE_GATE_COOLDOWN")
	if n := h.count(`SELECT count(*) FROM member_ages WHERE user_id=$1`, sam); n != 0 {
		t.Fatal("a refused identity got a birth date stored")
	}
	// The refusal is by identity, so it outlives the account row.
	h.mustExec(`DELETE FROM auth_identities WHERE subject='age-gate-subject'`)
	h.mustExec(`INSERT INTO auth_identities(issuer,subject,user_id) VALUES('test-issuer','age-gate-subject',$1)`, sam)
	h.expect(h.call("POST", "/v1/me/onboarding/age", token, `{"birthDate":"`+adult+`"}`), 403, "AGE_GATE_COOLDOWN")
	// After 7 days it is open again.
	h.mustExec(`UPDATE age_gate_refusals SET refused_at=now()-interval '8 days'`)
	h.expect(h.call("POST", "/v1/me/onboarding/age", token, `{"birthDate":"`+adult+`"}`), 200, "")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(adult, "2026-10-01")), 200, "")
	// Validation: only birthDate, a real date.
	for _, body := range []string{`{}`, `{"birthDate":"13/10/2013"}`, `{"birthDate":"2013-10-13","termsVersion":"2026-10-01"}`, `{"birthDate":"2999-01-01"}`} {
		h.expect(h.call("POST", "/v1/me/onboarding/age", token, body), 422, "VALIDATION")
	}
	if n, err := h.db.PurgeAgeRefusals(h.ctx, 24*time.Hour, 10); err != nil || n != 1 {
		t.Fatalf("purge %d %v", n, err)
	}
	_ = strings.TrimSpace
}

// The refusal on completion (not only on the age step) is recorded too.
func TestCompletionWithAnUnderageDateRecordsTheRefusal(t *testing.T) {
	h := newOnboardingHarness(t)
	h.mustExec(`DELETE FROM age_gate_refusals`)
	h.mustExec(`INSERT INTO auth_identities(issuer,subject,user_id) VALUES('test-issuer','age-gate-2',$1) ON CONFLICT DO NOTHING`, sam)
	token := h.login(sam)
	h.finishProfile(token, "sam_k", "Sam")
	young := time.Now().UTC().AddDate(-12, 0, -1).Format(time.DateOnly)
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(young, "2026-10-01")), 403, "AGE_REQUIREMENT_NOT_MET")
	if n := h.count(`SELECT count(*) FROM age_gate_refusals WHERE subject='age-gate-2'`); n != 1 {
		t.Fatalf("%d refusals recorded", n)
	}
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(memberBirthDate(), "2026-10-01")), 403, "AGE_GATE_COOLDOWN")
}
