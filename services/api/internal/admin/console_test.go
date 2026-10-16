package admin

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/realtime"
)

func TestEveryRouteEnforcesItsRole(t *testing.T) {
	e := newEnv(t)
	roles := map[Role]sess{}
	for _, r := range []Role{RoleViewer, RoleModerator, RoleAdmin} {
		roles[r] = sess{}
	}
	routes := e.srv.Routes()
	if len(routes) < 12 {
		t.Fatalf("only %d routes registered", len(routes))
	}
	public := 0
	for _, route := range routes {
		if route.Min == "" {
			public++
			if route.Path != "/admin/v1/login" {
				t.Fatalf("%s is public", route.Path)
			}
			continue
		}
		path := strings.ReplaceAll(route.Path, "{id}", uuid.NewString())
		// No session: 401.
		if r := e.do(request{method: route.Method, path: path, body: "{}"}); r.status != 401 {
			t.Fatalf("%s %s without a session: %d", route.Method, route.Path, r.status)
		}
		for _, role := range []Role{RoleViewer, RoleModerator, RoleAdmin} {
			op := e.operator(role)
			s := e.session(op)
			var body any
			if route.Method == "POST" {
				body = "{}"
			}
			r := e.do(request{method: route.Method, path: path, body: body, s: &s})
			if role.Allows(route.Min) {
				if r.status == 401 || r.status == 403 {
					t.Fatalf("%s %s as %s refused: %d %s", route.Method, route.Path, role, r.status, r.raw)
				}
			} else if r.status != 403 || r.code() != "FORBIDDEN" {
				t.Fatalf("%s %s as %s allowed: %d %s", route.Method, route.Path, role, r.status, r.raw)
			}
		}
	}
	if public != 1 {
		t.Fatalf("%d public routes", public)
	}
	// The sign-in identity needs an administrator, on a route a viewer may otherwise use.
	user := e.member(false)
	for role, want := range map[Role]int{RoleViewer: 403, RoleModerator: 403, RoleAdmin: 200} {
		s := e.session(e.operator(role))
		if r := e.get(s, "/admin/v1/users/"+user+"?identity=true"); r.status != want {
			t.Fatalf("identity as %s: %d", role, r.status)
		}
	}
}

