-- hiyall:allow-locking-index: Hiyall has not launched, so posts and comments hold no real data yet and the indexes below build instantly; the file stays one transaction (also what the test databases apply).
-- Wave 7 social features (docs/api/27-stories-notices-support.md). Every statement is idempotent. A later migration
-- that indexes these tables once they are large must use CONCURRENTLY outside a transaction (cmd/migrate lint).
--
-- 1. Topics: posts.topic and stories.topic hold one of the server's topic names (domain.Topics). The database only
--    checks the shape of the name, so a new topic is a code change and never another migration.
-- 2. Search: GIN indexes over to_tsvector('simple', body), the expression the queries use. No stored column, so no
--    table rewrite.
-- 3. Voice: a post or story may carry one voice clip (media_assets.purpose 'voice', audio/mp4, at most 60 s). The clip
--    is validated, not transcoded, and not scanned (scan_result stays NULL). voice_ms is the duration the server read
--    from the file. A story may now be only a voice clip.
-- 4. Threaded comments: replies are one level deep (comments.parent_id already exists). An index serves "replies of
--    this comment" and the reply counts. Two new notification events: comment.replied and profile.visited.
-- 5. Notification choices per category, a master switch and the hide-names option (extends notification_prefs).
-- 6. Notice board (notices, notice_seen): staff posts, a "last seen" pointer per member for the unread dot.
-- 7. In-app support threads (support_threads, support_messages): plaintext, kept 365 days after the thread closes.

-- 1
ALTER TABLE posts ADD COLUMN IF NOT EXISTS topic text CHECK (topic ~ '^[a-z]{1,24}$');
ALTER TABLE stories ADD COLUMN IF NOT EXISTS topic text CHECK (topic ~ '^[a-z]{1,24}$');

-- 3
ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_purpose_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_purpose_check CHECK (purpose IN ('post','story','avatar','voice'));
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS duration_ms integer CHECK (duration_ms IS NULL OR duration_ms BETWEEN 1 AND 120000);
ALTER TABLE posts ADD COLUMN IF NOT EXISTS voice_media_id uuid UNIQUE REFERENCES media_assets(media_id);
ALTER TABLE posts ADD COLUMN IF NOT EXISTS voice_ms integer CHECK (voice_ms IS NULL OR voice_ms BETWEEN 1 AND 120000);
ALTER TABLE stories ADD COLUMN IF NOT EXISTS voice_media_id uuid UNIQUE REFERENCES media_assets(media_id);
ALTER TABLE stories ADD COLUMN IF NOT EXISTS voice_ms integer CHECK (voice_ms IS NULL OR voice_ms BETWEEN 1 AND 120000);
ALTER TABLE stories DROP CONSTRAINT IF EXISTS stories_check;
ALTER TABLE stories DROP CONSTRAINT IF EXISTS stories_content_check;
ALTER TABLE stories ADD CONSTRAINT stories_content_check CHECK (media_id IS NOT NULL OR voice_media_id IS NOT NULL OR body <> '');

-- 4
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_event_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_event_check CHECK (event IN
  ('follow.started','follow.requested','follow.accepted','friend.requested','friend.accepted','post.reacted','post.commented',
   'space.invited','space.requested','space.approved','comment.replied','profile.visited'));

-- 5
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true;
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS follows boolean NOT NULL DEFAULT true;
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS comments boolean NOT NULL DEFAULT true;
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS reactions boolean NOT NULL DEFAULT true;
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS replies boolean NOT NULL DEFAULT true;
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS friend_requests boolean NOT NULL DEFAULT true;
-- Profile visit notices are an owner opt-in: off until the member turns them on.
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS visits boolean NOT NULL DEFAULT false;
-- NULL means "the default for this member": names hidden for a minor, shown for an adult. true/false is the member's choice.
ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS hide_names boolean;
-- A member who had switched the old "social" switch off keeps every social category off.
UPDATE notification_prefs SET follows = false, comments = false, reactions = false, replies = false, friend_requests = false WHERE NOT social;

