package httpapi

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"hiyall/services/api/internal/media"
)

// avatarPhoto is the photo every avatar test uploads.
func avatarPhoto(t *testing.T) []byte { return photo(t, 120, 90) }

// setAvatar patches avatarMediaId (a media id or nil) at the caller's current profile version.
func (h *socialHarness) setAvatar(user string, value any) reply {
	h.t.Helper()
	body, _ := json.Marshal(map[string]any{"avatarMediaId": value})
	return h.patch(user, "/v1/me/profile", fmt.Sprint(h.ok(user, "GET", "/v1/me/profile")["version"]), string(body))
}

// avatarState is the stored status and attached flag of a media row.
func (h *socialHarness) avatarState(id string) (status string, attached bool) {
	h.t.Helper()
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT status,attached FROM media_assets WHERE media_id=$1`, id).Scan(&status, &attached); err != nil {
		h.t.Fatal(err)
	}
	return status, attached
}

// wantAvatar checks a person object (or profile) for a signed thumbnail of media id, or for none when id is "".
func wantAvatar(t *testing.T, where string, person map[string]any, id string) {
	t.Helper()
	got, present := person["avatarUrl"]
	if !present {
		t.Fatalf("%s has no avatarUrl key: %v", where, person)
	}
	if id == "" {
		if got != nil {
			t.Fatalf("%s avatarUrl = %v, want null", where, got)
		}
		return
	}
	if got != "memory://get/media/"+id+"/thumb.jpg" {
		t.Fatalf("%s avatarUrl = %v, want the thumbnail of %s", where, got, id)
	}
}

func TestAvatarUploadClaimAndReplace(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := avatarPhoto(t)

	// The avatar purpose is accepted with the same limits as other photos.
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "avatar", "contentType": "image/gif", "sizeBytes": 10}), 415, "UNSUPPORTED_MEDIA")
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "avatar", "contentType": "image/jpeg", "sizeBytes": media.MaxUploadBytes + 1}), 413, "TOO_LARGE")
	first := h.upload(store, alice, "avatar", pic)
	if status, attached := h.avatarState(first); status != "ready" || attached {
		t.Fatalf("uploaded avatar is %s attached=%v", status, attached)
	}
	// Until it is attached to the profile it is not shown.
	profile := h.ok(alice, "GET", "/v1/me/profile")
	if profile["avatarMediaId"] != nil || profile["avatarUrl"] != nil || profile["avatarFullUrl"] != nil {
		t.Fatalf("avatar before claiming: %v", profile)
	}

	// Claiming attaches it and the profile answers with signed URLs (thumbnail and full size).
	set := h.expect(h.setAvatar(alice, first), 200, "").data
	if set["avatarMediaId"] != first || set["avatarUrl"] != "memory://get/media/"+first+"/thumb.jpg" || set["avatarFullUrl"] != "memory://get/media/"+first+"/full.jpg" {
		t.Fatalf("after claiming: %v", set)
	}
	if status, attached := h.avatarState(first); status != "ready" || !attached {
		t.Fatalf("claimed avatar is %s attached=%v", status, attached)
	}
	own := h.ok(alice, "GET", "/v1/me/profile")
	if own["avatarUrl"] != set["avatarUrl"] || own["avatarFullUrl"] != set["avatarFullUrl"] || own["avatarMediaId"] != first {
		t.Fatalf("own profile: %v", own)
	}
	// Signed URLs are never stored in the profile data.
	var stored string
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT data::text FROM profiles WHERE user_id=$1`, alice).Scan(&stored); err != nil || strings.Contains(stored, "memory://") || strings.Contains(stored, "avatarUrl") {
		t.Fatalf("stored profile %s (%v)", stored, err)
	}

	// Sending the current id again is a no-op: the photo stays attached and shown.
	again := h.expect(h.setAvatar(alice, first), 200, "").data
	if again["avatarUrl"] != set["avatarUrl"] {
		t.Fatalf("same id changed the avatar: %v", again)
	}
	if status, attached := h.avatarState(first); status != "ready" || !attached {
		t.Fatalf("same id released the photo: %s attached=%v", status, attached)
	}
	// Other profile fields keep working without touching the avatar.
	h.expect(h.patch(alice, "/v1/me/profile", fmt.Sprint(again["version"]), `{"bio":"still here"}`), 200, "")
	if h.ok(alice, "GET", "/v1/me/profile")["avatarMediaId"] != first {
		t.Fatal("a bio update lost the avatar")
	}

	// Replacing releases the previous photo for the media cleanup, in the same update.
	second := h.upload(store, alice, "avatar", pic)
	h.expect(h.setAvatar(alice, second), 200, "")
	if status, _ := h.avatarState(first); status != "deleted" {
		t.Fatalf("replaced avatar is %s", status)
	}
	if status, attached := h.avatarState(second); status != "ready" || !attached {
		t.Fatalf("new avatar is %s attached=%v", status, attached)
	}
	keys, _, err := h.db.MediaGarbage(h.ctx, 100)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(keys, " ")
	if !strings.Contains(got, first+"/full.jpg") || !strings.Contains(got, first+"/thumb.jpg") || strings.Contains(got, second) {
		t.Fatalf("cleanup keys %v, want only the replaced photo's", keys)
	}
	wantAvatar(t, "own profile", h.ok(alice, "GET", "/v1/me/profile"), second)
	// The released photo cannot be claimed again.
	h.expect(h.setAvatar(alice, first), 422, "VALIDATION")

	// null clears the avatar and releases the photo the same way.
	cleared := h.expect(h.setAvatar(alice, nil), 200, "").data
	if cleared["avatarMediaId"] != nil || cleared["avatarUrl"] != nil || cleared["avatarFullUrl"] != nil {
		t.Fatalf("after clearing: %v", cleared)
	}
	if status, _ := h.avatarState(second); status != "deleted" {
		t.Fatalf("cleared avatar is %s", status)
	}
	if keys, _, _ := h.db.MediaGarbage(h.ctx, 100); !strings.Contains(strings.Join(keys, " "), second+"/full.jpg") {
		t.Fatalf("cleanup keys %v", keys)
	}
	// Clearing when there is none is fine.
	h.expect(h.setAvatar(alice, nil), 200, "")
}