func TestAuditLogRefusesUpdateDeleteAndTruncate(t *testing.T) {
	e := newEnv(t)
	op := e.operator(RoleViewer)
	id := op.ID
	if err := insertAudit(e.ctx, e.svc.Pool, AuditEntry{OperatorID: &id, Actor: op.Email, Action: "test", Reason: "immutable"}); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`UPDATE operator_audit SET reason='tampered' WHERE actor='` + op.Email + `'`,
		`DELETE FROM operator_audit WHERE actor='` + op.Email + `'`,
		`TRUNCATE operator_audit`,
	} {
		_, err := e.db.Pool.Exec(e.ctx, q)
		if err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Fatalf("%s: %v", q, err)
		}
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE actor=$1 AND reason='immutable'`, op.Email) != 1 {
		t.Fatal("entry changed")
	}
}

func TestResolveNeedsAReasonAndWritesAuditAndModerationAction(t *testing.T) {
	e := newEnv(t)
	mod := e.operator(RoleModerator)
	s := e.session(mod)
	subject := e.member(false)
	report := e.report(e.member(false), subject, "harassment")
	path := "/admin/v1/reports/" + report + "/resolve"

	for _, reason := range []string{"", "short", "         "} {
		if r := e.post(s, path, map[string]any{"action": "warn", "reason": reason}); r.status != 422 {
			t.Fatalf("reason %q: %d", reason, r.status)
		}
	}
	if r := e.post(s, path, map[string]any{"action": "ban", "reason": "a perfectly good reason"}); r.status != 422 {
		t.Fatalf("action: %d", r.status)
	}
	if r := e.post(s, path, `{"action":"warn","reason":"a perfectly good reason","extra":1}`); r.status != 422 {
		t.Fatalf("unknown field: %d", r.status)
	}
	if r := e.post(s, path, map[string]any{"action": "suspend", "reason": "a perfectly good reason"}); r.status != 422 {
		t.Fatalf("suspend without confirmation: %d", r.status)
	}
	if e.count(`SELECT count(*) FROM reports WHERE report_id=$1 AND status='open'`, report) != 1 || e.count(`SELECT count(*) FROM operator_audit WHERE target_id=$1 AND action LIKE 'report_%'`, report) != 0 {
		t.Fatal("a refused request changed something")
	}

	reason := "repeated abuse in direct messages"
	if r := e.post(s, path, map[string]any{"action": "warn", "reason": reason}); r.status != 200 {
		t.Fatal(r.raw)
	}
	var status, code string
	e.db.Pool.QueryRow(e.ctx, `SELECT status,resolution_code FROM reports WHERE report_id=$1`, report).Scan(&status, &code)
	if status != "actioned" || code != "warn" {
		t.Fatal(status, code)
	}
	var actor, note string
	e.db.Pool.QueryRow(e.ctx, `SELECT actor,note FROM moderation_actions WHERE report_id=$1`, report).Scan(&actor, &note)
	if actor != mod.Email || note != reason {
		t.Fatal(actor, note)
	}
	var auditReason, ip string
	var opID *string
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT reason,ip,operator_id::text FROM operator_audit WHERE action='report_warn' AND target_id=$1`, report).Scan(&auditReason, &ip, &opID); err != nil || auditReason != reason || opID == nil || *opID != mod.ID || !strings.HasSuffix(ip, "/24") {
		t.Fatal(err, auditReason, ip)
	}
	// The same report cannot be resolved twice.
	if r := e.post(s, path, map[string]any{"action": "dismiss", "reason": "a perfectly good reason"}); r.status != 409 || r.code() != "REPORT_CLOSED" {
		t.Fatalf("second resolve: %d %s", r.status, r.raw)
	}
	if r := e.post(s, "/admin/v1/reports/"+uuid.NewString()+"/resolve", map[string]any{"action": "dismiss", "reason": "a perfectly good reason"}); r.status != 404 {
		t.Fatalf("unknown report: %d", r.status)
	}
	if r := e.post(s, "/admin/v1/reports/not-an-id/resolve", map[string]any{"action": "dismiss", "reason": "a perfectly good reason"}); r.status != 404 {
		t.Fatalf("bad id: %d", r.status)
	}
}

