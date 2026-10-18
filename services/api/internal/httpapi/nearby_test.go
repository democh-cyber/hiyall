package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// bengaluru is the usual centre; 0.01 degrees of latitude is about 1.11 km.
var bengaluru = domain.RoundLocation(12.9716, 77.5946) // stored as 12.97, 77.59

// place stores a point for a member directly, already rounded, as fresh as now.
func (h *socialHarness) place(id string, lat, lon float64) {
	h.t.Helper()
	loc := domain.RoundLocation(lat, lon)
	h.visible(id)
	h.exec(`INSERT INTO user_locations(user_id,latitude,longitude,updated_at) VALUES($1,$2,$3,now()) ON CONFLICT(user_id) DO UPDATE SET latitude=excluded.latitude,longitude=excluded.longitude,updated_at=now()`, id, loc.Latitude, loc.Longitude)
}

// visible turns "Show me in Nearby" on for a member directly, as migration 0034 leaves an adult who shared.
func (h *socialHarness) visible(id string) {
	h.t.Helper()
	// Today's offset is fixed at zero so stored points are exactly the rounded ones; TestDailyOffset... covers the offset.
	h.exec(`INSERT INTO nearby_prefs(user_id,visible,offset_day,offset_north_km,offset_east_km) VALUES($1,true,(now() AT TIME ZONE 'UTC')::date,0,0)
 ON CONFLICT(user_id) DO UPDATE SET visible=true,offset_day=excluded.offset_day,offset_north_km=0,offset_east_km=0`, id)
}

// fresh forgets a member's stored point and today's location-change count, so a test can write any sequence
// of points without meeting the change cap or the speed check (their own tests do).
func (h *socialHarness) fresh(id string) {
	h.t.Helper()
	h.api.locations.reset(id)
	h.exec(`DELETE FROM user_locations WHERE user_id=$1`, id)
	h.exec(`DELETE FROM member_daily_counts WHERE user_id=$1 AND kind='location_change'`, id)
}

// north places a member dLat degrees of latitude north of the centre.
func (h *socialHarness) north(id string, dLat float64) {
	h.t.Helper()
	h.place(id, bengaluru.Latitude+dLat, bengaluru.Longitude)
}

// full performs a request and keeps the raw body and headers.
func (h *socialHarness) full(actor, method, path, contentType, body string) (int, http.Header, []byte) {
	h.t.Helper()
	r := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	r.RemoteAddr = "127.0.0.1:50000"
	r.Header.Set("Authorization", "Bearer "+actor)
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	return w.Code, w.Header(), w.Body.Bytes()
}

// nearbyList reads one page with a POST body, resetting the read limiter first so a test can page freely.
func (h *socialHarness) nearbyList(actor string, body any) (reply, []string, []int) {
	h.t.Helper()
	h.api.search.reset(actor)
	h.api.clients.reset("127.0.0.1") // the per-address limit is not what these paging tests are about
	got := h.send(actor, "POST", "/v1/discover/nearby", body)
	var users []string
	var buckets []int
	if got.status == 200 {
		for _, item := range items(got.data) {
			users = append(users, item["userId"].(string))
			buckets = append(buckets, int(item["distanceKm"].(float64)))
		}
	}
	return got, users, buckets
}

func (h *socialHarness) nearbyOK(actor string, body any) ([]string, []int) {
	h.t.Helper()
	got, users, buckets := h.nearbyList(actor, body)
	h.expect(got, 200, "")
	return users, buckets
}

// radius is the smallest Nearby body.
func radius(km int) map[string]any { return map[string]any{"radiusKm": km} }

func putLocation(lat, lon any) map[string]any {
	return map[string]any{"latitude": lat, "longitude": lon}
}

