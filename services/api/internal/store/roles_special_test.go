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

// splitTop splits s at commas that are not inside parentheses.
func splitTop(s string) []string {
	var out []string
	depth, start := 0, 0
	for i, c := range s {
		switch c {
		case '(':
			depth++
		case ')':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, strings.TrimSpace(s[start:i]))
				start = i + 1
			}
		}
	}
	return append(out, strings.TrimSpace(s[start:]))
}

// grantTuples parses every explicit GRANT of the script for the two roles into the "role|kind|PRIV|object|column"
// lines of GrantSpec.Tuples. The loop that grants every table to hiyall_api (a DO block) and the blanket grant on
// all sequences are not explicit grants; ExpectedGrants does not list them.
func grantTuples(t *testing.T, script string) []string {
	t.Helper()
	script = regexp.MustCompile(`(?m)--.*$`).ReplaceAllString(script, "")
	script = regexp.MustCompile(`(?s)DO \$\$.*?\$\$;`).ReplaceAllString(script, "")
	var out []string
	for _, m := range regexp.MustCompile(`(?s)\bGRANT\s+(.+?)\s+ON\s+(.+?)\s+TO\s+(hiyall_api|hiyall_admin)\s*;`).FindAllStringSubmatch(script, -1) {
		privs, on, role := m[1], strings.Join(strings.Fields(m[2]), " "), m[3]
		if strings.HasPrefix(on, "ALL ") {
			continue
		}
		kind := "table"
		switch {
		case strings.HasPrefix(on, "FUNCTION "):
			kind, on = "function", strings.TrimPrefix(on, "FUNCTION ")
		case strings.HasPrefix(on, "SEQUENCE "):
			kind, on = "sequence", strings.TrimPrefix(on, "SEQUENCE ")
		}
		var objects []string
		for _, o := range splitTop(on) {
			// Normalise the argument list the way grants.sql writes it: "name(type, type)".
			objects = append(objects, strings.ReplaceAll(strings.ReplaceAll(o, " (", "("), ",", ", "))
		}
		for i, o := range objects {
			objects[i] = strings.Join(strings.Fields(o), " ")
		}
		var specs []GrantSpec
		for _, p := range splitTop(privs) {
			if kind == "function" {
				specs = append(specs, GrantSpec{Role: role, Kind: kind, Objects: objects})
				break
			}
			if i := strings.Index(p, "("); i > 0 { // SELECT (a, b)
				cols := splitTop(strings.TrimSuffix(p[i+1:], ")"))
				specs = append(specs, GrantSpec{Role: role, Kind: "column", Privs: []string{strings.TrimSpace(p[:i])}, Objects: objects, Columns: cols})
				continue
			}
			specs = append(specs, GrantSpec{Role: role, Kind: kind, Privs: []string{p}, Objects: objects})
		}
		for _, g := range specs {
			out = append(out, g.Tuples()...)
		}
	}
	sort.Strings(out)
	return slices.Compact(out)
}

// Every explicit grant of grants.sql is checked by GrantProblems, and nothing is demanded that the script does not
// grant (round-4 audit N1). Both lists are compared as sets of one privilege on one object each.
func TestGrantSpecsMatchGrantsScript(t *testing.T) {
	want := grantTuples(t, dbtest.Script(t, "grants.sql"))
	var have []string
	for _, g := range ExpectedGrants {
		have = append(have, g.Tuples()...)
	}
	sort.Strings(have)
	have = slices.Compact(have)
	if len(want) < 40 {
		t.Fatalf("the parser found only %d grants in grants.sql: update it with the script", len(want))
	}
	for _, w := range want {
		if !slices.Contains(have, w) {
			t.Errorf("grants.sql grants %s but store.ExpectedGrants does not list it: GrantProblems would not notice it missing", w)
		}
	}
	for _, h := range have {
		if !slices.Contains(want, h) {
			t.Errorf("store.ExpectedGrants lists %s but grants.sql does not grant it: GrantProblems would refuse a correct database", h)
		}
	}
}
