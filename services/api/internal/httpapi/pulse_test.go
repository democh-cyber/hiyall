package httpapi

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"strings"
	"testing"

	"hiyall/services/api/internal/media"
)

// photo encodes a small JPEG and splices in an EXIF segment carrying a GPS
// marker, like a phone camera would.
func photo(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 120, 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	payload := []byte("Exif\x00\x00GPSLatitude=12.97;GPSLongitude=77.59")
	segment := append([]byte{0xFF, 0xE1, byte((len(payload) + 2) >> 8), byte(len(payload) + 2)}, payload...)
	data := buf.Bytes()
	return append(append(append([]byte{}, data[:2]...), segment...), data[2:]...)
}

func withMedia(h *socialHarness) *media.Memory {
	store := media.NewMemory()
	h.api.Media = store
	return store
}

// upload runs the full client flow and returns the media id.
func (h *socialHarness) upload(store *media.Memory, user, purpose string, data []byte) string {
	h.t.Helper()
	made := h.expect(h.send(user, "POST", "/v1/media/uploads", map[string]any{"purpose": purpose, "contentType": "image/jpeg", "sizeBytes": len(data)}), 201, "").data
	id := made["mediaId"].(string)
	key := strings.TrimPrefix(made["uploadUrl"].(string), "memory://put/")
	_ = store.Put(h.ctx, key, data, "image/jpeg")
	h.expect(h.call(user, "POST", "/v1/media/"+id+"/complete"), 200, "")
	return id
}

func (h *socialHarness) post(user, audience, body string, mediaIDs ...string) string {
	h.t.Helper()
	if mediaIDs == nil {
		mediaIDs = []string{}
	}
	return h.expect(h.send(user, "POST", "/v1/posts", map[string]any{"body": body, "audience": audience, "mediaIds": mediaIDs}), 201, "").data["postId"].(string)
}

func feedBodies(h *socialHarness, user, mode string) []string {
	h.t.Helper()
	var out []string
	for _, p := range items(h.ok(user, "GET", "/v1/feed?mode="+mode)) {
		out = append(out, p["body"].(string))
	}
	return out
}

func TestPhotoUploadsAreReencodedWithoutMetadataAndBounded(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	original := photo(t, 300, 200)
	if !bytes.Contains(original, []byte("GPSLatitude")) {
		t.Fatal("fixture lacks location metadata")
	}
	id := h.upload(store, alice, "post", original)
	var full, thumb []byte
	for key, data := range store.Objects {
		switch {
		case strings.HasSuffix(key, id+"/full.jpg"):
			full = data
		case strings.HasSuffix(key, id+"/thumb.jpg"):
			thumb = data
		case strings.HasPrefix(key, "uploads/"):
			t.Fatalf("original kept: %s", key)
		}
	}
	if full == nil || thumb == nil || bytes.Contains(full, []byte("GPS")) || bytes.Contains(full, []byte("Exif")) {
		t.Fatal("variants missing or still carry metadata")
	}
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(full)); err != nil || cfg.Width != 300 || cfg.Height != 200 {
		t.Fatalf("full variant %v %v", cfg, err)
	}

	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/gif", "sizeBytes": 10}), 415, "UNSUPPORTED_MEDIA")
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": media.MaxUploadBytes + 1}), 413, "TOO_LARGE")
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "banner", "contentType": "image/jpeg", "sizeBytes": 10}), 422, "VALIDATION")

	// A file that isn't an image is rejected and its upload removed.
	made := h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 11}), 201, "").data
	key := strings.TrimPrefix(made["uploadUrl"].(string), "memory://put/")
	_ = store.Put(h.ctx, key, []byte("not a photo"), "image/jpeg")
	h.expect(h.call(alice, "POST", "/v1/media/"+made["mediaId"].(string)+"/complete"), 415, "UNSUPPORTED_MEDIA")
	if _, ok := store.Objects[key]; ok {
		t.Fatal("rejected upload kept")
	}
	// Uploading more than declared is refused; someone else can't complete yours.
	made = h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 100}), 201, "").data
	_ = store.Put(h.ctx, strings.TrimPrefix(made["uploadUrl"].(string), "memory://put/"), original, "image/jpeg")
	h.expect(h.call(bob, "POST", "/v1/media/"+made["mediaId"].(string)+"/complete"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/media/"+made["mediaId"].(string)+"/complete"), 422, "VALIDATION")

	// Media can be attached once, by its owner, for its purpose.
	h.expect(h.send(bob, "POST", "/v1/posts", map[string]any{"body": "mine now", "audience": "public", "mediaIds": []string{id}}), 409, "MEDIA_NOT_READY")
	story := h.upload(store, alice, "story", photo(t, 20, 20))
	h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "", "audience": "public", "mediaIds": []string{story}}), 409, "MEDIA_NOT_READY")
	post := h.post(alice, "public", "", id)
	h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "again", "audience": "public", "mediaIds": []string{id}}), 409, "MEDIA_NOT_READY")
	got := h.ok(alice, "GET", "/v1/posts/"+post)
	m := got["media"].([]any)[0].(map[string]any)
	if m["width"] != float64(300) || !strings.Contains(m["url"].(string), id+"/full.jpg") {
		t.Fatalf("post media %v", m)
	}

	// Deleting the post queues its photos; cleanup removes the objects.
	h.ok(alice, "DELETE", "/v1/posts/"+post)
	h.expect(h.call(alice, "GET", "/v1/posts/"+post), 404, "NOT_FOUND")
	keys, rows, err := h.db.MediaGarbage(h.ctx, 100)
	if err != nil || rows < 1 {
		t.Fatalf("garbage %v %d %v", keys, rows, err)
	}
	_ = store.Delete(h.ctx, keys...)
	for key := range store.Objects {
		if strings.Contains(key, id) {
			t.Fatalf("deleted post's photo remains: %s", key)
		}
	}
	if again, _, _ := h.db.MediaGarbage(h.ctx, 100); len(again) != 0 {
		t.Fatalf("garbage returned twice: %v", again)
	}
}

