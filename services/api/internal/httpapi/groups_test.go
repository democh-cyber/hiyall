package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Group chat over HTTP against PostgreSQL (docs/api/29-group-chat.md).

const (
	gm1 = "019a4000-0000-7000-8000-0000000001a1"
	gm2 = "019a4000-0000-7000-8000-0000000001a2"
	gm3 = "019a4000-0000-7000-8000-0000000001a3"
	gm4 = "019a4000-0000-7000-8000-0000000001a4"
)

type groupEnv struct {
	*socialHarness
	chat  *media.Memory
	dev   map[string][]testDevice
	users []string
}

// newGroupEnv makes eleven adult members who accept messages from anyone, each with one chat device (alice has two).
func newGroupEnv(t *testing.T, opts ...store.Option) *groupEnv {
	t.Helper()
	h := newSocialHarnessWith(t, opts...)
	for i, id := range []string{gm1, gm2, gm3, gm4} {
		h.user(id, fmt.Sprintf("gm%d", i+1))
	}
	e := newGroupEnvOn(t, h, alice, bob, cara, dev, eli, xan, yui, gm1, gm2, gm3, gm4)
	e.dev[alice] = append(e.dev[alice], h.register(alice))
	return e
}

// newGroupEnvOn is the environment over an existing harness and its members: adults who accept messages from anyone,
// each with one chat device.
func newGroupEnvOn(t *testing.T, h *socialHarness, users ...string) *groupEnv {
	t.Helper()
	e := &groupEnv{socialHarness: h, chat: media.NewMemory(), dev: map[string][]testDevice{}, users: users}
	h.api.ChatMedia = e.chat
	for _, u := range users {
		h.policy(u, "messagesFrom", "everyone")
		h.policy(u, "followPolicy", "everyone")
		h.setAge(u, 30)
		e.dev[u] = []testDevice{h.register(u)}
	}
	return e
}

func (e *groupEnv) count(query string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.db.Pool.QueryRow(e.ctx, query, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

// do is send with the per-account limiters reset first: a test makes far more requests than a person.
func (e *groupEnv) do(actor, method, path string, payload any) reply {
	e.t.Helper()
	for _, l := range []*keyedLimiter{e.api.graph, e.api.lists, e.api.messages, e.api.auxMessages, e.api.firstChats, e.api.blobSlots, e.api.blobURLs} {
		l.reset(actor)
	}
	return e.send(actor, method, path, payload)
}

// chatWith opens a direct conversation (so the two know each other as Chatting).
func (e *groupEnv) chatWith(a, b string) {
	e.t.Helper()
	e.expect(e.do(a, "POST", "/v1/conversations", map[string]string{"userId": b}), 200, "")
}

func (e *groupEnv) create(creator, name string, members ...string) reply {
	e.t.Helper()
	for _, m := range members {
		e.chatWith(creator, m)
	}
	return e.do(creator, "POST", "/v1/groups", map[string]any{"name": name, "memberIds": members})
}

func (e *groupEnv) devicesOf(users ...string) []testDevice {
	var out []testDevice
	for _, u := range users {
		out = append(out, e.dev[u]...)
	}
	return out
}

func (e *groupEnv) activeMembers(group string) []string {
	e.t.Helper()
	rows, err := e.db.Pool.Query(e.ctx, `SELECT user_id::text FROM chat_group_members WHERE conversation_id=$1 AND state='active' ORDER BY joined_at,user_id`, group)
	if err != nil {
		e.t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			e.t.Fatal(err)
		}
		out = append(out, id)
	}
	return out
}

// sealFor is a message (or control message) from sender's first device to every device of the group's active members,
// the sending device excepted, plus extra users' devices.
func (e *groupEnv) sealFor(group, sender string, extra ...string) map[string]any {
	e.t.Helper()
	var to []testDevice
	for _, u := range append(e.activeMembers(group), extra...) {
		for _, d := range e.dev[u] {
			if d.id != e.dev[sender][0].id {
				to = append(to, d)
			}
		}
	}
	return message(e.dev[sender][0], dedupe(to)...)
}

func dedupe(devices []testDevice) []testDevice {
	seen := map[string]bool{}
	var out []testDevice
	for _, d := range devices {
		if !seen[d.id] {
			seen[d.id] = true
			out = append(out, d)
		}
	}
	return out
}

// accept answers an invite with the join message the app would send.
func (e *groupEnv) accept(user, group string) reply {
	e.t.Helper()
	return e.do(user, "POST", "/v1/groups/"+group+"/accept", map[string]any{"control": e.sealFor(group, user)})
}

// formed creates a group and has every invitee accept, in the order given.
func (e *groupEnv) formed(creator, name string, members ...string) string {
	e.t.Helper()
	id := e.expect(e.create(creator, name, members...), 201, "").data["groupId"].(string)
	for _, m := range members {
		e.expect(e.accept(m, id), 200, "")
	}
	return id
}

func (e *groupEnv) post(sender, group string) reply {
	e.t.Helper()
	return e.do(sender, "POST", "/v1/conversations/"+group+"/messages", e.sealFor(group, sender))
}

func (e *groupEnv) inbox(user string, device testDevice) []map[string]any {
	e.t.Helper()
	e.api.chatInbox.reset(user)
	return items(e.expect(e.send(user, "GET", "/v1/devices/"+device.id+"/inbox", nil), 200, "").data)
}

func (e *groupEnv) group(user, id string) map[string]any {
	e.t.Helper()
	return e.expect(e.do(user, "GET", "/v1/groups/"+id, nil), 200, "").data
}

func memberIDs(g map[string]any) []string {
	var out []string
	for _, m := range g["members"].([]any) {
		out = append(out, m.(map[string]any)["userId"].(string))
	}
	return out
}

func TestGroupLifecycleCreateInviteAcceptSendAndRead(t *testing.T) {
	e := newGroupEnv(t)
	created := e.expect(e.create(alice, "weekend crew", bob, cara), 201, "").data
	id := created["groupId"].(string)
	if created["conversationId"] != id || created["kind"] != "group" || created["name"] != "weekend crew" || created["ownerId"] != alice || created["status"] != "active" || created["myState"] != "active" {
		t.Fatalf("created group: %v", created)
	}
	if got := memberIDs(created); fmt.Sprint(got) != fmt.Sprint([]string{alice}) {
		t.Fatalf("only the creator is active: %v", got)
	}
	if n := len(created["pending"].([]any)); n != 2 {
		t.Fatalf("pending invites: %v", created["pending"])
	}
	limits := created["limits"].(map[string]any)
	if limits["maxMembers"] != float64(10) || limits["inviteExpiryDays"] != float64(7) {
		t.Fatalf("limits: %v", limits)
	}

	// The invited person sees the invite, no content, the people already in it, and can read the group.
	invites := items(e.expect(e.do(bob, "GET", "/v1/groups/invites", nil), 200, "").data)
	if len(invites) != 1 || invites[0]["groupId"] != id || invites[0]["name"] != "weekend crew" || invites[0]["memberCount"] != float64(1) ||
		invites[0]["invitedBy"].(map[string]any)["userId"] != alice {
		t.Fatalf("invites: %v", invites)
	}
	if got := e.group(bob, id); got["myState"] != "invited" || len(got["pending"].([]any)) != 0 || got["events"] != nil {
		t.Fatalf("an invitee sees the group without pending people or events: %v", got)
	}
	// An invited person is not in the group: no list entry, no messages, no blobs.
	if got := items(e.expect(e.do(bob, "GET", "/v1/groups", nil), 200, "").data); len(got) != 0 {
		t.Fatalf("an invite is not in the list: %v", got)
	}
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", e.sealFor(id, bob, alice)), 404, "NOT_FOUND")
	// Nobody else can see the group at all.
	e.expect(e.do(dev, "GET", "/v1/groups/"+id, nil), 404, "NOT_FOUND")
	e.expect(e.do(dev, "POST", "/v1/groups/"+id+"/accept", map[string]any{"control": e.sealFor(id, dev)}), 404, "NOT_FOUND")

	// Accepting needs the join message sealed for exactly the devices of the people already in the group.
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/accept", map[string]any{"control": message(e.dev[bob][0], e.dev[alice][0])}), 409, "DEVICES_CHANGED")
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/accept", map[string]any{}), 422, "VALIDATION")
	joined := e.expect(e.accept(bob, id), 200, "").data
	if got := memberIDs(joined); fmt.Sprint(got) != fmt.Sprint([]string{alice, bob}) || joined["myState"] != "active" {
		t.Fatalf("after bob joined: %v", got)
	}
	// Replaying the accept is not a second join: the invite is gone.
	e.expect(e.accept(bob, id), 404, "NOT_FOUND")
	e.expect(e.accept(cara, id), 200, "")

	// The join message reached the people who were in the group, on every device, as an auxiliary message.
	for _, d := range e.dev[alice] {
		in := e.inbox(alice, d)
		if len(in) != 2 || in[0]["aux"] != true || in[0]["conversationId"] != id || in[0]["senderId"] != bob {
			t.Fatalf("alice's device %s got %v", d.id, in)
		}
	}
	if in := e.inbox(bob, e.dev[bob][0]); len(in) != 1 || in[0]["senderId"] != cara {
		t.Fatalf("bob sees only what was sent after he joined: %v", in)
	}
	if in := e.inbox(cara, e.dev[cara][0]); len(in) != 0 {
		t.Fatalf("cara sees nothing from before she joined: %v", in)
	}

	// A message needs an envelope for every device of every member (and the sender's other devices).
	e.expect(e.do(alice, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[alice][0], e.dev[bob][0])), 409, "DEVICES_CHANGED")
	e.expect(e.do(alice, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[alice][0], e.dev[bob][0], e.dev[cara][0])), 409, "DEVICES_CHANGED") // alice's second device missing
	sent := e.expect(e.post(alice, id), 200, "").data
	if sent["messageId"] == nil || sent["createdAt"] == nil {
		t.Fatalf("send: %v", sent)
	}
	// Idempotent by message id; another sender cannot take the id.
	m := e.sealFor(id, bob)
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", m), 200, "")
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", m), 200, "")
	m2 := e.sealFor(id, cara)
	m2["messageId"] = m["messageId"]
	e.expect(e.do(cara, "POST", "/v1/conversations/"+id+"/messages", m2), 422, "VALIDATION")

	// The relay stores one envelope per device, the ciphertext is gone once acknowledged, and unread counts follow the members.
	var stored int
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT count(*) FROM message_envelopes e JOIN messages m USING(message_id) WHERE m.message_id=$1`, sent["messageId"]).Scan(&stored); err != nil || stored != 3 {
		t.Fatalf("envelopes of alice's message: %d %v", stored, err)
	}
	unread := func(u string) float64 {
		return e.expect(e.do(u, "GET", "/v1/conversations/unread", nil), 200, "").data["messages"].(float64)
	}
	if unread(bob) != 0 || unread(cara) != 2 || unread(alice) != 1 {
		t.Fatalf("unread alice %v bob %v cara %v", unread(alice), unread(bob), unread(cara))
	}
	in := e.inbox(bob, e.dev[bob][0])
	var ids []string
	for _, i := range in {
		ids = append(ids, i["messageId"].(string))
	}
	e.expect(e.send(bob, "POST", "/v1/devices/"+e.dev[bob][0].id+"/inbox/ack", map[string]any{"messageIds": ids}), 200, "")
	var left int
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT count(*) FROM message_envelopes WHERE recipient_device_id=$1 AND ciphertext IS NOT NULL`, e.dev[bob][0].id).Scan(&left); err != nil || left != 0 {
		t.Fatalf("ciphertext left after ack: %d %v", left, err)
	}
	// Reading moves only the caller's pointer; no receipts exist.
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/read", map[string]any{"readAt": time.Now().Add(time.Second).UTC().Format(time.RFC3339Nano)}), 200, "")
	if unread(bob) != 0 || unread(cara) != 2 {
		t.Fatalf("after bob read: bob %v cara %v", unread(bob), unread(cara))
	}
	// The list carries the group with its members for every member.
	list := items(e.expect(e.do(cara, "GET", "/v1/groups", nil), 200, "").data)
	if len(list) != 1 || list[0]["memberCount"] != float64(3) || list[0]["unreadCount"] != float64(2) {
		t.Fatalf("cara's list: %v", list)
	}
	// A direct conversation list never shows a group.
	for _, c := range items(e.expect(e.do(cara, "GET", "/v1/conversations", nil), 200, "").data) {
		if c["conversationId"] == id {
			t.Fatal("a group appeared in the direct conversation list")
		}
	}
	e.expect(e.do(cara, "GET", "/v1/conversations/"+id, nil), 404, "NOT_FOUND")
}

