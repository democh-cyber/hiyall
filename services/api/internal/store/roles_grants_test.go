package store

import (
	"context"
	"strings"
	"testing"

	"hiyall/services/api/internal/dbtest"
)

// GrantProblems checks EVERY explicit grant of grants.sql for hiyall_api and hiyall_admin, not two functions
// (round-4 audit N1). On a database of its own (privileges are per database) each privilege is taken away from
// its role in turn: exactly that one is reported, then it is given back and the role is complete again.
func TestGrantProblemsSeesEveryMissingExplicitGrant(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	dbtest.ApplyRoles(t, ctx, s.Pool)
	for _, role := range []string{GrantsRole, AdminRole} {
		if p, err := s.GrantProblems(ctx, role); err != nil || len(p) != 0 {
			t.Fatalf("%s should be complete after grants.sql: %v %v", role, p, err)
		}
	}
	checked := map[string]int{}
	for _, g := range ExpectedGrants {
		for _, tuple := range g.Tuples() {
			f := strings.SplitN(tuple, "|", 5)
			kind, priv, obj, col := f[1], f[2], f[3], f[4]
			var take, give, wantWord string
			switch kind {
			case "function":
				take, give, wantWord = `REVOKE EXECUTE ON FUNCTION `+obj+` FROM `+g.Role, `GRANT EXECUTE ON FUNCTION `+obj+` TO `+g.Role, "EXECUTE on function: "+obj
			case "table":
				take, give, wantWord = `REVOKE `+priv+` ON `+obj+` FROM `+g.Role, `GRANT `+priv+` ON `+obj+` TO `+g.Role, priv+" on "+obj
			case "column":
				take, give, wantWord = `REVOKE `+priv+` (`+col+`) ON `+obj+` FROM `+g.Role, `GRANT `+priv+` (`+col+`) ON `+obj+` TO `+g.Role, priv+" on "+obj+"."+col
			case "sequence":
				take, give, wantWord = `REVOKE `+priv+` ON SEQUENCE `+obj+` FROM `+g.Role, `GRANT `+priv+` ON SEQUENCE `+obj+` TO `+g.Role, priv+" on "+obj
			}
			mustExec(t, s, take)
			p, err := s.GrantProblems(ctx, g.Role)
			mustExec(t, s, give)
			if err != nil {
				t.Fatal(err)
			}
			all := strings.Join(p, " | ")
			if len(p) == 0 {
				t.Errorf("revoking %s from %s was not reported", wantWord, g.Role)
				continue
			}
			if !strings.Contains(all, wantWord) {
				t.Errorf("revoking %s from %s: the report does not name it: %s", wantWord, g.Role, all)
			}
			checked[g.Role+"/"+kind]++
		}
	}
	for _, role := range []string{GrantsRole, AdminRole} {
		if p, err := s.GrantProblems(ctx, role); err != nil || len(p) != 0 {
			t.Fatalf("%s is not complete after the grants were given back: %v %v", role, p, err)
		}
	}
	for _, key := range []string{"hiyall_api/function", "hiyall_admin/function", "hiyall_admin/table", "hiyall_admin/column", "hiyall_admin/sequence", "hiyall_api/column"} {
		if checked[key] == 0 {
			t.Errorf("no %s grant was exercised: ExpectedGrants changed shape", key)
		}
	}
	t.Logf("exercised %v", checked)
}

// A role that is missing one function names it, in the form an operator can act on.
func TestGrantProblemsNamesTheMissingFunction(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	dbtest.ApplyRoles(t, ctx, s.Pool)
	mustExec(t, s, `REVOKE EXECUTE ON FUNCTION safety_queue_stats() FROM hiyall_api`)
	p, err := s.GrantProblems(ctx, "")
	if err != nil || len(p) != 1 || !strings.Contains(p[0], "hiyall_api lacks EXECUTE on function: safety_queue_stats()") {
		t.Fatalf("got %v %v", p, err)
	}
	mustExec(t, s, `REVOKE EXECUTE ON FUNCTION evidence_decide(uuid, uuid, text, text), operator_set_role(uuid, text, uuid) FROM hiyall_admin`)
	p, err = s.GrantProblems(ctx, AdminRole)
	if err != nil || len(p) != 1 || !strings.Contains(p[0], "evidence_decide(uuid, uuid, text, text)") || !strings.Contains(p[0], "operator_set_role(uuid, text, uuid)") {
		t.Fatalf("got %v %v", p, err)
	}
}
