package httpapi

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"hiyall/services/api/internal/store"
)

// openTo registers a device with a key for each member and returns them, so keys can be claimed and messages relayed.
func (h *socialHarness) devicesFor(users ...string) map[string]testDevice {
	h.t.Helper()
	out := map[string]testDevice{}
	for i, u := range users {
		d := h.register(u)
		h.expect(h.send(u, "POST", "/v1/devices/"+d.id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{d.oneTimeKey(fmt.Sprintf("k%d", i))}}), 200, "")
		out[u] = d
	}
	return out
}

// Anyone who is not blocked and is in the same age band can message anyone: no friendship, and whatever the follow
// state between them (none, pending, active, in either direction).
func TestStrangersCanMessageWithoutFriendshipOrFollow(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(dev, "followPolicy", "approval") // so alice's follow of dev is only pending
	devices := h.devicesFor(alice, cara, dev, eli, xan, yui)
	states := map[string]string{
		cara: "no follow at all",
		dev:  "a pending follow request",
		eli:  "an active follow",
		xan:  "they follow alice",
		yui:  "alice follows and they follow back",
	}
	h.expect(h.call(alice, "POST", "/v1/users/"+dev+"/follow"), 200, "")
	h.expect(h.call(alice, "POST", "/v1/users/"+eli+"/follow"), 200, "")
	h.expect(h.call(xan, "POST", "/v1/users/"+alice+"/follow"), 200, "")
	h.expect(h.call(alice, "POST", "/v1/users/"+yui+"/follow"), 200, "")
	h.expect(h.call(yui, "POST", "/v1/users/"+alice+"/follow"), 200, "")
	if rel := h.relationship(alice, dev); rel["following"] != "pending" || rel["friendship"] != "none" {
		t.Fatalf("the pending case is not pending: %v", rel)
	}
	for peer, state := range states {
		if rel := h.relationship(alice, peer); rel["friendship"] != "none" {
			t.Fatalf("%s: already friends: %v", state, rel)
		}
		// Devices, a key claim, the conversation, a message each way and the inbox: nothing asks for a friend or a follow.
		h.expect(h.call(alice, "GET", "/v1/users/"+peer+"/devices"), 200, "")
		h.expect(h.call(alice, "POST", "/v1/users/"+peer+"/devices/"+devices[peer].id+"/claim"), 200, "")
		convo := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": peer}), 200, "").data["conversationId"].(string)
		path := "/v1/conversations/" + convo
		h.expect(h.send(alice, "POST", path+"/messages", message(devices[alice], devices[peer])), 200, "")
		if got := items(h.ok(peer, "GET", "/v1/devices/"+devices[peer].id+"/inbox")); len(got) != 1 {
			t.Fatalf("%s: the stranger's message was not delivered: %v", state, got)
		}
		h.expect(h.send(peer, "POST", path+"/messages", message(devices[peer], devices[alice])), 200, "")
		if list := items(h.ok(peer, "GET", "/v1/conversations")); len(list) != 1 {
			t.Fatalf("%s: the recipient does not see the conversation", state)
		}
		if rel := h.relationship(alice, peer); rel["friendship"] != "none" {
			t.Fatalf("%s: messaging created a friendship: %v", state, rel)
		}
	}
	// A member can also be messaged by a stranger who has been refused a friend request.
	h.expect(h.send(cara, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "")
}

// Blocks and the age-band barrier still refuse messaging, exactly like before.
func TestOpenMessagingStillStopsAtBlocksAndAgeBands(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	h.ageAt(eli, 16)
	h.ageAt(cara, 30)
	devices := h.devicesFor(alice, cara, dev, eli, xan)
	open := func(from, to string) reply {
		return h.send(from, "POST", "/v1/conversations", map[string]string{"userId": to})
	}
	// Same band: a stranger minor to a minor, an adult to an adult.
	h.expect(open(dev, eli), 200, "")
	h.expect(open(cara, alice), 200, "")
	// Cross band, both directions: refused like a block, and nothing about age is said.
	for _, pair := range [][2]string{{dev, cara}, {cara, dev}, {dev, alice}, {eli, xan}} {
		got := open(pair[0], pair[1])
		h.expect(got, 404, "NOT_FOUND")
		h.expect(h.call(pair[0], "GET", "/v1/users/"+pair[1]+"/devices"), 404, "NOT_FOUND")
	}
	h.expect(h.call(dev, "POST", "/v1/users/"+cara+"/devices/"+devices[cara].id+"/claim"), 404, "NOT_FOUND")
	// A block, with isolation off or on.
	h.expect(h.call(xan, "POST", "/v1/users/"+alice+"/block"), 200, "")
	h.expect(open(alice, xan), 404, "NOT_FOUND")
	h.expect(open(xan, alice), 404, "NOT_FOUND")
	off := newSocialHarnessWith(t, store.WithAgeBandIsolation(false))
	off.ageAt(dev, 15)
	off.ageAt(cara, 30)
	off.expect(off.send(dev, "POST", "/v1/conversations", map[string]string{"userId": cara}), 200, "")
	off.expect(off.call(cara, "POST", "/v1/users/"+dev+"/block"), 200, "")
	off.expect(off.send(dev, "POST", "/v1/conversations", map[string]string{"userId": cara}), 404, "NOT_FOUND")
	// Reports still work on a conversation that was opened by a stranger.
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": alice, "reasonCode": "spam"}), 201, "")
}

// Members who chose another setting through the API are still honoured; nothing in the app sets them.
func TestMessagesFromSettingsAreStillHonoured(t *testing.T) {
	h := newSocialHarness(t)
	h.devicesFor(alice, bob, cara, dev)
	open := func(from, to string) reply {
		return h.send(from, "POST", "/v1/conversations", map[string]string{"userId": to})
	}
	// friends: only friends.
	h.policy(bob, "messagesFrom", "friends")
	h.expect(open(alice, bob), 403, "MESSAGES_NOT_ALLOWED")
	h.expect(h.call(alice, "GET", "/v1/users/"+bob+"/devices"), 403, "MESSAGES_NOT_ALLOWED")
	h.ok(alice, "POST", "/v1/users/"+bob+"/friend-requests")
	h.ok(bob, "POST", "/v1/users/"+alice+"/friend-requests")
	h.expect(open(alice, bob), 200, "")
	// nobody: not even a friend, until they have written first.
	h.policy(cara, "messagesFrom", "nobody")
	h.expect(open(alice, cara), 403, "MESSAGES_NOT_ALLOWED")
	h.expect(open(bob, cara), 403, "MESSAGES_NOT_ALLOWED")
	// followers: a follow is enough, a stranger is not.
	h.policy(dev, "messagesFrom", "followers")
	h.expect(open(alice, dev), 403, "MESSAGES_NOT_ALLOWED")
	h.ok(alice, "POST", "/v1/users/"+dev+"/follow")
	h.expect(open(alice, dev), 200, "")
	// Back to everyone: the stranger may.
	h.policy(cara, "messagesFrom", "everyone")
	h.expect(open(alice, cara), 200, "")
}

// Opening a conversation with someone you have never exchanged a message with has its own budget: a burst of 10, then
// one a minute, on top of the general limits.
func TestNewConversationsHaveATighterBudget(t *testing.T) {
	h := newSocialHarness(t)
	var strangers []string
	for i := 0; i < 14; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 900+i)
		h.user(id, fmt.Sprintf("stranger_%d", i))
		strangers = append(strangers, id)
	}
	phone := h.register(alice)
	other := h.register(strangers[0])
	open := func(from, to string) (int, string, string) {
		status, header, raw := h.full(from, "POST", "/v1/conversations", "application/json", `{"userId":"`+to+`"}`)
		return status, header.Get("Retry-After"), string(raw)
	}
	for i := 0; i < 10; i++ {
		if status, _, raw := open(alice, strangers[i]); status != 200 {
			t.Fatalf("conversation %d: %d %s", i+1, status, raw)
		}
	}
	status, retry, raw := open(alice, strangers[10])
	if status != 429 || retry != "60" || !strings.Contains(raw, `"RATE_LIMITED"`) {
		t.Fatalf("the eleventh new conversation: %d retry=%q %s", status, retry, raw)
	}
	// The general graph limit is a separate budget and is nowhere near used.
	h.expect(h.call(alice, "GET", "/v1/me/friends"), 200, "")
	// A conversation that has held messages is not a new contact: reopening it is not limited.
	h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": strangers[0]}), 429, "RATE_LIMITED")
	h.api.firstChats.reset(alice)
	h.api.graph.reset(alice)
	convo := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": strangers[0]}), 200, "").data["conversationId"].(string)
	h.expect(h.send(alice, "POST", "/v1/conversations/"+convo+"/messages", message(phone, other)), 200, "")
	h.api.graph.reset(alice)
	for i := 0; i < 10; i++ { // use the new-contact budget up again
		open(alice, strangers[i+1])
	}
	if status, _, _ := open(alice, strangers[13]); status != 429 {
		t.Fatalf("a new stranger after the budget: %d", status)
	}
	if status, _, raw := open(alice, strangers[0]); status != 200 {
		t.Fatalf("reopening a conversation with messages was limited: %d %s", status, raw)
	}
	// The reply direction is a conversation that has messages too.
	if status, _, raw := open(strangers[0], alice); status != 200 {
		t.Fatalf("the recipient opening it: %d %s", status, raw)
	}
	// Per account: someone else has a full budget.
	if status, _, raw := open(cara, strangers[11]); status != 200 {
		t.Fatalf("another account: %d %s", status, raw)
	}
	// Refused attempts (a block, another band) are not free: they use the budget like any other.
	h.api.firstChats.reset(dev)
	h.api.graph.reset(dev)
	h.ageAt(dev, 15)
	for i := 0; i < 10; i++ {
		if status, _, _ := open(dev, strangers[i]); status != 404 {
			t.Fatalf("a minor opening an adult: %d", status)
		}
	}
	if status, _, _ := open(dev, strangers[12]); status != 429 {
		t.Fatalf("refused attempts did not use the budget: %d", status)
	}
}

