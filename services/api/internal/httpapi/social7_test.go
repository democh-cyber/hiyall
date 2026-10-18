package httpapi

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// Wave 7: topics, search, voice notes, threaded comments, My activity, notification choices, visit notices, the
// notice board and support (docs/api/27-stories-notices-support.md).

func mkBox(kind string, body ...[]byte) []byte {
	var payload []byte
	for _, b := range body {
		payload = append(payload, b...)
	}
	out := make([]byte, 8, 8+len(payload))
	binary.BigEndian.PutUint32(out, uint32(8+len(payload)))
	copy(out[4:], kind)
	return append(out, payload...)
}

// voiceClip is a minimal audio-only MP4 of the given duration.
func voiceClip(ms int) []byte {
	mvhd := make([]byte, 100)
	binary.BigEndian.PutUint32(mvhd[12:], 1000)
	binary.BigEndian.PutUint32(mvhd[16:], uint32(ms))
	hdlr := make([]byte, 24)
	copy(hdlr[8:], "soun")
	ftyp := mkBox("ftyp", []byte("M4A "), []byte{0, 0, 0, 0}, []byte("isom"))
	moov := mkBox("moov", mkBox("mvhd", mvhd), mkBox("trak", mkBox("mdia", mkBox("hdlr", hdlr))))
	return append(append(ftyp, moov...), mkBox("mdat", make([]byte, 128))...)
}

func (h *socialHarness) uploadVoice(store *media.Memory, user string, data []byte) reply {
	h.t.Helper()
	made := h.expect(h.send(user, "POST", "/v1/media/uploads", map[string]any{"purpose": "voice", "contentType": "audio/mp4", "sizeBytes": len(data)}), 201, "").data
	key := strings.TrimPrefix(made["uploadUrl"].(string), "memory://put/")
	_ = store.Put(h.ctx, key, data, "audio/mp4")
	got := h.call(user, "POST", "/v1/media/"+made["mediaId"].(string)+"/complete")
	if got.data == nil {
		got.data = map[string]any{}
	}
	got.data["mediaId"] = made["mediaId"]
	return got
}

func (h *socialHarness) topicPost(user, audience, body, topic string) string {
	h.t.Helper()
	return h.expect(h.send(user, "POST", "/v1/posts", map[string]any{"body": body, "audience": audience, "topic": topic}), 201, "").data["postId"].(string)
}

func bodies(data map[string]any) []string {
	var out []string
	for _, it := range items(data) {
		out = append(out, it["body"].(string))
	}
	return out
}

func TestTopicsFeedFilterAndStoryExplore(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 30)
	h.setAge(bob, 30)
	h.setAge(cara, 30)
	got := h.ok(bob, "GET", "/v1/topics")["items"].([]any)
	if len(got) != 8 || got[0] != "language" {
		t.Fatalf("topics %v", got)
	}
	h.topicPost(alice, "public", "guitar practice", "music")
	h.topicPost(alice, "public", "ramen night", "food")
	h.post(alice, "public", "no topic")
	h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "x", "audience": "public", "topic": "politics"}), 422, "VALIDATION")
	same(t, bodies(h.ok(bob, "GET", "/v1/feed?mode=everyone&topic=music")), "guitar practice")
	same(t, bodies(h.ok(bob, "GET", "/v1/feed?mode=everyone&topic=food")), "ramen night")
	if n := len(items(h.ok(bob, "GET", "/v1/feed?mode=everyone"))); n != 3 {
		t.Fatalf("unfiltered feed %d", n)
	}
	h.expect(h.call(bob, "GET", "/v1/feed?mode=everyone&topic=nope"), 422, "VALIDATION")
	// The following feed filters inside each author's probe, and a cursor made for one topic is refused for another.
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	same(t, bodies(h.ok(bob, "GET", "/v1/feed?mode=following&topic=music")), "guitar practice")
	first := h.ok(bob, "GET", "/v1/feed?mode=everyone&topic=music&limit=1")
	if first["nextCursor"] != nil {
		t.Fatalf("one music post, cursor %v", first["nextCursor"])
	}
	h.topicPost(alice, "public", "second music", "music")
	page := h.ok(bob, "GET", "/v1/feed?mode=everyone&topic=music&limit=1")
	cursor, _ := page["nextCursor"].(string)
	if cursor == "" {
		t.Fatal("no cursor")
	}
	h.expect(h.call(bob, "GET", "/v1/feed?mode=everyone&topic=food&cursor="+cursor), 422, "INVALID_CURSOR")

	// Stories: the tray filters by topic, the Everyone list shows public stories of people outside the viewer's own.
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "gm music", "audience": "public", "topic": "music"}), 201, "")
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "friends only", "audience": "friends", "topic": "music"}), 201, "")
	h.expect(h.send(cara, "POST", "/v1/stories", map[string]any{"body": "cara food", "audience": "public", "topic": "food"}), 201, "")
	explore := h.ok(bob, "GET", "/v1/stories/explore")
	var texts []string
	for _, it := range items(explore) {
		texts = append(texts, it["body"].(string))
		if it["author"].(map[string]any)["userId"] == "" {
			t.Fatal("no author")
		}
	}
	if fmt.Sprint(texts) != "[cara food gm music]" {
		t.Fatalf("explore %v", texts)
	}
	same(t, bodies(h.ok(bob, "GET", "/v1/stories/explore?topic=food")), "cara food")
	if n := len(items(h.ok(alice, "GET", "/v1/stories/explore"))); n != 1 {
		t.Fatalf("alice's own stories must not be in her Everyone list: %d", n)
	}
	// Muted, blocked and other-band authors are left out.
	h.ok(bob, "POST", "/v1/users/"+cara+"/mute")
	same(t, bodies(h.ok(bob, "GET", "/v1/stories/explore")), "gm music")
	h.ok(bob, "POST", "/v1/users/"+alice+"/block")
	if n := len(items(h.ok(bob, "GET", "/v1/stories/explore"))); n != 0 {
		t.Fatalf("blocked author in explore: %d", n)
	}
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/block")
	h.setAge(bob, 15)
	if n := len(items(h.ok(bob, "GET", "/v1/stories/explore"))); n != 0 {
		t.Fatalf("a minor sees adult stories: %d", n)
	}
	h.expect(h.call(bob, "GET", "/v1/stories/tray?topic=nope"), 422, "VALIDATION")
}