func TestGroupCreationRulesAndLimits(t *testing.T) {
	e := newGroupEnv(t)
	for _, c := range []struct {
		name string
		body map[string]any
	}{
		{"one invitee", map[string]any{"memberIds": []string{bob}}},
		{"ten invitees", map[string]any{"memberIds": []string{bob, cara, dev, eli, xan, yui, gm1, gm2, gm3, gm4}}},
		{"duplicate", map[string]any{"memberIds": []string{bob, bob}}},
		{"not an id", map[string]any{"memberIds": []string{bob, "x"}}},
		{"no members", map[string]any{"name": "x"}},
		{"unknown field", map[string]any{"memberIds": []string{bob, cara}, "admin": true}},
		{"long name", map[string]any{"name": strings.Repeat("a", 41), "memberIds": []string{bob, cara}}},
		{"control characters in the name", map[string]any{"name": "a‮b", "memberIds": []string{bob, cara}}},
		{"newline in the name", map[string]any{"name": "a\nb", "memberIds": []string{bob, cara}}},
	} {
		if r := e.do(alice, "POST", "/v1/groups", c.body); r.status != 422 || r.code != "VALIDATION" {
			t.Fatalf("%s: %d %s", c.name, r.status, r.code)
		}
	}
	// Yourself is not someone to invite.
	e.chatWith(alice, bob)
	e.chatWith(alice, cara)
	if r := e.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{alice, bob}}); r.status != 409 || r.code != "CANNOT_ADD_MEMBER" {
		t.Fatalf("self: %d %s", r.status, r.code)
	}
	// A name is optional, 40 characters fit (counted in characters), and it is stored normalised.
	none := e.expect(e.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara}}), 201, "").data
	if none["name"] != "" {
		t.Fatalf("no name: %v", none["name"])
	}
	long := e.expect(e.do(alice, "POST", "/v1/groups", map[string]any{"name": "  " + strings.Repeat("é", 40) + "  ", "memberIds": []string{bob, cara}}), 201, "").data
	if long["name"] != strings.Repeat("é", 40) {
		t.Fatalf("a 40 character name: %v", long["name"])
	}
	// Only people the creator chats with or follows: a stranger is "cannot be added", naming them and nothing else.
	r := e.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, dev}})
	if r.status != 409 || r.code != "CANNOT_ADD_MEMBER" {
		t.Fatalf("a stranger: %d %s", r.status, r.code)
	}
	// Following is enough.
	e.expect(e.do(alice, "POST", "/v1/users/"+dev+"/follow", nil), 200, "")
	e.expect(e.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, dev}}), 201, "")
}

