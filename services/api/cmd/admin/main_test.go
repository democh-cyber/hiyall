package main

import (
	"bytes"
	"context"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/admin"
	"hiyall/services/api/internal/store"
)

func testEnv(t *testing.T) (func(string) string, *store.Store, context.Context) {
	t.Helper()
	dsn := os.Getenv("ADMIN_TEST_DATABASE_URL")
	if dsn == "" {
		// Same rule as internal/admin: TEST_DATABASE_URL with the database name swapped.
		u, err := url.Parse(os.Getenv("TEST_DATABASE_URL"))
		if err != nil || strings.TrimPrefix(u.Path, "/") != "hiyall_test" {
			t.Skip("ADMIN_TEST_DATABASE_URL (a database named hiyall_test_admin) required for PostgreSQL integration")
		}
		u.Path = "/hiyall_test_admin"
		dsn = u.String()
	}
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		if os.Getenv("ADMIN_TEST_DATABASE_URL") == "" {
			t.Skipf("no hiyall_test_admin database next to TEST_DATABASE_URL: %v", err)
		}
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	var name string
	if err = db.Pool.QueryRow(ctx, `SELECT current_database()`).Scan(&name); err != nil || name != "hiyall_test_admin" {
		t.Fatalf("needs the hiyall_test_admin database, not %q", name)
	}
	vars := map[string]string{"APP_ENV": "development", "DATABASE_URL": dsn, "ADMIN_DATA_KEY": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))}
	return func(k string) string { return vars[k] }, db, ctx
}

func TestOperatorAddPrintsEnrolmentOnceAndTheOperatorCanSignIn(t *testing.T) {
	getenv, db, ctx := testEnv(t)
	email := "cli-" + strings.ReplaceAll(time.Now().Format("150405.000000"), ".", "") + "@hiyall.test"
	password := "a long CLI test password"
	var out, errOut bytes.Buffer
	if err := run(ctx, []string{"operator-add", "-email", email, "-role", "viewer", "-name", "CLI Test"}, getenv, strings.NewReader(password+"\n"), &out, &errOut); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	if strings.Contains(text, password) || strings.Contains(errOut.String(), password) {
		t.Fatal("the password was printed")
	}
	uri := regexp.MustCompile(`otpauth://totp/\S+`).FindString(text)
	secretText := regexp.MustCompile(`Secret: (\S+)`).FindStringSubmatch(text)
	if uri == "" || secretText == nil || !strings.Contains(uri, "secret="+secretText[1]) {
		t.Fatal(text)
	}
	seed, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secretText[1])
	if err != nil || len(seed) != 20 {
		t.Fatal(err, len(seed))
	}
	// Stored sealed and hashed: neither the seed nor the password is in the table.
	var hash string
	var sealed []byte
	if err = db.Pool.QueryRow(ctx, `SELECT password_hash,totp_secret FROM operators WHERE email=$1`, email).Scan(&hash, &sealed); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(hash, "$argon2id$") || strings.Contains(hash, password) || bytes.Contains(sealed, seed) {
		t.Fatal("credentials stored in the clear")
	}
	// The printed secret really enrols: the operator signs in with it.
	cfg, _ := admin.LoadConfig(getenv)
	svc, err := admin.NewService(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = svc.Login(ctx, email, password, admin.TOTPCode(seed, admin.TOTPStep(time.Now())), "198.51.100.9"); err != nil {
		t.Fatal(err)
	}
	// The audit log records who created the account.
	var n int
	db.Pool.QueryRow(ctx, `SELECT count(*) FROM operator_audit WHERE action='operator_create' AND actor LIKE 'cli:%' AND detail->>'email'=$1`, email).Scan(&n)
	if n != 1 {
		t.Fatal("creation not audited")
	}
	// A second add of the same address, a bad role, a weak password and missing flags are all refused.
	for name, args := range map[string][]string{"duplicate": {"operator-add", "-email", email, "-role", "viewer"}} {
		if err := run(ctx, args, getenv, strings.NewReader(password+"\n"), &out, &errOut); err == nil {
			t.Fatal(name)
		}
	}
	var usage usageError
	if err := run(ctx, []string{"operator-add", "-email", email, "-role", "root"}, getenv, strings.NewReader(password+"\n"), &out, &errOut); !errors.As(err, &usage) {
		t.Fatalf("bad role: %v", err)
	}
	if err := run(ctx, []string{"operator-add", "-email", email}, getenv, strings.NewReader(password), &out, &errOut); !errors.As(err, &usage) {
		t.Fatal("missing role")
	}
	if err := run(ctx, []string{"operator-add", "-email", "weak-" + email, "-role", "viewer"}, getenv, strings.NewReader("short\n"), &out, &errOut); err == nil {
		t.Fatal("weak password accepted")
	}
	if err := run(ctx, []string{"operator-add", "-email", "empty-" + email, "-role", "viewer"}, getenv, strings.NewReader(""), &out, &errOut); err == nil {
		t.Fatal("no password accepted")
	}
	if err := run(ctx, []string{"frobnicate"}, getenv, strings.NewReader(""), &out, &errOut); !errors.As(err, &usage) {
		t.Fatal("unknown command")
	}

	// Reset gives a new password and authenticator, and ends sessions; disable shuts the account out.
	var reset bytes.Buffer
	if err := run(ctx, []string{"operator-reset", "-email", email}, getenv, strings.NewReader("another long password!\n"), &reset, &errOut); err != nil {
		t.Fatal(err)
	}
	if reset.String() == text || !strings.Contains(reset.String(), "Reset") {
		t.Fatal("reset output")
	}
	if err := run(ctx, []string{"operator-disable", "-email", email, "-reason", "short"}, getenv, strings.NewReader(""), &out, &errOut); err == nil {
		t.Fatal("a disable needs a real reason")
	}
	if err := run(ctx, []string{"operator-disable", "-email", email, "-reason", "left the company last week"}, getenv, strings.NewReader(""), &out, &errOut); err != nil {
		t.Fatal(err)
	}
	var disabled bool
	db.Pool.QueryRow(ctx, `SELECT disabled_at IS NOT NULL FROM operators WHERE email=$1`, email).Scan(&disabled)
	if !disabled {
		t.Fatal("not disabled")
	}
}

