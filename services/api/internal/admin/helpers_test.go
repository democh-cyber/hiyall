package admin

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

func init() {
	// Real cost is 64 MiB per hash; the suite does dozens. One pass over 64 KiB checks the same code.
	DefaultPasswordParams = PasswordParams{Time: 1, Memory: 64, Threads: 1}
}

// The integration tests need a database that is theirs alone: they create fresh members and operators
// with random names and never truncate, but the last-admin test disables every other administrator.
const testDatabase = "hiyall_test_admin"

// adminTestDSN is the connection string of the console's own test database, hiyall_test_admin:
// ADMIN_TEST_DATABASE_URL, else TEST_DATABASE_URL with its database name swapped. The integration tests create
// operators and disable administrators, so they never share a database with the API's tests (which truncate).
func adminTestDSN(t *testing.T) string {
	t.Helper()
	if dsn := os.Getenv("ADMIN_TEST_DATABASE_URL"); dsn != "" {
		return dsn
	}
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("ADMIN_TEST_DATABASE_URL (a database named hiyall_test_admin) required for PostgreSQL integration")
	}
	u, err := url.Parse(dsn)
	if err != nil || strings.TrimPrefix(u.Path, "/") != "hiyall_test" {
		t.Skip("ADMIN_TEST_DATABASE_URL (a database named hiyall_test_admin) required for PostgreSQL integration")
	}
	u.Path = "/hiyall_test_admin"
	return u.String()
}

type env struct {
	t     *testing.T
	ctx   context.Context
	db    *store.Store
	svc   *Service
	srv   *Server
	h     http.Handler
	clock time.Time
	ip    string
}

func testConfig() Config {
	key := bytes.Repeat([]byte{7}, 32)
	return Config{Env: "development", Addr: "127.0.0.1:8081", StaticDir: "/nonexistent", AllowedHosts: []string{"localhost"}, DataKey: key}
}