func TestNearbyOrderingBucketsRadiusAndItemShape(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	// Distances north of the caller: 0, 2.2, 5.6, 11.1, 33.4 and 89.0 km, plus one beyond every radius.
	h.north(bob, 0)
	h.north(cara, 0.02)
	h.north(dev, 0.05)
	h.north(eli, 0.10)
	h.north(xan, 0.30)
	h.north(yui, 0.80)

	users, buckets := h.nearbyOK(alice, map[string]any{})
	same(t, users, bob, cara, dev, eli) // default radius 25 km
	if fmt.Sprint(buckets) != "[5 5 10 15]" {
		t.Fatalf("buckets %v", buckets)
	}
	users, buckets = h.nearbyOK(alice, radius(100))
	same(t, users, bob, cara, dev, eli, xan, yui)
	if fmt.Sprint(buckets) != "[5 5 10 15 50 100]" {
		t.Fatalf("buckets %v", buckets)
	}
	users, _ = h.nearbyOK(alice, radius(5))
	same(t, users, bob, cara) // dev is 5.6 km away
	users, _ = h.nearbyOK(alice, radius(10))
	same(t, users, bob, cara, dev)
	users, _ = h.nearbyOK(alice, radius(15))
	same(t, users, bob, cara, dev, eli)

	// The distance shown is the bucket, never smaller than the real distance, and the order follows it
	// with ties broken by user id. Two members in the same bucket are sorted by id.
	h.north(cara, 0.00)
	h.north(dev, 0.00)
	users, buckets = h.nearbyOK(alice, radius(100))
	same(t, users, bob, cara, dev, eli, xan, yui)
	if fmt.Sprint(buckets) != "[5 5 5 15 50 100]" {
		t.Fatalf("buckets %v", buckets)
	}
	if !slices.IsSorted(users[:3]) {
		t.Fatalf("ties are not ordered by user id: %v", users[:3])
	}

	// An item has exactly the public search fields the member shows, a bucket, and nothing positional.
	h.exec(`UPDATE profiles SET data=data||'{"headline":"hi","bio":"about","interests":["Music"],"currentVibe":"Chill","country":"IN","languages":[{"code":"en"}],"city":"secret city"}'::jsonb WHERE user_id=$1`, bob)
	got, _, _ := h.nearbyList(alice, radius(5))
	item := items(got.data)[0]
	want := []string{"avatarUrl", "bio", "country", "currentVibe", "displayName", "distanceKm", "headline", "interests", "languages", "localTime", "personalityTags", "sharedInterests", "userId", "username"}
	keys := make([]string, 0, len(item))
	for k := range item {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if fmt.Sprint(keys) != fmt.Sprint(want) {
		t.Fatalf("item keys %v, want %v", keys, want)
	}
	if got.data["nextCursor"] != nil {
		t.Fatalf("cursor %v", got.data["nextCursor"])
	}
	// Field audiences work exactly as in people search.
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(jsonb_set(jsonb_set(jsonb_set(data,'{fieldAudiences,interests}','"nobody"'),'{fieldAudiences,languages}','"friends"'),'{fieldAudiences,vibe}','"nobody"'),'{fieldAudiences,location}','"nobody"') WHERE user_id=$1`, bob)
	got, _, _ = h.nearbyList(alice, radius(5))
	item = items(got.data)[0]
	for _, hidden := range []string{"interests", "languages", "currentVibe", "country", "city", "online"} {
		if _, ok := item[hidden]; ok {
			t.Fatalf("%s shown against the member's audience: %v", hidden, item)
		}
	}
	if item["headline"] != "hi" || item["distanceKm"] != float64(5) {
		t.Fatalf("item %v", item)
	}
}

func TestNearbyExcludesWhoIsNotEligible(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	for _, id := range []string{bob, cara, dev, eli, xan, yui} {
		h.north(id, 0.01)
	}
	list := func() []string {
		t.Helper()
		users, _ := h.nearbyOK(alice, map[string]any{})
		return users
	}
	same(t, list(), bob, cara, dev, eli, xan, yui)

	// The caller is never listed.
	h.north(alice, 0.01)
	same(t, list(), bob, cara, dev, eli, xan, yui)

	// A stale location (older than 24 hours) is not sharing; 23 hours still is.
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '25 hours' WHERE user_id=$1`, bob)
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '23 hours' WHERE user_id=$1`, cara)
	same(t, list(), cara, dev, eli, xan, yui)
	h.exec(`UPDATE user_locations SET updated_at=now() WHERE user_id=$1`, bob)

	// Stopping to share removes the member at once, and doing it twice is harmless.
	h.expect(h.call(dev, "DELETE", "/v1/me/location"), 200, "")
	h.expect(h.call(dev, "DELETE", "/v1/me/location"), 200, "")
	same(t, list(), bob, cara, eli, xan, yui)
	h.north(dev, 0.01)

	// Not discoverable, or not public, is not listed.
	h.policy(eli, "discoverable", false)
	h.policy(xan, "profileAudience", "friends")
	same(t, list(), bob, cara, dev, yui)
	h.policy(eli, "discoverable", true)
	h.policy(xan, "profileAudience", "public")

	// Blocks hide in both directions.
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/block"), 200, "")
	h.expect(h.call(cara, "POST", "/v1/users/"+alice+"/block"), 200, "")
	same(t, list(), dev, eli, xan, yui)
	// ... and the blocked member does not see the caller either.
	h.place(bob, bengaluru.Latitude, bengaluru.Longitude)
	_, hiddenFromBob, _ := h.nearbyList(bob, map[string]any{})
	if slices.Contains(hiddenFromBob, alice) {
		t.Fatal("a blocked member saw the person who blocked them")
	}
	h.expect(h.call(alice, "DELETE", "/v1/users/"+bob+"/block"), 200, "")
	h.expect(h.call(cara, "DELETE", "/v1/users/"+alice+"/block"), 200, "")
	same(t, list(), bob, cara, dev, eli, xan, yui) // all in the 5 km bucket, so ordered by id

	// A member who has not finished onboarding, or is not active, is not listed.
	h.exec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, yui)
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, xan)
	same(t, list(), bob, cara, dev, eli)
}

func TestNearbyRequiresTheCallerToShareAFreshLocation(t *testing.T) {
	h := newSocialHarness(t)
	h.north(bob, 0.01)
	// Not visible: Nearby is closed to the caller, with or without a stored point (reciprocity).
	got, _, _ := h.nearbyList(alice, map[string]any{})
	h.expect(got, 409, "NEARBY_OFF")
	h.visible(alice)
	got, _, _ = h.nearbyList(alice, map[string]any{})
	h.expect(got, 409, "LOCATION_NOT_SHARED")
	status, _, raw := h.full(alice, "POST", "/v1/discover/nearby", "application/json", `{}`)
	var body struct {
		Error map[string]string `json:"error"`
	}
	_ = json.Unmarshal(raw, &body)
	if status != 409 || body.Error["message"] != "Share your location to see people nearby." {
		t.Fatalf("%d %s", status, raw)
	}
	// A stale location is the same as none.
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '25 hours' WHERE user_id=$1`, alice)
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{}), 409, "LOCATION_NOT_SHARED")
	// An invalid body is refused before the location matters, and a filter is no substitute for sharing; a fresh point works.
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", radius(0)), 422, "VALIDATION")
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", radius(4)), 422, "VALIDATION")
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{"country": "IN"}), 409, "LOCATION_NOT_SHARED")
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	users, _ := h.nearbyOK(alice, map[string]any{})
	same(t, users, bob)
	// Sharing, then stopping, closes Nearby for the caller as well.
	h.expect(h.call(alice, "DELETE", "/v1/me/location"), 200, "")
	got, _, _ = h.nearbyList(alice, map[string]any{})
	h.expect(got, 409, "LOCATION_NOT_SHARED")
}

func TestNearbyRadiusValidation(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	for _, bad := range []string{`0`, `1`, `2`, `3`, `4`, `6`, `7`, `20`, `24`, `26`, `99`, `-1`, `101`, `1000`, `"abc"`, `"25"`, `"5km"`, `"5"`, `1.5`, `5.0`, `1e1`, `25e0`, `null`, `true`, `[5]`, `{"km":5}`, `""`, `99999999999999999999`, `-0`, `0.5`} {
		got, _, _ := h.nearbyList(alice, json.RawMessage(`{"radiusKm":`+bad+`}`))
		h.expect(got, 422, "VALIDATION")
	}
	// The radius given twice is a duplicate key.
	got, _, _ := h.nearbyList(alice, json.RawMessage(`{"radiusKm":5,"radiusKm":10}`))
	h.expect(got, 422, "VALIDATION")
	// Only the bucket radii are accepted: nothing narrows the circle below 5 km or between the buckets.
	for _, good := range []int{5, 10, 15, 25, 50, 100} {
		got, _, _ := h.nearbyList(alice, radius(good))
		h.expect(got, 200, "")
	}
	// Omitted means 25.
	h.north(bob, 0.2)  // 22 km
	h.north(cara, 0.3) // 33 km
	users, _ := h.nearbyOK(alice, map[string]any{})
	same(t, users, bob)
	// The body must be a JSON object with the right content type, and GET is no longer served.
	for name, tc := range map[string]struct{ contentType, body string }{
		"not an object":     {"application/json", `[]`},
		"empty body":        {"application/json", ``},
		"text":              {"text/plain", `{}`},
		"no content type":   {"", `{}`},
		"trailing data":     {"application/json", `{}{}`},
		"form encoded":      {"application/x-www-form-urlencoded", `radiusKm=5`},
		"invalid json":      {"application/json", `{"radiusKm":`},
		"duplicate filters": {"application/json", `{"country":"IN","country":"FR"}`},
	} {
		h.api.search.reset(alice)
		status, _, raw := h.full(alice, "POST", "/v1/discover/nearby", tc.contentType, tc.body)
		if status != 422 || !strings.Contains(string(raw), `"VALIDATION"`) {
			t.Fatalf("%s: %d %s", name, status, raw)
		}
	}
	h.api.search.reset(alice)
	h.expect(h.send(alice, "GET", "/v1/discover/nearby", nil), 404, "NOT_FOUND")
	h.expect(h.send(alice, "GET", "/v1/discover/nearby?radiusKm=5", nil), 404, "NOT_FOUND")
	h.expect(h.send(alice, "PUT", "/v1/discover/nearby", map[string]any{}), 404, "NOT_FOUND")
	h.expect(h.send(alice, "DELETE", "/v1/discover/nearby", nil), 404, "NOT_FOUND")
	h.expect(h.send(alice, "PATCH", "/v1/me/location", map[string]any{}), 405, "METHOD_NOT_ALLOWED")
}

