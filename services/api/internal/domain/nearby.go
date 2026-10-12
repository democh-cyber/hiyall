package domain

import (
	"encoding/json"
	"math"
	"strconv"
)

// Nearby is deliberately coarse. A member opts in by sending a location, the
// server rounds it to a ~1.1 km grid before it is stored, the stored point
// expires, and other members only ever see a distance bucket, never a point.

const (
	// LocationDecimals is the number of decimal places kept in a stored coordinate.
	LocationDecimals = 2
	// LocationFreshHours is how long a stored location counts as "sharing".
	LocationFreshHours = 24
	// LocationRetentionDays is when the maintenance job deletes stored locations.
	LocationRetentionDays = 7
	// DefaultNearbyRadiusKm and MaxNearbyRadiusKm bound the search radius.
	DefaultNearbyRadiusKm = 25
	MaxNearbyRadiusKm     = 100
	// EarthRadiusKm is the sphere used by every distance calculation, in Go and SQL.
	EarthRadiusKm = 6371.0
)

// NearbyBuckets are the only distances a member is ever shown, in km.
var NearbyBuckets = []int{1, 2, 3, 5, 10, 15, 25, 50, 100}

var ErrLocationNotShared = &PolicyError{409, "LOCATION_NOT_SHARED", "Share your location to see people nearby."}

// Location is a stored, already rounded point. It never leaves the server.
type Location struct{ Latitude, Longitude float64 }

// RoundCoordinate rounds one coordinate to the adult storage grid (LocationDecimals).
func RoundCoordinate(v float64) float64 { return RoundCoordinateTo(v, LocationDecimals) }

// RoundCoordinateTo rounds to the given number of decimals. It also turns -0 into 0.
func RoundCoordinateTo(v float64, decimals int) float64 {
	scale := math.Pow(10, float64(decimals))
	r := math.Round(v*scale) / scale
	if r == 0 {
		return 0
	}
	return r
}

// RoundLocation snaps a point to the adult storage grid.
func RoundLocation(lat, lon float64) Location {
	return Location{RoundCoordinate(lat), RoundCoordinate(lon)}
}

// LocationInput is a validated point at both storage precisions. The adult grid
// (Fine) and the minor grid (Coarse, MinorLocationDecimals) are both computed from
// the submitted value, which is not kept: the store chooses by the member's band at
// write time, so a precise coordinate never leaves the parser.
type LocationInput struct{ Fine, Coarse Location }

// For is the point to store for a member of the given band.
func (in LocationInput) For(minor bool) Location {
	if minor {
		return RoundLocationTo(in.Coarse, MinorLocationDecimals)
	}
	return RoundLocationTo(in.Fine, LocationDecimals)
}

// RoundLocationTo rounds both coordinates to the given number of decimals.
func RoundLocationTo(l Location, decimals int) Location {
	return Location{RoundCoordinateTo(l.Latitude, decimals), RoundCoordinateTo(l.Longitude, decimals)}
}

// ParseLocation reads the body of PUT /v1/me/location: exactly two finite
// numbers in range. The result carries only rounded points, so callers cannot
// store, log or echo the precise value by accident.
func ParseLocation(body map[string]json.RawMessage) (LocationInput, error) {
	var out [2]float64
	for i, name := range []string{"latitude", "longitude"} {
		raw, ok := body[name]
		if !ok {
			return LocationInput{}, invalid(name, "is required")
		}
		var v float64
		if string(raw) == "null" || json.Unmarshal(raw, &v) != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			return LocationInput{}, invalid(name, "must be a number")
		}
		limit := 90.0
		if name == "longitude" {
			limit = 180
		}
		if v < -limit || v > limit {
			return LocationInput{}, invalid(name, "is out of range")
		}
		out[i] = v
	}
	for name := range body {
		if name != "latitude" && name != "longitude" {
			// The key is not repeated: it is client input, and this endpoint echoes nothing it was sent.
			return LocationInput{}, invalid("body", "only latitude and longitude are accepted")
		}
	}
	return LocationInput{
		Fine:   Location{RoundCoordinateTo(out[0], LocationDecimals), RoundCoordinateTo(out[1], LocationDecimals)},
		Coarse: Location{RoundCoordinateTo(out[0], MinorLocationDecimals), RoundCoordinateTo(out[1], MinorLocationDecimals)},
	}, nil
}

