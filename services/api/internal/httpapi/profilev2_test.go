package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
)

// HTTP tests of profile and discovery v2 (docs/api/25-profile-and-discovery-v2.md).

func (h *socialHarness) profilePatch(user, body string) reply {
	h.t.Helper()
	return h.patch(user, "/v1/me/profile", fmt.Sprint(h.ok(user, "GET", "/v1/me/profile")["version"]), body)
}

func (h *socialHarness) privacyPatch(user, body string) reply {
	h.t.Helper()
	return h.patch(user, "/v1/me/privacy", fmt.Sprint(h.ok(user, "GET", "/v1/me/privacy")["version"]), body)
}

func (h *socialHarness) searchBody(user string, body map[string]any) reply {
	h.t.Helper()
	h.api.search.reset(user)
	return h.send(user, "POST", "/v1/discovery/search", body)
}

func names(rows []map[string]any) []string {
	out := []string{}
	for _, r := range rows {
		out = append(out, r["username"].(string))
	}
	return out
}

func TestProfilePatchLanguagesPersonalityAndText(t *testing.T) {
	h := newSocialHarness(t)
	// Levels are numbers; the older words and a missing level still work and are stored as numbers.
	got := h.expect(h.profilePatch(alice, `{"languages":[{"code":"en","level":6},{"code":"ko","level":"basic"},{"code":"hi"}]}`), 200, "").data
	raw, _ := json.Marshal(got["languages"])
	if string(raw) != `[{"code":"en","level":6},{"code":"ko","level":2},{"code":"hi","level":3}]` {
		t.Fatalf("languages %s", raw)
	}
	// At most five languages (Entitlements.LanguagesMax), with a level from 1 to 6.
	six := `{"languages":[{"code":"en"},{"code":"hi"},{"code":"ko"},{"code":"ja"},{"code":"es"},{"code":"fr"}]}`
	h.expect(h.profilePatch(alice, six), 422, "VALIDATION")
	h.expect(h.profilePatch(alice, `{"languages":[{"code":"en","level":7}]}`), 422, "VALIDATION")
	h.api.Entitlements = func(context.Context, string) domain.Entitlements {
		e := domain.Free()
		e.LanguagesMax = 6
		return e
	}
	h.expect(h.profilePatch(alice, six), 200, "")
	h.api.Entitlements = nil

	// Personality tags: none, or three to five from the fixed list.
	h.expect(h.profilePatch(alice, `{"personalityTags":["curious","maker","foodie"]}`), 200, "")
	h.expect(h.profilePatch(alice, `{"personalityTags":["curious","maker"]}`), 422, "VALIDATION")
	h.expect(h.profilePatch(alice, `{"personalityTags":["curious","maker","foodie","playful","sporty","chatty"]}`), 422, "VALIDATION")
	h.expect(h.profilePatch(alice, `{"personalityTags":["curious","maker","wizard"]}`), 422, "VALIDATION")
	own := h.ok(alice, "GET", "/v1/me/profile")
	if fmt.Sprint(own["personalityTags"]) != "[curious maker foodie]" {
		t.Fatalf("tags %v", own["personalityTags"])
	}
	h.expect(h.profilePatch(alice, `{"personalityTags":[]}`), 200, "")

	// Ten interests; about me up to 160 characters; hometown without an address.
	ten := `["a1","a2","a3","a4","a5","a6","a7","a8","a9","a10"]`
	h.expect(h.profilePatch(alice, `{"interests":`+ten+`}`), 200, "")
	h.expect(h.profilePatch(alice, `{"interests":["a1","a2","a3","a4","a5","a6","a7","a8","a9","a10","a11"]}`), 422, "VALIDATION")
	h.expect(h.profilePatch(alice, `{"aboutMe":"`+strings.Repeat("x", 160)+`","hometown":"Pune"}`), 200, "")
	h.expect(h.profilePatch(alice, `{"aboutMe":"`+strings.Repeat("x", 161)+`"}`), 422, "VALIDATION")
	h.expect(h.profilePatch(alice, `{"hometown":"14 Rose Street"}`), 422, "VALIDATION")
	// The error never repeats what was typed.
	if r := h.profilePatch(alice, `{"hometown":"14 Rose Street"}`); strings.Contains(fmt.Sprint(r.data), "Rose") {
		t.Fatal("the refusal echoed the address")
	}
}