func TestFeedRespectsAudienceMuteAndBlock(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(alice, "followPolicy", "everyone")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(alice, "POST", "/v1/users/"+cara+"/friend-requests")
	h.ok(cara, "POST", "/v1/users/"+alice+"/friend-requests")

	h.post(alice, "public", "for everyone")
	h.post(alice, "followers", "for followers")
	h.post(alice, "friends", "for friends")
	h.post(dev, "public", "dev says hi")

	if got := feedBodies(h, bob, "following"); fmt.Sprint(got) != "[for followers for everyone]" {
		t.Fatalf("follower sees %v", got)
	}
	if got := feedBodies(h, cara, "following"); fmt.Sprint(got) != "[for friends for followers for everyone]" {
		t.Fatalf("friend sees %v", got)
	}
	if got := feedBodies(h, alice, "following"); len(got) != 3 {
		t.Fatalf("own posts %v", got)
	}
	if got := feedBodies(h, eli, "following"); len(got) != 0 {
		t.Fatalf("stranger following feed %v", got)
	}
	if got := feedBodies(h, eli, "everyone"); fmt.Sprint(got) != "[dev says hi for everyone]" {
		t.Fatalf("everyone feed %v", got)
	}

	// Posts hidden from the viewer never crowd out older visible ones.
	// Direct rows: 25 more posts in one day are past the daily post limit.
	h.exec(`INSERT INTO posts(post_id,author_id,body,audience,created_at) SELECT gen_random_uuid(),$1,'friends only '||g,'friends',now()-interval '1 minute'+g*interval '1 millisecond' FROM generate_series(0,24) g`, alice)
	first := h.ok(bob, "GET", "/v1/feed?limit=1")
	if got := items(first); len(got) != 1 || got[0]["body"] != "for followers" || first["nextCursor"] == nil {
		t.Fatalf("page %v", got)
	}
	next := h.ok(bob, "GET", "/v1/feed?limit=1&cursor="+first["nextCursor"].(string))
	if got := items(next); len(got) != 1 || got[0]["body"] != "for everyone" || next["nextCursor"] != nil {
		t.Fatalf("second page %v", next)
	}

	h.ok(bob, "POST", "/v1/users/"+alice+"/mute")
	if got := feedBodies(h, bob, "following"); len(got) != 0 {
		t.Fatalf("muted author in feed %v", got)
	}
	if got := feedBodies(h, bob, "everyone"); fmt.Sprint(got) != "[dev says hi]" {
		t.Fatalf("muted author in everyone %v", got)
	}
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/mute")
	public := items(h.ok(eli, "GET", "/v1/users/"+alice+"/posts"))
	if len(public) != 1 {
		t.Fatalf("profile posts for stranger %v", public)
	}
	h.ok(alice, "POST", "/v1/users/"+eli+"/block")
	h.expect(h.call(eli, "GET", "/v1/posts/"+public[0]["postId"].(string)), 404, "NOT_FOUND")
	if got := feedBodies(h, eli, "everyone"); fmt.Sprint(got) != "[dev says hi]" {
		t.Fatalf("blocked author visible %v", got)
	}
}