func TestGroupCannotBeJoinedAcrossBlocksBandsOrPrivacyAndSaysNothingAboutWhy(t *testing.T) {
	e := newGroupEnv(t)
	for _, u := range []string{bob, cara, dev, eli} {
		e.chatWith(alice, u)
	}
	bodyOf := func(r reply) string { return fmt.Sprint(r.status, r.code) }
	refused := func(what string, members ...string) string {
		t.Helper()
		status, _, raw := (&blobEnv{socialHarness: e.socialHarness}).full(alice, "POST", "/v1/groups", "application/json", fmt.Sprintf(`{"memberIds":["%s"]}`, strings.Join(members, `","`)))
		if status != 409 || !strings.Contains(string(raw), `"CANNOT_ADD_MEMBER"`) {
			t.Fatalf("%s: %d %s", what, status, raw)
		}
		// Only the person is named: nothing about why.
		for _, leak := range []string{"block", "age band", "privacy", "limit", "band", "follow"} {
			if strings.Contains(strings.ToLower(string(raw)), leak) {
				t.Fatalf("%s leaks %q: %s", what, leak, raw)
			}
		}
		return string(raw)
	}
	// The creator blocks, or is blocked by, an invitee.
	e.expect(e.do(alice, "POST", "/v1/users/"+dev+"/block", nil), 200, "")
	a := refused("blocked by the creator", bob, dev)
	e.expect(e.do(alice, "DELETE", "/v1/users/"+dev+"/block", nil), 200, "")
	e.chatWith(alice, dev)
	e.expect(e.do(eli, "POST", "/v1/users/"+alice+"/block", nil), 200, "")
	b := refused("blocked by the invitee", bob, eli)
	e.expect(e.do(eli, "DELETE", "/v1/users/"+alice+"/block", nil), 200, "")
	e.chatWith(alice, eli)
	// A block between two invitees refuses the add too, and names one of them.
	e.expect(e.do(bob, "POST", "/v1/users/"+cara+"/block", nil), 200, "")
	c := refused("blocked between two invitees", bob, cara)
	e.expect(e.do(bob, "DELETE", "/v1/users/"+cara+"/block", nil), 200, "")
	// Another age band (isolation is on by default).
	e.setAge(dev, 16)
	d := refused("another age band", bob, dev)
	e.setAge(dev, 30)
	// The invitee's own messagesFrom choice.
	e.policy(eli, "messagesFrom", "nobody")
	f := refused("messagesFrom nobody", bob, eli)
	e.policy(eli, "messagesFrom", "everyone")
	// The reasons give the same answer apart from the person named.
	for _, s := range []string{a, b, c, d, f} {
		if !strings.Contains(s, "This person can’t be added to the group.") {
			t.Fatalf("the refusal differs: %s", s)
		}
	}
	// With everything lifted the same people can be added.
	e.expect(e.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara, dev, eli}}), 201, "")
	_ = bodyOf
}

func TestGroupsHonourAgeBandIsolationSetting(t *testing.T) {
	// Isolation on: all minors or all adults. Isolation off: the rule is off with it, as for every other feature.
	on := newGroupEnv(t)
	on.setAge(alice, 16)
	on.setAge(bob, 16)
	on.setAge(cara, 16)
	on.setAge(dev, 40)
	on.chatWith(alice, bob)
	on.chatWith(alice, cara)
	on.expect(on.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara}}), 201, "")
	for _, u := range []string{bob, cara, dev} {
		on.policy(u, "messagesFrom", "everyone")
	}
	if r := on.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, dev}}); r.status != 409 || r.code != "CANNOT_ADD_MEMBER" {
		t.Fatalf("a minor group with an adult, isolation on: %d %s", r.status, r.code)
	}
	// Two adults and a minor: also refused (the minor is barred from the adults).
	on.setAge(alice, 30)
	if r := on.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, dev}}); r.status != 409 {
		t.Fatalf("an adult group with a minor: %d %s", r.status, r.code)
	}

	off := newGroupEnvIsolationOff(t)
	off.chatWith(alice, bob)
	off.chatWith(alice, dev)
	off.expect(off.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, dev}}), 201, "")
}

func newGroupEnvIsolationOff(t *testing.T) *groupEnv {
	t.Helper()
	e := newGroupEnv(t, store.WithAgeBandIsolation(false))
	e.setAge(alice, 16)
	e.setAge(bob, 40)
	e.setAge(dev, 16)
	return e
}

func TestGroupSizeAndPerMemberAndDailyLimits(t *testing.T) {
	e := newGroupEnv(t)
	// Ten people is the most: nine invitees fit, and invites count towards the ten.
	id := e.expect(e.create(alice, "big", bob, cara, dev, eli, xan, yui, gm1, gm2, gm3), 201, "").data["groupId"].(string)
	e.chatWith(alice, gm4)
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{gm4}}), 409, "GROUP_FULL")
	// Declining makes room.
	e.expect(e.do(gm3, "POST", "/v1/groups/"+id+"/decline", nil), 200, "")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{gm4}}), 200, "")
	// Everyone accepts: ten active members, and a message carries up to 19+ envelopes.
	for _, u := range []string{bob, cara, dev, eli, xan, yui, gm1, gm2, gm4} {
		e.expect(e.accept(u, id), 200, "")
	}
	g := e.group(alice, id)
	if len(memberIDs(g)) != 10 || g["memberCount"] != float64(10) {
		t.Fatalf("ten members: %v", memberIDs(g))
	}
	e.expect(e.post(alice, id), 200, "")
	e.expect(e.post(gm4, id), 200, "")

	// Groups a member is in or invited to: the cap comes from the member's entitlements.
	f := newGroupEnv(t)
	f.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.GroupsPerMemberMax = 2
		return x
	}
	f.expect(f.create(alice, "one", bob, cara), 201, "")
	f.chatWith(alice, dev)
	f.expect(f.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, dev}}), 201, "") // bob has 2 now
	f.chatWith(alice, eli)
	// Alice is in two groups: a third is hers to refuse.
	if r := f.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{eli, cara}}); r.status != 409 || r.code != "GROUP_LIMIT" {
		t.Fatalf("creator over the cap: %d %s", r.status, r.code)
	}
	// An invitee at their cap is "cannot be added", never the reason.
	g2 := newGroupEnv(t)
	g2.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.GroupsPerMemberMax = 1
		return x
	}
	g2.expect(g2.create(alice, "a", bob, cara), 201, "")
	g2.chatWith(dev, bob)
	g2.chatWith(dev, eli)
	if r := g2.do(dev, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, eli}}); r.status != 409 || r.code != "CANNOT_ADD_MEMBER" || r.data != nil && fmt.Sprint(r.data) == "" {
		t.Fatalf("invitee at the cap: %d %s", r.status, r.code)
	}
	// Groups created per day and people invited per day.
	h := newGroupEnv(t)
	h.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.GroupsCreatedPerDay = 2
		x.GroupInvitesPerDay = 5
		return x
	}
	h.chatWith(alice, bob)
	h.chatWith(alice, cara)
	h.expect(h.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara}}), 201, "")
	h.expect(h.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara}}), 201, "")
	// The third group is over the daily creation cap (2); the invites so far were 4 of 5.
	if r := h.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara}}); r.status != 429 || r.code != "DAILY_LIMIT" {
		t.Fatalf("groups per day: %d %s", r.status, r.code)
	}
	h2 := newGroupEnv(t)
	h2.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.GroupInvitesPerDay = 3
		return x
	}
	h2.chatWith(alice, bob)
	h2.chatWith(alice, cara)
	h2.chatWith(alice, dev)
	h2.chatWith(alice, eli)
	gid := h2.expect(h2.do(alice, "POST", "/v1/groups", map[string]any{"memberIds": []string{bob, cara}}), 201, "").data["groupId"].(string)
	h2.expect(h2.do(alice, "POST", "/v1/groups/"+gid+"/members", map[string]any{"userIds": []string{dev}}), 200, "")
	if r := h2.do(alice, "POST", "/v1/groups/"+gid+"/members", map[string]any{"userIds": []string{eli}}); r.status != 429 || r.code != "DAILY_LIMIT" {
		t.Fatalf("invites per day: %d %s", r.status, r.code)
	}
}

