package httpapi

import (
	"fmt"
	"sort"
	"testing"
	"time"
)

// onlineBoth runs the Online filter (plus any other filters) through people search and Nearby.
func (h *socialHarness) onlineBoth(viewer string, extra map[string]any) (search, nearby []string) {
	h.t.Helper()
	return h.both(viewer, merge(map[string]any{"online": true}, extra))
}

func has(ids []string, id string) bool { return slicesContain(ids, id) }

// The filter admits exactly the members whose online audience admits the viewer (the rule of the per-row
// flag) and who have had session activity in the online window, for every audience and every kind of viewer.
func TestOnlineFilterFollowsTheAudienceMatrix(t *testing.T) {
	h := newSocialHarness(t)
	h.bobsCircle()
	h.session(bob, 10*time.Second)
	for _, audience := range []string{"everyone", "friends", "followers", "nobody", "bogus"} {
		h.policy(bob, "onlineAudience", audience)
		for _, v := range presenceViewers {
			if v.id == bob {
				continue
			}
			search, nearby := h.onlineBoth(v.id, nil)
			want := admits(audience, v.id)
			if audience == "bogus" {
				want = false
			}
			if has(search, bob) != want || has(nearby, bob) != want {
				t.Fatalf("%s audience, %s viewer: search %v nearby %v, want bob listed=%v", audience, v.name, has(search, bob), has(nearby, bob), want)
			}
			// Whoever the filter returns carries the precise row flag, and nobody else is flagged by it.
			if want {
				h.api.search.reset(v.id)
				for _, item := range items(h.expect(h.send(v.id, "POST", "/v1/discovery/search", map[string]any{"online": true}), 200, "").data) {
					if item["userId"] == bob && item["online"] != true {
						t.Fatalf("%s audience, %s viewer: filtered row is not flagged online: %v", audience, v.name, item)
					}
				}
			}
			// Without the filter bob is listed for everybody, whatever his audience.
			if all, _ := h.both(v.id, map[string]any{}); !has(all, bob) {
				t.Fatalf("%s audience, %s viewer: bob vanished without the filter", audience, v.name)
			}
		}
	}
}

func TestOnlineFilterNeedsRecentUsableSessionActivity(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	check := func(label string, want bool) {
		t.Helper()
		search, nearby := h.onlineBoth(alice, nil)
		if has(search, bob) != want || has(nearby, bob) != want {
			t.Fatalf("%s: search %v nearby %v, want %v", label, has(search, bob), has(nearby, bob), want)
		}
	}
	check("no session", false)
	h.session(bob, 0)
	check("active now", true)
	h.session(bob, 115*time.Second)
	check("active 115s ago", true)
	h.session(bob, 125*time.Second)
	check("stale by five seconds", false)
	h.session(bob, 3*time.Hour)
	check("active hours ago", false)
	// One recent session among stale ones is enough; the latest wins.
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour',now()-interval '20 seconds')`, bob)
	check("one stale and one recent session", true)
	// Revoked and expired sessions are not activity.
	h.exec(`DELETE FROM sessions WHERE user_id=$1`, bob)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at,revoked_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour',now(),now())`, bob)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at) VALUES(gen_random_uuid(),$1,now()-interval '1 minute',now())`, bob)
	check("revoked and expired sessions only", false)
	// Documented limit: a live connection alone (hub state is per node, not in SQL) does not make the
	// filter match, but when the member is matched the row flag is the precise one.
	h.connect(bob)
	check("connected without recent session activity", false)
	h.session(bob, 3*time.Second)
	check("connected with recent activity", true)
	// "online": false is the same as no filter.
	h.session(bob, time.Hour)
	if s, n := h.both(alice, map[string]any{"online": false}); !has(s, bob) || !has(n, bob) {
		t.Fatalf("online=false filtered: %v %v", s, n)
	}
}

