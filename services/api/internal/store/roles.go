package store

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strings"
)

// Database role checks (database/roles). The API is meant to connect as hiyall_api: it can read and write what
// members own and cannot reach the operator tables, the audit log or case evidence. These checks say whether the
// connection it was given is that role, and whether the grants a release applied are complete.

// OperatorTables are never readable (or writable) by the API role.
//
// This file is the one Go source of truth for the tables and sequences that database/roles/grants.sql treats
// specially (excluded from the blanket grant to hiyall_api, asserted at its end). TestSpecialTablesMatchGrantsScript
// parses grants.sql and fails when the script and these lists differ, so a table added to one is not forgotten in
// the other (round-3 audit DB-NEW-9).
var OperatorTables = []string{"operators", "operator_sessions", "operator_login_attempts", "operator_audit", "evidence_approvals"}

// CaseTable is the one table the API may INSERT into and read one column of (media_id), nothing else.
const CaseTable = "content_cases"

// SpecialTables are the OperatorTables and CaseTable: what GrantProblems expects the API role to be kept away from.
func SpecialTables() []string { return append(append([]string{}, OperatorTables...), CaseTable) }

// OperatorSequences are the sequences of operator tables; the API role has no USAGE on them.
var OperatorSequences = []string{"operator_login_attempts_attempt_id_seq", "operator_audit_audit_id_seq"}

func isSpecialTable(name string) bool { return slices.Contains(SpecialTables(), name) }

// RoleProblems says what is wrong with the role this store's connections run as, for the production start and
// `api check-config -db`: a superuser (or a role that bypasses row security or can create roles or databases),
// an owner of tables (it could change a table, a trigger or a grant), a role that can read an operator table or
// case evidence, or one that can change the audit log. An empty result is a role of the right shape. It does
// not say that the grants are complete: GrantProblems does.
func (s *Store) RoleProblems(ctx context.Context) ([]string, error) {
	var user string
	var super, createRole, createDB, bypass, owns bool
	if err := s.Pool.QueryRow(ctx, `SELECT current_user::text,r.rolsuper,r.rolcreaterole,r.rolcreatedb,r.rolbypassrls,
 EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m') AND pg_get_userbyid(c.relowner)=current_user::text)
 FROM pg_roles r WHERE r.rolname=current_user::text`).Scan(&user, &super, &createRole, &createDB, &bypass, &owns); err != nil {
		return nil, err
	}
	var problems []string
	if super {
		problems = append(problems, fmt.Sprintf("the database role %q is a superuser", user))
	}
	if createRole || createDB || bypass {
		problems = append(problems, fmt.Sprintf("the database role %q can create roles or databases or bypass row security", user))
	}
	if owns {
		problems = append(problems, fmt.Sprintf("the database role %q owns tables (it could change a table, a trigger or a grant)", user))
	}
	var readable []string
	rows, err := s.Pool.Query(ctx, `SELECT t FROM unnest($1::text[]) AS t WHERE coalesce(has_table_privilege(current_user::text, to_regclass('public.'||t), 'SELECT'),false)`, SpecialTables())
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var t string
		if err = rows.Scan(&t); err != nil {
			rows.Close()
			return nil, err
		}
		readable = append(readable, t)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if len(readable) > 0 {
		problems = append(problems, fmt.Sprintf("the database role %q can read %s", user, strings.Join(readable, ", ")))
	}
	var changeAudit bool
	if err = s.Pool.QueryRow(ctx, `SELECT coalesce(has_table_privilege(current_user::text, to_regclass('public.operator_audit'), 'UPDATE') OR has_table_privilege(current_user::text, to_regclass('public.operator_audit'), 'DELETE') OR has_table_privilege(current_user::text, to_regclass('public.operator_audit'), 'TRUNCATE'),false)`).Scan(&changeAudit); err != nil {
		return nil, err
	}
	if changeAudit {
		problems = append(problems, fmt.Sprintf("the database role %q can change or delete operator_audit", user))
	}
	return problems, nil
}