func TestPulseSearchRespectsAudiencesBlocksBandsAndCaps(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{alice, bob, cara, dev} {
		h.setAge(id, 30)
	}
	h.post(alice, "public", "learning Spanish with songs")
	h.post(alice, "followers", "spanish followers secret")
	h.post(alice, "friends", "spanish friends secret")
	h.post(dev, "public", "spanish from dev")
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "spanish story", "audience": "public"}), 201, "")
	search := func(viewer, q string, extra string) map[string]any {
		return h.ok(viewer, "GET", "/v1/search/pulse?q="+q+extra)
	}
	// A stranger finds only public posts; case does not matter, every word must match.
	got := bodies(search(cara, "SPANISH", ""))
	if len(got) != 2 || strings.Contains(strings.Join(got, "|"), "secret") {
		t.Fatalf("stranger found %v", got)
	}
	same(t, bodies(search(cara, "spanish+songs", "")), "learning Spanish with songs")
	if len(items(search(cara, "spanish", "&scope=stories"))) != 1 {
		t.Fatal("story search")
	}
	// A follower also finds the followers-only post, a friend the friends one.
	h.ok(cara, "POST", "/v1/users/"+alice+"/follow")
	if n := len(bodies(search(cara, "spanish", ""))); n != 3 {
		t.Fatalf("follower found %d", n)
	}
	// Block, mute and age band.
	h.ok(cara, "POST", "/v1/users/"+dev+"/mute")
	for _, b := range bodies(search(cara, "spanish", "")) {
		if b == "spanish from dev" {
			t.Fatal("a muted author was found")
		}
	}
	h.ok(cara, "POST", "/v1/users/"+alice+"/block")
	if n := len(items(search(cara, "spanish", ""))); n != 0 {
		t.Fatalf("a blocked author was found: %d", n)
	}
	h.ok(cara, "DELETE", "/v1/users/"+alice+"/block")
	h.setAge(bob, 15)
	if n := len(items(search(bob, "spanish", ""))); n != 0 {
		t.Fatalf("a minor found adult posts: %d", n)
	}
	// Topic filter and validation.
	h.topicPost(alice, "public", "spanish guitar lesson", "music")
	same(t, bodies(search(dev, "spanish", "&topic=music")), "spanish guitar lesson")
	h.expect(h.call(cara, "GET", "/v1/search/pulse?q=a"), 422, "VALIDATION")
	h.expect(h.call(cara, "GET", "/v1/search/pulse?q=spanish&scope=people"), 422, "VALIDATION")
	h.expect(h.call(cara, "GET", "/v1/search/pulse?q=spanish&topic=zzz"), 422, "VALIDATION")
	// Cursors are bound to the member and the search.
	h.exec(`INSERT INTO posts(post_id,author_id,body,audience) SELECT gen_random_uuid(),$1,'paging banana '||g,'public' FROM generate_series(1,25) g`, alice)
	first := search(dev, "banana", "")
	cursor, _ := first["nextCursor"].(string)
	if len(items(first)) != 20 || cursor == "" || first["hasMore"] != true {
		t.Fatalf("first page %d %q", len(items(first)), cursor)
	}
	if n := len(items(search(dev, "banana", "&cursor="+cursor))); n != 5 {
		t.Fatalf("second page %d", n)
	}
	h.expect(h.call(cara, "GET", "/v1/search/pulse?q=banana&cursor="+cursor), 422, "INVALID_CURSOR")
	h.expect(h.call(dev, "GET", "/v1/search/pulse?q=apple&cursor="+cursor), 422, "INVALID_CURSOR")
	// Every page counts against the day.
	h.exec(`INSERT INTO member_daily_counts(user_id,kind,day,n) VALUES($1,'pulse_search_page',(now() AT TIME ZONE 'UTC')::date,$2) ON CONFLICT (user_id,kind,day) DO UPDATE SET n=excluded.n`, dev, domain.Free().PulseSearchPagesPerDay)
	h.expect(h.call(dev, "GET", "/v1/search/pulse?q=banana"), 429, "DAILY_LIMIT")
}

