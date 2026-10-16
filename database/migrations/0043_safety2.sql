-- Safety release 2 (round-3 audit API-1, API-5, API-6, API-7, API-8).
--
-- 1. apple_revocations learns a second kind of row. 'queued' is what it always held: a sealed Sign in with Apple
--    refresh token that could not be revoked at deletion time, retried by the purge. 'manual' has NO token: the
--    member asked to delete the account but the app could not obtain an Apple authorization code (POST
--    /v1/me/deletion {appleCodeUnavailable:true}), or support scheduled the deletion (`admin schedule-deletion`).
--    The deletion goes ahead, the purge skips Apple for the row, and the console lists it so an operator revokes
--    the authorization by hand in Apple's console and marks it done (audited; the row is then deleted).
-- 2. content_cases.status gains 'pending': the case row is written BEFORE the evidence objects, so an object in the
--    evidence bucket never exists without a case that names it. A case is 'pending' until the objects are written
--    (activate_quarantine_case); the console sweeps pending cases older than an hour (objects missing: the case is
--    dropped; objects present: it is activated) and lists hold/ objects that no case names.
-- 3. The two-person transitions move into SECURITY DEFINER functions with a pinned search_path, executable only by
--    hiyall_admin (database/roles/grants.sql). hiyall_admin loses its direct UPDATE on content_cases and
--    evidence_approvals, and on operators.role: the rules cannot be skipped by a bug or a stolen console session in
--    Go. In SQL: the proposer never approves (proposed_by <> decided_by), a hold behind a legal hold or an open
--    report cannot be released, a legal hold is lifted only with a counsel reference of the form
--    ^[A-Za-z0-9][A-Za-z0-9 ._/-]{5,119}$, a case behind a legal hold cannot be cleared, promoting an operator to
--    administrator needs a second administrator's approval (evidence_approvals, kind promote_admin) unless no
--    administrator is active, and a late 'reported' moves hold_until to at least a year from the report. What a
--    function cannot know is WHICH operator the console says it is acting for: a fully compromised console process
--    can still name two administrators. The functions check that the named operators exist, are enabled and are
--    administrators, and the audit log names both.
-- 4. Note on 0038: its comments, and docs written before, describe the API's evidence token as write-only. R2 cannot
--    scope a token that way. The API now proves what its token can do (`api check-config -net`, EVIDENCE_CANARY),
--    and where it can delete, a bucket-lock retention rule on the evidence bucket is the protection
--    (docs/deployment/10-deploy-guide.md). The comment on held_objects_due below carries the correction; 0038 itself
--    is checksummed and unchanged.

-- 1
ALTER TABLE apple_revocations ALTER COLUMN token_sealed DROP NOT NULL;
ALTER TABLE apple_revocations ADD COLUMN status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','manual'));
ALTER TABLE apple_revocations ADD COLUMN user_id uuid;
ALTER TABLE apple_revocations ADD COLUMN reason text;
ALTER TABLE apple_revocations ADD COLUMN revocation_id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE apple_revocations ADD CONSTRAINT apple_revocations_token CHECK ((status = 'queued') = (token_sealed IS NOT NULL));
CREATE UNIQUE INDEX apple_revocations_id ON apple_revocations(revocation_id);

-- 2
ALTER TABLE content_cases DROP CONSTRAINT content_cases_status_check;
ALTER TABLE content_cases ADD CONSTRAINT content_cases_status_check CHECK (status IN ('pending','open','confirmed','cleared','reported'));
CREATE INDEX content_cases_pending ON content_cases(created_at) WHERE status = 'pending';