func TestGroupInviteDeclineExpiryAndClosing(t *testing.T) {
	e := newGroupEnv(t)
	id := e.expect(e.create(alice, "short lived", bob, cara), 201, "").data["groupId"].(string)
	// An invite lives 7 days.
	var days float64
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT extract(epoch FROM expires_at-invited_at)/86400 FROM chat_group_members WHERE conversation_id=$1 AND user_id=$2`, id, bob).Scan(&days); err != nil || days < 6.99 || days > 7.01 {
		t.Fatalf("invite lifetime %v days (%v)", days, err)
	}
	// Declining deletes the invite; nobody else is told, and the group stays open while another invite is pending.
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/decline", nil), 200, "")
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/decline", nil), 404, "NOT_FOUND")
	e.expect(e.accept(bob, id), 404, "NOT_FOUND")
	if g := e.group(alice, id); g["status"] != "active" {
		t.Fatalf("group closed while an invite is pending: %v", g["status"])
	}
	// An unanswered invite expires after 7 days: it leaves the list, cannot be accepted, and the hourly job removes it.
	e.exec(`UPDATE chat_group_members SET expires_at=now()-interval '1 minute' WHERE conversation_id=$1 AND user_id=$2`, id, cara)
	if got := items(e.expect(e.do(cara, "GET", "/v1/groups/invites", nil), 200, "").data); len(got) != 0 {
		t.Fatalf("an expired invite is listed: %v", got)
	}
	e.expect(e.do(cara, "GET", "/v1/groups/"+id, nil), 404, "NOT_FOUND")
	e.expect(e.accept(cara, id), 404, "NOT_FOUND")
	if n, err := e.db.ExpireGroupInvites(e.ctx, 100); err != nil || n != 1 {
		t.Fatalf("expiry job: %d %v", n, err)
	}
	// With nobody left to answer and one member, the group closes: no more messages, and the creator can still leave it.
	g := e.group(alice, id)
	if g["status"] != "closed" || len(g["pending"].([]any)) != 0 {
		t.Fatalf("a group of one with no invites closes: %v", g["status"])
	}
	e.expect(e.do(alice, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[alice][0], e.dev[bob][0])), 403, "CONVERSATION_CLOSED")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{dev}}), 403, "CONVERSATION_CLOSED")
	// A closed group stays in the list (read only) until the member deletes it.
	if list := items(e.expect(e.do(alice, "GET", "/v1/groups", nil), 200, "").data); len(list) != 1 || list[0]["status"] != "closed" {
		t.Fatalf("a closed group in the list: %v", list)
	}
	e.expect(e.do(alice, "POST", "/v1/conversations/"+id+"/hide", nil), 200, "")
	if list := items(e.expect(e.do(alice, "GET", "/v1/groups", nil), 200, "").data); len(list) != 0 {
		t.Fatalf("a hidden group in the list: %v", list)
	}
	if hidden := items(e.expect(e.do(alice, "GET", "/v1/groups/hidden", nil), 200, "").data); len(hidden) != 1 || hidden[0]["hiddenAt"] == nil || hidden[0]["restoreUntil"] == nil {
		t.Fatalf("hidden groups: %v", hidden)
	}
	e.expect(e.do(alice, "POST", "/v1/conversations/"+id+"/restore", nil), 200, "")
	if list := items(e.expect(e.do(alice, "GET", "/v1/groups", nil), 200, "").data); len(list) != 1 {
		t.Fatalf("a restored group: %v", list)
	}
}

func TestGroupOwnerRemovesRenamesAndMembersLeave(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara, dev)

	// Only the owner renames and removes; a member gets 403, a stranger 404.
	rename := func(user, name string) reply {
		return e.do(user, "PATCH", "/v1/groups/"+id, map[string]any{"name": name, "control": e.sealFor(id, user)})
	}
	e.expect(rename(bob, "bobs"), 403, "GROUP_NOT_OWNER")
	e.expect(rename(eli, "elis"), 404, "NOT_FOUND")
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/members/"+cara+"/remove", map[string]any{"control": e.sealFor(id, bob)}), 403, "GROUP_NOT_OWNER")
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{eli}}), 403, "GROUP_NOT_OWNER")
	// Rename needs the message for everyone; a bad name is refused before anything changes.
	e.expect(e.do(alice, "PATCH", "/v1/groups/"+id, map[string]any{"name": "no control"}), 422, "VALIDATION")
	e.expect(e.do(alice, "PATCH", "/v1/groups/"+id, map[string]any{"name": strings.Repeat("x", 41), "control": e.sealFor(id, alice)}), 422, "VALIDATION")
	e.expect(e.do(alice, "PATCH", "/v1/groups/"+id, map[string]any{"name": "short", "control": message(e.dev[alice][0], e.dev[bob][0])}), 409, "DEVICES_CHANGED")
	renamed := e.expect(rename(alice, "new name"), 200, "").data
	if renamed["name"] != "new name" {
		t.Fatalf("renamed: %v", renamed["name"])
	}
	// The event is recorded and links to the control message.
	g := e.group(bob, id)
	events := g["events"].([]any)
	last := events[len(events)-1].(map[string]any)
	if last["kind"] != "renamed" || last["name"] != "new name" || last["actorId"] != alice || last["messageId"] == nil {
		t.Fatalf("last event: %v", last)
	}
	// A control message is auxiliary: never unread, never counted as a conversation turn.
	if n := e.expect(e.do(bob, "GET", "/v1/conversations/unread", nil), 200, "").data["messages"]; n != float64(0) {
		t.Fatalf("control messages are not unread: %v", n)
	}
	e.expect(e.do(alice, "PATCH", "/v1/groups/"+id, map[string]any{"name": "", "control": e.sealFor(id, alice)}), 200, "")

	// Removing: the message goes to everyone, the removed person included, and nothing after it is sealed for them.
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members/"+alice+"/remove", map[string]any{"control": e.sealFor(id, alice)}), 422, "VALIDATION")
	before := e.post(bob, id)
	e.expect(before, 200, "")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members/"+dev+"/remove", nil), 422, "VALIDATION") // no control message
	removed := e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members/"+dev+"/remove", map[string]any{"control": e.sealFor(id, alice)}), 200, "").data
	if got := memberIDs(removed); fmt.Sprint(got) != fmt.Sprint([]string{alice, bob, cara}) {
		t.Fatalf("after removal: %v", got)
	}
	in := e.inbox(dev, e.dev[dev][0])
	if len(in) == 0 {
		t.Fatal("the removed person got nothing")
	}
	for _, i := range in {
		if i["aux"] != true && i["senderId"] != alice {
			// Ciphertext sent while they were a member may still be there only if it was the removal itself.
			t.Fatalf("the removed person keeps waiting ciphertext: %v", i)
		}
	}
	if last := in[len(in)-1]; last["senderId"] != alice || last["aux"] != true {
		t.Fatalf("the removed person's last message is the removal: %v", last)
	}
	// They are gone from the group: no access, no more messages; the others no longer seal for them.
	e.expect(e.do(dev, "GET", "/v1/groups/"+id, nil), 404, "NOT_FOUND")
	e.expect(e.do(dev, "POST", "/v1/conversations/"+id+"/messages", e.sealFor(id, dev, alice)), 404, "NOT_FOUND")
	stale := message(e.dev[bob][0], e.devicesOf(alice, cara, dev)...)
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", stale), 409, "DEVICES_CHANGED")
	e.expect(e.post(bob, id), 200, "")
	if list := items(e.expect(e.do(dev, "GET", "/v1/groups", nil), 200, "").data); len(list) != 0 {
		t.Fatalf("a removed member still lists the group: %v", list)
	}
	// A pending invite is cancelled without a message.
	e.chatWith(alice, eli)
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{eli}}), 200, "")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members/"+eli+"/remove", nil), 200, "")
	e.expect(e.accept(eli, id), 404, "NOT_FOUND")

	// A member leaves: the message goes to the others, and they stop sealing for the leaver.
	e.expect(e.do(cara, "POST", "/v1/groups/"+id+"/leave", nil), 422, "VALIDATION")
	e.expect(e.do(cara, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": e.sealFor(id, cara)}), 200, "")
	if got := memberIDs(e.group(alice, id)); fmt.Sprint(got) != fmt.Sprint([]string{alice, bob}) {
		t.Fatalf("after cara left: %v", got)
	}
	e.expect(e.do(cara, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": e.sealFor(id, cara)}), 404, "NOT_FOUND")
	// The owner leaves while two people remain: they must say who takes over. With two left the group closes.
	e.formedAgain(id, cara)
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": e.sealFor(id, alice)}), 422, "VALIDATION")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/leave", map[string]any{"newOwnerId": alice, "control": e.sealFor(id, alice)}), 422, "VALIDATION")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/leave", map[string]any{"newOwnerId": dev, "control": e.sealFor(id, alice)}), 422, "VALIDATION")
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/leave", map[string]any{"newOwnerId": bob, "control": e.sealFor(id, alice)}), 200, "")
	g = e.group(bob, id)
	if g["ownerId"] != bob || g["status"] != "active" || fmt.Sprint(memberIDs(g)) != fmt.Sprint([]string{bob, cara}) {
		t.Fatalf("after the owner left: owner %v status %v members %v", g["ownerId"], g["status"], memberIDs(g))
	}
	e.expect(rename(bob, "bobs now"), 200, "")
	e.expect(rename(alice, "still alice"), 404, "NOT_FOUND")
	// Down to one person the group closes, and the last member sees why.
	e.expect(e.do(cara, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": e.sealFor(id, cara)}), 200, "")
	g = e.group(bob, id)
	if g["status"] != "closed" {
		t.Fatalf("a group of one closes: %v", g["status"])
	}
	kinds := []string{}
	for _, ev := range g["events"].([]any) {
		kinds = append(kinds, ev.(map[string]any)["kind"].(string))
	}
	if !strings.HasSuffix(strings.Join(kinds, ","), "left,closed") {
		t.Fatalf("events: %v", kinds)
	}
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[bob][0], e.dev[cara][0])), 403, "CONVERSATION_CLOSED")
	// The last member can leave a closed group without telling anyone.
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/leave", nil), 200, "")
}

// formedAgain invites user back to a group and has them accept.
func (e *groupEnv) formedAgain(group, user string) {
	e.t.Helper()
	owner := e.group(e.activeMembers(group)[0], group)["ownerId"].(string)
	e.chatWith(owner, user)
	e.expect(e.do(owner, "POST", "/v1/groups/"+group+"/members", map[string]any{"userIds": []string{user}}), 200, "")
	e.expect(e.accept(user, group), 200, "")
}

func TestGroupBlockBetweenMembersHidesThemFromEachOtherOnly(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	e.expect(e.do(bob, "POST", "/v1/users/"+cara+"/block", nil), 200, "")
	// The group carries on for everyone, but bob and cara no longer see each other in it.
	if got := memberIDs(e.group(bob, id)); fmt.Sprint(got) != fmt.Sprint([]string{alice, bob}) {
		t.Fatalf("bob's view after blocking cara: %v", got)
	}
	if got := memberIDs(e.group(cara, id)); fmt.Sprint(got) != fmt.Sprint([]string{alice, cara}) {
		t.Fatalf("cara's view after being blocked: %v", got)
	}
	if got := memberIDs(e.group(alice, id)); len(got) != 3 {
		t.Fatalf("alice still sees all three: %v", got)
	}
	// Bob seals for alice only; sealing for cara is refused. Alice seals for both.
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[bob][0], e.devicesOf(alice)...)), 200, "")
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[bob][0], e.devicesOf(alice, cara)...)), 409, "DEVICES_CHANGED")
	e.expect(e.post(alice, id), 200, "")
	// Cara never receives bob's message, and bob never receives hers.
	for _, i := range e.inbox(cara, e.dev[cara][0]) {
		if i["senderId"] == bob {
			t.Fatalf("a blocked member's message was delivered: %v", i)
		}
	}
	// The unread count of the one who is blocked does not rise either.
	var unread int
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT unread_count FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, id, cara).Scan(&unread); err != nil || unread != 1 {
		t.Fatalf("cara's unread %d %v", unread, err)
	}
	// A pending invite between a blocked pair is cancelled.
	e.chatWith(alice, dev)
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{dev}}), 200, "")
	e.expect(e.do(dev, "POST", "/v1/users/"+alice+"/block", nil), 200, "")
	if got := items(e.expect(e.do(dev, "GET", "/v1/groups/invites", nil), 200, "").data); len(got) != 0 {
		t.Fatalf("an invite from someone who is blocked: %v", got)
	}
}

func TestGroupMembersMayStartSessionsWithoutBeingConnected(t *testing.T) {
	e := newGroupEnv(t)
	e.chatWith(alice, bob)
	e.chatWith(alice, eli)
	gid := e.formed(alice, "mix", bob, eli)
	// Eli now takes messages from friends only: a stranger cannot fetch his devices or claim a key...
	e.policy(eli, "messagesFrom", "friends")
	e.expect(e.do(dev, "GET", "/v1/users/"+eli+"/devices", nil), 403, "MESSAGES_NOT_ALLOWED")
	e.expect(e.do(dev, "POST", "/v1/users/"+eli+"/devices/"+e.dev[eli][0].id+"/claim", nil), 403, "MESSAGES_NOT_ALLOWED")
	// ...but bob shares a group with him, so bob may start the Olm session his group messages need.
	e.expect(e.do(bob, "GET", "/v1/users/"+eli+"/devices", nil), 200, "")
	e.expect(e.send(eli, "POST", "/v1/devices/"+e.dev[eli][0].id+"/keys", map[string]any{"oneTimeKeys": []map[string]string{e.dev[eli][0].oneTimeKey("k1")}}), 200, "")
	claim := e.expect(e.do(bob, "POST", "/v1/users/"+eli+"/devices/"+e.dev[eli][0].id+"/claim", nil), 200, "").data
	if claim["keyId"] != "k1" {
		t.Fatalf("claim: %v", claim)
	}
	// A block still wins over the group.
	e.expect(e.do(bob, "POST", "/v1/users/"+eli+"/block", nil), 200, "")
	e.expect(e.do(bob, "GET", "/v1/users/"+eli+"/devices", nil), 404, "NOT_FOUND")
	// Leaving the group ends it.
	e.expect(e.do(eli, "POST", "/v1/groups/"+gid+"/leave", map[string]any{"control": message(e.dev[eli][0], e.devicesOf(alice)...)}), 200, "")

	// An invited person may reach the people already in the group, and nobody may reach a person who is only invited.
	f := newGroupEnv(t)
	gid2 := f.expect(f.create(alice, "pair", bob, cara), 201, "").data["groupId"].(string)
	f.policy(alice, "messagesFrom", "friends")
	f.policy(cara, "messagesFrom", "friends")
	f.expect(f.do(bob, "GET", "/v1/users/"+alice+"/devices", nil), 200, "")
	f.expect(f.do(dev, "GET", "/v1/users/"+alice+"/devices", nil), 403, "MESSAGES_NOT_ALLOWED")
	f.expect(f.do(bob, "GET", "/v1/users/"+cara+"/devices", nil), 403, "MESSAGES_NOT_ALLOWED")
	f.expect(f.do(bob, "POST", "/v1/groups/"+gid2+"/decline", nil), 200, "")
	f.expect(f.do(bob, "GET", "/v1/users/"+alice+"/devices", nil), 403, "MESSAGES_NOT_ALLOWED")
}

func TestGroupPinHideMuteAndTheSharedPinCap(t *testing.T) {
	e := newGroupEnv(t)
	e.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.ChatPinsMax = 2
		return x
	}
	g1 := e.formed(alice, "one", bob, cara)
	g2 := e.formed(alice, "two", bob, cara)
	g3 := e.formed(alice, "three", bob, cara)
	e.chatWith(alice, dev)
	direct := e.expect(e.do(alice, "POST", "/v1/conversations", map[string]string{"userId": dev}), 200, "").data["conversationId"].(string)
	pin := func(id string, on bool) reply {
		return e.do(alice, "PUT", "/v1/conversations/"+id+"/pin", map[string]any{"pinned": on})
	}
	e.expect(pin(g1, true), 200, "")
	e.expect(pin(direct, true), 200, "")
	// The cap is shared by groups and direct chats.
	e.expect(pin(g2, true), 409, "PIN_LIMIT")
	e.expect(pin(g1, true), 200, "") // pinning a pinned chat is fine
	e.expect(pin(g1, false), 200, "")
	e.expect(pin(g2, true), 200, "")
	list := items(e.expect(e.do(alice, "GET", "/v1/groups", nil), 200, "").data)
	if len(list) != 3 || list[0]["groupId"] != g2 || list[0]["pinnedAt"] == nil {
		t.Fatalf("pinned group first: %v", list)
	}
	// Hide and restore, per member.
	e.expect(e.do(alice, "POST", "/v1/conversations/"+g3+"/hide", nil), 200, "")
	if got := items(e.expect(e.do(alice, "GET", "/v1/groups", nil), 200, "").data); len(got) != 2 {
		t.Fatalf("after hiding: %v", got)
	}
	if got := items(e.expect(e.do(bob, "GET", "/v1/groups", nil), 200, "").data); len(got) != 3 {
		t.Fatalf("bob still lists all three: %v", got)
	}
	// A message brings it back for the member who deleted it.
	e.expect(e.post(bob, g3), 200, "")
	if got := items(e.expect(e.do(alice, "GET", "/v1/groups", nil), 200, "").data); len(got) != 3 {
		t.Fatalf("a message restores the group: %v", got)
	}
	// Mute is per member and shown as mutedUntil.
	e.expect(e.do(bob, "POST", "/v1/conversations/"+g1+"/mute", nil), 200, "")
	for _, gg := range items(e.expect(e.do(bob, "GET", "/v1/groups", nil), 200, "").data) {
		if (gg["groupId"] == g1) != (gg["mutedUntil"] != nil) {
			t.Fatalf("mute: %v", gg)
		}
	}
	e.expect(e.post(alice, g1), 200, "")
	e.expect(e.post(alice, g2), 200, "")
	if n := e.expect(e.do(bob, "GET", "/v1/conversations/unread", nil), 200, "").data["messages"]; n != float64(1) {
		// Bob's unread counts g2 only: g1 is muted, and his own message in g3 left nothing unread.
		t.Fatalf("unread with a muted group: %v", n)
	}
}

func TestGroupPhotosVoiceAndVideoBlobsAreSharedByMembers(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	blobEnv := &blobEnv{socialHarness: e.socialHarness, chat: e.chat}
	data := noise(2000)
	// Any member uploads without the "peer replied" gate; a stranger cannot.
	e.expect(e.do(dev, "POST", "/v1/conversations/"+id+"/blobs", map[string]any{"role": "full", "sizeBytes": len(data), "ctSha256": ctOf(data)}), 404, "NOT_FOUND")
	blob := blobEnv.uploaded(bob, id, "full", data)
	voice := blobEnv.uploaded(bob, id, "voice", noise(3000))
	m := e.sealFor(id, bob)
	m["blobIds"] = []string{blob, voice}
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", m), 200, "")
	// Another member's blob cannot be claimed.
	other := e.sealFor(id, cara)
	other["blobIds"] = []string{blobEnv.uploaded(bob, id, "full", noise(500))}
	e.expect(e.do(cara, "POST", "/v1/conversations/"+id+"/messages", other), 409, "BLOB_NOT_READY")
	// Every active member may download; a stranger and a barred member cannot.
	for _, u := range []string{alice, bob, cara} {
		e.expect(e.do(u, "GET", "/v1/conversations/"+id+"/blobs/"+blob+"/url", nil), 200, "")
	}
	e.expect(e.do(dev, "GET", "/v1/conversations/"+id+"/blobs/"+blob+"/url", nil), 404, "NOT_FOUND")
	e.expect(e.do(cara, "POST", "/v1/users/"+bob+"/block", nil), 200, "")
	e.expect(e.do(cara, "GET", "/v1/conversations/"+id+"/blobs/"+blob+"/url", nil), 404, "NOT_FOUND")
	e.expect(e.do(alice, "GET", "/v1/conversations/"+id+"/blobs/"+blob+"/url", nil), 200, "")
	// They keep the 30 day retention from the message.
	var days float64
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT extract(epoch FROM expires_at-now())/86400 FROM chat_blobs WHERE blob_id=$1`, blob).Scan(&days); err != nil || days < 29.9 || days > 30.1 {
		t.Fatalf("retention %v (%v)", days, err)
	}
	// The quotas are the member's own, counted where the slot is made.
	if n := e.count(`SELECT count(*) FROM chat_blobs WHERE uploader_id=$1`, bob); n != 3 {
		t.Fatalf("bob's blobs %d", n)
	}
}