func TestVoiceNotesOnPostsAndStories(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	h.setAge(alice, 30)
	h.setAge(bob, 30)
	// The flow: validated, not transcoded, stored under media/{id}/voice.m4a, the upload removed.
	clip := voiceClip(12500)
	done := h.uploadVoice(store, alice, clip)
	if done.status != 200 || done.data["durationMs"] != float64(12500) || done.data["status"] != "ready" {
		t.Fatalf("complete %d %v", done.status, done.data)
	}
	id := done.data["mediaId"].(string)
	if _, ok := store.Objects["media/"+id+"/voice.m4a"]; !ok {
		t.Fatalf("clip not stored: %v", store.Keys())
	}
	for key := range store.Objects {
		if strings.HasPrefix(key, "uploads/") {
			t.Fatalf("upload kept: %s", key)
		}
	}
	// A voice-only post, readable by others with a signed url and the duration.
	post := h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "", "audience": "public", "voiceMediaId": id}), 201, "").data
	voice := post["voice"].(map[string]any)
	if voice["durationMs"] != float64(12500) || !strings.Contains(voice["url"].(string), "voice.m4a") || voice["mediaId"] != id {
		t.Fatalf("voice %v", voice)
	}
	if got := h.ok(bob, "GET", "/v1/posts/"+post["postId"].(string)); got["voice"] == nil {
		t.Fatal("others do not see the clip")
	}
	// The clip is used once, by its owner only.
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"audience": "public", "voiceMediaId": id}), 409, "MEDIA_NOT_READY")
	other := h.uploadVoice(store, alice, voiceClip(3000)).data["mediaId"].(string)
	h.expect(h.send(bob, "POST", "/v1/posts", map[string]any{"body": "mine", "audience": "public", "voiceMediaId": other}), 409, "MEDIA_NOT_READY")
	// A story may be only a voice note, with a topic.
	story := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"audience": "public", "voiceMediaId": other, "topic": "music"}), 201, "").data["storyId"]
	mine := items(h.ok(alice, "GET", "/v1/me/stories"))
	if len(mine) != 1 || mine[0]["storyId"] != story || mine[0]["voice"] == nil || mine[0]["topic"] != "music" {
		t.Fatalf("my stories %v", mine)
	}
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	group := items(h.ok(bob, "GET", "/v1/stories/tray"))[0]["stories"].([]any)[0].(map[string]any)
	if group["voice"] == nil {
		t.Fatal("tray lacks the voice")
	}
	// Refusals: wrong content type for the purpose, too large, not audio, too long, a photo as voice.
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "voice", "contentType": "image/jpeg", "sizeBytes": 100}), 415, "UNSUPPORTED_MEDIA")
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "audio/mp4", "sizeBytes": 100}), 415, "UNSUPPORTED_MEDIA")
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "voice", "contentType": "audio/mp4", "sizeBytes": media.MaxAudioBytes + 1}), 413, "TOO_LARGE")
	if bad := h.uploadVoice(store, alice, []byte(strings.Repeat("not audio ", 10))); bad.status != 415 || bad.code != "UNSUPPORTED_MEDIA" {
		t.Fatalf("garbage: %d %s", bad.status, bad.code)
	}
	if long := h.uploadVoice(store, alice, voiceClip(75000)); long.status != 422 || long.code != "VOICE_TOO_LONG" {
		t.Fatalf("long: %d %s", long.status, long.code)
	}
	photoID := h.upload(store, alice, "post", photo(t, 30, 30))
	h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "x", "audience": "public", "voiceMediaId": photoID}), 409, "MEDIA_NOT_READY")
	// Deleting the post releases the clip for the cleanup.
	h.ok(alice, "DELETE", "/v1/posts/"+post["postId"].(string))
	var status string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status FROM media_assets WHERE media_id=$1`, id).Scan(&status); err != nil || status != "deleted" {
		t.Fatalf("clip status %q %v", status, err)
	}
}

func TestThreadedCommentsAreOneLevelDeepAndNotify(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{alice, bob, cara, dev} {
		h.setAge(id, 30)
		h.policy(id, "commentsFrom", "everyone")
	}
	post := h.post(alice, "public", "discuss")
	comment := func(user, body string, parent string) map[string]any {
		payload := map[string]any{"body": body}
		if parent != "" {
			payload["parentId"] = parent
		}
		return h.expect(h.send(user, "POST", "/v1/posts/"+post+"/comments", payload), 201, "").data
	}
	top := comment(bob, "top level", "")
	reply := comment(cara, "reply to bob", top["commentId"].(string))
	deep := comment(dev, "reply to cara's reply", reply["commentId"].(string))
	if deep["parentId"] != top["commentId"] {
		t.Fatalf("a reply to a reply must join the top-level thread: %v", deep["parentId"])
	}
	own := comment(alice, "reply from the author", top["commentId"].(string))
	h.expect(h.send(bob, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": "x", "parentId": "019a4000-0000-7000-8000-00000000dead"}), 422, "VALIDATION")
	// Listing: flat as before, top-level with replyCount, replies of one comment.
	if n := len(items(h.ok(dev, "GET", "/v1/posts/"+post+"/comments"))); n != 4 {
		t.Fatalf("flat list %d", n)
	}
	tops := items(h.ok(dev, "GET", "/v1/posts/"+post+"/comments?parent=none"))
	if len(tops) != 1 || tops[0]["replyCount"] != float64(3) {
		t.Fatalf("top level %v", tops)
	}
	replies := items(h.ok(dev, "GET", "/v1/posts/"+post+"/comments?parent="+top["commentId"].(string)))
	if len(replies) != 3 || replies[0]["body"] != "reply to bob" || replies[0]["replyCount"] != float64(0) {
		t.Fatalf("replies %v", replies)
	}
	h.expect(h.call(dev, "GET", "/v1/posts/"+post+"/comments?parent=oops"), 422, "VALIDATION")
	// Notifications: bob hears about replies (cara's and alice's); alice, the post author, hears about the two
	// comments that were not replies to her own comment, and not about her own reply.
	events := func(user string) []string {
		var out []string
		for _, n := range items(h.ok(user, "GET", "/v1/notifications")) {
			out = append(out, n["event"].(string))
		}
		return out
	}
	if got := events(bob); fmt.Sprint(got) != "[comment.replied comment.replied]" {
		t.Fatalf("bob (replied to by cara and alice; dev answered cara) %v", got)
	}
	aliceGot := events(alice)
	if len(aliceGot) == 0 || strings.Contains(strings.Join(aliceGot, ","), "comment.replied") {
		t.Fatalf("alice %v", aliceGot)
	}
	if got := events(cara); fmt.Sprint(got) != "[comment.replied]" {
		t.Fatalf("cara (replied to by dev) %v", got)
	}
	// The count of the post follows, and deleting the top-level comment removes its replies with it.
	if c := h.ok(dev, "GET", "/v1/posts/"+post)["commentCount"]; c != float64(4) {
		t.Fatalf("count %v", c)
	}
	h.ok(bob, "DELETE", "/v1/comments/"+top["commentId"].(string))
	if c := h.ok(dev, "GET", "/v1/posts/"+post)["commentCount"]; c != float64(0) {
		t.Fatalf("count after deleting the thread %v", c)
	}
	if n := len(items(h.ok(dev, "GET", "/v1/posts/"+post+"/comments"))); n != 0 {
		t.Fatalf("thread still listed: %d", n)
	}
	_ = own
	// A restricted commenter's comments and replies are stored hidden and notify nobody.
	h.setAge(xan, 30)
	h.policy(xan, "commentsFrom", "everyone")
	h.ok(alice, "POST", "/v1/users/"+xan+"/restrict")
	t2 := comment(bob, "again", "")
	if hidden := comment(xan, "hidden reply", t2["commentId"].(string)); hidden["commentId"] == "" {
		t.Fatal("hidden reply")
	}
	comment(xan, "hidden top level", "")
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM notifications WHERE actor_id=$1`, xan).Scan(&n); err != nil || n != 0 {
		t.Fatalf("a restricted member's comments notified someone: %d %v", n, err)
	}
	if c := h.ok(dev, "GET", "/v1/posts/"+post)["commentCount"]; c != float64(1) {
		t.Fatalf("hidden comments are not counted: %v", c)
	}
}