// CurrentRole is the database role this store's connections run as.
func (s *Store) CurrentRole(ctx context.Context) (string, error) {
	var role string
	err := s.Pool.QueryRow(ctx, `SELECT current_user::text`).Scan(&role)
	return role, err
}

// RoleExists says whether the cluster has a role of this name.
func (s *Store) RoleExists(ctx context.Context, role string) (bool, error) {
	var exists bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)`, role).Scan(&exists)
	return exists, err
}

// GrantsRole is the role whose grants GrantProblems checks by default; AdminRole is the console's.
const (
	GrantsRole = "hiyall_api"
	AdminRole  = "hiyall_admin"
)

// GrantSpec is one group of the privileges database/roles/grants.sql gives a role beyond the blanket grant to
// hiyall_api (every table and view it may reach, every sequence): Kind "table" or "sequence" (Objects are relation
// names), "column" (Objects are tables, Columns the columns) or "function" (Objects are signatures such as
// "held_objects_due(integer)"; the privilege is always EXECUTE).
type GrantSpec struct {
	Role    string
	Kind    string
	Privs   []string
	Objects []string
	Columns []string
}

// Tuples is the spec as one "role|kind|PRIV|object|column" line per privilege and object, the form the drift
// test compares with grants.sql.
func (g GrantSpec) Tuples() []string {
	var out []string
	cols := g.Columns
	if g.Kind != "column" {
		cols = []string{""}
	}
	privs := g.Privs
	if g.Kind == "function" {
		privs = []string{"EXECUTE"}
	}
	for _, p := range privs {
		for _, o := range g.Objects {
			for _, c := range cols {
				out = append(out, g.Role+"|"+g.Kind+"|"+p+"|"+o+"|"+c)
			}
		}
	}
	return out
}

// ExpectedGrants is the one Go source of truth for every explicit grant in database/roles/grants.sql (the ones
// that are not a loop over every table): the privileges GrantProblems checks at start, in /readyz and in the
// console's start check. TestGrantSpecsMatchGrantsScript parses grants.sql and fails when the two differ, so a
// grant added to the script is checked from then on and one removed is not demanded any more (round-4 audit N1: only
// two functions were checked, so a missing EXECUTE on any other surfaced as a 500 on first use).
var ExpectedGrants = []GrantSpec{
	// hiyall_api
	{Role: GrantsRole, Kind: "table", Privs: []string{"SELECT"}, Objects: []string{"schema_migrations"}},
	{Role: GrantsRole, Kind: "column", Privs: []string{"INSERT"}, Objects: []string{"content_cases"}, Columns: []string{"case_id", "media_id", "user_id", "purpose", "result", "scanner", "signals",
		"original_sha256", "original_bytes", "content_type", "original_key", "full_key", "suspended_user", "hold_until"}},
	{Role: GrantsRole, Kind: "column", Privs: []string{"SELECT"}, Objects: []string{"content_cases"}, Columns: []string{"media_id"}},
	{Role: GrantsRole, Kind: "function", Objects: []string{"held_objects_due(integer)", "mark_hold_purged(uuid)",
		"activate_quarantine_case(uuid)", "hold_still_releasable(uuid)", "safety_queue_stats()", "hold_lock_for_purge(uuid)"}},
	// hiyall_admin
	{Role: AdminRole, Kind: "table", Privs: []string{"SELECT"}, Objects: []string{"users", "profiles", "member_ages", "reports", "moderation_actions", "chat_blobs",
		"sessions", "auth_identities", "posts", "post_media", "comments", "stories", "media_assets", "spaces", "space_entries", "content_cases",
		"operators", "operator_sessions", "operator_login_attempts", "operator_audit", "evidence_approvals"}},
	{Role: AdminRole, Kind: "table", Privs: []string{"UPDATE"}, Objects: []string{"users", "reports", "sessions", "operator_sessions", "operator_login_attempts"}},
	{Role: AdminRole, Kind: "column", Privs: []string{"UPDATE"}, Objects: []string{"operators"}, Columns: []string{"password_hash", "totp_secret", "totp_last_step", "last_login_at"}},
	{Role: AdminRole, Kind: "table", Privs: []string{"INSERT"}, Objects: []string{"moderation_actions", "operator_sessions", "operator_login_attempts", "operator_audit"}},
	{Role: AdminRole, Kind: "column", Privs: []string{"SELECT"}, Objects: []string{"apple_revocations"}, Columns: []string{"revocation_id", "issuer", "subject", "user_id", "status", "reason", "created_at"}},
	{Role: AdminRole, Kind: "table", Privs: []string{"SELECT", "INSERT", "UPDATE", "DELETE"}, Objects: []string{"evidence_orphan_report"}},
	{Role: AdminRole, Kind: "table", Privs: []string{"DELETE"}, Objects: []string{"operator_sessions", "operator_login_attempts"}},
	{Role: AdminRole, Kind: "sequence", Privs: []string{"USAGE", "SELECT"}, Objects: []string{"operator_login_attempts_attempt_id_seq", "operator_audit_audit_id_seq"}},
	{Role: AdminRole, Kind: "function", Objects: []string{"held_objects_due(integer)", "mark_hold_purged(uuid)", "prune_operator_audit(uuid, text, text, integer)",
		"evidence_propose(uuid, uuid, text, uuid, text, text)", "operator_promotion_propose(uuid, uuid, uuid, text)", "evidence_decide(uuid, uuid, text, text)",
		"evidence_expire_due()", "content_case_confirm(uuid, uuid, text)", "content_case_report(uuid, uuid, text, text)", "operator_set_role(uuid, text, uuid)",
		"pending_cases_due(integer)", "drop_pending_case(uuid, text)", "admin_schedule_deletion(uuid, text, text, text, text)",
		"activate_quarantine_case(uuid)", "hold_still_releasable(uuid)", "safety_queue_stats()", "hold_lock_for_purge(uuid)",
		"operator_create(uuid, text, text, text, text, bytea, uuid, text)", "operator_set_disabled(uuid, boolean, uuid, text, text, boolean)",
		"apple_revocation_acknowledge(uuid, uuid, text)", "apple_revocations_prune(integer)"}},
}

// grantSpecsFor are the explicit grants of role (the API's for any role that is not the console's).
func grantSpecsFor(role string) []GrantSpec {
	want := GrantsRole
	if role == AdminRole {
		want = AdminRole
	}
	var out []GrantSpec
	for _, g := range ExpectedGrants {
		if g.Role == want {
			out = append(out, g)
		}
	}
	return out
}

// missingGrants returns "PRIV on object" for every privilege of specs that role lacks (or whose object does not
// exist), sorted.
func (s *Store) missingGrants(ctx context.Context, role string, specs []GrantSpec) ([]string, error) {
	var kinds, privs, objs, cols []string
	for _, g := range specs {
		for _, t := range g.Tuples() {
			f := strings.SplitN(t, "|", 5)
			kinds, privs, objs, cols = append(kinds, f[1]), append(privs, f[2]), append(objs, f[3]), append(cols, f[4])
		}
	}
	if len(kinds) == 0 {
		return nil, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT g.priv, g.obj, g.col FROM unnest($2::text[],$3::text[],$4::text[],$5::text[]) AS g(kind,priv,obj,col)
 WHERE NOT coalesce(CASE g.kind
   WHEN 'table' THEN has_table_privilege($1, to_regclass('public.'||g.obj), g.priv)
   WHEN 'sequence' THEN has_sequence_privilege($1, to_regclass('public.'||g.obj), g.priv)
   WHEN 'function' THEN has_function_privilege($1, to_regprocedure('public.'||g.obj), 'EXECUTE')
   WHEN 'column' THEN CASE WHEN EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=to_regclass('public.'||g.obj) AND a.attname=g.col AND NOT a.attisdropped)
     THEN has_column_privilege($1, to_regclass('public.'||g.obj), g.col, g.priv) END
   END, false)`, role, kinds, privs, objs, cols)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var priv, obj, col string
		if err = rows.Scan(&priv, &obj, &col); err != nil {
			return nil, err
		}
		if col != "" {
			obj += "." + col
		}
		out = append(out, priv+" on "+obj)
	}
	sort.Strings(out)
	return out, rows.Err()
}

