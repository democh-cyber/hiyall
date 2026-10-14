package httpapi

import (
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// ageAt stores a birth date that makes the member exactly `years` old today (their birthday is today),
// or years old until `daysUntilNext` days from now when negative. It writes straight to the table, so a
// test sets any age without waiting for time to pass.
func (h *socialHarness) ageAt(id string, years int) { h.ageOffset(id, years, 0) }

// ageOffset is ageAt shifted by days: a positive shift makes the birth date earlier (so the member has
// had the birthday for that many days), a negative one later (the birthday is that many days away).
func (h *socialHarness) ageOffset(id string, years, days int) {
	h.t.Helper()
	h.exec(`INSERT INTO member_ages(user_id,birth_date) VALUES($1,(now() AT TIME ZONE 'UTC')::date-make_interval(years=>$2,days=>$3))
 ON CONFLICT(user_id) DO UPDATE SET birth_date=excluded.birth_date`, id, years, days)
}

// setAge stores an age, or removes the stored birth date for 0 so the age is unknown. Seed gives Anjali and Niko
// birth dates, so a test that wants an unknown age asks for it.
func (h *socialHarness) setAge(id string, years int) {
	h.t.Helper()
	if years == 0 {
		h.exec(`DELETE FROM member_ages WHERE user_id=$1`, id)
		return
	}
	h.ageAt(id, years)
}

// markers are the content the target owns, so each path can be checked for visibility.
const targetPost = "post by the target"

// reach tries every path between a and b once and reports which answered as available. "Available" is anything
// except the 404 a block gives: a path that is open for the pair can still answer 403 for another reason.
func (h *socialHarness) reach(a, b string) map[string]bool {
	h.t.Helper()
	got := map[string]bool{}
	status := func(name string, r reply) { got[name] = r.status != 404 }

	h.policy(b, "followPolicy", "everyone")
	h.policy(b, "messagesFrom", "everyone")
	h.policy(b, "commentsFrom", "everyone")
	post := h.post(b, "public", targetPost)
	story := h.expect(h.send(b, "POST", "/v1/stories", map[string]any{"body": "gm", "background": "pink", "audience": "public"}), 201, "").data["storyId"].(string)
	space := makeSpace(h, b, "community", "public", 10, nil)

	// Profiles and people.
	status("profile", h.send(a, "GET", "/v1/users/"+b+"/profile", nil))
	status("followers list", h.send(a, "GET", "/v1/users/"+b+"/followers", nil))
	status("follow", h.send(a, "POST", "/v1/users/"+b+"/follow", nil))
	status("friend request", h.send(a, "POST", "/v1/users/"+b+"/friend-requests", nil))
	h.api.search.reset(a)
	search := h.send(a, "POST", "/v1/discovery/search", map[string]any{})
	got["people search"] = slicesContain(userIDs(items(search.data)), b)
	h.visible(a)
	h.visible(b)
	h.exec(`INSERT INTO user_locations(user_id,latitude,longitude) VALUES($1,12.97,77.59),($2,12.97,77.59) ON CONFLICT(user_id) DO UPDATE SET updated_at=now()`, a, b)
	h.api.search.reset(a)
	nearby := h.send(a, "POST", "/v1/discover/nearby", map[string]any{})
	got["nearby"] = nearby.status == 200 && slicesContain(userIDs(items(nearby.data)), b)

	// Chat: opening a conversation, the peer's devices, and the list.
	status("peer devices", h.send(a, "GET", "/v1/users/"+b+"/devices", nil))
	status("open conversation", h.send(a, "POST", "/v1/conversations", map[string]string{"userId": b}))

	// Content.
	got["user posts"] = len(items(h.send(a, "GET", "/v1/users/"+b+"/posts", nil).data)) > 0
	status("post", h.send(a, "GET", "/v1/posts/"+post, nil))
	status("reaction", h.send(a, "PUT", "/v1/posts/"+post+"/reaction", map[string]string{"reaction": "heart"}))
	status("comment", h.send(a, "POST", "/v1/posts/"+post+"/comments", map[string]string{"body": "hi"}))
	status("comments list", h.send(a, "GET", "/v1/posts/"+post+"/comments", nil))
	status("save", h.send(a, "PUT", "/v1/posts/"+post+"/save", nil))
	status("story view", h.send(a, "POST", "/v1/stories/"+story+"/view", nil))
	got["everyone feed"] = slicesContain(feedBodies(h, a, "everyone"), targetPost)

	// Spaces.
	status("space", h.send(a, "GET", "/v1/spaces/"+space, nil))
	got["space list"] = slicesContain(spaceIDs(items(h.send(a, "GET", "/v1/spaces?kind=community", nil).data)), space)
	status("space join", h.send(a, "PUT", "/v1/spaces/"+space+"/membership", map[string]string{}))

	// State that exists regardless of what the API allows now: a follow, a friendship, a pending request, a
	// notification and a conversation, written straight to the tables, so the readers are checked on their own.
	h.exec(`INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active') ON CONFLICT(follower_id,followee_id) DO UPDATE SET state='active',removed_at=NULL`, a, b)
	got["following feed"] = slicesContain(feedBodies(h, a, "following"), targetPost)
	tray := items(h.send(a, "GET", "/v1/stories/tray", nil).data)
	got["story tray"] = false
	for _, group := range tray {
		if group["author"].(map[string]any)["userId"] == b {
			got["story tray"] = true
		}
	}
	h.exec(`INSERT INTO notifications(notification_id,recipient_id,actor_id,event,target_id) VALUES($1,$2,$3,'follow.started',$3)`, uuid.NewString(), a, b)
	got["notifications"] = len(items(h.send(a, "GET", "/v1/notifications", nil).data)) > 0 && h.send(a, "GET", "/v1/notifications/unread-count", nil).data["unreadCount"] != float64(0)
	low, high := a, b
	if low > high {
		low, high = high, low
	}
	h.exec(`DELETE FROM friendships WHERE user_low_id=$1 AND user_high_id=$2`, low, high)
	h.exec(`INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES($1,$2,$3,$4,'pending')`, uuid.NewString(), low, high, b)
	got["incoming requests"] = len(items(h.send(a, "GET", "/v1/me/friend-requests?direction=incoming", nil).data)) > 0
	h.exec(`UPDATE friendships SET status='accepted' WHERE user_low_id=$1 AND user_high_id=$2`, low, high)
	got["friends list"] = slicesContain(userIDs(items(h.send(a, "GET", "/v1/me/friends", nil).data)), b)
	got["following list"] = slicesContain(userIDs(items(h.send(a, "GET", "/v1/me/following", nil).data)), b)
	h.exec(`INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) VALUES($1,$2,$3,$4,'active') ON CONFLICT(user_low_id,user_high_id) DO NOTHING`, uuid.NewString(), low, high, a)
	var convo string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT conversation_id::text FROM conversations WHERE user_low_id=$1 AND user_high_id=$2`, low, high).Scan(&convo); err != nil {
		h.t.Fatal(err)
	}
	h.exec(`INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at) VALUES($1,$2,$3,now()),($1,$3,$2,now()) ON CONFLICT DO NOTHING`, convo, a, b)
	got["conversation list"] = len(items(h.send(a, "GET", "/v1/conversations", nil).data)) > 0
	status("conversation", h.send(a, "GET", "/v1/conversations/"+convo, nil))
	return got
}

func userIDs(list []map[string]any) []string {
	var out []string
	for _, item := range list {
		switch {
		case item["userId"] != nil:
			out = append(out, item["userId"].(string))
		case item["user"] != nil:
			out = append(out, item["user"].(map[string]any)["userId"].(string))
		}
	}
	return out
}

func spaceIDs(list []map[string]any) []string {
	var out []string
	for _, item := range list {
		out = append(out, item["spaceId"].(string))
	}
	return out
}

func slicesContain(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// expectAll fails for every path whose availability differs from want.
func expectAll(t *testing.T, got map[string]bool, want bool, label string) {
	t.Helper()
	var wrong []string
	for path, open := range got {
		if open != want {
			wrong = append(wrong, path)
		}
	}
	sort.Strings(wrong)
	if len(got) < 25 {
		t.Fatalf("%s: only %d paths were exercised", label, len(got))
	}
	if len(wrong) > 0 {
		state := "open"
		if !want {
			state = "barred"
		}
		t.Fatalf("%s: expected every path %s, but these are not: %s", label, state, strings.Join(wrong, ", "))
	}
}

var bandPairs = []struct {
	name       string
	a, b       string
	aAge, bAge int // 0: no birth date stored (unknown)
	sameBand   bool
}{
	{"two adults", cara, xan, 30, 40, true},
	{"unknown age is an adult", alice, cara, 0, 30, true},
	{"two unknown ages", alice, bob, 0, 0, true},
	{"two minors", dev, eli, 15, 16, true},
	{"thirteen and seventeen", dev, eli, 13, 17, true},
	{"eighteen and an adult", dev, cara, 18, 30, true},
	{"minor reaching an adult", dev, cara, 15, 30, false},
	{"adult reaching a minor", cara, dev, 30, 15, false},
	{"unknown age reaching a minor", alice, dev, 0, 15, false},
	{"minor reaching an unknown age", dev, alice, 15, 0, false},
	{"seventeen and eighteen", dev, eli, 17, 18, false},
}

// Minors and adults do not see or reach each other on any path; inside a band everything is open.
func TestAgeBandIsolationBarsEveryPathAcrossBands(t *testing.T) {
	for _, tc := range bandPairs {
		t.Run(tc.name, func(t *testing.T) {
			h := newSocialHarness(t)
			for id, age := range map[string]int{tc.a: tc.aAge, tc.b: tc.bAge} {
				h.setAge(id, age)
			}
			expectAll(t, h.reach(tc.a, tc.b), tc.sameBand, tc.name)
		})
	}
}

// AGE_BAND_ISOLATION=false restores block-only behaviour: every cross-band path opens, and a block still bars.
func TestAgeBandIsolationOffRestoresBlockOnlyBehaviour(t *testing.T) {
	for _, tc := range bandPairs {
		t.Run(tc.name, func(t *testing.T) {
			h := newSocialHarnessWith(t, store.WithAgeBandIsolation(false))
			for id, age := range map[string]int{tc.a: tc.aAge, tc.b: tc.bAge} {
				h.setAge(id, age)
			}
			expectAll(t, h.reach(tc.a, tc.b), true, tc.name+" with isolation off")
		})
	}
	for _, off := range []bool{false, true} {
		h := newSocialHarnessWith(t, store.WithAgeBandIsolation(off))
		h.ageAt(dev, 15)
		h.ageAt(eli, 15)
		h.expect(h.call(dev, "POST", "/v1/users/"+eli+"/block"), 200, "")
		expectAll(t, h.reach(dev, eli), false, fmt.Sprintf("blocked pair, isolation %v", off))
	}
}

// A member who has no stored birth date counts as an adult, in the SQL function and in every path.
func TestUnknownBirthDateIsAnAdult(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 0)
	var band string
	var age *int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT age_band($1),member_age($1)`, alice).Scan(&band, &age); err != nil || band != "adult" || age != nil {
		t.Fatalf("unknown age: band %q age %v (%v)", band, age, err)
	}
	h.ageAt(cara, 30)
	h.ageAt(dev, 15)
	if !h.reach(alice, cara)["profile"] {
		t.Fatal("an unknown age could not reach an adult")
	}
}