func TestNearbyPagingCursorBindingAndLimits(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	// 45 members at the same point plus 5 in a farther bucket.
	var all []string
	for i := 0; i < 50; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 100+i)
		h.user(id, fmt.Sprintf("near_%d", i))
		if i < 45 {
			h.north(id, 0)
		} else {
			h.north(id, 0.05)
		}
		all = append(all, id)
	}
	var seen []string
	var cursors []string
	body := map[string]any{}
	for page := 0; page < 3; page++ {
		got, users, buckets := h.nearbyList(alice, body)
		h.expect(got, 200, "")
		if want := []int{20, 20, 10}[page]; len(users) != want {
			t.Fatalf("page %d has %d items, want %d", page, len(users), want)
		}
		seen = append(seen, users...)
		if !sort.IntsAreSorted(buckets) {
			t.Fatalf("page %d buckets %v", page, buckets)
		}
		next, _ := got.data["nextCursor"].(string)
		if page < 2 {
			if next == "" {
				t.Fatalf("page %d has no cursor", page)
			}
			cursors = append(cursors, next)
			body = map[string]any{"cursor": next}
		} else if got.data["nextCursor"] != nil {
			t.Fatalf("last page has a cursor: %v", got.data["nextCursor"])
		}
	}
	if len(seen) != 50 {
		t.Fatalf("%d members listed", len(seen))
	}
	dedup := map[string]bool{}
	for _, id := range seen {
		if dedup[id] {
			t.Fatalf("duplicate %s", id)
		}
		dedup[id] = true
	}
	for _, id := range all {
		if !dedup[id] {
			t.Fatalf("%s was skipped", id)
		}
	}
	// Whole order: the 45 members in the nearest bucket by id, then the 5 farther ones by id.
	if !slices.IsSorted(seen[:45]) || !slices.IsSorted(seen[45:]) {
		t.Fatal("members are not ordered by id inside a bucket")
	}
	for _, id := range seen[45:] {
		if n := strings.TrimPrefix(id, "019a4000-0000-7000-8000-"); n < "000000000145" {
			t.Fatalf("%s should be in the nearest bucket", id)
		}
	}

	cursor := cursors[0]
	// A cursor holds a bucket and a user id, never a coordinate or an exact distance.
	payload, err := base64.RawURLEncoding.DecodeString(strings.Split(cursor, ".")[0])
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err = json.Unmarshal(payload, &fields); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if fmt.Sprint(keys) != "[a b e l p q r u]" || fields["b"] != float64(5) || fields["r"] != float64(25) || len(fields["q"].(string)) != 64 {
		t.Fatalf("cursor payload %v", fields)
	}
	if strings.Contains(string(payload), "12.97") || strings.Contains(string(payload), "77.59") {
		t.Fatalf("cursor carries a coordinate: %s", payload)
	}

	bad := func(name string, body map[string]any, actor string) {
		t.Helper()
		got, _, _ := h.nearbyList(actor, body)
		if got.status != 422 || got.code != "INVALID_CURSOR" {
			t.Fatalf("%s: %d %q", name, got.status, got.code)
		}
	}
	with := func(cursor string, more ...any) map[string]any {
		body := map[string]any{"cursor": cursor}
		for i := 0; i+1 < len(more); i += 2 {
			body[more[i].(string)] = more[i+1]
		}
		return body
	}
	// Different radius, tampering, truncation, garbage, another member, and an expired or too-deep cursor.
	bad("other radius", with(cursor, "radiusKm", 10), alice)
	bad("another bucket radius", with(cursor, "radiusKm", 50), alice)
	bad("tampered", with(cursor+"x"), alice)
	bad("flipped payload", with(flipFirstByte(cursor)), alice)
	bad("signature removed", with(strings.Split(cursor, ".")[0]), alice)
	bad("garbage", with("not-a-cursor"), alice)
	// Like people search, a cursor over 2048 characters is refused as malformed input before it is read.
	h.expect(h.send(alice, "POST", "/v1/discover/nearby", with(strings.Repeat("a", 2100))), 422, "VALIDATION")
	for _, notText := range []any{5, true, nil, []string{"x"}} {
		h.api.search.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{"cursor": notText}), 422, "VALIDATION")
	}
	h.place(bob, bengaluru.Latitude, bengaluru.Longitude)
	bad("foreign principal", with(cursor), bob)
	// A people-search cursor cannot be replayed here.
	peopleCursor := h.api.peopleSign(peopleCursor{User: alice, Query: "x", After: bob, Exp: time.Now().Add(time.Minute).Unix(), Page: 1})
	bad("people-search cursor", with(peopleCursor), alice)
	tag := h.api.nearbyCentreTag(bengaluru)
	noFilters := nearbyQueryHash(mustFilters(t, `{}`))
	sealed := func(mutate func(*nearbyCursor)) string {
		c := nearbyCursor{User: alice, Radius: 25, Query: noFilters, Loc: tag, Bucket: 5, After: bob, Exp: time.Now().Add(time.Minute).Unix(), Page: 1}
		mutate(&c)
		return h.api.nearbySeal(c)
	}
	bad("expired", with(sealed(func(c *nearbyCursor) { c.Exp = time.Now().Add(-time.Minute).Unix() })), alice)
	for _, page := range []int{0, 10, 11, -1} {
		bad(fmt.Sprintf("page %d", page), with(sealed(func(c *nearbyCursor) { c.Page = page })), alice)
	}
	bad("unknown bucket", with(sealed(func(c *nearbyCursor) { c.Bucket = 4 })), alice)
	bad("another filter hash", with(sealed(func(c *nearbyCursor) { c.Query = nearbyQueryHash(mustFilters(t, `{"country":"IN"}`)) })), alice)
	bad("no filter hash", with(sealed(func(c *nearbyCursor) { c.Query = "" })), alice)
	if got, _, _ := h.nearbyList(alice, with(sealed(func(c *nearbyCursor) { c.Page = 9 }))); got.status != 200 {
		t.Fatalf("a valid cursor at the last page was refused: %d %q", got.status, got.code)
	}
	// Moving invalidates cursors: the order they continue from no longer exists.
	h.place(alice, bengaluru.Latitude+0.5, bengaluru.Longitude)
	bad("caller moved", with(cursor), alice)
}