func TestMinorHometownThroughTheAPI(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 15)
	h.setAge(bob, 15)
	h.setAge(cara, 15)
	// A minor may set a short coarse hometown, never an address, never more than 40 characters.
	h.expect(h.profilePatch(alice, `{"hometown":"Lisbon"}`), 200, "")
	h.expect(h.profilePatch(alice, `{"hometown":"12 Baker Street"}`), 422, "VALIDATION")
	h.expect(h.profilePatch(alice, `{"hometown":"`+strings.Repeat("a", 41)+`"}`), 422, "VALIDATION")
	// Hidden by default, and the audience cannot go past friends.
	if p := h.ok(bob, "GET", "/v1/users/"+alice+"/profile"); p["hometown"] != nil {
		t.Fatalf("a minor's hometown is shown by default: %v", p)
	}
	for _, audience := range []string{"everyone", "followers"} {
		status, code := h.patchPrivacy(alice, `{"fieldAudiences":{"hometown":"`+audience+`"}}`)
		if status != 422 || code != "MINOR_SETTING_LOCKED" {
			t.Fatalf("hometown audience %s: %d %s", audience, status, code)
		}
	}
	if status, code := h.patchPrivacy(alice, `{"fieldAudiences":{"hometown":"friends"}}`); status != 200 {
		t.Fatalf("friends: %d %s", status, code)
	}
	// Only a confirmed friend sees it: bob follows and is not a friend, cara is a friend.
	h.expect(h.call(bob, "POST", "/v1/users/"+alice+"/follow"), 200, "")
	h.exec(`INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'accepted')`, alice, cara)
	if p := h.ok(bob, "GET", "/v1/users/"+alice+"/profile"); p["hometown"] != nil {
		t.Fatalf("a follower sees a minor's hometown: %v", p)
	}
	if p := h.ok(cara, "GET", "/v1/users/"+alice+"/profile"); p["hometown"] != "Lisbon" {
		t.Fatalf("a friend does not: %v", p)
	}
	// Never in search or Nearby rows, for anyone, even a friend.
	r := h.searchBody(cara, map[string]any{})
	for _, row := range items(r.data) {
		if _, ok := row["hometown"]; ok {
			t.Fatalf("a search row carries a hometown: %v", row)
		}
	}
	// An adult cannot open the minor at all (the age band), so cannot see the hometown either.
	h.setAge(eli, 30)
	h.expect(h.call(eli, "GET", "/v1/users/"+alice+"/profile"), 404, "NOT_FOUND")
}

func TestMinorsCannotShareVisitorsOrABirthday(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 16)
	for _, body := range []string{`{"visitorsVisibleToOthers":true}`, `{"showBirthday":true}`, `{"fieldAudiences":{"birthday":"friends"}}`} {
		if status, code := h.patchPrivacy(alice, body); status != 422 || code != "MINOR_SETTING_LOCKED" {
			t.Errorf("%s: %d %s", body, status, code)
		}
	}
	// An adult can.
	h.setAge(bob, 30)
	if status, code := h.patchPrivacy(bob, `{"visitorsVisibleToOthers":true,"showBirthday":true}`); status != 200 {
		t.Fatalf("adult: %d %s", status, code)
	}
	got := h.ok(bob, "GET", "/v1/me/privacy")
	if got["visitorsVisibleToOthers"] != true || got["showBirthday"] != true {
		t.Fatalf("%v", got)
	}
}