// member_age and age_band agree with the Go calculation on and around the birthdays that matter.
func TestSQLAgeBandsMatchTheGoCalculation(t *testing.T) {
	h := newSocialHarness(t)
	today := time.Now().UTC()
	for _, tc := range []struct{ years, days int }{
		{13, 0}, {13, -1}, {13, 1}, {12, 0}, {12, 364}, {17, 0}, {17, -1}, {18, 0}, {18, -1}, {18, 1}, {30, 0}, {99, 0}, {0, 0}, {0, 100},
	} {
		h.ageOffset(cara, tc.years, tc.days)
		var birth time.Time
		var age int
		var band string
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT birth_date::timestamp,member_age($1),age_band($1) FROM member_ages WHERE user_id=$1`, cara).Scan(&birth, &age, &band); err != nil {
			t.Fatal(err)
		}
		if want := domain.AgeAt(birth, today); age != want || band != domain.BandAt(birth, today) {
			t.Fatalf("born %s: SQL age %d band %s, Go age %d band %s", birth.Format(time.DateOnly), age, band, want, domain.BandAt(birth, today))
		}
	}
	// A leap-day birth turns a year older on 1 March in common years, like AgeAt.
	for _, born := range []string{"2012-02-29", "2000-02-29", "2008-02-29"} {
		h.exec(`UPDATE member_ages SET birth_date=$2 WHERE user_id=$1`, cara, born)
		var age int
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT member_age($1)`, cara).Scan(&age); err != nil {
			t.Fatal(err)
		}
		birth, _ := time.Parse(time.DateOnly, born)
		if age != domain.AgeAt(birth, today) {
			t.Fatalf("leap-day birth %s: SQL %d, Go %d", born, age, domain.AgeAt(birth, today))
		}
	}
	// A future birth date cannot be stored.
	if _, err := h.db.Pool.Exec(h.ctx, `UPDATE member_ages SET birth_date=current_date+1 WHERE user_id=$1`, cara); err == nil {
		t.Fatal("a birth date in the future was accepted")
	}
	// interaction_barred is a plain boolean over blocks and bands, and never bars a member from themselves.
	h.ageAt(dev, 15)
	var self, cross, same bool
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT interaction_barred($1,$1),interaction_barred($1,$2),interaction_barred($2,$2)`, dev, cara).Scan(&self, &cross, &same); err != nil || self || !cross || same {
		t.Fatalf("self %v cross %v same %v (%v)", self, cross, same, err)
	}
}

// A relationship made inside one band goes dark when the pair ends up in different bands and comes back when
// they share a band again; nothing is deleted. Birthdays are moved in the table, not waited for.
func TestExistingRelationshipsGoDarkAcrossBandsAndReturn(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 16)
	h.ageAt(eli, 16)
	h.policy(dev, "messagesFrom", "everyone")
	h.policy(eli, "messagesFrom", "everyone")
	phone, other := h.register(dev), h.register(eli)
	h.ok(dev, "POST", "/v1/users/"+eli+"/friend-requests")
	h.ok(eli, "POST", "/v1/users/"+dev+"/friend-requests")
	convo := h.expect(h.send(dev, "POST", "/v1/conversations", map[string]string{"userId": eli}), 200, "").data["conversationId"].(string)
	path := "/v1/conversations/" + convo
	h.expect(h.send(dev, "POST", path+"/messages", message(phone, other)), 200, "")
	post := h.post(eli, "public", "eli's post")
	h.ok(dev, "POST", "/v1/notifications/read-all")
	h.exec(`INSERT INTO notifications(notification_id,recipient_id,actor_id,event,target_id) VALUES($1,$2,$3,'follow.started',$3)`, uuid.NewString(), dev, eli)

	visible := func() map[string]bool {
		out := map[string]bool{}
		out["profile"] = h.send(dev, "GET", "/v1/users/"+eli+"/profile", nil).status == 200
		out["profile (other way)"] = h.send(eli, "GET", "/v1/users/"+dev+"/profile", nil).status == 200
		out["friends"] = slicesContain(userIDs(items(h.send(dev, "GET", "/v1/me/friends", nil).data)), eli)
		out["conversation"] = h.send(dev, "GET", path, nil).status == 200
		out["conversation list"] = len(items(h.send(eli, "GET", "/v1/conversations", nil).data)) == 1
		out["post"] = h.send(dev, "GET", "/v1/posts/"+post, nil).status == 200
		out["notifications"] = len(items(h.send(dev, "GET", "/v1/notifications", nil).data)) > 0
		out["unread messages"] = h.send(eli, "GET", "/v1/conversations/unread", nil).data["messages"] == float64(1)
		out["inbox"] = len(items(h.send(eli, "GET", "/v1/devices/"+other.id+"/inbox", nil).data)) == 1
		return out
	}
	// While the pair shares a band, everything is there.
	for name, ok := range visible() {
		if !ok {
			t.Fatalf("within one band: %s is not available", name)
		}
	}
	countRows := func() [4]int {
		var n [4]int
		for i, table := range []string{"friendships", "conversations", "messages", "message_envelopes"} {
			if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM `+table).Scan(&n[i]); err != nil {
				t.Fatal(err)
			}
		}
		return n
	}
	before := countRows()

	// Eli turns 18 while Dev is still 16: the same pair, now in different bands.
	h.ageOffset(eli, 18, 0)
	h.expect(h.send(dev, "POST", path+"/messages", message(phone, other)), 404, "NOT_FOUND")
	for name, ok := range visible() {
		if ok {
			t.Fatalf("across bands: %s is still available", name)
		}
	}
	if after := countRows(); after != before {
		t.Fatalf("rows changed while dark: %v -> %v", before, after)
	}
	var status string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status FROM friendships WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`, dev, eli).Scan(&status); err != nil || status != "accepted" {
		t.Fatalf("the friendship was changed: %q (%v)", status, err)
	}

	// Dev turns 18 as well (the 18th birthday is today): the same band again, and everything returns.
	h.ageOffset(dev, 18, 0)
	for name, ok := range visible() {
		if !ok {
			t.Fatalf("same band again: %s did not come back", name)
		}
	}
	// And a day before the birthday is still a minor: 17 years and 364 days.
	h.ageOffset(dev, 18, -1)
	h.expect(h.send(eli, "POST", path+"/messages", message(other, phone)), 404, "NOT_FOUND")
	h.ageOffset(dev, 18, 0)
	h.expect(h.send(eli, "POST", path+"/messages", message(other, phone)), 200, "")
}

// Reports keep to the same barrier: an entry written by a member who is now in the other band is not reportable.
func TestReportsOfSpaceEntriesRespectTheBarrier(t *testing.T) {
	h := newSocialHarness(t)
	space := makeSpace(h, alice, "community", "public", 10, nil)
	h.expect(h.send(bob, "PUT", "/v1/spaces/"+space+"/membership", map[string]string{}), 200, "")
	entry := h.expect(h.send(bob, "POST", "/v1/spaces/"+space+"/entries", map[string]string{"body": "an entry"}), 201, "").data["entryId"].(string)
	report := map[string]any{"targetType": "space_entry", "targetId": entry, "reasonCode": "spam"}
	h.ageAt(bob, 15) // bob is now a minor in an adult's space
	h.expect(h.send(alice, "POST", "/v1/reports", report), 404, "NOT_FOUND")
	h.ageAt(bob, 30)
	h.expect(h.send(alice, "POST", "/v1/reports", report), 201, "")
}

// A member of a space who is in another band than a host cannot see the space, its entries or its members.
func TestSpaceEntriesAndMembersHideCrossBandMembers(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(dev, 15)
	space := makeSpace(h, cara, "community", "public", 10, nil)
	h.expect(h.send(xan, "PUT", "/v1/spaces/"+space+"/membership", map[string]string{}), 200, "")
	h.expect(h.send(xan, "POST", "/v1/spaces/"+space+"/entries", map[string]string{"body": "from an adult"}), 201, "")
	// The minor was a member before the bands were told apart: written straight into the tables.
	h.exec(`INSERT INTO space_members(space_id,user_id,role,state) VALUES($1,$2,'member','active')`, space, dev)
	h.exec(`INSERT INTO space_entries(entry_id,space_id,author_id,body) VALUES($1,$2,$3,'from a minor')`, uuid.NewString(), space, dev)
	entries := func(viewer string) []string {
		var out []string
		for _, e := range items(h.ok(viewer, "GET", "/v1/spaces/"+space+"/entries")) {
			out = append(out, e["body"].(string))
		}
		return out
	}
	if got := entries(cara); fmt.Sprint(got) != "[from an adult]" {
		t.Fatalf("an adult sees %v", got)
	}
	if got := userIDs(items(h.ok(cara, "GET", "/v1/spaces/"+space+"/members"))); slicesContain(got, dev) || !slicesContain(got, xan) {
		t.Fatalf("an adult's member list %v", got)
	}
	// The minor cannot see the adult's space at all, so cannot read or write in it.
	h.expect(h.call(dev, "GET", "/v1/spaces/"+space), 404, "NOT_FOUND")
	h.expect(h.call(dev, "GET", "/v1/spaces/"+space+"/entries"), 404, "NOT_FOUND")
	h.expect(h.send(dev, "POST", "/v1/spaces/"+space+"/entries", map[string]string{"body": "x"}), 404, "NOT_FOUND")
	// Invitations follow the same rule, without telling the host: inviting the minor by username is
	// answered like any invitation (usernames are public, so a refusal would reveal the band) but
	// invites nobody.
	private := makeSpace(h, cara, "community", "invite", 10, nil)
	h.expect(h.send(cara, "POST", "/v1/spaces/"+private+"/invitations", map[string]string{"username": "dev_k"}), 200, "")
	h.expect(h.send(cara, "POST", "/v1/spaces/"+private+"/invitations", map[string]string{"username": "eli"}), 200, "") // an adult can be invited
	if got := userIDs(items(h.ok(cara, "GET", "/v1/spaces/"+private+"/members?state=invited"))); fmt.Sprint(got) != fmt.Sprint([]string{eli}) {
		t.Fatalf("invited %v", got)
	}
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM space_members WHERE space_id=$1 AND user_id=$2`, private, dev).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("the minor was invited: %d %v", rows, err)
	}
}

