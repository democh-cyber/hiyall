-- Open messaging, instant follows, and the visitors and stories counts.
--
-- 1. Anyone may message anyone who is not blocked and is in the same age band, and a
--    follow takes effect at once. Both are privacy defaults (messagesFrom and followPolicy
--    "everyone"), so every existing privacy row is rewritten to them, minors included
--    (they keep their other stricter defaults). Members can still set "friends",
--    "followers", "nobody" or "approval" through the API; nothing in the app does. Version
--    is bumped only on rows that change, so running this again changes nothing.
-- 2. fieldAudiences.counts governs who sees the counts on a profile (friends, following,
--    followers, visitors, stories); default "everyone", added to rows that lack it. The
--    connection lists keep their own audience, fieldAudiences.connections ("friends").
-- 3. profile_visits records which member opened which profile, once per pair; it is
--    never exposed, no endpoint lists visitors. profile_visit_counts is the counter, in 8
--    slots like post_counters so many first visits to a hot profile do not queue on one
--    row; it is incremented only when a new pair is inserted, and read as a sum. Deleting a
--    member removes their visit rows but not the all-time count. The backfill is zero.
UPDATE privacy_settings SET
  data = jsonb_set(
           data || '{"messagesFrom":"everyone","followPolicy":"everyone"}'::jsonb,
           '{fieldAudiences}',
           coalesce(data->'fieldAudiences', '{}'::jsonb) || CASE WHEN coalesce(data->'fieldAudiences', '{}'::jsonb) ? 'counts' THEN '{}'::jsonb ELSE '{"counts":"everyone"}'::jsonb END),
  version = version + 1,
  updated_at = now()
WHERE data->>'messagesFrom' IS DISTINCT FROM 'everyone'
   OR data->>'followPolicy' IS DISTINCT FROM 'everyone'
   OR NOT (coalesce(data->'fieldAudiences', '{}'::jsonb) ? 'counts');

CREATE TABLE profile_visits (
  profile_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  visitor_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  first_visited_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, visitor_id),
  CHECK (profile_id <> visitor_id)
);
CREATE INDEX profile_visits_visitor ON profile_visits(visitor_id);

CREATE TABLE profile_visit_counts (
  profile_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  slot smallint NOT NULL CHECK (slot BETWEEN 0 AND 7),
  visitors bigint NOT NULL DEFAULT 0 CHECK (visitors >= 0),
  PRIMARY KEY (profile_id, slot)
);
INSERT INTO profile_visit_counts(profile_id, slot, visitors) SELECT user_id, 0, 0 FROM users;
