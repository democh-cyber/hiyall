-- Teen safety and abuse limits (docs/architecture/18-teen-safety.md).
--
-- 1. nearby_prefs: whether a member has turned on "Show me in Nearby" (default off for everyone), and the
--    member's current daily random offset, applied to a shared point before it is rounded and stored. The
--    offset is secret to the server and rotates when offset_day is not today (UTC).
-- 2. member_daily_counts: one counter per member, kind and UTC day, for the daily caps in
--    domain.Entitlements (follows, friend requests, comments, spaces, space entries, search pages, profile
--    views, Nearby queries, location changes). Rows older than a few days are purged by maintenance.
-- 3. age_gate_refusals: an identity (issuer + subject) that declared an age under the minimum. No birth
--    date is kept. Further onboarding from that identity is refused for 7 days from the last refusal. The
--    row has no foreign key on purpose: deleting the account must not clear the refusal.

CREATE TABLE nearby_prefs (
  user_id uuid PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  visible boolean NOT NULL DEFAULT false,
  offset_day date,
  offset_north_km double precision NOT NULL DEFAULT 0,
  offset_east_km double precision NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX nearby_prefs_visible ON nearby_prefs(user_id) WHERE visible;

-- Existing members: Nearby stays on only for adults who shared a location in the last 24 hours. Every other
-- member (all minors, everyone who is not sharing) starts off. Minors' stored points are deleted.
INSERT INTO nearby_prefs(user_id, visible)
SELECT l.user_id, true FROM user_locations l
WHERE l.updated_at > now() - interval '24 hours' AND age_band(l.user_id) = 'adult';

DELETE FROM user_locations l WHERE NOT EXISTS (SELECT 1 FROM nearby_prefs p WHERE p.user_id = l.user_id AND p.visible);

CREATE TABLE member_daily_counts (
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (length(kind) BETWEEN 1 AND 40),
  day date NOT NULL,
  n integer NOT NULL DEFAULT 0 CHECK (n >= 0),
  PRIMARY KEY (user_id, kind, day)
);
CREATE INDEX member_daily_counts_day ON member_daily_counts(day);

CREATE TABLE age_gate_refusals (
  issuer text NOT NULL,
  subject text NOT NULL,
  refused_at timestamptz NOT NULL DEFAULT now(),
  refusals integer NOT NULL DEFAULT 1,
  PRIMARY KEY (issuer, subject)
);
CREATE INDEX age_gate_refusals_at ON age_gate_refusals(refused_at);
