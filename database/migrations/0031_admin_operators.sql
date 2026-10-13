-- Admin console staff accounts (docs/security/15-admin-console.md).
--
-- Operators are Hiyall staff. They are a separate population from members: nothing here references
-- users, and a member token never authorizes an admin route or the other way round.
--
-- operators          staff accounts. Created only by `admin operator-add` (never over HTTP). The TOTP secret
--                    is sealed with AES-256-GCM under ADMIN_DATA_KEY, so a copy of this table alone does not
--                    reveal it. totp_last_step makes a code single-use (replay protection).
-- operator_sessions  console sessions. Only the SHA-256 of the random token is stored.
-- operator_login_attempts  rate limiting and lockout that survives restarts and works across nodes. Keys are
--                    HMACs of the e-mail and of the client address, so the table holds neither in the clear.
-- operator_audit     append-only record of what staff read and did. A trigger refuses UPDATE, DELETE and
--                    TRUNCATE, whoever runs them. See the docs for the restricted database role.

CREATE TABLE IF NOT EXISTS operators (
  operator_id uuid PRIMARY KEY,
  email text NOT NULL CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 254),
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  role text NOT NULL CHECK (role IN ('viewer','moderator','admin')),
  password_hash text NOT NULL,
  totp_secret bytea NOT NULL,
  totp_last_step bigint NOT NULL DEFAULT 0,
  disabled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS operators_email_key ON operators(email);

CREATE TABLE IF NOT EXISTS operator_sessions (
  session_id uuid PRIMARY KEY,
  operator_id uuid NOT NULL REFERENCES operators(operator_id),
  token_hash bytea NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  ip text NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS operator_sessions_operator ON operator_sessions(operator_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS operator_login_attempts (
  attempt_id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  account_key bytea NOT NULL,
  ip_key bytea NOT NULL,
  succeeded boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS operator_login_attempts_at ON operator_login_attempts(at);
CREATE INDEX IF NOT EXISTS operator_login_attempts_account ON operator_login_attempts(account_key,at) WHERE NOT succeeded;
CREATE INDEX IF NOT EXISTS operator_login_attempts_ip ON operator_login_attempts(ip_key,at) WHERE NOT succeeded;

CREATE TABLE IF NOT EXISTS operator_audit (
  audit_id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  operator_id uuid REFERENCES operators(operator_id),
  -- Who, as text, so the entry stays readable if the account is renamed: the e-mail, or "cli:<os user>".
  actor text NOT NULL,
  action text NOT NULL,
  target_type text NOT NULL DEFAULT '',
  target_id text NOT NULL DEFAULT '',
  reason text NOT NULL DEFAULT '',
  -- Truncated client address (IPv4 /24, IPv6 /48): enough to tell a VPN from somewhere else.
  ip text NOT NULL DEFAULT '',
  detail jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(detail)='object')
);
CREATE INDEX IF NOT EXISTS operator_audit_operator ON operator_audit(operator_id,audit_id DESC);
CREATE INDEX IF NOT EXISTS operator_audit_target ON operator_audit(target_type,target_id,audit_id DESC);

CREATE OR REPLACE FUNCTION operator_audit_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'operator_audit is append-only' USING ERRCODE = '55000';
END
$$;
DROP TRIGGER IF EXISTS operator_audit_no_change ON operator_audit;
CREATE TRIGGER operator_audit_no_change BEFORE UPDATE OR DELETE ON operator_audit
  FOR EACH ROW EXECUTE FUNCTION operator_audit_append_only();
DROP TRIGGER IF EXISTS operator_audit_no_truncate ON operator_audit;
CREATE TRIGGER operator_audit_no_truncate BEFORE TRUNCATE ON operator_audit
  FOR EACH STATEMENT EXECUTE FUNCTION operator_audit_append_only();