// A follow is instant by default; a member whose policy says approval still gets requests to approve; and none of it
// has anything to do with messaging.
func TestFollowsAreInstantByDefaultAndApprovalStillWorks(t *testing.T) {
	h := newSocialHarness(t)
	if got := h.ok(bob, "GET", "/v1/me/privacy")["followPolicy"]; got != "everyone" {
		t.Fatalf("default followPolicy %v", got)
	}
	h.ok(alice, "POST", "/v1/notifications/read-all")
	h.ok(bob, "POST", "/v1/notifications/read-all")
	if got := h.ok(alice, "POST", "/v1/users/"+bob+"/follow")["following"]; got != "active" {
		t.Fatalf("a follow with the default policy is %v", got)
	}
	same(t, ids(h.ok(bob, "GET", "/v1/notifications")), alice+":follow.started")
	if rel := h.relationship(alice, bob); rel["following"] != "active" || rel["friendship"] != "none" {
		t.Fatalf("relationship %v", rel)
	}
	same(t, ids(h.ok(bob, "GET", "/v1/me/followers")), alice)
	same(t, ids(h.ok(bob, "GET", "/v1/me/follow-requests")))
	// Approval path for a member who asks for it.
	h.policy(cara, "followPolicy", "approval")
	if got := h.ok(alice, "POST", "/v1/users/"+cara+"/follow")["following"]; got != "pending" {
		t.Fatalf("a follow with policy approval is %v", got)
	}
	same(t, ids(h.ok(cara, "GET", "/v1/notifications")), alice+":follow.requested")
	h.ok(cara, "POST", "/v1/users/"+alice+"/follow-requests/accept")
	same(t, ids(h.ok(cara, "GET", "/v1/me/followers")), alice)
	// nobody still refuses.
	h.policy(dev, "followPolicy", "nobody")
	h.expect(h.call(alice, "POST", "/v1/users/"+dev+"/follow"), 403, "FOLLOW_NOT_ALLOWED")
	// And a follow, instant or not, never changes whether someone can message.
	h.devicesFor(alice, bob, cara)
	h.expect(h.send(cara, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "")
}

// 0019 makes messaging and follows open for every existing row (minors included), adds the counts audience, bumps the
// version only where something changed, creates the visit tables with a zero backfill, and changes nothing when run again.
func TestMigration0019OpensMessagingAndFollowsAndCreatesVisitTables(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0019_open_messaging_visitors.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	const a, b, c, d, e, f = "019a4000-0000-7000-8000-000000000e01", "019a4000-0000-7000-8000-000000000e02", "019a4000-0000-7000-8000-000000000e03", "019a4000-0000-7000-8000-000000000e04", "019a4000-0000-7000-8000-000000000e05", "019a4000-0000-7000-8000-000000000e06"
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_19`,
		`SET LOCAL search_path = migration_scratch_19`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`CREATE TABLE privacy_settings(user_id uuid PRIMARY KEY REFERENCES users(user_id), data jsonb NOT NULL, version bigint NOT NULL DEFAULT 1, updated_at timestamptz NOT NULL DEFAULT '2020-01-01')`,
		`INSERT INTO users VALUES ('` + a + `'),('` + b + `'),('` + c + `'),('` + d + `'),('` + e + `'),('` + f + `')`,
		`INSERT INTO privacy_settings(user_id,data,version) VALUES
 ('` + a + `','{"messagesFrom":"friends","followPolicy":"approval","onlineAudience":"nobody","fieldAudiences":{"location":"friends","vibe":"everyone"}}',3),
 ('` + b + `','{"messagesFrom":"everyone","followPolicy":"everyone","fieldAudiences":{"counts":"nobody"}}',9),
 ('` + c + `','{"messagesFrom":"everyone","followPolicy":"approval","fieldAudiences":{"counts":"everyone"}}',2),
 ('` + d + `','{"messagesFrom":"nobody","followPolicy":"nobody","customKey":"kept","fieldAudiences":{"gender":"friends"}}',5),
 ('` + e + `','{"profileAudience":"public"}',1),
 ('` + f + `','{"messagesFrom":"followers","followPolicy":"everyone","fieldAudiences":{"counts":"friends"}}',4)`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := func() string {
		rows, err := tx.Query(ctx, `SELECT user_id::text||' v'||version||' '||(data->>'messagesFrom')||' '||(data->>'followPolicy')||' '||(data->'fieldAudiences')::text||' '||coalesce(data->>'customKey','')||' '||(updated_at>'2021-01-01')::text FROM privacy_settings ORDER BY user_id`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var line string
			_ = rows.Scan(&line)
			out = append(out, line)
		}
		return strings.Join(out, "\n")
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("migration: %v", err)
	}
	first := snapshot()
	for _, want := range []string{
		a + ` v4 everyone everyone {"vibe": "everyone", "counts": "everyone", "location": "friends"} `, // everything changed
		b + ` v9 everyone everyone {"counts": "nobody"} `,                                              // already open and chose counts: untouched, version unchanged
		c + ` v3 everyone everyone {"counts": "everyone"} `,                                            // only the follow policy changed
		d + ` v6 everyone everyone {"counts": "everyone", "gender": "friends"} kept`,                   // other keys kept
		e + ` v2 everyone everyone {"counts": "everyone"} `,                                            // no audiences at all
		f + ` v5 everyone everyone {"counts": "friends"} `,                                             // their own counts choice kept
	} {
		if !strings.Contains(first, want) {
			t.Fatalf("after the migration:\n%s\nmissing %q", first, want)
		}
	}
	if !strings.Contains(first, b+" v9 everyone everyone {\"counts\": \"nobody\"}  false") {
		t.Fatalf("an unchanged row was rewritten:\n%s", first)
	}
	// The privacy rewrite is the part before the tables (those are created once by the migration runner); run again, it changes nothing.
	rewrite := string(migration)[:strings.Index(string(migration), "CREATE TABLE profile_visits")]
	if _, err = tx.Exec(ctx, rewrite); err != nil {
		t.Fatal(err)
	}
	if second := snapshot(); second != first {
		t.Fatalf("running it again changed rows:\n%s\n--\n%s", first, second)
	}

	// The tables: one row per pair, never oneself, 8 counter slots, a zero backfill for every member.
	var counters, nonZero int
	if err = tx.QueryRow(ctx, `SELECT count(*),count(*) FILTER (WHERE visitors<>0) FROM profile_visit_counts`).Scan(&counters, &nonZero); err != nil || counters != 6 || nonZero != 0 {
		t.Fatalf("backfill: %d counters, %d non-zero (%v)", counters, nonZero, err)
	}
	for _, statement := range []string{
		`SAVEPOINT s; INSERT INTO profile_visits(profile_id,visitor_id) VALUES('` + a + `','` + a + `')`,
		`SAVEPOINT s; INSERT INTO profile_visits(profile_id,visitor_id) VALUES('` + a + `','019a4000-0000-7000-8000-0000000fffff')`,
		`SAVEPOINT s; INSERT INTO profile_visit_counts(profile_id,slot,visitors) VALUES('` + a + `',8,1)`,
		`SAVEPOINT s; INSERT INTO profile_visit_counts(profile_id,slot,visitors) VALUES('` + a + `',-1,1)`,
		`SAVEPOINT s; INSERT INTO profile_visit_counts(profile_id,slot,visitors) VALUES('` + a + `',1,-1)`,
	} {
		if _, err = tx.Exec(ctx, statement); err == nil {
			t.Fatalf("accepted: %s", statement)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, `INSERT INTO profile_visits(profile_id,visitor_id) VALUES('`+a+`','`+b+`')`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SAVEPOINT s; INSERT INTO profile_visits(profile_id,visitor_id) VALUES('`+a+`','`+b+`')`); err == nil {
		t.Fatal("a pair was recorded twice")
	}
	if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	// Deleting a member removes their visit rows; the all-time count stays.
	if _, err = tx.Exec(ctx, `UPDATE profile_visit_counts SET visitors=1 WHERE profile_id=$1 AND slot=0`, a); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO profile_visits(profile_id,visitor_id) VALUES('`+c+`','`+a+`')`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM privacy_settings WHERE user_id=$1`, a); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM users WHERE user_id=$1`, a); err != nil {
		t.Fatal(err)
	}
	var left int
	if err = tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM profile_visits WHERE visitor_id=$1 OR profile_id=$1)+(SELECT count(*) FROM profile_visit_counts WHERE profile_id=$1)`, a).Scan(&left); err != nil || left != 0 {
		t.Fatalf("%d rows outlive the member (%v)", left, err)
	}
	_ = tx.Rollback(ctx)
	var exists bool
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_19.profile_visits') IS NOT NULL`).Scan(&exists); err != nil || exists {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
