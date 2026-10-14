-- Chat device lifecycle. A chat device is linked to the auth session that registered it, so that
-- signing that session out (sign out, "sign out everywhere else", suspension, account deletion)
-- also revokes the device, drops its unclaimed keys and its undelivered ciphertext. Devices that
-- stay unseen for 90 days are revoked by the hourly maintenance job (Store.RevokeStaleDevices),
-- which frees the 10-device cap.
-- No foreign key: purging an old session row must not touch the device, and a session id that has
-- no row is simply never revoked.
ALTER TABLE devices ADD COLUMN session_id uuid;
CREATE INDEX devices_session ON devices(session_id) WHERE session_id IS NOT NULL AND revoked_at IS NULL;
CREATE INDEX devices_stale ON devices(last_seen_at) WHERE revoked_at IS NULL;

CREATE FUNCTION revoke_session_devices() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
    WITH gone AS (
      UPDATE devices SET revoked_at = now(), push_provider = NULL, push_token = NULL
      WHERE session_id = NEW.session_id AND revoked_at IS NULL
      RETURNING device_id
    ), k1 AS (
      DELETE FROM one_time_keys WHERE device_id IN (SELECT device_id FROM gone)
    ), k2 AS (
      DELETE FROM fallback_keys WHERE device_id IN (SELECT device_id FROM gone)
    )
    DELETE FROM message_envelopes WHERE recipient_device_id IN (SELECT device_id FROM gone) AND delivered_at IS NULL;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER sessions_revoke_devices AFTER UPDATE OF revoked_at ON sessions
  FOR EACH ROW EXECUTE FUNCTION revoke_session_devices();
