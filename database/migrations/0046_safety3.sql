-- Safety release 3 (round-4 audit API N-1 to N-12, DB N2 and N8).
--
-- 1. content_cases: the API role can open a case and nothing more (N-1). Its INSERT is limited to the columns the
--    upload scanner fills; the keys of the held objects must be the ones the upload path writes
--    (hold/<media id>/original and hold/<media id>/full.jpg), so a case cannot be made to point at someone else's
--    evidence; and a trigger forces everything a reviewer or an approval sets (status, release, report, legal hold)
--    for the API role whatever it sends. A compromised API can no longer insert a case that is already "released"
--    for real evidence and have the console's purge delete it.
-- 2. Operators (N-2, DB N2): creating an operator and disabling or enabling one are SECURITY DEFINER functions;
--    hiyall_admin has no INSERT on operators and no UPDATE on operators.disabled_at any more. operator_create
--    refuses an administrator while another one is active (promotion goes through a second administrator's
--    approval) and an account that is not an e-mail address. operator_set_disabled refuses to leave no active
--    administrator and a self-disable, except for the CLI's emergency path.
-- 3. The two-person functions write their audit row inside the function, in the caller's transaction, with the
--    operator the console named (N-3). evidence_decide also refuses to approve what a proposer proposed who is no
--    longer an active administrator, and disabling or demoting an administrator withdraws what they proposed.
--    The caller's client address, the reason and the CLI actor come in through transaction-local settings
--    (hiyall.ip, hiyall.reason, hiyall.actor), so no function signature changes.
-- 4. Apple (N-4): there is no way for an operator to revoke a member's Sign in with Apple authorization by hand
--    (Apple's API needs the member's own token and the developer portal has no per-user revoke). A deletion made
--    without a code now records 'member_informed': the app told the member to remove Hiyall in Apple ID settings.
--    The row is a record only and is removed after 90 days. 'manual' stays for a deletion that support scheduled:
--    the member could not be told in the app, so an operator tells them, then acknowledges. Acknowledging goes
--    through apple_revocation_acknowledge; hiyall_admin has no DELETE on the table any more.
-- 5. Pending cases (N-7): a case made for a scanner match is never dropped by the sweep, only a flagged one is.
--    The sweep's orphan report is kept in the database so every console node answers the same (N-12), and the
--    hold purge locks the case row (FOR SHARE) across its object deletes (DB N8).
-- 6. Support-driven deletion (N-12) records the real operator, works for a suspended, banned or deactivated
--    member (an erasure request), and a member suspended or banned cannot cancel it.
-- 7. quarantine_upload_leftovers: the key of an upload that could not be removed from the upload prefix after its
--    evidence was stored, so the API's cleanup job removes it later (N-7).

-- 1
ALTER TABLE content_cases ALTER COLUMN status SET DEFAULT 'pending';
-- NOT VALID: a row from before this release is not re-checked, every new row and every update of one is.
ALTER TABLE content_cases ADD CONSTRAINT content_cases_original_key CHECK (original_key = 'hold/' || media_id::text || '/original') NOT VALID;
ALTER TABLE content_cases ADD CONSTRAINT content_cases_full_key CHECK (full_key IS NULL OR full_key = 'hold/' || media_id::text || '/full.jpg') NOT VALID;

CREATE FUNCTION content_cases_insert_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  -- Only the API role is constrained here: it is the one process that faces the internet. The schema owner, a
  -- superuser and the tests insert what they mean to.
  IF current_user = 'hiyall_api' THEN
    NEW.status := 'pending';
    NEW.legal_hold := false;
    NEW.reviewed_by := NULL; NEW.reviewed_at := NULL; NEW.resolution_note := NULL;
    NEW.released_at := NULL; NEW.released_by := NULL; NEW.release_reason := NULL; NEW.objects_purged_at := NULL;
    NEW.report_reference := NULL; NEW.reported_at := NULL;
    -- Never shorter than the least EVIDENCE_RETENTION_DAYS allows.
    NEW.hold_until := greatest(NEW.hold_until, now() + interval '30 days');
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER content_cases_insert_guard BEFORE INSERT ON content_cases FOR EACH ROW EXECUTE FUNCTION content_cases_insert_guard();

