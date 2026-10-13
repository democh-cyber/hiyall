package httpapi

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"hiyall/services/api/internal/store"
)

func (h *acctHarness) exportDoc(user string) (int, map[string][]string, map[string]any, []byte) {
	h.t.Helper()
	h.api.clients.reset("127.0.0.1")
	status, header, body := h.full(user, "GET", "/v1/me/export", "", "")
	var doc map[string]any
	if status == 200 {
		if err := json.Unmarshal(body, &doc); err != nil {
			h.t.Fatalf("export is not valid JSON: %v", err)
		}
	}
	return status, header, doc, body
}

func list(t *testing.T, v any, name string) []any {
	t.Helper()
	l, ok := v.([]any)
	if !ok {
		t.Fatalf("%s is not a list: %v", name, v)
	}
	return l
}

func TestExportShapeContentAndRateLimit(t *testing.T) {
	w := newPurgeWorld(t) // a member with something everywhere
	h := w.acctHarness
	// Someone xan follows but who blocked xan afterwards (the follow row is still there): never listed.
	h.exec(`INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active')`, xan, yui)
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, yui, xan)

	status, header, doc, body := h.exportDoc(xan)
	if status != 200 {
		t.Fatalf("export %d", status)
	}
	if got := header["Content-Disposition"]; len(got) != 1 || !strings.HasPrefix(got[0], "attachment; filename=\"hiyall-data-") {
		t.Fatalf("Content-Disposition %v", got)
	}
	if got := header["Content-Type"]; len(got) != 1 || !strings.HasPrefix(got[0], "application/json") {
		t.Fatalf("Content-Type %v", got)
	}
	if doc["exportVersion"] != float64(1) || doc["complete"] != true || len(list(t, doc["truncated"], "truncated")) != 0 || doc["generatedAt"] == nil {
		t.Fatalf("envelope %v %v %v", doc["exportVersion"], doc["complete"], doc["truncated"])
	}
	account := doc["account"].(map[string]any)
	if account["username"] != "xan" || account["userId"] != xan || account["ageBand"] != "adult" || account["profile"] == nil {
		t.Fatalf("account %v", account)
	}
	for _, secret := range []string{"birthDate", "birth_date", "token-token", "access_token", "ciphertext", "push_token", "latitude", "longitude"} {
		if bytes.Contains(body, []byte(secret)) {
			t.Fatalf("the export contains %q", secret)
		}
	}
	if doc["settings"].(map[string]any)["privacy"] == nil || doc["settings"].(map[string]any)["notifications"].(map[string]any)["chat"] != false {
		t.Fatalf("settings %v", doc["settings"])
	}
	// Lists, with the counts the world was built with.
	for name, want := range map[string]int{"posts": 1, "comments": 2, "reactions": 1, "saves": 1, "stories": 2, "blocks": 1, "mutes": 1, "restrictions": 0, "devices": 1, "reports": 2, "media": 3} {
		if got := len(list(t, doc[name], name)); got != want {
			t.Errorf("%s: %d items, want %d", name, got, want)
		}
	}
	if sessions := list(t, doc["sessions"], "sessions"); len(sessions) == 0 || sessions[0].(map[string]any)["sessionId"] == nil {
		t.Fatalf("sessions %v", sessions)
	}
	if n := len(list(t, doc["notifications"], "notifications")); n == 0 {
		t.Fatal("no notifications")
	}
	// People: ids and usernames; the follow of someone who blocked the member is left out.
	connections := doc["connections"].(map[string]any)
	following := list(t, connections["following"], "following")
	if len(following) != 1 || following[0].(map[string]any)["userId"] != eli || following[0].(map[string]any)["username"] != "eli" {
		t.Fatalf("following %v", following)
	}
	if len(list(t, connections["followers"], "followers")) != 1 || len(list(t, connections["friends"], "friends")) != 1 {
		t.Fatalf("connections %v", connections)
	}
	visits := doc["visits"].(map[string]any)
	if len(list(t, visits["made"], "visits made")) != 1 || visits["ownProfileVisitors"] == nil {
		t.Fatalf("visits %v", visits)
	}
	if loc := doc["location"].(map[string]any); loc["sharing"] != true || loc["updatedAt"] == nil {
		t.Fatalf("location %v", loc)
	}
	spaces := doc["spaces"].(map[string]any)
	if len(list(t, spaces["memberships"], "memberships")) != 3 || len(list(t, spaces["owned"], "owned")) != 2 || len(list(t, spaces["entries"], "entries")) != 2 {
		t.Fatalf("spaces %v", spaces)
	}
	// Reports: the member's own words and whether they shared evidence, nothing from the evidence itself.
	for _, r := range list(t, doc["reports"], "reports") {
		if _, has := r.(map[string]any)["evidence"]; has {
			t.Fatal("report evidence in the export")
		}
	}
	// Media: links, valid for 24 hours (the memory store signs without a clock; the lifetime is the caller's).
	for _, m := range list(t, doc["media"], "media") {
		item := m.(map[string]any)
		urls := item["urls"].(map[string]any)
		if item["status"] == "ready" && (urls["thumb"] == nil || urls["full"] == nil) {
			t.Fatalf("media without links: %v", item)
		}
	}
	// Chat: structure and counts only, and a note that content lives on the devices.
	chat := doc["chat"].(map[string]any)
	if note := chat["note"].(string); !strings.Contains(note, "end-to-end encrypted") || !strings.Contains(note, "only on your devices") {
		t.Fatalf("chat note %q", note)
	}
	convos := list(t, chat["conversations"], "conversations")
	if len(convos) != 2 || chat["totals"].(map[string]any)["conversations"] != float64(2) {
		t.Fatalf("chat %v", chat)
	}
	first := convos[0].(map[string]any)
	if first["conversationId"] == nil || first["peerId"] == nil || first["messagesSent"] == nil {
		t.Fatalf("conversation %v", first)
	}

	// One export a day, per member, enforced by the server.
	status, header, _, _ = h.exportDoc(xan)
	if status != 429 {
		t.Fatalf("second export %d", status)
	}
	retry, err := strconv.Atoi(strings.Join(header["Retry-After"], ""))
	if err != nil || retry < 86300 || retry > 86400 {
		t.Fatalf("Retry-After %v", header["Retry-After"])
	}
	var errBody struct {
		Error map[string]string `json:"error"`
	}
	_, _, _, again := h.exportDoc(xan)
	_ = json.Unmarshal(again, &errBody)
	if errBody.Error["code"] != "RATE_LIMITED" {
		t.Fatalf("error %v", errBody)
	}
	// Another member is not affected; after 24 hours the member can export again.
	if status, _, _, _ = h.exportDoc(eli); status != 200 {
		t.Fatalf("eli's export %d", status)
	}
	h.exec(`UPDATE users SET last_export_at=now()-interval '25 hours' WHERE user_id=$1`, xan)
	if status, _, _, _ = h.exportDoc(xan); status != 200 {
		t.Fatalf("export after a day %d", status)
	}
}