func TestMyActivityListsCommentsAndReactionsWithRemovedPosts(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{alice, bob, cara} {
		h.setAge(id, 30)
		h.policy(id, "commentsFrom", "everyone")
	}
	p1, p2, p3 := h.post(alice, "public", "first post"), h.post(alice, "public", "second post"), h.post(cara, "public", "third post")
	for _, p := range []string{p1, p2, p3} {
		h.expect(h.send(bob, "POST", "/v1/posts/"+p+"/comments", map[string]any{"body": "c on " + p[:4]}), 201, "")
		h.expect(h.send(bob, "PUT", "/v1/posts/"+p+"/reaction", map[string]any{"reaction": "heart"}), 200, "")
	}
	comments := items(h.ok(bob, "GET", "/v1/me/activity/comments"))
	if len(comments) != 3 {
		t.Fatalf("comments %d", len(comments))
	}
	first := comments[0]["post"].(map[string]any)
	if first["state"] != "available" || first["excerpt"] != "third post" || first["author"] == nil {
		t.Fatalf("card %v", first)
	}
	h.ok(alice, "DELETE", "/v1/posts/"+p1)
	h.ok(bob, "POST", "/v1/users/"+cara+"/block")
	reactions := items(h.ok(bob, "GET", "/v1/me/activity/reactions"))
	states := map[string]string{}
	for _, r := range reactions {
		post := r["post"].(map[string]any)
		states[r["postId"].(string)] = post["state"].(string)
		if post["state"] == "removed" && (post["author"] != nil || post["excerpt"] != "") {
			t.Fatalf("a removed post leaks: %v", post)
		}
	}
	if states[p1] != "removed" || states[p2] != "available" || states[p3] != "removed" {
		t.Fatalf("states %v", states)
	}
	// Paging.
	page := h.ok(bob, "GET", "/v1/me/activity/comments?limit=2")
	if len(items(page)) != 2 || page["nextCursor"] == nil {
		t.Fatalf("page %v", page)
	}
	rest := h.ok(bob, "GET", "/v1/me/activity/comments?limit=2&cursor="+page["nextCursor"].(string))
	if len(items(rest)) != 1 {
		t.Fatalf("rest %d", len(items(rest)))
	}
	// Another member's activity is never visible.
	if n := len(items(h.ok(alice, "GET", "/v1/me/activity/comments"))); n != 0 {
		t.Fatalf("alice sees %d", n)
	}
}

