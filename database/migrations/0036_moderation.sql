-- Content scanning, quarantine, evidence holds and Apple token revocation
-- (docs/security/16-csam-and-illegal-content.md, docs/security/15-admin-console.md).
--
-- 1. media_assets.status gains 'quarantined': a photo the upload scanner matched or flagged. It is never
--    served, never attachable, never counted as ready, and the media cleanup never deletes it (the objects
--    sit under the hold/ prefix until a person releases them). scanned_at and scan_result record the
--    verdict of the scanner that cleared or stopped it.
-- 2. content_cases is the operator-visible case for each quarantined photo and the record kept for legal
--    reporting: who uploaded it, the SHA-256 of the exact bytes, what the scanner said (never the image),
--    where the held objects are, how long they are held and whether a report was made. The image itself is
--    only ever in object storage under hold/. Nothing here is sent to anyone automatically.
-- 3. apple_revocations holds a Sign in with Apple refresh token, sealed with a key derived from the Apple
--    key file, only when revoking it at deletion time failed; the purge retries it before it deletes the
--    identity. Normally the table is empty.

ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_status_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_status_check CHECK (status IN ('pending','ready','deleted','quarantined'));
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS scanned_at timestamptz;
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS scan_result text CHECK (scan_result IN ('clean','flagged','match'));

CREATE TABLE IF NOT EXISTS content_cases (
  case_id uuid PRIMARY KEY,
  media_id uuid NOT NULL UNIQUE REFERENCES media_assets(media_id),
  -- The uploader. The row outlives the account: the users row stays as a tombstone.
  user_id uuid NOT NULL REFERENCES users(user_id),
  purpose text NOT NULL CHECK (purpose IN ('post','story','avatar')),
  result text NOT NULL CHECK (result IN ('flagged','match')),
  scanner text NOT NULL,
  -- Scanner output without the image: a list name, a provider reference, a score. Never bytes.
  signals jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(signals)='object'),
  original_sha256 text NOT NULL,
  original_bytes bigint NOT NULL,
  content_type text NOT NULL,
  -- Held objects (hold/<media_id>/...): the exact upload, and the processed copy the scanner saw.
  original_key text NOT NULL,
  full_key text,
  suspended_user boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','confirmed','cleared','reported')),
  created_at timestamptz NOT NULL DEFAULT now(),
  -- Preservation: 90 days from detection unless counsel or an authority asks for longer (legal_hold).
  hold_until timestamptz NOT NULL DEFAULT now() + interval '90 days',
  legal_hold boolean NOT NULL DEFAULT false,
  reviewed_by text,
  reviewed_at timestamptz,
  resolution_note text,
  -- Filled in by staff after they report: the NCMEC CyberTipline report number or the authority's reference.
  report_reference text,
  reported_at timestamptz
);
CREATE INDEX IF NOT EXISTS content_cases_open ON content_cases(created_at) WHERE status='open';
CREATE INDEX IF NOT EXISTS content_cases_user ON content_cases(user_id,created_at DESC);

CREATE TABLE IF NOT EXISTS apple_revocations (
  issuer text NOT NULL,
  subject text NOT NULL,
  token_sealed bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (issuer,subject)
);

-- 4. Moderation writes fire two triggers that touch tables the console has no business reading: suspending or
--    restoring a member updates the neighbours' social counters (0033) and revoking their sessions revokes their
--    chat devices and prekeys (0035). Those trigger functions now run with their owner's rights, so the console's
--    least-privilege database role (database/roles/roles.sql) needs no grant on follows, friendships,
--    social_counters, devices or the key tables. search_path is pinned, as for any SECURITY DEFINER function.
ALTER FUNCTION users_status_counters() SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION revoke_session_devices() SECURITY DEFINER SET search_path = public, pg_temp;
