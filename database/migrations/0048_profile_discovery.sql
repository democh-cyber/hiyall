-- Profile and discovery v2 (docs/api/25-profile-and-discovery-v2.md).
--
-- 1. Language proficiency. Each language on a profile has a level 1..6 (1 just starting ... 6 native). The profile
--    JSON stays the source for display: its languages array becomes [{"code","level"}] with an integer level.
--    The old words map to numbers (basic 2, conversational 3, fluent 4, native 6); a language that had no level,
--    or a bare tag, gets the default level 3.
-- 2. Normalised copies for filtering and ranking: profile_languages, profile_interests and
--    profile_personality_tags. They are derived from the profile JSON by derive_profile_rows(), which a trigger
--    runs in the same transaction as every write of profiles.data that changes languages, interests or
--    personalityTags, so a write from any path (the API, a fixture, a SQL fix) cannot leave them behind.
--    profile_languages has the index (code, level, user_id) the language filter reads.
-- 3. The profile photo gallery: profile_photos orders up to ProfilePhotosMax photos (entitlement) per member. A
--    gallery photo is an ordinary media_assets row of purpose 'avatar' (same upload, scan, quarantine and cleanup
--    pipeline); position 0 is the profile photo and is mirrored into profiles.data->>'avatarMediaId'. An existing
--    avatar becomes photo 0.
-- 4. profile_visits.last_visited_at (refreshed at most once an hour, by RecordProfileVisit) serves the 30 day
--    "recent visitors" window (opt-in, adults only) and the member's own "places I've visited" list.
-- 5. New privacy settings, filled for every existing member by age band: showLocalTime, showDistance,
--    visitorsVisibleToOthers and showBirthday, and the field audiences aboutMe, hometown, personality and birthday.
--    Adults: local time and distance on, visitors and birthday off, aboutMe and hometown for followers, birthday
--    for friends, personality for everyone. Members under 18: everything off or hidden (personality aside).
-- 6. A partial index on the country of a profile for the "same country" signal of possible matches.

-- 1
CREATE FUNCTION language_level(e jsonb) RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN jsonb_typeof(e) = 'object' AND jsonb_typeof(e->'level') = 'number'
      THEN least(6, greatest(1, floor((e->>'level')::numeric)))::smallint
    WHEN jsonb_typeof(e) = 'object' AND jsonb_typeof(e->'level') = 'string'
      THEN (CASE e->>'level' WHEN 'basic' THEN 2 WHEN 'conversational' THEN 3 WHEN 'fluent' THEN 4 WHEN 'native' THEN 6 ELSE 3 END)::smallint
    ELSE 3::smallint
  END
$$;

CREATE FUNCTION language_code(e jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE jsonb_typeof(e) WHEN 'string' THEN e #>> '{}' WHEN 'object' THEN e->>'code' END
$$;

-- 2
CREATE TABLE profile_languages (
  user_id uuid NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  code text NOT NULL,
  level smallint NOT NULL CHECK (level BETWEEN 1 AND 6),
  PRIMARY KEY (user_id, code)
);
CREATE INDEX profile_languages_code_level ON profile_languages (code, level, user_id);

CREATE TABLE profile_interests (
  user_id uuid NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  interest text NOT NULL,
  PRIMARY KEY (user_id, interest)
);
CREATE INDEX profile_interests_interest ON profile_interests (interest, user_id);

CREATE TABLE profile_personality_tags (
  user_id uuid NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  tag text NOT NULL,
  PRIMARY KEY (user_id, tag)
);
CREATE INDEX profile_personality_tags_tag ON profile_personality_tags (tag, user_id);

CREATE FUNCTION derive_profile_rows(p_user uuid, p_data jsonb) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM profile_languages WHERE user_id = p_user;
  INSERT INTO profile_languages (user_id, code, level)
  SELECT p_user, code, max(level) FROM (
    SELECT lower(language_code(e)) AS code, language_level(e) AS level
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_data->'languages') = 'array' THEN p_data->'languages' ELSE '[]'::jsonb END) e
  ) x
  WHERE code ~ '^[a-z]{2,8}(-[a-z0-9]{1,8})*$' AND length(code) <= 35
  GROUP BY code;

  DELETE FROM profile_interests WHERE user_id = p_user;
  INSERT INTO profile_interests (user_id, interest)
  SELECT DISTINCT p_user, lower(e #>> '{}')
  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_data->'interests') = 'array' THEN p_data->'interests' ELSE '[]'::jsonb END) e
  WHERE jsonb_typeof(e) = 'string' AND length(e #>> '{}') BETWEEN 1 AND 40;

  DELETE FROM profile_personality_tags WHERE user_id = p_user;
  INSERT INTO profile_personality_tags (user_id, tag)
  SELECT DISTINCT p_user, lower(e #>> '{}')
  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_data->'personalityTags') = 'array' THEN p_data->'personalityTags' ELSE '[]'::jsonb END) e
  WHERE jsonb_typeof(e) = 'string' AND length(e #>> '{}') BETWEEN 1 AND 40;
END
$$;

-- The profile JSON takes the numeric level (original order and spelling of the codes, duplicates by code dropped).
UPDATE profiles p SET
  data = jsonb_set(p.data, '{languages}', coalesce((
    SELECT jsonb_agg(jsonb_build_object('code', x.code, 'level', x.level) ORDER BY x.ord)
    FROM (
      SELECT language_code(e) AS code, language_level(e) AS level, ord,
             row_number() OVER (PARTITION BY lower(language_code(e)) ORDER BY ord) AS rn
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p.data->'languages') = 'array' THEN p.data->'languages' ELSE '[]'::jsonb END) WITH ORDINALITY AS t(e, ord)
    ) x
    WHERE x.rn = 1 AND x.code ~ '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$' AND length(x.code) <= 35
  ), '[]'::jsonb)),
  version = version + 1,
  updated_at = now()
