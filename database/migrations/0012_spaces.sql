-- Adult-only shared spaces. Discussion entries are server-readable content,
-- not private chat messages. Private continuation uses the E2EE chat service.
CREATE TABLE spaces (
 space_id uuid PRIMARY KEY,
 owner_id uuid NOT NULL REFERENCES users(user_id),
 parent_id uuid REFERENCES spaces(space_id),
 kind text NOT NULL CHECK(kind IN ('community','moment','event')),
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 80),
 description text NOT NULL DEFAULT '',
 rules text NOT NULL DEFAULT '',
 visibility text NOT NULL CHECK(visibility IN ('public','private','invite')),
 capacity int NOT NULL CHECK(capacity BETWEEN 2 AND 10000),
 starts_at timestamptz,
 ends_at timestamptz,
 timezone text NOT NULL DEFAULT 'UTC',
 location text NOT NULL DEFAULT '',
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed','archived')),
 member_count int NOT NULL DEFAULT 1 CHECK(member_count >= 1),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(kind='community' OR (starts_at IS NOT NULL AND ends_at>starts_at))
);
CREATE INDEX spaces_browse ON spaces(kind,created_at DESC,space_id DESC) WHERE visibility<>'invite';
CREATE INDEX spaces_parent ON spaces(parent_id,created_at DESC,space_id DESC);
CREATE TABLE space_members (
 space_id uuid NOT NULL REFERENCES spaces(space_id),
 user_id uuid NOT NULL REFERENCES users(user_id),
 role text NOT NULL DEFAULT 'member' CHECK(role IN ('owner','admin','moderator','member')),
 state text NOT NULL CHECK(state IN ('active','pending','invited','banned')),
 rsvp text NOT NULL DEFAULT 'going' CHECK(rsvp IN ('going','interested')),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(space_id,user_id)
);
CREATE INDEX space_members_user ON space_members(user_id,space_id) WHERE state='active';
CREATE INDEX space_members_list ON space_members(space_id,state,created_at DESC,user_id DESC);
CREATE TABLE space_entries (
 entry_id uuid PRIMARY KEY,
 space_id uuid NOT NULL REFERENCES spaces(space_id),
 author_id uuid NOT NULL REFERENCES users(user_id),
 body text NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),
 created_at timestamptz NOT NULL DEFAULT now(),
 deleted_at timestamptz
);
CREATE INDEX space_entries_list ON space_entries(space_id,created_at DESC,entry_id DESC) WHERE deleted_at IS NULL;
ALTER TABLE reports DROP CONSTRAINT reports_target_type_check;
ALTER TABLE reports ADD CONSTRAINT reports_target_type_check CHECK(target_type IN ('user','conversation','message','post','comment','story','space','space_entry'));