// mustFilters parses a body the way the endpoint does and returns its filters.
func mustFilters(t *testing.T, raw string) domain.PeopleFilters {
	t.Helper()
	var body map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatal(err)
	}
	req, err := domain.ParseNearbyRequest(body)
	if err != nil {
		t.Fatal(err)
	}
	return req.Filters
}

func flipFirstByte(cursor string) string {
	b := []byte(cursor)
	if b[0] == 'A' {
		b[0] = 'B'
	} else {
		b[0] = 'A'
	}
	return string(b)
}

// The tenth page is the last: pages are capped so a crawl of one position stays bounded.
func TestNearbyStopsAfterTenPages(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	for i := 0; i < 215; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 1000+i)
		h.user(id, fmt.Sprintf("crowd_%d", i))
		h.north(id, 0)
	}
	body, pages, total := map[string]any{}, 0, 0
	for {
		got, users, _ := h.nearbyList(alice, body)
		h.expect(got, 200, "")
		pages++
		total += len(users)
		next, _ := got.data["nextCursor"].(string)
		if next == "" {
			break
		}
		body = map[string]any{"cursor": next}
	}
	if pages != 10 || total != 200 {
		t.Fatalf("%d pages and %d members, want 10 and 200", pages, total)
	}
}

func TestLocationEndpoints(t *testing.T) {
	h := newSocialHarness(t)
	h.visible(alice)
	state := func() map[string]any { return h.ok(alice, "GET", "/v1/me/location") }
	if got := state(); got["sharing"] != false || got["updatedAt"] != nil || len(got) != 2 {
		t.Fatalf("before sharing %v", got)
	}
	put := h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "").data
	if put["sharing"] != true || len(put) != 2 {
		t.Fatalf("PUT %v", put)
	}
	stamp, err := time.Parse(time.RFC3339Nano, put["updatedAt"].(string))
	if err != nil || time.Since(stamp) > time.Minute || time.Until(stamp) > time.Minute {
		t.Fatalf("updatedAt %v (%v)", put["updatedAt"], err)
	}
	if got := state(); got["sharing"] != true || got["updatedAt"] != put["updatedAt"] || len(got) != 2 {
		t.Fatalf("after sharing %v", got)
	}
	// A location that has gone stale is not sharing, and no coordinates are ever returned.
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '25 hours' WHERE user_id=$1`, alice)
	if got := state(); got["sharing"] != false || got["updatedAt"] != nil {
		t.Fatalf("stale %v", got)
	}
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '23 hours' WHERE user_id=$1`, alice)
	if got := state(); got["sharing"] != true {
		t.Fatalf("23 hours old %v", got)
	}
	del := h.expect(h.call(alice, "DELETE", "/v1/me/location"), 200, "").data
	if del["sharing"] != false || len(del) != 1 {
		t.Fatalf("DELETE %v", del)
	}
	if again := h.expect(h.call(alice, "DELETE", "/v1/me/location"), 200, "").data; again["sharing"] != false || len(again) != 1 {
		t.Fatalf("second DELETE %v", again)
	}
	if got := state(); got["sharing"] != false || got["updatedAt"] != nil {
		t.Fatalf("after stopping %v", got)
	}
	var rows int
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("%d rows after stopping (%v)", rows, err)
	}
	// Sharing again replaces the point instead of adding a row.
	h.api.locations.reset(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(1, 2)), 200, "")
	h.exec(`UPDATE user_locations SET updated_at=now()-interval '30 hours' WHERE user_id=$1`, alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(3, 4)), 200, "")
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations`).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("%d rows (%v)", rows, err)
	}
}

func TestLocationValidation(t *testing.T) {
	h := newSocialHarness(t)
	h.visible(alice)
	bad := func(name, contentType, body string) {
		t.Helper()
		h.api.locations.reset(alice)
		status, _, raw := h.full(alice, "PUT", "/v1/me/location", contentType, body)
		var parsed struct {
			Error map[string]string `json:"error"`
		}
		_ = json.Unmarshal(raw, &parsed)
		if status != 422 || parsed.Error["code"] != "VALIDATION" {
			t.Fatalf("%s: %d %s", name, status, raw)
		}
		// The refusal never repeats what was sent.
		for _, digits := range []string{"91", "181", "12.9716", "NaN"} {
			if strings.Contains(parsed.Error["message"], digits) {
				t.Fatalf("%s: message repeats the input: %q", name, parsed.Error["message"])
			}
		}
	}
	const appJSON = "application/json"
	bad("empty object", appJSON, `{}`)
	bad("missing longitude", appJSON, `{"latitude":12.97}`)
	bad("missing latitude", appJSON, `{"longitude":77.59}`)
	bad("extra key", appJSON, `{"latitude":12.97,"longitude":77.59,"accuracy":5}`)
	bad("altitude", appJSON, `{"latitude":12.97,"longitude":77.59,"altitude":1}`)
	bad("string numbers", appJSON, `{"latitude":"12.97","longitude":"77.59"}`)
	bad("null", appJSON, `{"latitude":null,"longitude":77.59}`)
	bad("boolean", appJSON, `{"latitude":true,"longitude":77.59}`)
	bad("array", appJSON, `{"latitude":[12.97],"longitude":77.59}`)
	bad("object", appJSON, `{"latitude":{"v":1},"longitude":77.59}`)
	bad("latitude too high", appJSON, `{"latitude":90.0001,"longitude":0}`)
	bad("latitude too low", appJSON, `{"latitude":-90.0001,"longitude":0}`)
	bad("longitude too high", appJSON, `{"latitude":0,"longitude":180.0001}`)
	bad("longitude too low", appJSON, `{"latitude":0,"longitude":-180.0001}`)
	bad("far out of range", appJSON, `{"latitude":91,"longitude":181}`)
	bad("overflow", appJSON, `{"latitude":1e999,"longitude":0}`)
	bad("negative overflow", appJSON, `{"latitude":0,"longitude":-1e999}`)
	bad("NaN token", appJSON, `{"latitude":NaN,"longitude":0}`)
	bad("Infinity token", appJSON, `{"latitude":Infinity,"longitude":0}`)
	bad("duplicate key", appJSON, `{"latitude":1,"latitude":2,"longitude":3}`)
	bad("not an object", appJSON, `[12.97,77.59]`)
	bad("bare number", appJSON, `12.97`)
	bad("trailing data", appJSON, `{"latitude":1,"longitude":2}{}`)
	bad("not json", appJSON, `latitude=1&longitude=2`)
	bad("wrong content type", "text/plain", `{"latitude":1,"longitude":2}`)
	bad("no content type", "", `{"latitude":1,"longitude":2}`)
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("a refused request stored %d rows (%v)", rows, err)
	}
	// The extremes themselves, and integers and exponents, are fine.
	for i, body := range []string{`{"latitude":90,"longitude":180}`, `{"latitude":-90,"longitude":-180}`, `{"latitude":0,"longitude":0}`, `{"latitude":1e1,"longitude":-1.5E2}`, `{"latitude":-0.0,"longitude":0.004}`} {
		h.fresh(alice)
		if status, _, raw := h.full(alice, "PUT", "/v1/me/location", appJSON, body); status != 200 {
			t.Fatalf("case %d %s: %d %s", i, body, status, raw)
		}
	}
}

func TestLocationWritesAndNearbyReadsAreRateLimited(t *testing.T) {
	h := newSocialHarness(t)
	h.visible(alice)
	h.visible(cara)
	h.place(bob, bengaluru.Latitude, bengaluru.Longitude)
	for i := 0; i < 3; i++ {
		h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.97, 77.59+float64(i)*0.01)), 200, "")
	}
	status, header, raw := h.full(alice, "PUT", "/v1/me/location", "application/json", `{"latitude":12.97,"longitude":77.59}`)
	if status != 429 || header.Get("Retry-After") != "120" || !strings.Contains(string(raw), `"RATE_LIMITED"`) {
		t.Fatalf("fourth write: %d %q %s", status, header.Get("Retry-After"), raw)
	}
	// The limit is per account, and reading and stopping are not part of it.
	h.expect(h.send(cara, "PUT", "/v1/me/location", putLocation(12.97, 77.59)), 200, "")
	h.expect(h.call(alice, "GET", "/v1/me/location"), 200, "")
	h.expect(h.call(alice, "DELETE", "/v1/me/location"), 200, "")
	// A refused body does not use a token: the limit counts only writes that would be stored.
	h.api.locations.reset(alice)
	for i := 0; i < 5; i++ {
		h.expect(h.send(alice, "PUT", "/v1/me/location", map[string]any{"latitude": 999, "longitude": 0}), 422, "VALIDATION")
	}
	for i := 0; i < 3; i++ {
		h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.97, 77.59)), 200, "")
	}

	// Reading Nearby shares the search limit: a burst of 10, then 429 with Retry-After: 2.
	h.api.search.reset(alice)
	for i := 0; i < 10; i++ {
		h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{}), 200, "")
	}
	status, header, raw = h.full(alice, "POST", "/v1/discover/nearby", "application/json", `{}`)
	if status != 429 || header.Get("Retry-After") != "2" || !strings.Contains(string(raw), `"RATE_LIMITED"`) {
		t.Fatalf("eleventh read: %d %q %s", status, header.Get("Retry-After"), raw)
	}
}

// Precise coordinates are rounded before the database sees them and appear in no response, table, event or log.
func TestLocationIsRoundedBeforeStorageAndNeverLeaks(t *testing.T) {
	h := newSocialHarness(t)
	h.visible(alice)
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previous) })

	const preciseLat, preciseLon = "12.971634", "77.594566"
	status, _, put := h.full(alice, "PUT", "/v1/me/location", "application/json", `{"latitude":`+preciseLat+`,"longitude":`+preciseLon+`}`)
	if status != 200 {
		t.Fatalf("PUT %d %s", status, put)
	}
	var lat, lon float64
	var text string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT latitude,longitude,latitude::text||','||longitude::text FROM user_locations WHERE user_id=$1`, alice).Scan(&lat, &lon, &text); err != nil {
		t.Fatal(err)
	}
	if lat != 12.97 || lon != 77.59 || text != "12.97,77.59" {
		t.Fatalf("stored %v,%v (%s), want 12.97,77.59", lat, lon, text)
	}
	// Every stored coordinate sits on the 2-decimal grid, whatever put it there.
	var offGrid int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations WHERE abs(latitude*100-round(latitude*100))>1e-9 OR abs(longitude*100-round(longitude*100))>1e-9`).Scan(&offGrid); err != nil || offGrid != 0 {
		t.Fatalf("%d off-grid rows (%v)", offGrid, err)
	}
	// Rounding is to nearest, also for negatives, and a tiny negative becomes plain zero.
	h.api.locations.reset(alice)
	for _, tc := range []struct{ in, want string }{
		{`{"latitude":-33.8688,"longitude":151.2093}`, "-33.87,151.21"},
		{`{"latitude":-0.004,"longitude":-0.0049}`, "0,0"},
		{`{"latitude":89.996,"longitude":-179.996}`, "90,-180"},
		{`{"latitude":0.016,"longitude":0.994}`, "0.02,0.99"},
	} {
		h.fresh(alice)
		h.expect(h.send(alice, "PUT", "/v1/me/location", json.RawMessage(tc.in)), 200, "")
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT latitude::text||','||longitude::text FROM user_locations WHERE user_id=$1`, alice).Scan(&text); err != nil || text != tc.want {
			t.Fatalf("%s stored %q (%v), want %s", tc.in, text, err, tc.want)
		}
	}
	h.fresh(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.971634, 77.594566)), 200, "")

	// Reading back and Nearby never return a position.
	h.north(bob, 0.01)
	var responses []string
	responses = append(responses, string(put))
	for _, call := range [][3]string{{"GET", "/v1/me/location", ""}, {"POST", "/v1/discover/nearby", `{}`}, {"POST", "/v1/discover/nearby", `{"radiusKm":100,"country":"IN"}`}} {
		h.api.search.reset(alice)
		_, _, raw := h.full(alice, call[0], call[1], "application/json", call[2])
		responses = append(responses, string(raw))
	}
	_, _, raw := h.full(alice, "DELETE", "/v1/me/location", "", "")
	responses = append(responses, string(raw))
	for _, body := range responses {
		for _, leak := range []string{preciseLat, preciseLon, `"latitude"`, `"longitude"`, `"lat"`, `"lon"`} {
			if strings.Contains(body, leak) {
				t.Fatalf("response leaks %q: %s", leak, body)
			}
		}
	}
	// The precise value is in no table.
	h.api.locations.reset(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.971634, 77.594566)), 200, "")
	tables, err := h.db.Pool.Query(h.ctx, `SELECT tablename FROM pg_tables WHERE schemaname='public'`)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for tables.Next() {
		var name string
		if err = tables.Scan(&name); err != nil {
			t.Fatal(err)
		}
		names = append(names, name)
	}
	tables.Close()
	for _, name := range names {
		for _, precise := range []string{preciseLat, preciseLon} {
			var hits int
			query := fmt.Sprintf(`SELECT count(*) FROM %s t WHERE t::text LIKE $1`, pgx.Identifier{name}.Sanitize())
			if err = h.db.Pool.QueryRow(h.ctx, query, "%"+precise+"%").Scan(&hits); err != nil || hits != 0 {
				t.Fatalf("%s found in table %s (%v)", precise, name, err)
			}
		}
	}
	// Nor in any log line, including requests that were refused.
	h.api.locations.reset(alice)
	h.full(alice, "PUT", "/v1/me/location", "application/json", `{"latitude":12.971634,"longitude":77.594566,"x":1}`)
	h.full(alice, "PUT", "/v1/me/location", "application/json", `{"latitude":912.971634,"longitude":77.594566}`)
	for _, precise := range []string{preciseLat, preciseLon} {
		if strings.Contains(logs.String(), precise) {
			t.Fatalf("a log line contains %s:\n%s", precise, logs.String())
		}
	}
	if logs.Len() == 0 {
		t.Fatal("captured no log output, so the log check proved nothing")
	}
}