-- A pending case binds a release exactly as an open one does.
CREATE OR REPLACE FUNCTION hold_release_blocker(p_case uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN c.status IN ('open','pending') THEN 'CASE_OPEN'
    WHEN c.legal_hold THEN 'LEGAL_HOLD'
    WHEN EXISTS (SELECT 1 FROM reports r WHERE r.status = 'open' AND r.subject_id = c.user_id) THEN 'REPORT_OPEN'
    WHEN EXISTS (SELECT 1 FROM content_cases o WHERE o.case_id <> c.case_id AND o.user_id = c.user_id AND o.status IN ('open','pending')) THEN 'OTHER_CASE_OPEN'
  END
  FROM content_cases c WHERE c.case_id = p_case
$$;

COMMENT ON FUNCTION held_objects_due(integer) IS
  'Released holds whose window is over. Correction to 0038: the API token for the evidence bucket is intended to be write-only, which R2 cannot enforce; the API proves what it can do (api check-config -net) and the console purge re-checks hold_still_releasable before every object delete.';

-- 3
-- evidence_approvals also carries admin promotions: no case, a target operator.
ALTER TABLE evidence_approvals ALTER COLUMN case_id DROP NOT NULL;
ALTER TABLE evidence_approvals ADD COLUMN target_operator uuid REFERENCES operators(operator_id);
ALTER TABLE evidence_approvals DROP CONSTRAINT evidence_approvals_kind_check;
ALTER TABLE evidence_approvals ADD CONSTRAINT evidence_approvals_kind_check CHECK (kind IN ('clear','release','legal_hold_lift','promote_admin'));
ALTER TABLE evidence_approvals ADD CONSTRAINT evidence_approvals_subject CHECK (
  (kind = 'promote_admin' AND target_operator IS NOT NULL AND case_id IS NULL) OR (kind <> 'promote_admin' AND case_id IS NOT NULL AND target_operator IS NULL));
-- Not validated against old rows: they were written before the format was fixed. Every new row must match.
ALTER TABLE evidence_approvals ADD CONSTRAINT evidence_approvals_counsel_format CHECK (
  counsel_reference IS NULL OR counsel_reference ~ '^[A-Za-z0-9][A-Za-z0-9 ._/-]{5,119}$') NOT VALID;
CREATE UNIQUE INDEX evidence_approvals_one_pending_promotion ON evidence_approvals(target_operator) WHERE status = 'pending' AND kind = 'promote_admin';

-- Internal helpers, executable by nobody (the definer functions below call them as the owner).
CREATE FUNCTION safety_fail(p_code text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'hiyall:%', p_code USING ERRCODE = 'HY001';
END
$$;

CREATE FUNCTION safety_admin_email(p_operator uuid) RETURNS text LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE e text;
BEGIN
  SELECT email INTO e FROM operators WHERE operator_id = p_operator AND role = 'admin' AND disabled_at IS NULL;
  IF e IS NULL THEN PERFORM safety_fail('NOT_ADMIN'); END IF;
  RETURN e;
END
$$;

CREATE FUNCTION safety_counsel_ok(p_ref text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_ref ~ '^[A-Za-z0-9][A-Za-z0-9 ._/-]{5,119}$'
$$;

-- Propose clearing a case, releasing its hold or lifting its legal hold.
CREATE FUNCTION evidence_propose(p_id uuid, p_case uuid, p_kind text, p_operator uuid, p_reason text, p_counsel text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE; blocker text; counsel text := nullif(btrim(coalesce(p_counsel, '')), '');
BEGIN
  PERFORM safety_admin_email(p_operator);
  IF p_kind NOT IN ('clear','release','legal_hold_lift') THEN PERFORM safety_fail('VALIDATION_KIND'); END IF;
  IF btrim(coalesce(p_reason, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  IF counsel IS NOT NULL AND NOT safety_counsel_ok(counsel) THEN PERFORM safety_fail('COUNSEL_REFERENCE'); END IF;
  IF p_kind = 'legal_hold_lift' AND counsel IS NULL THEN PERFORM safety_fail('COUNSEL_REFERENCE'); END IF;
  SELECT * INTO c FROM content_cases WHERE case_id = p_case FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF p_kind = 'clear' THEN
    IF c.status <> 'open' THEN PERFORM safety_fail('CASE_STATE'); END IF;
    IF c.legal_hold THEN PERFORM safety_fail('HOLD_LEGAL_HOLD'); END IF;
  ELSIF p_kind = 'release' THEN
    IF c.released_at IS NOT NULL THEN PERFORM safety_fail('HOLD_ALREADY_RELEASED'); END IF;
    blocker := hold_release_blocker(p_case);
    IF blocker IS NOT NULL THEN PERFORM safety_fail('HOLD_' || blocker); END IF;
  ELSIF NOT c.legal_hold THEN
    PERFORM safety_fail('CASE_STATE');
  END IF;
  -- A proposal past its time frees the slot for a new one.
  UPDATE evidence_approvals SET status = 'expired' WHERE case_id = p_case AND kind = p_kind AND status = 'pending' AND expires_at <= now();
  BEGIN
    INSERT INTO evidence_approvals(approval_id, case_id, kind, proposed_by, reason, counsel_reference, expires_at)
    VALUES (p_id, p_case, p_kind, p_operator, p_reason, counsel, now() + interval '24 hours');
  EXCEPTION WHEN unique_violation THEN
    PERFORM safety_fail('PROPOSAL_PENDING');
  END;
  RETURN p_id;
END
$$;

-- Propose making an operator an administrator. Needs a second administrator's approval (evidence_decide).
CREATE FUNCTION operator_promotion_propose(p_id uuid, p_target uuid, p_operator uuid, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t operators%ROWTYPE;
BEGIN
  PERFORM safety_admin_email(p_operator);
  IF btrim(coalesce(p_reason, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  PERFORM pg_advisory_xact_lock(4917303);
  SELECT * INTO t FROM operators WHERE operator_id = p_target;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF t.role = 'admin' THEN PERFORM safety_fail('NO_CHANGE'); END IF;
  IF t.disabled_at IS NOT NULL THEN PERFORM safety_fail('TARGET_DISABLED'); END IF;
  UPDATE evidence_approvals SET status = 'expired' WHERE target_operator = p_target AND kind = 'promote_admin' AND status = 'pending' AND expires_at <= now();
  BEGIN
    INSERT INTO evidence_approvals(approval_id, target_operator, kind, proposed_by, reason, expires_at)
    VALUES (p_id, p_target, 'promote_admin', p_operator, p_reason, now() + interval '24 hours');
  EXCEPTION WHEN unique_violation THEN
    PERFORM safety_fail('PROPOSAL_PENDING');
  END;
  RETURN p_id;
END
$$;

-- Approve, reject or withdraw a proposal. Approving applies the step in this transaction, checking again that it
-- still can be applied. Returns the proposal's new status ('expired' when it was past its 24 hours: it is marked,
-- nothing is applied, and the caller says so).
CREATE FUNCTION evidence_decide(p_approval uuid, p_operator uuid, p_decision text, p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a evidence_approvals%ROWTYPE; c content_cases%ROWTYPE; t operators%ROWTYPE; blocker text; email text; nstat text;
BEGIN
  email := safety_admin_email(p_operator);
  IF btrim(coalesce(p_reason, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  SELECT * INTO a FROM evidence_approvals WHERE approval_id = p_approval FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF a.status <> 'pending' THEN PERFORM safety_fail('PROPOSAL_DECIDED'); END IF;
  IF a.expires_at <= now() THEN
    UPDATE evidence_approvals SET status = 'expired' WHERE approval_id = p_approval;
    RETURN 'expired';
  END IF;
  IF p_decision IN ('approve', 'reject') THEN
    IF p_operator = a.proposed_by THEN PERFORM safety_fail('SECOND_APPROVER_REQUIRED'); END IF;
  ELSIF p_decision = 'withdraw' THEN
    IF p_operator <> a.proposed_by THEN PERFORM safety_fail('NOT_PROPOSER'); END IF;
  ELSE
    PERFORM safety_fail('VALIDATION_DECISION');
  END IF;
  nstat := CASE p_decision WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'withdrawn' END;
  IF p_decision = 'approve' AND a.kind = 'promote_admin' THEN
    PERFORM pg_advisory_xact_lock(4917303);
    SELECT * INTO t FROM operators WHERE operator_id = a.target_operator FOR UPDATE;
    IF NOT FOUND OR t.role = 'admin' OR t.disabled_at IS NOT NULL THEN PERFORM safety_fail('NO_CHANGE'); END IF;
    UPDATE operators SET role = 'admin' WHERE operator_id = a.target_operator;
  ELSIF p_decision = 'approve' THEN
    SELECT * INTO c FROM content_cases WHERE case_id = a.case_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
    IF a.kind = 'clear' THEN
      IF c.status <> 'open' THEN PERFORM safety_fail('CASE_STATE'); END IF;
      IF c.legal_hold THEN PERFORM safety_fail('HOLD_LEGAL_HOLD'); END IF;
      UPDATE content_cases SET status = 'cleared', reviewed_by = email, reviewed_at = now(), resolution_note = 'approved: ' || p_reason || ' | proposed: ' || a.reason WHERE case_id = a.case_id;
    ELSIF a.kind = 'release' THEN
      IF c.released_at IS NOT NULL THEN PERFORM safety_fail('HOLD_ALREADY_RELEASED'); END IF;
      blocker := hold_release_blocker(a.case_id);
      IF blocker IS NOT NULL THEN PERFORM safety_fail('HOLD_' || blocker); END IF;
      UPDATE content_cases SET released_at = now(), released_by = email, release_reason = 'approved: ' || p_reason || ' | proposed: ' || a.reason WHERE case_id = a.case_id;
    ELSE
      IF NOT c.legal_hold THEN PERFORM safety_fail('CASE_STATE'); END IF;
      IF a.counsel_reference IS NULL OR NOT safety_counsel_ok(a.counsel_reference) THEN PERFORM safety_fail('COUNSEL_REFERENCE'); END IF;
      UPDATE content_cases SET legal_hold = false WHERE case_id = a.case_id;
    END IF;
  END IF;
  UPDATE evidence_approvals SET status = nstat, decided_by = p_operator, decided_at = now(), decision_reason = p_reason WHERE approval_id = p_approval;
  RETURN nstat;
END
$$;

-- Mark every proposal past its 24 hours as expired (the console runs it on a timer; reads already show them so).
CREATE FUNCTION evidence_expire_due() RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n bigint;
BEGIN
  UPDATE evidence_approvals SET status = 'expired' WHERE status = 'pending' AND expires_at <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$$;

-- confirm / report a quarantine case. Both make the case evidence under a legal hold; 'reported' also keeps the
-- evidence at least a year from the report, however late it is made (hold_until never moves earlier).
CREATE FUNCTION content_case_confirm(p_case uuid, p_operator uuid, p_note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE; email text;
BEGIN
  email := safety_admin_email(p_operator);
  SELECT * INTO c FROM content_cases WHERE case_id = p_case FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF c.status <> 'open' THEN PERFORM safety_fail('CASE_STATE'); END IF;
  UPDATE content_cases SET status = 'confirmed', reviewed_by = email, reviewed_at = now(), resolution_note = p_note, legal_hold = true WHERE case_id = p_case;
  RETURN c.user_id;
END
$$;

CREATE FUNCTION content_case_report(p_case uuid, p_operator uuid, p_note text, p_reference text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE; email text;
BEGIN
  email := safety_admin_email(p_operator);
  IF btrim(coalesce(p_reference, '')) = '' OR length(p_reference) > 200 THEN PERFORM safety_fail('VALIDATION_REFERENCE'); END IF;
  SELECT * INTO c FROM content_cases WHERE case_id = p_case FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF c.status NOT IN ('open', 'confirmed') THEN PERFORM safety_fail('CASE_STATE'); END IF;
  UPDATE content_cases SET status = 'reported', reviewed_by = email, reviewed_at = now(), resolution_note = p_note, report_reference = p_reference, reported_at = now(),
         legal_hold = true, hold_until = greatest(hold_until, now() + interval '365 days')
   WHERE case_id = p_case;
  RETURN c.user_id;
END
$$;

-- Role changes. Anything but a promotion to administrator is done here; a promotion needs the approval above,
-- unless no administrator is active (bootstrap). The last active administrator is never demoted.
CREATE FUNCTION operator_set_role(p_target uuid, p_role text, p_operator uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t operators%ROWTYPE; others integer;
BEGIN
  IF p_role NOT IN ('viewer','moderator','admin') THEN PERFORM safety_fail('VALIDATION_ROLE'); END IF;
  PERFORM pg_advisory_xact_lock(4917303);
  SELECT count(*) INTO others FROM operators WHERE role = 'admin' AND disabled_at IS NULL AND operator_id <> p_target;
  IF p_operator IS NOT NULL OR others > 0 THEN PERFORM safety_admin_email(p_operator); END IF;
  SELECT * INTO t FROM operators WHERE operator_id = p_target FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF t.role = p_role THEN PERFORM safety_fail('NO_CHANGE'); END IF;
  IF p_role = 'admin' AND others > 0 THEN PERFORM safety_fail('APPROVAL_REQUIRED'); END IF;
  IF t.role = 'admin' AND t.disabled_at IS NULL AND others = 0 THEN PERFORM safety_fail('LAST_ADMIN'); END IF;
  UPDATE operators SET role = p_role WHERE operator_id = p_target;
END
$$;

-- Quarantine: the case is written 'pending' before the objects; this opens it once they are there. The API role
-- runs it (it still cannot read or change a case otherwise).
CREATE FUNCTION activate_quarantine_case(p_case uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE content_cases SET status = 'open' WHERE case_id = p_case AND status = 'pending';
  RETURN FOUND;
END
$$;

-- The console's sweep: pending cases older than an hour, then either activate (objects present) or drop (missing).
CREATE FUNCTION pending_cases_due(p_limit integer) RETURNS TABLE(case_id uuid, media_id uuid, user_id uuid, result text, original_key text, full_key text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT c.case_id, c.media_id, c.user_id, c.result, c.original_key, c.full_key, c.created_at FROM content_cases c
   WHERE c.status = 'pending' AND c.created_at < now() - interval '1 hour' ORDER BY c.created_at LIMIT p_limit
$$;

-- Drop a pending case whose objects are gone. The upload becomes 'deleted'; a suspension a match caused stays.
CREATE FUNCTION drop_pending_case(p_case uuid, p_actor text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE;
BEGIN
  SELECT * INTO c FROM content_cases WHERE case_id = p_case AND status = 'pending' AND created_at < now() - interval '1 hour' FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  DELETE FROM content_cases WHERE case_id = p_case;
  UPDATE media_assets SET status = 'deleted', variants = NULL WHERE media_id = c.media_id AND status = 'quarantined';
  INSERT INTO operator_audit(actor, action, target_type, target_id, reason, detail)
  VALUES (p_actor, 'pending_case_dropped', 'content_case', p_case::text, 'evidence objects were never written',
          jsonb_build_object('mediaId', c.media_id, 'userId', c.user_id, 'result', c.result, 'suspendedUser', c.suspended_user));
  RETURN true;
END
$$;

-- Used by the purge immediately before each object delete: is the hold STILL releasable and due? (A report can be
-- opened between the list and the delete.)
CREATE FUNCTION hold_still_releasable(p_case uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT c.released_at IS NOT NULL AND c.objects_purged_at IS NULL AND c.hold_until <= now() AND hold_release_blocker(c.case_id) IS NULL
                     FROM content_cases c WHERE c.case_id = p_case), false)
$$;

-- Support-driven deletion (`admin schedule-deletion`): what POST /v1/me/deletion does, for the console role, which has
-- no access to the member tables. An Apple identity gets a 'manual' revocation row. Audited here.
CREATE FUNCTION admin_schedule_deletion(p_user uuid, p_actor text, p_reason text, p_channel text, p_notice text) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE st text; due timestamptz; apple integer;
BEGIN
  IF btrim(coalesce(p_reason, '')) = '' OR btrim(coalesce(p_actor, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  SELECT status, deletion_due_at INTO st, due FROM users WHERE user_id = p_user FOR NO KEY UPDATE;
  IF NOT FOUND OR st NOT IN ('active', 'pending_deletion') THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF st = 'pending_deletion' THEN RETURN due; END IF;
  UPDATE users SET status = 'pending_deletion', deletion_scheduled_at = now(), deletion_due_at = now() + interval '30 days' WHERE user_id = p_user RETURNING deletion_due_at INTO due;
  UPDATE sessions SET revoked_at = coalesce(revoked_at, now()) WHERE user_id = p_user;
  UPDATE auth_identities SET sessions_revoked_before = now() WHERE user_id = p_user;
  UPDATE devices SET push_provider = NULL, push_token = NULL WHERE user_id = p_user;
  INSERT INTO apple_revocations(issuer, subject, status, user_id, reason)
  SELECT issuer, subject, 'manual', p_user, 'support-driven deletion: ' || left(p_reason, 200) FROM auth_identities
   WHERE user_id = p_user AND (sign_in_provider = 'apple.com' OR apple_linked)
  ON CONFLICT (issuer, subject) DO NOTHING;  -- an existing row (a sealed token the purge will use) is kept
  GET DIAGNOSTICS apple = ROW_COUNT;
  PERFORM pg_notify(p_channel, p_notice);
  INSERT INTO operator_audit(actor, action, target_type, target_id, reason, detail)
  VALUES (p_actor, 'account_deletion_scheduled', 'user', p_user::text, p_reason, jsonb_build_object('dueAt', due, 'appleManualRevocations', apple));
  RETURN due;
END
$$;

-- Numbers for the API's gauges (hiyall_pending_approvals and friends). Counts only: nothing a member could read.
CREATE FUNCTION safety_queue_stats() RETURNS TABLE(pending_approvals integer, oldest_pending_seconds double precision, manual_apple_revocations integer, pending_cases integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (SELECT count(*)::integer FROM evidence_approvals WHERE status = 'pending' AND expires_at > now()),
         coalesce((SELECT extract(epoch FROM now() - min(proposed_at))::double precision FROM evidence_approvals WHERE status = 'pending' AND expires_at > now()), 0),
         (SELECT count(*)::integer FROM apple_revocations WHERE status = 'manual'),
         (SELECT count(*)::integer FROM content_cases WHERE status = 'pending')
$$;

REVOKE ALL ON FUNCTION safety_fail(text), safety_admin_email(uuid), safety_counsel_ok(text),
  evidence_propose(uuid, uuid, text, uuid, text, text), operator_promotion_propose(uuid, uuid, uuid, text), evidence_decide(uuid, uuid, text, text),
  evidence_expire_due(), content_case_confirm(uuid, uuid, text), content_case_report(uuid, uuid, text, text), operator_set_role(uuid, text, uuid),
  activate_quarantine_case(uuid), pending_cases_due(integer), drop_pending_case(uuid, text), hold_still_releasable(uuid),
  admin_schedule_deletion(uuid, text, text, text, text), safety_queue_stats() FROM PUBLIC;
