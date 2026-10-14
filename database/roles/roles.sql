-- Database roles for production (docs/security/15-admin-console.md, docs/deployment/10-deploy-guide.md).
--
-- Three roles, least privilege:
--   hiyall_migrate  owns the schema and runs `go run ./cmd/migrate` (the /migrate image entrypoint). It is the
--                   only role that can change tables, triggers or grants, so it is used by the release step and by
--                   nothing that serves traffic.
--   hiyall_api      the public API (DATABASE_URL). Reads and writes member data. Has NO access to the operator
--                   tables (operators, operator_sessions, operator_login_attempts, operator_audit): an internet
--                   facing process cannot read staff password hashes or sealed authenticator secrets, and cannot
--                   touch the audit log.
--   hiyall_admin    the admin console (ADMIN_DATABASE_URL). Reads what the console shows, writes what moderation
--                   changes, runs the operator tables, and on operator_audit holds INSERT and SELECT only (no
--                   UPDATE, DELETE or TRUNCATE; the trigger from migration 0031 is a second line, and as the table
--                   owner only hiyall_migrate or a superuser could disable it).
--
-- This is a script and not a migration because roles belong to the whole cluster, and many managed databases
-- do not let the migration role create roles. Run it as a superuser or a role with CREATEROLE, once to create
-- the roles and again AFTER EVERY `migrate` run (it is idempotent): a table the script does not know is
-- unreachable by hiyall_api and hiyall_admin, which fails closed.
--
--   psql "$ADMIN_SUPERUSER_URL" -v ON_ERROR_STOP=1 -f database/roles/roles.sql
--
-- The roles are created NOLOGIN. Give each a password (or certificate) once, outside this file:
--   ALTER ROLE hiyall_api LOGIN PASSWORD '...';   (same for hiyall_admin and hiyall_migrate)
-- and run the migrations as hiyall_migrate from the first migration. A database already owned by another role is
-- handed over with:  REASSIGN OWNED BY <old owner> TO hiyall_migrate;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['hiyall_migrate','hiyall_api','hiyall_admin'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', r);
    END IF;
  END LOOP;
END
$$;

-- Nobody but the owner creates objects in the schema.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO hiyall_migrate;
GRANT USAGE ON SCHEMA public TO hiyall_api, hiyall_admin;
GRANT ALL ON ALL TABLES IN SCHEMA public TO hiyall_migrate;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO hiyall_migrate;

-- Start from nothing, so re-running after a change removes what was granted before.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM hiyall_api, hiyall_admin;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM hiyall_api, hiyall_admin;

-- ---- API: everything except the operator tables and the migration bookkeeping.
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
              AND c.relname NOT IN ('operators','operator_sessions','operator_login_attempts','operator_audit','schema_migrations','content_cases')
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO hiyall_api', t.relname);
  END LOOP;
END
$$;
GRANT SELECT ON schema_migrations TO hiyall_api;        -- /readyz compares it with the shipped migrations
GRANT INSERT ON content_cases TO hiyall_api;            -- the upload scanner opens a case; it cannot read or change one
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO hiyall_api;
REVOKE ALL ON SEQUENCE operator_login_attempts_attempt_id_seq, operator_audit_audit_id_seq FROM hiyall_api;

-- ---- Admin console: what a case and a member view read, what moderation writes, the operator tables.
GRANT SELECT ON users, profiles, member_ages, reports, moderation_actions, chat_blobs, sessions, auth_identities,
                posts, post_media, comments, stories, media_assets, spaces, space_entries, content_cases,
                operators, operator_sessions, operator_login_attempts, operator_audit TO hiyall_admin;
GRANT UPDATE ON users, reports, sessions, content_cases, operators, operator_sessions, operator_login_attempts TO hiyall_admin;
GRANT INSERT ON moderation_actions, operators, operator_sessions, operator_login_attempts, operator_audit TO hiyall_admin;
GRANT DELETE ON operator_sessions, operator_login_attempts TO hiyall_admin;
GRANT USAGE, SELECT ON SEQUENCE operator_login_attempts_attempt_id_seq, operator_audit_audit_id_seq TO hiyall_admin;
