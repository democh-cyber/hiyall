-- Open access, open profiles and Nearby.
--
-- 1. The age gate is a minimum age, not an adult check, so the column that
--    records the declaration is renamed. (0015 is already applied; it is not edited.)
-- 2. discovery_eligibility is retired: nothing reads it any more and every
--    active, onboarded member is eligible for discovery and shared spaces. The
--    table stays for migration history.
-- 3. Every existing privacy row is rewritten to the new open defaults and the
--    profile's mirrored audience follows. Only the listed keys change; any other
--    key (for example readReceipts) keeps its stored value. Connections stay
--    friends-only.
-- 4. user_locations holds one coarse, opt-in, expiring point per member. The
--    server rounds both coordinates to 2 decimal places (about 1.1 km) before
--    it writes, so a precise position is never stored. A row updated within the
--    last 24 hours means "sharing"; rows older than 7 days are purged.
ALTER TABLE onboarding RENAME COLUMN adult_declared_at TO age_declared_at;

COMMENT ON TABLE discovery_eligibility IS 'Retired. Nothing reads or writes this table; kept only for migration history.';

UPDATE privacy_settings SET
  data = data || jsonb_build_object(
    'profileAudience', 'public',
    'discoverable', true,
    'showInterestOverlap', true,
    'onlineAudience', 'everyone',
    'messagesFrom', 'friends',
    'followPolicy', 'approval',
    'requestsFrom', 'everyone',
    'storyAudience', 'friends',
    'commentsFrom', 'friends',
    'mentionsFrom', 'friends',
    'activityAudience', 'nobody',
    'lastSeenAudience', 'nobody',
    'locationAudience', 'nobody',
    'fieldAudiences', jsonb_build_object(
      'pronouns', 'everyone', 'location', 'everyone', 'profession', 'everyone',
      'education', 'everyone', 'website', 'everyone', 'timezone', 'everyone',
      'languages', 'everyone', 'interests', 'everyone', 'vibe', 'everyone',
      'connections', 'friends')),
  version = version + 1,
  updated_at = now();

UPDATE profiles SET
  data = jsonb_set(data, '{profileAudience}', '"public"'),
  version = version + 1,
  updated_at = now();

CREATE TABLE user_locations (
  user_id uuid PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  latitude double precision NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Bounding-box prefilter for Nearby, and the freshness filter and retention purge.
CREATE INDEX user_locations_point ON user_locations(latitude, longitude);
CREATE INDEX user_locations_updated ON user_locations(updated_at);