func TestAvatarClaimRefusals(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := avatarPhoto(t)

	mine := h.upload(store, alice, "avatar", pic)
	others := h.upload(store, bob, "avatar", pic)
	postPhoto := h.upload(store, alice, "post", pic)
	storyPhoto := h.upload(store, alice, "story", pic)
	made := h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "avatar", "contentType": "image/jpeg", "sizeBytes": len(pic)}), 201, "").data
	pending := made["mediaId"].(string)
	attached := h.upload(store, alice, "avatar", pic)
	h.exec(`UPDATE media_assets SET attached=true WHERE media_id=$1`, attached)

	for name, id := range map[string]any{
		"someone else's photo":  others,
		"a post photo":          postPhoto,
		"a story photo":         storyPhoto,
		"a pending upload":      pending,
		"an attached photo":     attached,
		"an unknown photo":      "019a4000-0000-7000-8000-00000000ffff",
		"not an id":             "unowned",
		"upper case id":         strings.ToUpper(mine),
		"a number":              7,
		"an object":             map[string]any{"id": mine},
		"an empty id":           "",
		"an id with whitespace": " " + mine,
	} {
		if got := h.setAvatar(alice, id); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("%s: got %d %q", name, got.status, got.code)
		}
		if profile := h.ok(alice, "GET", "/v1/me/profile"); profile["avatarMediaId"] != nil {
			t.Fatalf("%s was accepted: %v", name, profile)
		}
	}
	// The refusals changed nothing about the photos either.
	if status, att := h.avatarState(others); status != "ready" || att {
		t.Fatalf("someone else's photo is %s attached=%v", status, att)
	}
	if status, att := h.avatarState(postPhoto); status != "ready" || att {
		t.Fatalf("post photo is %s attached=%v", status, att)
	}
	// The error names the field.
	body, _ := json.Marshal(map[string]any{"avatarMediaId": others})
	version := fmt.Sprint(h.ok(alice, "GET", "/v1/me/profile")["version"])
	refused := serve(t, h.api.Handler(), "PATCH", "/v1/me/profile", alice, map[string]string{"If-Match": `"` + version + `"`}, string(body))
	if refused.status != 422 || refused.code != "VALIDATION" || !strings.HasPrefix(refused.message, "avatarMediaId:") {
		t.Fatalf("refusal %d %q %q", refused.status, refused.code, refused.message)
	}
	// A refused claim rolls back the whole update, other fields included.
	h.expect(h.patch(alice, "/v1/me/profile", version, `{"bio":"should not stick","avatarMediaId":"`+others+`"}`), 422, "VALIDATION")
	if profile := h.ok(alice, "GET", "/v1/me/profile"); profile["bio"] == "should not stick" || fmt.Sprint(profile["version"]) != version {
		t.Fatalf("a refused avatar still changed the profile: %v", profile)
	}
	// The cover photo stays disabled.
	h.expect(h.patch(alice, "/v1/me/profile", version, `{"coverMediaId":"`+mine+`"}`), 422, "VALIDATION")

	// A valid claim still works after all of that, and a second member cannot take the same photo.
	h.expect(h.setAvatar(alice, mine), 200, "")
	h.expect(h.setAvatar(bob, mine), 422, "VALIDATION")
	wantAvatar(t, "bob's profile", h.ok(bob, "GET", "/v1/me/profile"), "")
}

