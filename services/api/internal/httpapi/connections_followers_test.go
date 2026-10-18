package httpapi

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"

	"hiyall/services/api/internal/domain"
)

// befriend makes a and b accepted friends without going through the request flow.
func (h *socialHarness) befriend(a, b string) {
	h.t.Helper()
	h.exec(`INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'accepted')`, a, b)
}

// canSee is the profile's canSeeConnections flag as another member sees it.
func (h *socialHarness) canSee(viewer, owner string) any {
	h.t.Helper()
	return h.call(viewer, "GET", "/v1/users/"+owner+"/profile").data["canSeeConnections"]
}

// listAccess is the status of the three lists of owner for viewer: followers, following, friends.
func (h *socialHarness) listAccess(viewer, owner string) [3]int {
	h.t.Helper()
	var out [3]int
	for i, kind := range []string{"followers", "following", "friends"} {
		out[i] = h.call(viewer, "GET", "/v1/users/"+owner+"/"+kind).status
	}
	return out
}

// Who may open an adult member's followers and following lists, and who may open the friends list.
func TestFollowersOfAnAdultMayOpenTheirFollowersAndFollowingListsButNotTheFriendsList(t *testing.T) {
	h := newSocialHarness(t)
	for _, who := range []string{bob, alice, cara, dev, eli, xan, yui} {
		h.ageAt(who, 30)
	}
	// Defaults, not overrides: this is what a new adult gets.
	if got := h.ok(bob, "GET", "/v1/me/privacy")["fieldAudiences"].(map[string]any)["connections"]; got != "followers" {
		t.Fatalf("an adult's connections default is %v", got)
	}
	// Something to list in each direction.
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	h.ok(bob, "POST", "/v1/users/"+eli+"/follow")
	h.befriend(bob, eli)
	h.befriend(bob, dev)

	const (
		ok     = 200
		denied = 403
		hidden = 404
	)
	check := func(label, viewer string, want [3]int, flag any) {
		t.Helper()
		h.api.clients.reset("127.0.0.1") // many calls from one test address
		if got := h.listAccess(viewer, bob); got != want {
			t.Fatalf("%s: followers/following/friends %v, want %v", label, got, want)
		}
		if viewer != bob {
			if got := h.canSee(viewer, bob); got != flag {
				t.Fatalf("%s: canSeeConnections %v, want %v", label, got, flag)
			}
		}
	}

	// The owner reads their own, all three, and their own profile carries no flag.
	check("owner", bob, [3]int{ok, ok, ok}, nil)
	same(t, ids(h.ok(bob, "GET", "/v1/users/"+bob+"/followers")), cara)
	same(t, ids(h.ok(bob, "GET", "/v1/users/"+bob+"/following")), eli)

	// An active follower reads followers and following, read-only, but not the friends list.
	check("follower", cara, [3]int{ok, ok, denied}, true)
	same(t, ids(h.ok(cara, "GET", "/v1/users/"+bob+"/followers")), cara)
	same(t, ids(h.ok(cara, "GET", "/v1/users/"+bob+"/following")), eli)
	// A stranger reads none.
	check("non-follower", xan, [3]int{denied, denied, denied}, false)
	h.expect(h.call(xan, "GET", "/v1/users/"+bob+"/followers"), 403, "CONNECTIONS_PRIVATE")
	// A friend (who does not follow) reads all three: friends are part of "followers".
	check("friend", eli, [3]int{ok, ok, ok}, true)
	friends := ids(h.ok(eli, "GET", "/v1/users/"+bob+"/friends"))
	sort.Strings(friends)
	wantFriends := []string{dev, eli}
	sort.Strings(wantFriends)
	same(t, friends, wantFriends...)

	// A pending follow request does not count; accepting it does.
	h.policy(bob, "followPolicy", "approval")
	same(t, []string{h.ok(yui, "POST", "/v1/users/"+bob+"/follow")["following"].(string)}, "pending")
	check("pending request", yui, [3]int{denied, denied, denied}, false)
	h.ok(bob, "POST", "/v1/users/"+yui+"/follow-requests/accept")
	check("accepted request", yui, [3]int{ok, ok, denied}, true)
	h.policy(bob, "followPolicy", "everyone")

	// Unfollowing takes the access back at once.
	h.ok(xan, "POST", "/v1/users/"+bob+"/follow")
	check("follows again", xan, [3]int{ok, ok, denied}, true)
	h.ok(xan, "DELETE", "/v1/users/"+bob+"/follow")
	check("unfollowed", xan, [3]int{denied, denied, denied}, false)

	// Following is one-way: the owner following the viewer gives the viewer nothing.
	h.ok(bob, "POST", "/v1/users/"+xan+"/follow")
	check("followed by the owner only", xan, [3]int{denied, denied, denied}, false)
	h.ok(bob, "DELETE", "/v1/users/"+xan+"/follow")

	// A block either way hides the member entirely, and removes the follow.
	h.ok(cara, "POST", "/v1/users/"+bob+"/block")
	check("blocked by the viewer", cara, [3]int{hidden, hidden, hidden}, nil)
	h.ok(cara, "DELETE", "/v1/users/"+bob+"/block")
	check("unblocked: the follow is gone", cara, [3]int{denied, denied, denied}, false)
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	h.ok(bob, "POST", "/v1/users/"+cara+"/block")
	h.ok(bob, "DELETE", "/v1/users/"+cara+"/block")
	check("blocked by the owner", cara, [3]int{denied, denied, denied}, false)
	// A block seen from inside the lists: a follower who is blocked by the viewer is not listed.
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	h.ok(eli, "POST", "/v1/users/"+bob+"/follow")
	h.ok(eli, "POST", "/v1/users/"+dev+"/block")
	got := ids(h.ok(dev, "GET", "/v1/users/"+bob+"/followers"))
	sort.Strings(got)
	want := []string{cara, yui}
	sort.Strings(want)
	same(t, got, want...)
	h.ok(eli, "DELETE", "/v1/users/"+dev+"/block")

	// The other age band is barred like a block, even with an active follow.
	h.ok(xan, "POST", "/v1/users/"+bob+"/follow")
	check("same band follower", xan, [3]int{ok, ok, denied}, true)
	h.ageAt(xan, 15)
	check("age-barred follower", xan, [3]int{hidden, hidden, hidden}, nil)
	h.expect(h.call(xan, "GET", "/v1/users/"+bob+"/profile"), 404, "NOT_FOUND")
	h.ageAt(xan, 30)

	// The owner can still narrow it: the field audience rules apply to anyone who is not the owner.
	h.policy2(bob, "connections", "friends")
	check("narrowed to friends: follower", yui, [3]int{denied, denied, denied}, false)
	check("narrowed to friends: friend", eli, [3]int{ok, ok, ok}, true)
	h.policy2(bob, "connections", "nobody")
	check("narrowed to nobody: friend", eli, [3]int{denied, denied, denied}, false)
	h.policy2(bob, "connections", "everyone")
	check("opened to everyone", xan, [3]int{ok, ok, ok}, true)
	h.policy2(bob, "connections", "followers")
	// A profile that is itself closed to the viewer closes the lists too, whatever the field says.
	h.policy(bob, "profileAudience", "friends")
	check("closed profile: follower", yui, [3]int{denied, denied, denied}, nil)
	check("closed profile: friend", eli, [3]int{ok, ok, ok}, true)
	h.policy(bob, "profileAudience", "public")
	// A deactivated or unfinished account is not found.
	h.exec(`UPDATE users SET status='deactivated' WHERE user_id=$1`, bob)
	h.expect(h.call(yui, "GET", "/v1/users/"+bob+"/followers"), 404, "NOT_FOUND")
}

