package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Locations are coarse and expiring. The point is rounded before it is written, to a
// ~1.1 km grid for adults and a ~11 km grid for minors (the member's band at write
// time), so a precise position never reaches the database, a log line or an outbox
// event. A row updated within the last 24 hours means the member is sharing; the
// maintenance job deletes rows after 7 days.

// SetLocation stores the member's point and returns when it was stored. The member must have turned on
// "Show me in Nearby" (ErrNearbyOff otherwise). The submitted point is moved by the member's daily random
// offset (rotated when the stored offset is not from today, UTC), then rounded to the precision of the
// member's age band at write time, so neither a precise position nor the member's true grid cell is ever
// stored. A write that lands in the cell already stored only refreshes its time. Any other write counts as
// a location change against e.LocationChangesPerDay and is refused when it is faster than
// domain.MaxTravelKmh from the last stored point (domain.ErrLocationJump): together they stop a script from
// walking spoofed centres around a member to find them.
func (s *Store) SetLocation(ctx context.Context, userID string, in domain.LocationInput, e domain.Entitlements) (time.Time, error) {
	var updated time.Time
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockQuota(ctx, tx, "location", userID); err != nil {
			return err
		}
		var visible, minor bool
		var day *time.Time
		var north, east float64
		err := tx.QueryRow(ctx, `SELECT p.visible,p.offset_day,p.offset_north_km,p.offset_east_km,age_band(u.user_id)=$2
 FROM nearby_prefs p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status='active' FOR UPDATE OF p`, userID, domain.BandMinor).Scan(&visible, &day, &north, &east, &minor)
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNearbyOff
		}
		if err != nil {
			return err
		}
		if !visible {
			return domain.ErrNearbyOff
		}
		now := time.Now().UTC()
		today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		if day == nil || !day.UTC().Equal(today) {
			radius := domain.NearbyOffsetKm
			if minor {
				radius = domain.MinorNearbyOffsetKm
			}
			off := randomOffset(radius)
			north, east = off.NorthKm, off.EastKm
			if _, err = tx.Exec(ctx, `UPDATE nearby_prefs SET offset_day=$2::date,offset_north_km=$3,offset_east_km=$4 WHERE user_id=$1`, userID, today.Format(time.DateOnly), north, east); err != nil {
				return err
			}
		}
		decimals := domain.LocationDecimals
		if minor {
			decimals = domain.MinorLocationDecimals
		}
		point := domain.RoundLocationTo(in.For(minor).Shift(domain.Offset{NorthKm: north, EastKm: east}), decimals)
		var prev domain.Location
		var prevAt time.Time
		err = tx.QueryRow(ctx, `SELECT latitude,longitude,updated_at FROM user_locations WHERE user_id=$1 FOR UPDATE`, userID).Scan(&prev.Latitude, &prev.Longitude, &prevAt)
		had := err == nil
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		fresh := had && now.Sub(prevAt) < domain.LocationFreshHours*time.Hour
		if !(fresh && prev == point) {
			if had && domain.ImplausibleJump(prev, point, now.Sub(prevAt)) {
				return domain.ErrLocationJump
			}
			if err = bumpDaily(ctx, tx, userID, domain.DailyLocationChanges, e.LocationChangesPerDay); err != nil {
				return err
			}
		}
		return tx.QueryRow(ctx, `INSERT INTO user_locations(user_id,latitude,longitude,updated_at) VALUES($1,$2,$3,now())
 ON CONFLICT(user_id) DO UPDATE SET latitude=excluded.latitude,longitude=excluded.longitude,updated_at=excluded.updated_at
 RETURNING updated_at`, userID, point.Latitude, point.Longitude).Scan(&updated)
	})
	if err != nil {
		return time.Time{}, mapped(err)
	}
	return updated, nil
}

// LocationSharing reports whether the member is sharing now and when the shared
// point was stored. It never returns coordinates. updatedAt is nil unless sharing.
func (s *Store) LocationSharing(ctx context.Context, userID string) (bool, *time.Time, error) {
	var updated *time.Time
	err := s.Pool.QueryRow(ctx, `SELECT l.updated_at FROM user_locations l JOIN users u USING(user_id) WHERE l.user_id=$1 AND u.status='active' AND l.updated_at>now()-make_interval(hours=>$2::int)`, userID, domain.LocationFreshHours).Scan(&updated)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil, nil
	}
	if err != nil {
		return false, nil, err
	}
	return true, updated, nil
}

