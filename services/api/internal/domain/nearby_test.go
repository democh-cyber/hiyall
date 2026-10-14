package domain

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

func locationBody(raw string) map[string]json.RawMessage {
	var body map[string]json.RawMessage
	_ = json.Unmarshal([]byte(raw), &body)
	return body
}

func TestRoundingSnapsToTheGridBeforeAnythingIsStored(t *testing.T) {
	for _, tc := range []struct{ in, want float64 }{
		{12.971634, 12.97}, {77.594566, 77.59}, {-33.8688, -33.87}, {0.016, 0.02}, {0.004, 0},
		{-0.004, 0}, {89.996, 90}, {-179.996, -180}, {0, 0}, {1.005001, 1.01},
	} {
		if got := RoundCoordinate(tc.in); got != tc.want || math.Signbit(got) && got == 0 {
			t.Fatalf("RoundCoordinate(%v)=%v, want %v", tc.in, got, tc.want)
		}
		if again := RoundCoordinate(RoundCoordinate(tc.in)); again != tc.want {
			t.Fatalf("rounding is not idempotent for %v: %v", tc.in, again)
		}
	}
	got, err := ParseLocation(locationBody(`{"latitude":12.971634,"longitude":77.594566}`))
	if err != nil || got.Fine != (Location{12.97, 77.59}) || got.Coarse != (Location{13.0, 77.6}) {
		t.Fatalf("ParseLocation %+v (%v)", got, err)
	}
	// The point stored depends on the band: 2 decimals for adults, 1 for minors.
	if got.For(false) != (Location{12.97, 77.59}) || got.For(true) != (Location{13.0, 77.6}) {
		t.Fatalf("For %+v %+v", got.For(false), got.For(true))
	}
	// Rounding to one decimal is from the submitted value, not from the two-decimal point.
	edge, err := ParseLocation(locationBody(`{"latitude":12.449,"longitude":-0.04}`))
	if err != nil || edge.Coarse != (Location{12.4, 0}) || edge.Fine != (Location{12.45, -0.04}) {
		t.Fatalf("edge %+v (%v)", edge, err)
	}
}

func TestParseLocationAcceptsOnlyTwoFiniteNumbersInRange(t *testing.T) {
	for _, body := range []string{
		`{}`, `{"latitude":1}`, `{"longitude":1}`, `{"latitude":1,"longitude":2,"x":3}`,
		`{"latitude":"1","longitude":2}`, `{"latitude":null,"longitude":2}`, `{"latitude":true,"longitude":2}`,
		`{"latitude":[1],"longitude":2}`, `{"latitude":90.01,"longitude":0}`, `{"latitude":-90.01,"longitude":0}`,
		`{"latitude":0,"longitude":180.01}`, `{"latitude":0,"longitude":-180.01}`, `{"latitude":1e999,"longitude":0}`,
	} {
		if _, err := ParseLocation(locationBody(body)); err == nil {
			t.Errorf("accepted %s", body)
		} else if v, ok := err.(*ValidationError); !ok || strings.ContainsAny(v.Message, "0123456789") {
			t.Errorf("%s: error %v is not a plain validation message", body, err)
		}
	}
	for _, body := range []string{`{"latitude":90,"longitude":180}`, `{"latitude":-90,"longitude":-180}`, `{"latitude":0,"longitude":0}`, `{"latitude":-0.0,"longitude":1e2}`} {
		if _, err := ParseLocation(locationBody(body)); err != nil {
			t.Errorf("rejected %s: %v", body, err)
		}
	}
}

func TestParseNearbyRadius(t *testing.T) {
	for raw, want := range map[string]int{"5": 5, "10": 10, "15": 15, "25": 25, "50": 50, "100": 100} {
		if got, err := ParseNearbyRadius(raw); err != nil || got != want {
			t.Fatalf("%q: %d %v", raw, got, err)
		}
	}
	for _, raw := range []string{"", "0", "1", "2", "3", "4", "6", "24", "99", "-5", "101", "1.5", "05", "+5", " 5", "5 ", "1e1", "abc", "0x10", "99999999999999999999"} {
		if _, err := ParseNearbyRadius(raw); err == nil {
			t.Errorf("accepted %q", raw)
		}
	}
	if DefaultNearbyRadiusKm != 25 || MaxNearbyRadiusKm != 100 || MinNearbyRadiusKm != 5 {
		t.Fatal("radius bounds changed")
	}
}

func TestDistanceBucketsAreTheSmallestValueAtLeastTheDistance(t *testing.T) {
	for _, tc := range []struct {
		km   float64
		want int
	}{
		{0, 5}, {0.99, 5}, {1, 5}, {1.0001, 5}, {2, 5}, {2.5, 5}, {3, 5}, {3.01, 5}, {5, 5}, {5.01, 10}, {10, 10}, {10.5, 15}, {15, 15}, {16, 25}, {25, 25}, {25.1, 50}, {50, 50}, {50.1, 100}, {100, 100}, {250, 100},
	} {
		if got := DistanceBucket(tc.km); got != tc.want {
			t.Fatalf("DistanceBucket(%v)=%d, want %d", tc.km, got, tc.want)
		}
	}
}