func TestNotificationChoicesAndPushAudience(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 30)
	h.setAge(bob, 15)
	h.setAge(cara, 30)
	adult := h.ok(alice, "GET", "/v1/me/notifications")
	if adult["enabled"] != true || adult["follows"] != true || adult["comments"] != true || adult["visits"] != false || adult["hideNames"] != false || adult["social"] != true {
		t.Fatalf("adult defaults %v", adult)
	}
	if minor := h.ok(bob, "GET", "/v1/me/notifications"); minor["hideNames"] != true || minor["visits"] != false {
		t.Fatalf("minor defaults %v", minor)
	}
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{}), 422, "VALIDATION")
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"loud": true}), 422, "VALIDATION")
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"comments": "yes"}), 422, "VALIDATION")
	got := h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"comments": false, "visits": true}), 200, "").data
	if got["comments"] != false || got["visits"] != true || got["follows"] != true || got["social"] != true {
		t.Fatalf("patched %v", got)
	}
	// The legacy umbrella sets every social category except visits; categories set explicitly in the same patch win.
	got = h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"social": false}), 200, "").data
	if got["social"] != false || got["follows"] != false || got["replies"] != false || got["reactions"] != false || got["friendRequests"] != false || got["visits"] != true || got["chat"] != true {
		t.Fatalf("umbrella off %v", got)
	}
	got = h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"social": true, "reactions": false}), 200, "").data
	if got["reactions"] != false || got["follows"] != true || got["social"] != true {
		t.Fatalf("umbrella on %v", got)
	}

	// The dispatcher's database half: every kind against the choices.
	audience := func(recipient, actor, kind string) (bool, string) {
		t.Helper()
		category := "social"
		switch kind {
		case "chat":
			category = "chat"
		case "device":
			category = "security"
		}
		ok, name, err := h.db.PushAudienceFor(h.ctx, recipient, actor, "", category, kind)
		if err != nil {
			t.Fatal(err)
		}
		return ok, name
	}
	// Alice now has comments, follows, replies and requests on, reactions off, visits on, names shown.
	for kind, want := range map[string]bool{"follow": true, "follow_request": true, "friend_request": true, "comment": true, "reply": true, "reaction": false, "visit": true, "visit_anon": true, "chat": true} {
		if ok, _ := audience(alice, cara, kind); ok != want {
			t.Errorf("%s: pushed=%v want %v", kind, ok, want)
		}
	}
	if ok, name := audience(alice, cara, "follow"); !ok || name != "Cara" {
		t.Fatalf("names are shown by default for an adult: %v %q", ok, name)
	}
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"hideNames": true}), 200, "")
	if ok, name := audience(alice, cara, "follow"); !ok || name != "" {
		t.Fatalf("hideNames must make the push generic: %v %q", ok, name)
	}
	// The master switch silences everything but security; support obeys it too.
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"enabled": false}), 200, "")
	for _, kind := range []string{"follow", "comment", "chat", "visit"} {
		if ok, _ := audience(alice, cara, kind); ok {
			t.Errorf("%s pushed with the master switch off", kind)
		}
	}
	if ok, _ := audience(alice, alice, "device"); !ok {
		t.Error("a security push must ignore every choice")
	}
	if ok, _, _ := h.db.PushAudienceFor(h.ctx, alice, supportNobody, "", "social", "support"); ok {
		t.Error("support pushed with the master switch off")
	}
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"enabled": true}), 200, "")
	if ok, _, _ := h.db.PushAudienceFor(h.ctx, alice, supportNobody, "", "social", "support"); !ok {
		t.Error("support must push to a member with pushes on")
	}
	// A minor starts with names hidden and visit notices off; blocks and the age band still stop a push.
	h.setAge(eli, 15)
	if ok, name := audience(bob, eli, "follow"); !ok || name != "" {
		t.Fatalf("minor default: %v %q", ok, name)
	}
	if ok, _ := audience(bob, eli, "visit"); ok {
		t.Fatal("visit pushes are off by default")
	}
	if ok, _ := audience(bob, cara, "follow"); ok {
		t.Fatal("a push crossed the age band")
	}
	h.expect(h.send(bob, "PATCH", "/v1/me/notifications", map[string]any{"hideNames": false}), 200, "")
	if ok, name := audience(bob, eli, "follow"); !ok || name != "Eli" {
		t.Fatalf("a minor may choose to show names: %v %q", ok, name)
	}
	h.ok(bob, "POST", "/v1/users/"+eli+"/block")
	if ok, _ := audience(bob, eli, "follow"); ok {
		t.Fatal("a push crossed a block")
	}
}

