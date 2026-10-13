package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

func member(t *testing.T, ctx context.Context, db *store.Store) string {
	t.Helper()
	id := uuid.Must(uuid.NewV7()).String()
	username := "t" + strings.ReplaceAll(id, "-", "")[12:30]
	for _, q := range []string{
		`INSERT INTO users(user_id) VALUES($1)`,
		`INSERT INTO onboarding(user_id,completed_at,terms_version) VALUES($1,now(),'test')`,
		`INSERT INTO profiles(user_id,username,data) VALUES($1,'` + username + `','{"displayName":"X"}')`,
		`INSERT INTO member_ages(user_id,birth_date) VALUES($1,'1990-01-01')`,
	} {
		if _, err := db.Pool.Exec(ctx, q, id); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

// The command line still works end to end through the shared store methods the console also uses.
func TestModerateCLIQueueResolveRestore(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required for PostgreSQL integration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Pool.Close()
	var name string
	if err = db.Pool.QueryRow(ctx, `SELECT current_database()`).Scan(&name); err != nil || name != "hiyall_test_admin" {
		t.Skipf("needs the hiyall_test_admin database, not %q", name)
	}
	reporter, subject := member(t, ctx, db), member(t, ctx, db)
	rep, _, err := db.CreateReport(ctx, reporter, domain.NewReport{TargetType: "user", TargetID: subject, ReasonCode: "threats", Description: "cli test report"})
	if err != nil {
		t.Fatal(err)
	}
	run1 := func(args ...string) (string, error) {
		var out bytes.Buffer
		err := run(ctx, db, args, &out)
		return out.String(), err
	}
	out, err := run1("queue", "-limit", "500")
	if err != nil || !strings.Contains(out, rep.ReportID) || !strings.Contains(out, "[HIGH] threats") {
		t.Fatal(err, out)
	}
	for _, bad := range [][]string{{"resolve"}, {"resolve", "-report", rep.ReportID}, {"restore"}, {"nope"}, {"queue", "-limit", "x"}} {
		if _, err := run1(bad...); !errors.Is(err, errUsage) {
			t.Fatalf("%v: %v", bad, err)
		}
	}
	if out, err = run1("resolve", "-report", rep.ReportID, "-action", "suspend", "-operator", "ops@hiyall", "-note", "credible threat"); err != nil || out != "Resolved.\n" {
		t.Fatal(err, out)
	}
	var status string
	db.Pool.QueryRow(ctx, `SELECT status FROM users WHERE user_id=$1`, subject).Scan(&status)
	if status != "suspended" {
		t.Fatal(status)
	}
	if _, err = run1("resolve", "-report", rep.ReportID, "-action", "dismiss", "-operator", "ops@hiyall"); err == nil {
		t.Fatal("resolved twice")
	}
	if out, err = run1("restore", "-user", subject, "-operator", "ops@hiyall", "-note", "appeal upheld"); err != nil || out != "Restored.\n" {
		t.Fatal(err, out)
	}
	var actions int
	db.Pool.QueryRow(ctx, `SELECT count(*) FROM moderation_actions WHERE subject_id=$1`, subject).Scan(&actions)
	if actions != 2 {
		t.Fatal(actions)
	}
}