func TestSuspendCutsSessionsNotifiesRealtimeAndRestoreReverses(t *testing.T) {
	e := newEnv(t)
	mod := e.operator(RoleModerator)
	s := e.session(mod)
	subject := e.member(false)
	reporter := e.member(false)
	report := e.report(reporter, subject, "threats")
	if _, err := e.db.Pool.Exec(e.ctx, `INSERT INTO sessions(session_id,user_id,expires_at) VALUES($1,$2,now()+interval '1 day')`, uuid.NewString(), subject); err != nil {
		t.Fatal(err)
	}
	conn, err := e.db.Pool.Acquire(e.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err = conn.Exec(e.ctx, `LISTEN `+realtime.Channel); err != nil {
		t.Fatal(err)
	}
	if r := e.post(s, "/admin/v1/reports/"+report+"/resolve", map[string]any{"action": "suspend", "confirm": true, "reason": "credible threat against another member"}); r.status != 200 {
		t.Fatal(r.raw)
	}
	var status string
	e.db.Pool.QueryRow(e.ctx, `SELECT status FROM users WHERE user_id=$1`, subject).Scan(&status)
	if status != "suspended" || e.count(`SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, subject) != 0 {
		t.Fatal("not suspended and cut off", status)
	}
	wait, cancel := context.WithTimeout(e.ctx, 5*time.Second)
	defer cancel()
	found := false
	for !found {
		n, err := conn.Conn().WaitForNotification(wait)
		if err != nil {
			t.Fatal("no realtime disconnect notice", err)
		}
		found = strings.Contains(n.Payload, subject)
	}
	_ = realtime.DisconnectEvent

	// Restore: a moderator may, a viewer may not, and it needs a reason.
	viewer := e.session(e.operator(RoleViewer))
	if r := e.post(viewer, "/admin/v1/users/"+subject+"/restore", map[string]any{"reason": "appeal upheld after review"}); r.status != 403 {
		t.Fatal(r.status)
	}
	if r := e.post(s, "/admin/v1/users/"+subject+"/restore", map[string]any{"reason": "short"}); r.status != 422 {
		t.Fatal(r.status)
	}
	if r := e.post(s, "/admin/v1/users/"+subject+"/restore", map[string]any{"reason": "appeal upheld after review"}); r.status != 200 {
		t.Fatal(r.raw)
	}
	e.db.Pool.QueryRow(e.ctx, `SELECT status FROM users WHERE user_id=$1`, subject).Scan(&status)
	if status != "active" {
		t.Fatal(status)
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE action='user_restore' AND target_id=$1 AND reason='appeal upheld after review'`, subject) != 1 {
		t.Fatal("restore not audited")
	}
	if r := e.post(s, "/admin/v1/users/"+subject+"/restore", map[string]any{"reason": "appeal upheld after review"}); r.status != 409 || r.code() != "NOT_SUSPENDED" {
		t.Fatalf("restore active: %d %s", r.status, r.raw)
	}
	if r := e.post(s, "/admin/v1/users/"+uuid.NewString()+"/restore", map[string]any{"reason": "appeal upheld after review"}); r.status != 404 {
		t.Fatalf("restore unknown: %d", r.status)
	}
}

func TestCaseShowsOnlyWhatTheReporterSharedAndIsAudited(t *testing.T) {
	e := newEnv(t)
	viewer := e.operator(RoleViewer)
	s := e.session(viewer)
	reporter, subject := e.member(false), e.member(true)
	low, high := reporter, subject
	if low > high {
		low, high = high, low
	}
	conv, device := uuid.NewString(), uuid.NewString()
	shared, secretMsg, blob := uuid.NewString(), uuid.NewString(), uuid.NewString()
	// A conversation with one shared message (with an image) and one the reporter did not share, whose ciphertext is on file.
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) VALUES($1,$2,$3,$2,'active')`, []any{conv, low, high}},
		{`INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at) VALUES($1,$2,$3,now()),($1,$3,$2,now())`, []any{conv, low, high}},
		{`INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform) VALUES($1,$2,$3,'s','g','web')`, []any{device, subject, "ik-" + device}},
		{`INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id) VALUES($1,$2,$3,$4),($5,$2,$3,$4)`, []any{shared, conv, subject, device, secretMsg}},
		{`INSERT INTO message_envelopes(message_id,recipient_device_id,envelope_type,ciphertext) VALUES($1,$2,0,'CIPHERTEXT-SENTINEL-NOT-SHARED'),($3,$2,0,'CIPHERTEXT-SENTINEL-SHARED-ONE')`, []any{secretMsg, device, shared}},
		{`INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,message_id,role,size_bytes,ct_sha256,state,object_key,uploaded_at,expires_at) VALUES($1,$2,$3,$4,'full',2048,decode(repeat('ab',32),'hex'),'uploaded','chat/'||$5::text,now(),now()+interval '30 days')`, []any{blob, subject, conv, shared, blob}},
	} {
		if _, err := e.db.Pool.Exec(e.ctx, q.sql, q.args...); err != nil {
			t.Fatal(err)
		}
	}
	rep, created, err := e.db.CreateReport(e.ctx, reporter, domain.NewReport{TargetType: "conversation", TargetID: conv, ReasonCode: "sexual_content", Description: "sent me an image I did not ask for", DisclosureConsent: true,
		Evidence: []domain.Evidence{{MessageID: shared, Text: "PLAINTEXT-THE-REPORTER-SHARED", Attachments: []domain.EvidenceAttachment{{BlobIDs: []string{blob}, Descriptor: json.RawMessage(`{"key":"DESCRIPTOR-KEY-SENTINEL"}`)}}}}})
	if err != nil || !created {
		t.Fatal(err, created)
	}

	r := e.get(s, "/admin/v1/reports/"+rep.ReportID)
	if r.status != 200 {
		t.Fatal(r.status, r.raw)
	}
	body := string(r.raw)
	for _, must := range []string{"PLAINTEXT-THE-REPORTER-SHARED", blob, "sent me an image I did not ask for", `"minor":true`, `"ageBand":"minor"`, `"ageBand":"adult"`} {
		if !strings.Contains(body, must) {
			t.Fatalf("missing %q in %s", must, body)
		}
	}
	var c struct {
		Evidence   []map[string]any `json:"evidence"`
		HeldImages []struct {
			BlobID    string `json:"blobId"`
			SizeBytes int    `json:"sizeBytes"`
			SHA256    string `json:"sha256"`
		} `json:"heldImages"`
		Reporter map[string]any `json:"reporter"`
		Subject  map[string]any `json:"subject"`
	}
	r.data(&c)
	if len(c.Evidence) != 1 || len(c.HeldImages) != 1 || c.HeldImages[0].BlobID != blob || c.HeldImages[0].SizeBytes != 2048 || c.HeldImages[0].SHA256 != "q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s=" {
		t.Fatalf("evidence %+v held %+v", c.Evidence, c.HeldImages)
	}
	for _, never := range []string{"CIPHERTEXT-SENTINEL", "DESCRIPTOR-KEY-SENTINEL", "descriptor", secretMsg, "object_key", "chat/" + blob, "birth", "ciphertext", "location", "email"} {
		if strings.Contains(strings.ToLower(body), strings.ToLower(never)) {
			t.Fatalf("case leaks %q: %s", never, body)
		}
	}
	for _, key := range []string{"userId", "username", "displayName", "ageBand", "status", "reportsAgainst", "reportsFiled"} {
		if _, ok := c.Subject[key]; !ok {
			t.Fatalf("subject summary lacks %s", key)
		}
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE operator_id=$1 AND action='case_view' AND target_id=$2`, viewer.ID, rep.ReportID) != 1 {
		t.Fatal("reading a case must be audited")
	}
	if r := e.get(s, "/admin/v1/reports/"+uuid.NewString()); r.status != 404 {
		t.Fatal(r.status)
	}

	// The user view: moderation facts only.
	ur := e.get(s, "/admin/v1/users/"+subject)
	if ur.status != 200 {
		t.Fatal(ur.raw)
	}
	for _, never := range []string{"CIPHERTEXT", "birth", "location", "visitor", "email", "identit", "PLAINTEXT"} {
		if strings.Contains(strings.ToLower(string(ur.raw)), strings.ToLower(never)) {
			t.Fatalf("user view leaks %q: %s", never, ur.raw)
		}
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE operator_id=$1 AND action='user_view' AND target_id=$2`, viewer.ID, subject) != 1 {
		t.Fatal("user view must be audited")
	}
	// Admins can look up the sign-in identity, which is audited on its own. There is no email to show.
	if _, err = e.db.Pool.Exec(e.ctx, `INSERT INTO auth_identities(issuer,subject,user_id) VALUES('https://securetoken.google.com/test',$1,$2)`, "uid-"+subject, subject); err != nil {
		t.Fatal(err)
	}
	adm := e.operator(RoleAdmin)
	ar := e.get(e.session(adm), "/admin/v1/users/"+subject+"?identity=true")
	if ar.status != 200 || !strings.Contains(string(ar.raw), "uid-"+subject) || e.count(`SELECT count(*) FROM operator_audit WHERE operator_id=$1 AND action='user_identity_view'`, adm.ID) != 1 {
		t.Fatalf("identity %d %s", ar.status, ar.raw)
	}
}

func TestQueueOrderFiltersAndSignedCursors(t *testing.T) {
	e := newEnv(t)
	s := e.session(e.operator(RoleViewer))
	subject := e.member(false)
	adult := func() string { return e.member(false) }
	// Created oldest first. Expected order: minors first (high before normal), then high, then normal, each oldest first.
	r1 := e.report(adult(), subject, "spam")           // normal
	r2 := e.report(adult(), subject, "threats")        // high
	r3 := e.report(e.member(true), subject, "spam")    // normal, minor reporter
	r4 := e.report(e.member(true), subject, "threats") // high, minor reporter
	r5 := e.report(adult(), subject, "scam")           // normal
	r6 := e.report(adult(), subject, "hate")           // high
	want := []string{r4, r3, r2, r6, r1, r5}

	type page struct {
		Items []struct {
			ReportID string `json:"reportId"`
			Minor    bool   `json:"minor"`
			Severity string `json:"severity"`
		} `json:"items"`
		Next    *string `json:"nextCursor"`
		HasMore bool    `json:"hasMore"`
	}
	walk := func(query string) ([]string, int) {
		var ids []string
		cursor, pages := "", 0
		for {
			path := "/admin/v1/reports?subject=" + subject + "&limit=2" + query
			if cursor != "" {
				path += "&cursor=" + cursor
			}
			r := e.get(s, path)
			if r.status != 200 {
				t.Fatal(r.status, r.raw)
			}
			var p page
			r.data(&p)
			pages++
			for _, it := range p.Items {
				ids = append(ids, it.ReportID)
				if (it.ReportID == r3 || it.ReportID == r4) != it.Minor {
					t.Fatalf("minor flag wrong on %s", it.ReportID)
				}
			}
			if !p.HasMore {
				return ids, pages
			}
			cursor = *p.Next
		}
	}
	got, pages := walk("")
	if strings.Join(got, ",") != strings.Join(want, ",") || pages != 3 {
		t.Fatalf("order %v pages %d, want %v", got, pages, want)
	}
	if got, _ = walk("&minor=true"); strings.Join(got, ",") != r4+","+r3 {
		t.Fatalf("minor filter %v", got)
	}
	if got, _ = walk("&severity=high"); strings.Join(got, ",") != r4+","+r2+","+r6 {
		t.Fatalf("severity filter %v", got)
	}

	// Cursors are signed, expire, and belong to one operator and one filter.
	first := e.get(s, "/admin/v1/reports?subject="+subject+"&limit=2")
	var p page
	first.data(&p)
	cur := *p.Next
	for name, path := range map[string]string{
		"tampered":      "/admin/v1/reports?subject=" + subject + "&limit=2&cursor=" + cur[:len(cur)-3] + "AAA",
		"garbage":       "/admin/v1/reports?subject=" + subject + "&cursor=xyz",
		"other filter":  "/admin/v1/reports?subject=" + subject + "&limit=2&severity=high&cursor=" + cur,
		"other subject": "/admin/v1/reports?subject=" + uuid.NewString() + "&limit=2&cursor=" + cur,
	} {
		if r := e.get(s, path); r.status != 422 || r.code() != "INVALID_CURSOR" {
			t.Fatalf("%s: %d %s", name, r.status, r.raw)
		}
	}
	if r := e.get(e.session(e.operator(RoleViewer)), "/admin/v1/reports?subject="+subject+"&limit=2&cursor="+cur); r.status != 422 {
		t.Fatalf("another operator's cursor: %d", r.status)
	}
	e.clock = e.clock.Add(16 * time.Minute)
	if r := e.get(s, "/admin/v1/reports?subject="+subject+"&limit=2&cursor="+cur); r.status != 422 {
		t.Fatalf("expired cursor: %d", r.status)
	}
	for _, bad := range []string{"status=nope", "severity=urgent", "limit=0", "limit=51", "minor=maybe", "subject=x"} {
		if r := e.get(s, "/admin/v1/reports?"+bad); r.status != 422 {
			t.Fatalf("%s: %d", bad, r.status)
		}
	}

	// Resolved reports list newest first under their own status.
	mod := e.session(e.operator(RoleModerator))
	e.post(mod, "/admin/v1/reports/"+r1+"/resolve", map[string]any{"action": "dismiss", "reason": "nothing to see in this one"})
	e.post(mod, "/admin/v1/reports/"+r5+"/resolve", map[string]any{"action": "dismiss", "reason": "nothing to see in this one"})
	if got, _ = walk("&status=dismissed"); strings.Join(got, ",") != r5+","+r1 {
		t.Fatalf("dismissed %v", got)
	}
	if got, _ = walk("&status=all"); len(got) != 6 || got[0] != r6 {
		t.Fatalf("all %v", got)
	}
}

func TestOperatorManagementRules(t *testing.T) {
	e := newEnv(t)
	// Make this operator the only active administrator.
	if _, err := e.db.Pool.Exec(e.ctx, `UPDATE operators SET disabled_at=now() WHERE role='admin' AND disabled_at IS NULL`); err != nil {
		t.Fatal(err)
	}
	boss := e.operator(RoleAdmin)
	s := e.session(boss)
	viewer := e.operator(RoleViewer)
	reason := map[string]any{"reason": "quarterly access review done"}
	with := func(extra map[string]any) map[string]any {
		m := map[string]any{}
		for k, v := range reason {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}

	if r := e.post(s, "/admin/v1/operators/"+boss.ID+"/disable", reason); r.status != 409 || r.code() != "SELF_DISABLE" {
		t.Fatalf("self disable: %d %s", r.status, r.raw)
	}
	if r := e.post(s, "/admin/v1/operators/"+boss.ID+"/role", with(map[string]any{"role": "moderator"})); r.status != 409 || r.code() != "LAST_ADMIN" {
		t.Fatalf("demote last admin: %d %s", r.status, r.raw)
	}
	if r := e.post(s, "/admin/v1/operators/"+viewer.ID+"/role", with(map[string]any{"role": "root"})); r.status != 422 {
		t.Fatalf("bad role: %d", r.status)
	}
	if r := e.post(s, "/admin/v1/operators/"+viewer.ID+"/role", map[string]any{"role": "moderator", "reason": "short"}); r.status != 422 {
		t.Fatalf("reason: %d", r.status)
	}
	if r := e.post(s, "/admin/v1/operators/"+viewer.ID+"/role", with(map[string]any{"role": "viewer"})); r.status != 409 {
		t.Fatalf("no-op: %d", r.status)
	}
	// A role change applies to a session that is already open.
	vs := e.session(viewer)
	if e.post(vs, "/admin/v1/reports/"+uuid.NewString()+"/resolve", with(map[string]any{"action": "dismiss"})).status != 403 {
		t.Fatal("viewer resolved")
	}
	// Making someone an administrator is a proposal a different administrator approves (round-3 API-5).
	second := e.operator(RoleAdmin)
	secondSession := e.session(second)
	r := e.post(s, "/admin/v1/operators/"+viewer.ID+"/role", with(map[string]any{"role": "admin"}))
	var proposal struct {
		Pending  bool
		Approval struct{ ApprovalID, Kind, TargetOperator string }
	}
	r.data(&proposal)
	if r.status != 202 || !proposal.Pending || proposal.Approval.Kind != "promote_admin" || proposal.Approval.TargetOperator != viewer.ID {
		t.Fatalf("promotion must be a proposal: %d %s", r.status, r.raw)
	}
	if e.get(vs, "/admin/v1/operators").status != 403 {
		t.Fatal("the proposal alone promoted the operator")
	}
	if r = e.decide(s, proposal.Approval.ApprovalID, "approve", "approving my own proposal"); r.status != 403 || r.code() != "SECOND_APPROVER_REQUIRED" {
		t.Fatalf("self approval: %d %s", r.status, r.raw)
	}
	if r = e.decide(secondSession, proposal.Approval.ApprovalID, "approve", "second administrator checked the request"); r.status != 200 {
		t.Fatalf("approval: %d %s", r.status, r.raw)
	}
	if e.get(vs, "/admin/v1/operators").status != 200 {
		t.Fatal("promotion did not apply to the open session")
	}
	// With a second administrator the first can be demoted, and then the second is the last.
	if r := e.post(s, "/admin/v1/operators/"+boss.ID+"/role", with(map[string]any{"role": "moderator"})); r.status != 200 {
		t.Fatal(r.raw)
	}
	if r := e.post(vs, "/admin/v1/operators/"+viewer.ID+"/disable", reason); r.status != 409 || r.code() != "SELF_DISABLE" {
		t.Fatal(r.status)
	}
	// The command line can shut out even the last administrator (a stolen device), and says so in the log.
	if _, err := e.svc.SetDisabled(e.ctx, Actor{Label: "cli:test"}, viewer.ID, true, "stolen laptop reported", false); err != nil {
		t.Fatal(err)
	}
	if e.get(vs, "/admin/v1/me").status != 401 {
		t.Fatal("disabled administrator kept a session")
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE actor='cli:test' AND action='operator_disable' AND target_id=$1`, viewer.ID) != 1 {
		t.Fatal("cli action not audited")
	}
	// Listing never carries credentials.
	r = e.get(e.session(e.operator(RoleAdmin)), "/admin/v1/operators")
	if r.status != 200 {
		t.Fatal(r.status)
	}
	for _, never := range []string{"password", "totp", "hash", "secret"} {
		if strings.Contains(strings.ToLower(string(r.raw)), never) {
			t.Fatalf("operator list leaks %q", never)
		}
	}
	// Disable and enable are audited with their reasons.
	adm2 := e.session(e.operator(RoleAdmin))
	target := e.operator(RoleViewer)
	e.post(adm2, "/admin/v1/operators/"+target.ID+"/disable", reason)
	if r := e.post(adm2, "/admin/v1/operators/"+target.ID+"/enable", reason); r.status != 200 {
		t.Fatal(r.raw)
	}
	if e.count(`SELECT count(*) FROM operator_audit WHERE target_id=$1 AND action IN ('operator_disable','operator_enable') AND reason=$2`, target.ID, "quarterly access review done") != 2 {
		t.Fatal("management actions not audited with reasons")
	}
}

