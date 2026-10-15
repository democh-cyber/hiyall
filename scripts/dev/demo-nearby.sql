-- Nearby fixtures for the LOCAL development database only. Run through
-- scripts/dev/seed-demo-nearby.sh, which passes the centre as :lat and :lon.
--
-- Places Anjali, Niko, Kai and the demo_ people (scripts/dev/demo-people.sql, including the two
-- demo_minor_ ones) 0.5 to 40 km from the centre, spread around the compass by the golden angle,
-- nearest first by name. Coordinates are rounded to the grid the API itself stores (2 decimals
-- for adults, 1 for minors), and updated_at is now, so every point counts as shared for the next
-- 24 hours. Re-running moves the same people to the same places. Minors only appear in Nearby for
-- other minors, and adults only for adults.
\set ON_ERROR_STOP on
DO $$ BEGIN
  IF current_database() <> 'hiyall' THEN
    RAISE EXCEPTION 'demo nearby locations are only for the local development database (hiyall)';
  END IF;
END $$;

BEGIN;
WITH people AS (
  SELECT p.user_id, row_number() OVER (ORDER BY p.username) - 1 AS rank, count(*) OVER () AS total,
         age_band(p.user_id) = 'minor' AS minor
    FROM profiles p
    JOIN users u USING (user_id)
    JOIN onboarding o ON o.user_id = p.user_id AND o.completed_at IS NOT NULL
   WHERE u.status = 'active' AND (p.username IN ('anjali', 'niko', 'kai') OR p.username LIKE 'demo\_%')
), spread AS (
  SELECT user_id, minor,
         -- distance grows with rank, denser near the centre: 0.5 km .. 40 km
         0.5 + 39.5 * power(rank::float8 / greatest(total - 1, 1), 1.5) AS km,
         radians(mod((rank * 137.50776405)::numeric, 360)::float8) AS bearing
    FROM people
), target AS (
  SELECT user_id, minor,
         greatest(-90, least(90, :'lat'::float8 + km * cos(bearing) / 111.195)) AS raw_lat,
         km, bearing
    FROM spread
), points AS (
  -- the grid the API itself stores: 2 decimals for adults, 1 decimal for minors
  SELECT user_id,
         round(raw_lat::numeric, CASE WHEN minor THEN 1 ELSE 2 END)::float8 AS latitude,
         -- longitude degrees shrink with latitude; keep the result in [-180, 180]
         round(mod(mod((:'lon'::float8 + km * sin(bearing) / (111.195 * greatest(cos(radians(raw_lat)), 0.0001)) + 540)::numeric, 360) + 360, 360) - 180, CASE WHEN minor THEN 1 ELSE 2 END)::float8 AS longitude
    FROM target
)
INSERT INTO user_locations (user_id, latitude, longitude, updated_at)
SELECT user_id, latitude, longitude, now() FROM points
ON CONFLICT (user_id) DO UPDATE
   SET latitude = excluded.latitude, longitude = excluded.longitude, updated_at = excluded.updated_at;
COMMIT;

SELECT p.username, age_band(p.user_id) AS band,
       round((2 * 6371.0 * asin(least(1, sqrt(
         power(sin(radians(l.latitude - :'lat'::float8) / 2), 2) +
         cos(radians(:'lat'::float8)) * cos(radians(l.latitude)) * power(sin(radians(l.longitude - :'lon'::float8) / 2), 2)))))::numeric, 1) AS km_from_centre
  FROM user_locations l JOIN profiles p USING (user_id)
 WHERE p.username IN ('anjali', 'niko', 'kai') OR p.username LIKE 'demo\_%'
 ORDER BY km_from_centre;
