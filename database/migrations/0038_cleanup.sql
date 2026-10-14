-- Cleanup and the last audit items (D5, D9, D16, G8, admin evidence holds and audit retention).
--
-- D5: nothing has read or written outbox_events or users.aggregate_version since 0037 (the API stopped, and the
-- release before that is gone), so both are dropped. Contract step of the expand and contract that 0037 began.
DROP TABLE IF EXISTS outbox_events;
ALTER TABLE users DROP COLUMN IF EXISTS aggregate_version;

-- D16: Nearby reads its candidates through a GiST index on point(longitude, latitude), built-in geometric types
-- and no extension. The bounding box is "point <@ box(...)" and the nearest candidates come out of the index
-- in order ("point <-> centre"), so the API can cap them (store.NearbyCandidateCap). It replaces the B-tree
-- on (latitude, longitude), which could only narrow one axis.
DROP INDEX IF EXISTS user_locations_point;
CREATE INDEX user_locations_point_gist ON user_locations USING gist (point(longitude, latitude));

-- G8: idempotency for creating posts, stories and space entries. A client sends an Idempotency-Key header (a
-- UUID it makes once per attempt and reuses on every retry). The key is claimed in the same transaction that
-- creates the item, so a retry after a lost response, or two requests racing, create it once; the retry
-- is answered with the original result. scope says what was created (post, story, entry:<space id>) and
-- request_hash the body it was created from, so a key reused for something else is refused and not answered
-- with an unrelated item. A job removes keys after 24 hours.
CREATE TABLE idempotency_keys (
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  key uuid NOT NULL,
  scope text NOT NULL,
  request_hash bytea NOT NULL,
  ref_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);
CREATE INDEX idempotency_keys_created ON idempotency_keys(created_at);

-- Evidence holds: release, and removal of the held objects once the retention window has passed
-- (docs/security/16-csam-and-illegal-content.md section 9).
--
-- A quarantine case holds its photo under hold/ in the media bucket. An administrator can now release the hold
-- (POST /admin/v1/holds/{id}/release, with a reason, audited) once the case is not open, no legal hold is set
-- and no open member report or other open case is about the same member. Releasing deletes nothing by itself:
-- the API's maintenance job removes the objects at hold_until (90 days after detection by default), or
-- at once if that has passed, and records it. The case row, with the hash and the times, stays as the record.
ALTER TABLE content_cases ADD COLUMN released_at timestamptz;
ALTER TABLE content_cases ADD COLUMN released_by text;
ALTER TABLE content_cases ADD COLUMN release_reason text;
ALTER TABLE content_cases ADD COLUMN objects_purged_at timestamptz;
CREATE INDEX content_cases_release_due ON content_cases(hold_until) WHERE released_at IS NOT NULL AND objects_purged_at IS NULL;

-- Why a hold may not be released (NULL: it may). One definition for the console's check, the release and the
-- purge, so the three cannot disagree. A case is bound by: being open, a legal hold, an open member report
-- about the uploader, another open case of the same uploader.
CREATE FUNCTION hold_release_blocker(p_case uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN c.status = 'open' THEN 'CASE_OPEN'
    WHEN c.legal_hold THEN 'LEGAL_HOLD'
    WHEN EXISTS (SELECT 1 FROM reports r WHERE r.status = 'open' AND r.subject_id = c.user_id) THEN 'REPORT_OPEN'
    WHEN EXISTS (SELECT 1 FROM content_cases o WHERE o.case_id <> c.case_id AND o.user_id = c.user_id AND o.status = 'open') THEN 'OTHER_CASE_OPEN'
  END
  FROM content_cases c WHERE c.case_id = p_case
$$;

-- What the API's maintenance job may do with held objects, without any other access to content_cases (the API
-- role cannot read or change a case, and this keeps it that way): list the objects of released holds that are
-- due, and record that they are gone. Both run with the owner's rights and re-check every condition.
CREATE FUNCTION held_objects_due(p_limit integer) RETURNS TABLE(case_id uuid, original_key text, full_key text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT c.case_id, c.original_key, c.full_key FROM content_cases c
  WHERE c.released_at IS NOT NULL AND c.objects_purged_at IS NULL AND c.hold_until <= now() AND hold_release_blocker(c.case_id) IS NULL
  ORDER BY c.hold_until LIMIT p_limit
$$;

CREATE FUNCTION mark_hold_purged(p_case uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE done boolean;
BEGIN
  UPDATE content_cases c SET objects_purged_at = now()
   WHERE c.case_id = p_case AND c.released_at IS NOT NULL AND c.objects_purged_at IS NULL AND c.hold_until <= now()
     AND hold_release_blocker(c.case_id) IS NULL;
  done := FOUND;
  IF done THEN
    INSERT INTO operator_audit(actor, action, target_type, target_id, reason, detail)
    VALUES ('system:hold-purge', 'hold_objects_purged', 'content_case', p_case::text, 'hold released and retention window over', '{}'::jsonb);
  END IF;
  RETURN done;
END
$$;
REVOKE ALL ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid) FROM PUBLIC;

-- Operator audit retention: the log is append-only for everyone, and an administrator may prune what is older
-- than a year. The trigger that refuses UPDATE and DELETE stays on for all roles; this function, which runs with
-- its owner's rights (the migration role, the table's owner, so no one else can do the same), switches it off
-- for the one DELETE and on again in the same transaction, so a failure leaves it on. It writes its own audit
-- entry in the same transaction, and it will not delete anything younger than 365 days whatever it is asked.
CREATE FUNCTION prune_operator_audit(p_operator uuid, p_actor text, p_reason text, p_older_than_days integer DEFAULT 365) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE removed bigint; cutoff timestamptz;
BEGIN
  IF p_older_than_days IS NULL OR p_older_than_days < 365 THEN
    RAISE EXCEPTION 'audit entries younger than 365 days are never pruned' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023';
  END IF;
  cutoff := now() - make_interval(days => p_older_than_days);
  ALTER TABLE operator_audit DISABLE TRIGGER operator_audit_no_change;
  DELETE FROM operator_audit WHERE at < cutoff;
  GET DIAGNOSTICS removed = ROW_COUNT;
  ALTER TABLE operator_audit ENABLE TRIGGER operator_audit_no_change;
  INSERT INTO operator_audit(operator_id, actor, action, target_type, target_id, reason, detail)
  VALUES (p_operator, p_actor, 'audit_prune', 'operator_audit', '', p_reason,
          jsonb_build_object('deleted', removed, 'olderThanDays', p_older_than_days, 'cutoff', cutoff));
  RETURN removed;
END
$$;
REVOKE ALL ON FUNCTION prune_operator_audit(uuid, text, text, integer) FROM PUBLIC;
