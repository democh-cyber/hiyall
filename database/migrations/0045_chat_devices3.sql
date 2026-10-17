-- Chat devices, round 4 (CHAT-N1, N2). revoked_reason gains 'idle': a device the relay removed only because it had
-- not been used for a long time (the 35-day sweep) or because it sat idle for more than 48 hours while one sender
-- alone had filled its per-sender share (the send revokes it inside the transaction). Unlike 'inactive' (a device
-- over the undelivered-envelope cap, whose ciphertext is dropped), an idle removal keeps the device row and the
-- ciphertext that has not expired yet (the 30-day envelope expiry still applies; the unclaimed keys are dropped
-- and uploaded again on return), so the same app can come back with the same identity: registering the same
-- device id and keys again reactivates the row (Store.RegisterDeviceNew), peers see nothing change and nobody is
-- told that a new device appeared. Any other removal stays final: its registration still conflicts.
-- Like 'inactive' it sets revoked_by_other, so the owner's other devices list it in GET /v1/me/devices for 30 days.
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_revoked_reason_check;
ALTER TABLE devices ADD CONSTRAINT devices_revoked_reason_check CHECK (revoked_reason IS NULL OR revoked_reason IN ('inactive','idle'));