func TestReactionsCommentsAndSaves(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(alice, "followPolicy", "everyone")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(alice, "POST", "/v1/notifications/read-all")
	post := h.post(alice, "followers", "hello")
	path := "/v1/posts/" + post

	h.expect(h.send(bob, "PUT", path+"/reaction", map[string]string{"reaction": "meh"}), 422, "VALIDATION")
	h.expect(h.send(cara, "PUT", path+"/reaction", map[string]string{"reaction": "heart"}), 404, "NOT_FOUND")
	h.expect(h.send(bob, "PUT", path+"/reaction", map[string]string{"reaction": "heart"}), 200, "")
	h.expect(h.send(bob, "PUT", path+"/reaction", map[string]string{"reaction": "fire"}), 200, "")
	h.expect(h.send(alice, "PUT", path+"/reaction", map[string]string{"reaction": "laugh"}), 200, "")
	got := h.ok(bob, "GET", path)
	if got["reactionCount"] != float64(2) || got["myReaction"] != "fire" {
		t.Fatalf("reactions %v", got)
	}
	if n := h.ok(alice, "GET", "/v1/notifications"); n["unreadCount"] != float64(1) || items(n)[0]["text"] != "Niko reacted to your post" {
		t.Fatalf("reaction activity %v", n)
	}
	h.ok(bob, "DELETE", path+"/reaction")
	h.ok(bob, "DELETE", path+"/reaction")
	if got := h.ok(bob, "GET", path); got["reactionCount"] != float64(1) || got["myReaction"] != nil {
		t.Fatalf("after removal %v", got)
	}

	// Comments default to friends only.
	h.expect(h.send(bob, "POST", path+"/comments", map[string]string{"body": "nice"}), 403, "COMMENTS_NOT_ALLOWED")
	h.policy(alice, "commentsFrom", "followers")
	c1 := h.expect(h.send(bob, "POST", path+"/comments", map[string]string{"body": "nice"}), 201, "").data
	h.expect(h.send(alice, "POST", path+"/comments", map[string]any{"body": "thanks", "parentId": c1["commentId"]}), 201, "")
	h.expect(h.send(alice, "POST", path+"/comments", map[string]any{"body": "x", "parentId": "019a4000-0000-7000-8000-00000000dead"}), 422, "VALIDATION")
	h.expect(h.send(bob, "POST", path+"/comments", map[string]string{"body": "  "}), 422, "VALIDATION")

	// A restricted commenter's words reach only them.
	h.ok(alice, "POST", "/v1/users/"+bob+"/restrict")
	h.expect(h.send(bob, "POST", path+"/comments", map[string]string{"body": "only I see this"}), 201, "")
	if list := items(h.ok(bob, "GET", path+"/comments")); len(list) != 3 || list[2]["body"] != "only I see this" {
		t.Fatalf("bob's view %v", list)
	}
	if list := items(h.ok(alice, "GET", path+"/comments")); len(list) != 2 {
		t.Fatalf("author sees hidden comment %v", list)
	}
	if got := h.ok(alice, "GET", path); got["commentCount"] != float64(2) {
		t.Fatalf("hidden comment counted %v", got)
	}
	// The post's author can remove any comment; others only their own.
	reply := items(h.ok(alice, "GET", path+"/comments"))[1]["commentId"].(string)
	h.expect(h.call(bob, "DELETE", "/v1/comments/"+reply), 404, "NOT_FOUND")
	h.ok(alice, "DELETE", "/v1/comments/"+c1["commentId"].(string))
	if got := h.ok(alice, "GET", path); got["commentCount"] != float64(1) {
		t.Fatalf("after delete %v", got)
	}

	// Reports on posts need access and can't target your own.
	h.expect(h.send(cara, "POST", "/v1/reports", map[string]any{"targetType": "post", "targetId": post, "reasonCode": "spam"}), 404, "NOT_FOUND")
	h.expect(h.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "post", "targetId": post, "reasonCode": "spam"}), 422, "VALIDATION")
	reported := h.expect(h.send(bob, "POST", "/v1/reports", map[string]any{"targetType": "post", "targetId": post, "reasonCode": "spam"}), 201, "").data
	if reported["report"].(map[string]any)["subject"].(map[string]any)["userId"] != alice {
		t.Fatalf("post report %v", reported)
	}
	h.ok(bob, "PUT", path+"/save")
	h.ok(bob, "PUT", path+"/save")
	if saved := items(h.ok(bob, "GET", "/v1/me/saved")); len(saved) != 1 || saved[0]["saved"] != true {
		t.Fatalf("saved %v", saved)
	}
	// Losing access removes it from saved, without deleting anything.
	h.ok(bob, "DELETE", "/v1/users/"+alice+"/follow")
	if saved := items(h.ok(bob, "GET", "/v1/me/saved")); len(saved) != 0 {
		t.Fatalf("saved after losing access %v", saved)
	}
}

