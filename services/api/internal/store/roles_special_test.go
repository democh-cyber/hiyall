package store

import (
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"

	"hiyall/services/api/internal/dbtest"
)

// The tables database/roles/grants.sql keeps from the API role are listed in the script (the blanket grant skips
// them, the closing assertion checks them) and in this package (roles.go: what RoleProblems and GrantProblems
// check). Two lists of one fact drift, so this parses the script and compares (round-3 audit DB-NEW-9).
func TestSpecialTablesMatchGrantsScript(t *testing.T) {
	script := dbtest.Script(t, "grants.sql")
	names := func(list string) []string {
		var out []string
		for _, part := range strings.Split(list, ",") {
			part = strings.Trim(strings.TrimSpace(part), "'\"")
			if part != "" {
				out = append(out, part)
			}
		}
		sort.Strings(out)
		return out
	}
	want := SpecialTables()
	sort.Strings(want)

	// "relname NOT IN (...)" appears twice: the blanket grant (also leaves out the migration bookkeeping table) and
	// the assertion that every other table is readable.
	notIn := regexp.MustCompile(`relname NOT IN \(([^)]*)\)`).FindAllStringSubmatch(script, -1)
	if len(notIn) != 2 {
		t.Fatalf("grants.sql has %d `relname NOT IN (...)` lists, want 2 (the grant loop and the assertion): update this test with the script", len(notIn))
	}
	grantLoop, assertion := names(notIn[0][1]), names(notIn[1][1])
	if without := slices.DeleteFunc(slices.Clone(grantLoop), func(s string) bool { return s == "schema_migrations" }); !slices.Equal(without, want) {
		t.Errorf("grants.sql grant loop skips %v, store.SpecialTables() is %v", without, want)
	}
	if !slices.Equal(assertion, want) {
		t.Errorf("grants.sql assertion skips %v, store.SpecialTables() is %v", assertion, want)
	}

	// The tables the closing assertion demands hiyall_api cannot SELECT.
	cannot := map[string]bool{}
	for _, m := range regexp.MustCompile(`has_table_privilege\('hiyall_api', '(\w+)', 'SELECT'\)`).FindAllStringSubmatch(script, -1) {
		cannot[m[1]] = true
	}
	var got []string
	for name := range cannot {
		got = append(got, name)
	}
	sort.Strings(got)
	if !slices.Equal(got, want) {
		t.Errorf("grants.sql asserts hiyall_api cannot read %v, store.SpecialTables() is %v", got, want)
	}

	// Sequences of operator tables.
	seq := regexp.MustCompile(`REVOKE ALL ON SEQUENCE ([^;]*?) FROM hiyall_api`).FindStringSubmatch(script)
	if seq == nil {
		t.Fatal("grants.sql no longer revokes the operator sequences from hiyall_api")
	}
	wantSeq := slices.Clone(OperatorSequences)
	sort.Strings(wantSeq)
	if got := names(seq[1]); !slices.Equal(got, wantSeq) {
		t.Errorf("grants.sql revokes sequences %v, store.OperatorSequences is %v", got, wantSeq)
	}
}