func TestGroupReactionsAreQuietAndControlMessagesCannotBeSentAsMessages(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	reaction := e.sealFor(id, bob)
	reaction["aux"] = "reaction"
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", reaction), 200, "")
	var unread int
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT unread_count FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, id, alice).Scan(&unread); err != nil || unread != 0 {
		t.Fatalf("a reaction is not unread: %d %v", unread, err)
	}
	// A reaction envelope is at most 2 KiB.
	big := e.sealFor(id, bob)
	big["aux"] = "reaction"
	for _, env := range big["envelopes"].([]map[string]any) {
		env["ciphertext"] = b64.EncodeToString(noise(3000))
	}
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", big), 413, "TOO_LARGE")
	// The group marker belongs to the membership routes: a plain send cannot carry it.
	control := e.sealFor(id, bob)
	control["aux"] = "group"
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", control), 422, "VALIDATION")
	// A membership message takes no attachments and no aux member.
	withBlob := e.sealFor(id, bob)
	withBlob["blobIds"] = []string{uuid.NewString()}
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": withBlob}), 422, "VALIDATION")
	withAux := e.sealFor(id, bob)
	withAux["aux"] = "reaction"
	e.expect(e.do(bob, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": withAux}), 422, "VALIDATION")
	// 101 envelopes are refused.
	var many []map[string]any
	for i := 0; i < 101; i++ {
		many = append(many, envelopes(newTestDevice(alice))...)
	}
	tooMany := map[string]any{"messageId": uuid.NewString(), "senderDeviceId": e.dev[bob][0].id, "envelopes": many}
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/messages", tooMany), 422, "VALIDATION")
	// A group send may be larger than the 64 KiB of other routes: 19 envelopes of 12 KiB.
	e.expect(e.post(bob, id), 200, "")
}

func TestGroupSendQuotaAndBacklogCaps(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	e.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.ChatMessagesPerConversationPerDay = 4
		x.ChatBacklogPerSenderPerDevice = 3
		return x
	}
	// Bob's join message and two messages wait on alice's devices: the per-sender share (3) is spent.
	e.expect(e.post(bob, id), 200, "")
	e.expect(e.post(bob, id), 200, "")
	if r := e.post(bob, id); r.status != 429 || r.code != "RECIPIENT_BACKLOG" {
		t.Fatalf("per sender backlog: %d %s", r.status, r.code)
	}
	// Another sender is not held back by bob's share.
	e.expect(e.post(cara, id), 200, "")
	// The daily quota counts every message of a sender in the group, the join message too (3 so far).
	e.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := domain.Free()
		x.ChatMessagesPerConversationPerDay = 4
		return x
	}
	e.expect(e.post(bob, id), 200, "")
	if r := e.post(bob, id); r.status != 429 || r.code != "CHAT_DAILY_LIMIT" {
		t.Fatalf("daily quota: %d %s", r.status, r.code)
	}
}