func TestHaversineAgreesWithKnownDistances(t *testing.T) {
	// One degree of latitude is about 111.2 km on this sphere.
	if d := HaversineKm(Location{0, 0}, Location{1, 0}); math.Abs(d-111.195) > 0.01 {
		t.Fatalf("1 degree of latitude: %v km", d)
	}
	// Bengaluru to Chennai is roughly 290 km.
	if d := HaversineKm(Location{12.97, 77.59}, Location{13.08, 80.27}); d < 280 || d > 300 {
		t.Fatalf("Bengaluru to Chennai: %v km", d)
	}
	// Across the antimeridian the short way round is used.
	if d := HaversineKm(Location{0, 179.99}, Location{0, -179.99}); math.Abs(d-2.224) > 0.01 {
		t.Fatalf("across the antimeridian: %v km", d)
	}
	if d := HaversineKm(Location{90, 0}, Location{-90, 123}); math.Abs(d-math.Pi*EarthRadiusKm) > 0.01 {
		t.Fatalf("pole to pole: %v km", d)
	}
	if HaversineKm(Location{12.97, 77.59}, Location{12.97, 77.59}) != 0 {
		t.Fatal("same point is not zero")
	}
}

func TestNearbyBoxShapes(t *testing.T) {
	// Away from poles and the antimeridian the box is a plain rectangle.
	box := NearbyBox(Location{12.97, 77.59}, 25)
	if !box.LonLimited || box.Wrap || box.LatMin >= 12.97 || box.LatMax <= 12.97 || box.LonMin >= 77.59 || box.LonMax <= 77.59 {
		t.Fatalf("plain box %+v", box)
	}
	// It wraps near the antimeridian, from either side.
	if east := NearbyBox(Location{0.5, 179.99}, 50); !east.Wrap || !east.Contains(Location{0.5, -179.9}) || !east.Contains(Location{0.5, 179.8}) || east.Contains(Location{0.5, 0}) {
		t.Fatalf("east box %+v", east)
	}
	if west := NearbyBox(Location{0.5, -179.99}, 50); !west.Wrap || !west.Contains(Location{0.5, 179.9}) || !west.Contains(Location{0.5, -179.8}) || west.Contains(Location{0.5, 0}) {
		t.Fatalf("west box %+v", west)
	}
	// Within reach of a pole only latitude limits it; a little farther away longitude does again.
	if b := NearbyBox(Location{89, -170}, 100); !b.LonLimited {
		t.Fatalf("89 degrees is out of reach of the pole at 100 km: %+v", b)
	}
	for _, c := range []Location{{89.9, 10}, {-90, 0}, {89.2, -170}, {-89.2, 123}} {
		if b := NearbyBox(c, 100); b.LonLimited {
			t.Fatalf("polar box %+v for %+v", b, c)
		}
	}
	// It never leaves the valid latitude range.
	if b := NearbyBox(Location{89.99, 0}, 100); b.LatMax != 90 {
		t.Fatalf("latitude overflow %+v", b)
	}
}

func TestParseNearbyRequestSharesPeopleSearchRules(t *testing.T) {
	req, err := ParseNearbyRequest(locationBody(`{}`))
	if err != nil || req.RadiusKm != 25 || req.Filters.Country != "" || req.Filters.Interests == nil || req.Filters.Languages == nil {
		t.Fatalf("empty body %+v (%v)", req, err)
	}
	req, err = ParseNearbyRequest(locationBody(`{"radiusKm":10,"interests":["Music"],"languages":["EN"],"country":"IN","vibe":" Chill ","cursor":"abc"}`))
	if err != nil || req.RadiusKm != 10 || req.Filters.Languages[0] != "en" || req.Filters.Vibe != "Chill" || req.Filters.Country != "IN" || req.Filters.Cursor != "abc" {
		t.Fatalf("full body %+v (%v)", req, err)
	}
	// Anything people search refuses is refused here, and so is anything it does not know.
	for _, body := range []string{
		`{"radiusKm":0}`, `{"radiusKm":101}`, `{"radiusKm":"25"}`, `{"radiusKm":25.5}`, `{"radiusKm":null}`, `{"radiusKm":5e0}`,
		`{"interests":null}`, `{"languages":["x"]}`, `{"country":"in"}`, `{"vibe":null}`, `{"cursor":1}`,
		`{"minAge":12}`, `{"latitude":1,"longitude":2}`, `{"radius":5}`,
	} {
		if _, err := ParseNearbyRequest(locationBody(body)); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
}

func TestNearbyRadiusForWidensAMinorsRadiusToTheirBuckets(t *testing.T) {
	for _, tc := range []struct {
		minor  bool
		in, to int
	}{{false, 5, 5}, {false, 15, 15}, {true, 5, 10}, {true, 10, 10}, {true, 15, 25}, {true, 25, 25}, {true, 100, 100}} {
		if got := NearbyRadiusFor(tc.minor, tc.in); got != tc.to {
			t.Errorf("NearbyRadiusFor(%v,%d)=%d, want %d", tc.minor, tc.in, got, tc.to)
		}
	}
}
