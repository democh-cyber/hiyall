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

// SetLocation stores the member's point at the precision of their age band, rounding
// again as a safety net, and returns when it was stored. The band is read in the same
// statement as the write.
func (s *Store) SetLocation(ctx context.Context, userID string, in domain.LocationInput) (time.Time, error) {
	fine, coarse := domain.RoundLocationTo(in.Fine, domain.LocationDecimals), domain.RoundLocationTo(in.Coarse, domain.MinorLocationDecimals)
	var updated time.Time
	err := s.Pool.QueryRow(ctx, `INSERT INTO user_locations(user_id,latitude,longitude,updated_at)
 SELECT user_id,CASE WHEN age_band(user_id)=$6 THEN $2::float8 ELSE $4::float8 END,CASE WHEN age_band(user_id)=$6 THEN $3::float8 ELSE $5::float8 END,now() FROM users WHERE user_id=$1 AND status='active'
 ON CONFLICT(user_id) DO UPDATE SET latitude=excluded.latitude,longitude=excluded.longitude,updated_at=excluded.updated_at
 RETURNING updated_at`, userID, coarse.Latitude, coarse.Longitude, fine.Latitude, fine.Longitude, domain.BandMinor).Scan(&updated)
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

// OwnLocation is the caller's fresh stored point, used only as the centre of a
// Nearby search, and whether the caller is a minor (which decides their distance
// buckets). It is ErrLocationNotShared when none is stored or it has expired.
func (s *Store) OwnLocation(ctx context.Context, userID string) (loc domain.Location, minor bool, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT l.latitude,l.longitude,age_band(l.user_id)=$3 FROM user_locations l JOIN users u USING(user_id) WHERE l.user_id=$1 AND u.status='active' AND l.updated_at>now()-make_interval(hours=>$2::int)`, userID, domain.LocationFreshHours, domain.BandMinor).Scan(&loc.Latitude, &loc.Longitude, &minor)
	if errors.Is(err, pgx.ErrNoRows) {
		return loc, false, domain.ErrLocationNotShared
	}
	return loc, minor, err
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
 ELSE CASE WHEN km<=1 THEN 1 WHEN km<=2 THEN 2 WHEN km<=3 THEN 3 WHEN km<=5 THEN 5 WHEN km<=10 THEN 10 WHEN km<=15 THEN 15 WHEN km<=25 THEN 25 WHEN km<=50 THEN 50 ELSE 100 END END`

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
