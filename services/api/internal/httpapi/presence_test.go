package httpapi

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/realtime"
	"hiyall/services/api/internal/store"
)

// session replaces a member's sessions with one that was last active `ago` ago and has not expired.
func (h *socialHarness) session(id string, ago time.Duration) {
	h.t.Helper()
	h.exec(`DELETE FROM sessions WHERE user_id=$1`, id)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour',now()-make_interval(secs=>$2))`, id, ago.Seconds())
}

// connect gives a member a live realtime connection on this node, without a socket.
func (h *socialHarness) connect(id string) {
	h.t.Helper()
	if h.api.RT == nil {
		h.api.RT = realtime.NewHub(realtime.NewLocalBus(), 4, 100)
	}
	hub, c := h.api.RT, realtime.NewClient(id, 4)
	if !hub.Register(c) {
		h.t.Fatal("hub refused the connection")
	}
	h.t.Cleanup(func() { hub.Unregister(c) })
}

// shownPresence is what a payload says about a member's presence: the two optional keys.
type shownPresence struct {
	online   any
	lastSeen any
}

func shown(v map[string]any) shownPresence { return shownPresence{v["online"], v["lastSeenAt"]} }

// surfaces returns the member as viewer sees them in people search, Nearby, the profile and the
// conversation peer. A surface the viewer cannot get at (self in search, a barred pair) is nil.
func (h *socialHarness) surfaces(viewer, target string) map[string]map[string]any {
	h.t.Helper()
	got := map[string]map[string]any{}
	h.api.search.reset(viewer)
	h.api.clients.reset("127.0.0.1")
	for _, item := range items(h.expect(h.send(viewer, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data) {
		if item["userId"] == target {
			got["search"] = item
		}
	}
	h.api.search.reset(viewer)
	h.api.clients.reset("127.0.0.1")
	for _, item := range items(h.expect(h.send(viewer, "POST", "/v1/discover/nearby", map[string]any{}), 200, "").data) {
		if item["userId"] == target {
			got["nearby"] = item
		}
	}
	if r := h.send(viewer, "GET", "/v1/users/"+target+"/profile", nil); r.status == 200 {
		got["profile"] = r.data
	}
	if viewer != target {
		got["conversation"] = h.conversationPeer(viewer, target)
	}
	return got
}

// conversationPeer is the peer object of the viewer's conversation with target, from the list, the open call
// and the single get, which must agree.
func (h *socialHarness) conversationPeer(viewer, target string) map[string]any {
	h.t.Helper()
	h.api.clients.reset("127.0.0.1")
	h.api.firstChats.reset(viewer)
	var listed map[string]any
	for _, c := range items(h.ok(viewer, "GET", "/v1/conversations?limit=50")) {
		if c["peer"].(map[string]any)["userId"] == target {
			listed = c
		}
	}
	if listed == nil {
		r := h.send(viewer, "POST", "/v1/conversations", map[string]string{"userId": target})
		if r.status != 200 {
			return nil
		}
		listed = r.data
	}
	h.api.firstChats.reset(viewer)
	opened := h.expect(h.send(viewer, "POST", "/v1/conversations", map[string]string{"userId": target}), 200, "").data
	fetched := h.ok(viewer, "GET", "/v1/conversations/"+listed["conversationId"].(string))
	peer := listed["peer"].(map[string]any)
	for name, other := range map[string]map[string]any{"open": opened, "get": fetched} {
		if got := other["peer"].(map[string]any); !reflect.DeepEqual(shown(got), shown(peer)) {
			h.t.Fatalf("%s peer presence %v differs from the list %v", name, shown(got), shown(peer))
		}
	}
	for _, key := range []string{"online", "lastSeenAt"} {
		if _, found := listed[key]; found {
			h.t.Fatalf("presence belongs on the peer, not the conversation: %v", listed)
		}
	}
	return peer
}

func (h *socialHarness) presenceWorld() {
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.place(cara, bengaluru.Latitude, bengaluru.Longitude)
	h.place(dev, bengaluru.Latitude, bengaluru.Longitude)
	h.north(bob, 0.01)
}

// bob is the member being looked at. alice is a stranger to him, cara follows him, dev is his friend.
func (h *socialHarness) bobsCircle() {
	h.presenceWorld()
	h.expect(h.call(cara, "POST", "/v1/users/"+bob+"/follow"), 200, "")
	h.befriend(bob, dev)
}

var presenceViewers = []struct {
	name, id string
}{{"stranger", alice}, {"follower", cara}, {"friend", dev}, {"self", bob}}

func admits(audience, viewer string) bool {
	switch audience {
	case "everyone":
		return true
	case "followers":
		return viewer != alice
	case "friends":
		return viewer == dev || viewer == bob
	}
	return viewer == bob // "nobody": only the member themself
}

func TestPresenceFollowsTheOnlineAudienceForEveryViewer(t *testing.T) {
	h := newSocialHarness(t)
	h.bobsCircle()
	for _, state := range []string{"online", "away"} {
		if state == "online" {
			h.session(bob, 10*time.Second)
		} else {
			h.session(bob, 17*time.Minute)
		}
		for _, audience := range []string{"everyone", "friends", "followers", "nobody"} {
			h.policy(bob, "onlineAudience", audience)
			for _, v := range presenceViewers {
				for surface, payload := range h.surfaces(v.id, bob) {
					if payload == nil {
						if v.id == bob && (surface == "search" || surface == "nearby") {
							continue // a member does not appear in their own people lists
						}
						t.Fatalf("%s %s audience %s: bob is missing from %s", state, v.name, audience, surface)
					}
					got := shown(payload)
					label := fmt.Sprintf("%s, %s audience, %s viewer, %s", state, audience, v.name, surface)
					switch {
					case !admits(audience, v.id):
						if got.online != nil || got.lastSeen != nil {
							t.Fatalf("%s: presence leaked: %v", label, got)
						}
					case state == "online":
						if got.online != true || got.lastSeen != nil {
							t.Fatalf("%s: %v, want online only", label, got)
						}
					default:
						stamp, _ := got.lastSeen.(string)
						at, err := time.Parse(time.RFC3339, stamp)
						if got.online != nil || err != nil || at.Location() != time.UTC || at.Unix()%300 != 0 {
							t.Fatalf("%s: %v, want a five-minute lastSeenAt and no online (%v)", label, got, err)
						}
					}
				}
			}
		}
	}
}

func TestOnlineComesFromTheHubOrRecentSessionActivity(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	check := func(label string, online bool, lastSeen bool) {
		t.Helper()
		for surface, payload := range h.surfaces(alice, bob) {
			got := shown(payload)
			if (got.online == true) != online || (got.lastSeen != nil) != lastSeen || (got.online != nil && got.online != true) {
				t.Fatalf("%s: %s shows %v, want online=%v lastSeenAt=%v", label, surface, got, online, lastSeen)
			}
		}
	}
	check("no session, not connected", false, false)

	h.session(bob, 0)
	check("active now", true, false)
	h.session(bob, 119*time.Second)
	check("active 119s ago", true, false)
	h.session(bob, 125*time.Second)
	check("active 125s ago", false, true)
	h.session(bob, 3*24*time.Hour)
	check("active three days ago", false, true)

	// A live connection is online whatever the sessions say, and has no last-seen time.
	h.connect(bob)
	check("connected, stale session", true, false)
	h.session(bob, 0)
	h.exec(`DELETE FROM sessions WHERE user_id=$1`, bob)
	check("connected, no session", true, false)
	h.api.RT = nil
	check("no hub, no session", false, false)

	// The latest session wins, whichever row it is.
	h.session(bob, time.Hour)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour',now()-interval '20 seconds')`, bob)
	check("one stale, one recent session", true, false)

	// Revoked and expired sessions are not activity.
	h.exec(`DELETE FROM sessions WHERE user_id=$1`, bob)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at,revoked_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour',now(),now())`, bob)
	check("only a revoked session", false, false)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at) VALUES(gen_random_uuid(),$1,now()-interval '1 minute',now()-interval '10 seconds')`, bob)
	check("revoked and expired sessions", false, false)
	h.session(bob, 40*time.Minute)
	h.exec(`INSERT INTO sessions(session_id,user_id,expires_at,last_seen_at,revoked_at) VALUES(gen_random_uuid(),$1,now()+interval '1 hour',now(),now())`, bob)
	check("a recent revoked session beside a stale live one", false, true)
}

func TestLastSeenIsRoundedDownToFiveMinutes(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	for _, ago := range []time.Duration{3*time.Minute + 7*time.Second, 11*time.Minute + 59*time.Second, 61*time.Minute + 20*time.Second, 49 * time.Hour} {
		h.session(bob, ago)
		var actual time.Time
		h.db.Pool.QueryRow(h.ctx, `SELECT last_seen_at FROM sessions WHERE user_id=$1`, bob).Scan(&actual)
		want := actual.UTC().Truncate(5 * time.Minute).Format(time.RFC3339)
		for surface, payload := range h.surfaces(alice, bob) {
			if got := payload["lastSeenAt"]; got != want {
				t.Fatalf("ago %v, %s: lastSeenAt %v, want %s (actual %s)", ago, surface, got, want, actual.UTC().Format(time.RFC3339Nano))
			}
		}
	}
}

func TestPresenceIsNeverShownAcrossBlocksOrAgeBands(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	h.session(bob, 5*time.Second)
	h.connect(bob)

	// A block in either direction removes the member entirely, so there is nothing to carry presence.
	h.befriend(alice, bob)
	for name, blocker := range map[string][2]string{"alice blocks bob": {alice, bob}, "bob blocks alice": {bob, alice}} {
		h.ok(blocker[0], "POST", "/v1/users/"+blocker[1]+"/block")
		got := h.surfaces(alice, bob)
		for surface, payload := range got {
			if payload != nil {
				t.Fatalf("%s: bob still reachable through %s: %v", name, surface, payload)
			}
		}
		// The conversation list has no row for a blocked pair either.
		for _, c := range items(h.ok(alice, "GET", "/v1/conversations?limit=50")) {
			if c["peer"].(map[string]any)["userId"] == bob {
				t.Fatalf("%s: conversation still listed: %v", name, c)
			}
		}
		h.ok(blocker[0], "DELETE", "/v1/users/"+blocker[1]+"/block")
	}
	if got := shown(h.surfaces(alice, bob)["profile"]); got.online != true {
		t.Fatalf("presence does not come back after unblocking: %v", got)
	}

	// Across age bands the pair does not exist for each other.
	h.ageAt(alice, 30)
	h.ageAt(bob, 15)
	got := h.surfaces(alice, bob)
	for surface, payload := range got {
		if payload != nil {
			t.Fatalf("an adult reaches a minor through %s: %v", surface, payload)
		}
	}
	got = h.surfaces(bob, alice)
	for surface, payload := range got {
		if payload != nil {
			t.Fatalf("a minor reaches an adult through %s: %v", surface, payload)
		}
	}
}

func TestMinorsDefaultToNoPresenceAndKeepItWithinTheirBand(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	h.ageAt(alice, 15)
	h.ageAt(bob, 14)
	h.ageAt(cara, 16)
	var q domain.Privacy
	q = domain.DefaultPrivacy()
	domain.ApplyMinorDefaults(&q)
	for _, minor := range []string{bob, cara} {
		h.policy(minor, "onlineAudience", q.OnlineAudience)
	}
	h.session(bob, 5*time.Second)
	h.connect(bob)
	for surface, payload := range h.surfaces(alice, bob) {
		if payload == nil {
			t.Fatalf("a minor cannot see another minor in %s", surface)
		}
		if got := shown(payload); got.online != nil || got.lastSeen != nil {
			t.Fatalf("a minor's default shows presence in %s: %v", surface, got)
		}
	}
	// Choosing to show it is the minor's own decision and then works within the band.
	h.policy(bob, "onlineAudience", "everyone")
	for surface, payload := range h.surfaces(alice, bob) {
		if shown(payload).online != true {
			t.Fatalf("%s: %v", surface, payload)
		}
	}
	// And the adults, who cannot see bob at all, learn nothing.
	h.ageAt(dev, 40)
	h.place(dev, bengaluru.Latitude, bengaluru.Longitude)
	for surface, payload := range h.surfaces(dev, bob) {
		if payload != nil {
			t.Fatalf("%s: an adult reaches a minor: %v", surface, payload)
		}
	}
}

func TestHiddenPresenceLooksExactlyLikeOffline(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()

	// bob has hidden presence and is active and connected...
	h.policy(bob, "onlineAudience", "nobody")
	h.session(bob, 3*time.Second)
	h.connect(bob)
	hidden := h.surfaces(alice, bob)
	hiddenStatus := h.send(alice, "GET", "/v1/users/"+bob+"/profile", nil).status
	// ...and then shows presence but has never been seen anywhere.
	h.policy(bob, "onlineAudience", "everyone")
	h.api.RT = nil
	h.exec(`DELETE FROM sessions WHERE user_id=$1`, bob)
	offline := h.surfaces(alice, bob)
	if !reflect.DeepEqual(hidden, offline) {
		t.Fatalf("hidden and offline differ:\nhidden  %v\noffline %v", hidden, offline)
	}
	if offline["conversation"] == nil || h.send(alice, "GET", "/v1/users/"+bob+"/profile", nil).status != hiddenStatus {
		t.Fatal("the surfaces are missing or the status differs")
	}
}

func TestOwnPresenceIsAlwaysVisibleToTheMember(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	h.session(bob, 4*time.Second)
	for _, audience := range []string{"everyone", "friends", "nobody"} {
		h.policy(bob, "onlineAudience", audience)
		if got := h.ok(bob, "GET", "/v1/users/"+bob+"/profile")["online"]; got != true {
			t.Fatalf("own profile with audience %s: online=%v", audience, got)
		}
	}
}

func TestConversationPresenceIsThePeersAndRecordsNoVisit(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	h.session(bob, 5*time.Second)
	h.session(alice, 5*time.Second)
	rowsBefore, countedBefore := h.visitRows(bob)
	aliceBefore, _ := h.visitRows(alice)

	peer := h.conversationPeer(alice, bob)
	if peer["online"] != true || peer["userId"] != bob || len(peer) != 5 {
		t.Fatalf("bob's peer object for alice: %v", peer)
	}
	// From bob's side the peer is alice, not bob, and the keys are alice's.
	back := h.conversationPeer(bob, alice)
	if back["userId"] != alice || back["online"] != true {
		t.Fatalf("alice's peer object for bob: %v", back)
	}
	// Presence is per peer: when only one of the two is active, only that peer carries it.
	h.session(alice, 30*time.Minute)
	if got := shown(h.conversationPeer(bob, alice)); got.online != nil || got.lastSeen == nil {
		t.Fatalf("alice is away: %v", got)
	}
	if got := shown(h.conversationPeer(alice, bob)); got.online != true {
		t.Fatalf("bob is still online for alice: %v", got)
	}
	if rows, counted := h.visitRows(bob); rows != rowsBefore || counted != countedBefore {
		t.Fatalf("conversations recorded a visit to bob: %d rows, %d counted", rows, counted)
	}
	if rows, _ := h.visitRows(alice); rows != aliceBefore {
		t.Fatalf("conversations recorded a visit to alice: %d rows", rows)
	}
	// Discovery does not either.
	h.surfaces(cara, bob)
	h.place(cara, bengaluru.Latitude, bengaluru.Longitude)
	h.api.search.reset(cara)
	h.send(cara, "POST", "/v1/discovery/search", map[string]any{})
	if rows, _ := h.visitRows(bob); rows != rowsBefore+1 {
		// surfaces() opens bob's profile once for cara, which is a visit; nothing else is.
		t.Fatalf("visit rows for bob: %d, want %d", rows, rowsBefore+1)
	}
}

// A request that authenticates with a session keeps the member online, as the web app (which has no
// realtime socket) relies on: VerifyDevSession refreshes last_seen_at at most once a minute.
func TestAuthenticatedRequestsKeepAMemberOnline(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	h.exec(`DELETE FROM sessions WHERE user_id=$1`, bob)
	if _, err := h.db.CreateDevSession(h.ctx, bob, "bobs-web-token", "web"); err != nil {
		t.Fatal(err)
	}
	h.exec(`UPDATE sessions SET last_seen_at=now()-interval '10 minutes' WHERE user_id=$1`, bob)
	if got := shown(h.surfaces(alice, bob)["profile"]); got.online != nil || got.lastSeen == nil {
		t.Fatalf("before the request: %v", got)
	}
	if _, err := h.db.VerifyDevSession(h.ctx, "bobs-web-token"); err != nil {
		t.Fatal(err)
	}
	for surface, payload := range h.surfaces(alice, bob) {
		if got := shown(payload); got.online != true || got.lastSeen != nil {
			t.Fatalf("%s after an authenticated request: %v", surface, got)
		}
	}
	// Refreshes are throttled to once a minute, which is why the online window is two.
	var touched time.Time
	h.db.Pool.QueryRow(h.ctx, `SELECT last_seen_at FROM sessions WHERE user_id=$1`, bob).Scan(&touched)
	h.db.VerifyDevSession(h.ctx, "bobs-web-token")
	var again time.Time
	h.db.Pool.QueryRow(h.ctx, `SELECT last_seen_at FROM sessions WHERE user_id=$1`, bob).Scan(&again)
	if !again.Equal(touched) {
		t.Fatalf("last_seen_at written twice within a minute: %v then %v", touched, again)
	}
	if domain.PresenceOnlineWindow <= time.Minute {
		t.Fatal("the online window must exceed the one minute session refresh")
	}
}

// statements records the SQL of every statement a store sends.
type statements struct {
	mu  sync.Mutex
	sql []string
}

func (s *statements) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sql = append(s.sql, data.SQL)
	return ctx
}

func (*statements) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func (s *statements) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sql = nil
}

func (s *statements) count(fragment string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, q := range s.sql {
		if strings.Contains(q, fragment) {
			n++
		}
	}
	return n
}

// Presence for a page of people is resolved with a fixed number of statements however long the page is, and the
// hub is asked only about members the viewer is admitted to.
func TestPresenceIsResolvedInOneBatchPerPage(t *testing.T) {
	h := newSocialHarness(t)
	h.presenceWorld()
	trace := &statements{}
	traced, err := store.New(h.ctx, os.Getenv("TEST_DATABASE_URL"), store.WithQueryTracer(trace))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(traced.Pool.Close)

	// Twelve peers: alice has a conversation with each, and all of them are visible people.
	for i := 0; i < 12; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-0000000001%02x", i)
		h.user(id, fmt.Sprintf("peer%02d", i))
		h.place(id, bengaluru.Latitude, bengaluru.Longitude)
		h.session(id, time.Duration(i)*time.Minute)
		// A mix of audiences: friends-only for every third, which needs the relationship lookup.
		if i%3 == 0 {
			h.policy(id, "onlineAudience", "friends")
			h.befriend(alice, id)
		}
		h.api.firstChats.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": id}), 200, "")
	}
	asked := 0
	hub := func(string) bool { asked++; return false }
	const sessionsSQL = "FROM sessions WHERE user_id=ANY"
	const relationshipsSQL = "FROM unnest($2::uuid[]) t(id)"

	trace.reset()
	list, err := traced.ListConversations(h.ctx, alice, nil, "ffffffff-ffff-ffff-ffff-ffffffffffff", 50, nil, hub)
	if err != nil || len(list) != 12 {
		t.Fatalf("list: %d, %v", len(list), err)
	}
	if trace.count(sessionsSQL) != 1 || trace.count(relationshipsSQL) != 1 || asked != 12 {
		t.Fatalf("conversations: %d session statements, %d relationship statements, hub asked %d times", trace.count(sessionsSQL), trace.count(relationshipsSQL), asked)
	}
	// The hub said offline for everyone, so only session activity (peer NN was active NN minutes ago) counts,
	// and every audience here admits alice.
	for _, c := range list {
		var n int
		fmt.Sscanf(c.Peer.Username, "peer%d", &n)
		if c.Peer.Online != (n <= 1) || (c.Peer.LastSeenAt != nil) == (n <= 1) {
			t.Fatalf("%s: %+v", c.Peer.Username, c.Peer)
		}
	}

	asked = 0
	trace.reset()
	people, err := traced.SearchPeople(h.ctx, alice, domain.PeopleFilters{}, "00000000-0000-0000-0000-000000000000", 50, hub, nil)
	if err != nil || len(people) < 12 {
		t.Fatalf("search: %d, %v", len(people), err)
	}
	if trace.count(sessionsSQL) != 1 || trace.count(relationshipsSQL) != 1 {
		t.Fatalf("search: %d session statements, %d relationship statements", trace.count(sessionsSQL), trace.count(relationshipsSQL))
	}
	if asked > len(people) {
		t.Fatalf("the hub was asked %d times for %d people", asked, len(people))
	}
}