-- 6
CREATE TABLE IF NOT EXISTS notices (
  notice_id uuid PRIMARY KEY,
  category text NOT NULL CHECK (category IN ('safety','news','update')),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 4000),
  audience text NOT NULL DEFAULT 'all' CHECK (audience IN ('all','minors','adults')),
  -- '' is every language; otherwise a language code ('en', 'hi', 'pt-BR'): a viewer's language matches on its first subtag.
  locale text NOT NULL DEFAULT '' CHECK (locale ~ '^([a-z]{2,3}(-[A-Za-z0-9]{2,8})*)?$'),
  pinned boolean NOT NULL DEFAULT false,
  published_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  unpublished_at timestamptz,
  created_by uuid NOT NULL REFERENCES operators(operator_id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES operators(operator_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (expires_at IS NULL OR expires_at > published_at)
);
-- The member feed: live notices of an audience, newest first.
CREATE INDEX IF NOT EXISTS notices_feed ON notices (published_at DESC, notice_id DESC) WHERE unpublished_at IS NULL;
-- One pointer per member: "I have seen everything published up to here". No per-notice reads, no tracking.
CREATE TABLE IF NOT EXISTS notice_seen (
  user_id uuid PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  seen_at timestamptz NOT NULL DEFAULT now()
);

-- 7
CREATE TABLE IF NOT EXISTS support_threads (
  thread_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  category text NOT NULL CHECK (category IN ('account','safety','bug','other')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  assigned_to uuid REFERENCES operators(operator_id),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz NOT NULL DEFAULT now(),
  last_author text NOT NULL DEFAULT 'member' CHECK (last_author IN ('member','staff')),
  -- The member's own pointer: a staff message newer than this is unread.
  member_read_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz
);
-- One open thread per member and category.
CREATE UNIQUE INDEX IF NOT EXISTS support_threads_one_open ON support_threads (user_id, category) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS support_threads_user ON support_threads (user_id, last_message_at DESC, thread_id DESC);
-- The staff inbox: open threads waiting for staff first, oldest waiting first.
CREATE INDEX IF NOT EXISTS support_threads_inbox ON support_threads (status, last_author, last_message_at, thread_id);
-- The retention job: closed threads past their 365 days.
CREATE INDEX IF NOT EXISTS support_threads_closed ON support_threads (closed_at) WHERE status = 'closed';
CREATE TABLE IF NOT EXISTS support_messages (
  message_id uuid PRIMARY KEY,
  thread_id uuid NOT NULL REFERENCES support_threads(thread_id) ON DELETE CASCADE,
  author text NOT NULL CHECK (author IN ('member','staff')),
  operator_id uuid REFERENCES operators(operator_id),
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now(),
  -- A staff message waits here until the API has sent its content-free push (the API claims it with SKIP LOCKED).
  pushed_at timestamptz,
  CHECK ((author = 'staff') = (operator_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS support_messages_thread ON support_messages (thread_id, created_at, message_id);
CREATE INDEX IF NOT EXISTS support_messages_unpushed ON support_messages (created_at) WHERE author = 'staff' AND pushed_at IS NULL;

-- 2 and 4: the indexes on the large tables.
CREATE INDEX IF NOT EXISTS posts_search ON posts USING gin (to_tsvector('simple', body)) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS posts_topic_public ON posts (topic, created_at DESC, post_id DESC) WHERE deleted_at IS NULL AND audience = 'public' AND topic IS NOT NULL;
CREATE INDEX IF NOT EXISTS comments_replies ON comments (parent_id, created_at, comment_id) WHERE deleted_at IS NULL AND parent_id IS NOT NULL;
-- "Everything this member commented", newest first, for My activity (comments_author orders by created_at only).
CREATE INDEX IF NOT EXISTS comments_author_list ON comments (author_id, created_at DESC, comment_id DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS stories_search ON stories USING gin (to_tsvector('simple', body)) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS stories_topic_public ON stories (topic, created_at DESC, story_id DESC) WHERE deleted_at IS NULL AND audience = 'public' AND topic IS NOT NULL;
CREATE INDEX IF NOT EXISTS stories_public_recent ON stories (created_at DESC, story_id DESC) WHERE deleted_at IS NULL AND audience = 'public';
