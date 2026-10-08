-- End-to-end encrypted direct chat relay. The server stores device public keys,
-- conversation membership, message metadata and per-device ciphertext only.
-- It never receives plaintext or private keys. Ciphertext is deleted on delivery.
CREATE TABLE devices (
  device_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(user_id),
  identity_key text NOT NULL UNIQUE,
  signing_key text NOT NULL,
  signature text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('android','ios','web','linux','unknown')),
  display_name text NOT NULL DEFAULT '' CHECK (length(display_name) <= 60),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE INDEX devices_user_active ON devices(user_id) WHERE revoked_at IS NULL;

CREATE TABLE one_time_keys (
  device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
  key_id text NOT NULL CHECK (length(key_id) BETWEEN 1 AND 64),
  public_key text NOT NULL,
  signature text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, key_id)
);

CREATE TABLE fallback_keys (
  device_id uuid PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
  key_id text NOT NULL CHECK (length(key_id) BETWEEN 1 AND 64),
  public_key text NOT NULL,
  signature text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE conversations (
  conversation_id uuid PRIMARY KEY,
  user_low_id uuid NOT NULL REFERENCES users(user_id),
  user_high_id uuid NOT NULL REFERENCES users(user_id),
  created_by uuid NOT NULL REFERENCES users(user_id),
  status text NOT NULL CHECK (status IN ('active','closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz,
  UNIQUE (user_low_id, user_high_id),
  CHECK (user_low_id < user_high_id)
);
CREATE INDEX conversations_low ON conversations(user_low_id, last_message_at DESC);
CREATE INDEX conversations_high ON conversations(user_high_id, last_message_at DESC);

CREATE TABLE messages (
  message_id uuid PRIMARY KEY,
  conversation_id uuid NOT NULL REFERENCES conversations(conversation_id),
  sender_id uuid NOT NULL REFERENCES users(user_id),
  sender_device_id uuid NOT NULL REFERENCES devices(device_id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_conversation ON messages(conversation_id, created_at DESC);

CREATE TABLE message_envelopes (
  message_id uuid NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
  recipient_device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
  envelope_type smallint NOT NULL CHECK (envelope_type IN (0,1)),
  ciphertext text CHECK (ciphertext IS NULL OR length(ciphertext) <= 21848),
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  PRIMARY KEY (message_id, recipient_device_id),
  CHECK ((delivered_at IS NULL) = (ciphertext IS NOT NULL))
);
CREATE INDEX envelopes_inbox ON message_envelopes(recipient_device_id, created_at, message_id) WHERE delivered_at IS NULL;
