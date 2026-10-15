-- Privilege refresh for the three roles of roles.sql. Run it AFTER EVERY MIGRATION, as hiyall_migrate (the owner
-- of the tables; a superuser works too). `cmd/migrate` runs it by itself when MIGRATE_RUN_GRANTS=true, so the
-- release step is one command: migrate, then this file. It is idempotent.
--
--   psql "$MIGRATE_DATABASE_URL" -v ON_ERROR_STOP=1 -f database/roles/grants.sql
--
-- The whole script is ONE TRANSACTION. Nothing outside it sees a moment without rights: the running API keeps
-- the old grants until COMMIT and has the new ones from then on (GRANT and REVOKE take no table lock). A relation
-- this script does not know is unreachable by hiyall_api and hiyall_admin, which fails closed; a table added by a
-- migration reaches hiyall_api here, and `api check-config -db` (and the production start) tell you if it did not.
--
-- The last block asserts the result, so a run by a role that does not own the tables (PostgreSQL only warns
-- "no privileges were granted") rolls back with an error instead of leaving the API half-granted.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- Start from nothing, so re-running after a change removes what was granted before. Column grants go with the table.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM hiyall_api, hiyall_admin;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM hiyall_api, hiyall_admin;

-- ---- API: every table (read and write) and view (read) except the operator tables and the migration bookkeeping.
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m')
              AND c.relname NOT IN ('operators','operator_sessions','operator_login_attempts','operator_audit','schema_migrations','content_cases','evidence_approvals')
  LOOP
    IF t.relkind IN ('r','p') THEN
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO hiyall_api', t.relname);
    ELSE
      -- Views run with their owner's rights, so reading one needs no grant on the tables behind it.
      EXECUTE format('GRANT SELECT ON public.%I TO hiyall_api', t.relname);
    END IF;
  END LOOP;
END
$$;
GRANT SELECT ON schema_migrations TO hiyall_api;        -- /readyz compares it with the shipped migrations
GRANT INSERT ON content_cases TO hiyall_api;            -- the upload scanner opens a case; it cannot read or change one
GRANT SELECT (media_id) ON content_cases TO hiyall_api; -- the media tombstone purge asks "does a case still point at this photo"; no other column
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO hiyall_api;
REVOKE ALL ON SEQUENCE operator_login_attempts_attempt_id_seq, operator_audit_audit_id_seq FROM hiyall_api;

-- ---- Admin console: what a case and a member view read, what moderation writes, the operator tables.
GRANT SELECT ON users, profiles, member_ages, reports, moderation_actions, chat_blobs, sessions, auth_identities,
                posts, post_media, comments, stories, media_assets, spaces, space_entries, content_cases,
                operators, operator_sessions, operator_login_attempts, operator_audit TO hiyall_admin;
GRANT UPDATE ON users, reports, sessions, content_cases, operators, operator_sessions, operator_login_attempts TO hiyall_admin;
GRANT INSERT ON moderation_actions, operators, operator_sessions, operator_login_attempts, operator_audit TO hiyall_admin;
-- Two-person control over evidence (migration 0041): proposals and decisions. The API role has no access at all.
GRANT SELECT, INSERT, UPDATE ON evidence_approvals TO hiyall_admin;
GRANT DELETE ON operator_sessions, operator_login_attempts TO hiyall_admin;
GRANT USAGE, SELECT ON SEQUENCE operator_login_attempts_attempt_id_seq, operator_audit_audit_id_seq TO hiyall_admin;

-- ---- Functions that cross the table boundary, each granted to exactly one role (migration 0038). They run with the
-- owner's rights, so the role needs no table grant behind them.
REVOKE ALL ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid), prune_operator_audit(uuid, text, text, integer) FROM PUBLIC, hiyall_api, hiyall_admin;
-- The API's maintenance job removes the objects of released evidence holds once their window is over, and records it;
-- it still cannot read or change a case.
GRANT EXECUTE ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid) TO hiyall_api;
-- With a separate evidence bucket the API's token there cannot delete; the console's purge job (admin purge-holds,
-- which holds the only delete credential) runs the same two functions.
GRANT EXECUTE ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid) TO hiyall_admin;
-- The console prunes audit entries older than a year (POST /admin/v1/audit/prune); the trigger that keeps the
-- table append-only stays on for everything else.
GRANT EXECUTE ON FUNCTION prune_operator_audit(uuid, text, text, integer) TO hiyall_admin;

-- ---- Assert the outcome (also what `api check-config -db` compares).
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO missing
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m')
     AND c.relname NOT IN ('operators','operator_sessions','operator_login_attempts','operator_audit','content_cases','evidence_approvals')
     AND NOT has_table_privilege('hiyall_api', c.oid, 'SELECT');
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'grants.sql: hiyall_api has no SELECT on: % (run it as the table owner, hiyall_migrate)', missing;
  END IF;
  IF has_table_privilege('hiyall_api', 'operators', 'SELECT') OR has_table_privilege('hiyall_api', 'operator_sessions', 'SELECT')
     OR has_table_privilege('hiyall_api', 'operator_login_attempts', 'SELECT') OR has_table_privilege('hiyall_api', 'operator_audit', 'SELECT')
     OR has_table_privilege('hiyall_api', 'content_cases', 'SELECT') OR has_table_privilege('hiyall_api', 'evidence_approvals', 'SELECT') THEN
    RAISE EXCEPTION 'grants.sql: hiyall_api can read an operator table, content_cases or evidence_approvals';
  END IF;
  IF has_table_privilege('hiyall_admin', 'operator_audit', 'UPDATE') OR has_table_privilege('hiyall_admin', 'operator_audit', 'DELETE') THEN
    RAISE EXCEPTION 'grants.sql: hiyall_admin can change the audit log';
  END IF;
END
$$;

COMMIT;
