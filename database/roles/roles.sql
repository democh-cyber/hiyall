-- Database roles for production (docs/security/15-admin-console.md, docs/deployment/10-deploy-guide.md).
-- This file is the ONE-TIME step: it creates the roles and the schema-level rights. The table, view, sequence and
-- function grants live in database/roles/grants.sql, which hiyall_migrate (the table owner) runs after every
-- migration (`cmd/migrate` does it itself with MIGRATE_RUN_GRANTS=true).
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
-- do not let the migration role create roles. Run it ONCE as a superuser or a role with CREATEROLE (it is
-- idempotent, so a second run does no harm), then run the migrations, then grants.sql:
--
--   psql "$ADMIN_SUPERUSER_URL" -v ON_ERROR_STOP=1 -f database/roles/roles.sql
--   (migrate as hiyall_migrate; MIGRATE_RUN_GRANTS=true applies grants.sql in the same step)
--
-- The roles are created NOLOGIN. Give each a password (or certificate) once, outside this file:
--   ALTER ROLE hiyall_api LOGIN PASSWORD '...';   (same for hiyall_admin and hiyall_migrate)
-- and run the migrations as hiyall_migrate from the first migration. A database already owned by another role is
-- handed over with:  REASSIGN OWNED BY <old owner> TO hiyall_migrate;
-- The whole script is one transaction: a failure leaves nothing half done.

BEGIN;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['hiyall_migrate','hiyall_api','hiyall_admin'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      BEGIN
        EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', r);
      EXCEPTION WHEN duplicate_object OR unique_violation THEN
        NULL;  -- another run created it a moment ago (roles are cluster wide)
      END;
    END IF;
  END LOOP;
END
$$;

-- Nobody but the owner creates objects in the schema.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO hiyall_migrate;
GRANT USAGE ON SCHEMA public TO hiyall_api, hiyall_admin;
-- A database that was not created by hiyall_migrate keeps working for it until REASSIGN OWNED has run.
GRANT ALL ON ALL TABLES IN SCHEMA public TO hiyall_migrate;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO hiyall_migrate;

COMMIT;
