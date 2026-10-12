-- Age bands and gender.
--
-- 1. member_ages keeps the birth date a member declared at onboarding. It is PRIVATE:
--    nothing selects it into an API response, profile JSON, outbox event or log line, and
--    no endpoint returns an age or a birth date, even to its owner. The first stored value
--    is final (ON CONFLICT DO NOTHING in the application), so it cannot be changed later
--    to move between bands. A member with no row (every account that existed before this
--    migration, and the Anjali/Niko fixtures until Seed adds theirs) has an unknown age,
--    which counts as an adult so existing accounts keep working. The declaration is
--    self-reported and can be falsified; it is not age assurance.
-- 2. member_age(), age_band() and interaction_barred() are the single definition of "who
--    may interact". Minors (under 18) and adults are separate bands. interaction_barred()
--    is true for a block in either direction, or, while isolation is enabled, for two
--    members in different bands. Isolation is read from the session setting
--    kairova.age_band_isolation, which the API sets on every connection from
--    AGE_BAND_ISOLATION ('off' disables it; anything else, including unset, enables it).
-- 3. fieldAudiences.gender is added to every existing privacy row as "everyone", like the
--    other fields (see 0016), without touching any other key.
CREATE TABLE member_ages (
  user_id uuid PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  birth_date date NOT NULL CHECK (birth_date <= current_date),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Whole years as of today in UTC, by calendar date; NULL when the birth date is unknown.
CREATE FUNCTION member_age(m uuid) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT date_part('year', age((now() AT TIME ZONE 'UTC')::date, birth_date))::integer
    FROM member_ages WHERE user_id = m
$$;

-- 'minor' below 18, otherwise 'adult'. An unknown birth date is an adult. 18 is domain.AdultAge.
CREATE FUNCTION age_band(m uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN member_age(m) < 18 THEN 'minor' ELSE 'adult' END
$$;

CREATE FUNCTION age_isolation_enabled() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('kairova.age_band_isolation', true), 'on') <> 'off'
$$;

-- True when a and b must not see or reach each other: a block in either direction, or
-- different age bands while isolation is enabled. Callers treat it exactly like a block.
-- It is written without calling age_band so that checking a candidate is one lookup of
-- each member's birth date, not a chain of function calls: it runs once per candidate row
-- in people search, Nearby, feeds and lists. "Minor" here is birth_date after the date 18
-- years ago, which is exactly age_band = 'minor' (a test compares the two); no birth date is an adult.
CREATE FUNCTION interaction_barred(a uuid, b uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM blocks WHERE (blocker_id = a AND blocked_id = b) OR (blocker_id = b AND blocked_id = a))
      OR (age_isolation_enabled()
          AND coalesce((SELECT birth_date > (now() AT TIME ZONE 'UTC')::date - interval '18 years' FROM member_ages WHERE user_id = a), false)
           <> coalesce((SELECT birth_date > (now() AT TIME ZONE 'UTC')::date - interval '18 years' FROM member_ages WHERE user_id = b), false))
$$;

UPDATE privacy_settings SET
  data = jsonb_set(data, '{fieldAudiences}', coalesce(data->'fieldAudiences', '{}'::jsonb) || '{"gender":"everyone"}'::jsonb),
  version = version + 1,
  updated_at = now()
WHERE NOT (coalesce(data->'fieldAudiences', '{}'::jsonb) ? 'gender');