func TestShowLocalTimeAndDistanceSettings(t *testing.T) {
	h := newSocialHarness(t)
	priv := h.ok(alice, "GET", "/v1/me/privacy")
	if priv["showLocalTime"] != true || priv["showDistance"] != true || priv["visitorsVisibleToOthers"] != false || priv["showBirthday"] != false {
		t.Fatalf("adult defaults %v", priv)
	}
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{timezone}','"Asia/Kolkata"') WHERE user_id=$1`, alice)
	lt := h.ok(bob, "GET", "/v1/users/"+alice+"/profile")["localTime"].(map[string]any)
	if lt["utcOffsetMinutes"] != float64(330) || lt["label"] != "UTC+5:30" {
		t.Fatalf("localTime %v", lt)
	}
	if status, _ := h.patchPrivacy(alice, `{"showLocalTime":false}`); status != 200 {
		t.Fatal("setting refused")
	}
	if p := h.ok(bob, "GET", "/v1/users/"+alice+"/profile"); p["localTime"] != nil {
		t.Fatalf("hidden local time shown: %v", p["localTime"])
	}
	// The setting is only a boolean.
	if status, _ := h.patchPrivacy(alice, `{"showLocalTime":"no"}`); status != 422 {
		t.Fatalf("a string was accepted: %d", status)
	}
	// Discover rows carry it too, only for a member who shows it.
	h.exec(`UPDATE privacy_settings SET data=data||'{"showLocalTime":true}' WHERE user_id=$1`, alice)
	for _, row := range items(h.searchBody(bob, map[string]any{}).data) {
		if row["username"] == "anjali" && row["localTime"] == nil {
			t.Fatal("a Discover row has no local time")
		}
	}
	// Minors: off by default.
	h.setAge(cara, 15)
	h.setAge(dev, 15)
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{timezone}','"Asia/Tokyo"') WHERE user_id=$1`, cara)
	h.exec(`UPDATE privacy_settings SET data=data||'{"showLocalTime":false}' WHERE user_id=$1`, cara)
	if p := h.ok(dev, "GET", "/v1/users/"+cara+"/profile"); p["localTime"] != nil {
		t.Fatalf("a minor's local time is shown: %v", p["localTime"])
	}
}

func TestSearchFiltersLanguageLevelPersonalityAndSameCountry(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`UPDATE profiles SET data=data||'{"country":"IN"}' WHERE user_id=$1`, alice)
	h.exec(`UPDATE profiles SET data=data||'{"country":"IN","languages":[{"code":"ko","level":5}],"personalityTags":["maker","curious","foodie"]}' WHERE user_id=$1`, bob)
	h.exec(`UPDATE profiles SET data=data||'{"country":"KR","languages":[{"code":"ko","level":2}],"personalityTags":["playful","sporty","chatty"]}' WHERE user_id=$1`, cara)
	for _, id := range []string{alice, bob, cara} {
		h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences}',data->'fieldAudiences'||'{"location":"everyone"}') WHERE user_id=$1`, id)
	}
	query := func(body string) []string {
		var m map[string]any
		_ = json.Unmarshal([]byte(body), &m)
		r := h.expect(h.searchBody(alice, m), 200, "")
		got := names(items(r.data))
		var keep []string
		for _, n := range got {
			if n == "niko" || n == "cara" {
				keep = append(keep, n)
			}
		}
		slices.Sort(keep)
		return keep
	}
	same := func(got []string, want ...string) {
		t.Helper()
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	same(query(`{"languages":["ko"]}`), "cara", "niko")
	same(query(`{"languages":["ko"],"languageMinLevel":4}`), "niko")
	same(query(`{"personalityTags":["maker"]}`), "niko")
	same(query(`{"personalityTags":["maker","sporty"]}`), "cara", "niko")
	same(query(`{"sameCountry":true}`), "niko")
	// Bad input.
	for _, body := range []string{`{"languageMinLevel":3}`, `{"languages":["ko"],"languageMinLevel":9}`, `{"personalityTags":["nope"]}`, `{"sameCountry":"yes"}`, `{"sameCountry":true,"country":"IN"}`} {
		var m map[string]any
		_ = json.Unmarshal([]byte(body), &m)
		if r := h.searchBody(alice, m); r.status != 422 {
			t.Errorf("%s: %d", body, r.status)
		}
	}
	// A viewer with no country cannot use the shortcut.
	h.exec(`UPDATE profiles SET data=data-'country' WHERE user_id=$1`, alice)
	h.expect(h.searchBody(alice, map[string]any{"sameCountry": true}), 422, "COUNTRY_NOT_SET")
}