// ParseNearbyRadius reads a present radiusKm value: the text of a plain integer
// from 1 to 100 with no sign, space, decimal point, exponent or leading zero. A
// JSON string or null never matches, because its raw text carries quotes or letters.
func ParseNearbyRadius(raw string) (int, error) {
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > MaxNearbyRadiusKm || strconv.Itoa(n) != raw {
		return 0, invalid("radiusKm", "must be a whole number from 1 to 100")
	}
	return n, nil
}

// NearbyRequest is the body of POST /v1/discover/nearby: a radius and the same
// filters people search takes. Every key is optional.
type NearbyRequest struct {
	RadiusKm int
	Filters  PeopleFilters
}

// ParseNearbyRequest reads the body. radiusKm is taken here; every other key,
// including the cursor, goes through ParsePeopleFilters so Nearby validates
// interests, languages, country, vibe and cursor exactly as people search does,
// and an unknown key (a position, an age, an email) is refused.
func ParseNearbyRequest(body map[string]json.RawMessage) (NearbyRequest, error) {
	req := NearbyRequest{RadiusKm: DefaultNearbyRadiusKm}
	rest := make(map[string]json.RawMessage, len(body))
	for key, raw := range body {
		if key != "radiusKm" {
			rest[key] = raw
			continue
		}
		radius, err := ParseNearbyRadius(string(raw))
		if err != nil {
			return req, err
		}
		req.RadiusKm = radius
	}
	filters, err := ParsePeopleFilters(rest)
	if err != nil {
		return req, err
	}
	req.Filters = filters
	return req, nil
}

// HaversineKm is the great-circle distance between two points on the sphere
// used throughout. The SQL in the store computes the same expression.
func HaversineKm(a, b Location) float64 {
	rad := math.Pi / 180
	dLat := (b.Latitude - a.Latitude) * rad
	dLon := (b.Longitude - a.Longitude) * rad
	h := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(a.Latitude*rad)*math.Cos(b.Latitude*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * EarthRadiusKm * math.Asin(math.Min(1, math.Sqrt(h)))
}

// DistanceBucket is the smallest bucket that is at least km. A distance beyond
// the last bucket is clamped to it; searches never reach that far.
func DistanceBucket(km float64) int { return DistanceBucketIn(NearbyBuckets, km) }

// DistanceBucketIn is DistanceBucket over a given bucket set (see NearbyBucketsFor).
func DistanceBucketIn(buckets []int, km float64) int {
	for _, b := range buckets {
		if km <= float64(b) {
			return b
		}
	}
	return buckets[len(buckets)-1]
}

// BoundingBox is a cheap prefilter around a point. It only has to be a superset
// of the circle; the exact haversine decides. When the circle reaches a pole no
// longitude limit exists (LonLimited is false) and only latitude filters.
// When the longitude range crosses the antimeridian, Wrap is true and a
// longitude matches when it is >= LonMin or <= LonMax.
type BoundingBox struct {
	LatMin, LatMax float64
	LonMin, LonMax float64
	LonLimited     bool
	Wrap           bool
}

// NearbyBox returns the prefilter for radiusKm around centre. A small margin
// absorbs rounding so the box never drops a point the haversine would keep.
func NearbyBox(centre Location, radiusKm int) BoundingBox {
	angle := float64(radiusKm)/EarthRadiusKm*1.01 + 1e-6 // radians, with margin
	dLat := angle * 180 / math.Pi
	box := BoundingBox{LatMin: math.Max(-90, centre.Latitude-dLat), LatMax: math.Min(90, centre.Latitude+dLat)}
	// The circle contains a pole (or comes too close to treat longitude as
	// bounded) when its angular radius reaches it.
	if math.Abs(centre.Latitude)*math.Pi/180+angle >= math.Pi/2-1e-6 {
		return box
	}
	dLon := math.Asin(math.Min(1, math.Sin(angle)/math.Cos(centre.Latitude*math.Pi/180))) * 180 / math.Pi
	box.LonLimited = true
	box.LonMin, box.LonMax = centre.Longitude-dLon, centre.Longitude+dLon
	switch {
	case box.LonMin < -180:
		box.Wrap = true
		box.LonMin += 360
	case box.LonMax > 180:
		box.Wrap = true
		box.LonMax -= 360
	}
	return box
}

// Contains reports whether the box admits a point. It mirrors the SQL prefilter
// and is used by tests to check the box against the exact distance.
func (b BoundingBox) Contains(p Location) bool {
	if p.Latitude < b.LatMin || p.Latitude > b.LatMax {
		return false
	}
	if !b.LonLimited {
		return true
	}
	if b.Wrap {
		return p.Longitude >= b.LonMin || p.Longitude <= b.LonMax
	}
	return p.Longitude >= b.LonMin && p.Longitude <= b.LonMax
}
