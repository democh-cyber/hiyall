-- Account deletion (30 day grace period, then a purge) and the data export rate limit.
-- Flow and retention: docs/api/22-account-deletion-and-export.md.
--
-- 1. users.status gains 'pending_deletion' (asked to delete, can still cancel). The existing
--    'deleting' (purge running or waiting for object storage) and 'deleted' (purge finished) are
--    used as they were reserved in 0001. Every query that wants a live account says status='active',
--    so a pending member drops out of Discover, Nearby, lists, search, Pulse and the counts at once.
-- 2. deletion_scheduled_at / deletion_due_at hold the request time and the end of the grace period
--    (request + 30 days); both are NULL unless the member asked for deletion and have not cancelled.
-- 3. last_export_at is the last time the member downloaded their data; the API allows one export per
--    24 hours (GET /v1/me/export, 429 RATE_LIMITED with Retry-After).
-- 4. deleted_users is the tombstone of a purged account: the id and when it was purged, nothing
--    else, so the id is never handed out again and a purge that already finished is never repeated.
--    There is deliberately no foreign key: it is the record that outlives everything else. The users
--    row itself stays too (status 'deleted', no personal data) because the retained report and
--    evidence rows reference it.
-- 5. auth_identities.provider_deleted_at records that the identity provider account (Firebase user)
--    was deleted, so the purge never calls the provider twice. The identity row itself is kept for 24
--    hours after the purge: an ID token minted before the purge stays valid for up to an hour, and
--    while this row exists it resolves to a deleted account and is refused, instead of provisioning a
--    new account for the same provider identity.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_status_check;
ALTER TABLE users ADD CONSTRAINT users_status_check CHECK (status IN ('active','deactivated','suspended','banned','pending_deletion','deleting','deleted'));
ALTER TABLE users ADD COLUMN deletion_scheduled_at timestamptz;
ALTER TABLE users ADD COLUMN deletion_due_at timestamptz;
ALTER TABLE users ADD COLUMN last_export_at timestamptz;
ALTER TABLE users ADD CONSTRAINT users_deletion_pair CHECK ((deletion_scheduled_at IS NULL) = (deletion_due_at IS NULL));
ALTER TABLE users ADD CONSTRAINT users_pending_deletion_due CHECK (status NOT IN ('pending_deletion','deleting') OR deletion_due_at IS NOT NULL);
-- The purge job reads accounts that are due or mid-purge.
CREATE INDEX users_deletion_due ON users(deletion_due_at) WHERE status IN ('pending_deletion','deleting');

CREATE TABLE deleted_users (
  user_id uuid PRIMARY KEY,
  deleted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX deleted_users_age ON deleted_users(deleted_at);

ALTER TABLE auth_identities ADD COLUMN provider_deleted_at timestamptz;
