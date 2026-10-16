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

// GrantsRole is the role whose grants GrantProblems checks by default.
const GrantsRole = "hiyall_api"

// GrantProblems compares what role (hiyall_api when empty) may do with what database/roles/grants.sql gives it:
// SELECT on every table and view of the public schema except the operator tables and content_cases, INSERT,
// UPDATE and DELETE on every table, USAGE on every sequence except the two operator ones, the one column of
// content_cases the tombstone purge reads, INSERT into it, and EXECUTE on the two hold functions. A table a
// migration added that grants.sql has not yet been run for shows up here (the API would answer 500 for it).
// It also reports what the role has that it must not (any operator table, content_cases as a whole).
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
			// Operator tables: nothing. content_cases: INSERT only (plus the one column, checked below).
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
	var problems []string
	add := func(what string, names []string) {
		if len(names) > 0 {
			sort.Strings(names)
			problems = append(problems, fmt.Sprintf("%s %s: %s", role, what, strings.Join(names, ", ")))
		}
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
	var column, insertCase, execs bool
	if err = s.Pool.QueryRow(ctx, `SELECT coalesce(has_column_privilege($1,'public.content_cases','media_id','SELECT'),false),
 coalesce(has_table_privilege($1,'public.content_cases','INSERT'),false),
 coalesce(has_function_privilege($1,'public.held_objects_due(integer)','EXECUTE') AND has_function_privilege($1,'public.mark_hold_purged(uuid)','EXECUTE'),false)`, role).Scan(&column, &insertCase, &execs); err != nil {
		return nil, err
	}
	if !column {
		problems = append(problems, role+" cannot read content_cases.media_id (the media tombstone purge fails)")
	}
	if !insertCase {
		problems = append(problems, role+" cannot insert into content_cases (the upload scanner cannot open a case)")
	}
	if !execs {
		problems = append(problems, role+" cannot execute held_objects_due or mark_hold_purged (released holds are never cleaned up)")
	}
	return problems, nil
}