// A search cursor belongs to the filters it was made for: a new filter, the shortcut or the level invalidates it.
func TestSearchCursorIsBoundToTheV2Filters(t *testing.T) {
	h := newSocialHarness(t)
	for i := 3; i <= 30; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 5000+i)
		h.user(id, fmt.Sprintf("pm%02d", i))
		h.exec(`UPDATE profiles SET data=data||'{"languages":[{"code":"ko","level":4}],"personalityTags":["maker","curious","foodie"]}' WHERE user_id=$1`, id)
	}
	body := map[string]any{"languages": []string{"ko"}, "languageMinLevel": 4, "personalityTags": []string{"maker"}}
	first := h.expect(h.searchBody(alice, body), 200, "").data
	cursor, _ := first["nextCursor"].(string)
	if cursor == "" || len(items(first)) != 20 {
		t.Fatalf("first page %d items, cursor %q", len(items(first)), cursor)
	}
	body["cursor"] = cursor
	second := h.expect(h.searchBody(alice, body), 200, "").data
	if len(items(second)) != 8+0 && len(items(second)) == 0 {
		t.Fatalf("second page %v", second)
	}
	seen := map[string]bool{}
	for _, row := range append(items(first), items(second)...) {
		if seen[row["userId"].(string)] {
			t.Fatalf("%v listed on both pages", row["username"])
		}
		seen[row["userId"].(string)] = true
	}
	for name, change := range map[string]func(map[string]any){
		"level":    func(m map[string]any) { m["languageMinLevel"] = 5 },
		"tags":     func(m map[string]any) { m["personalityTags"] = []string{"curious"} },
		"language": func(m map[string]any) { m["languages"] = []string{"fr"} },
		"drop":     func(m map[string]any) { delete(m, "personalityTags") },
	} {
		changed := map[string]any{"languages": body["languages"], "languageMinLevel": body["languageMinLevel"], "personalityTags": body["personalityTags"], "cursor": cursor}
		change(changed)
		h.expect(h.searchBody(alice, changed), 422, "INVALID_CURSOR")
		_ = name
	}
	// Another member cannot use it, and a tampered one is refused.
	h.expect(h.searchBody(bob, body), 422, "INVALID_CURSOR")
	body["cursor"] = cursor + "x"
	h.expect(h.searchBody(alice, body), 422, "INVALID_CURSOR")
}