// StopSharingLocation deletes the member's point. It is idempotent, and the
// member leaves everyone's Nearby results at once.
func (s *Store) StopSharingLocation(ctx context.Context, userID string) error {
	_, err := s.Pool.Exec(ctx, `DELETE FROM user_locations WHERE user_id=$1`, userID)
	return err
}

// OwnLocation is the caller's fresh stored point, used only as the centre of a Nearby search, and whether
// the caller is a minor (which decides their distance buckets). A member who is not visible cannot search
// (domain.ErrNearbyOff: you must be in Nearby to see Nearby); it is ErrLocationNotShared when none is
// stored or it has expired.
func (s *Store) OwnLocation(ctx context.Context, userID string) (loc domain.Location, minor bool, err error) {
	var visible bool
	var lat, lon *float64
	err = s.Pool.QueryRow(ctx, `SELECT coalesce(np.visible,false),l.latitude,l.longitude,age_band(u.user_id)=$3
 FROM users u LEFT JOIN nearby_prefs np ON np.user_id=u.user_id
 LEFT JOIN user_locations l ON l.user_id=u.user_id AND l.updated_at>now()-make_interval(hours=>$2::int)
 WHERE u.user_id=$1 AND u.status='active'`, userID, domain.LocationFreshHours, domain.BandMinor).Scan(&visible, &lat, &lon, &minor)
	if errors.Is(err, pgx.ErrNoRows) {
		return loc, false, domain.ErrNotFound
	}
	if err != nil {
		return loc, false, err
	}
	if !visible {
		return loc, minor, domain.ErrNearbyOff
	}
	if lat == nil || lon == nil {
		return loc, minor, domain.ErrLocationNotShared
	}
	return domain.Location{Latitude: *lat, Longitude: *lon}, minor, nil
}

