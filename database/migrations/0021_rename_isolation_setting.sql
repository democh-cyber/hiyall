-- The product is now Hiyall. The age-band isolation switch is read from the session
-- setting hiyall.age_band_isolation, which the API sets on every connection from
-- AGE_BAND_ISOLATION ('off' disables it; anything else, including unset, enables it).
-- 0017 read kairova.age_band_isolation; applied migrations can't change, so the
-- function is replaced here. Everything else about isolation is as described in 0017.
CREATE OR REPLACE FUNCTION age_isolation_enabled() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('hiyall.age_band_isolation', true), 'on') <> 'off'
$$;