// A minor's lists stay friends-only: a follower of a minor does not get in, a friend does.
func TestFollowersOfAMinorCannotOpenTheirLists(t *testing.T) {
	h := newSocialHarness(t)
	minor, follower, friend := cara, dev, eli
	for _, who := range []string{minor, follower, friend} {
		h.ageAt(who, 15)
	}
	// What completing onboarding as a minor stores.
	defaults := domain.DefaultPrivacy()
	domain.ApplyMinorDefaults(&defaults)
	raw, _ := json.Marshal(defaults)
	h.exec(`UPDATE privacy_settings SET data=$2 WHERE user_id=$1`, minor, raw)
	if got := h.ok(minor, "GET", "/v1/me/privacy")["fieldAudiences"].(map[string]any)["connections"]; got != "friends" {
		t.Fatalf("a minor's connections default is %v", got)
	}
	h.ok(follower, "POST", "/v1/users/"+minor+"/follow")
	h.ok(minor, "POST", "/v1/users/"+friend+"/follow")
	h.befriend(minor, friend)

	if got := h.listAccess(follower, minor); got != [3]int{403, 403, 403} {
		t.Fatalf("follower of a minor: %v", got)
	}
	h.expect(h.call(follower, "GET", "/v1/users/"+minor+"/following"), 403, "CONNECTIONS_PRIVATE")
	if got := h.canSee(follower, minor); got != false {
		t.Fatalf("canSeeConnections for a follower of a minor: %v", got)
	}
	if got := h.listAccess(friend, minor); got != [3]int{200, 200, 200} {
		t.Fatalf("friend of a minor: %v", got)
	}
	if got := h.canSee(friend, minor); got != true {
		t.Fatalf("canSeeConnections for a friend of a minor: %v", got)
	}
	if got := h.listAccess(minor, minor); got != [3]int{200, 200, 200} {
		t.Fatalf("a minor's own lists: %v", got)
	}
	// An adult cannot reach a minor at all, followers or not.
	h.ageAt(xan, 30)
	h.expect(h.call(xan, "GET", "/v1/users/"+minor+"/followers"), 404, "NOT_FOUND")
}

