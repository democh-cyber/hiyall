-- Real-time chat support: per-member inbox rows with read pointers and unread
-- counters, push tokens on devices, and expiry of undelivered ciphertext.

-- One row per participant. The inbox is read from (user_id, sort_at) alone, so a
-- page never scans or sorts the user's other conversations. unread_count is
-- maintained on write so badges are O(1).
CREATE TABLE conversation_members (
  conversation_id uuid NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(user_id),
  peer_id uuid NOT NULL REFERENCES users(user_id),
  sort_at timestamptz NOT NULL,
  read_at timestamptz,
  unread_count integer NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
  PRIMARY KEY (user_id, conversation_id)
);
CREATE INDEX conversation_members_inbox ON conversation_members(user_id, sort_at DESC, conversation_id DESC);
CREATE INDEX conversation_members_unread ON conversation_members(user_id) WHERE unread_count > 0;

INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at)
SELECT conversation_id,user_low_id,user_high_id,coalesce(last_message_at,created_at) FROM conversations
UNION ALL
SELECT conversation_id,user_high_id,user_low_id,coalesce(last_message_at,created_at) FROM conversations;

-- The old pair indexes served the inbox query that members now answer.
DROP INDEX conversations_low;
DROP INDEX conversations_high;

-- Push wake-ups carry no message content. A token belongs to one active device.
ALTER TABLE devices
  ADD COLUMN push_provider text CHECK (push_provider IN ('fcm','apns')),
  ADD COLUMN push_token text CHECK (push_token IS NULL OR length(push_token) BETWEEN 8 AND 4096),
  ADD CONSTRAINT devices_push_pair CHECK ((push_provider IS NULL) = (push_token IS NULL));
CREATE UNIQUE INDEX devices_push_token ON devices(push_provider, push_token) WHERE push_token IS NOT NULL AND revoked_at IS NULL;

-- Expiry sweeps delete in created_at order without scanning live inboxes.
CREATE INDEX envelopes_expiry ON message_envelopes(created_at);
