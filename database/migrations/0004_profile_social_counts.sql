-- Read foundation for profile statistics. Relationship creation/approval APIs
-- remain a separate feature; no synthetic relationships are seeded here.
CREATE TABLE friendships (
  friendship_id uuid PRIMARY KEY,
  user_low_id uuid NOT NULL REFERENCES users(user_id),
  user_high_id uuid NOT NULL REFERENCES users(user_id),
  requested_by uuid NOT NULL REFERENCES users(user_id),
  status text NOT NULL CHECK (status IN ('pending','accepted','declined','cancelled','removed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_low_id,user_high_id),
  CHECK (user_low_id < user_high_id),
  CHECK (requested_by IN (user_low_id,user_high_id))
);
CREATE INDEX friendships_low_active ON friendships(user_low_id) WHERE status='accepted';
CREATE INDEX friendships_high_active ON friendships(user_high_id) WHERE status='accepted';
CREATE TABLE follows (
  follower_id uuid NOT NULL REFERENCES users(user_id),
  followee_id uuid NOT NULL REFERENCES users(user_id),
  state text NOT NULL CHECK (state IN ('pending','active','removed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  source text NOT NULL DEFAULT 'profile',
  PRIMARY KEY (follower_id,followee_id),
  CHECK (follower_id <> followee_id)
);
CREATE INDEX follows_out_active ON follows(follower_id) WHERE state='active';
CREATE INDEX follows_in_active ON follows(followee_id) WHERE state='active';

-- Counts are derived at read time and cannot be overwritten through profile JSON.
CREATE VIEW profile_social_counts AS
SELECT u.user_id,
  (SELECT count(*) FROM friendships f
   JOIN users other ON other.user_id=CASE WHEN f.user_low_id=u.user_id THEN f.user_high_id ELSE f.user_low_id END
   WHERE (f.user_low_id=u.user_id OR f.user_high_id=u.user_id)
     AND f.status='accepted' AND other.status='active'
     AND NOT EXISTS (SELECT 1 FROM blocks b WHERE
       (b.blocker_id=u.user_id AND b.blocked_id=other.user_id) OR
       (b.blocker_id=other.user_id AND b.blocked_id=u.user_id))) AS friends,
  (SELECT count(*) FROM follows f JOIN users other ON other.user_id=f.followee_id
   WHERE f.follower_id=u.user_id AND f.state='active' AND other.status='active'
     AND NOT EXISTS (SELECT 1 FROM blocks b WHERE
       (b.blocker_id=u.user_id AND b.blocked_id=other.user_id) OR
       (b.blocker_id=other.user_id AND b.blocked_id=u.user_id))) AS following,
  (SELECT count(*) FROM follows f JOIN users other ON other.user_id=f.follower_id
   WHERE f.followee_id=u.user_id AND f.state='active' AND other.status='active'
     AND NOT EXISTS (SELECT 1 FROM blocks b WHERE
       (b.blocker_id=u.user_id AND b.blocked_id=other.user_id) OR
       (b.blocker_id=other.user_id AND b.blocked_id=u.user_id))) AS followers
FROM users u;