// The followers stat tap and the profile say the same thing, and Visitors is never someone else's to list.
func TestVisitorsOfAnotherMemberAreNeverListedEvenToFollowers(t *testing.T) {
	h := newSocialHarness(t)
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	h.visit(alice, bob, "1 hour")
	if got := h.canSee(cara, bob); got != true {
		t.Fatalf("canSeeConnections %v", got)
	}
	stats, _ := h.statsOf(cara, bob)
	if stats["visitors"] != float64(2) { // alice, and cara herself once she opened the profile
		t.Fatalf("stats %v", stats)
	}
	for _, path := range []string{"/v1/users/" + bob + "/visitors", "/v1/users/" + bob + "/profile/visitors", "/v1/me/visitors?user=" + bob} {
		if r := h.call(cara, "GET", path); r.status == 200 && len(items(r.data)) > 0 {
			t.Fatalf("%s listed visitors: %v", path, r.data)
		}
	}
	// The one route that exists (profile v2) is opt-in: with the default settings nobody gets a list, not even the owner.
	h.expect(h.call(cara, "GET", "/v1/users/"+bob+"/visitors"), 403, "VISITORS_PRIVATE")
}

// A follower sees a followed member's followers and public stories, a stranger only the public ones, and the
// friends-only ones need a friendship; the Stories count on the profile is the same number.
func TestFollowersWatchFollowersAndPublicStoriesButFriendsStoriesNeedFriendship(t *testing.T) {
	h := newSocialHarness(t)
	for _, who := range []string{bob, alice, cara, dev, eli} {
		h.ageAt(who, 30)
	}
	story := func(audience string) string {
		return h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": audience, "background": "lime", "audience": audience}), 201, "").data["storyId"].(string)
	}
	pub, fol, fri := story("public"), story("followers"), story("friends")
	listed := func(viewer string) []string {
		t.Helper()
		out := []string{}
		for _, row := range items(h.ok(viewer, "GET", "/v1/users/"+bob+"/stories")) {
			out = append(out, row["body"].(string))
		}
		return out
	}
	count := func(viewer string) float64 {
		stats, _ := h.statsOf(viewer, bob)
		return stats["stories"].(float64)
	}
	has := func(viewer string, want ...string) {
		t.Helper()
		got := listed(viewer)
		if len(got) != len(want) || count(viewer) != float64(len(want)) {
			t.Fatalf("%s: stories %v, count %v, want %v", viewer, got, count(viewer), want)
		}
		seen := map[string]bool{}
		for _, g := range got {
			seen[g] = true
		}
		for _, w := range want {
			if !seen[w] {
				t.Fatalf("%s: stories %v, want %v", viewer, got, want)
			}
		}
	}
	has(cara, "public") // a stranger
	h.ok(cara, "POST", "/v1/users/"+bob+"/follow")
	has(cara, "public", "followers") // a follower; never the friends-only one
	// A follower may open and view them (the viewer behind the stat tap).
	h.ok(cara, "POST", "/v1/stories/"+fol+"/view")
	h.ok(cara, "POST", "/v1/stories/"+pub+"/view")
	h.expect(h.call(cara, "POST", "/v1/stories/"+fri+"/view"), 404, "NOT_FOUND")
	// A pending request does not count.
	h.policy(bob, "followPolicy", "approval")
	h.ok(dev, "POST", "/v1/users/"+bob+"/follow")
	has(dev, "public")
	h.expect(h.call(dev, "POST", "/v1/stories/"+fol+"/view"), 404, "NOT_FOUND")
	h.ok(bob, "POST", "/v1/users/"+dev+"/follow-requests/accept")
	has(dev, "public", "followers")
	// Unfollowing takes the followers stories away again.
	h.ok(cara, "DELETE", "/v1/users/"+bob+"/follow")
	has(cara, "public")
	// A friend sees all three.
	h.befriend(bob, eli)
	has(eli, "public", "followers", "friends")
	// The owner's own profile counts their own.
	if stats, _ := h.statsOf(bob, bob); stats["stories"] != float64(3) {
		t.Fatalf("own stats %v", stats)
	}
}