// The prefilter and the exact distance agree with a brute-force reference on a few hundred rows, including
// around the antimeridian and the poles where a naive longitude box would drop or duplicate people.
func TestNearbyMatchesAReferenceAroundTheAntimeridianAndPoles(t *testing.T) {
	h := newSocialHarness(t)
	const n = 300
	ids := make([]string, n)
	for i := range ids {
		ids[i] = fmt.Sprintf("019a4000-0000-7000-8000-%012d", 5000+i)
		h.user(ids[i], fmt.Sprintf("spread_%d", i))
	}
	rng := rand.New(rand.NewSource(7))
	// Every member gets a country, vibe, interests and languages, and some hide a field, so the filtered runs
	// below are checked against a reference that knows about field audiences.
	attrs := make(map[string]spreadAttrs, n)
	for i, id := range ids {
		a := spreadAttrs{
			country:   []string{"IN", "FR", "JP"}[i%3],
			vibe:      []string{"Chill", "Active"}[i%2],
			interests: [][]string{{"Music"}, {"Art", "Books"}, {"Music", "Gaming"}, {"Travel"}}[i%4],
			languages: [][]string{{"en"}, {"fr", "en"}, {"ja"}, {"hi", "en"}, {"ko"}}[i%5],
			hidden:    map[string]bool{"location": i%7 == 0, "vibe": i%11 == 0, "interests": i%13 == 0, "languages": i%17 == 0},
		}
		// Bands and blocks, so the reference also knows who the barrier hides: every fifth member is a minor, every
		// third of the rest an adult with a stored birth date, the others unknown; some are blocked in either direction.
		switch {
		case i%5 == 0:
			a.minor = true
			h.ageAt(id, 15)
		case i%3 == 0:
			h.ageAt(id, 30)
		}
		switch {
		case i%23 == 0:
			a.blocked = true
			h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, alice, id)
		case i%29 == 0:
			a.blocked = true
			h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, id, alice)
		}
		attrs[id] = a
		languages := make([]map[string]string, len(a.languages))
		for j, code := range a.languages {
			languages[j] = map[string]string{"code": code}
		}
		data, _ := json.Marshal(map[string]any{"country": a.country, "currentVibe": a.vibe, "interests": a.interests, "languages": languages})
		h.exec(`UPDATE profiles SET data=data||$2::jsonb WHERE user_id=$1`, id, data)
		for field, hide := range a.hidden {
			if hide {
				h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],'"nobody"') WHERE user_id=$1`, id, field)
			}
		}
	}
	filtered := 0
	wrapLon := func(v float64) float64 {
		for v > 180 {
			v -= 360
		}
		for v < -180 {
			v += 360
		}
		return v
	}
	for _, sc := range []struct {
		name    string
		centre  domain.Location
		radius  int
		scatter func() (float64, float64)
	}{
		{"city", domain.RoundLocation(12.9716, 77.5946), 50, func() (float64, float64) {
			return 12.97 + (rng.Float64()-0.5)*1.8, 77.59 + (rng.Float64()-0.5)*1.8
		}},
		{"city wide", domain.RoundLocation(12.9716, 77.5946), 100, func() (float64, float64) {
			return 12.97 + (rng.Float64()-0.5)*2.4, 77.59 + (rng.Float64()-0.5)*2.4
		}},
		{"east of the antimeridian", domain.RoundLocation(0.5, 179.99), 100, func() (float64, float64) {
			return 0.5 + (rng.Float64()-0.5)*2.4, wrapLon(179.99 + (rng.Float64()-0.5)*2.4)
		}},
		{"west of the antimeridian", domain.RoundLocation(-16.5, -179.97), 50, func() (float64, float64) {
			return -16.5 + (rng.Float64()-0.5)*1.6, wrapLon(-179.97 + (rng.Float64()-0.5)*1.6)
		}},
		{"on the antimeridian at high latitude", domain.RoundLocation(66.0, 180), 100, func() (float64, float64) {
			return 66 + (rng.Float64()-0.5)*2.2, wrapLon(180 + (rng.Float64()-0.5)*5)
		}},
		{"north pole", domain.RoundLocation(89.9, 10), 100, func() (float64, float64) {
			return 88.6 + rng.Float64()*1.4, rng.Float64()*360 - 180
		}},
		{"south pole", domain.RoundLocation(-90, 0), 100, func() (float64, float64) {
			return -88.9 - rng.Float64()*1.1, rng.Float64()*360 - 180
		}},
		{"just under the pole", domain.RoundLocation(-89.2, 123.45), 100, func() (float64, float64) {
			return -88.0 - rng.Float64()*2, wrapLon(123.45 + (rng.Float64()-0.5)*180)
		}},
	} {
		t.Run(sc.name, func(t *testing.T) {
			points := make(map[string]domain.Location, n)
			for _, id := range ids {
				lat, lon := sc.scatter()
				lat = math.Max(-90, math.Min(90, lat))
				points[id] = domain.RoundLocation(lat, lon)
				h.place(id, lat, lon)
			}
			h.place(alice, sc.centre.Latitude, sc.centre.Longitude)
			type entry struct {
				id     string
				bucket int
			}
			type inRange struct {
				id string
				km float64
			}
			var everyoneInRange []inRange
			for _, id := range ids {
				d := domain.HaversineKm(sc.centre, points[id])
				// A point within a hair of the radius or a bucket edge is ambiguous to the last bit; drop it.
				edge := math.Abs(d - float64(sc.radius))
				for _, b := range domain.NearbyBuckets {
					edge = math.Min(edge, math.Abs(d-float64(b)))
				}
				if edge < 1e-6 {
					h.exec(`DELETE FROM user_locations WHERE user_id=$1`, id)
					continue
				}
				if d <= float64(sc.radius) {
					everyoneInRange = append(everyoneInRange, inRange{id, d})
				}
			}
			// check runs the endpoint over every page and compares with the reference for one filter set.
			check := func(label string, spec filterSpec, viewerMinor bool) {
				var want []entry
				for _, e := range everyoneInRange {
					// The barrier: a block either way, or a member in the other band, does not exist for the viewer.
					if attrs[e.id].blocked || attrs[e.id].minor != viewerMinor {
						continue
					}
					if attrs[e.id].matches(spec) {
						want = append(want, entry{e.id, domain.DistanceBucketIn(domain.NearbyBucketsFor(viewerMinor), e.km)})
					}
				}
				sort.Slice(want, func(i, j int) bool {
					if want[i].bucket != want[j].bucket {
						return want[i].bucket < want[j].bucket
					}
					return want[i].id < want[j].id
				})
				if len(want) > 200 {
					want = want[:200]
				}
				var got []entry
				body := spec.body(sc.radius)
				for {
					reply, users, buckets := h.nearbyList(alice, body)
					h.expect(reply, 200, "")
					for i := range users {
						got = append(got, entry{users[i], buckets[i]})
					}
					next, _ := reply.data["nextCursor"].(string)
					if next == "" {
						break
					}
					body = spec.body(sc.radius)
					body["cursor"] = next
				}
				if strings.HasPrefix(label, "no filter") && len(want) < 5 {
					t.Fatalf("scenario %q finds only %d members; it does not exercise anything", sc.name, len(want))
				}
				if !strings.HasPrefix(label, "no filter") {
					filtered += len(want)
				}
				if fmt.Sprint(got) != fmt.Sprint(want) {
					t.Fatalf("%s: %d members listed, reference has %d\n got %v\nwant %v", label, len(got), len(want), got, want)
				}
			}
			for _, viewerMinor := range []bool{false, true} {
				if viewerMinor {
					h.ageAt(alice, 15)
				} else {
					h.ageAt(alice, 40)
				}
				suffix := map[bool]string{false: " (adult viewer)", true: " (minor viewer)"}[viewerMinor]
				check("no filter"+suffix, filterSpec{}, viewerMinor)
				check("country"+suffix, filterSpec{country: "IN"}, viewerMinor)
				check("interests and languages"+suffix, filterSpec{interests: []string{"music", "travel"}, languages: []string{"en", "ja"}}, viewerMinor)
				check("vibe, country and language"+suffix, filterSpec{vibe: "chill", country: "FR", languages: []string{"fr"}}, viewerMinor)
			}
		})
	}
	if filtered < 40 {
		t.Fatalf("filtered runs matched only %d members in all; the reference was barely exercised", filtered)
	}
}

type spreadAttrs struct {
	country, vibe        string
	interests, languages []string
	hidden               map[string]bool
	minor, blocked       bool
}

// filterSpec is one set of Nearby filters, as the reference sees them.
type filterSpec struct {
	country, vibe        string
	interests, languages []string
}

func (f filterSpec) body(radius int) map[string]any {
	body := map[string]any{"radiusKm": radius}
	if f.country != "" {
		body["country"] = f.country
	}
	if f.vibe != "" {
		body["vibe"] = f.vibe
	}
	if f.interests != nil {
		body["interests"] = f.interests
	}
	if f.languages != nil {
		body["languages"] = f.languages
	}
	return body
}

// matches is the reference for the filter semantics shared with people search: a dimension filters only when the
// member shows that field to everyone, any value inside a dimension may match, and dimensions combine with AND.
func (a spreadAttrs) matches(f filterSpec) bool {
	any := func(have, want []string) bool {
		for _, h := range have {
			for _, w := range want {
				if strings.EqualFold(h, w) {
					return true
				}
			}
		}
		return false
	}
	switch {
	case f.country != "" && (a.hidden["location"] || a.country != f.country):
		return false
	case f.vibe != "" && (a.hidden["vibe"] || !strings.EqualFold(a.vibe, f.vibe)):
		return false
	case len(f.interests) > 0 && (a.hidden["interests"] || !any(a.interests, f.interests)):
		return false
	case len(f.languages) > 0 && (a.hidden["languages"] || !any(a.languages, f.languages)):
		return false
	}
	return true
}

// The bounding box is only a prefilter, so it must never exclude a point the exact distance would include.
func TestNearbyBoundingBoxNeverDropsAMemberWithinTheRadius(t *testing.T) {
	rng := rand.New(rand.NewSource(11))
	centres := []domain.Location{{Latitude: 0, Longitude: 0}, {Latitude: 12.97, Longitude: 77.59}, {Latitude: 60, Longitude: 179.9}, {Latitude: -60, Longitude: -179.9}, {Latitude: 89.99, Longitude: 0}, {Latitude: -89.5, Longitude: 90}, {Latitude: 90, Longitude: 0}, {Latitude: 0, Longitude: 180}, {Latitude: 0, Longitude: -180}, {Latitude: 80, Longitude: -120}}
	for _, centre := range centres {
		for _, radius := range []int{1, 10, 50, 100} {
			box := domain.NearbyBox(centre, radius)
			for i := 0; i < 4000; i++ {
				p := domain.RoundLocation(math.Max(-90, math.Min(90, centre.Latitude+(rng.Float64()-0.5)*5)), rng.Float64()*360-180)
				if rng.Intn(2) == 0 {
					lon := centre.Longitude + (rng.Float64()-0.5)*6
					for lon > 180 {
						lon -= 360
					}
					for lon < -180 {
						lon += 360
					}
					p.Longitude = domain.RoundCoordinate(lon)
				}
				if domain.HaversineKm(centre, p) <= float64(radius) && !box.Contains(p) {
					t.Fatalf("box %+v around %+v radius %d drops %+v at %.3f km", box, centre, radius, p, domain.HaversineKm(centre, p))
				}
			}
		}
	}
}

func TestNearbyOnlineFlagFollowsAudienceAndConnection(t *testing.T) {
	h := newSocialHarness(t)
	server, _ := withRealtime(t, h)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.north(bob, 0.01)

	// The same member seen through the three places presence can appear.
	view := func() (search, nearby, profile map[string]any) {
		t.Helper()
		h.api.search.reset(alice)
		got := h.expect(h.send(alice, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data
		for _, item := range items(got) {
			if item["userId"] == bob {
				search = item
			}
		}
		h.api.search.reset(alice)
		for _, item := range items(h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{}), 200, "").data) {
			if item["userId"] == bob {
				nearby = item
			}
		}
		profile = h.ok(alice, "GET", "/v1/users/"+bob+"/profile")
		if search == nil || nearby == nil {
			t.Fatalf("bob is missing from search or nearby: %v %v", search, nearby)
		}
		return
	}
	expectOnline := func(label string, present bool) {
		t.Helper()
		search, nearby, profile := view()
		for name, v := range map[string]map[string]any{"search": search, "nearby": nearby, "profile": profile} {
			value, ok := v["online"]
			if ok != present || (ok && value != true) {
				t.Fatalf("%s: %s online=%v present=%v, want present=%v", label, name, value, ok, present)
			}
			for _, key := range []string{"lastSeen", "lastSeenAt", "lastActive", "presence", "status", "connectedAt"} {
				if _, found := v[key]; found {
					t.Fatalf("%s: %s reveals %s", label, name, key)
				}
			}
		}
	}

	// The default audience is "everyone", but nobody is connected: no key at all, not false.
	if got := h.ok(bob, "GET", "/v1/me/privacy")["onlineAudience"]; got != "everyone" {
		t.Fatalf("default onlineAudience %v", got)
	}
	expectOnline("everyone, offline", false)

	ws, _, err := dial(t, server, bob)
	if err != nil {
		t.Fatal(err)
	}
	expectOnline("everyone, connected", true)

	// Any other audience hides presence from this viewer (a stranger), even while connected.
	for _, audience := range []string{"nobody", "friends", "followers"} {
		h.policy(bob, "onlineAudience", audience)
		expectOnline(audience+", connected", false)
	}
	// Presence follows the member's own control, set through the API.
	h.policy(bob, "onlineAudience", "nobody")
	h.expect(h.send(bob, "PATCH", "/v1/me/privacy", map[string]any{"onlineAudience": "everyone"}), 428, "PRECONDITION_REQUIRED")
	version := h.expect(h.call(bob, "GET", "/v1/me/privacy"), 200, "").data["version"].(string)
	patch, _ := json.Marshal(map[string]any{"onlineAudience": "everyone"})
	r := httptest.NewRequest("PATCH", "/v1/me/privacy", bytes.NewReader(patch))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+bob)
	r.Header.Set("If-Match", `"`+version+`"`)
	r.RemoteAddr = "127.0.0.1:50000"
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("PATCH onlineAudience: %d %s", w.Code, w.Body.String())
	}
	expectOnline("everyone again, connected", true)

	// A locked card carries no presence either: the viewer cannot see this profile.
	h.policy(bob, "profileAudience", "friends")
	if card := h.ok(alice, "GET", "/v1/users/"+bob+"/profile"); card["locked"] != true || card["online"] != nil {
		t.Fatalf("locked card %v", card)
	}
	h.policy(bob, "profileAudience", "public")

	// Disconnecting ends it.
	ws.conn.Close(websocket.StatusNormalClosure, "")
	eventually(t, func() bool { return !h.api.RT.Connected(bob) })
	expectOnline("everyone, disconnected", false)

	// A node with no realtime hub reports nobody as online, and does not fail.
	h.api.RT = nil
	expectOnline("no hub", false)
}

func TestNearbyRoutesAndLocationWaitForOnboarding(t *testing.T) {
	for _, route := range [][2]string{{"GET", "/v1/me/location"}, {"PUT", "/v1/me/location"}, {"DELETE", "/v1/me/location"}, {"GET", "/v1/me/nearby"}, {"PUT", "/v1/me/nearby"}, {"DELETE", "/v1/me/nearby"}, {"POST", "/v1/discover/nearby"}, {"GET", "/v1/discover/nearby"}} {
		if onboardingExempt(route[0], route[1]) {
			t.Fatalf("%s %s is exempt from onboarding", route[0], route[1])
		}
	}
	h := newOnboardingHarness(t)
	token := h.login(sam)
	for _, route := range [][2]string{{"GET", "/v1/me/location"}, {"PUT", "/v1/me/location"}, {"DELETE", "/v1/me/location"}, {"GET", "/v1/me/nearby"}, {"PUT", "/v1/me/nearby"}, {"DELETE", "/v1/me/nearby"}, {"POST", "/v1/discover/nearby"}, {"GET", "/v1/discover/nearby"}} {
		h.expect(h.call(route[0], route[1], token, `{"latitude":12.97,"longitude":77.59}`), 403, "ONBOARDING_REQUIRED")
	}
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("a member who has not onboarded stored %d locations (%v)", rows, err)
	}
	h.finishProfile(token, "sam_k", "Sam")
	h.expect(h.call("POST", "/v1/me/onboarding/complete", token, completeBody(memberBirthDate(), "2026-10-01")), 200, "")
	h.expect(h.call("PUT", "/v1/me/location", token, `{"latitude":12.97,"longitude":77.59}`), 409, "NEARBY_OFF")
	h.expect(h.call("PUT", "/v1/me/nearby", token, ``), 200, "")
	h.expect(h.call("PUT", "/v1/me/location", token, `{"latitude":12.97,"longitude":77.59}`), 200, "")
	h.expect(h.call("POST", "/v1/discover/nearby", token, `{}`), 200, "")
	// A member who has not onboarded is never listed, even if a location row exists.
	h.mustExec(`UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, sam)
	anjali := h.login(alice)
	h.mustExec(`INSERT INTO nearby_prefs(user_id,visible) VALUES($1,true)`, alice)
	h.mustExec(`INSERT INTO user_locations(user_id,latitude,longitude) VALUES($1,12.97,77.59)`, alice)
	got := h.expect(h.call("POST", "/v1/discover/nearby", anjali, `{}`), 200, "").data
	if len(items(got)) != 0 {
		t.Fatalf("a member who is not onboarded was listed: %v", got)
	}
}

