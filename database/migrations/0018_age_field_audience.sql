-- A member's age in whole years can be shown on their profile to other members who may
-- view it, governed by its own field audience like the other fields. The birth date is
-- never shown. New accounts get fieldAudiences.age = "everyone" from the defaults; this
-- adds it to existing privacy rows that lack it, bumping the version only where it
-- changed, so running it again changes nothing. The app has no screen to hide it.
UPDATE privacy_settings SET
  data = jsonb_set(data, '{fieldAudiences}', coalesce(data->'fieldAudiences', '{}'::jsonb) || '{"age":"everyone"}'::jsonb),
  version = version + 1,
  updated_at = now()
WHERE NOT (coalesce(data->'fieldAudiences', '{}'::jsonb) ? 'age');