func TestOnlineFilterExcludesBlockedAgeBarredAndHidesMinorsByDefault(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	h.session(bob, 4*time.Second)
	if s, n := h.onlineBoth(alice, nil); !has(s, bob) || !has(n, bob) {
		t.Fatalf("setup: %v %v", s, n)
	}
	for name, blocker := range map[string][2]string{"alice blocks bob": {alice, bob}, "bob blocks alice": {bob, alice}} {
		h.ok(blocker[0], "POST", "/v1/users/"+blocker[1]+"/block")
		if s, n := h.onlineBoth(alice, nil); has(s, bob) || has(n, bob) {
			t.Fatalf("%s: a blocked member is matched %v %v", name, s, n)
		}
		h.ok(blocker[0], "DELETE", "/v1/users/"+blocker[1]+"/block")
	}
	// Not discoverable: never found, online or not.
	h.policy(bob, "discoverable", false)
	if s, n := h.onlineBoth(alice, nil); has(s, bob) || has(n, bob) {
		t.Fatalf("an undiscoverable member is matched %v %v", s, n)
	}
	h.policy(bob, "discoverable", true)
	// A suspended member is not listed.
	h.exec(`UPDATE users SET status='suspended' WHERE user_id=$1`, bob)
	if s, n := h.onlineBoth(alice, nil); has(s, bob) || has(n, bob) {
		t.Fatalf("a suspended member is matched %v %v", s, n)
	}
	h.exec(`UPDATE users SET status='active' WHERE user_id=$1`, bob)

	// Minors: the minor default hides presence, so the filter finds nobody until they choose to show it.
	h.ageAt(alice, 15)
	h.ageAt(bob, 14)
	h.ageAt(cara, 16)
	h.session(cara, 5*time.Second)
	for _, minor := range []string{bob, cara} {
		h.policy(minor, "onlineAudience", "nobody") // the minor default (see domain.ApplyMinorDefaults)
	}
	if s, n := h.onlineBoth(alice, nil); has(s, bob) || has(n, bob) || has(s, cara) || has(n, cara) {
		t.Fatalf("minors who hide presence are matched %v %v", s, n)
	}
	h.policy(bob, "onlineAudience", "everyone")
	if s, n := h.onlineBoth(alice, nil); !has(s, bob) || !has(n, bob) || has(s, cara) {
		t.Fatalf("a minor who shows presence is not matched within the band %v %v", s, n)
	}
	// An adult never reaches the minor, whatever the minor shows.
	h.ageAt(dev, 40)
	h.place(dev, bengaluru.Latitude, bengaluru.Longitude)
	if s, n := h.onlineBoth(dev, nil); has(s, bob) || has(n, bob) {
		t.Fatalf("an adult reaches a minor through the online filter %v %v", s, n)
	}
	if s, n := h.onlineBoth(alice, nil); has(s, dev) || has(n, dev) {
		t.Fatalf("a minor reaches an adult through the online filter %v %v", s, n)
	}
}

func TestOnlineFilterPagesAndBindsIntoTheCursor(t *testing.T) {
	h := filterPeople(t, 0)
	var online []string
	for i := 0; i < 27; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 900+i)
		h.user(id, fmt.Sprintf("online_%d", i))
		h.ageAt(id, 30)
		h.north(id, 0.02)
		h.session(id, time.Duration(i)*time.Second)
		online = append(online, id)
	}
	// A stale one and a hidden one are not in the list, but are among the members.
	stale := "019a4000-0000-7000-8000-000000000990"
	h.user(stale, "stale_one")
	h.ageAt(stale, 30)
	h.north(stale, 0.02)
	h.session(stale, time.Hour)
	hidden := "019a4000-0000-7000-8000-000000000991"
	h.user(hidden, "hidden_one")
	h.ageAt(hidden, 30)
	h.north(hidden, 0.02)
	h.session(hidden, time.Second)
	h.policy(hidden, "onlineAudience", "nobody")
	sort.Strings(online)

	read := func(path string, body map[string]any) (ids []string, next string, code int, errCode string) {
		for page := 0; page < 5; page++ {
			h.api.search.reset(alice)
			h.api.clients.reset("127.0.0.1")
			r := h.send(alice, "POST", path, body)
			if r.status != 200 {
				return ids, "", r.status, r.code
			}
			for _, item := range items(r.data) {
				if item["online"] != true {
					t.Fatalf("a row of the online filter is not online: %v", item)
				}
				ids = append(ids, item["userId"].(string))
			}
			c, _ := r.data["nextCursor"].(string)
			if c == "" {
				return ids, "", 200, ""
			}
			next = c
			body = merge(body, map[string]any{"cursor": c})
		}
		return ids, next, 200, ""
	}
	for _, path := range []string{"/v1/discovery/search", "/v1/discover/nearby"} {
		body := map[string]any{"online": true}
		if path == "/v1/discover/nearby" {
			body["radiusKm"] = 100
		}
		ids, _, code, _ := read(path, body)
		if code != 200 || len(ids) != len(online) {
			t.Fatalf("%s: %d ids (%d), want %d", path, len(ids), code, len(online))
		}
		got := append([]string(nil), ids...)
		sort.Strings(got)
		if fmt.Sprint(got) != fmt.Sprint(online) || has(ids, stale) || has(ids, hidden) {
			t.Fatalf("%s: paging lost or invented members: %v", path, ids)
		}
		// The cursor of one filter set does not continue another: dropping or changing online is refused.
		h.api.search.reset(alice)
		h.api.clients.reset("127.0.0.1")
		first := h.send(alice, "POST", path, body)
		cursor, _ := first.data["nextCursor"].(string)
		if cursor == "" {
			t.Fatalf("%s: no cursor on a 27 member list", path)
		}
		for name, changed := range map[string]map[string]any{"dropped": {}, "false": {"online": false}} {
			if path == "/v1/discover/nearby" {
				changed = merge(changed, map[string]any{"radiusKm": 100})
			}
			h.api.search.reset(alice)
			h.api.clients.reset("127.0.0.1")
			if got := h.send(alice, "POST", path, merge(changed, map[string]any{"cursor": cursor})); got.status != 422 || got.code != "INVALID_CURSOR" {
				t.Fatalf("%s online %s: %d %q", path, name, got.status, got.code)
			}
		}
	}
}