// The barrier and the age filter are written as date bounds so they cost one lookup per candidate; they must say
// exactly what member_age and age_band say, on every day including leap days.
func TestSQLDateBoundsAgreeWithMemberAgeAndAgeBand(t *testing.T) {
	h := newSocialHarness(t)
	const today = `(now() AT TIME ZONE 'UTC')::date`
	var minorMismatch, filterMismatch, days int
	query := fmt.Sprintf(`WITH d AS (SELECT g::date AS born FROM generate_series(%[1]s-36500,%[1]s,interval '1 day') g)
 SELECT count(*),
  count(*) FILTER (WHERE (date_part('year',age(%[1]s,born))::int<18) <> (born>%[1]s-interval '18 years')),
  count(*) FILTER (WHERE (SELECT bool_and((date_part('year',age(%[1]s,born))::int>=a AND date_part('year',age(%[1]s,born))::int<=b)=(born<=%[1]s-make_interval(years=>a) AND born>%[1]s-make_interval(years=>b+1)))
                           FROM (VALUES (13,17),(13,13),(18,18),(18,99),(25,34),(20,30),(99,99),(13,99)) r(a,b))=false)
 FROM d`, today)
	if err := h.db.Pool.QueryRow(h.ctx, query).Scan(&days, &minorMismatch, &filterMismatch); err != nil {
		t.Fatal(err)
	}
	if days < 36000 || minorMismatch != 0 || filterMismatch != 0 {
		t.Fatalf("%d days checked: %d band mismatches, %d age-range mismatches", days, minorMismatch, filterMismatch)
	}
	// interaction_barred is the same as comparing age_band, for members with and without birth dates, on both sides.
	h.exec(`DELETE FROM member_ages WHERE user_id IN ($1,$2,$3,$4)`, cara, dev, eli, xan)
	h.ageOffset(dev, 18, 0)  // exactly 18 today: adult
	h.ageOffset(eli, 18, -1) // turns 18 tomorrow: minor
	h.ageAt(xan, 13)
	var wrong int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM unnest($1::uuid[]) a, unnest($1::uuid[]) b WHERE interaction_barred(a,b) <> (age_band(a)<>age_band(b))`, []string{cara, dev, eli, xan, alice, bob}).Scan(&wrong); err != nil || wrong != 0 {
		t.Fatalf("%d pairs where interaction_barred disagrees with age_band (%v)", wrong, err)
	}
	var band string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT age_band($1)||age_band($2)||age_band($3)||age_band($4)`, cara, dev, eli, xan).Scan(&band); err != nil || band != "adultadultminorminor" {
		t.Fatalf("bands %q (%v)", band, err)
	}
}

