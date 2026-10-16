package httpapi

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"testing"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// storedLocation is a member's stored point as numbers.
func (h *socialHarness) storedLocation(id string) domain.Location {
	h.t.Helper()
	var l domain.Location
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT latitude,longitude FROM user_locations WHERE user_id=$1`, id).Scan(&l.Latitude, &l.Longitude); err != nil {
		h.t.Fatal(err)
	}
	return l
}

// unpinned turns Nearby on with NO pinned offset, as production does: the offset comes from the key.
func (h *socialHarness) unpinned(id string) {
	h.t.Helper()
	h.exec(`INSERT INTO nearby_prefs(user_id,visible) VALUES($1,true) ON CONFLICT(user_id) DO UPDATE SET visible=true,offset_day=NULL,offset_north_km=0,offset_east_km=0`, id)
}

// The member's offset is derived, not stored: the columns stay empty, the same point is stored on every
// write and on every "day", and it sits within the offset radius plus a cell of the true point.
func TestStableOffsetIsDerivedFixedAndMovesTheStoredPoint(t *testing.T) {
	store.SetNearbyOffsetKey([]byte("0123456789abcdef0123456789abcdef"))
	h := newSocialHarness(t)
	h.unpinned(alice)
	h.unpinned(dev)
	h.ageAt(dev, 15)
	truth := domain.Location{Latitude: 12.9716, Longitude: 77.5946}
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(truth.Latitude, truth.Longitude)), 200, "")
	first := h.storedLocation(alice)
	if n := h.count(`SELECT count(*) FROM nearby_prefs WHERE user_id=$1 AND offset_day IS NULL AND offset_north_km=0 AND offset_east_km=0`, alice); n != 1 {
		t.Fatal("the derived offset was written to the row")
	}
	if d := domain.HaversineKm(domain.RoundLocation(truth.Latitude, truth.Longitude), first); d > domain.NearbyOffsetKm+1.6 {
		t.Fatalf("stored point is %.2f km from the rounded true point", d)
	}
	// Forty days of updates from the same place: always the same stored point, whatever the clock says.
	for day := 0; day < 40; day++ {
		h.exec(`UPDATE user_locations SET updated_at=now()-make_interval(days=>$2::int) WHERE user_id=$1`, alice, day)
		h.exec(`DELETE FROM member_daily_counts WHERE user_id=$1`, alice)
		h.api.locations.reset(alice)
		h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(truth.Latitude, truth.Longitude)), 200, "")
		if got := h.storedLocation(alice); got != first {
			t.Fatalf("day %d: the stored point moved from %v to %v", day, first, got)
		}
	}
	// A minor is moved by up to 5 km and stored on the coarse grid.
	h.expect(h.send(dev, "PUT", "/v1/me/location", putLocation(truth.Latitude, truth.Longitude)), 200, "")
	if d := domain.HaversineKm(domain.RoundLocationTo(truth, domain.MinorLocationDecimals), h.storedLocation(dev)); d > domain.MinorNearbyOffsetKm+8 {
		t.Fatalf("a minor's stored point is %.1f km from the rounded true point", d)
	}
}

// The attack the stable offset answers: submit and search again and again, average what comes back. A
// random daily offset averages out to the true position; a fixed one never does. The average of thirty
// slightly different true positions converges on the same point the first write stored, which is the
// true position plus the member's secret offset: it never gets closer to the truth than the offset is.
func TestAveragingManyDaysDoesNotConvergeOnTheTruePosition(t *testing.T) {
	key := []byte("0123456789abcdef0123456789abcdef")
	var userKey []byte
	// A member whose offset is at least 1.2 km, so the difference between "true" and "stored" is measurable.
	for i := 0; i < 50 && userKey == nil; i++ {
		k := []byte(fmt.Sprintf("averaging-test-key-%032d", i))[:32]
		off := domain.StableOffset(k, alice, domain.NearbyOffsetKm)
		if math.Hypot(off.NorthKm, off.EastKm) >= 1.2 {
			userKey = k
		}
	}
	if userKey == nil {
		t.Fatal("no key with a large offset in 50 tries")
	}
	store.SetNearbyOffsetKey(userKey)
	t.Cleanup(func() { store.SetNearbyOffsetKey(key) })
	h := newSocialHarness(t)
	h.unpinned(alice)
	off := domain.StableOffset(userKey, alice, domain.NearbyOffsetKm)
	truth := domain.Location{Latitude: 12.9716, Longitude: 77.5946}
	var sumLat, sumLon float64
	const days = 60
	for day := 0; day < days; day++ {
		// A member standing in roughly the same place: the phone's fix wanders by ~100 m.
		jitterLat := float64(day%7-3) * 0.0004
		jitterLon := float64(day%5-2) * 0.0004
		h.fresh(alice)
		h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(truth.Latitude+jitterLat, truth.Longitude+jitterLon)), 200, "")
		l := h.storedLocation(alice)
		sumLat += l.Latitude
		sumLon += l.Longitude
	}
	mean := domain.Location{Latitude: sumLat / days, Longitude: sumLon / days}
	toTruth := domain.HaversineKm(mean, truth)
	toOffsetTruth := domain.HaversineKm(mean, truth.Shift(off))
	t.Logf("offset %.2f km; mean of %d days is %.2f km from the truth and %.2f km from truth+offset", math.Hypot(off.NorthKm, off.EastKm), days, toTruth, toOffsetTruth)
	if toTruth < 0.4 {
		t.Fatalf("averaging %d days landed %.2f km from the true position: the offset is not hiding it", days, toTruth)
	}
	if toOffsetTruth > 0.9 {
		t.Fatalf("the average should settle on the true point plus the stable offset, but is %.2f km from it", toOffsetTruth)
	}
}

func TestOffsetDependsOnTheMemberAndTheKeyOnly(t *testing.T) {
	k1, k2 := []byte("0123456789abcdef0123456789abcdef"), []byte("fedcba9876543210fedcba9876543210")
	a1, a2 := domain.StableOffset(k1, alice, 2), domain.StableOffset(k2, alice, 2)
	b1 := domain.StableOffset(k1, bob, 2)
	if a1 == a2 || a1 == b1 {
		t.Fatalf("offsets collide: %v %v %v", a1, a2, b1)
	}
	if domain.StableOffset(k1, alice, 2) != a1 {
		t.Fatal("not deterministic")
	}
	for i := 0; i < 500; i++ {
		o := domain.StableOffset(k1, fmt.Sprintf("member-%d", i), 5)
		if math.Hypot(o.NorthKm, o.EastKm) > 5+1e-9 {
			t.Fatalf("offset %v outside the 5 km disc", o)
		}
	}
	// A new key moves the stored point once, at the member's next update.
	store.SetNearbyOffsetKey(k1)
	h := newSocialHarness(t)
	h.unpinned(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "")
	before := h.storedLocation(alice)
	store.SetNearbyOffsetKey(k2)
	t.Cleanup(func() { store.SetNearbyOffsetKey(k1) })
	h.fresh(alice)
	h.expect(h.send(alice, "PUT", "/v1/me/location", putLocation(12.9716, 77.5946)), 200, "")
	if after := h.storedLocation(alice); after == before && math.Hypot(a1.NorthKm-a2.NorthKm, a1.EastKm-a2.EastKm) > 3 {
		t.Fatal("a new key did not change the stored point")
	}
}

// expectPolicy asserts err is a policy refusal with the status and code.
func (h *socialHarness) expectPolicy(err error, status int, code string) {
	h.t.Helper()
	var p *domain.PolicyError
	if !errors.As(err, &p) || p.Status != status || p.Code != code {
		h.t.Fatalf("got %v, want %d %s", err, status, code)
	}
}

// An account may search from 10 different centres a day; the 11th is refused, a centre already used is free.
func TestNearbyProbesAreCappedPerAccountPerDay(t *testing.T) {
	h := newSocialHarness(t)
	h.withCaps(func(e *domain.Entitlements) { e.NearbyQueriesPerDay = 500 })
	h.exec(`DELETE FROM nearby_probe_centres`)
	h.visible(alice)
	centre := func(i int) { h.place(alice, bengaluru.Latitude+float64(i)*0.1, bengaluru.Longitude) }
	search := func(km int) reply {
		h.api.search.reset(alice) // the per-minute search limiter is not under test
		return h.send(alice, "POST", "/v1/discover/nearby", radius(km))
	}
	for i := 0; i < domain.NearbyCentresPerAccount; i++ {
		centre(i)
		h.expect(search(5), 200, "")
	}
	centre(domain.NearbyCentresPerAccount)
	h.expect(search(5), 429, "DAILY_LIMIT")
	// Back at a centre already used today: free, and again as often as asked.
	centre(3)
	h.expect(search(5), 200, "")
	h.expect(search(10), 200, "")
	// Tomorrow the count starts again.
	h.exec(`UPDATE nearby_probe_centres SET day=day-1`)
	centre(domain.NearbyCentresPerAccount)
	h.expect(search(5), 200, "")
}

// The address cap counts ACCOUNTS, not centres: a shared network where many people search from different places
// works, and an address that drives too many accounts is stopped. The table keeps neither the account nor the address.
func TestNearbyProbesAreCappedPerSourceAddress(t *testing.T) {
	h := newSocialHarness(t)
	ctx := h.ctx
	h.exec(`DELETE FROM nearby_probe_centres`)
	for i := 0; i < 5; i++ {
		// Five different accounts behind one address, at most 4 accounts allowed.
		user := fmt.Sprintf("user-%d", i)
		err := h.db.CountNearbyProbe(ctx, user, "203.0.113.7", fmt.Sprintf("centre-%d", i), 10, 4)
		if i < 4 && err != nil {
			t.Fatalf("account %d refused: %v", i, err)
		}
		if i == 4 {
			h.expectPolicy(err, 429, "DAILY_LIMIT")
		}
	}
	// A refused probe leaves no half record: the account's own insert rolled back with it.
	if n := h.count(`SELECT count(*) FROM nearby_probe_centres`); n != 8 {
		t.Fatalf("%d rows, want 4 account rows + 4 address rows", n)
	}
	// A counted account is free to search from many centres at the same address, and to come back.
	for i := 0; i < 8; i++ {
		if err := h.db.CountNearbyProbe(ctx, "user-0", "203.0.113.7", fmt.Sprintf("other-%d", i), 10, 4); err != nil {
			t.Fatalf("a counted account refused at centre %d: %v", i, err)
		}
	}
	// Another address is unaffected.
	if err := h.db.CountNearbyProbe(ctx, "user-9", "203.0.113.8", "centre-0", 10, 4); err != nil {
		t.Fatal(err)
	}
	// Nothing readable is stored.
	var text string
	h.db.Pool.QueryRow(ctx, `SELECT string_agg(encode(subject,'escape')||encode(centre,'escape'),'') FROM nearby_probe_centres`).Scan(&text)
	if strings.Contains(text, "203.0.113") || strings.Contains(text, "user-") || strings.Contains(text, "centre-") {
		t.Fatalf("the probe table holds identifiers: %q", text)
	}
	if n, err := h.db.PurgeNearbyProbes(ctx, 0, 100); err != nil || n != 0 {
		t.Fatalf("today's rows purged: %d %v", n, err)
	}
	h.exec(`UPDATE nearby_probe_centres SET day=day-5`)
	if n, err := h.db.PurgeNearbyProbes(ctx, 3, 100); err != nil || n != 18 {
		t.Fatalf("old rows: %d %v", n, err)
	}
}
