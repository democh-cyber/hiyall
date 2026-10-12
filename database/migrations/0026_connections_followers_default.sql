-- Followers can open an adult member's followers and following lists.
--
-- The privacy field fieldAudiences.connections says who may open a member's followers and
-- following lists. It started as "friends" for everyone; the new default for an adult is
-- "followers" (whoever has an active follow on the member, and friends). This moves every
-- existing ADULT member whose stored value is still "friends" to "followers", bumping the
-- version and updated_at as the earlier privacy migrations did. A member counts as an adult
-- exactly as age_band() (0017) says: 18 or older, or no stored birth date. Members under 18
-- keep "friends" and are not touched (new minors get "friends" from the minor defaults at
-- onboarding), and a value that is anything other than "friends" ("everyone", "nobody",
-- "followers") is never rewritten. The friends list is not governed by this move: the API
-- reads "followers" as "friends" for it, so it stays friends-only. Only rows that change are
-- updated, so running this again changes nothing.
UPDATE privacy_settings SET
  data = jsonb_set(data, '{fieldAudiences,connections}', '"followers"'::jsonb),
  version = version + 1,
  updated_at = now()
WHERE data #>> '{fieldAudiences,connections}' = 'friends'
  AND age_band(user_id) = 'adult';
