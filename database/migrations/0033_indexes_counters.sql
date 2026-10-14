-- Indexes for foreign keys and list queries, counter tables, and retention indexes
-- (audit D1, D2, D6, D7, D11, D13, F21).
--
-- Plain CREATE INDEX is used on purpose: every table here is empty or tiny before launch, so the build takes no
-- meaningful lock. Once these tables hold data, new indexes must use CREATE INDEX CONCURRENTLY in a migration
-- file marked no-transaction.

-- 1. Foreign keys that had no supporting index. Each made a delete or purge of the referenced row scan the
--    whole referencing table.
CREATE INDEX comments_parent ON comments(parent_id) WHERE parent_id IS NOT NULL;
-- The listing index was partial (live comments only); the purge and the hard delete need every comment of a post.
DROP INDEX comments_post;
CREATE INDEX comments_post ON comments(post_id, created_at, comment_id);
CREATE INDEX saved_posts_post ON saved_posts(post_id);
CREATE INDEX messages_sender_device ON messages(sender_device_id);
DROP INDEX chat_blobs_conversation;
CREATE INDEX chat_blobs_conversation ON chat_blobs(conversation_id);
CREATE INDEX conversation_members_conversation ON conversation_members(conversation_id);

-- Columns the account purge deletes by.
CREATE INDEX space_entries_author ON space_entries(author_id);
CREATE INDEX story_views_viewer ON story_views(viewer_id);
CREATE INDEX user_controls_target ON user_controls(target_id);
CREATE INDEX key_claims_claimer ON key_claims(claimer_id);
CREATE INDEX spaces_owner ON spaces(owner_id);
DROP INDEX space_members_user;
CREATE INDEX space_members_user ON space_members(user_id, space_id);

-- 2. Conversations: the new-chat quota counts by creator and window; the pair lookups lead with user_high_id.
CREATE INDEX conversations_creator ON conversations(created_by, created_at);
CREATE INDEX conversations_high ON conversations(user_high_id);
-- "Has the peer replied" (non-reaction messages of one sender in one conversation).
CREATE INDEX messages_conversation_sender ON messages(conversation_id, sender_id) WHERE NOT aux;

-- 3. Followers and following pages: one index per direction, ordered like the page, covering every state so the
--    partial indexes for active and pending edges are no longer needed.
CREATE INDEX follows_followee_list ON follows(followee_id, state, created_at DESC, follower_id DESC);
CREATE INDEX follows_follower_list ON follows(follower_id, state, created_at DESC, followee_id DESC);
DROP INDEX follows_out_active;
DROP INDEX follows_in_active;
DROP INDEX follows_in_pending;

-- sessions_expiry (expires_at alone) is redundant (audit G4): every query that filters on sessions.expires_at also
-- has an equality on user_id, session_id, access_token_hash or issuer+external_sid, and the hourly purge, the
-- only one that scans by expiry, matches the partial sessions_purgeable index (migration 0020).
DROP INDEX sessions_expiry;