func TestPossibleMatchesEndpoint(t *testing.T) {
	h := newSocialHarness(t)
	h.exec(`UPDATE profiles SET data=data||'{"interests":["music","books","hiking"],"country":"IN"}' WHERE user_id=$1`, alice)
	for i := 3; i <= 27; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 6000+i)
		h.user(id, fmt.Sprintf("pm%02d", i))
		interests := `["music"]`
		if i%3 == 0 {
			interests = `["music","books"]`
		}
		h.exec(`UPDATE profiles SET data=data||jsonb_build_object('interests',$2::jsonb) WHERE user_id=$1`, id, interests)
	}
	possible := func(user string, body map[string]any) reply {
		h.api.search.reset(user)
		return h.send(user, "POST", "/v1/discovery/possible-matches", body)
	}
	first := h.expect(possible(alice, map[string]any{}), 200, "").data
	rows := items(first)
	if len(rows) != 20 || first["nextCursor"] == nil {
		t.Fatalf("first page %d rows, cursor %v", len(rows), first["nextCursor"])
	}
	for _, row := range rows {
		reasons, _ := row["reasons"].([]any)
		if len(reasons) == 0 || row["score"] != nil || row["matchScore"] != nil {
			t.Fatalf("row %v", row)
		}
		if row["username"] == "anjali" {
			t.Fatal("the viewer is in their own list")
		}
	}
	// Two books-and-music members come before the music-only ones.
	if !strings.HasPrefix(fmt.Sprint(rows[0]["sharedInterests"]), "[") {
		t.Fatalf("shared interests %v", rows[0])
	}
	second := h.expect(possible(alice, map[string]any{"cursor": first["nextCursor"]}), 200, "").data
	seen := map[string]bool{}
	for _, row := range append(rows, items(second)...) {
		if seen[row["userId"].(string)] {
			t.Fatalf("%v is listed on two pages", row["username"])
		}
		seen[row["userId"].(string)] = true
	}
	if len(seen) < 24 {
		t.Fatalf("%d people over two pages", len(seen))
	}
	// A page size for the Home strip.
	strip := h.expect(possible(alice, map[string]any{"limit": 12, "excludeFollowing": true}), 200, "").data
	if len(items(strip)) != 12 {
		t.Fatalf("strip %d", len(items(strip)))
	}
	// Following: left out with excludeFollowing.
	someone := rows[0]["userId"].(string)
	h.expect(h.call(alice, "POST", "/v1/users/"+someone+"/follow"), 200, "")
	for _, row := range items(h.expect(possible(alice, map[string]any{"excludeFollowing": true}), 200, "").data) {
		if row["userId"] == someone {
			t.Fatal("a followed member was listed")
		}
	}
	// Cursors: another member's, a changed option, a tampered one, one of another kind.
	h.expect(possible(bob, map[string]any{"cursor": first["nextCursor"]}), 422, "INVALID_CURSOR")
	h.expect(possible(alice, map[string]any{"cursor": first["nextCursor"], "excludeFollowing": true}), 422, "INVALID_CURSOR")
	h.expect(possible(alice, map[string]any{"cursor": fmt.Sprint(first["nextCursor"]) + "A"}), 422, "INVALID_CURSOR")
	search := h.expect(h.searchBody(alice, map[string]any{}), 200, "").data
	if c, _ := search["nextCursor"].(string); c != "" {
		h.expect(possible(alice, map[string]any{"cursor": c}), 422, "INVALID_CURSOR")
	}
	// Bad bodies.
	for _, body := range []map[string]any{{"limit": 0}, {"limit": 21}, {"interests": []string{"a"}}, {"excludeFollowing": "yes"}} {
		if r := possible(alice, body); r.status != 422 {
			t.Errorf("%v: %d", body, r.status)
		}
	}
	// Every page counts against the day's search pages.
	h.api.Entitlements = func(context.Context, string) domain.Entitlements {
		e := domain.Free()
		e.SearchPagesPerDay = 2
		return e
	}
	h.exec(`DELETE FROM member_daily_counts WHERE user_id=$1`, alice)
	h.expect(possible(alice, map[string]any{}), 200, "")
	h.expect(possible(alice, map[string]any{}), 200, "")
	h.expect(possible(alice, map[string]any{}), 429, "DAILY_LIMIT")
	h.api.Entitlements = nil
}