func TestStoredLocationsExpireAfterSevenDays(t *testing.T) {
	h := newSocialHarness(t)
	for _, tc := range []struct {
		id  string
		age string
	}{{alice, "8 days"}, {bob, "6 days"}, {cara, "10 days"}, {dev, "1 hour"}} {
		h.place(tc.id, bengaluru.Latitude, bengaluru.Longitude)
		h.exec(`UPDATE user_locations SET updated_at=now()-$2::interval WHERE user_id=$1`, tc.id, tc.age)
	}
	week := time.Duration(domain.LocationRetentionDays) * 24 * time.Hour
	if domain.LocationRetentionDays != 7 || domain.LocationFreshHours != 24 {
		t.Fatalf("retention %d days, freshness %d hours", domain.LocationRetentionDays, domain.LocationFreshHours)
	}
	// Batches are bounded; the job loops until a batch is short.
	n, err := h.db.PurgeLocations(h.ctx, week, 1)
	if err != nil || n != 1 {
		t.Fatalf("first batch %d (%v)", n, err)
	}
	n, err = h.db.PurgeLocations(h.ctx, week, 100)
	if err != nil || n != 1 {
		t.Fatalf("second batch %d (%v)", n, err)
	}
	var left []string
	rows, err := h.db.Pool.Query(h.ctx, `SELECT user_id::text FROM user_locations ORDER BY user_id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		_ = rows.Scan(&id)
		left = append(left, id)
	}
	rows.Close()
	same(t, left, bob, dev)
	if n, err = h.db.PurgeLocations(h.ctx, week, 100); err != nil || n != 0 {
		t.Fatalf("a third purge removed %d (%v)", n, err)
	}
}
