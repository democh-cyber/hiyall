-- Chat limits and the device-removal record (re-audit CHAT-2, CHAT-4).
--
-- revoked_by_other: the device was removed by a session that is not the one that registered it (another phone
-- of the account, or whoever holds a stolen credential), as opposed to its own sign-out, the hourly stale-device
-- job or the session trigger. The owner's remaining devices read these rows (GET /v1/me/devices, "removed") for
-- 30 days, so a removal they missed on the realtime socket is still shown as a notice.
--
-- The undelivered-envelope cap per device and the daily per-conversation quota need no new structure: they count
-- through envelopes_inbox (0007, partial on undelivered rows) and messages_conversation (0007).
ALTER TABLE devices ADD COLUMN revoked_by_other boolean NOT NULL DEFAULT false;
CREATE INDEX devices_removed_by_other ON devices(user_id, revoked_at DESC) WHERE revoked_by_other;
