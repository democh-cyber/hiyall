-- Chat devices, round 3 (CHAT-N1). revoked_reason says why a device was removed by the system and not by its owner:
-- 'inactive' is a device that had not polled for days while its undelivered ciphertext reached the cap (the send
-- revokes it inside the transaction) or that held more than half the cap and was idle for three days (the hourly
-- sweep). Such a removal also sets revoked_by_other, so the owner's remaining devices list it in
-- GET /v1/me/devices ("removed") for 30 days, now with the reason. NULL is every other removal.
ALTER TABLE devices ADD COLUMN revoked_reason text CHECK (revoked_reason IS NULL OR revoked_reason IN ('inactive'));
