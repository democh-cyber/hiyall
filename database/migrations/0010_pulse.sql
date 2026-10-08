-- Pulse: photos, posts, reactions, comments, saves and stories.
--
-- Bytes never live here. media_assets tracks an object through upload
-- (pending, private upload key) to ready (re-encoded variants with all
-- metadata such as GPS stripped). Signed URLs are issued per read after the
-- viewer is authorized for the post or story that uses the media.
CREATE TABLE IF NOT EXISTS media_assets (
  media_id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES users(user_id),
  purpose text NOT NULL CHECK (purpose IN ('post','story')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ready','deleted')),
  content_type text NOT NULL,
  size_bytes bigint NOT NULL,
  width int,
  height int,
  upload_key text NOT NULL,
  variants jsonb,
  attached boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  deleted_at timestamptz
);
CREATE INDEX IF NOT EXISTS media_owner ON media_assets(owner_id,created_at DESC);
-- Cleanup: abandoned uploads, and unattached or deleted media past expiry.
CREATE INDEX IF NOT EXISTS media_expiry ON media_assets(expires_at) WHERE status<>'deleted' AND NOT attached;
CREATE INDEX IF NOT EXISTS media_deleted ON media_assets(deleted_at) WHERE status='deleted' AND variants IS NOT NULL;

CREATE TABLE IF NOT EXISTS posts (
  post_id uuid PRIMARY KEY,
  author_id uuid NOT NULL REFERENCES users(user_id),
  body text NOT NULL DEFAULT '',
  audience text NOT NULL CHECK (audience IN ('public','followers','friends')),
  created_at timestamptz NOT NULL DEFAULT now(),
  edited_at timestamptz,
  deleted_at timestamptz
);
-- Author timelines and the following feed (one probe per followed author).
CREATE INDEX IF NOT EXISTS posts_author ON posts(author_id,created_at DESC,post_id DESC) WHERE deleted_at IS NULL;
-- The public "everyone" feed.
CREATE INDEX IF NOT EXISTS posts_public ON posts(created_at DESC,post_id DESC) WHERE deleted_at IS NULL AND audience='public';

CREATE TABLE IF NOT EXISTS post_media (
  post_id uuid NOT NULL REFERENCES posts(post_id),
  position smallint NOT NULL CHECK (position BETWEEN 0 AND 9),
  media_id uuid NOT NULL UNIQUE REFERENCES media_assets(media_id),
  alt_text text,
  PRIMARY KEY (post_id,position)
);

-- Counts are spread over 8 slots per post so a viral post's likes don't all
-- queue on one row; reads sum the slots for a page of posts at once.
CREATE TABLE IF NOT EXISTS post_counters (
  post_id uuid NOT NULL REFERENCES posts(post_id),
  slot smallint NOT NULL CHECK (slot BETWEEN 0 AND 7),
  reactions int NOT NULL DEFAULT 0,
  comments int NOT NULL DEFAULT 0,
  PRIMARY KEY (post_id,slot)
);

CREATE TABLE IF NOT EXISTS post_reactions (
  post_id uuid NOT NULL REFERENCES posts(post_id),
  user_id uuid NOT NULL REFERENCES users(user_id),
  reaction text NOT NULL CHECK (reaction IN ('heart','fire','laugh','wow','sad')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id,user_id)
);
CREATE INDEX IF NOT EXISTS post_reactions_user ON post_reactions(user_id,created_at DESC);

CREATE TABLE IF NOT EXISTS comments (
  comment_id uuid PRIMARY KEY,
  post_id uuid NOT NULL REFERENCES posts(post_id),
  author_id uuid NOT NULL REFERENCES users(user_id),
  parent_id uuid REFERENCES comments(comment_id),
  body text NOT NULL,
  -- Comments from someone the post's author restricted are shown only to
  -- their writer and are not counted.
  hidden boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);
CREATE INDEX IF NOT EXISTS comments_post ON comments(post_id,created_at,comment_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS comments_author ON comments(author_id,created_at DESC);

CREATE TABLE IF NOT EXISTS saved_posts (
  user_id uuid NOT NULL REFERENCES users(user_id),
  post_id uuid NOT NULL REFERENCES posts(post_id),
  saved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id,post_id)
);
CREATE INDEX IF NOT EXISTS saved_posts_list ON saved_posts(user_id,saved_at DESC,post_id DESC);

CREATE TABLE IF NOT EXISTS stories (
  story_id uuid PRIMARY KEY,
  author_id uuid NOT NULL REFERENCES users(user_id),
  media_id uuid UNIQUE REFERENCES media_assets(media_id),
  body text NOT NULL DEFAULT '',
  background text NOT NULL DEFAULT 'lime',
  audience text NOT NULL CHECK (audience IN ('public','followers','friends')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  deleted_at timestamptz,
  CHECK (media_id IS NOT NULL OR body<>'')
);
CREATE INDEX IF NOT EXISTS stories_author ON stories(author_id,expires_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS stories_expiry ON stories(expires_at);

CREATE TABLE IF NOT EXISTS story_views (
  story_id uuid NOT NULL REFERENCES stories(story_id) ON DELETE CASCADE,
  viewer_id uuid NOT NULL REFERENCES users(user_id),
  viewed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (story_id,viewer_id)
);
CREATE INDEX IF NOT EXISTS story_views_list ON story_views(story_id,viewed_at DESC,viewer_id);

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_event_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_event_check CHECK (event IN
  ('follow.started','follow.requested','follow.accepted','friend.requested','friend.accepted','post.reacted','post.commented'));