// Everywhere a person is shown carries avatarUrl.
func TestAvatarUrlOnEveryPersonRow(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := avatarPhoto(t)
	// some makes sure a list this test loops over is not empty, so no check passes vacuously.
	some := func(rows []map[string]any) []map[string]any {
		t.Helper()
		if len(rows) == 0 {
			t.Fatal("empty list")
		}
		return rows
	}
	avatars := map[string]string{}
	for _, user := range []string{alice, bob, cara} {
		avatars[user] = h.upload(store, user, "avatar", pic)
		h.expect(h.setAvatar(user, avatars[user]), 200, "")
	}
	// dev has none.
	h.policy(alice, "followPolicy", "everyone")
	h.policy(bob, "followPolicy", "everyone")
	h.policy(alice, "commentsFrom", "everyone")
	h.policy(alice, "messagesFrom", "everyone")
	h.policy(bob, "messagesFrom", "everyone")
	h.policy(alice, "storyAudience", "everyone")

	// Public profile (the visitor view): thumbnail and full size.
	visit := h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	wantAvatar(t, "public profile", visit, avatars[alice])
	if visit["avatarFullUrl"] != "memory://get/media/"+avatars[alice]+"/full.jpg" {
		t.Fatalf("public profile full url: %v", visit)
	}
	none := h.ok(bob, "GET", "/v1/users/"+dev+"/profile")
	wantAvatar(t, "public profile without a photo", none, "")
	if v, ok := none["avatarFullUrl"]; !ok || v != nil {
		t.Fatalf("avatarFullUrl without a photo: %v", none)
	}
	own := h.ok(alice, "GET", "/v1/users/"+alice+"/profile")
	if own["avatarFullUrl"] == nil {
		t.Fatalf("own profile through the visitor route: %v", own)
	}
	// A locked card still names the person with their thumbnail, but not the full-size photo.
	h.policy(alice, "profileAudience", "private")
	locked := h.ok(cara, "GET", "/v1/users/"+alice+"/profile")
	if locked["locked"] != true || locked["avatarFullUrl"] != nil {
		t.Fatalf("locked card %v", locked)
	}
	wantAvatar(t, "locked card", locked, avatars[alice])
	h.policy(alice, "profileAudience", "public")

	// People search and Nearby.
	h.api.search.reset(cara)
	var found int
	for _, item := range some(items(h.expect(h.send(cara, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data)) {
		switch item["userId"] {
		case alice, bob:
			wantAvatar(t, "search row", item, avatars[item["userId"].(string)])
			found++
		case dev:
			wantAvatar(t, "search row without a photo", item, "")
		}
	}
	if found != 2 {
		t.Fatalf("search found %d of the members with photos", found)
	}
	h.place(cara, bengaluru.Latitude, bengaluru.Longitude)
	h.north(alice, 0.01)
	h.north(dev, 0.02)
	got, _, _ := h.nearbyList(cara, map[string]any{"radiusKm": 25})
	h.expect(got, 200, "")
	for _, item := range some(items(got.data)) {
		id := avatars[item["userId"].(string)]
		wantAvatar(t, "nearby row", item, id)
	}
	if len(items(got.data)) != 2 {
		t.Fatalf("nearby %v", got.data)
	}

	// Posts, comments and stories.
	post := h.post(alice, "public", "hello")
	for _, p := range some(items(h.ok(cara, "GET", "/v1/feed?mode=everyone"))) {
		wantAvatar(t, "post author", p["author"].(map[string]any), avatars[alice])
	}
	wantAvatar(t, "single post author", h.ok(cara, "GET", "/v1/posts/"+post)["author"].(map[string]any), avatars[alice])
	wantAvatar(t, "user posts author", items(h.ok(cara, "GET", "/v1/users/"+alice+"/posts"))[0]["author"].(map[string]any), avatars[alice])
	added := h.expect(h.send(cara, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": "nice"}), 201, "").data
	wantAvatar(t, "new comment author", added["author"].(map[string]any), avatars[cara])
	h.expect(h.send(bob, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": "from bob"}), 201, "")
	h.expect(h.send(dev, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": "no photo"}), 201, "")
	for _, c := range some(items(h.ok(alice, "GET", "/v1/posts/"+post+"/comments"))) {
		who := c["author"].(map[string]any)
		wantAvatar(t, "comment author", who, avatars[who["userId"].(string)])
	}
	story := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"body": "gm", "audience": "public"}), 201, "").data["storyId"].(string)
	h.ok(alice, "POST", "/v1/users/"+bob+"/follow")
	h.ok(bob, "POST", "/v1/users/"+alice+"/follow")
	for _, g := range some(items(h.ok(bob, "GET", "/v1/stories/tray"))) {
		who := g["author"].(map[string]any)
		wantAvatar(t, "story author", who, avatars[who["userId"].(string)])
	}
	h.ok(bob, "POST", "/v1/stories/"+story+"/view")
	wantAvatar(t, "story viewer", items(h.ok(alice, "GET", "/v1/stories/"+story+"/viewers"))[0]["user"].(map[string]any), avatars[bob])

	// Follow lists, requests and activity.
	for _, row := range some(items(h.ok(alice, "GET", "/v1/me/followers"))) {
		who := row["user"].(map[string]any)
		wantAvatar(t, "follower", who, avatars[who["userId"].(string)])
	}
	for _, row := range some(items(h.ok(bob, "GET", "/v1/me/following"))) {
		wantAvatar(t, "following", row["user"].(map[string]any), avatars[alice])
	}
	sent := h.ok(cara, "POST", "/v1/users/"+alice+"/friend-requests")
	wantAvatar(t, "sent friend request sender", sent["sender"].(map[string]any), avatars[cara])
	wantAvatar(t, "sent friend request recipient", sent["recipient"].(map[string]any), avatars[alice])
	for _, row := range some(items(h.ok(alice, "GET", "/v1/me/friend-requests?direction=incoming"))) {
		wantAvatar(t, "incoming request sender", row["sender"].(map[string]any), avatars[cara])
		wantAvatar(t, "incoming request recipient", row["recipient"].(map[string]any), avatars[alice])
	}
	accepted := h.ok(alice, "POST", "/v1/friend-requests/"+sent["requestId"].(string)+"/accept")
	wantAvatar(t, "accepted request", accepted["sender"].(map[string]any), avatars[cara])
	for _, row := range some(items(h.ok(alice, "GET", "/v1/me/friends"))) {
		wantAvatar(t, "friend", row["user"].(map[string]any), avatars[cara])
	}
	notes := items(h.ok(alice, "GET", "/v1/notifications"))
	if len(notes) == 0 {
		t.Fatal("no activity")
	}
	for _, n := range notes {
		for _, actor := range n["actors"].([]any) {
			who := actor.(map[string]any)
			wantAvatar(t, "activity actor", who, avatars[who["userId"].(string)])
		}
	}

	// Conversations.
	h.devicesFor(alice, bob)
	conversation := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data
	wantAvatar(t, "opened conversation peer", conversation["peer"].(map[string]any), avatars[bob])
	wantAvatar(t, "conversation peer", h.ok(alice, "GET", "/v1/conversations/"+conversation["conversationId"].(string))["peer"].(map[string]any), avatars[bob])
	for _, c := range some(items(h.ok(alice, "GET", "/v1/conversations"))) {
		who := c["peer"].(map[string]any)
		wantAvatar(t, "conversation list peer", who, avatars[who["userId"].(string)])
	}

	// Spaces: the host and the member lists and entries.
	space := makeSpace(h, alice, "community", "public", 10, nil)
	h.expect(h.send(bob, "PUT", "/v1/spaces/"+space+"/membership", map[string]string{}), 200, "")
	h.expect(h.send(bob, "POST", "/v1/spaces/"+space+"/entries", map[string]string{"body": "hi all"}), 201, "")
	wantAvatar(t, "space owner", h.ok(bob, "GET", "/v1/spaces/"+space)["owner"].(map[string]any), avatars[alice])
	members := items(h.ok(bob, "GET", "/v1/spaces/"+space+"/members"))
	if len(members) != 2 {
		t.Fatalf("members %v", members)
	}
	for _, m := range members {
		who := m["user"].(map[string]any)
		wantAvatar(t, "space member", who, avatars[who["userId"].(string)])
	}
	for _, e := range some(items(h.ok(alice, "GET", "/v1/spaces/"+space+"/entries"))) {
		wantAvatar(t, "space entry author", e["author"].(map[string]any), avatars[bob])
	}
	for _, s := range some(items(h.ok(bob, "GET", "/v1/spaces?kind=community"))) {
		wantAvatar(t, "space list owner", s["owner"].(map[string]any), avatars[alice])
	}

	// Safety lists.
	h.expect(h.send(alice, "POST", "/v1/users/"+bob+"/mute", map[string]any{}), 200, "")
	h.ok(alice, "POST", "/v1/users/"+cara+"/block")
	for _, kind := range []string{"muted", "blocked"} {
		for _, row := range some(items(h.ok(alice, "GET", "/v1/me/"+kind))) {
			who := row["user"].(map[string]any)
			wantAvatar(t, kind+" list", who, avatars[who["userId"].(string)])
		}
	}
	if len(items(h.ok(alice, "GET", "/v1/me/blocked"))) != 1 {
		t.Fatal("blocked list")
	}
}

func TestAvatarUrlIsNullWithoutStorage(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	id := h.upload(store, alice, "avatar", avatarPhoto(t))
	h.expect(h.setAvatar(alice, id), 200, "")
	h.post(alice, "public", "hello")
	h.api.Media = nil

	// Storage is not configured: everything renders, with no URLs, and uploads answer 503.
	own := h.ok(alice, "GET", "/v1/me/profile")
	if own["avatarMediaId"] != id || own["avatarUrl"] != nil || own["avatarFullUrl"] != nil {
		t.Fatalf("own profile %v", own)
	}
	visit := h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	wantAvatar(t, "public profile", visit, "")
	if v, ok := visit["avatarFullUrl"]; !ok || v != nil {
		t.Fatalf("avatarFullUrl %v", visit)
	}
	h.api.search.reset(bob)
	for _, item := range items(h.expect(h.send(bob, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data) {
		wantAvatar(t, "search row", item, "")
	}
	for _, p := range items(h.ok(bob, "GET", "/v1/feed?mode=everyone")) {
		wantAvatar(t, "post author", p["author"].(map[string]any), "")
	}
	h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "avatar", "contentType": "image/jpeg", "sizeBytes": 10}), 503, "MEDIA_UNAVAILABLE")
	// Clearing the avatar needs no storage.
	h.expect(h.setAvatar(alice, nil), 200, "")
}

// Deleting avatar media, or a profile that points at media it does not own, never breaks anyone's profile.
func TestAvatarMediaGoneDoesNotBreakRendering(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := avatarPhoto(t)
	mine := h.upload(store, alice, "avatar", pic)
	h.expect(h.setAvatar(alice, mine), 200, "")
	theirs := h.upload(store, bob, "avatar", pic)
	h.expect(h.setAvatar(bob, theirs), 200, "")
	post := h.post(alice, "public", "hello")

	check := func(want string) {
		t.Helper()
		wantAvatar(t, "own profile", h.ok(alice, "GET", "/v1/me/profile"), want)
		wantAvatar(t, "public profile", h.ok(bob, "GET", "/v1/users/"+alice+"/profile"), want)
		wantAvatar(t, "post author", h.ok(bob, "GET", "/v1/posts/"+post)["author"].(map[string]any), want)
		h.api.search.reset(bob)
		for _, item := range items(h.expect(h.send(bob, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data) {
			if item["userId"] == alice {
				wantAvatar(t, "search row", item, want)
			}
		}
	}
	check(mine)

	// Deleted, and then purged by the cleanup: the person simply has no photo.
	h.exec(`UPDATE media_assets SET status='deleted',deleted_at=now() WHERE media_id=$1`, mine)
	check("")
	if keys, _, err := h.db.MediaGarbage(h.ctx, 100); err != nil || len(keys) == 0 {
		t.Fatalf("cleanup %v %v", keys, err)
	}
	check("")
	// A new photo can be set over a deleted one.
	next := h.upload(store, alice, "avatar", pic)
	h.expect(h.setAvatar(alice, next), 200, "")
	check(next)

	// An id in the profile that names another member's photo, or a row that is not an avatar, shows nothing.
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{avatarMediaId}',to_jsonb($2::text)) WHERE user_id=$1`, alice, theirs)
	check("")
	postPhoto := h.upload(store, alice, "post", pic)
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{avatarMediaId}',to_jsonb($2::text)) WHERE user_id=$1`, alice, postPhoto)
	check("")
	// And clearing from that state works: the stale id is not released as an avatar, and the post photo survives.
	h.expect(h.setAvatar(alice, nil), 200, "")
	if status, _ := h.avatarState(postPhoto); status != "ready" {
		t.Fatalf("clearing released a post photo: %s", status)
	}
}

// People who cannot see each other never get each other's photo, in any response.
func TestAvatarDoesNotLeakAcrossBlocksAndAgeBands(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := avatarPhoto(t)
	avatars := map[string]string{}
	for _, user := range []string{alice, bob, cara, dev} {
		avatars[user] = h.upload(store, user, "avatar", pic)
		h.expect(h.setAvatar(user, avatars[user]), 200, "")
	}
	h.policy(alice, "commentsFrom", "everyone")
	post := h.post(bob, "public", "from bob")
	h.expect(h.send(bob, "POST", "/v1/posts/"+post+"/comments", map[string]any{"body": "hello"}), 201, "")
	h.ok(alice, "POST", "/v1/users/"+bob+"/block")

	// Everything that would carry bob's photo to alice is gone, and so is the reverse.
	for _, pair := range [][2]string{{alice, bob}, {bob, alice}} {
		viewer, target := pair[0], pair[1]
		h.expect(h.call(viewer, "GET", "/v1/users/"+target+"/profile"), 404, "NOT_FOUND")
		h.api.search.reset(viewer)
		for _, item := range items(h.expect(h.send(viewer, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data) {
			if item["userId"] == target {
				t.Fatalf("%s sees %s in search: %v", viewer, target, item)
			}
		}
	}
	h.expect(h.call(alice, "GET", "/v1/posts/"+post), 404, "NOT_FOUND")
	for _, p := range items(h.ok(alice, "GET", "/v1/feed?mode=everyone")) {
		if who := p["author"].(map[string]any); who["userId"] == bob {
			t.Fatalf("blocked author in the feed: %v", who)
		}
	}
	raw := h.expect(h.call(alice, "GET", "/v1/feed?mode=everyone"), 200, "")
	if strings.Contains(fmt.Sprint(raw.data), avatars[bob]) {
		t.Fatalf("bob's photo leaked into the feed: %v", raw.data)
	}

	// Other age band: the same rule.
	h.setAge(alice, 30)
	h.setAge(cara, 15)
	h.expect(h.call(alice, "GET", "/v1/users/"+cara+"/profile"), 404, "NOT_FOUND")
	h.expect(h.call(cara, "GET", "/v1/users/"+alice+"/profile"), 404, "NOT_FOUND")
	h.api.search.reset(alice)
	for _, item := range items(h.expect(h.send(alice, "POST", "/v1/discovery/search", map[string]any{}), 200, "").data) {
		if item["userId"] == cara {
			t.Fatalf("an adult sees a minor in search: %v", item)
		}
	}
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.north(cara, 0.01)
	got, users, _ := h.nearbyList(alice, map[string]any{"radiusKm": 25})
	h.expect(got, 200, "")
	for _, id := range users {
		if id == cara || id == bob {
			t.Fatalf("barred member in nearby: %v", users)
		}
	}
	if strings.Contains(fmt.Sprint(got.data), avatars[cara]) || strings.Contains(fmt.Sprint(got.data), avatars[bob]) {
		t.Fatalf("a barred member's photo leaked into nearby: %v", got.data)
	}
	// Followers, notifications and conversations of the minor are not shown across the band either.
	h.policy(cara, "followPolicy", "everyone")
	h.expect(h.call(alice, "POST", "/v1/users/"+cara+"/follow"), 404, "NOT_FOUND")
	if strings.Contains(fmt.Sprint(h.ok(alice, "GET", "/v1/notifications")), avatars[cara]) {
		t.Fatal("minor's photo in an adult's activity")
	}
}

// The migration widens the media purposes and nothing else.
func TestMigration0022AllowsAvatarMediaPurpose(t *testing.T) {
	ctx, db := connectTestDB(t)
	pulse, err := os.ReadFile("../../../../database/migrations/0010_pulse.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../../../../database/migrations/0022_avatar_media.sql")
	if err != nil {
		t.Fatal(err)
	}
	// The table exactly as 0010 created it.
	start := strings.Index(string(pulse), "CREATE TABLE IF NOT EXISTS media_assets")
	end := start + strings.Index(string(pulse)[start:], ");\n") + 3
	if start < 0 || end < start {
		t.Fatal("media_assets not found in 0010")
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	const owner, a, b = "019a4000-0000-7000-8000-000000000f01", "019a4000-0000-7000-8000-000000000f11", "019a4000-0000-7000-8000-000000000f12"
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_22`,
		`SET LOCAL search_path = migration_scratch_22`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`INSERT INTO users VALUES ('` + owner + `')`,
		string(pulse)[start:end],
		`INSERT INTO media_assets(media_id,owner_id,purpose,content_type,size_bytes,upload_key,expires_at) VALUES ('` + a + `','` + owner + `','post','image/jpeg',1,'k1',now())`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	insert := `INSERT INTO media_assets(media_id,owner_id,purpose,content_type,size_bytes,upload_key,expires_at) VALUES ('` + b + `','` + owner + `','avatar','image/jpeg',1,'k2',now())`
	if _, err = tx.Exec(ctx, `SAVEPOINT s; `+insert); err == nil {
		t.Fatal("0010 already accepts avatar")
	}
	if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	for run := 0; run < 2; run++ { // applying it again changes nothing
		if _, err = tx.Exec(ctx, string(migration)); err != nil {
			t.Fatalf("migration run %d: %v", run+1, err)
		}
	}
	if _, err = tx.Exec(ctx, insert); err != nil {
		t.Fatalf("avatar purpose refused: %v", err)
	}
	for _, purpose := range []string{"banner", "", "Avatar"} {
		if _, err = tx.Exec(ctx, `SAVEPOINT s; INSERT INTO media_assets(media_id,owner_id,purpose,content_type,size_bytes,upload_key,expires_at) VALUES (gen_random_uuid(),'`+owner+`','`+purpose+`','image/jpeg',1,'k3',now())`); err == nil {
			t.Fatalf("purpose %q accepted", purpose)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
	}
	var purposes, constraints int
	if err = tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE purpose IN ('post','avatar')),(SELECT count(*) FROM pg_constraint WHERE conrelid='media_assets'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%purpose%') FROM media_assets`).Scan(&purposes, &constraints); err != nil || purposes != 2 || constraints != 1 {
		t.Fatalf("rows %d purpose constraints %d (%v)", purposes, constraints, err)
	}
	// The status constraint and the primary key are untouched.
	if _, err = tx.Exec(ctx, `SAVEPOINT s; UPDATE media_assets SET status='gone'`); err == nil {
		t.Fatal("status constraint lost")
	}
	if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	// The real database already has it applied, and the stored profile shape is unchanged.
	var applied bool
	if err = db.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0022_avatar_media.sql')`).Scan(&applied); err != nil || !applied {
		t.Fatalf("0022 not applied to the test database: %v", err)
	}
}