-- 4. Retention jobs (docs/legal/data-retention.md) find their rows by age.
CREATE INDEX notifications_age ON notifications(created_at);
CREATE INDEX reports_closed_age ON reports(resolved_at) WHERE status <> 'open';
CREATE INDEX posts_deleted ON posts(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX comments_deleted ON comments(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX space_entries_deleted ON space_entries(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX messages_age ON messages(created_at);
CREATE INDEX media_tombstones ON media_assets(deleted_at) WHERE status = 'deleted' AND variants IS NULL;
-- PurgeChatBlobTombstones: deleted blobs whose object is gone, oldest first.
CREATE INDEX chat_blobs_tombstones ON chat_blobs(created_at) WHERE state = 'deleted' AND object_key IS NULL AND held_report_id IS NULL;

-- A deleted space entry is blanked by the retention job, so the 1-2000 character rule applies to live ones only.
ALTER TABLE space_entries DROP CONSTRAINT space_entries_body_check;
ALTER TABLE space_entries ADD CONSTRAINT space_entries_body_check CHECK (deleted_at IS NOT NULL OR length(body) BETWEEN 1 AND 2000);

-- 5. Social counters (D6). followers, following and friends are kept by triggers in the transaction that
--    changes the edge or the other member's status, replacing the profile_social_counts view on the profile
--    read path. They count what the view counted: active follows and accepted friendships whose other side is
--    an active account. A missing row means zero; negative values (only possible through drift) read as zero
--    and are repaired by the weekly reconcile job.
CREATE TABLE social_counters (
  user_id uuid PRIMARY KEY REFERENCES users(user_id),
  followers integer NOT NULL DEFAULT 0,
  following integer NOT NULL DEFAULT 0,
  friends integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO social_counters(user_id, followers, following, friends)
SELECT user_id, followers, following, friends FROM profile_social_counts WHERE followers + following + friends > 0;

-- Adds the deltas to the counter rows. Rows are written in user id order so two transactions touching the same
-- two members never wait on each other in opposite orders.
CREATE FUNCTION social_bump(a uuid, a_followers int, a_following int, a_friends int,
                            b uuid, b_followers int, b_following int, b_friends int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO social_counters(user_id, followers, following, friends)
  SELECT v.uid, sum(v.f1), sum(v.f2), sum(v.f3)
  FROM (VALUES (a, a_followers, a_following, a_friends), (b, b_followers, b_following, b_friends)) v(uid, f1, f2, f3)
  WHERE v.uid IS NOT NULL
  GROUP BY v.uid HAVING sum(v.f1) <> 0 OR sum(v.f2) <> 0 OR sum(v.f3) <> 0
  ORDER BY v.uid
  ON CONFLICT (user_id) DO UPDATE SET followers = social_counters.followers + excluded.followers,
    following = social_counters.following + excluded.following, friends = social_counters.friends + excluded.friends, updated_at = now()
$$;

CREATE FUNCTION social_follow_apply(f uuid, e uuid, s text, sign int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE f_active boolean; e_active boolean;
BEGIN
  IF s <> 'active' THEN RETURN; END IF;
  SELECT status = 'active' INTO f_active FROM users WHERE user_id = f;
  SELECT status = 'active' INTO e_active FROM users WHERE user_id = e;
  -- The followee gains a follower when the follower is active; the follower gains a followee when the followee is.
  PERFORM social_bump(e, CASE WHEN f_active THEN sign ELSE 0 END, 0, 0, f, 0, CASE WHEN e_active THEN sign ELSE 0 END, 0);
END $$;

CREATE FUNCTION social_friend_apply(lo uuid, hi uuid, s text, sign int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE lo_active boolean; hi_active boolean;
BEGIN
  IF s <> 'accepted' THEN RETURN; END IF;
  SELECT status = 'active' INTO lo_active FROM users WHERE user_id = lo;
  SELECT status = 'active' INTO hi_active FROM users WHERE user_id = hi;
  PERFORM social_bump(lo, 0, 0, CASE WHEN hi_active THEN sign ELSE 0 END, hi, 0, 0, CASE WHEN lo_active THEN sign ELSE 0 END);
END $$;

CREATE FUNCTION follows_counters() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN PERFORM social_follow_apply(OLD.follower_id, OLD.followee_id, OLD.state, -1); END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN PERFORM social_follow_apply(NEW.follower_id, NEW.followee_id, NEW.state, 1); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER follows_counters AFTER INSERT OR DELETE OR UPDATE OF state, follower_id, followee_id ON follows
  FOR EACH ROW EXECUTE FUNCTION follows_counters();

CREATE FUNCTION friendships_counters() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN PERFORM social_friend_apply(OLD.user_low_id, OLD.user_high_id, OLD.status, -1); END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN PERFORM social_friend_apply(NEW.user_low_id, NEW.user_high_id, NEW.status, 1); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER friendships_counters AFTER INSERT OR DELETE OR UPDATE OF status, user_low_id, user_high_id ON friendships
  FOR EACH ROW EXECUTE FUNCTION friendships_counters();

-- An account that stops being active (suspended, deactivated, pending deletion, banned) leaves its neighbours'
-- counts, and comes back into them when it is active again.
CREATE FUNCTION users_status_counters() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE sign int := CASE WHEN NEW.status = 'active' THEN 1 ELSE -1 END;
BEGIN
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
CREATE TRIGGER users_status_counters AFTER UPDATE OF status ON users
  FOR EACH ROW WHEN ((OLD.status = 'active') <> (NEW.status = 'active')) EXECUTE FUNCTION users_status_counters();

-- 6. Reconcile progress (F21). The weekly jobs that recompute social counters, post counters and space member
--    counts walk their table in key order and remember where they stopped, so a restart or a leader change
--    carries on instead of beginning again; finished_at gates the next full pass.
CREATE TABLE reconcile_state (
  job text PRIMARY KEY,
  cursor text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
