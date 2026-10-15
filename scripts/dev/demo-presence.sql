-- Presence fixtures for the LOCAL development databases only: makes some demo people look online and others
-- recently active, so the green dots (Discover, Nearby, Chats list) and "last seen ..." (conversation header)
-- have something to show. Run through scripts/dev/seed-demo-presence.sh. Safe to re-run.
--
-- Presence is real server data: online means session activity within the last 2 minutes (or a live
-- realtime connection), and last seen is the latest session activity rounded down to 5 minutes. So this
-- writes sessions.last_seen_at for each person (creating one tagged session row, issuer 'demo-presence', when
-- they have none) with a spread of ages, and makes sure adults let everyone see presence (onlineAudience
-- "everyone"). Minors are never touched: they keep the default "nobody". The "online" people are only online for
-- about two minutes, so run it again (or use seed-demo-presence.sh --keep) when the dots go away.
--
--   :extra  comma separated extra usernames to include besides the adult demo_ people (for example anjali,niko);
--           empty by default so real sign-in accounts do not gain a demo session in their Sessions list.
\set ON_ERROR_STOP on
DO $$ BEGIN
  IF current_database() NOT IN ('hiyall', 'hiyall_test') THEN
    RAISE EXCEPTION 'demo presence is only for the local development databases (hiyall, hiyall_test)';
  END IF;
END $$;

BEGIN;
-- Adults only, in a stable order. member_age is null for an account with no stored birth date (an adult).
CREATE TEMP TABLE people ON COMMIT DROP AS
SELECT p.user_id, row_number() OVER (ORDER BY p.username) - 1 AS n
  FROM profiles p
  JOIN users u USING (user_id)
  JOIN onboarding o ON o.user_id = p.user_id AND o.completed_at IS NOT NULL
 WHERE u.status = 'active'
   AND (p.username LIKE 'demo\_%' OR p.username = ANY (string_to_array(NULLIF(:'extra', ''), ',')))
   AND p.username NOT LIKE 'demo\_minor\_%'
   AND coalesce(member_age(p.user_id), 18) >= 18;

-- Seconds since last activity, by position. A few are online (under two minutes), the rest away for minutes,
-- hours and days; a NULL means never seen (no session, so the person shows nothing at all).
CREATE TEMP TABLE spread(slot int PRIMARY KEY, secs int) ON COMMIT DROP;
INSERT INTO spread VALUES (0, 15), (1, 600), (2, 40), (3, 1500), (4, 3 * 3600), (5, 25), (6, 26 * 3600),
  (7, NULL), (8, 70), (9, 4 * 86400), (10, 1020), (11, 9 * 86400), (12, 50), (13, 8 * 3600), (14, NULL), (15, 100);

-- Adults show presence to everyone (the app's one switch, "Show when I'm online and last seen", on).
UPDATE privacy_settings q SET data = jsonb_set(data, '{onlineAudience}', '"everyone"')
  FROM people WHERE q.user_id = people.user_id AND q.data->>'onlineAudience' IS DISTINCT FROM 'everyone';

-- One tagged session each, refreshed on every run; people with no activity lose it.
INSERT INTO sessions(session_id, user_id, issuer, external_sid, expires_at, last_seen_at, platform)
SELECT md5('demo-presence:' || people.user_id)::uuid, people.user_id, 'demo-presence', people.user_id::text,
       now() + interval '30 days', now() - make_interval(secs => spread.secs), 'unknown'
  FROM people JOIN spread ON spread.slot = people.n % 16
 WHERE spread.secs IS NOT NULL
ON CONFLICT (session_id) DO UPDATE SET last_seen_at = excluded.last_seen_at, expires_at = excluded.expires_at, revoked_at = NULL;
DELETE FROM sessions s USING people JOIN spread ON spread.slot = people.n % 16
 WHERE s.session_id = md5('demo-presence:' || people.user_id)::uuid AND spread.secs IS NULL;

SELECT p.username,
       CASE WHEN s.last_seen_at IS NULL THEN 'never seen'
            WHEN s.last_seen_at > now() - interval '2 minutes' THEN 'online'
            ELSE 'last seen ' || to_char(date_trunc('hour', s.last_seen_at) + floor(extract(minute FROM s.last_seen_at) / 5) * interval '5 minutes', 'YYYY-MM-DD HH24:MI') || ' UTC' END AS presence
  FROM people JOIN profiles p USING (user_id)
  LEFT JOIN sessions s ON s.session_id = md5('demo-presence:' || people.user_id)::uuid
 ORDER BY p.username;
COMMIT;