func TestStoriesTrayViewsAndExpiry(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	h.policy(alice, "followPolicy", "everyone")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	h.ok(cara, "POST", "/v1/users/"+alice+"/follow")

	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"audience": "followers"}), 422, "VALIDATION")
	text := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "gm", "background": "pink", "audience": "followers"}), 201, "").data["storyId"].(string)
	pic := h.upload(store, alice, "story", photo(t, 40, 80))
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"mediaId": pic, "audience": "friends"}), 201, "")
	h.expect(h.send(bob, "POST", "/v1/stories", map[string]any{"body": "bob here", "audience": "public"}), 201, "")

	tray := items(h.ok(bob, "GET", "/v1/stories/tray"))
	if len(tray) != 2 || tray[0]["mine"] != true || tray[1]["allSeen"] != false {
		t.Fatalf("bob's tray %v", tray)
	}
	if stories := tray[1]["stories"].([]any); len(stories) != 1 {
		t.Fatalf("follower sees friends-only story: %v", stories)
	}
	h.ok(bob, "POST", "/v1/stories/"+text+"/view")
	h.ok(bob, "POST", "/v1/stories/"+text+"/view")
	h.expect(h.call(eli, "POST", "/v1/stories/"+text+"/view"), 404, "NOT_FOUND")
	if tray := items(h.ok(bob, "GET", "/v1/stories/tray")); tray[1]["allSeen"] != true {
		t.Fatalf("seen state %v", tray)
	}
	mine := items(h.ok(alice, "GET", "/v1/stories/tray"))[0]
	first := mine["stories"].([]any)[0].(map[string]any)
	if mine["mine"] != true || first["viewCount"] != float64(1) {
		t.Fatalf("author's tray %v", mine)
	}
	if viewers := items(h.ok(alice, "GET", "/v1/stories/"+text+"/viewers")); len(viewers) != 1 || viewers[0]["user"].(map[string]any)["userId"] != bob {
		t.Fatalf("viewers %v", viewers)
	}
	h.expect(h.call(bob, "GET", "/v1/stories/"+text+"/viewers"), 404, "NOT_FOUND")

	// Expired stories leave the tray, then are purged with their photos.
	h.exec(`UPDATE stories SET expires_at=now()-interval '2 days' WHERE author_id=$1`, alice)
	if tray := items(h.ok(cara, "GET", "/v1/stories/tray")); len(tray) != 0 {
		t.Fatalf("expired stories shown %v", tray)
	}
	// The count is stories deleted (two, one with a photo), not media rows, so the hourly loop
	// keeps purging while full batches remain.
	if n, err := h.db.PurgeStories(h.ctx, 100); err != nil || n != 2 {
		t.Fatalf("purge %d %v", n, err)
	}
	keys, _, _ := h.db.MediaGarbage(h.ctx, 100)
	if len(keys) != 3 {
		t.Fatalf("story photo keys %v", keys)
	}
}

// The tray is bounded, and when the bound bites the oldest stories are left out: the viewer's
// own stories always come first, every author contributes their newest, and one prolific author
// cannot crowd the others out.
func TestStoryTrayKeepsOwnAndNewestStories(t *testing.T) {
	h := newSocialHarness(t)
	h.policy(bob, "followPolicy", "everyone")
	h.policy(cara, "followPolicy", "everyone")
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	h.ok(alice, "POST", "/v1/users/"+cara+"/follow")
	add := func(author string, count int, age string) {
		h.exec(`INSERT INTO stories(story_id,author_id,body,audience,created_at,expires_at)
 SELECT gen_random_uuid(),$1,'story '||g,'public',now()-$3::interval+g*interval '1 millisecond',now()+interval '1 hour' FROM generate_series(1,$2::int) g`, author, count, age)
	}
	add(alice, 1, "3 hours")
	add(bob, 2000, "2 hours")
	add(cara, 1, "1 minute")
	tray := items(h.ok(alice, "GET", "/v1/stories/tray"))
	if len(tray) != 3 || tray[0]["mine"] != true {
		t.Fatalf("tray groups %d, first %v", len(tray), tray[0]["author"])
	}
	byAuthor := map[string][]any{}
	for _, g := range tray {
		byAuthor[g["author"].(map[string]any)["userId"].(string)] = g["stories"].([]any)
	}
	if len(byAuthor[alice]) != 1 || len(byAuthor[cara]) != 1 || len(byAuthor[bob]) != 100 {
		t.Fatalf("stories per author: alice %d cara %d bob %d", len(byAuthor[alice]), len(byAuthor[cara]), len(byAuthor[bob]))
	}
	// Bob's are his newest 100, oldest first within the group.
	bobs := byAuthor[bob]
	if first, last := bobs[0].(map[string]any)["body"], bobs[99].(map[string]any)["body"]; first != "story 1901" || last != "story 2000" {
		t.Fatalf("bob's stories run %v to %v", first, last)
	}
}