// Without isolation a minor can filter for adults and find them; with it nobody is returned, and the filter never
// scans for nothing.
func TestAgeFilterAcrossBandsDependsOnIsolation(t *testing.T) {
	for _, on := range []bool{true, false} {
		h := newSocialHarnessWith(t, store.WithAgeBandIsolation(on))
		h.ageAt(alice, 15)
		h.ageAt(cara, 30)
		h.ageAt(dev, 15)
		h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
		h.north(cara, 0.01)
		h.north(dev, 0.01)
		h.setAge(bob, 0) // Niko has a stored age of his own; an unknown age never matches an age filter
		// A minor has no age or gender filters at all, whatever the isolation setting.
		h.api.search.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/discovery/search", map[string]any{"ageMin": 25, "ageMax": 34}), 422, "FILTER_NOT_AVAILABLE")
		got, _, _ := h.nearbyList(alice, map[string]any{"radiusKm": 100, "ageMin": 25, "ageMax": 34})
		h.expect(got, 422, "FILTER_NOT_AVAILABLE")
		h.place(cara, bengaluru.Latitude, bengaluru.Longitude)
		s, n := h.both(cara, map[string]any{"ageMin": 13, "ageMax": 17})
		var want []string
		if !on {
			want = sorted(alice, dev)
			if search := s; !slicesContain(search, store.KaiID) {
				t.Fatalf("Kai (15) is missing for an adult with isolation off: %v", search)
			}
			s = without(s, store.KaiID)
		}
		if fmt.Sprint(s) != fmt.Sprint(want) || fmt.Sprint(n) != fmt.Sprint(want) {
			t.Fatalf("isolation %v: an adult filtering for 13-17 found %v %v, want %v", on, s, n, want)
		}
	}
}

