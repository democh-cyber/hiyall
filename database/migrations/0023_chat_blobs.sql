-- Encrypted chat attachments (phase 1: images).
--
-- A chat blob is one opaque ciphertext object in the separate chat bucket (key chat/<blob_id>). The
-- server never sees plaintext or keys: the key, the hash and the descriptor travel inside the
-- end-to-end encrypted message. This table is what lets the API authorize, size-check, rate-limit and
-- expire the objects, see docs/security/14-encrypted-chat-attachments.md.
--
-- Lifecycle: 'pending' (slot handed out, expires after 1 hour) -> 'uploaded' (the stored size matched;
-- still expires after 1 hour until a message claims it) -> linked to a message (message_id set,
-- expires 30 days later) -> 'deleted' (retention, uploader delete, block or account deletion; the
-- clean-up job then removes the object and clears object_key).
--
-- Foreign keys: users, conversations and messages are never hard-deleted (accounts are deactivated,
-- blocking closes a conversation), so they are plain references: a future hard delete has to mark the
-- blobs deleted first, which is also what account deletion must do. A report that is ever purged
-- releases its hold instead of blocking the purge.
CREATE TABLE chat_blobs (
  blob_id uuid PRIMARY KEY,
  uploader_id uuid NOT NULL REFERENCES users(user_id),
  conversation_id uuid NOT NULL REFERENCES conversations(conversation_id),
  -- Set once, by the message send that claims the blob; never moved to another message.
  message_id uuid REFERENCES messages(message_id),
  -- 'video' and 'poster' arrive in phase 2 with a wider constraint.
  role text NOT NULL CHECK (role IN ('full','thumb')),
  -- Exact ciphertext size the uploader declared; complete verifies the stored object against it.
  -- 4 MiB is the largest cap (role 'full'); the API applies the per-role caps (thumb 256 KiB).
  size_bytes integer NOT NULL CHECK (size_bytes BETWEEN 32 AND 4194304),
  -- SHA-256 of the whole ciphertext, signed into the upload so the object store rejects any other body.
  ct_sha256 bytea NOT NULL CHECK (octet_length(ct_sha256) = 32),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','uploaded','deleted')),
  -- NULL once the object is gone from the chat bucket (the row stays as a tombstone for the quota window).
  object_key text,
  -- While set, retention, uploader delete, block and account deletion leave the blob alone: it is
  -- evidence in this report.
  held_report_id uuid REFERENCES reports(report_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  uploaded_at timestamptz,
  expires_at timestamptz NOT NULL,
  deleted_at timestamptz,
  CHECK (state <> 'deleted' OR deleted_at IS NOT NULL),
  CHECK (state = 'deleted' OR object_key IS NOT NULL),
  CHECK (state <> 'uploaded' OR uploaded_at IS NOT NULL)
);
-- The daily quota counts every blob an uploader created in the last 24 hours, whatever became of it.
CREATE INDEX chat_blobs_uploader ON chat_blobs(uploader_id, created_at);
-- Clean-up: blobs past expiry that still have an object or a live row.
CREATE INDEX chat_blobs_expiry ON chat_blobs(expires_at) WHERE state <> 'deleted';
-- Deleted blobs whose object has not been removed yet (retry after a storage failure).
CREATE INDEX chat_blobs_removal ON chat_blobs(deleted_at) WHERE state = 'deleted' AND object_key IS NOT NULL;
-- Message lookups: evidence checks and block clean-up.
CREATE INDEX chat_blobs_message ON chat_blobs(message_id) WHERE message_id IS NOT NULL;
CREATE INDEX chat_blobs_conversation ON chat_blobs(conversation_id) WHERE state <> 'deleted';
CREATE INDEX chat_blobs_held ON chat_blobs(held_report_id) WHERE held_report_id IS NOT NULL;