func newEnv(t *testing.T) *env {
	t.Helper()
	dsn := adminTestDSN(t)
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		if os.Getenv("ADMIN_TEST_DATABASE_URL") == "" {
			t.Skipf("no %s database next to TEST_DATABASE_URL: %v", testDatabase, err)
		}
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != testDatabase {
		t.Fatalf("admin integration tests need a database named %s, not %q (see docs/security/15-admin-console.md)", testDatabase, name)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	svc, err := NewService(db, testConfig())
	if err != nil {
		t.Fatal(err)
	}
	e := &env{t: t, ctx: ctx, db: db, svc: svc, clock: time.Now()}
	svc.Now = func() time.Time { return e.clock }
	e.srv = NewServer(svc, svc.cfg)
	e.h = e.srv.Handler()
	e.ip = e.randomIP()
	return e
}

func (e *env) randomIP() string {
	b := make([]byte, 3)
	_, _ = rand.Read(b)
	return fmt.Sprintf("10.%d.%d.%d", b[0], b[1], b[2])
}

func randomName(prefix string) string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

const testPassword = "correct horse battery staple"

type testOperator struct {
	Operator
	seed     []byte
	password string
}

func (e *env) operator(role Role) testOperator {
	e.t.Helper()
	enrol, err := e.svc.CreateOperator(e.ctx, randomName("op")+"@hiyall.test", "Test "+string(role), role, testPassword, "test")
	if err != nil {
		e.t.Fatal(err)
	}
	return testOperator{Operator: enrol.Operator, seed: enrol.TOTPSeed, password: testPassword}
}

// code is a valid one-time code for the operator at the test clock, moved to a step nobody used yet.
func (e *env) nextCode(op testOperator) string {
	e.clock = e.clock.Add(time.Duration(totpPeriod) * time.Second)
	return TOTPCode(op.seed, TOTPStep(e.clock))
}

type sess struct {
	token, csrf string
}

// session opens a console session for op directly in the database (the login tests use the real endpoint).
func (e *env) session(op testOperator) sess {
	e.t.Helper()
	token, err := randomToken()
	if err != nil {
		e.t.Fatal(err)
	}
	if _, err = e.db.Pool.Exec(e.ctx, `INSERT INTO operator_sessions(session_id,operator_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '8 hours')`,
		uuid.Must(uuid.NewV7()), op.ID, tokenHash(token)); err != nil {
		e.t.Fatal(err)
	}
	return sess{token: token, csrf: e.svc.csrfFor(token)}
}

type reply struct {
	status int
	header http.Header
	raw    []byte
	body   struct {
		Success bool            `json:"success"`
		Data    json.RawMessage `json:"data"`
		Error   *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
}

func (r reply) code() string {
	if r.body.Error != nil {
		return r.body.Error.Code
	}
	return ""
}

func (r reply) data(v any) {
	json.Unmarshal(r.body.Data, v)
}

type request struct {
	method, path string
	body         any
	s            *sess
	noCSRF       bool
	csrf         string
	ip           string
	headers      map[string]string
	host         string
}

func (e *env) do(q request) reply {
	e.t.Helper()
	var reader io.Reader
	if q.body != nil {
		raw, ok := q.body.(string)
		if !ok {
			b, _ := json.Marshal(q.body)
			raw = string(b)
		}
		reader = strings.NewReader(raw)
	}
	host := q.host
	if host == "" {
		host = "localhost"
	}
	req := httptest.NewRequest(q.method, "http://"+host+q.path, reader)
	req.RemoteAddr = e.ip + ":4444"
	if q.ip != "" {
		req.RemoteAddr = q.ip + ":4444"
	}
	if q.body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if q.s != nil {
		req.AddCookie(&http.Cookie{Name: cookieName, Value: q.s.token})
		if q.method != "GET" && !q.noCSRF {
			req.Header.Set(csrfHeader, q.s.csrf)
		}
		if q.csrf != "" {
			req.Header.Set(csrfHeader, q.csrf)
		}
	}
	for k, v := range q.headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	r := reply{status: rec.Code, header: rec.Header(), raw: rec.Body.Bytes()}
	_ = json.Unmarshal(r.raw, &r.body)
	return r
}

func (e *env) get(s sess, path string) reply { return e.do(request{method: "GET", path: path, s: &s}) }
func (e *env) post(s sess, path string, body any) reply {
	return e.do(request{method: "POST", path: path, body: body, s: &s})
}

// member inserts an onboarded account with a profile and a declared birth date, so it has an age band.
func (e *env) member(minor bool) string {
	e.t.Helper()
	return newMember(e.t, e.ctx, e.db, minor)
}

func newMember(t *testing.T, ctx context.Context, db *store.Store, minor bool) string {
	t.Helper()
	id := uuid.Must(uuid.NewV7()).String()
	username := "t" + strings.ReplaceAll(id, "-", "")[12:30]
	birth := time.Now().UTC().AddDate(-30, 0, 0)
	if minor {
		birth = time.Now().UTC().AddDate(-15, -6, 0)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO users(user_id) VALUES($1)`, []any{id}},
		{`INSERT INTO onboarding(user_id,completed_at,terms_version) VALUES($1,now(),'test')`, []any{id}},
		{`INSERT INTO profiles(user_id,username,data) VALUES($1,$2,jsonb_build_object('displayName',$3::text))`, []any{id, username, "Name " + username}},
		{`INSERT INTO member_ages(user_id,birth_date) VALUES($1,$2::date)`, []any{id, birth.Format(time.DateOnly)}},
	} {
		if _, err = tx.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatal(err)
		}
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	return id
}

func (e *env) report(reporter, subject, reason string) string {
	e.t.Helper()
	r, created, err := e.db.CreateReport(e.ctx, reporter, domain.NewReport{TargetType: "user", TargetID: subject, ReasonCode: reason})
	if err != nil || !created {
		e.t.Fatalf("report: %v created=%v", err, created)
	}
	return r.ReportID
}

func (e *env) count(query string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.db.Pool.QueryRow(e.ctx, query, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}
