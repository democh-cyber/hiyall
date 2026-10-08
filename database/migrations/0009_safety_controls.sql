-- Mute, restrict, per-chat mute and user reports.
--
-- user_controls holds one person's private controls over another. Nothing here
-- is ever shown to the target: a restricted or muted person sees no change.
--   mute     - their activity arrives already read and without push.
--   restrict - mute, plus no read receipts or typing in either direction and
--              their chats leave the unread badge. Later phases also hide
--              their comments from everyone but them.
CREATE TABLE IF NOT EXISTS user_controls (
  actor_id uuid NOT NULL REFERENCES users(user_id),
  target_id uuid NOT NULL REFERENCES users(user_id),
  control text NOT NULL CHECK (control IN ('mute','restrict')),
  until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_id,target_id,control),
  CHECK (actor_id<>target_id)
);
CREATE INDEX IF NOT EXISTS user_controls_list ON user_controls(actor_id,control,created_at DESC,target_id);

CREATE INDEX IF NOT EXISTS blocks_list ON blocks(blocker_id,created_at DESC,blocked_id);

-- A muted conversation still counts unread on its own row but leaves the
-- badge and sends no push until muted_until passes (9999-12-31 = until unmuted).
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS muted_until timestamptz;

-- Reports are case intake for the trust-and-safety operator tool, never shown
-- to the reported person. Private-message evidence is only what the reporter
-- selected and consented to disclose; the server cannot decrypt anything else.
CREATE TABLE IF NOT EXISTS reports (
  report_id uuid PRIMARY KEY,
  reporter_id uuid NOT NULL REFERENCES users(user_id),
  target_type text NOT NULL CHECK (target_type IN ('user','conversation','message')),
  target_id uuid NOT NULL,
  subject_id uuid NOT NULL REFERENCES users(user_id),
  reason_code text NOT NULL,
  description text,
  evidence jsonb,
  disclosure_consent boolean NOT NULL DEFAULT false,
  severity text NOT NULL CHECK (severity IN ('high','normal')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','actioned','dismissed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolution_code text,
  CHECK (evidence IS NULL OR disclosure_consent)
);
-- One open report per reporter and target; repeats are idempotent.
CREATE UNIQUE INDEX IF NOT EXISTS reports_open_once ON reports(reporter_id,target_type,target_id) WHERE status='open';
CREATE INDEX IF NOT EXISTS reports_queue ON reports(status,severity,created_at);
CREATE INDEX IF NOT EXISTS reports_subject ON reports(subject_id,created_at DESC);
CREATE INDEX IF NOT EXISTS reports_reporter ON reports(reporter_id,created_at DESC,report_id);

CREATE TABLE IF NOT EXISTS moderation_actions (
  action_id uuid PRIMARY KEY,
  report_id uuid REFERENCES reports(report_id),
  actor text NOT NULL,
  subject_id uuid NOT NULL REFERENCES users(user_id),
  action_type text NOT NULL CHECK (action_type IN ('dismiss','warn','suspend','restore')),
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS moderation_actions_subject ON moderation_actions(subject_id,created_at DESC);
CREATE INDEX IF NOT EXISTS moderation_actions_report ON moderation_actions(report_id,created_at);
