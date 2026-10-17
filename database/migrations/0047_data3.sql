-- Data release 3 (round-4 audit N4, N10).
--
-- 1. drop_pending_case left the photo it dropped at status 'deleted' with no deleted_at. The tombstone purge
--    (PurgeMediaTombstones) and the media cleanup both find a deleted photo by deleted_at, so such a row was never
--    removed. This is the version of 0046 (a case is dropped only when it is flagged, pending and an hour old) that
--    also sets deleted_at, and the rows it already left behind get one now: the 30 days of a tombstone start from
--    this migration for them, since the day they were dropped is not recorded. Owner, SECURITY DEFINER and the
--    grants are unchanged (CREATE OR REPLACE keeps them; database/roles/grants.sql sets them again on every release).
-- 2. Revoked sign-in sessions of an identity provider are kept as tombstones so that a refresh token that is still
--    valid cannot recreate them (a Firebase session id is stable for the life of the sign-in). Store.PurgeSessions
--    now removes one 400 days after the sign-out when the identity's "signed out everywhere" watermark
--    (auth_identities.sessions_revoked_before) already covers it, because the watermark refuses that sign-in without
--    a session row. This index serves its walk (a cursor in reconcile_state) in revocation order.

-- 1
CREATE OR REPLACE FUNCTION drop_pending_case(p_case uuid, p_actor text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE;
BEGIN
  SELECT * INTO c FROM content_cases WHERE case_id = p_case AND status = 'pending' AND result = 'flagged' AND created_at < now() - interval '1 hour' FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  DELETE FROM content_cases WHERE case_id = p_case;
  UPDATE media_assets SET status = 'deleted', variants = NULL, deleted_at = coalesce(deleted_at, now()) WHERE media_id = c.media_id AND status = 'quarantined';
  INSERT INTO operator_audit(actor, action, target_type, target_id, reason, detail)
  VALUES (p_actor, 'pending_case_dropped', 'content_case', p_case::text, 'evidence objects were never written',
          jsonb_build_object('mediaId', c.media_id, 'userId', c.user_id, 'result', c.result, 'suspendedUser', c.suspended_user));
  RETURN true;
END
$$;
REVOKE ALL ON FUNCTION drop_pending_case(uuid, text) FROM PUBLIC;

UPDATE media_assets SET deleted_at = now() WHERE status = 'deleted' AND deleted_at IS NULL;

-- 2
CREATE INDEX sessions_revoked_tombstones ON sessions (revoked_at, session_id) WHERE revoked_at IS NOT NULL AND external_sid IS NOT NULL;