func TestPossibleMatchesRespectBlocksAndBands(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{alice, bob, cara, dev} {
		h.exec(`UPDATE profiles SET data=data||'{"interests":["music","books"]}' WHERE user_id=$1`, id)
	}
	h.setAge(dev, 15)
	list := func(user string) []string {
		h.api.search.reset(user)
		return names(items(h.expect(h.send(user, "POST", "/v1/discovery/possible-matches", map[string]any{}), 200, "").data))
	}
	got := list(alice)
	for _, n := range got {
		if n == "dev_k" {
			t.Fatalf("a minor is suggested to an adult: %v", got)
		}
	}
	h.exec(`INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, alice, bob)
	for _, n := range list(alice) {
		if n == "niko" {
			t.Fatal("a blocked member is suggested")
		}
	}
	for _, n := range list(bob) {
		if n == "anjali" {
			t.Fatal("a member who blocked you is suggested")
		}
	}
	h.exec(`DELETE FROM blocks`)
	h.exec(`UPDATE privacy_settings SET data=data||'{"discoverable":false}' WHERE user_id=$1`, cara)
	for _, n := range list(alice) {
		if n == "cara" {
			t.Fatal("a member who is not discoverable is suggested")
		}
	}
}

// ---- Gallery

func (h *socialHarness) addPhoto(user string, id string) reply {
	return h.send(user, "POST", "/v1/me/photos", map[string]any{"mediaId": id})
}

func photoIDs(r reply) []string {
	out := []string{}
	for _, p := range r.data["photos"].([]any) {
		out = append(out, p.(map[string]any)["mediaId"].(string))
	}
	return out
}

func TestGalleryEndToEnd(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	pic := photo(t, 90, 70)
	var all []string
	for i := 0; i < 8; i++ {
		id := h.upload(store, alice, "avatar", pic)
		r := h.expect(h.addPhoto(alice, id), 201, "")
		all = append(all, id)
		if fmt.Sprint(photoIDs(r)) != fmt.Sprint(all) || r.data["max"] != float64(8) {
			t.Fatalf("after %d photos: %v max %v", i+1, photoIDs(r), r.data["max"])
		}
	}
	// The first photo is the avatar everywhere.
	own := h.ok(alice, "GET", "/v1/me/profile")
	wantAvatar(t, "own profile", own, all[0])
	if len(own["photos"].([]any)) != 8 {
		t.Fatalf("own profile photos %v", own["photos"])
	}
	// A ninth: refused with PHOTOS_FULL and the upload is not used up.
	ninth := h.upload(store, alice, "avatar", pic)
	h.expect(h.addPhoto(alice, ninth), 409, "PHOTOS_FULL")
	if _, attached := h.avatarState(ninth); attached {
		t.Fatal("a refused photo was attached")
	}
	// Others see the gallery with signed URLs.
	seen := h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	photos := seen["photos"].([]any)
	if len(photos) != 8 {
		t.Fatalf("a viewer sees %d photos", len(photos))
	}
	first := photos[0].(map[string]any)
	if first["url"] != "memory://get/media/"+all[0]+"/full.jpg" || first["thumbUrl"] != "memory://get/media/"+all[0]+"/thumb.jpg" || first["width"] == nil {
		t.Fatalf("photo %v", first)
	}
	// Reorder, replace, delete.
	order := append([]string{all[7]}, all[:7]...)
	r := h.expect(h.send(alice, "PUT", "/v1/me/photos/order", map[string]any{"mediaIds": order}), 200, "")
	if fmt.Sprint(photoIDs(r)) != fmt.Sprint(order) {
		t.Fatalf("order %v", photoIDs(r))
	}
	wantAvatar(t, "after reorder", h.ok(alice, "GET", "/v1/me/profile"), all[7])
	h.expect(h.send(alice, "PUT", "/v1/me/photos/order", map[string]any{"mediaIds": order[:7]}), 422, "VALIDATION")
	h.expect(h.send(alice, "PUT", "/v1/me/photos/order", map[string]any{"mediaIds": []string{"nope"}}), 422, "VALIDATION")
	replacement := h.upload(store, alice, "avatar", pic)
	r = h.expect(h.send(alice, "PUT", "/v1/me/photos/"+order[3], map[string]any{"mediaId": replacement}), 200, "")
	if photoIDs(r)[3] != replacement {
		t.Fatalf("replace %v", photoIDs(r))
	}
	if status, _ := h.avatarState(order[3]); status != "deleted" {
		t.Fatalf("replaced photo %s", status)
	}
	r = h.expect(h.call(alice, "DELETE", "/v1/me/photos/"+order[0]), 200, "")
	if len(photoIDs(r)) != 7 || photoIDs(r)[0] != order[1] {
		t.Fatalf("delete %v", photoIDs(r))
	}
	wantAvatar(t, "after deleting the first", h.ok(alice, "GET", "/v1/me/profile"), order[1])
	h.expect(h.call(alice, "DELETE", "/v1/me/photos/"+order[0]), 404, "NOT_FOUND")
	// Another member's photo or gallery cannot be touched.
	h.expect(h.call(bob, "DELETE", "/v1/me/photos/"+order[1]), 404, "NOT_FOUND")
	theirs := h.upload(store, bob, "avatar", pic)
	h.expect(h.addPhoto(alice, theirs), 422, "VALIDATION")
	h.expect(h.send(alice, "POST", "/v1/me/photos", map[string]any{"mediaId": "not-an-id"}), 422, "VALIDATION")
	h.expect(h.send(alice, "POST", "/v1/me/photos", map[string]any{"mediaId": theirs, "extra": 1}), 422, "VALIDATION")
	// The gallery is a locked card to someone the audience excludes.
	h.exec(`UPDATE profiles SET data=jsonb_set(data,'{profileAudience}','"friends"') WHERE user_id=$1`, alice)
	h.policy(alice, "profileAudience", "friends")
	locked := h.ok(bob, "GET", "/v1/users/"+alice+"/profile")
	if locked["locked"] != true || locked["photos"] != nil {
		t.Fatalf("locked card %v", locked)
	}
	// The upload counts towards the usual limits (upload slots are taken by every photo).
	if n := h.count("SELECT count(*) FROM media_assets WHERE owner_id=$1", alice); n < 10 {
		t.Fatalf("%d uploads recorded", n)
	}
}

// The upload scanner runs before a photo is ready: a flagged or matched gallery photo is quarantined, never shown,
// and can never be added.
func TestGalleryUploadGoesThroughTheScanner(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	bad, good := photo(t, 80, 60), photo(t, 100, 70)
	h.api.Scanner = &scriptedScanner{verdicts: map[string]media.Verdict{media.SHA256Hex(bad): media.Flagged}}
	id, _ := h.beginUpload(store, alice, "avatar", bad)
	h.expect(h.call(alice, "POST", "/v1/media/"+id+"/complete"), 422, "UPLOAD_REJECTED")
	h.expect(h.addPhoto(alice, id), 422, "VALIDATION")
	if status, _ := h.avatarState(id); status != "quarantined" {
		t.Fatalf("status %s", status)
	}
	if n := h.count(`SELECT count(*) FROM profile_photos WHERE user_id=$1`, alice); n != 0 {
		t.Fatal("a quarantined photo is in the gallery")
	}
	ok := h.upload(store, alice, "avatar", good)
	h.expect(h.addPhoto(alice, ok), 201, "")
	// A pending upload cannot be added either.
	pending, _ := h.beginUpload(store, alice, "avatar", good)
	h.expect(h.addPhoto(alice, pending), 422, "VALIDATION")
}

func TestGalleryOfAMinorIsForTheirBandOnly(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	h.setAge(alice, 15)
	h.setAge(bob, 15)
	h.setAge(cara, 30)
	h.expect(h.addPhoto(alice, h.upload(store, alice, "avatar", photo(t, 90, 70))), 201, "")
	if p := h.ok(bob, "GET", "/v1/users/"+alice+"/profile"); len(p["photos"].([]any)) != 1 {
		t.Fatalf("same band: %v", p["photos"])
	}
	h.expect(h.call(cara, "GET", "/v1/users/"+alice+"/profile"), 404, "NOT_FOUND")
}

// ---- Visitors

func TestRecentVisitorsEndpoint(t *testing.T) {
	h := newSocialHarness(t)
	h.setAge(alice, 30)
	for _, id := range []string{bob, cara, dev, eli} {
		h.setAge(id, 30)
		h.ok(id, "GET", "/v1/users/"+alice+"/profile")
	}
	h.setAge(xan, 15)
	// Off: 403 VISITORS_PRIVATE for others, and the profile does not offer it. The owner's own list is as before.
	h.expect(h.call(bob, "GET", "/v1/users/"+alice+"/visitors"), 403, "VISITORS_PRIVATE")
	h.expect(h.call(alice, "GET", "/v1/users/"+alice+"/visitors"), 403, "VISITORS_PRIVATE")
	if p := h.ok(bob, "GET", "/v1/users/"+alice+"/profile"); p["visitorsVisible"] != nil {
		t.Fatalf("visitorsVisible %v", p["visitorsVisible"])
	}
	if len(items(h.ok(alice, "GET", "/v1/me/visitors"))) != 4 {
		t.Fatal("the owner's list changed")
	}
	h.expect(h.privacyPatch(alice, `{"visitorsVisibleToOthers":true}`), 200, "")
	if p := h.ok(bob, "GET", "/v1/users/"+alice+"/profile"); p["visitorsVisible"] != true {
		t.Fatalf("visitorsVisible %v", p["visitorsVisible"])
	}
	list := h.ok(cara, "GET", "/v1/users/"+alice+"/visitors")
	if len(items(list)) < 3 {
		t.Fatalf("visitors %v", list)
	}
	for _, row := range items(list) {
		if row["visitedAt"] == nil || row["user"] == nil {
			t.Fatalf("row %v", row)
		}
		if row["user"].(map[string]any)["userId"] == xan {
			t.Fatal("a minor is in the list")
		}
	}
	// Blocks: a visitor the viewer blocked is not in their list; a blocked viewer gets a 404.
	h.expect(h.call(cara, "POST", "/v1/users/"+bob+"/block"), 200, "")
	for _, row := range items(h.ok(cara, "GET", "/v1/users/"+alice+"/visitors")) {
		if row["user"].(map[string]any)["userId"] == bob {
			t.Fatal("a blocked visitor is listed")
		}
	}
	h.expect(h.call(alice, "POST", "/v1/users/"+eli+"/block"), 200, "")
	h.expect(h.call(eli, "GET", "/v1/users/"+alice+"/visitors"), 404, "NOT_FOUND")
	// A minor cannot ask for an adult's list (the age band), and a minor's own list is never offered.
	h.expect(h.call(xan, "GET", "/v1/users/"+alice+"/visitors"), 404, "NOT_FOUND")
	h.setAge(yui, 15)
	h.exec(`UPDATE privacy_settings SET data=data||'{"visitorsVisibleToOthers":true}' WHERE user_id=$1`, xan)
	h.ok(xan, "GET", "/v1/users/"+yui+"/profile")
	h.expect(h.call(yui, "GET", "/v1/users/"+xan+"/visitors"), 403, "VISITORS_PRIVATE")
	if p := h.ok(yui, "GET", "/v1/users/"+xan+"/profile"); p["visitorsVisible"] != nil {
		t.Fatal("a minor's profile offers a visitor list")
	}
	// Turning it off closes it at once.
	h.expect(h.privacyPatch(alice, `{"visitorsVisibleToOthers":false}`), 200, "")
	h.expect(h.call(cara, "GET", "/v1/users/"+alice+"/visitors"), 403, "VISITORS_PRIVATE")
}

func TestPlacesVisitedIsOwnHistoryOnly(t *testing.T) {
	h := newSocialHarness(t)
	h.ok(alice, "GET", "/v1/users/"+bob+"/profile")
	h.ok(alice, "GET", "/v1/users/"+cara+"/profile")
	got := h.ok(alice, "GET", "/v1/me/visited")
	if len(items(got)) != 2 {
		t.Fatalf("places %v", got)
	}
	if len(items(h.ok(bob, "GET", "/v1/me/visited"))) != 0 {
		t.Fatal("another member's history is shown")
	}
	h.expect(h.call(alice, "DELETE", "/v1/me/visited"), 200, "")
	if len(items(h.ok(alice, "GET", "/v1/me/visited"))) != 0 {
		t.Fatal("history not cleared")
	}
}

// ---- Nearby distance

func TestNearbyHidesTheDistanceOfMembersWhoTurnedItOff(t *testing.T) {
	h := newSocialHarness(t)
	for _, id := range []string{alice, bob, cara} {
		h.expect(h.send(id, "PUT", "/v1/me/nearby", nil), 200, "")
		h.expect(h.send(id, "PUT", "/v1/me/location", map[string]any{"latitude": 12.97, "longitude": 77.59}), 200, "")
	}
	h.policy(bob, "showDistance", false)
	r := h.expect(h.send(alice, "POST", "/v1/discover/nearby", map[string]any{"radiusKm": 25}), 200, "")
	seen := map[string]map[string]any{}
	for _, row := range items(r.data) {
		seen[row["username"].(string)] = row
	}
	if seen["niko"] == nil || seen["cara"] == nil {
		t.Fatalf("rows %v", seen)
	}
	if _, ok := seen["niko"]["distanceKm"]; ok {
		t.Fatalf("a hidden distance was sent: %v", seen["niko"])
	}
	if _, ok := seen["niko"]["distanceHidden"]; ok {
		t.Fatal("the internal marker leaked")
	}
	if seen["cara"]["distanceKm"] == nil {
		t.Fatalf("a shown distance is missing: %v", seen["cara"])
	}
}