WHERE CASE WHEN jsonb_typeof(p.data->'languages') = 'array' THEN jsonb_array_length(p.data->'languages') > 0 ELSE false END;

SELECT derive_profile_rows(user_id, data) FROM profiles;

CREATE FUNCTION profiles_derive_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND (OLD.data->'languages', OLD.data->'interests', OLD.data->'personalityTags')
         IS NOT DISTINCT FROM (NEW.data->'languages', NEW.data->'interests', NEW.data->'personalityTags') THEN
    RETURN NULL;
  END IF;
  PERFORM derive_profile_rows(NEW.user_id, NEW.data);
  RETURN NULL;
END
$$;
CREATE TRIGGER profiles_derive AFTER INSERT OR UPDATE OF data ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_derive_trigger();

-- 3
CREATE TABLE profile_photos (
  user_id uuid NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  position smallint NOT NULL CHECK (position BETWEEN 0 AND 31),
  media_id uuid NOT NULL UNIQUE REFERENCES media_assets(media_id) ON DELETE CASCADE,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, position)
);

INSERT INTO profile_photos (user_id, position, media_id)
SELECT p.user_id, 0, m.media_id
FROM profiles p
JOIN media_assets m ON m.media_id = nullif(p.data->>'avatarMediaId', '')::uuid
  AND m.owner_id = p.user_id AND m.purpose = 'avatar' AND m.status = 'ready';

-- 4
ALTER TABLE profile_visits ADD COLUMN last_visited_at timestamptz;
UPDATE profile_visits SET last_visited_at = first_visited_at;
ALTER TABLE profile_visits ALTER COLUMN last_visited_at SET NOT NULL, ALTER COLUMN last_visited_at SET DEFAULT now();
CREATE INDEX profile_visits_profile_recent ON profile_visits (profile_id, last_visited_at DESC, visitor_id DESC);
CREATE INDEX profile_visits_visitor_recent ON profile_visits (visitor_id, last_visited_at DESC, profile_id DESC);

-- 5
UPDATE privacy_settings q SET
  data = q.data
    || CASE WHEN age_band(q.user_id) = 'minor'
         THEN '{"showLocalTime":false,"showDistance":false,"visitorsVisibleToOthers":false,"showBirthday":false}'::jsonb
         ELSE '{"showLocalTime":true,"showDistance":true,"visitorsVisibleToOthers":false,"showBirthday":false}'::jsonb END
    || jsonb_build_object('fieldAudiences', coalesce(q.data->'fieldAudiences', '{}'::jsonb)
         || CASE WHEN age_band(q.user_id) = 'minor'
              THEN '{"aboutMe":"nobody","hometown":"nobody","personality":"everyone","birthday":"nobody"}'::jsonb
              ELSE '{"aboutMe":"followers","hometown":"followers","personality":"everyone","birthday":"friends"}'::jsonb END),
  version = version + 1,
  updated_at = now()
WHERE NOT (q.data ? 'showLocalTime');

-- 6
CREATE INDEX profiles_country ON profiles ((data->>'country')) WHERE data->>'country' IS NOT NULL;