// 0026 moves adults who are still on the old "friends" default to "followers", leaves minors and every other
// choice alone, bumps the version only where a row changes, and changes nothing when run again.
func TestMigration0026OpensAdultConnectionsToFollowersAndLeavesMinorsAlone(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0026_connections_followers_default.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	const (
		adult    = "019a4000-0000-7000-8000-000000000e01" // adult, friends: moves
		minor    = "019a4000-0000-7000-8000-000000000e02" // 17 years, friends: untouched
		unknown  = "019a4000-0000-7000-8000-000000000e03" // no birth date counts as an adult: moves
		chose    = "019a4000-0000-7000-8000-000000000e04" // adult who chose nobody: untouched
		open     = "019a4000-0000-7000-8000-000000000e05" // adult who chose everyone: untouched
		already  = "019a4000-0000-7000-8000-000000000e06" // adult already on followers: untouched, version kept
		bare     = "019a4000-0000-7000-8000-000000000e07" // no field audiences at all: untouched
		eighteen = "019a4000-0000-7000-8000-000000000e08" // turned 18 today: adult, moves
		minorToo = "019a4000-0000-7000-8000-000000000e09" // turns 18 tomorrow: minor, untouched
	)
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_26`,
		`SET LOCAL search_path = migration_scratch_26, public`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`CREATE TABLE member_ages(user_id uuid PRIMARY KEY REFERENCES users(user_id), birth_date date NOT NULL)`,
		`CREATE TABLE privacy_settings(user_id uuid PRIMARY KEY REFERENCES users(user_id), data jsonb NOT NULL, version bigint NOT NULL DEFAULT 1, updated_at timestamptz NOT NULL DEFAULT '2020-01-01')`,
		`INSERT INTO users VALUES ('` + strings.Join([]string{adult, minor, unknown, chose, open, already, bare, eighteen, minorToo}, `'),('`) + `')`,
		`INSERT INTO member_ages VALUES
 ('` + adult + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>30)),
 ('` + minor + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>17)),
 ('` + chose + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>30)),
 ('` + open + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>30)),
 ('` + already + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>30)),
 ('` + eighteen + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>18)),
 ('` + minorToo + `',(now() AT TIME ZONE 'UTC')::date-make_interval(years=>18)+interval '1 day')`,
		`INSERT INTO privacy_settings(user_id,data,version) VALUES
 ('` + adult + `','{"customKey":"kept","onlineAudience":"everyone","fieldAudiences":{"connections":"friends","location":"everyone"}}',4),
 ('` + minor + `','{"onlineAudience":"nobody","fieldAudiences":{"connections":"friends","location":"friends"}}',2),
 ('` + unknown + `','{"fieldAudiences":{"connections":"friends"}}',1),
 ('` + chose + `','{"fieldAudiences":{"connections":"nobody"}}',6),
 ('` + open + `','{"fieldAudiences":{"connections":"everyone"}}',5),
 ('` + already + `','{"fieldAudiences":{"connections":"followers"}}',9),
 ('` + bare + `','{"profileAudience":"friends"}',1),
 ('` + eighteen + `','{"fieldAudiences":{"connections":"friends"}}',3),
 ('` + minorToo + `','{"fieldAudiences":{"connections":"friends"}}',3)`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	// The scratch schema uses the real age_band(), which reads member_ages from the first schema in the path.
	var band string
	if err = tx.QueryRow(ctx, `SELECT age_band('`+minor+`')`).Scan(&band); err != nil || band != "minor" {
		t.Fatalf("scratch band %q (%v)", band, err)
	}
	snapshot := func() map[string]string {
		rows, err := tx.Query(ctx, `SELECT user_id::text,version||' '||coalesce(data #>> '{fieldAudiences,connections}','-')||' '||coalesce(data->>'customKey','')||' '||(updated_at>'2021-01-01')::text FROM privacy_settings`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]string{}
		for rows.Next() {
			var id, line string
			if err = rows.Scan(&id, &line); err != nil {
				t.Fatal(err)
			}
			out[id] = line
		}
		return out
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("migration: %v", err)
	}
	first := snapshot()
	for id, want := range map[string]string{
		adult:    "5 followers kept true",
		unknown:  "2 followers  true",
		eighteen: "4 followers  true",
		minor:    "2 friends  false",
		minorToo: "3 friends  false",
		chose:    "6 nobody  false",
		open:     "5 everyone  false",
		already:  "9 followers  false",
		bare:     "1 -  false",
	} {
		if first[id] != want {
			t.Fatalf("%s is %q after the migration, want %q", id, first[id], want)
		}
	}
	var online, location string
	if err = tx.QueryRow(ctx, `SELECT data->>'onlineAudience',data #>> '{fieldAudiences,location}' FROM privacy_settings WHERE user_id=$1`, adult).Scan(&online, &location); err != nil || online != "everyone" || location != "everyone" {
		t.Fatalf("other keys moved: %q %q (%v)", online, location, err)
	}
	if _, err = tx.Exec(ctx, string(migration)); err != nil {
		t.Fatal(err)
	}
	for id, line := range snapshot() {
		if first[id] != line {
			t.Fatalf("running it again changed %s: %q -> %q", id, first[id], line)
		}
	}
	_ = tx.Rollback(ctx)
	var exists bool
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_26.privacy_settings') IS NOT NULL`).Scan(&exists); err != nil || exists {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