func TestGroupReportsNameTheSenderOrTheOwnerAndAdminsSeeMembershipOnly(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	sent := e.expect(e.post(bob, id), 200, "").data["messageId"].(string)
	// A member reports a message: the subject is its sender, the evidence is what the reporter shared.
	report := e.expect(e.do(cara, "POST", "/v1/reports", map[string]any{"targetType": "message", "targetId": sent, "reasonCode": "harassment",
		"evidence": []map[string]any{{"messageId": sent, "text": "what bob wrote", "sentAt": time.Now().UTC().Format(time.RFC3339)}}, "disclosureConsent": true}), 201, "").data["report"].(map[string]any)
	if report["subject"].(map[string]any)["userId"] != bob {
		t.Fatalf("the subject of a group message is its sender: %v", report["subject"])
	}
	// Reporting the group names its owner; the owner has to report a message or a member.
	onGroup := e.expect(e.do(bob, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": id, "reasonCode": "spam"}), 201, "").data["report"].(map[string]any)
	if onGroup["subject"].(map[string]any)["userId"] != alice {
		t.Fatalf("the subject of a group report is the owner: %v", onGroup["subject"])
	}
	e.expect(e.do(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": id, "reasonCode": "spam"}), 422, "VALIDATION")
	// A stranger cannot report a message in a group they are not in.
	e.expect(e.do(dev, "POST", "/v1/reports", map[string]any{"targetType": "message", "targetId": sent, "reasonCode": "spam"}), 404, "NOT_FOUND")
	// The console's view of the report carries the group's metadata and nothing that was said beyond the evidence.
	c, err := e.db.AdminCase(e.ctx, report["reportId"].(string))
	if err != nil || c.Group == nil || c.Group.Name != "crew" || c.Group.OwnerID != alice || c.Group.OwnerUsername == "" || len(c.Group.Members) != 3 {
		t.Fatalf("admin case group: %+v %v", c.Group, err)
	}
	for _, m := range c.Group.Members {
		if m.State != "active" || (m.UserID == alice) != (m.Role == "owner") {
			t.Fatalf("member row: %+v", m)
		}
	}
	// A report about something else has no group.
	other := e.expect(e.do(cara, "POST", "/v1/reports", map[string]any{"targetType": "user", "targetId": bob, "reasonCode": "spam"}), 201, "").data["report"].(map[string]any)
	if c, err = e.db.AdminCase(e.ctx, other["reportId"].(string)); err != nil || c.Group != nil {
		t.Fatalf("a user report has no group: %+v %v", c.Group, err)
	}
}

func (e *groupEnv) exportOf(user string) map[string]any {
	e.t.Helper()
	e.api.clients.reset("127.0.0.1")
	status, _, body := (&blobEnv{socialHarness: e.socialHarness}).full(user, "GET", "/v1/me/export", "", "")
	if status != 200 {
		e.t.Fatalf("export: %d %s", status, body)
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		e.t.Fatal(err)
	}
	return doc
}

func TestGroupExportListsTheMembersOwnGroupsAndInvites(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	e.expect(e.post(alice, id), 200, "")
	e.chatWith(alice, dev)
	e.expect(e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{dev}}), 200, "")
	section, _ := e.exportOf(bob)["chat"].(map[string]any)
	groups, _ := section["groups"].([]any)
	if len(groups) != 1 {
		t.Fatalf("export groups: %v", section)
	}
	g := groups[0].(map[string]any)
	if g["name"] != "crew" || g["role"] != "member" || g["memberCount"] != float64(3) || g["messagesReceived"] != float64(1) || g["messagesSent"] != float64(1) { // bob's join message is his
		t.Fatalf("export group: %v", g)
	}
	totals := section["totals"].(map[string]any)
	if totals["groups"] != float64(1) || totals["conversations"] != float64(1) { // the chat alice opened to invite him
		t.Fatalf("export totals: %v", totals)
	}
	invites, _ := e.exportOf(dev)["chat"].(map[string]any)["groupInvites"].([]any)
	if len(invites) != 1 || invites[0].(map[string]any)["name"] != "crew" {
		t.Fatalf("export invites: %v", invites)
	}
}

func TestGroupAccountDeletionRecordsAnEventPassesOwnershipAndPurgesWhatTheyWrote(t *testing.T) {
	ah := newAcctHarness(t)
	e := newGroupEnvOn(t, ah.socialHarness, xan, eli, yui, cara)
	id := e.formed(xan, "crew", eli, yui)
	e.chatWith(xan, cara)
	e.expect(e.do(xan, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{cara}}), 200, "")
	e.expect(e.post(xan, id), 200, "")
	e.expect(e.post(eli, id), 200, "")
	// A group xan is only a member of, with two others: it closes when xan goes (only one stays) .
	small := e.formed(eli, "small", xan, cara)
	_ = small

	ah.scheduled(xan, "xan")
	ah.expire(xan)
	del := &fakeDeleter{}
	for range 4 {
		if _, err := ah.db.PurgeDeletedAccounts(ah.ctx, del, 10); err != nil {
			t.Fatal(err)
		}
		if _, err := ah.db.PurgeChatBlobs(ah.ctx, e.chat, 5000); err != nil {
			t.Fatal(err)
		}
	}
	g := e.group(eli, id)
	if g["ownerId"] != eli || g["status"] != "active" || fmt.Sprint(memberIDs(g)) != fmt.Sprint([]string{eli, yui}) {
		t.Fatalf("after the owner's account was deleted: owner %v status %v members %v", g["ownerId"], g["status"], memberIDs(g))
	}
	if n := len(g["pending"].([]any)); n != 0 {
		t.Fatalf("the invites the deleted member sent are cancelled: %v", g["pending"])
	}
	kinds := map[string]string{}
	for _, ev := range g["events"].([]any) {
		m := ev.(map[string]any)
		kinds[m["kind"].(string)] = fmt.Sprint(m["subjectId"])
	}
	if kinds["member_deleted"] != xan || kinds["owner_changed"] != eli {
		t.Fatalf("events after deletion: %v", kinds)
	}
	for _, ev := range g["events"].([]any) {
		m := ev.(map[string]any)
		if m["actorId"] == xan || (m["subjectId"] == xan && m["kind"] != "member_deleted") {
			t.Fatalf("an event still names the deleted account: %v", m)
		}
	}
	// What xan sent in groups is purged, what others sent stays, and nothing of xan's membership is left.
	if e.count(`SELECT count(*) FROM messages WHERE sender_id=$1`, xan) != 0 || e.count(`SELECT count(*) FROM messages WHERE sender_id=$1`, eli) == 0 {
		t.Fatal("messages after the purge")
	}
	if e.count(`SELECT count(*) FROM chat_group_members WHERE user_id=$1 OR invited_by=$1`, xan) != 0 || e.count(`SELECT count(*) FROM conversations WHERE created_by=$1`, xan) != 0 {
		t.Fatal("rows still name the deleted member")
	}
	// The other group had xan and two more: it carries on with two people.
	if g2 := e.group(eli, small); g2["status"] != "active" || len(memberIDs(g2)) != 2 {
		t.Fatalf("small group: %v %v", g2["status"], memberIDs(g2))
	}
	// A deleted member's devices are gone from the sealed set: the others seal without them.
	e.expect(e.post(eli, id), 200, "")
	// Down to one member the group closes; the last one leaves it without telling anyone.
	e.expect(e.do(eli, "POST", "/v1/groups/"+id+"/leave", map[string]any{"control": e.sealFor(id, eli)}), 200, "")
	if g3 := e.group(yui, id); g3["status"] != "closed" {
		t.Fatalf("a group of one: %v", g3["status"])
	}
	e.expect(e.do(yui, "POST", "/v1/groups/"+id+"/leave", nil), 200, "")
}

func TestGroupSendWithNoOtherDeviceIsRefused(t *testing.T) {
	e := newGroupEnv(t)
	id := e.formed(alice, "crew", bob, cara)
	// Everyone else's devices are gone: nothing can be sealed.
	e.exec(`UPDATE devices SET revoked_at=now() WHERE user_id IN ($1,$2)`, bob, cara)
	if r := e.do(alice, "POST", "/v1/conversations/"+id+"/messages", message(e.dev[alice][0], e.dev[alice][1])); r.status != 409 || r.code != "GROUP_WAITING" {
		t.Fatalf("no other devices: %d %s", r.status, r.code)
	}
}

func TestGroupPushesAreGenericAndRespectMutes(t *testing.T) {
	e := newGroupEnv(t)
	log, _ := pushing(t, e.socialHarness, nil)
	e.token(e.dev[bob][0], "bob-token-1")
	e.token(e.dev[cara][0], "cara-token-1")
	id := e.expect(e.create(alice, "a very private name", bob, cara), 201, "").data["groupId"].(string)
	// An invite pushes "You have a new group invite" to each invitee: no group name, no sender.
	invites := log.wait(t, 2)
	for _, m := range invites {
		if m.Body != "You have a new group invite" || m.Data["kind"] != "group_invite" || strings.Contains(fmt.Sprint(m), "private") || strings.Contains(fmt.Sprint(m), "alice") {
			t.Fatalf("invite push: %+v", m)
		}
	}
	e.expect(e.accept(bob, id), 200, "")
	e.expect(e.accept(cara, id), 200, "")
	log.quiet(t, 2, "joining sends only auxiliary messages")
	// Bob mutes the group; a message pushes to cara alone, with no content and no name.
	e.expect(e.do(bob, "POST", "/v1/conversations/"+id+"/mute", nil), 200, "")
	e.expect(e.post(alice, id), 200, "")
	all := log.wait(t, 3)
	got := all[2]
	if got.Body != "New message" || got.Data["kind"] != "chat" || got.Data["conversationId"] != id || strings.Contains(fmt.Sprint(got), "private") {
		t.Fatalf("message push: %+v", got)
	}
	log.mu.Lock()
	to := log.to[2]
	log.mu.Unlock()
	if to.UserID != cara {
		t.Fatalf("pushed to %s, not cara", to.UserID)
	}
	// A reaction and a membership message are never pushed.
	reaction := e.sealFor(id, alice)
	reaction["aux"] = "reaction"
	e.expect(e.do(alice, "POST", "/v1/conversations/"+id+"/messages", reaction), 200, "")
	e.expect(e.do(cara, "PATCH", "/v1/groups/"+id, map[string]any{"name": "x", "control": e.sealFor(id, cara)}), 403, "GROUP_NOT_OWNER")
	log.quiet(t, 3, "reactions are quiet")
}

func TestGroupConcurrentChangesCannotBreakTheRosterLimits(t *testing.T) {
	e := newGroupEnv(t)
	// Eight people, room for two more; four owners' invites race for two places.
	id := e.formed(alice, "full-ish", bob, cara, dev, eli, xan, yui, gm1)
	for _, u := range []string{gm2, gm3, gm4} {
		e.chatWith(alice, u)
	}
	results := make(chan int, 3)
	for _, u := range []string{gm2, gm3, gm4} {
		go func(u string) {
			results <- e.do(alice, "POST", "/v1/groups/"+id+"/members", map[string]any{"userIds": []string{u}}).status
		}(u)
	}
	ok, full := 0, 0
	for range 3 {
		switch <-results {
		case 200:
			ok++
		case 409:
			full++
		}
	}
	if ok != 2 || full != 1 {
		t.Fatalf("two of three invites fit: ok %d full %d", ok, full)
	}
	if n := e.count(`SELECT count(*) FROM chat_group_members WHERE conversation_id=$1`, id); n != 10 {
		t.Fatalf("rows %d", n)
	}
	// The same message id sent twice at once is stored once.
	m := e.sealFor(id, bob)
	codes := make(chan int, 4)
	for range 4 {
		go func() { codes <- e.send(bob, "POST", "/v1/conversations/"+id+"/messages", m).status }()
	}
	for range 4 {
		if c := <-codes; c != 200 && c != 429 {
			t.Fatalf("concurrent send: %d", c)
		}
	}
	if n := e.count(`SELECT count(*) FROM messages WHERE message_id=$1`, m["messageId"]); n != 1 {
		t.Fatalf("message stored %d times", n)
	}
}

func TestGroupBlockingTheInviterCancelsTheInviteAndClosesAGroupThatWasOnlyWaiting(t *testing.T) {
	e := newGroupEnv(t)
	id := e.expect(e.create(alice, "waiting", bob, cara), 201, "").data["groupId"].(string)
	e.expect(e.do(bob, "POST", "/v1/users/"+alice+"/block", nil), 200, "")
	if g := e.group(alice, id); g["status"] != "active" || len(g["pending"].([]any)) != 1 {
		t.Fatalf("one invite left keeps the group open: %v %v", g["status"], g["pending"])
	}
	e.expect(e.do(cara, "POST", "/v1/users/"+alice+"/block", nil), 200, "")
	if g := e.group(alice, id); g["status"] != "closed" || len(g["pending"].([]any)) != 0 {
		t.Fatalf("nobody left to answer: %v %v", g["status"], g["pending"])
	}
}
