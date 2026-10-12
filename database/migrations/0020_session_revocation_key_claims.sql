-- Durable session revocation and one-time key claim caps.
--
-- 1. auth_identities.sessions_revoked_before is a per-identity watermark set by "sign out
--    everywhere else". A Firebase session is identified by sub plus auth_time (the
--    interactive sign-in), and a Firebase refresh token keeps minting ID tokens with the same
--    auth_time, so ResolveOIDC refuses to create a new session row for a Firebase sign-in
--    whose auth_time is before the watermark. That covers sign-ins this server never saw a
--    session row for. NULL means no watermark.
-- 2. Revoked sessions that came from an identity provider (external_sid set) are tombstones:
--    they are what stops a still-valid token for that sid from recreating the session, so
--    the hourly purge never deletes them (see store.PurgeSessions). The partial index covers
--    only the rows the purge may delete, so tombstones never slow it down.
-- 3. key_claims records each one-time key claim for an hour, so claims can be capped per
--    claimer and target device and per target device (see store.ClaimKey). Rows older than
--    a day are purged hourly.
ALTER TABLE auth_identities ADD COLUMN sessions_revoked_before timestamptz;

CREATE INDEX sessions_purgeable ON sessions(expires_at) WHERE external_sid IS NULL OR revoked_at IS NULL;

CREATE TABLE key_claims (
  claimer_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
  one_time boolean NOT NULL,
  claimed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX key_claims_pair ON key_claims(device_id, claimer_id, claimed_at);
CREATE INDEX key_claims_age ON key_claims(claimed_at);
