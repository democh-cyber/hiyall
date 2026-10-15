-- Safety release (re-audit API-4, API-8, SAFE-1, LEGAL-2, admin items).
--
-- 1. Nearby: the stored point is moved by a STABLE per-member offset derived on the server (HMAC of the user id
--    under NEARBY_OFFSET_KEY), not by a daily random one, so averaging many days of results no longer converges.
--    nearby_prefs.offset_* stay as an explicit pin (offset_day not null) that production never writes; any value
--    left by the daily scheme is cleared here. nearby_probe_centres counts the distinct search centres an account
--    or a source address has probed today; the API refuses a new centre past the cap.
-- 2. auth_identities.sign_in_provider: Firebase's sign_in_provider claim at the last sign-in (apple.com, google.com,
--    password, ...) and whether apple.com is linked. Account deletion for an identity with Apple needs the Apple
--    authorization code. Existing rows are filled at their next sign-in.
-- 3. content_cases.hold_until now defaults to one year (pending counsel). Only NEW cases get it; existing rows are
--    untouched. The API also passes EVIDENCE_RETENTION_DAYS explicitly.
-- 4. evidence_approvals: the second-approver record. Clearing a quarantine case, releasing an evidence hold and
--    lifting a legal hold each need a proposal by one operator and an approval by a different one within 24 hours.
--    The table lives with the operator tables: the API role has no access (database/roles/grants.sql).
-- 5. prune_operator_audit removes ONE batch of at most 5000 entries per call, so the table lock it needs
--    (ALTER TABLE ... DISABLE TRIGGER) is held for milliseconds and audited reads, which insert an audit row first,
--    are not blocked for long. The console calls it in a loop, each call its own transaction.

-- 1
UPDATE nearby_prefs SET offset_day = NULL, offset_north_km = 0, offset_east_km = 0;

CREATE TABLE nearby_probe_centres (
  -- Keyed hash of the account id or of the source address; the id and the address themselves are never stored.
  subject bytea NOT NULL,
  day date NOT NULL,
  -- Keyed hash of the stored point used as the search centre.
  centre bytea NOT NULL,
  PRIMARY KEY (subject, day, centre)
);
CREATE INDEX nearby_probe_centres_day ON nearby_probe_centres(day);

-- 2
ALTER TABLE auth_identities ADD COLUMN sign_in_provider text CHECK (sign_in_provider IS NULL OR length(sign_in_provider) <= 128);
-- True when the token also lists apple.com among the linked providers (an account that signed in with Google
-- but once linked Apple still holds an Apple authorization that deletion must revoke).
ALTER TABLE auth_identities ADD COLUMN apple_linked boolean NOT NULL DEFAULT false;

-- 3
ALTER TABLE content_cases ALTER COLUMN hold_until SET DEFAULT now() + interval '365 days';

-- 4
CREATE TABLE evidence_approvals (
  approval_id uuid PRIMARY KEY,
  case_id uuid NOT NULL REFERENCES content_cases(case_id),
  -- clear: close an open case as cleared. release: release the evidence hold. legal_hold_lift: remove the legal
  -- hold (needs counsel's reference).
  kind text NOT NULL CHECK (kind IN ('clear','release','legal_hold_lift')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired','withdrawn')),
  proposed_by uuid NOT NULL REFERENCES operators(operator_id),
  proposed_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  counsel_reference text CHECK (counsel_reference IS NULL OR length(counsel_reference) <= 200),
  expires_at timestamptz NOT NULL,
  decided_by uuid REFERENCES operators(operator_id),
  decided_at timestamptz,
  decision_reason text,
  -- The proposer can never approve their own proposal.
  CONSTRAINT evidence_approvals_two_people CHECK (decided_by IS NULL OR status IN ('withdrawn','expired') OR decided_by <> proposed_by),
  CONSTRAINT evidence_approvals_counsel CHECK (kind <> 'legal_hold_lift' OR btrim(coalesce(counsel_reference, '')) <> ''),
  CONSTRAINT evidence_approvals_decided CHECK ((status = 'pending') = (decided_at IS NULL) OR status = 'expired')
);
-- One open proposal per case and kind.
CREATE UNIQUE INDEX evidence_approvals_one_pending ON evidence_approvals(case_id, kind) WHERE status = 'pending';
CREATE INDEX evidence_approvals_case ON evidence_approvals(case_id, proposed_at DESC);

-- 5
CREATE OR REPLACE FUNCTION prune_operator_audit(p_operator uuid, p_actor text, p_reason text, p_older_than_days integer DEFAULT 365) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET lock_timeout = '2s' AS $$
DECLARE removed bigint; cutoff timestamptz;
BEGIN
  IF p_older_than_days IS NULL OR p_older_than_days < 365 THEN
    RAISE EXCEPTION 'audit entries younger than 365 days are never pruned' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023';
  END IF;
  cutoff := now() - make_interval(days => p_older_than_days);
  -- One batch: the caller repeats until it gets fewer than 5000 back.
  ALTER TABLE operator_audit DISABLE TRIGGER operator_audit_no_change;
  DELETE FROM operator_audit WHERE audit_id IN (SELECT audit_id FROM operator_audit WHERE at < cutoff ORDER BY audit_id LIMIT 5000);
  GET DIAGNOSTICS removed = ROW_COUNT;
  ALTER TABLE operator_audit ENABLE TRIGGER operator_audit_no_change;
  IF removed > 0 THEN
    INSERT INTO operator_audit(operator_id, actor, action, target_type, target_id, reason, detail)
    VALUES (p_operator, p_actor, 'audit_prune', 'operator_audit', '', p_reason,
            jsonb_build_object('deleted', removed, 'olderThanDays', p_older_than_days, 'cutoff', cutoff, 'batchLimit', 5000));
  END IF;
  RETURN removed;
END
$$;
REVOKE ALL ON FUNCTION prune_operator_audit(uuid, text, text, integer) FROM PUBLIC;
