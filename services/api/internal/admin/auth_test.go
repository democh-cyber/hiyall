package admin

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

type loginBody struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Code     string `json:"code"`
}

func (e *env) login(op testOperator, password, code string, ip string) reply {
	return e.do(request{method: "POST", path: "/admin/v1/login", body: loginBody{op.Email, password, code}, ip: ip})
}

func sessionCookie(r reply) *http.Cookie {
	for _, c := range (&http.Response{Header: r.header}).Cookies() {
		if c.Name == cookieName || c.Name == secureCookieName {
			return c
		}
	}
	return nil
}

func TestLoginRequiresPasswordAndCodeAndGivesGenericErrors(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleModerator)

	wrongPassword := e.login(op, "not the password at all", e.nextCode(op), "")
	wrongCode := e.login(op, op.password, wrongCodeFor(op, e.clock), "")
	unknown := e.do(request{method: "POST", path: "/admin/v1/login", body: loginBody{randomName("nobody") + "@hiyall.test", op.password, e.nextCode(op)}})
	noCode := e.login(op, op.password, "", "")
	for name, r := range map[string]reply{"wrong password": wrongPassword, "wrong code": wrongCode, "unknown account": unknown, "no code": noCode} {
		if r.status != 401 || r.code() != "SIGN_IN_FAILED" || r.body.Error.Message != "Sign-in failed" {
			t.Fatalf("%s: %d %s", name, r.status, r.raw)
		}
		if sessionCookie(r) != nil {
			t.Fatalf("%s set a cookie", name)
		}
	}
	// Unknown account, wrong password and wrong code look identical to the caller.
	if wrongPassword.body.Error.Message != unknown.body.Error.Message || wrongCode.body.Error.Code != unknown.body.Error.Code {
		t.Fatal("responses differ")
	}

	ok := e.login(op, op.password, e.nextCode(op), "")
	if ok.status != 200 {
		t.Fatalf("%d %s", ok.status, ok.raw)
	}
	c := sessionCookie(ok)
	if c == nil || !c.HttpOnly || c.SameSite != http.SameSiteStrictMode || c.Secure || c.Path != "/" || c.Name != cookieName {
		t.Fatalf("cookie %+v", c)
	}
	if strings.Contains(string(ok.raw), c.Value) {
		t.Fatal("the session token must only be in the cookie")
	}
	// Only the hash of the token is stored.
	if e.count(`SELECT count(*) FROM operator_sessions WHERE token_hash=$1`, tokenHash(c.Value)) != 1 || e.count(`SELECT count(*) FROM operator_sessions WHERE token_hash=convert_to($1,'UTF8')`, c.Value) != 0 {
		t.Fatal("token storage")
	}
	var data struct {
		CSRF string `json:"csrfToken"`
	}
	ok.data(&data)
	me := e.do(request{method: "GET", path: "/admin/v1/me", s: &sess{token: c.Value}})
	if me.status != 200 {
		t.Fatal(me.status)
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE operator_id=$1 AND action='login'`, op.ID) != 1 {
		t.Fatal("login not audited")
	}
	if e.count(`SELECT count(*) FROM operators WHERE operator_id=$1 AND last_login_at IS NOT NULL`, op.ID) != 1 {
		t.Fatal("last login")
	}
}

// wrongCodeFor is a six digit code that is not valid at any step the verifier accepts.
func wrongCodeFor(op testOperator, now time.Time) string {
	valid := map[string]bool{}
	for d := int64(-1); d <= 1; d++ {
		valid[TOTPCode(op.seed, TOTPStep(now)+d)] = true
	}
	for _, c := range []string{"000000", "111111", "222222"} {
		if !valid[c] {
			return c
		}
	}
	return "999999"
}

func TestOneTimeCodeCannotBeReplayed(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleViewer)
	code := e.nextCode(op)
	first := e.login(op, op.password, code, "")
	if first.status != 200 {
		t.Fatal(first.raw)
	}
	again := e.login(op, op.password, code, "")
	if again.status != 401 {
		t.Fatalf("replayed code accepted: %d", again.status)
	}
	// Even an older code from the accepted window cannot be used once a newer one was.
	older := TOTPCode(op.seed, TOTPStep(e.clock)-1)
	if r := e.login(op, op.password, older, ""); r.status != 401 {
		t.Fatalf("older step accepted: %d", r.status)
	}
	if r := e.login(op, op.password, e.nextCode(op), ""); r.status != 200 {
		t.Fatal("a fresh code works", r.raw)
	}
}

func TestTwoRequestsRacingWithOneCodeOpenOneSession(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleViewer)
	code := e.nextCode(op)
	results := make(chan int, 4)
	for i := 0; i < 4; i++ {
		go func() { results <- e.login(op, op.password, code, "").status }()
	}
	won := 0
	for i := 0; i < 4; i++ {
		if <-results == 200 {
			won++
		}
	}
	if won != 1 {
		t.Fatalf("%d sessions from one code", won)
	}
}

func TestLockoutPerAccountAndPerAddressSurvivesRestart(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleModerator)
	other := e.operator(RoleModerator)
	ip := e.randomIP()
	for i := 0; i < 5; i++ {
		if r := e.login(op, "wrong password here", e.nextCode(op), ip); r.status != 401 {
			t.Fatalf("attempt %d: %d", i, r.status)
		}
	}
	// The account is locked, whatever the address and even for the right credentials.
	locked := e.login(op, op.password, e.nextCode(op), e.randomIP())
	if locked.status != 429 || locked.code() != "TOO_MANY_ATTEMPTS" || locked.header.Get("Retry-After") == "" {
		t.Fatalf("account lock: %d %s", locked.status, locked.raw)
	}
	// The address is locked too, for other accounts.
	if r := e.login(other, other.password, e.nextCode(other), ip); r.status != 429 {
		t.Fatalf("address lock: %d", r.status)
	}
	// The other account from a clean address is untouched.
	if r := e.login(other, other.password, e.nextCode(other), e.randomIP()); r.status != 200 {
		t.Fatalf("collateral lock: %d %s", r.status, r.raw)
	}
	// A new process (restart, or another node) sees the same limits: they live in the database.
	svc2, err := NewService(e.db, testConfig())
	if err != nil {
		t.Fatal(err)
	}
	h2 := NewServer(svc2, svc2.cfg)
	e2 := *e
	e2.svc, e2.srv, e2.h = svc2, h2, h2.Handler()
	svc2.Now = func() time.Time { return e.clock }
	if r := e2.login(op, op.password, e.nextCode(op), e.randomIP()); r.status != 429 {
		t.Fatalf("lockout lost on restart: %d", r.status)
	}
	// No account enumeration through the lockout: an address that does not exist locks the same way.
	ghost := testOperator{Operator: Operator{Email: randomName("ghost") + "@hiyall.test"}, password: "whatever password"}
	ip2 := e.randomIP()
	for i := 0; i < 5; i++ {
		e.login(ghost, ghost.password, "123456", ip2)
	}
	if r := e.login(ghost, ghost.password, "123456", e.randomIP()); r.status != 429 {
		t.Fatalf("unknown account not limited: %d", r.status)
	}
	// Failures age out of the window.
	if _, err = e.db.Pool.Exec(e.ctx, `UPDATE operator_login_attempts SET at=at-interval '16 minutes' WHERE account_key=$1`, e.svc.keys.mac("account", op.Email)); err != nil {
		t.Fatal(err)
	}
	if r := e.login(op, op.password, e.nextCode(op), e.randomIP()); r.status != 200 {
		t.Fatalf("lock did not lift: %d %s", r.status, r.raw)
	}
	if e.count(`SELECT count(*) FROM operator_login_attempts WHERE succeeded AND account_key=$1`, e.svc.keys.mac("account", op.Email)) != 1 {
		t.Fatal("success not recorded")
	}
}

func TestSessionExpiryIdleAbsoluteAndDisable(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleViewer)
	status := func(s sess) int { return e.get(s, "/admin/v1/me").status }

	fresh := e.session(op)
	if status(fresh) != 200 {
		t.Fatal("fresh session")
	}
	idle := e.session(op)
	e.db.Pool.Exec(e.ctx, `UPDATE operator_sessions SET last_seen_at=now()-interval '31 minutes' WHERE token_hash=$1`, tokenHash(idle.token))
	if status(idle) != 401 {
		t.Fatal("idle session accepted after 30 minutes")
	}
	active := e.session(op)
	e.db.Pool.Exec(e.ctx, `UPDATE operator_sessions SET last_seen_at=now()-interval '29 minutes' WHERE token_hash=$1`, tokenHash(active.token))
	if status(active) != 200 {
		t.Fatal("a session used within 30 minutes is alive")
	}
	if e.count(`SELECT count(*) FROM operator_sessions WHERE token_hash=$1 AND last_seen_at>now()-interval '1 minute'`, tokenHash(active.token)) != 1 {
		t.Fatal("use must refresh the idle clock")
	}
	old := e.session(op)
	e.db.Pool.Exec(e.ctx, `UPDATE operator_sessions SET expires_at=now()-interval '1 second' WHERE token_hash=$1`, tokenHash(old.token))
	if status(old) != 401 {
		t.Fatal("absolute expiry")
	}
	// The absolute lifetime of a real login is 8 hours.
	r := e.login(op, op.password, e.nextCode(op), "")
	var d struct {
		ExpiresAt time.Time `json:"expiresAt"`
	}
	r.data(&d)
	if left := time.Until(d.ExpiresAt); left < 7*time.Hour+50*time.Minute || left > 8*time.Hour+time.Minute {
		t.Fatalf("session lifetime %v", left)
	}
	if status(sess{token: "garbage"}) != 401 || status(sess{}) != 401 {
		t.Fatal("garbage token")
	}
	// Logout ends the session, and is audited.
	out := e.session(op)
	if e.post(out, "/admin/v1/logout", nil).status != 200 || status(out) != 401 {
		t.Fatal("logout")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE operator_id=$1 AND action='logout'`, op.ID) != 1 {
		t.Fatal("logout not audited")
	}
	// Disabling the account ends its sessions at once.
	live := e.session(op)
	admin := e.operator(RoleAdmin)
	as := e.session(admin)
	if r := e.post(as, "/admin/v1/operators/"+op.ID+"/disable", map[string]string{"reason": "device reported stolen"}); r.status != 200 {
		t.Fatal(r.raw)
	}
	if status(live) != 401 {
		t.Fatal("disabled operator kept a session")
	}
	if r := e.login(op, op.password, e.nextCode(op), ""); r.status != 401 {
		t.Fatal("disabled operator signed in")
	}
}