func TestAuditEndpointIsAdminOnlyFilteredAndPaged(t *testing.T) {
	e := newEnv(t)
	actor := e.operator(RoleViewer)
	s := e.session(actor)
	for i := 0; i < 3; i++ {
		e.get(s, "/admin/v1/users/"+e.member(false))
	}
	adm := e.session(e.operator(RoleAdmin))
	var got struct {
		Items []struct {
			AuditID int64  `json:"auditId"`
			Action  string `json:"action"`
			Actor   string `json:"actor"`
			IP      string `json:"ip"`
		} `json:"items"`
		Next *string `json:"nextCursor"`
	}
	r := e.get(adm, "/admin/v1/audit?operator="+actor.ID+"&action=user_view&limit=2")
	if r.status != 200 {
		t.Fatal(r.raw)
	}
	r.data(&got)
	if len(got.Items) != 2 || got.Next == nil || got.Items[0].Actor != actor.Email || got.Items[0].AuditID <= got.Items[1].AuditID {
		t.Fatalf("%+v", got)
	}
	r = e.get(adm, "/admin/v1/audit?operator="+actor.ID+"&action=user_view&limit=2&cursor="+*got.Next)
	r.data(&got)
	if len(got.Items) != 1 || got.Next != nil {
		t.Fatalf("second page %+v", got)
	}
	if e.get(e.session(e.operator(RoleModerator)), "/admin/v1/audit").status != 403 {
		t.Fatal("moderator read the audit log")
	}
	if e.get(adm, "/admin/v1/audit?operator=nope").status != 422 {
		t.Fatal("bad filter")
	}
}
