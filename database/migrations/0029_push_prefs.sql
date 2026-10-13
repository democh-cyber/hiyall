-- Push notification choices, one row per member who changed them (no row means both on).
-- chat covers new messages; social covers friend requests, new followers and follow requests.
-- The server enforces them when it decides whether to push (internal/push); the app only
-- shows the switches. Muting a chat or a person is separate and always applies.
CREATE TABLE notification_prefs (
  user_id uuid PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  chat boolean NOT NULL DEFAULT true,
  social boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);
