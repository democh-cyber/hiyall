package httpapi

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
)

func (h *socialHarness) interests(id string, values ...string) {
	h.t.Helper()
	raw, _ := json.Marshal(values)
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{interests}',$2::jsonb) WHERE user_id=$1`, id, string(raw))
}

func (h *socialHarness) fieldAudience(id, field, audience string) {
	h.t.Helper()
	raw, _ := json.Marshal(audience)
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],$3::jsonb) WHERE user_id=$1`, id, field, string(raw))
}

func strs(v any) []string {
	raw, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, len(raw))
	for i, x := range raw {
		out[i] = x.(string)
	}
	return out
}

// shared reads sharedInterests for the pair through every payload that carries a conversation: open (the first
// time only, new chats are rate limited), get and list.
func (h *socialHarness) shared(viewer, peer string) []string {
	h.t.Helper()
	var convo map[string]any
	for _, c := range items(h.ok(viewer, "GET", "/v1/conversations?limit=50")) {
		if c["peer"].(map[string]any)["userId"] == peer {
			convo = c
		}
	}
	if convo == nil {
		convo = h.expect(h.send(viewer, "POST", "/v1/conversations", map[string]string{"userId": peer}), 200, "").data
	}
	if _, ok := convo["sharedInterests"].([]any); !ok {
		h.t.Fatalf("sharedInterests must be an array, never null or missing: %v", convo["sharedInterests"])
	}
	got := strs(convo["sharedInterests"])
	fetched := h.ok(viewer, "GET", "/v1/conversations/"+convo["conversationId"].(string))
	if !reflect.DeepEqual(strs(fetched["sharedInterests"]), got) {
		h.t.Fatalf("get %v differs from list %v", fetched["sharedInterests"], got)
	}
	if got == nil {
		got = []string{}
	}
	return got
}

// The peer's interests are only compared when the peer's "interests" audience admits the caller.
func TestSharedInterestsFollowTheInterestsAudience(t *testing.T) {
	h := newSocialHarness(t)
	h.interests(alice, "Music", "Art", "Gaming")
	// bob: a stranger to alice; cara: alice follows her; dev: friends with alice.
	for _, p := range []string{bob, cara, dev} {
		h.interests(p, "gaming", "MUSIC", "Cooking")
	}
	h.expect(h.call(alice, "POST", "/v1/users/"+cara+"/follow"), 200, "")
	h.ok(alice, "POST", "/v1/users/"+dev+"/friend-requests")
	h.ok(dev, "POST", "/v1/users/"+alice+"/friend-requests")
	if rel := h.relationship(alice, dev); rel["friendship"] != "accepted" {
		t.Fatalf("not friends: %v", rel)
	}
	if rel := h.relationship(alice, cara); rel["following"] != "active" || rel["friendship"] != "none" {
		t.Fatalf("not a plain follower: %v", rel)
	}
	both := []string{"Music", "Gaming"} // the caller's spelling and order, not the peer's
	cases := []struct {
		audience                string
		stranger, follower, pal bool
	}{
		{"everyone", true, true, true},
		{"followers", false, true, true},
		{"friends", false, false, true},
		{"nobody", false, false, false},
	}
	for _, tc := range cases {
		for peer, allowed := range map[string]bool{bob: tc.stranger, cara: tc.follower, dev: tc.pal} {
			h.fieldAudience(peer, "interests", tc.audience)
			want := []string{}
			if allowed {
				want = both
			}
			if got := h.shared(alice, peer); !reflect.DeepEqual(got, want) {
				t.Fatalf("audience %s, peer %s: got %v, want %v", tc.audience, map[string]string{bob: "stranger", cara: "follower", dev: "friend"}[peer], got, want)
			}
		}
	}
	// A locked profile (friends-only) hides interests on the profile card, so they are not offered here either.
	h.fieldAudience(bob, "interests", "everyone")
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{profileAudience}','"friends"') WHERE user_id=$1`, bob)
	if got := h.shared(alice, bob); len(got) != 0 {
		t.Fatalf("a locked profile leaked interests: %v", got)
	}
	// The caller's own interests audience does not matter: the caller always sees their own.
	h.fieldAudience(alice, "interests", "nobody")
	if got := h.shared(alice, cara); len(got) != 0 {
		// cara's audience is still "nobody" from the last loop iteration
		t.Fatalf("unexpected %v", got)
	}
	h.fieldAudience(cara, "interests", "everyone")
	if got := h.shared(alice, cara); !reflect.DeepEqual(got, both) {
		t.Fatalf("own audience should not hide own interests: %v", got)
	}
	// And the other way round, bob sees alice's only if alice allows it... alice's is "nobody" now.
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{profileAudience}','"public"') WHERE user_id=$1`, bob)
	if got := h.shared(cara, alice); len(got) != 0 {
		t.Fatalf("alice's hidden interests leaked to cara: %v", got)
	}
}