func TestExportCapsTruncateAndAFailureGivesBackTheSlot(t *testing.T) {
	w := newPurgeWorld(t)
	h := w.acctHarness
	var out bytes.Buffer
	complete, err := h.db.ExportAccount(h.ctx, xan, &out, store.ExportOptions{ListCap: 1, Sign: func(key string) string { return "https://example.test/" + key }})
	if err != nil || !complete {
		t.Fatal(complete, err)
	}
	var doc map[string]any
	if err = json.Unmarshal(out.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	truncated := list(t, doc["truncated"], "truncated")
	if len(truncated) == 0 || len(list(t, doc["comments"], "comments")) != 1 {
		t.Fatalf("truncated %v", truncated)
	}
	// A byte cap stops the lists the same way.
	out.Reset()
	if complete, err = h.db.ExportAccount(h.ctx, xan, &out, store.ExportOptions{MaxBytes: 1500}); err != nil || !complete {
		t.Fatal(complete, err)
	}
	if err = json.Unmarshal(out.Bytes(), &doc); err != nil || len(list(t, doc["truncated"], "truncated")) == 0 {
		t.Fatalf("byte cap: %v %v", err, doc["truncated"])
	}

	// A claim that was not used is handed back, so a failure never costs the member the day's export.
	prev, err := h.db.ClaimExport(h.ctx, xan)
	if err != nil || prev != nil {
		t.Fatal(prev, err)
	}
	if _, err = h.db.ClaimExport(h.ctx, xan); err == nil {
		t.Fatal("second claim allowed")
	}
	h.db.ReleaseExport(h.ctx, xan, prev)
	if _, err = h.db.ClaimExport(h.ctx, xan); err != nil {
		t.Fatalf("claim after release: %v", err)
	}
	// A client that goes away mid-download fails the export and releases the claim in the handler.
	h.exec(`UPDATE users SET last_export_at=NULL WHERE user_id=$1`, xan)
	if complete, err = h.db.ExportAccount(h.ctx, xan, failingWriter{}, store.ExportOptions{}); complete || err == nil {
		t.Fatal("a dead writer should fail the export")
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errClientGone }

var errClientGone = &clientGone{}

type clientGone struct{}

func (*clientGone) Error() string { return "client gone" }

func TestExportWithoutMediaStorageLeavesLinksOut(t *testing.T) {
	w := newPurgeWorld(t)
	w.api.Media = nil
	status, _, doc, _ := w.exportDoc(xan)
	if status != 200 {
		t.Fatalf("export %d", status)
	}
	for _, m := range list(t, doc["media"], "media") {
		if len(m.(map[string]any)["urls"].(map[string]any)) != 0 {
			t.Fatal("links without storage")
		}
	}
}
