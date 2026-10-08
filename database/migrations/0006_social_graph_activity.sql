-- Follow/friend workflows and the recipient-only activity feed.
-- Notifications reference the actor and are filtered by current blocks and
-- account status at read time; text is rendered by the API, never stored.
CREATE INDEX friendships_low_pending ON friendships(user_low_id, created_at DESC) WHERE status='pending';
CREATE INDEX friendships_high_pending ON friendships(user_high_id, created_at DESC) WHERE status='pending';
CREATE INDEX follows_in_pending ON follows(followee_id, created_at DESC) WHERE state='pending';

CREATE TABLE notifications (
  notification_id uuid PRIMARY KEY,
  recipient_id uuid NOT NULL REFERENCES users(user_id),
  actor_id uuid NOT NULL REFERENCES users(user_id),
  event text NOT NULL CHECK (event IN ('follow.started','follow.requested','follow.accepted','friend.requested','friend.accepted')),
  target_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  CHECK (recipient_id <> actor_id),
  -- Repeating an action refreshes one row instead of flooding the recipient.
  UNIQUE (recipient_id, actor_id, event)
);
CREATE INDEX notifications_feed ON notifications(recipient_id, created_at DESC, notification_id DESC);
CREATE INDEX notifications_unread ON notifications(recipient_id) WHERE read_at IS NULL;
CREATE INDEX notifications_actor ON notifications(actor_id);