func TestSharedInterestsAreCaseInsensitiveStableAndCappedAtThree(t *testing.T) {
	h := newSocialHarness(t)
	h.interests(alice, "Photography", "music", "Gaming", "Art", "Food", "Solo")
	h.interests(bob, "FOOD", "art", "GAMING", "Music", "photography", "Hiking")
	want := []string{"Photography", "music", "Gaming"}
	for i := 0; i < 3; i++ {
		if got := h.shared(alice, bob); !reflect.DeepEqual(got, want) {
			t.Fatalf("run %d: got %v, want %v", i, got, want)
		}
	}
	// From bob's side the order and spelling are bob's own.
	if got := h.shared(bob, alice); !reflect.DeepEqual(got, []string{"FOOD", "art", "GAMING"}) {
		t.Fatalf("bob's view: %v", got)
	}
	// Nothing in common, missing and null interests all give an empty array.
	h.interests(bob, "Hiking")
	if got := h.shared(alice, bob); len(got) != 0 {
		t.Fatalf("nothing in common: %v", got)
	}
	h.exec(`UPDATE profiles SET data=data-'interests' WHERE user_id=$1`, bob)
	if got := h.shared(alice, bob); len(got) != 0 {
		t.Fatalf("missing interests: %v", got)
	}
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{interests}','null'::jsonb) WHERE user_id=$1`, bob)
	if got := h.shared(alice, bob); len(got) != 0 {
		t.Fatalf("null interests: %v", got)
	}
}

func TestSharedInterestsStopAtBlocksAndAgeBands(t *testing.T) {
	h := newSocialHarness(t)
	h.interests(alice, "Music")
	for _, p := range []string{bob, cara, dev} {
		h.interests(p, "Music")
	}
	h.ageAt(alice, 30)
	h.ageAt(bob, 30)
	h.ageAt(cara, 30)
	h.ageAt(dev, 30)
	ids := map[string]string{}
	for _, p := range []string{bob, cara, dev} {
		if got := h.shared(alice, p); !reflect.DeepEqual(got, []string{"Music"}) {
			t.Fatalf("%s: %v", p, got)
		}
		for _, c := range items(h.ok(alice, "GET", "/v1/conversations")) {
			if c["peer"].(map[string]any)["userId"] == p {
				ids[p] = c["conversationId"].(string)
			}
		}
	}
	// Blocked either way: the conversation, and with it the interests, is gone for the caller.
	h.expect(h.call(alice, "POST", "/v1/users/"+bob+"/block"), 200, "")
	h.expect(h.call(cara, "POST", "/v1/users/"+alice+"/block"), 200, "")
	// Barred by age band: dev became a minor.
	h.ageAt(dev, 15)
	for _, p := range []string{bob, cara, dev} {
		h.expect(h.call(alice, "GET", "/v1/conversations/"+ids[p]), 404, "NOT_FOUND")
	}
	h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 404, "NOT_FOUND")
	if list := items(h.ok(alice, "GET", "/v1/conversations")); len(list) != 0 {
		t.Fatalf("barred pairs are still listed: %v", list)
	}
}

func TestSharedInterestsRecordNoVisit(t *testing.T) {
	h := newSocialHarness(t)
	h.interests(alice, "Music", "Art")
	h.interests(bob, "Music", "Art")
	count := func() string {
		var out string
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT (SELECT count(*) FROM profile_visits)||'/'||coalesce((SELECT sum(visitors) FROM profile_visit_counts),0)`).Scan(&out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	before := count()
	for i := 0; i < 3; i++ {
		if got := h.shared(alice, bob); len(got) != 2 {
			t.Fatal(got)
		}
		if got := h.shared(bob, alice); len(got) != 2 {
			t.Fatal(got)
		}
	}
	if after := count(); after != before {
		t.Fatalf("conversation payloads recorded a visit: %s -> %s", before, after)
	}
	// The check is meaningful: opening the profile does record one.
	h.ok(alice, "GET", "/v1/users/"+bob+"/profile")
	if after := count(); after == before {
		t.Fatalf("expected a profile view to change %s", fmt.Sprint(before))
	}
}
