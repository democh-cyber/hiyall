-- Authoritative eligibility is provisioned by a trusted age-assurance integration.
-- No profile/privacy patch or consumer endpoint can grant it. Unknown is denied.
CREATE TABLE discovery_eligibility (
  user_id uuid PRIMARY KEY REFERENCES users(user_id),
  age_group text NOT NULL CHECK (age_group IN ('adult','minor','unknown')),
  confirmed_at timestamptz NOT NULL,
  valid_until timestamptz NOT NULL,
  CHECK (valid_until > confirmed_at)
);
CREATE INDEX discovery_adults ON discovery_eligibility(user_id,valid_until) WHERE age_group='adult';
CREATE INDEX discovery_opt_in ON privacy_settings(user_id) WHERE data->>'discoverable'='true' AND data->>'profileAudience'='public';