// PurgeLocations deletes stored locations not refreshed within retain, at most
// batch rows per call.
func (s *Store) PurgeLocations(ctx context.Context, retain time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM user_locations WHERE ctid IN (SELECT ctid FROM user_locations WHERE updated_at<now()-$1::interval ORDER BY updated_at LIMIT $2)`, retain, batch)
	return tag.RowsAffected(), err
}

// NearbyAfter is the keyset position of a Nearby page: the last distance bucket
// and user id already returned. A zero value starts at the beginning.
type NearbyAfter struct {
	Bucket int
	UserID string
}

// Distances are bucketed in SQL with the same boundaries as domain.NearbyBuckets (and, for a
// viewer who is a minor, domain.MinorNearbyBuckets), and
// nearbySQL uses the same sphere (6371.0 km) as domain.EarthRadiusKm; tests compare
// the two against a reference implementation.
const nearbyBucketSQL = `CASE WHEN $23::boolean THEN CASE WHEN km<=10 THEN 10 WHEN km<=25 THEN 25 WHEN km<=50 THEN 50 ELSE 100 END
 ELSE CASE WHEN km<=5 THEN 5 WHEN km<=10 THEN 10 WHEN km<=15 THEN 15 WHEN km<=25 THEN 25 WHEN km<=50 THEN 50 ELSE 100 END END`

// nearbySQL finds members whose fresh stored point lies within the radius of the
// caller's. The bounding box on (latitude, longitude) bounds the rows the exact
// haversine has to look at; it is a superset of the circle, so it never changes
// the answer. The box, the distance and the barrier (blocks and age bands) are
// evaluated first, once per nearby row, in a materialized step that PostgreSQL cannot
// reorder: the planner has no statistics for the settings stored as JSON, so left alone
// it can start from every discoverable member in the system instead of from the few
// who are nearby, and an expensive barrier check would be repeated for every pairing.
// The settings are then read by key from a fenced (OFFSET 0) lateral subquery, which
// cannot be turned into a join over all members. Parameters: $1
// viewer, $2/$3 caller latitude/longitude, $4 radius km, $5/$6 box latitude
// min/max, $7 box is longitude limited, $8 box wraps the antimeridian, $9/$10 box
// longitude min/max, $11/$12 keyset bucket and user id, $13 limit, $14 freshness
// hours, $15 to $22 the filters (see peopleFilterSQL), $23 whether the viewer is a minor.
//
// Rows come back ordered by distance bucket and then user id. Ordering by the
// bucket (the only distance a member is ever shown) rather than the exact
// distance means neither the order nor the keyset cursor can reveal anything
// finer than the bucket.
var nearbySQLBase = `
WITH within AS MATERIALIZED (
 SELECT c.user_id,` + nearbyBucketSQL + ` AS bucket FROM (
  SELECT l.user_id,
   2*6371.0*asin(least(1,sqrt(power(sin(radians(l.latitude-$2::float8)/2),2)+cos(radians($2::float8))*cos(radians(l.latitude))*power(sin(radians(l.longitude-$3::float8)/2),2)))) AS km
  FROM user_locations l
  WHERE l.user_id<>$1::uuid AND l.updated_at>now()-make_interval(hours=>$14::int)
  AND EXISTS(SELECT 1 FROM nearby_prefs np WHERE np.user_id=l.user_id AND np.visible)
  AND l.latitude BETWEEN $5::float8 AND $6::float8
  AND (NOT $7::boolean OR CASE WHEN $8::boolean THEN (l.longitude>=$9::float8 OR l.longitude<=$10::float8) ELSE l.longitude BETWEEN $9::float8 AND $10::float8 END)
 ) c WHERE c.km<=$4::float8 AND NOT interaction_barred($1::uuid,c.user_id)
)
SELECT p.user_id::text,p.username,p.data,q.data,w.bucket,` + avatarThumbKey("av") + `
FROM within w
JOIN users u ON u.user_id=w.user_id AND u.status='active'
JOIN onboarding o ON o.user_id=w.user_id AND o.completed_at IS NOT NULL
JOIN profiles p ON p.user_id=w.user_id
JOIN LATERAL (SELECT s.data FROM privacy_settings s WHERE s.user_id=w.user_id AND s.data->>'discoverable'='true' AND s.data->>'profileAudience'='public' OFFSET 0) q ON true` + avatarJoin("av", "p") + `
WHERE (w.bucket,w.user_id)>($11::int,$12::uuid)
`

// nearbySQL adds the people-search filters ($15 to $22: country, vibe, interests, languages,
// age minimum, age maximum, gender, online) before the order and the limit.
var nearbySQL = nearbySQLBase + peopleFilterSQL(15) + ` ORDER BY w.bucket,w.user_id LIMIT $13`

// NearbyPeople lists discoverable members near centre, nearest bucket first.
// Eligibility is the same as people search: active, onboarded, discoverable,
// public, not the viewer, and not blocked in either direction. Fields follow the
// member's own audiences, and f narrows the list exactly as in people search
// (same predicates, see peopleFilterSQL). Each item carries a distanceKm bucket
// and nothing finer: no coordinates, grid cells or exact distances leave this
// function.
func (s *Store) NearbyPeople(ctx context.Context, viewer string, centre domain.Location, minorViewer bool, radiusKm int, f domain.PeopleFilters, after NearbyAfter, limit int, online Presence, sign Signer) ([]map[string]any, error) {
	if minorViewer && f.UsesAgeOrGender() {
		return nil, domain.ErrFilterNotAvailable
	}
	if ageFilterCannotMatch(s.AgeBandIsolation, minorViewer, f) {
		return []map[string]any{}, nil
	}
	mine, err := s.viewerInterests(ctx, viewer)
	if err != nil {
		return nil, err
	}
	box := domain.NearbyBox(centre, radiusKm)
	afterID := after.UserID
	if afterID == "" {
		afterID = "00000000-0000-0000-0000-000000000000"
	}
	args := append([]any{viewer, centre.Latitude, centre.Longitude, float64(radiusKm), box.LatMin, box.LatMax, box.LonLimited, box.Wrap, box.LonMin, box.LonMax, after.Bucket, afterID, limit, domain.LocationFreshHours}, peopleFilterArgs(f).list()...)
	rows, err := s.Pool.Query(ctx, nearbySQL, append(args, minorViewer)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	var audiences []string
	for rows.Next() {
		var id, username string
		var data, policy []byte
		var bucket int
		var avatar *string
		if err = rows.Scan(&id, &username, &data, &policy, &bucket, &avatar); err != nil {
			return nil, err
		}
		var p domain.Profile
		var q domain.Privacy
		if err = json.Unmarshal(data, &p); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(policy, &q); err != nil {
			return nil, err
		}
		item := discoveryItem(id, username, p, q, avatarURL(sign, avatar), mine)
		item["distanceKm"] = bucket
		result = append(result, item)
		audiences = append(audiences, q.OnlineAudience)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	return result, s.addPresence(ctx, viewer, result, audiences, online)
}