func TestProfileVisitNoticesAreAnOwnerOptIn(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{alice, bob, cara, dev} {
		h.setAge(id, 30)
	}
	notices := func(user string) int {
		n := 0
		for _, it := range items(h.ok(user, "GET", "/v1/notifications")) {
			if it["event"] == "profile.visited" {
				n++
			}
		}
		return n
	}
	// Off by default: a first visit creates no notice.
	h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	if notices(alice) != 0 {
		t.Fatal("a visit notice without an opt-in")
	}
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"visits": true}), 200, "")
	h.ok(cara, "GET", "/v1/users/"+alice+"/profile")
	h.ok(cara, "GET", "/v1/users/"+alice+"/profile")
	items := items(h.ok(alice, "GET", "/v1/notifications"))
	if len(items) != 1 || items[0]["event"] != "profile.visited" || items[0]["type"] != "visit" || items[0]["targetType"] != "profile" || items[0]["targetId"] != cara {
		t.Fatalf("notice %v", items)
	}
	// Bob's earlier visit is a recorded pair: a repeat never notifies (one per visitor, and at most one a day).
	h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	if notices(alice) != 1 {
		t.Fatalf("repeat visit notified: %d", notices(alice))
	}
	// Nobody is notified about their own profile, or by a blocked or other-band member.
	h.ok(alice, "GET", "/v1/users/"+alice+"/profile")
	h.ok(dev, "POST", "/v1/users/"+alice+"/block")
	h.expect(h.call(dev, "GET", "/v1/users/"+alice+"/profile"), 404, "NOT_FOUND")
	h.setAge(eli, 15)
	h.expect(h.call(eli, "GET", "/v1/users/"+alice+"/profile"), 404, "NOT_FOUND")
	if notices(alice) != 1 {
		t.Fatalf("a refused visit notified: %d", notices(alice))
	}
	// The store reports whether a push may name the visitor: only when their own profile audience lets the owner in.
	h.policy(xan, "profileAudience", "friends")
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{profileAudience}','"friends"') WHERE user_id=$1`, xan)
	h.setAge(xan, 30)
	created, named, err := h.db.VisitNotice(h.ctx, xan, alice)
	if err != nil || !created || named {
		t.Fatalf("a visitor with a closed profile: created=%v named=%v %v", created, named, err)
	}
	if again, _, _ := h.db.VisitNotice(h.ctx, xan, alice); again {
		t.Fatal("a second notice inside a day")
	}
}