func TestOnlineFilterCombinesWithOtherFilters(t *testing.T) {
	h := filterPeople(t, 0)
	for _, id := range []string{cara, dev, eli, bob} {
		h.session(id, 10*time.Second)
	}
	h.session(xan, 30*time.Minute) // known, not online
	for name, tc := range map[string]struct {
		filters map[string]any
		want    []string
	}{
		"online alone":         {map[string]any{}, sorted(bob, cara, dev, eli)},
		"online and country":   {map[string]any{"country": "IN"}, sorted(bob, dev, eli)},
		"online and man":       {map[string]any{"gender": "man"}, sorted(dev)},
		"online and ages":      {map[string]any{"ageMin": 21, "ageMax": 30}, sorted(dev, eli)},
		"online and language":  {map[string]any{"languages": []string{"en"}}, sorted(bob, cara)}, // bob is a default English speaker
		"online, none match":   {map[string]any{"country": "FR", "gender": "nonbinary"}, nil},
		"the stale one hidden": {map[string]any{"gender": "woman"}, sorted(cara)},
	} {
		s, n := h.onlineBoth(alice, tc.filters)
		if fmt.Sprint(s) != fmt.Sprint(tc.want) || fmt.Sprint(n) != fmt.Sprint(tc.want) {
			t.Fatalf("%s: search %v nearby %v want %v", name, s, n, tc.want)
		}
	}
}

// Rows carry up to three of the member's own interests and what they share with the viewer, both only when
// the member's interests audience is "everyone", and sharedInterests uses the viewer's spelling.
func TestDiscoveryRowsCarryInterestsAndSharedInterests(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.north(bob, 0.01)
	h.north(cara, 0.01)
	h.interests(alice, "Music", "Art", "Gaming", "Hiking", "Books")
	h.interests(bob, "gaming", "MUSIC", "Cooking", "art", "hiking")
	h.interests(cara, "Cooking", "Dance")
	row := func(path string, id string) map[string]any {
		h.api.search.reset(alice)
		h.api.clients.reset("127.0.0.1")
		body := map[string]any{}
		if path == "/v1/discover/nearby" {
			body["radiusKm"] = 25
		}
		for _, item := range items(h.expect(h.send(alice, "POST", path, body), 200, "").data) {
			if item["userId"] == id {
				return item
			}
		}
		t.Fatalf("%s: %s missing", path, id)
		return nil
	}
	for _, path := range []string{"/v1/discovery/search", "/v1/discover/nearby"} {
		b := row(path, bob)
		// Capped at three and spelled as the viewer typed them, in the viewer's order.
		if got := fmt.Sprint(b["sharedInterests"]); got != "[Music Art Gaming]" {
			t.Fatalf("%s: sharedInterests %s", path, got)
		}
		if got := strs(b["interests"]); len(got) == 0 || got[0] != "gaming" {
			t.Fatalf("%s: the member's own spelling is shown in interests: %v", path, got)
		}
		if c := row(path, cara); fmt.Sprint(c["sharedInterests"]) != "[]" || fmt.Sprint(strs(c["interests"])) != "[Cooking Dance]" {
			t.Fatalf("%s: nothing in common: %v", path, c)
		}
		// A hidden interests field shows neither list, and nothing can be inferred.
		for _, audience := range []string{"nobody", "friends", "followers"} {
			h.fieldAudience(bob, "interests", audience)
			hidden := row(path, bob)
			if _, found := hidden["interests"]; found {
				t.Fatalf("%s: interests shown for audience %s", path, audience)
			}
			if _, found := hidden["sharedInterests"]; found {
				t.Fatalf("%s: sharedInterests shown for audience %s", path, audience)
			}
		}
		h.fieldAudience(bob, "interests", "everyone")
	}
	// A viewer without interests gets an empty array, never null.
	h.interests(alice)
	if got, found := row("/v1/discovery/search", bob)["sharedInterests"]; !found || fmt.Sprint(got) != "[]" {
		t.Fatalf("empty viewer: %v (%v)", got, found)
	}
}
