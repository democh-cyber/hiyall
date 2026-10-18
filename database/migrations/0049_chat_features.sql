-- Chat features: pinned chats, hidden ("deleted") chats with a 30 day restore window, and the close of a hidden chat
-- (docs/api/26-chat-voice-video-and-list.md).
--
-- All three are per member row, so each side of a conversation decides alone and the peer never learns of any of them.
--   pinned_at  the member pinned this chat; at most ChatPinsMax (5 on Free) per member, counted by the API in the
--              transaction that pins, under the member's quota lock.
--   hidden_at  the member deleted the chat from their list. Nothing else is touched: no message, no blob, not the
--              peer's row. It can be restored for 30 days (GET /v1/conversations/hidden). A message of the peer's
--              that arrives meanwhile clears it on both rows (SendMessage), and so does the member opening the chat.
--   closed_at  set by the hourly job once hidden_at is more than 30 days old: the chat is out of the Deleted-chats
--              list for good and can no longer be restored; the app wipes its local history for it (closedIds in the
--              hidden listing, for 90 days). A closed chat is always a hidden one.
ALTER TABLE conversation_members ADD COLUMN pinned_at timestamptz, ADD COLUMN hidden_at timestamptz, ADD COLUMN closed_at timestamptz;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_closed_is_hidden CHECK (closed_at IS NULL OR hidden_at IS NOT NULL);
CREATE INDEX conversation_members_pinned ON conversation_members (user_id) WHERE pinned_at IS NOT NULL;
-- The close job walks the hidden chats that are not closed yet, oldest first; the listing of closed ids reads a
-- member's own rows by (user_id) and is small.
CREATE INDEX conversation_members_hidden ON conversation_members (hidden_at) WHERE hidden_at IS NOT NULL AND closed_at IS NULL;

-- Voice messages and videos are two more blob roles, and a video blob is up to 40 MiB. The 0023 column checks
-- allowed the roles full and thumb and 4 MiB at most (the photo cap); the API applies the per-role caps (voice
-- 8 MiB, video 40 MiB on Free, thumb 256 KiB, full 4 MiB), so the column only keeps a sane ceiling of 64 MiB.
ALTER TABLE chat_blobs DROP CONSTRAINT chat_blobs_role_check;
ALTER TABLE chat_blobs ADD CONSTRAINT chat_blobs_role_check CHECK (role IN ('full','thumb','voice','video'));
ALTER TABLE chat_blobs DROP CONSTRAINT chat_blobs_size_bytes_check;
ALTER TABLE chat_blobs ADD CONSTRAINT chat_blobs_size_bytes_check CHECK (size_bytes BETWEEN 32 AND 67108864);
