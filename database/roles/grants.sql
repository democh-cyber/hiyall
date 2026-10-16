-- Privilege refresh for the three roles of roles.sql. Run it AFTER EVERY MIGRATION, as hiyall_migrate (the owner
-- of the tables; a superuser works too). `cmd/migrate` runs it by itself when MIGRATE_RUN_GRANTS=true, so the
-- release step is one command: migrate, then this file. It is idempotent.
--
--   psql "$MIGRATE_DATABASE_URL" -v ON_ERROR_STOP=1 -f database/roles/grants.sql
--
-- The whole script is ONE TRANSACTION. Nothing outside it sees a moment without rights: the running API keeps
-- the old grants until COMMIT and has the new ones from then on (GRANT and REVOKE take no table lock). A relation
-- this script does not know is unreachable by hiyall_api and hiyall_admin, which fails closed; a table added by a
-- migration reaches hiyall_api here. If it did not, a production API REFUSES TO START and names what is missing
-- (cmd/api/dbrole.go, store.GrantProblems), a node already running turns /readyz red a minute after it notices, and
-- `api check-config -db` reports it. Which tables are special here (the operator tables, content_cases) is also
-- listed in store/roles.go; TestSpecialTablesMatchGrantsScript fails when the two lists differ.
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
GRANT UPDATE ON users, reports, sessions, operator_sessions, operator_login_attempts TO hiyall_admin;
-- No direct UPDATE on content_cases or evidence_approvals, and none on operators.role: the two-person transitions are
-- SECURITY DEFINER functions below that enforce proposer <> approver and the legal-hold rules in SQL (migration 0043).
GRANT UPDATE (password_hash, totp_secret, totp_last_step, disabled_at, last_login_at) ON operators TO hiyall_admin;
GRANT INSERT ON moderation_actions, operators, operator_sessions, operator_login_attempts, operator_audit TO hiyall_admin;
-- Two-person control over evidence (migrations 0041, 0043): the console reads proposals; the functions write them.
GRANT SELECT ON evidence_approvals TO hiyall_admin;
-- Sign in with Apple revocations queued for a human (status 'manual'): every column but the sealed token, and DELETE
-- to mark one done (the console writes its audit entry in the same transaction).
GRANT SELECT (revocation_id, issuer, subject, user_id, status, reason, created_at) ON apple_revocations TO hiyall_admin;
GRANT DELETE ON apple_revocations TO hiyall_admin;
GRANT DELETE ON operator_sessions, operator_login_attempts TO hiyall_admin;
GRANT USAGE, SELECT ON SEQUENCE operator_login_attempts_attempt_id_seq, operator_audit_audit_id_seq TO hiyall_admin;

-- ---- Functions that cross the table boundary, each granted to exactly one role (migration 0038). They run with the
-- owner's rights, so the role needs no table grant behind them.
REVOKE ALL ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid), prune_operator_audit(uuid, text, text, integer) FROM PUBLIC, hiyall_api, hiyall_admin;
REVOKE ALL ON FUNCTION activate_quarantine_case(uuid), hold_still_releasable(uuid), safety_queue_stats(),
  evidence_propose(uuid, uuid, text, uuid, text, text), operator_promotion_propose(uuid, uuid, uuid, text), evidence_decide(uuid, uuid, text, text),
  evidence_expire_due(), content_case_confirm(uuid, uuid, text), content_case_report(uuid, uuid, text, text), operator_set_role(uuid, text, uuid),
  pending_cases_due(integer), drop_pending_case(uuid, text), admin_schedule_deletion(uuid, text, text, text, text) FROM PUBLIC, hiyall_api, hiyall_admin;
-- The API's maintenance job removes the objects of released evidence holds once their window is over, and records it;
-- it still cannot read or change a case.
GRANT EXECUTE ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid) TO hiyall_api;
-- Migration 0043: the upload path opens a case it wrote 'pending' once the evidence objects are stored, the purge asks
-- whether a hold is still releasable before each delete, and the gauges read queue lengths. Counts and a status flip:
-- still no way to read or change a case.
GRANT EXECUTE ON FUNCTION activate_quarantine_case(uuid), hold_still_releasable(uuid), safety_queue_stats() TO hiyall_api;
-- With a separate evidence bucket the API's token there cannot delete; the console's purge job (admin purge-holds,
-- which holds the only delete credential) runs the same two functions.
GRANT EXECUTE ON FUNCTION held_objects_due(integer), mark_hold_purged(uuid) TO hiyall_admin;
-- The console prunes audit entries older than a year (POST /admin/v1/audit/prune); the trigger that keeps the
-- table append-only stays on for everything else.
GRANT EXECUTE ON FUNCTION prune_operator_audit(uuid, text, text, integer) TO hiyall_admin;
-- The two-person transitions and the support-driven deletion (migration 0043): the console's only way to change a case,
-- a proposal or an operator's role. Each re-checks its rules in SQL.
GRANT EXECUTE ON FUNCTION evidence_propose(uuid, uuid, text, uuid, text, text), operator_promotion_propose(uuid, uuid, uuid, text),
  evidence_decide(uuid, uuid, text, text), evidence_expire_due(), content_case_confirm(uuid, uuid, text), content_case_report(uuid, uuid, text, text),
  operator_set_role(uuid, text, uuid), pending_cases_due(integer), drop_pending_case(uuid, text), admin_schedule_deletion(uuid, text, text, text, text),
  activate_quarantine_case(uuid), hold_still_releasable(uuid), safety_queue_stats() TO hiyall_admin;

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
  IF has_table_privilege('hiyall_admin', 'content_cases', 'UPDATE') OR has_table_privilege('hiyall_admin', 'content_cases', 'INSERT') OR has_table_privilege('hiyall_admin', 'content_cases', 'DELETE')
     OR has_table_privilege('hiyall_admin', 'evidence_approvals', 'UPDATE') OR has_table_privilege('hiyall_admin', 'evidence_approvals', 'INSERT') OR has_table_privilege('hiyall_admin', 'evidence_approvals', 'DELETE')
     OR has_column_privilege('hiyall_admin', 'operators', 'role', 'UPDATE') THEN
    RAISE EXCEPTION 'grants.sql: hiyall_admin can write cases, approvals or an operator role directly (only the two-person functions may)';
  END IF;
  IF has_column_privilege('hiyall_admin', 'apple_revocations', 'token_sealed', 'SELECT') THEN
    RAISE EXCEPTION 'grants.sql: hiyall_admin can read sealed Apple tokens';
  END IF;
END
$$;

COMMIT;