// GrantProblems compares what role may do with what database/roles/grants.sql gives it. For hiyall_api (the
// default when role is empty, and for any role that is not hiyall_admin): SELECT on every table and view of the
// public schema except the operator tables, content_cases and evidence_approvals, INSERT, UPDATE and DELETE on
// every table, USAGE on every sequence except the operator ones, and every explicit grant of ExpectedGrants
// (INSERT and one column of content_cases, EXECUTE on each function it may call). For hiyall_admin: the explicit
// grants only (the tables it reads and writes, the sequences, and EXECUTE on each definer function). A table a
// migration added that grants.sql has not yet been run for shows up here (the API would answer 500 for it), and
// so does a function a migration added whose grant is missing (the call would fail with "permission denied").
// For the API role it also reports what the role has that it must not (any operator table, content_cases as a
// whole).
func (s *Store) GrantProblems(ctx context.Context, role string) ([]string, error) {
	if role == "" {
		role = GrantsRole
	}
	var exists bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)`, role).Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		return []string{fmt.Sprintf("the database role %s does not exist (run database/roles/roles.sql once)", role)}, nil
	}
	var problems []string
	add := func(what string, names []string) {
		if len(names) > 0 {
			sort.Strings(names)
			problems = append(problems, fmt.Sprintf("%s %s: %s", role, what, strings.Join(names, ", ")))
		}
	}
	if role != AdminRole {
		rows, err := s.Pool.Query(ctx, `SELECT c.relname::text,c.relkind::text,has_table_privilege($1,c.oid,'SELECT'),has_table_privilege($1,c.oid,'INSERT'),
 has_table_privilege($1,c.oid,'UPDATE'),has_table_privilege($1,c.oid,'DELETE')
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m') ORDER BY c.relname`, role)
		if err != nil {
			return nil, err
		}
		var missingRead, missingWrite, forbidden []string
		for rows.Next() {
			var name, kind string
			var sel, ins, upd, del bool
			if err = rows.Scan(&name, &kind, &sel, &ins, &upd, &del); err != nil {
				rows.Close()
				return nil, err
			}
			if isSpecialTable(name) {
				// Operator tables: nothing. content_cases: no read, change or delete (what INSERT it has is judged by
				// ExpectedGrants below).
				if (name == CaseTable && (sel || upd || del)) || (name != CaseTable && (sel || ins || upd || del)) {
					forbidden = append(forbidden, name)
				}
				continue
			}
			if !sel {
				missingRead = append(missingRead, name)
			}
			if (kind == "r" || kind == "p") && name != "schema_migrations" && !(ins && upd && del) {
				missingWrite = append(missingWrite, name)
			}
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return nil, err
		}
		add("has no SELECT on", missingRead)
		add("lacks INSERT, UPDATE or DELETE on", missingWrite)
		add("has access it must not have to", forbidden)
		var seqMissing []string
		seqRows, err := s.Pool.Query(ctx, `SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'
 AND c.relname<>ALL($2::text[]) AND NOT coalesce(CASE WHEN c.relkind='S' THEN has_sequence_privilege($1,c.oid,'USAGE') END,false) ORDER BY c.relname`, role, OperatorSequences)
		if err != nil {
			return nil, err
		}
		for seqRows.Next() {
			var n string
			if err = seqRows.Scan(&n); err != nil {
				seqRows.Close()
				return nil, err
			}
			seqMissing = append(seqMissing, n)
		}
		seqRows.Close()
		if err = seqRows.Err(); err != nil {
			return nil, err
		}
		add("has no USAGE on sequence", seqMissing)
	}
	missing, err := s.missingGrants(ctx, role, grantSpecsFor(role))
	if err != nil {
		return nil, err
	}
	var execs, others []string
	for _, m := range missing {
		if strings.HasPrefix(m, "EXECUTE on ") {
			execs = append(execs, strings.TrimPrefix(m, "EXECUTE on "))
		} else {
			others = append(others, m)
		}
	}
	add("lacks EXECUTE on function", execs)
	add("lacks the privilege", others)
	return problems, nil
}