func TestServeRefusesToStartOnANonLoopbackAddress(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	for name, vars := range map[string]map[string]string{
		"all interfaces":     {"ADMIN_ADDR": ":8081"},
		"lan address":        {"ADMIN_ADDR": "10.0.0.5:8081"},
		"remote without TLS": {"ADMIN_ADDR": "0.0.0.0:8081", "ADMIN_ALLOW_REMOTE": "true", "ADMIN_ALLOWED_HOSTS": "a.test"},
	} {
		vars["APP_ENV"], vars["DATABASE_URL"], vars["ADMIN_DATA_KEY"] = "development", "postgres://nobody@127.0.0.1:1/none", key
		err := run(context.Background(), []string{"serve"}, func(k string) string { return vars[k] }, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "ADMIN_") {
			t.Fatalf("%s: %v", name, err)
		}
	}
}

// Round-3 audit API-1: support can delete an account that cannot get an Apple code, from a terminal, audited.
func TestScheduleDeletionCommandSchedulesAuditsAndQueuesTheAppleRevocation(t *testing.T) {
	getenv, db, ctx := testEnv(t)
	id := uuid.NewString()
	subject := "apple-" + id
	for _, q := range []string{
		`INSERT INTO users(user_id) VALUES('` + id + `')`,
		`INSERT INTO auth_identities(issuer,subject,user_id,sign_in_provider,apple_linked) VALUES('https://securetoken.google.com/test','` + subject + `','` + id + `','apple.com',true)`,
	} {
		if _, err := db.Pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	var out, errOut bytes.Buffer
	for _, bad := range [][]string{{"schedule-deletion"}, {"schedule-deletion", "-user", id}, {"schedule-deletion", "-reason", "support ticket 4411"}} {
		if err := run(ctx, bad, getenv, strings.NewReader(""), &out, &errOut); err == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
	if err := run(ctx, []string{"schedule-deletion", "-user", "not-an-id", "-reason", "support ticket 4411"}, getenv, strings.NewReader(""), &out, &errOut); err == nil {
		t.Fatal("accepted a bad id")
	}
	if err := run(ctx, []string{"schedule-deletion", "-user", id, "-reason", "short"}, getenv, strings.NewReader(""), &out, &errOut); err == nil {
		t.Fatal("accepted a short reason")
	}
	if err := run(ctx, []string{"schedule-deletion", "-user", uuid.NewString(), "-reason", "support ticket 4411"}, getenv, strings.NewReader(""), &out, &errOut); err == nil {
		t.Fatal("scheduled an unknown member")
	}
	out.Reset()
	if err := run(ctx, []string{"schedule-deletion", "-user", id, "-reason", "support ticket 4411: member cannot sign in with Apple"}, getenv, strings.NewReader(""), &out, &errOut); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Deletion scheduled") || !strings.Contains(out.String(), "Apple") {
		t.Fatalf("output: %s", out.String())
	}
	var status string
	var due *time.Time
	if err := db.Pool.QueryRow(ctx, `SELECT status,deletion_due_at FROM users WHERE user_id=$1`, id).Scan(&status, &due); err != nil || status != "pending_deletion" || due == nil || time.Until(*due) < 29*24*time.Hour {
		t.Fatalf("status %s due %v %v", status, due, err)
	}
	var n int
	db.Pool.QueryRow(ctx, `SELECT count(*) FROM apple_revocations WHERE subject=$1 AND status='manual' AND token_sealed IS NULL AND user_id=$2`, subject, id).Scan(&n)
	if n != 1 {
		t.Fatal("no manual Apple revocation queued")
	}
	var actor, reason string
	if err := db.Pool.QueryRow(ctx, `SELECT actor,reason FROM operator_audit WHERE action='account_deletion_scheduled' AND target_id=$1`, id).Scan(&actor, &reason); err != nil || !strings.HasPrefix(actor, "cli:") || !strings.Contains(reason, "ticket 4411") {
		t.Fatalf("audit %q %q %v", actor, reason, err)
	}
	// Again: the first due date stands and nothing is duplicated.
	if err := run(ctx, []string{"schedule-deletion", "-user", id, "-reason", "support ticket 4411 again"}, getenv, strings.NewReader(""), &out, &errOut); err != nil {
		t.Fatal(err)
	}
	db.Pool.QueryRow(ctx, `SELECT count(*) FROM apple_revocations WHERE user_id=$1`, id).Scan(&n)
	if n != 1 {
		t.Fatalf("%d revocation rows", n)
	}
}
