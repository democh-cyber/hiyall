-- Group chat (docs/api/29-group-chat.md, docs/mobile/19-group-chat.md): end-to-end encrypted rooms of 3 to 10 people.
--
-- A group is a conversation (kind 'group') so the whole relay keeps working on it unchanged: messages, the per-device
-- envelopes, blobs, read pointers, mute, pin, hide and the inbox are keyed by conversation_id. What is new is who is in it.
--
-- 1. conversations.kind: 'direct' (the pair rows that exist today) or 'group'. A group has no user_low_id / user_high_id,
--    so every query that names the pair (the pair lookup, "has this pair exchanged messages", the first-contact cap, the
--    deletion and block clean-ups) can never match a group. A CHECK ties the shape to the kind.
-- 2. conversation_members.peer_id may be NULL: a group member has no single peer. The direct-chat list joins on the peer, so
--    it never returns a group row. A group member row exists only while the person is an ACTIVE member; it carries the same
--    per-member flags (sort_at, read_at, unread_count, muted_until, pinned_at, hidden_at, closed_at) as a direct chat.
-- 3. chat_groups: the name (metadata the server sees, at most 40 characters, validated like other names) and the owner.
-- 4. chat_group_members: every person the group has had a say about: 'active' members and 'invited' people (an invite expires
--    after 7 days, expires_at). Leaving, removal, a declined or an expired invite delete the row. role 'owner' is held by
--    exactly the owner (chat_groups.owner_id).
-- 5. chat_group_events: the membership events the server records, shown to members as notices and the only way members learn
--    that an account was deleted (that person can no longer send a message). message_id links an event to the encrypted
--    control message that carried the same change, so an app shows one notice. Kept 90 days.

ALTER TABLE conversations ADD COLUMN kind text NOT NULL DEFAULT 'direct' CHECK (kind IN ('direct','group'));
ALTER TABLE conversations ALTER COLUMN user_low_id DROP NOT NULL, ALTER COLUMN user_high_id DROP NOT NULL;
-- A group outlives its creator's account, so created_by may be emptied for a group (the account purge does); a direct
-- chat always has one.
ALTER TABLE conversations ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE conversations ADD CONSTRAINT conversations_kind_shape CHECK (
  (kind = 'direct' AND user_low_id IS NOT NULL AND user_high_id IS NOT NULL AND created_by IS NOT NULL)
  OR (kind = 'group' AND user_low_id IS NULL AND user_high_id IS NULL));

ALTER TABLE conversation_members ALTER COLUMN peer_id DROP NOT NULL;

CREATE TABLE chat_groups (
  conversation_id uuid PRIMARY KEY REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT '' CHECK (char_length(name) <= 40),
  owner_id uuid NOT NULL REFERENCES users(user_id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_groups_owner ON chat_groups (owner_id);

CREATE TABLE chat_group_members (
  conversation_id uuid NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(user_id),
  state text NOT NULL CHECK (state IN ('invited','active')),
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
  invited_by uuid REFERENCES users(user_id),
  invited_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  joined_at timestamptz,
  PRIMARY KEY (conversation_id, user_id),
  CONSTRAINT chat_group_members_shape CHECK (
    (state = 'invited' AND expires_at IS NOT NULL AND joined_at IS NULL AND role = 'member')
    OR (state = 'active' AND joined_at IS NOT NULL))
);
-- "Which groups is this person in or invited to" (the group cap, the list, the key-claim exemption).
CREATE INDEX chat_group_members_user ON chat_group_members (user_id, state);
-- The hourly job deletes invites past their expiry.
CREATE INDEX chat_group_members_expiry ON chat_group_members (expires_at) WHERE state = 'invited';
-- The account purge finds the invites a member sent.
CREATE INDEX chat_group_members_invited_by ON chat_group_members (invited_by) WHERE invited_by IS NOT NULL;

CREATE TABLE chat_group_events (
  event_id uuid PRIMARY KEY,
  conversation_id uuid NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('created','joined','left','removed','renamed','owner_changed','member_deleted','closed')),
  actor_id uuid REFERENCES users(user_id),
  subject_id uuid REFERENCES users(user_id),
  message_id uuid,
  name text CHECK (name IS NULL OR char_length(name) <= 40),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_group_events_conversation ON chat_group_events (conversation_id, created_at, event_id);
-- The retention job deletes events older than 90 days.
CREATE INDEX chat_group_events_age ON chat_group_events (created_at);
-- The account purge finds the events that name a member.
CREATE INDEX chat_group_events_actor ON chat_group_events (actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX chat_group_events_subject ON chat_group_events (subject_id) WHERE subject_id IS NOT NULL;

-- 6. reports.conversation_id: the conversation a report about a chat message or a chat is in, so the console can show a
--    group's membership metadata (name, owner, who is in it) without reading message rows. NULL for every other target.
ALTER TABLE reports ADD COLUMN conversation_id uuid;