-- 2 and 5
ALTER TABLE users ADD COLUMN deletion_prior_status text CHECK (deletion_prior_status IS NULL OR deletion_prior_status IN ('active','deactivated','suspended','banned'));

ALTER TABLE apple_revocations DROP CONSTRAINT apple_revocations_status_check;
ALTER TABLE apple_revocations ADD CONSTRAINT apple_revocations_status_check CHECK (status IN ('queued','manual','member_informed'));
CREATE INDEX apple_revocations_informed ON apple_revocations(created_at) WHERE status = 'member_informed';

CREATE TABLE evidence_orphan_report (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  checked_at timestamptz NOT NULL,
  complete boolean NOT NULL,
  items jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(items) = 'array')
);

CREATE TABLE quarantine_upload_leftovers (
  object_key text PRIMARY KEY,
  media_id uuid,
  recorded_at timestamptz NOT NULL DEFAULT now()
);

-- Internal helpers, executable by nobody (the definer functions below call them as the owner).
CREATE FUNCTION safety_setting(p_name text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT nullif(btrim(current_setting(p_name, true)), '')
$$;

CREATE FUNCTION safety_audit(p_operator uuid, p_actor text, p_action text, p_type text, p_id text, p_reason text, p_detail jsonb) RETURNS void
LANGUAGE sql SET search_path = public, pg_temp AS $$
  INSERT INTO operator_audit(operator_id, actor, action, target_type, target_id, reason, ip, detail)
  VALUES (p_operator, coalesce(nullif(p_actor, ''), 'unknown'), p_action, p_type, p_id, coalesce(p_reason, ''), left(coalesce(safety_setting('hiyall.ip'), ''), 64), coalesce(p_detail, '{}'::jsonb))
$$;

-- Evidence proposals, now audited here (3).
CREATE OR REPLACE FUNCTION evidence_propose(p_id uuid, p_case uuid, p_kind text, p_operator uuid, p_reason text, p_counsel text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE; blocker text; email text; counsel text := nullif(btrim(coalesce(p_counsel, '')), '');
BEGIN
  email := safety_admin_email(p_operator);
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
  PERFORM safety_audit(p_operator, email, 'evidence_proposed', 'content_case', p_case::text, p_reason,
    jsonb_strip_nulls(jsonb_build_object('approvalId', p_id, 'kind', p_kind, 'subjectId', c.user_id, 'proposedBy', email, 'status', 'pending', 'counselReference', counsel)));
  RETURN p_id;
END
$$;

CREATE OR REPLACE FUNCTION operator_promotion_propose(p_id uuid, p_target uuid, p_operator uuid, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t operators%ROWTYPE; email text;
BEGIN
  email := safety_admin_email(p_operator);
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
  PERFORM safety_audit(p_operator, email, 'evidence_proposed', 'operator', p_target::text, p_reason,
    jsonb_build_object('approvalId', p_id, 'kind', 'promote_admin', 'subjectId', p_target, 'proposedBy', email, 'status', 'pending', 'targetEmail', t.email));
  RETURN p_id;
END
$$;

CREATE OR REPLACE FUNCTION evidence_decide(p_approval uuid, p_operator uuid, p_decision text, p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a evidence_approvals%ROWTYPE; c content_cases%ROWTYPE; t operators%ROWTYPE; blocker text; email text; pemail text; nstat text; subject text;
        detail jsonb; kindaction text;
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
  -- Two people means two administrators who are both still administrators when it is approved: a proposal made by
  -- someone since disabled or demoted is not approved on their old authority (round-4 N-3).
  IF p_decision = 'approve' AND NOT EXISTS (SELECT 1 FROM operators o WHERE o.operator_id = a.proposed_by AND o.role = 'admin' AND o.disabled_at IS NULL) THEN
    PERFORM safety_fail('PROPOSER_NOT_ADMIN');
  END IF;
  SELECT o.email INTO pemail FROM operators o WHERE o.operator_id = a.proposed_by;
  nstat := CASE p_decision WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'withdrawn' END;
  IF a.kind = 'promote_admin' THEN
    subject := a.target_operator::text;
  ELSE
    SELECT user_id::text INTO subject FROM content_cases WHERE case_id = a.case_id;
  END IF;
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
  detail := jsonb_strip_nulls(jsonb_build_object('approvalId', a.approval_id, 'kind', a.kind, 'subjectId', subject, 'proposedBy', pemail, 'status', nstat, 'decidedBy', email,
    'counselReference', a.counsel_reference, 'targetEmail', t.email));
  PERFORM safety_audit(p_operator, email, 'evidence_' || nstat, CASE WHEN a.kind = 'promote_admin' THEN 'operator' ELSE 'content_case' END,
    coalesce(a.case_id::text, a.target_operator::text), p_reason, detail);
  IF p_decision = 'approve' THEN
    IF a.kind = 'promote_admin' THEN
      PERFORM safety_audit(p_operator, email, 'operator_role', 'operator', a.target_operator::text, p_reason,
        jsonb_build_object('email', t.email, 'to', 'admin', 'approvalId', a.approval_id, 'proposedBy', pemail, 'approvedBy', email, 'proposalReason', a.reason));
    ELSE
      kindaction := CASE a.kind WHEN 'clear' THEN 'content_case_clear' WHEN 'release' THEN 'hold_release' ELSE 'legal_hold_lift' END;
      PERFORM safety_audit(p_operator, email, kindaction, 'content_case', a.case_id::text, p_reason,
        jsonb_build_object('subjectId', subject, 'approvalId', a.approval_id, 'proposedBy', pemail, 'approvedBy', email, 'proposalReason', a.reason, 'counselReference', coalesce(a.counsel_reference, '')));
    END IF;
  END IF;
  RETURN nstat;
END
$$;

CREATE OR REPLACE FUNCTION content_case_confirm(p_case uuid, p_operator uuid, p_note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE; email text;
BEGIN
  email := safety_admin_email(p_operator);
  SELECT * INTO c FROM content_cases WHERE case_id = p_case FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF c.status <> 'open' THEN PERFORM safety_fail('CASE_STATE'); END IF;
  UPDATE content_cases SET status = 'confirmed', reviewed_by = email, reviewed_at = now(), resolution_note = p_note, legal_hold = true WHERE case_id = p_case;
  PERFORM safety_audit(p_operator, email, 'content_case_confirm', 'content_case', p_case::text, p_note, jsonb_build_object('subjectId', c.user_id, 'reportReference', ''));
  RETURN c.user_id;
END
$$;

CREATE OR REPLACE FUNCTION content_case_report(p_case uuid, p_operator uuid, p_note text, p_reference text) RETURNS uuid
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
  PERFORM safety_audit(p_operator, email, 'content_case_reported', 'content_case', p_case::text, p_note, jsonb_build_object('subjectId', c.user_id, 'reportReference', p_reference));
  RETURN c.user_id;
END
$$;

-- Role changes. The reason and, for the CLI, the actor arrive as hiyall.reason and hiyall.actor.
CREATE OR REPLACE FUNCTION operator_set_role(p_target uuid, p_role text, p_operator uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t operators%ROWTYPE; others integer; email text; withdrawn integer := 0;
BEGIN
  IF p_role NOT IN ('viewer','moderator','admin') THEN PERFORM safety_fail('VALIDATION_ROLE'); END IF;
  PERFORM pg_advisory_xact_lock(4917303);
  SELECT count(*) INTO others FROM operators WHERE role = 'admin' AND disabled_at IS NULL AND operator_id <> p_target;
  IF p_operator IS NOT NULL OR others > 0 THEN email := safety_admin_email(p_operator); END IF;
  SELECT * INTO t FROM operators WHERE operator_id = p_target FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF t.role = p_role THEN PERFORM safety_fail('NO_CHANGE'); END IF;
  IF p_role = 'admin' AND others > 0 THEN PERFORM safety_fail('APPROVAL_REQUIRED'); END IF;
  IF t.role = 'admin' AND t.disabled_at IS NULL AND others = 0 THEN PERFORM safety_fail('LAST_ADMIN'); END IF;
  UPDATE operators SET role = p_role WHERE operator_id = p_target;
  IF t.role = 'admin' THEN
    UPDATE evidence_approvals SET status = 'withdrawn', decided_by = proposed_by, decided_at = now(), decision_reason = 'the proposer is no longer an administrator'
     WHERE proposed_by = p_target AND status = 'pending';
    GET DIAGNOSTICS withdrawn = ROW_COUNT;
  END IF;
  PERFORM safety_audit(p_operator, coalesce(email, safety_setting('hiyall.actor'), 'unknown'), 'operator_role', 'operator', p_target::text, safety_setting('hiyall.reason'),
    jsonb_build_object('email', t.email, 'from', t.role, 'to', p_role, 'withdrawnProposals', withdrawn));
END
$$;

-- 2: creating an operator. The role is the point: no administrator is made here while another is active.
CREATE FUNCTION operator_create(p_id uuid, p_email text, p_display_name text, p_role text, p_password_hash text, p_totp_sealed bytea,
                                p_operator uuid, p_actor text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE admins integer; actor text;
BEGIN
  IF p_role NOT IN ('viewer','moderator','admin') THEN PERFORM safety_fail('VALIDATION_ROLE'); END IF;
  IF p_email IS NULL OR p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN PERFORM safety_fail('VALIDATION_EMAIL'); END IF;
  IF coalesce(p_password_hash, '') = '' OR p_totp_sealed IS NULL THEN PERFORM safety_fail('VALIDATION_CREDENTIALS'); END IF;
  PERFORM pg_advisory_xact_lock(4917303);
  SELECT count(*) INTO admins FROM operators WHERE role = 'admin' AND disabled_at IS NULL;
  IF p_operator IS NOT NULL THEN
    actor := safety_admin_email(p_operator);
  ELSE
    actor := nullif(btrim(coalesce(p_actor, '')), '');
    IF actor IS NULL THEN PERFORM safety_fail('VALIDATION_ACTOR'); END IF;
  END IF;
  -- Bootstrap: the first administrator. Afterwards an administrator is made by a promotion a second one approves.
  IF p_role = 'admin' AND admins > 0 THEN PERFORM safety_fail('APPROVAL_REQUIRED'); END IF;
  BEGIN
    INSERT INTO operators(operator_id, email, display_name, role, password_hash, totp_secret) VALUES (p_id, p_email, p_display_name, p_role, p_password_hash, p_totp_sealed);
  EXCEPTION WHEN unique_violation THEN
    PERFORM safety_fail('EMAIL_TAKEN');
  END;
  PERFORM safety_audit(p_operator, actor, 'operator_create', 'operator', p_id::text, 'new operator', jsonb_build_object('email', p_email, 'role', p_role, 'bootstrap', p_role = 'admin'));
END
$$;

-- Disable or enable an operator; ends their sessions and withdraws what they proposed. Returns how many administrators
-- are active afterwards. p_force is the CLI's emergency path (a stolen device of the only administrator) and is
-- refused when a console operator is named.
CREATE FUNCTION operator_set_disabled(p_target uuid, p_disable boolean, p_operator uuid, p_actor text, p_reason text, p_force boolean) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t operators%ROWTYPE; others integer; remaining integer; actor text; withdrawn integer := 0;
BEGIN
  IF btrim(coalesce(p_reason, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  PERFORM pg_advisory_xact_lock(4917303);
  IF p_operator IS NOT NULL THEN
    IF p_force THEN PERFORM safety_fail('FORCE_FORBIDDEN'); END IF;
    actor := safety_admin_email(p_operator);
  ELSE
    actor := nullif(btrim(coalesce(p_actor, '')), '');
    IF actor IS NULL THEN PERFORM safety_fail('VALIDATION_ACTOR'); END IF;
  END IF;
  SELECT * INTO t FROM operators WHERE operator_id = p_target FOR UPDATE;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF p_disable = (t.disabled_at IS NOT NULL) THEN PERFORM safety_fail('NO_CHANGE'); END IF;
  SELECT count(*) INTO others FROM operators WHERE role = 'admin' AND disabled_at IS NULL AND operator_id <> p_target;
  IF p_disable THEN
    IF NOT coalesce(p_force, false) THEN
      IF p_operator IS NOT NULL AND p_operator = p_target THEN PERFORM safety_fail('SELF_DISABLE'); END IF;
      IF t.role = 'admin' AND others = 0 THEN PERFORM safety_fail('LAST_ADMIN'); END IF;
    END IF;
    UPDATE operators SET disabled_at = now() WHERE operator_id = p_target;
    UPDATE operator_sessions SET revoked_at = now() WHERE operator_id = p_target AND revoked_at IS NULL;
    UPDATE evidence_approvals SET status = 'withdrawn', decided_by = proposed_by, decided_at = now(), decision_reason = 'the proposer was disabled'
     WHERE proposed_by = p_target AND status = 'pending';
    GET DIAGNOSTICS withdrawn = ROW_COUNT;
    remaining := others;
  ELSE
    UPDATE operators SET disabled_at = NULL WHERE operator_id = p_target;
    remaining := others + CASE WHEN t.role = 'admin' THEN 1 ELSE 0 END;
  END IF;
  PERFORM safety_audit(p_operator, actor, CASE WHEN p_disable THEN 'operator_disable' ELSE 'operator_enable' END, 'operator', p_target::text, p_reason,
    jsonb_build_object('email', t.email, 'activeAdmins', remaining, 'withdrawnProposals', withdrawn));
  RETURN remaining;
END
$$;

-- 4: Apple rows. The console reads them (column grant) and acknowledges one here; nothing else deletes.
CREATE FUNCTION apple_revocation_acknowledge(p_id uuid, p_operator uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r apple_revocations%ROWTYPE; email text;
BEGIN
  email := safety_admin_email(p_operator);
  IF btrim(coalesce(p_reason, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  DELETE FROM apple_revocations WHERE revocation_id = p_id AND status IN ('manual', 'member_informed') RETURNING * INTO r;
  IF NOT FOUND THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  PERFORM safety_audit(p_operator, email, 'apple_revocation_acknowledged', 'user', coalesce(r.user_id::text, ''), p_reason,
    jsonb_build_object('revocationId', r.revocation_id, 'issuer', r.issuer, 'status', r.status, 'createdAt', r.created_at));
END
$$;

-- A 'member_informed' row is a record that the app told the member; it is removed after 90 days.
CREATE FUNCTION apple_revocations_prune(p_older_than_days integer) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n bigint;
BEGIN
  IF p_older_than_days IS NULL OR p_older_than_days < 30 THEN
    RAISE EXCEPTION 'records younger than 30 days are never pruned' USING ERRCODE = '22023';
  END IF;
  DELETE FROM apple_revocations WHERE status = 'member_informed' AND created_at < now() - make_interval(days => p_older_than_days);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$$;

-- 5: only a flagged pending case is ever dropped. A scanner match stays for an operator.
CREATE OR REPLACE FUNCTION drop_pending_case(p_case uuid, p_actor text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c content_cases%ROWTYPE;
BEGIN
  SELECT * INTO c FROM content_cases WHERE case_id = p_case AND status = 'pending' AND result = 'flagged' AND created_at < now() - interval '1 hour' FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  DELETE FROM content_cases WHERE case_id = p_case;
  UPDATE media_assets SET status = 'deleted', variants = NULL WHERE media_id = c.media_id AND status = 'quarantined';
  INSERT INTO operator_audit(actor, action, target_type, target_id, reason, detail)
  VALUES (p_actor, 'pending_case_dropped', 'content_case', p_case::text, 'evidence objects were never written',
          jsonb_build_object('mediaId', c.media_id, 'userId', c.user_id, 'result', c.result, 'suspendedUser', c.suspended_user));
  RETURN true;
END
$$;

-- The hold purge takes this lock before it deletes an object and keeps it, in the caller's transaction, until the case
-- is marked purged (round-4 DB N8): a report or a legal hold, which update the case row, wait for it.
CREATE FUNCTION hold_lock_for_purge(p_case uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM 1 FROM content_cases WHERE case_id = p_case FOR SHARE;
  IF NOT FOUND THEN RETURN false; END IF;
  RETURN hold_still_releasable(p_case);
END
$$;

-- 6: support-driven deletion records the real operator and works for members who cannot cancel it.
CREATE OR REPLACE FUNCTION admin_schedule_deletion(p_user uuid, p_actor text, p_reason text, p_channel text, p_notice text) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE st text; due timestamptz; apple integer; op uuid; actor text := lower(btrim(coalesce(p_actor, '')));
BEGIN
  IF btrim(coalesce(p_reason, '')) = '' THEN PERFORM safety_fail('VALIDATION_REASON'); END IF;
  IF actor !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN PERFORM safety_fail('VALIDATION_ACTOR'); END IF;
  SELECT operator_id INTO op FROM operators WHERE email = actor AND role = 'admin' AND disabled_at IS NULL;
  IF op IS NULL THEN PERFORM safety_fail('NOT_ADMIN'); END IF;
  SELECT status, deletion_due_at INTO st, due FROM users WHERE user_id = p_user FOR NO KEY UPDATE;
  IF NOT FOUND OR st NOT IN ('active', 'suspended', 'banned', 'deactivated', 'pending_deletion') THEN PERFORM safety_fail('NOT_FOUND'); END IF;
  IF st = 'pending_deletion' THEN RETURN due; END IF;
  UPDATE users SET status = 'pending_deletion', deletion_prior_status = st, deletion_scheduled_at = now(), deletion_due_at = now() + interval '30 days' WHERE user_id = p_user RETURNING deletion_due_at INTO due;
  UPDATE sessions SET revoked_at = coalesce(revoked_at, now()) WHERE user_id = p_user;
  UPDATE auth_identities SET sessions_revoked_before = now() WHERE user_id = p_user;
  UPDATE devices SET push_provider = NULL, push_token = NULL WHERE user_id = p_user;
  INSERT INTO apple_revocations(issuer, subject, status, user_id, reason)
  SELECT issuer, subject, 'manual', p_user, 'support-driven deletion: ' || left(p_reason, 200) || ' (tell the member to remove Hiyall under Settings > Apple ID > Sign in with Apple)' FROM auth_identities
   WHERE user_id = p_user AND (sign_in_provider = 'apple.com' OR apple_linked)
  ON CONFLICT (issuer, subject) DO NOTHING;  -- an existing row (a sealed token the purge will use) is kept
  GET DIAGNOSTICS apple = ROW_COUNT;
  PERFORM pg_notify(p_channel, p_notice);
  PERFORM safety_audit(op, actor, 'account_deletion_scheduled', 'user', p_user::text, p_reason, jsonb_build_object('dueAt', due, 'priorStatus', st, 'appleMemberNotices', apple));
  RETURN due;
END
$$;

-- Counts for the gauges: 'manual' rows are the ones an operator still has to act on.
CREATE OR REPLACE FUNCTION safety_queue_stats() RETURNS TABLE(pending_approvals integer, oldest_pending_seconds double precision, manual_apple_revocations integer, pending_cases integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (SELECT count(*)::integer FROM evidence_approvals WHERE status = 'pending' AND expires_at > now()),
         coalesce((SELECT extract(epoch FROM now() - min(proposed_at))::double precision FROM evidence_approvals WHERE status = 'pending' AND expires_at > now()), 0),
         (SELECT count(*)::integer FROM apple_revocations WHERE status = 'manual'),
         (SELECT count(*)::integer FROM content_cases WHERE status = 'pending')
$$;

REVOKE ALL ON FUNCTION content_cases_insert_guard(), safety_setting(text), safety_audit(uuid, text, text, text, text, text, jsonb),
  operator_create(uuid, text, text, text, text, bytea, uuid, text), operator_set_disabled(uuid, boolean, uuid, text, text, boolean),
  apple_revocation_acknowledge(uuid, uuid, text), apple_revocations_prune(integer), hold_lock_for_purge(uuid) FROM PUBLIC;