func TestCSRFAndSameOriginAreEnforcedOnEveryMutation(t *testing.T) {
	e := newEnv(t)
	mod := e.operator(RoleModerator)
	s := e.session(mod)
	subject := e.member(false)
	report := e.report(e.member(false), subject, "spam")
	path := "/admin/v1/reports/" + report + "/resolve"
	body := map[string]any{"action": "dismiss", "reason": "not a violation of anything"}

	for name, q := range map[string]request{
		"missing token": {method: "POST", path: path, body: body, s: &s, noCSRF: true},
		"wrong token":   {method: "POST", path: path, body: body, s: &s, csrf: "AAAA"},
		"other session": {method: "POST", path: path, body: body, s: &s, csrf: e.session(mod).csrf},
		"cross origin":  {method: "POST", path: path, body: body, s: &s, headers: map[string]string{"Origin": "https://evil.example"}},
		"cross site":    {method: "POST", path: path, body: body, s: &s, headers: map[string]string{"Sec-Fetch-Site": "cross-site"}},
		"login origin":  {method: "POST", path: "/admin/v1/login", body: loginBody{"a@b.test", "x", "1"}, headers: map[string]string{"Origin": "https://evil.example"}},
		"form post":     {method: "POST", path: path, body: "action=dismiss", s: &s},
	} {
		r := e.do(q)
		if name == "form post" {
			// Not JSON: refused as invalid input rather than executed.
			if r.status != 422 {
				t.Fatalf("%s: %d", name, r.status)
			}
			continue
		}
		if r.status != 403 || r.code() != "CSRF" {
			t.Fatalf("%s: %d %s", name, r.status, r.raw)
		}
	}
	if e.count(`SELECT count(*) FROM reports WHERE report_id=$1 AND status='open'`, report) != 1 {
		t.Fatal("a refused request changed the report")
	}
	same := e.do(request{method: "POST", path: path, body: body, s: &s, headers: map[string]string{"Origin": "http://localhost"}})
	if same.status != 200 {
		t.Fatalf("same origin: %d %s", same.status, same.raw)
	}
}

