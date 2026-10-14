package httpapi

import (
	"fmt"
	"testing"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// storedPoint reads what is stored for a member, as text so grid steps show exactly.
func (h *socialHarness) storedPoint(id string) string {
	h.t.Helper()
	var text string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT latitude::text||','||longitude::text FROM user_locations WHERE user_id=$1`, id).Scan(&text); err != nil {
		h.t.Fatal(err)
	}
	return text
}

// A minor's location is rounded to one decimal (about 11 km), an adult's to two, decided by the band when it is written.
func TestMinorLocationIsRoundedToOneDecimalAtWriteTime(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	h.ageAt(cara, 30)
	put := func(id string, lat, lon float64) {
		t.Helper()
		h.visible(id)
		h.fresh(id)
		h.expect(h.send(id, "PUT", "/v1/me/location", putLocation(lat, lon)), 200, "")
	}
	put(dev, 12.971634, 77.594566)
	put(cara, 12.971634, 77.594566)
	if got := h.storedPoint(dev); got != "13,77.6" {
		t.Fatalf("a minor's point is %s, want 13,77.6", got)
	}
	if got := h.storedPoint(cara); got != "12.97,77.59" {
		t.Fatalf("an adult's point is %s, want 12.97,77.59", got)
	}
	// Rounded to nearest from what was sent, also negative values and values that land on zero.
	for _, tc := range []struct {
		lat, lon float64
		want     string
	}{{-33.8688, 151.2093, "-33.9,151.2"}, {12.449, 77.451, "12.4,77.5"}, {-0.04, 0.049, "0,0"}, {89.96, -179.96, "90,-180"}} {
		put(dev, tc.lat, tc.lon)
		if got := h.storedPoint(dev); got != tc.want {
			t.Fatalf("%v,%v stored as %s, want %s", tc.lat, tc.lon, got, tc.want)
		}
	}
	// The band is read at write time: the same member writes a coarser point once they are a minor, and a finer
	// one again once they are an adult. Nothing is rounded again retroactively.
	put(cara, 12.971634, 77.594566)
	h.ageAt(cara, 17)
	if got := h.storedPoint(cara); got != "12.97,77.59" {
		t.Fatalf("changing band rewrote the stored point: %s", got)
	}
	put(cara, 12.971634, 77.594566)
	if got := h.storedPoint(cara); got != "13,77.6" {
		t.Fatalf("a member who is now a minor stored %s", got)
	}
	h.ageOffset(cara, 18, 0)
	put(cara, 12.971634, 77.594566)
	if got := h.storedPoint(cara); got != "12.97,77.59" {
		t.Fatalf("a member who turned 18 stored %s", got)
	}
	// Every minor row sits on the 0.1 grid, and the response says nothing about either.
	h.ageAt(cara, 15)
	put(cara, 1.2345, 2.3456)
	var off int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations l WHERE age_band(l.user_id)='minor' AND (abs(latitude*10-round(latitude*10))>1e-9 OR abs(longitude*10-round(longitude*10))>1e-9)`).Scan(&off); err != nil || off != 0 {
		t.Fatalf("%d minor rows off the 0.1 grid (%v)", off, err)
	}
	// Isolation off does not change how coarse a minor's location is.
	off2 := newSocialHarnessWith(t, store.WithAgeBandIsolation(false))
	off2.ageAt(dev, 15)
	off2.visible(dev)
	off2.fresh(dev)
	off2.expect(off2.send(dev, "PUT", "/v1/me/location", putLocation(12.971634, 77.594566)), 200, "")
	if got := off2.storedPoint(dev); got != "13,77.6" {
		t.Fatalf("with isolation off a minor stored %s", got)
	}
}

// Minors see only minors in Nearby, with distances in the coarser buckets 10, 25, 50 and 100; adults keep theirs.
func TestMinorNearbyShowsOnlyMinorsInCoarseBuckets(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{dev, eli, xan, yui} {
		h.ageAt(id, 15)
	}
	h.ageAt(cara, 30)
	// On the 0.1 grid, north of the viewer: 0, 11.1, 33.4 and 89 km, plus an adult in the same spot.
	h.place(dev, 13.0, 77.6)
	h.place(eli, 13.0, 77.6)
	h.place(xan, 13.1, 77.6)
	h.place(yui, 13.3, 77.6)
	h.place(alice, 13.0, 77.6)
	h.place(cara, 13.0, 77.6)
	h.place(bob, 13.0, 77.6)
	users, buckets := h.nearbyOK(dev, radius(100))
	same(t, users, eli, xan, yui)
	if fmt.Sprint(buckets) != "[10 25 50]" {
		t.Fatalf("a minor's buckets %v, want [10 25 50]", buckets)
	}
	h.place(yui, 13.8, 77.6)
	_, buckets = h.nearbyOK(dev, radius(100))
	if fmt.Sprint(buckets) != "[10 25 100]" {
		t.Fatalf("buckets %v", buckets)
	}
	// Nothing finer than a bucket from the set leaves the server: every distance is one of the four.
	for _, b := range buckets {
		found := false
		for _, allowed := range domain.MinorNearbyBuckets {
			found = found || b == allowed
		}
		if !found {
			t.Fatalf("bucket %d is not a minor bucket", b)
		}
	}
	// The adult viewer is unchanged: the adult buckets, and no minors.
	users, buckets = h.nearbyOK(alice, radius(100))
	same(t, users, bob, cara)
	if fmt.Sprint(buckets) != "[5 5]" {
		t.Fatalf("an adult's buckets %v", buckets)
	}
	// A cursor made for one set cannot carry a bucket of the other: 5 is an adult bucket only.
	tag := h.api.nearbyCentreTag(domain.Location{Latitude: 13.0, Longitude: 77.6})
	noFilters := nearbyQueryHash(mustFilters(t, `{}`))
	adultOnly := h.api.nearbySeal(nearbyCursor{User: dev, Radius: 25, Query: noFilters, Loc: tag, Bucket: 5, After: eli, Exp: 4102444800, Page: 1})
	got, _, _ := h.nearbyList(dev, map[string]any{"cursor": adultOnly})
	if got.status != 422 || got.code != "INVALID_CURSOR" {
		t.Fatalf("a minor accepted an adult bucket: %d %q", got.status, got.code)
	}
	// With isolation off the minor's buckets still follow the viewer, and adults are listed.
	off := newSocialHarnessWith(t, store.WithAgeBandIsolation(false))
	off.ageAt(dev, 15)
	off.ageAt(cara, 30)
	off.place(dev, 13.0, 77.6)
	off.place(cara, 13.0, 77.6)
	users, buckets = off.nearbyOK(dev, radius(100))
	if !slicesContain(users, cara) || buckets[0] != 10 {
		t.Fatalf("isolation off: %v %v", users, buckets)
	}
}
