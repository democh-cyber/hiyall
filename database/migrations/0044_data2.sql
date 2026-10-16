-- Data release 2 (round-3 audit DB-NEW-4..8, N11). Plain CREATE INDEX statements, like 0039: added while the
-- tables are small; use CONCURRENTLY in a "-- hiyall:no-transaction" file for an index added to a big table later.
--
-- 1. Full indexes the account purge and the foreign key checks need: devices(user_id) (devices_user_active is
--    partial, so the purge of a member's revoked devices and the users foreign key scanned the table),
--    conversation_members(peer_id) (the peer foreign key and "DELETE ... WHERE peer_id=$1").
-- 2. reports: target_id (the purge, the retention jobs and "is this row under an open report" looked a report up by
--    its target with a scan) and a small partial index of the reports that carry evidence, so the list of reported
--    message ids is read from those rows only.
-- 3. messages keyset: PurgeMessageMetadata walks messages in (created_at, message_id) order from a cursor. The
--    old messages_age(created_at) is replaced by it (it serves every ordering the old one did).
-- 4. media cleanup keyset: PurgeMedia reads the two kinds of work (expired uploads, deleted photos with objects)
--    each in index order from a cursor instead of sorting the whole backlog for every chunk of 50. Expired uploads
--    are ordered by media_expiry (expires_at) as it is; deleted photos need (deleted_at, media_id), which replaces
--    media_deleted.
-- 5. friendships(user_high_id, user_low_id) replaces friendships_high(user_high_id): the same lookups, and the
--    counter fix-up job can walk a member's friends in key order from either side.
-- 6. operator_audit(at): prune_operator_audit looks for an entry older than its cutoff before it locks the table,
--    so a call with nothing to prune takes no ALTER TABLE lock at all.
-- 7. users_status_counters (suspension, restore, deactivation) no longer touches every neighbour's counter row in
--    one statement. Up to 20000 neighbours are done in the trigger as before; for a bigger account the trigger
--    queues the work (counter_fixups) and the maintenance job recounts the neighbours in chunks of 500
--    (Store.ApplyCounterFixups). The suspension itself then costs a bounded read, never the 5 s statement
--    timeout. See docs/database/03-database-design.md, "Counters of a very large account".

-- 1
CREATE INDEX devices_user ON devices (user_id);
CREATE INDEX conversation_members_peer ON conversation_members (peer_id);

-- 2
CREATE INDEX reports_target ON reports (target_id);
CREATE INDEX reports_with_evidence ON reports (report_id) WHERE evidence IS NOT NULL;

-- 3
CREATE INDEX messages_age_key ON messages (created_at, message_id);
DROP INDEX messages_age;

-- 4
-- Every code path sets deleted_at with status 'deleted'; a row without it would never be found by the keyset below.
UPDATE media_assets SET deleted_at = coalesce(deleted_at, created_at) WHERE status = 'deleted' AND deleted_at IS NULL;
CREATE INDEX media_cleanup_deleted ON media_assets (deleted_at, media_id) WHERE status = 'deleted' AND variants IS NOT NULL;
DROP INDEX media_deleted;

-- 5
CREATE INDEX friendships_high_low ON friendships (user_high_id, user_low_id);
DROP INDEX friendships_high;

-- 6
CREATE INDEX operator_audit_at ON operator_audit (at);

CREATE OR REPLACE FUNCTION prune_operator_audit(p_operator uuid, p_actor text, p_reason text, p_older_than_days integer DEFAULT 365) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET lock_timeout = '2s' AS $$
DECLARE removed bigint; cutoff timestamptz;
BEGIN
  IF p_older_than_days IS NULL OR p_older_than_days < 365 THEN
    RAISE EXCEPTION 'audit entries younger than 365 days are never pruned' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023';
  END IF;
  cutoff := now() - make_interval(days => p_older_than_days);
  -- Nothing old enough: answer before the table lock below is asked for (operator_audit_at makes this one probe).
  IF NOT EXISTS (SELECT 1 FROM operator_audit WHERE at < cutoff) THEN
    RETURN 0;
  END IF;
  -- One batch: the caller repeats until it gets fewer than 5000 back.
  ALTER TABLE operator_audit DISABLE TRIGGER operator_audit_no_change;
  DELETE FROM operator_audit WHERE audit_id IN (SELECT audit_id FROM operator_audit WHERE at < cutoff ORDER BY audit_id LIMIT 5000);
  GET DIAGNOSTICS removed = ROW_COUNT;
  ALTER TABLE operator_audit ENABLE TRIGGER operator_audit_no_change;
  IF removed > 0 THEN
    INSERT INTO operator_audit(operator_id, actor, action, target_type, target_id, reason, detail)
    VALUES (p_operator, p_actor, 'audit_prune', 'operator_audit', '', p_reason,
            jsonb_build_object('deleted', removed, 'olderThanDays', p_older_than_days, 'cutoff', cutoff, 'batchLimit', 5000));
  END IF;
  RETURN removed;
END
$$;
REVOKE ALL ON FUNCTION prune_operator_audit(uuid, text, text, integer) FROM PUBLIC;

-- 7
-- One row per account whose neighbours' counters still have to be recounted. stream: 0 the accounts it follows,
-- 1 its followers, 2 friends with a higher id, 3 friends with a lower id. after_ts / after_id is the keyset position
-- inside the stream (the sentinel is "before the first row").
CREATE TABLE counter_fixups (
  user_id uuid PRIMARY KEY,
  stream smallint NOT NULL DEFAULT 0 CHECK (stream BETWEEN 0 AND 3),
  after_ts timestamptz NOT NULL DEFAULT 'infinity',
  after_id uuid NOT NULL DEFAULT 'ffffffff-ffff-ffff-ffff-ffffffffffff',
  queued_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX counter_fixups_queue ON counter_fixups (queued_at);

CREATE OR REPLACE FUNCTION users_status_counters() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE sign int := CASE WHEN NEW.status = 'active' THEN 1 ELSE -1 END; edges int;
BEGIN
  -- At most 20001 edges are looked at: enough to know whether this account is small.
  SELECT count(*) INTO edges FROM (
    SELECT 1 FROM follows WHERE follower_id = NEW.user_id AND state = 'active'
    UNION ALL SELECT 1 FROM follows WHERE followee_id = NEW.user_id AND state = 'active'
    UNION ALL SELECT 1 FROM friendships WHERE user_low_id = NEW.user_id AND status = 'accepted'
    UNION ALL SELECT 1 FROM friendships WHERE user_high_id = NEW.user_id AND status = 'accepted'
    LIMIT 20001) x;
  -- A big account, or one whose last recount is still running (a delta now would be counted twice by it): queue
  -- the recount from the start. The row lock makes a job chunk in flight finish first.
  IF edges > 20000 OR EXISTS (SELECT 1 FROM counter_fixups WHERE user_id = NEW.user_id) THEN
    INSERT INTO counter_fixups(user_id) VALUES (NEW.user_id)
    ON CONFLICT (user_id) DO UPDATE SET stream = 0, after_ts = 'infinity', after_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff', queued_at = now();
    RETURN NULL;
  END IF;
  INSERT INTO social_counters(user_id, followers, following, friends)
  SELECT x.uid, sum(x.f1), sum(x.f2), sum(x.f3) FROM (
    SELECT followee_id AS uid, sign AS f1, 0 AS f2, 0 AS f3 FROM follows WHERE follower_id = NEW.user_id AND state = 'active'
    UNION ALL SELECT follower_id, 0, sign, 0 FROM follows WHERE followee_id = NEW.user_id AND state = 'active'
    UNION ALL SELECT user_high_id, 0, 0, sign FROM friendships WHERE user_low_id = NEW.user_id AND status = 'accepted'
    UNION ALL SELECT user_low_id, 0, 0, sign FROM friendships WHERE user_high_id = NEW.user_id AND status = 'accepted'
  ) x GROUP BY x.uid ORDER BY x.uid
  ON CONFLICT (user_id) DO UPDATE SET followers = social_counters.followers + excluded.followers,
    following = social_counters.following + excluded.following, friends = social_counters.friends + excluded.friends, updated_at = now();
  RETURN NULL;
END $$;