func TestNoticeBoardAudienceLocaleUnreadAndPinned(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 30)
	h.setAge(bob, 15)
	h.exec(`DELETE FROM notices`)
	h.exec(`INSERT INTO operators(operator_id,email,display_name,role,password_hash,totp_secret) VALUES('019a4000-0000-7000-8000-0000000000a1','staff@hiyall.test','Staff','admin','x','\x00')
 ON CONFLICT DO NOTHING`)
	add := func(category, title, audience, locale string, pinned bool, publishedAgo, expiresIn string, unpublished bool) {
		t.Helper()
		var expires any
		if expiresIn != "" {
			expires = expiresIn
		}
		h.exec(`INSERT INTO notices(notice_id,category,title,body,audience,locale,pinned,published_at,expires_at,unpublished_at,created_by)
 VALUES(gen_random_uuid(),$1,$2,'body text',$3,$4,$5,now()-$6::interval,now()+$7::interval,CASE WHEN $8 THEN now() END,'019a4000-0000-7000-8000-0000000000a1')`, category, title, audience, locale, pinned, publishedAgo, expires, unpublished)
		_ = expires
	}
	// Created after both members exist, so each is "unread" for the member.
	h.exec(`UPDATE users SET created_at=now()-interval '10 days'`)
	add("safety", "For everyone", "all", "", true, "1 hour", "1 day", false)
	add("news", "For teens", "minors", "", false, "2 hours", "1 day", false)
	add("update", "For adults", "adults", "", false, "3 hours", "1 day", false)
	add("news", "Hindi only", "all", "hi", false, "4 hours", "1 day", false)
	add("news", "Old", "all", "", false, "5 hours", "-1 hour", false)
	add("news", "Pulled", "all", "", false, "6 hours", "1 day", true)
	add("news", "Scheduled", "all", "", false, "-1 hour", "1 day", false)
	titles := func(user, query string) []string {
		var out []string
		for _, n := range items(h.ok(user, "GET", "/v1/notices"+query)) {
			out = append(out, n["title"].(string))
		}
		return out
	}
	same(t, titles(alice, ""), "For everyone", "For adults")
	same(t, titles(bob, ""), "For everyone", "For teens")
	same(t, titles(alice, "?locale=hi-IN"), "For everyone", "For adults", "Hindi only")
	same(t, titles(alice, "?locale=en"), "For everyone", "For adults")
	// The summary: the unread count and the pinned banner.
	sum := h.ok(alice, "GET", "/v1/notices/summary")
	pinned := sum["pinned"].([]any)
	if sum["unreadCount"] != float64(2) || len(pinned) != 1 || pinned[0].(map[string]any)["title"] != "For everyone" || pinned[0].(map[string]any)["unread"] != true {
		t.Fatalf("summary %v", sum)
	}
	list := h.ok(alice, "GET", "/v1/notices")
	if list["unreadCount"] != float64(2) || len(list["pinned"].([]any)) != 1 {
		t.Fatalf("list extras %v", list)
	}
	// Seen moves the pointer: nothing is unread, and a notice published later is.
	h.ok(alice, "POST", "/v1/notices/seen")
	if h.ok(alice, "GET", "/v1/notices/summary")["unreadCount"] != float64(0) {
		t.Fatal("still unread after seen")
	}
	for _, it := range items(h.ok(alice, "GET", "/v1/notices")) {
		if it["unread"] != false {
			t.Fatalf("unread item %v", it)
		}
	}
	add("update", "Fresh", "all", "", false, "0 seconds", "1 day", false)
	if h.ok(alice, "GET", "/v1/notices/summary")["unreadCount"] != float64(1) {
		t.Fatal("a new notice is not unread")
	}
	// Paging.
	page := h.ok(alice, "GET", "/v1/notices?limit=2")
	if len(items(page)) != 2 || page["nextCursor"] == nil {
		t.Fatalf("page %v", page)
	}
	if rest := h.ok(alice, "GET", "/v1/notices?limit=2&cursor="+page["nextCursor"].(string)); len(items(rest)) != 1 {
		t.Fatalf("rest %v", rest)
	}
	// The pointer is the only thing kept, and it goes with the account.
	if n := func() int {
		var c int
		_ = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM notice_seen WHERE user_id=$1`, alice).Scan(&c)
		return c
	}(); n != 1 {
		t.Fatalf("pointer rows %d", n)
	}
}

func TestSupportThreadsLimitsPlaintextAndRetention(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 30)
	h.setAge(bob, 15) // minors may write to support
	h.exec(`INSERT INTO operators(operator_id,email,display_name,role,password_hash,totp_secret) VALUES('019a4000-0000-7000-8000-0000000000a1','staff@hiyall.test','Staff','moderator','x','\x00')
 ON CONFLICT DO NOTHING`)
	made := h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "safety", "body": "someone keeps messaging me"}), 201, "").data
	thread := made["threadId"].(string)
	if made["status"] != "open" || made["category"] != "safety" || made["lastAuthor"] != "member" || made["unread"] != false {
		t.Fatalf("thread %v", made)
	}
	// One open thread per category; other categories are fine; bad input is refused.
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "safety", "body": "again"}), 409, "SUPPORT_THREAD_OPEN")
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "bug", "body": "the app crashed"}), 201, "")
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "billing", "body": "x"}), 422, "VALIDATION")
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "other", "body": "   "}), 422, "VALIDATION")
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "other", "body": strings.Repeat("x", 2001)}), 422, "VALIDATION")
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "other", "body": "hi", "extra": 1}), 422, "VALIDATION")
	// Only the member reads and writes their thread.
	h.expect(h.call(alice, "GET", "/v1/support/threads/"+thread), 404, "NOT_FOUND")
	h.expect(h.call(alice, "GET", "/v1/support/threads/"+thread+"/messages"), 404, "NOT_FOUND")
	h.expect(h.send(alice, "POST", "/v1/support/threads/"+thread+"/messages", map[string]any{"body": "hello"}), 404, "NOT_FOUND")
	if n := len(items(h.ok(alice, "GET", "/v1/support/threads"))); n != 0 {
		t.Fatalf("alice lists %d", n)
	}
	h.expect(h.send(bob, "POST", "/v1/support/threads/"+thread+"/messages", map[string]any{"body": "more detail"}), 201, "")
	// A staff reply (the console's insert): unread for the member until they open it; the name is never sent.
	h.exec(`INSERT INTO support_messages(message_id,thread_id,author,operator_id,body) VALUES(gen_random_uuid(),$1,'staff','019a4000-0000-7000-8000-0000000000a1','We are on it')`, thread)
	h.exec(`UPDATE support_threads SET last_message_at=now(),member_read_at=now()-interval '1 minute',last_author='staff' WHERE thread_id=$1`, thread)
	list := h.ok(bob, "GET", "/v1/support/threads")
	if list["unreadCount"] != float64(1) || items(list)[0]["unread"] != true || items(list)[0]["preview"] != "We are on it" {
		t.Fatalf("list %v", list)
	}
	if h.ok(bob, "GET", "/v1/support/unread")["unreadCount"] != float64(1) {
		t.Fatal("unread count")
	}
	msgs := items(h.ok(bob, "GET", "/v1/support/threads/"+thread+"/messages"))
	if len(msgs) != 3 || msgs[2]["author"] != "staff" || msgs[2]["body"] != "We are on it" || msgs[2]["operator"] != nil || strings.Contains(fmt.Sprint(msgs), "Staff") {
		t.Fatalf("messages %v", msgs)
	}
	if h.ok(bob, "GET", "/v1/support/unread")["unreadCount"] != float64(0) {
		t.Fatal("opening the thread did not mark it read")
	}
	// The push is claimed once across nodes.
	users, err := h.db.ClaimSupportPushes(h.ctx, 10)
	if err != nil || len(users) != 1 || users[0] != bob {
		t.Fatalf("claim %v %v", users, err)
	}
	if again, _ := h.db.ClaimSupportPushes(h.ctx, 10); len(again) != 0 {
		t.Fatalf("claimed twice %v", again)
	}
	// Close, refuse, and a new thread in the category is allowed again.
	h.expect(h.send(bob, "POST", "/v1/support/threads/"+thread+"/close", nil), 200, "")
	h.expect(h.send(bob, "POST", "/v1/support/threads/"+thread+"/messages", map[string]any{"body": "still there?"}), 409, "SUPPORT_THREAD_CLOSED")
	h.expect(h.send(bob, "POST", "/v1/support/threads/"+thread+"/close", nil), 404, "NOT_FOUND")
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "safety", "body": "a new problem"}), 201, "")
	// 20 messages a day, counted when a thread is opened and when a message is sent.
	h.exec(`INSERT INTO member_daily_counts(user_id,kind,day,n) VALUES($1,'support_message',(now() AT TIME ZONE 'UTC')::date,$2) ON CONFLICT (user_id,kind,day) DO UPDATE SET n=excluded.n`, bob, domain.Free().SupportMessagesPerDay)
	h.expect(h.send(bob, "POST", "/v1/support/threads", map[string]any{"category": "account", "body": "x"}), 429, "DAILY_LIMIT")
	open := h.ok(bob, "GET", "/v1/support/threads?limit=1")["nextCursor"]
	if open == nil {
		t.Fatal("support list is not paged")
	}
	// Retention: a thread closed 365 days ago is purged with its messages; an open or recent one stays.
	h.exec(`UPDATE support_threads SET closed_at=now()-interval '366 days' WHERE thread_id=$1`, thread)
	if n, err := h.db.PurgeSupportThreads(h.ctx, 365*24*time.Hour, 100); err != nil || n != 1 {
		t.Fatalf("purge %d %v", n, err)
	}
	var left int
	if err = h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM support_messages WHERE thread_id=$1`, thread).Scan(&left); err != nil || left != 0 {
		t.Fatalf("messages left %d %v", left, err)
	}
	if n, _ := h.db.PurgeSupportThreads(h.ctx, 365*24*time.Hour, 100); n != 0 {
		t.Fatalf("open threads purged: %d", n)
	}
}

func TestExportIncludesSupportThreadsAndTheNewChoices(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 30)
	h.expect(h.send(alice, "POST", "/v1/support/threads", map[string]any{"category": "account", "body": "please help me export"}), 201, "")
	h.expect(h.send(alice, "PATCH", "/v1/me/notifications", map[string]any{"visits": true}), 200, "")
	var out bytes.Buffer
	if _, err := h.db.ExportAccount(h.ctx, alice, &out, store.ExportOptions{}); err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Support []struct {
			Category string
			Messages []struct{ Body string }
		}
		Settings struct{ Notifications map[string]any }
	}
	if err := json.Unmarshal(out.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Support) != 1 || doc.Support[0].Category != "account" || doc.Support[0].Messages[0].Body != "please help me export" {
		t.Fatalf("support section %+v", doc.Support)
	}
	if doc.Settings.Notifications["visits"] != true {
		t.Fatalf("notification choices %v", doc.Settings.Notifications)
	}
}