func TestSecureCookiesWhenTLSIsInFront(t *testing.T) {
	e := newEnv(t)
	cfg := testConfig()
	cfg.SecureCookies, cfg.TLSInFront, cfg.TrustProxy = true, true, true
	svc, _ := NewService(e.db, cfg)
	svc.Now = func() time.Time { return e.clock }
	e2 := *e
	e2.svc, e2.h = svc, NewServer(svc, cfg).Handler()
	op := e.operator(RoleViewer)
	r := e2.do(request{method: "POST", path: "/admin/v1/login", body: loginBody{op.Email, op.password, e.nextCode(op)}, headers: map[string]string{"X-Forwarded-Proto": "https"}})
	if r.status != 200 {
		t.Fatal(r.status, r.raw)
	}
	c := sessionCookie(r)
	if c == nil || !c.Secure || !c.HttpOnly || c.Name != secureCookieName || c.SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie %+v", c)
	}
}

func TestChangingYourOwnPassword(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleViewer)
	s, other := e.session(op), e.session(op)
	if r := e.post(s, "/admin/v1/me/password", map[string]string{"current": "wrong wrong wrong", "new": "a brand new long password"}); r.status != 403 {
		t.Fatalf("wrong current: %d", r.status)
	}
	if r := e.post(s, "/admin/v1/me/password", map[string]string{"current": op.password, "new": "short"}); r.status != 422 {
		t.Fatalf("weak: %d", r.status)
	}
	if r := e.post(s, "/admin/v1/me/password", map[string]string{"current": op.password, "new": "a brand new long password"}); r.status != 200 {
		t.Fatal(r.raw)
	}
	if e.get(other, "/admin/v1/me").status != 401 || e.get(s, "/admin/v1/me").status != 200 {
		t.Fatal("other sessions must end, this one stays")
	}
	if r := e.login(op, op.password, e.nextCode(op), ""); r.status != 401 {
		t.Fatal("old password still works")
	}
	if r := e.login(op, "a brand new long password", e.nextCode(op), ""); r.status != 200 {
		t.Fatal("new password", r.raw)
	}
}