func without(list []string, drop string) []string {
	var out []string
	for _, v := range list {
		if v != drop {
			out = append(out, v)
		}
	}
	return out
}

// An author's list of who viewed a story leaves out viewers who are now in the other band, like any other list.
func TestStoryViewersHideCrossBandViewers(t *testing.T) {
	h := newSocialHarness(t)
	h.ageAt(cara, 30)
	h.ageAt(xan, 30)
	h.ageAt(yui, 30)
	story := h.expect(h.send(cara, "POST", "/v1/stories", map[string]any{"body": "gm", "background": "pink", "audience": "public"}), 201, "").data["storyId"].(string)
	h.expect(h.call(xan, "POST", "/v1/stories/"+story+"/view"), 200, "")
	h.expect(h.call(yui, "POST", "/v1/stories/"+story+"/view"), 200, "")
	viewers := func() []string { return userIDs(items(h.ok(cara, "GET", "/v1/stories/"+story+"/viewers"))) }
	if got := viewers(); len(got) != 2 {
		t.Fatalf("viewers %v", got)
	}
	h.ageAt(xan, 16)
	if got := viewers(); fmt.Sprint(got) != fmt.Sprint([]string{yui}) {
		t.Fatalf("a viewer in the other band is listed: %v", got)
	}
	h.ageAt(xan, 30)
	if got := viewers(); len(got) != 2 {
		t.Fatalf("viewers after the band matches again: %v", got)
	}
}
