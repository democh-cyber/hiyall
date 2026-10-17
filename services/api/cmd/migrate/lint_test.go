package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Locking-index lint (round-4 audit N7). A migration runs in one transaction on every deploy. CREATE INDEX and DROP
// INDEX on a table that holds real data take a lock that blocks its writes for as long as the build takes, which on a
// table of millions of rows is minutes of a dead chat or feed on the day it matters. From migration 0045 on, an index
// created or dropped on one of the large tables must be CONCURRENTLY, in a file whose first line is
// "-- hiyall:no-transaction" (so it runs outside a transaction). A file that really means to lock (a table that is
// still empty, a window with the API stopped) says so with a line "-- hiyall:allow-locking-index" and a reason, which a
// reviewer then reads. Migrations before 0045 are applied and checksummed and are not judged.

// largeTables are the tables that grow with the number of members or their activity.
var largeTables = []string{"messages", "message_envelopes", "media_assets", "follows", "notifications", "chat_blobs", "posts", "comments"}

const (
	lintFirstMigration = 45
	allowLockingMarker = "-- hiyall:allow-locking-index"
)

var (
	createIndexRe = regexp.MustCompile(`(?is)\bCREATE\s+(?:UNIQUE\s+)?INDEX\s+(CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?("?\w+"?)\s+ON\s+(?:ONLY\s+)?(?:public\.)?"?(\w+)"?`)
	dropIndexRe   = regexp.MustCompile(`(?is)\bDROP\s+INDEX\s+(CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?((?:public\.)?"?\w+"?(?:\s*,\s*(?:public\.)?"?\w+"?)*)`)
	lineComment   = regexp.MustCompile(`--[^\n]*`)
)

func stripComments(sql string) string { return lineComment.ReplaceAllString(sql, "") }

func cleanName(n string) string {
	return strings.ToLower(strings.Trim(strings.TrimPrefix(strings.TrimSpace(n), "public."), `"`))
}

// indexTables maps every index a migration creates to its table.
func indexTables(files map[string]string) map[string]string {
	out := map[string]string{}
	for _, sql := range files {
		for _, m := range createIndexRe.FindAllStringSubmatch(stripComments(sql), -1) {
			out[cleanName(m[2])] = cleanName(m[3])
		}
	}
	return out
}

// lintMigration returns what is wrong with one migration's indexes on large tables ("" files are fine).
func lintMigration(text string, tableOf map[string]string) []string {
	if strings.Contains(text, allowLockingMarker) {
		return nil
	}
	first, _, _ := strings.Cut(text, "\n")
	outsideTx := strings.TrimSpace(first) == NoTransactionMarker
	body := stripComments(text)
	large := func(table string) bool {
		for _, l := range largeTables {
			if l == table {
				return true
			}
		}
		return false
	}
	var problems []string
	judge := func(verb, name, table string, concurrently bool) {
		switch {
		case !concurrently:
			problems = append(problems, verb+" INDEX "+name+" on the large table "+table+" locks it for the whole build: use CONCURRENTLY in a file that starts with "+NoTransactionMarker+", or add "+allowLockingMarker+" with the reason it is safe")
		case !outsideTx:
			problems = append(problems, verb+" INDEX CONCURRENTLY "+name+" on "+table+" cannot run inside the migration's transaction: the first line of the file must be "+NoTransactionMarker)
		}
	}
	for _, m := range createIndexRe.FindAllStringSubmatch(body, -1) {
		if table := cleanName(m[3]); large(table) {
			judge("CREATE", cleanName(m[2]), table, m[1] != "")
		}
	}
	for _, m := range dropIndexRe.FindAllStringSubmatch(body, -1) {
		for _, name := range strings.Split(m[2], ",") {
			name = cleanName(name)
			table, known := tableOf[name]
			switch {
			case !known:
				problems = append(problems, "DROP INDEX "+name+": the table of this index is not created by any migration, so the lint cannot tell whether it is large; add "+allowLockingMarker+" if it is not")
			case large(table):
				judge("DROP", name, table, m[1] != "")
			}
		}
	}
	return problems
}

func TestLintMigrationRules(t *testing.T) {
	tableOf := map[string]string{"messages_age": "messages", "sessions_x": "sessions"}
	cases := []struct {
		name string
		sql  string
		want int
	}{
		{"locking create on a large table", "CREATE INDEX m_x ON messages (created_at);", 1},
		{"unique, schema-qualified, quoted", `CREATE UNIQUE INDEX "f_x" ON public."follows" (a, b);`, 1},
		{"concurrently but inside the transaction", "CREATE INDEX CONCURRENTLY m_x ON messages (created_at);", 1},
		{"concurrently outside the transaction", "-- hiyall:no-transaction\nCREATE INDEX CONCURRENTLY IF NOT EXISTS m_x ON messages (created_at);", 0},
		{"a marker that is not the first line does not count", "-- note\n-- hiyall:no-transaction\nCREATE INDEX CONCURRENTLY m_x ON messages (created_at);", 1},
		{"a small table", "CREATE INDEX s_x ON sessions (revoked_at);", 0},
		{"allowed with a reason", "-- hiyall:allow-locking-index: the table is empty until launch\nCREATE INDEX m_x ON messages (created_at);", 0},
		{"drop of an index of a large table", "DROP INDEX messages_age;", 1},
		{"drop concurrently outside the transaction", "-- hiyall:no-transaction\nDROP INDEX CONCURRENTLY IF EXISTS messages_age;", 0},
		{"drop of an index of a small table", "DROP INDEX sessions_x;", 0},
		{"drop of an unknown index", "DROP INDEX nobody_knows;", 1},
		{"a comment is not a statement", "-- CREATE INDEX m_x ON messages (created_at);\nSELECT 1;", 0},
		{"two statements, one bad", "CREATE INDEX s_x ON sessions (a);\nCREATE INDEX n_x ON notifications (a);", 1},
	}
	for _, c := range cases {
		if got := lintMigration(c.sql, tableOf); len(got) != c.want {
			t.Errorf("%s: %d problems %v, want %d", c.name, len(got), got, c.want)
		}
	}
}

// No migration from 0045 on creates or drops an index on a large table in a way that locks it.
func TestNewMigrationsDoNotLockLargeTables(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "..", "database", "migrations")
	paths, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no migrations in %s: %v", dir, err)
	}
	sort.Strings(paths)
	files := map[string]string{}
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		files[filepath.Base(p)] = string(raw)
	}
	tableOf := indexTables(files)
	if tableOf["messages_age_key"] != "messages" {
		t.Fatalf("the index map is wrong: %v", tableOf["messages_age_key"])
	}
	judged := 0
	for name, text := range files {
		n, err := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if err != nil || n < lintFirstMigration {
			continue
		}
		judged++
		for _, p := range lintMigration(text, tableOf) {
			t.Errorf("%s: %s", name, p)
		}
	}
	if judged == 0 {
		t.Fatalf("no migration from %04d on was judged", lintFirstMigration)
	}
}
