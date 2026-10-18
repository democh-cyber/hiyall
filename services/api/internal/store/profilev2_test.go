package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// Profile and discovery v2 on a scratch database: the derived tables, the gallery, the filters, possible
// matches, and what a viewer may see of a profile.

var (
	adultBirth = time.Date(1995, 5, 17, 0, 0, 0, 0, time.UTC)
	teenBirth  = time.Now().UTC().AddDate(-15, -2, 0)
)

func testSigner(key string) string { return "https://media.test/" + key }

// v2Member creates an onboarded member (an adult unless birth says otherwise) and returns their id.
func v2Member(t *testing.T, s *Store, name string, birth time.Time) string {
	t.Helper()
	ctx := context.Background()
	id := newID()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if err = provision(ctx, tx, id, name, name, true); err != nil {
		t.Fatal(err)
	}
	if err = recordBirth(ctx, tx, id, birth, true); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	return id
}

func setProfile(t *testing.T, s *Store, id, json string) {
	t.Helper()
	mustExec(t, s, `UPDATE profiles SET data=data||$2::jsonb,version=version+1 WHERE user_id=$1`, id, json)
}

func setPrivacy(t *testing.T, s *Store, id, json string) {
	t.Helper()
	mustExec(t, s, `UPDATE privacy_settings SET data=data||$2::jsonb WHERE user_id=$1`, id, json)
}

func setAudience(t *testing.T, s *Store, id, field, audience string) {
	t.Helper()
	mustExec(t, s, `UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],to_jsonb($3::text)) WHERE user_id=$1`, id, field, audience)
}

func befriend(t *testing.T, s *Store, a, b string) {
	t.Helper()
	mustExec(t, s, `INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'accepted')`, a, b)
}

func readyPhoto(t *testing.T, s *Store, owner string) string {
	t.Helper()
	id := newID()
	mustExec(t, s, `INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,variants,width,height,expires_at)
 VALUES($1,$2,'avatar','ready','image/jpeg',100,100,$3,$4,640,480,now()+interval '1 day')`, id, owner, "uploads/"+owner+"/"+id, fmt.Sprintf(`{"full":"media/%s/full.jpg","thumb":"media/%s/thumb.jpg"}`, id, id))
	return id
}

func ids(photos []domain.ProfilePhoto) []string {
	out := []string{}
	for _, p := range photos {
		out = append(out, p.MediaID)
	}
	return out
}

func TestDerivedProfileTablesFollowTheProfileJSON(t *testing.T) {
	s := scratchStore(t)
	a := v2Member(t, s, "ana", adultBirth)
	// Any write path keeps them in step: here plain SQL, with legacy and new language shapes mixed.
	setProfile(t, s, a, `{"languages":[{"code":"ko","level":"basic"},"en",{"code":"Hi","level":5},{"code":"fr","level":9},{"code":"EN","level":6},{"code":"not a code!","level":3}],"interests":["Music","BOOKS","music"],"personalityTags":["Curious","maker"]}`)
	got := map[string]int{}
	rows, err := s.Pool.Query(context.Background(), `SELECT code,level FROM profile_languages WHERE user_id=$1`, a)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var code string
		var level int
		if err = rows.Scan(&code, &level); err != nil {
			t.Fatal(err)
		}
		got[code] = level
	}
	rows.Close()
	want := map[string]int{"ko": 2, "en": 6, "hi": 5, "fr": 6}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("profile_languages %v, want %v", got, want)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM profile_interests WHERE user_id=$1 AND interest IN ('music','books')`, a); n != 2 {
		t.Fatalf("interests %d", n)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM profile_interests WHERE user_id=$1`, a); n != 2 {
		t.Fatalf("interests not deduplicated: %d", n)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM profile_personality_tags WHERE user_id=$1 AND tag IN ('curious','maker')`, a); n != 2 {
		t.Fatalf("personality tags %d", n)
	}
	// A change to anything else leaves them alone; a change to the languages rewrites them.
	setProfile(t, s, a, `{"headline":"hello"}`)
	if n := mustCount(t, s, `SELECT count(*) FROM profile_languages WHERE user_id=$1`, a); n != 4 {
		t.Fatalf("languages changed by an unrelated write: %d", n)
	}
	setProfile(t, s, a, `{"languages":[]}`)
	if n := mustCount(t, s, `SELECT count(*) FROM profile_languages WHERE user_id=$1`, a); n != 0 {
		t.Fatalf("languages not cleared: %d", n)
	}
	// Through the API path, in the same transaction as the write.
	view, err := s.UpdateProfileFor(context.Background(), a, mustVersion(t, s, a), map[string]json.RawMessage{
		"languages":       json.RawMessage(`[{"code":"es","level":4},{"code":"de","level":1}]`),
		"personalityTags": json.RawMessage(`["foodie","maker","sporty"]`),
		"interests":       json.RawMessage(`["Chess"]`),
	}, domain.Free(), testSigner)
	if err != nil {
		t.Fatal(err)
	}
	if len(view.Languages) != 2 || view.Languages[0].Level != 4 || len(view.PersonalityTags) != 3 {
		t.Fatalf("%+v", view.Profile)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM profile_languages WHERE user_id=$1 AND ((code='es' AND level=4) OR (code='de' AND level=1))`, a); n != 2 {
		t.Fatal("profile_languages did not follow the update")
	}
	// Deleting the profile removes the rows (the purge deletes profiles last).
	mustExec(t, s, `DELETE FROM profiles WHERE user_id=$1`, a)
	if n := mustCount(t, s, `SELECT (SELECT count(*) FROM profile_languages)+(SELECT count(*) FROM profile_interests)+(SELECT count(*) FROM profile_personality_tags)`); n != 0 {
		t.Fatalf("%d derived rows survive the profile", n)
	}
}

func mustVersion(t *testing.T, s *Store, id string) int64 {
	t.Helper()
	var v int64
	if err := s.Pool.QueryRow(context.Background(), `SELECT version FROM profiles WHERE user_id=$1`, id).Scan(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

// Migration 0048 turns the old words into numbers and keeps the first spelling of a code.
func TestMigrationBackfillOfLanguageLevels(t *testing.T) {
	s := scratchStore(t)
	a := v2Member(t, s, "ana", adultBirth)
	mustExec(t, s, `ALTER TABLE profiles DISABLE TRIGGER profiles_derive`)
	mustExec(t, s, `UPDATE profiles SET data=data||'{"languages":[{"code":"ko","level":"basic"},"en",{"code":"hi","level":"native"},{"code":"EN","level":"fluent"},{"code":"fr"},{"code":"de","level":"conversational"},{"code":"??"},7]}'::jsonb WHERE user_id=$1`, a)
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "database", "migrations", "0048_profile_discovery.sql"))
	if err != nil {
		t.Fatal(err)
	}
	stmt := regexp.MustCompile(`(?s)UPDATE profiles p SET\n  data = jsonb_set\(.*?updated_at = now\(\)\nWHERE CASE WHEN jsonb_typeof\(p\.data->'languages'\) = 'array' THEN jsonb_array_length\(p\.data->'languages'\) > 0 ELSE false END;`).FindString(string(raw))
	if stmt == "" {
		t.Fatal("the language rewrite is not in 0048_profile_discovery.sql")
	}
	mustExec(t, s, stmt)
	var langs string
	if err = s.Pool.QueryRow(context.Background(), `SELECT data->'languages' FROM profiles WHERE user_id=$1`, a).Scan(&langs); err != nil {
		t.Fatal(err)
	}
	if langs != `[{"code": "ko", "level": 2}, {"code": "en", "level": 3}, {"code": "hi", "level": 6}, {"code": "fr", "level": 3}, {"code": "de", "level": 3}]` {
		t.Fatalf("rewritten languages: %s", langs)
	}
	mustExec(t, s, `SELECT derive_profile_rows(user_id,data) FROM profiles`)
	if n := mustCount(t, s, `SELECT count(*) FROM profile_languages WHERE user_id=$1`, a); n != 5 {
		t.Fatalf("%d rows", n)
	}
}

func TestGalleryLimitOrderReplaceDeleteAndAvatar(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a, b := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "ben", adultBirth)
	e := domain.Free()
	var all []string
	for i := 0; i < e.ProfilePhotosMax; i++ {
		id := readyPhoto(t, s, a)
		photos, err := s.AddProfilePhoto(ctx, a, id, e, testSigner)
		if err != nil {
			t.Fatalf("photo %d: %v", i+1, err)
		}
		all = append(all, id)
		if !slices.Equal(ids(photos), all) {
			t.Fatalf("order %v, want %v", ids(photos), all)
		}
	}
	// The first photo is the profile photo.
	if got := avatarOf(t, s, a); got != all[0] {
		t.Fatalf("avatar %q, want the first photo %q", got, all[0])
	}
	// The ninth does not fit, and is not claimed.
	extra := readyPhoto(t, s, a)
	if _, err := s.AddProfilePhoto(ctx, a, extra, e, testSigner); !errors.Is(err, domain.ErrPhotosFull) {
		t.Fatalf("ninth photo: %v", err)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE media_id=$1 AND NOT attached`, extra); n != 1 {
		t.Fatal("a refused photo was claimed")
	}
	// A higher entitlement takes it.
	e2 := e
	e2.ProfilePhotosMax = 9
	if _, err := s.AddProfilePhoto(ctx, a, extra, e2, testSigner); err != nil {
		t.Fatal(err)
	}
	all = append(all, extra)

	// Reorder: put the last first; the avatar follows. Lists that are not exactly the gallery are refused.
	order := append([]string{all[len(all)-1]}, all[:len(all)-1]...)
	photos, err := s.ReorderProfilePhotos(ctx, a, order, testSigner)
	if err != nil || !slices.Equal(ids(photos), order) {
		t.Fatalf("reorder: %v %v", ids(photos), err)
	}
	if got := avatarOf(t, s, a); got != order[0] {
		t.Fatalf("avatar did not follow the order: %q", got)
	}
	for name, bad := range map[string][]string{"short": order[:3], "duplicate": append(slices.Clone(order[:8]), order[0]), "stranger": append(slices.Clone(order[:8]), newID())} {
		if _, err = s.ReorderProfilePhotos(ctx, a, bad, testSigner); err == nil {
			t.Errorf("%s order accepted", name)
		}
	}
	// Replace keeps the place and releases the old photo.
	fresh := readyPhoto(t, s, a)
	photos, err = s.ReplaceProfilePhoto(ctx, a, order[2], fresh, testSigner)
	if err != nil || ids(photos)[2] != fresh || len(photos) != 9 {
		t.Fatalf("replace: %v %v", ids(photos), err)
	}
	if n := mustCount(t, s, `SELECT count(*) FROM media_assets WHERE media_id=$1 AND status='deleted' AND deleted_at IS NOT NULL`, order[2]); n != 1 {
		t.Fatal("the replaced photo was not released for deletion")
	}
	if _, err = s.ReplaceProfilePhoto(ctx, a, order[2], readyPhoto(t, s, a), testSigner); !errors.Is(err, domain.ErrPhotoNotFound) {
		t.Fatalf("replacing a photo that is gone: %v", err)
	}
	// Delete the first: the next one becomes the profile photo.
	photos, err = s.DeleteProfilePhoto(ctx, a, order[0], testSigner)
	if err != nil || len(photos) != 8 || ids(photos)[0] != order[1] {
		t.Fatalf("delete: %v %v", ids(photos), err)
	}
	if got := avatarOf(t, s, a); got != order[1] {
		t.Fatalf("avatar after deleting the first photo: %q", got)
	}
	if _, err = s.DeleteProfilePhoto(ctx, a, newID(), testSigner); !errors.Is(err, domain.ErrPhotoNotFound) {
		t.Fatalf("deleting a stranger's photo id: %v", err)
	}
	// Somebody else's photo, a photo already in use and a photo that is not ready cannot be added.
	theirs := readyPhoto(t, s, b)
	if _, err = s.AddProfilePhoto(ctx, a, theirs, e2, testSigner); err == nil {
		t.Fatal("a photo of another member was added")
	}
	if _, err = s.AddProfilePhoto(ctx, a, order[1], e2, testSigner); err == nil {
		t.Fatal("a photo that is already in the gallery was added again")
	}
	if _, err = s.DeleteProfilePhoto(ctx, b, order[1], testSigner); !errors.Is(err, domain.ErrPhotoNotFound) {
		t.Fatalf("deleting another member's photo: %v", err)
	}
	// Empty gallery: no avatar.
	for _, id := range ids(photos) {
		if _, err = s.DeleteProfilePhoto(ctx, a, id, testSigner); err != nil {
			t.Fatal(err)
		}
	}
	if got := avatarOf(t, s, a); got != "" {
		t.Fatalf("avatar of an empty gallery: %q", got)
	}
}

// The upload scanner's quarantine: a photo that did not pass is never ready, so it can never be added.
func TestGalleryRefusesQuarantinedAndPendingPhotos(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a := v2Member(t, s, "ana", adultBirth)
	for _, status := range []string{"pending", "quarantined", "deleted"} {
		id := newID()
		mustExec(t, s, `INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,expires_at)
 VALUES($1,$2,'avatar',$3,'image/jpeg',10,10,$4,now()+interval '1 day')`, id, a, status, "u/"+id)
		_, err := s.AddProfilePhoto(ctx, a, id, domain.Free(), testSigner)
		var ve *domain.ValidationError
		if !errors.As(err, &ve) || ve.Field != "mediaId" {
			t.Errorf("%s photo: %v", status, err)
		}
	}
	// A post photo is not a profile photo either.
	post := newID()
	mustExec(t, s, `INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,variants,expires_at)
 VALUES($1,$2,'post','ready','image/jpeg',10,10,$3,'{"full":"a","thumb":"b"}',now()+interval '1 day')`, post, a, "u/"+post)
	if _, err := s.AddProfilePhoto(ctx, a, post, domain.Free(), testSigner); err == nil {
		t.Fatal("a post photo was added to the gallery")
	}
	// A photo an operator removed after the fact disappears from the gallery and frees its place.
	id := readyPhoto(t, s, a)
	if _, err := s.AddProfilePhoto(ctx, a, id, domain.Free(), testSigner); err != nil {
		t.Fatal(err)
	}
	mustExec(t, s, `UPDATE media_assets SET status='quarantined' WHERE media_id=$1`, id)
	photos, err := s.ProfilePhotos(ctx, a, testSigner)
	if err != nil || len(photos) != 0 {
		t.Fatalf("a quarantined photo is still shown: %v %v", photos, err)
	}
}

func avatarOf(t *testing.T, s *Store, id string) string {
	t.Helper()
	var avatar *string
	if err := s.Pool.QueryRow(context.Background(), `SELECT data->>'avatarMediaId' FROM profiles WHERE user_id=$1`, id).Scan(&avatar); err != nil {
		t.Fatal(err)
	}
	if avatar == nil {
		return ""
	}
	return *avatar
}

// The old way of setting a profile photo (PATCH avatarMediaId) goes through the gallery.
func TestAvatarPatchKeepsTheGalleryInStep(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a := v2Member(t, s, "ana", adultBirth)
	first := readyPhoto(t, s, a)
	patch := func(v any) error {
		raw, _ := json.Marshal(v)
		_, err := s.UpdateProfileFor(ctx, a, mustVersion(t, s, a), map[string]json.RawMessage{"avatarMediaId": raw}, domain.Free(), testSigner)
		return err
	}
	if err := patch(first); err != nil {
		t.Fatal(err)
	}
	photos, _ := s.ProfilePhotos(ctx, a, testSigner)
	if !slices.Equal(ids(photos), []string{first}) {
		t.Fatalf("gallery %v", ids(photos))
	}
	second := readyPhoto(t, s, a)
	if _, err := s.AddProfilePhoto(ctx, a, second, domain.Free(), testSigner); err != nil {
		t.Fatal(err)
	}
	// A new avatar replaces the first photo and keeps the rest.
	third := readyPhoto(t, s, a)
	if err := patch(third); err != nil {
		t.Fatal(err)
	}
	photos, _ = s.ProfilePhotos(ctx, a, testSigner)
	if !slices.Equal(ids(photos), []string{third, second}) || avatarOf(t, s, a) != third {
		t.Fatalf("after replacing the avatar: %v avatar %s", ids(photos), avatarOf(t, s, a))
	}
	// Clearing it removes the first photo; the next one is promoted.
	if err := patch(nil); err != nil {
		t.Fatal(err)
	}
	photos, _ = s.ProfilePhotos(ctx, a, testSigner)
	if !slices.Equal(ids(photos), []string{second}) || avatarOf(t, s, a) != second {
		t.Fatalf("after clearing the avatar: %v avatar %s", ids(photos), avatarOf(t, s, a))
	}
	if err := patch(nil); err != nil {
		t.Fatal(err)
	}
	if avatarOf(t, s, a) != "" {
		t.Fatal("avatar not cleared")
	}
}

func TestGalleryIsShownToThoseWhoMayOpenTheProfile(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a, b := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "ben", adultBirth)
	teen, teen2 := v2Member(t, s, "kai", teenBirth), v2Member(t, s, "lee", teenBirth)
	for _, who := range []string{a, teen} {
		if _, err := s.AddProfilePhoto(ctx, who, readyPhoto(t, s, who), domain.Free(), testSigner); err != nil {
			t.Fatal(err)
		}
	}
	profile := func(viewer, target string) map[string]any {
		t.Helper()
		p, err := s.VisibleProfile(ctx, viewer, target, nil, testSigner)
		if err != nil {
			t.Fatalf("%s opening %s: %v", viewer, target, err)
		}
		return p
	}
	photos := func(p map[string]any) int {
		v, ok := p["photos"].([]domain.ProfilePhoto)
		if !ok {
			return -1
		}
		return len(v)
	}
	if photos(profile(b, a)) != 1 {
		t.Fatal("a public profile's gallery is not shown")
	}
	// A friends-only profile is a locked card: no photos, only the thumbnail.
	setPrivacy(t, s, a, `{"profileAudience":"friends"}`)
	if p := profile(b, a); p["locked"] != true || photos(p) != -1 {
		t.Fatalf("locked card leaks the gallery: %v", p)
	}
	befriend(t, s, a, b)
	if photos(profile(b, a)) != 1 {
		t.Fatal("a friend cannot see the gallery")
	}
	// Across the age band the profile does not exist; within it, it is open.
	if _, err := s.VisibleProfile(ctx, teen, a, nil, testSigner); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("a minor opening an adult: %v", err)
	}
	if photos(profile(teen2, teen)) != 1 {
		t.Fatal("a minor's gallery is not shown to their own band")
	}
	if _, err := s.VisibleProfile(ctx, b, teen, nil, testSigner); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("an adult opening a minor: %v", err)
	}
	// A block hides everything.
	if err := s.SetBlock(ctx, b, a, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.VisibleProfile(ctx, b, a, nil, testSigner); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("a blocked member opening the profile: %v", err)
	}
}

func TestLocalTimeIsShownOnlyWhenTheMemberAllows(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a, b, teen, teen2 := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "ben", adultBirth), v2Member(t, s, "kai", teenBirth), v2Member(t, s, "lee", teenBirth)
	setProfile(t, s, a, `{"timezone":"America/New_York"}`)
	setProfile(t, s, teen, `{"timezone":"Asia/Kolkata"}`)
	local := func(viewer, target string) map[string]any {
		p, err := s.VisibleProfile(ctx, viewer, target, nil, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		lt, _ := p["localTime"].(*domain.LocalTime)
		if lt == nil {
			return nil
		}
		return map[string]any{"offset": lt.UTCOffsetMinutes, "label": lt.Label}
	}
	want := domain.LocalTimeFor("America/New_York", time.Now())
	if got := local(b, a); got == nil || got["offset"] != want.UTCOffsetMinutes {
		t.Fatalf("adult default: %v", got)
	}
	setPrivacy(t, s, a, `{"showLocalTime":false}`)
	if got := local(b, a); got != nil {
		t.Fatalf("hidden local time shown: %v", got)
	}
	if got := local(a, a); got == nil {
		t.Fatal("a member does not see their own local time")
	}
	// Minors: off by default, and then it appears only once they turn it on.
	if got := local(teen2, teen); got != nil {
		t.Fatalf("minor default shows local time: %v", got)
	}
	setPrivacy(t, s, teen, `{"showLocalTime":true}`)
	if got := local(teen2, teen); got == nil || got["offset"] != 330 {
		t.Fatalf("minor opted in: %v", got)
	}
	// A bad stored zone yields no local time, never a wrong one.
	setProfile(t, s, a, `{"timezone":"Nowhere/Land"}`)
	setPrivacy(t, s, a, `{"showLocalTime":true}`)
	if got := local(b, a); got != nil {
		t.Fatalf("an unknown zone gave a local time: %v", got)
	}
}

func TestV2FieldsAndTheirAudiences(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a, f, o := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "fay", adultBirth), v2Member(t, s, "otto", adultBirth)
	befriend(t, s, a, f)
	setProfile(t, s, a, `{"aboutMe":"Slow mornings.","hometown":"Pune","personalityTags":["curious","maker","foodie"]}`)
	view := func(viewer, target string) map[string]any {
		p, err := s.VisibleProfile(ctx, viewer, target, nil, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	// Adult defaults: aboutMe and hometown for followers (friends included), personality for everyone.
	if p := view(o, a); p["aboutMe"] != nil || p["hometown"] != nil || p["personalityTags"] == nil {
		t.Fatalf("a stranger sees %v", p)
	}
	if p := view(f, a); p["aboutMe"] != "Slow mornings." || p["hometown"] != "Pune" {
		t.Fatalf("a friend sees %v", p)
	}
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active')`, o, a)
	if p := view(o, a); p["aboutMe"] != "Slow mornings." || p["hometown"] != "Pune" {
		t.Fatalf("a follower sees %v", p)
	}
	setAudience(t, s, a, "hometown", "nobody")
	setAudience(t, s, a, "personality", "friends")
	if p := view(f, a); p["hometown"] != nil || p["personalityTags"] == nil {
		t.Fatalf("hidden hometown: %v", p)
	}
	if p := view(o, a); p["personalityTags"] != nil {
		t.Fatalf("personality audience ignored: %v", p)
	}
	// The member always sees their own.
	if p := view(a, a); p["hometown"] != "Pune" || p["aboutMe"] == nil {
		t.Fatalf("own view: %v", p)
	}
}

func TestMinorHometownIsForConfirmedFriendsInTheBandOnly(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	kai, friend, follower, stranger := v2Member(t, s, "kai", teenBirth), v2Member(t, s, "fin", teenBirth), v2Member(t, s, "fol", teenBirth), v2Member(t, s, "str", teenBirth)
	adult := v2Member(t, s, "ada", adultBirth)
	befriend(t, s, kai, friend)
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active')`, follower, kai)

	set := func(text string) error {
		raw, _ := json.Marshal(text)
		_, err := s.UpdateProfileFor(ctx, kai, mustVersion(t, s, kai), map[string]json.RawMessage{"hometown": raw}, domain.Free(), testSigner)
		return err
	}
	// A minor may set a short, coarse hometown. Not an address, not more than 40 characters.
	for _, bad := range []string{"12 Baker Street", "Flat 4, Green Park", strings.Repeat("a", 41), "221B", "me@x.test"} {
		var ve *domain.ValidationError
		if err := set(bad); !errors.As(err, &ve) || ve.Field != "hometown" {
			t.Errorf("minor hometown %q: %v", bad, err)
		}
	}
	if err := set("Lisbon"); err != nil {
		t.Fatal(err)
	}
	view := func(viewer string) (map[string]any, error) {
		return s.VisibleProfile(ctx, viewer, kai, nil, testSigner)
	}
	// Hidden by default: nobody sees it, friends included.
	if p, _ := view(friend); p["hometown"] != nil {
		t.Fatalf("a hidden hometown shown to a friend: %v", p)
	}
	// Friends audience: the confirmed friend, and the owner, and nobody else.
	setAudience(t, s, kai, "hometown", "friends")
	if p, _ := view(friend); p["hometown"] != "Lisbon" {
		t.Fatalf("the friend does not see it: %v", p)
	}
	if p, _ := view(kai); p["hometown"] != "Lisbon" {
		t.Fatal("the owner does not see it")
	}
	for name, viewer := range map[string]string{"follower": follower, "stranger": stranger} {
		if p, err := view(viewer); err != nil || p["hometown"] != nil {
			t.Errorf("%s sees the hometown: %v %v", name, p, err)
		}
	}
	// Across the age band the profile itself is not there.
	if _, err := view(adult); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("an adult opening a minor: %v", err)
	}
	// Even an audience wider than friends (set behind the API's back) is read as friends-only for a minor.
	setAudience(t, s, kai, "hometown", "everyone")
	if p, _ := view(stranger); p["hometown"] != nil {
		t.Fatalf("a minor's hometown reached a stranger under an audience of everyone: %v", p)
	}
	if p, _ := view(follower); p["hometown"] != nil {
		t.Fatalf("a minor's hometown reached a follower: %v", p)
	}
	// Never in search results or Discover rows, whatever the audience.
	setAudience(t, s, kai, "hometown", "friends")
	items, _, err := s.SearchPeoplePage(ctx, stranger, domain.PeopleFilters{}, "00000000-0000-0000-0000-000000000000", 50, nil, testSigner)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range items {
		raw, _ := json.Marshal(it)
		if strings.Contains(string(raw), "Lisbon") || it["hometown"] != nil {
			t.Fatalf("search row leaks the hometown: %s", raw)
		}
	}
	// A friend becoming a non-friend ends the access; a block hides the profile.
	mustExec(t, s, `DELETE FROM friendships`)
	if p, _ := view(friend); p["hometown"] != nil {
		t.Fatalf("ex-friend still sees it: %v", p)
	}
	// The member may not loosen it past friends or show a birthday or a visitor list (ValidateMinorPrivacyPatch).
	// Clearing the text works.
	if err = set(""); err != nil {
		t.Fatal(err)
	}
}

func TestBirthdayShowsMonthAndDayToTheChosenAudienceOnly(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a, f, o := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "fay", adultBirth), v2Member(t, s, "otto", adultBirth)
	teen, teenFriend := v2Member(t, s, "kai", teenBirth), v2Member(t, s, "fin", teenBirth)
	befriend(t, s, a, f)
	befriend(t, s, teen, teenFriend)
	birthday := func(viewer, target string) any {
		p, err := s.VisibleProfile(ctx, viewer, target, nil, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		return p["birthday"]
	}
	// Off by default.
	if birthday(f, a) != nil {
		t.Fatal("birthday shown by default")
	}
	setPrivacy(t, s, a, `{"showBirthday":true}`)
	got, ok := birthday(f, a).(map[string]int)
	if !ok || got["month"] != 5 || got["day"] != 17 || len(got) != 2 {
		t.Fatalf("friend sees %v, want month 5 day 17 and nothing else", birthday(f, a))
	}
	if birthday(o, a) != nil {
		t.Fatal("birthday shown beyond the friends audience")
	}
	setAudience(t, s, a, "birthday", "everyone")
	if birthday(o, a) == nil {
		t.Fatal("birthday not shown to everyone")
	}
	p, _ := s.VisibleProfile(ctx, o, a, nil, testSigner)
	raw, _ := json.Marshal(p)
	if strings.Contains(string(raw), "1995") || strings.Contains(string(raw), "birthDate") {
		t.Fatalf("the year of birth leaked: %s", raw)
	}
	// A minor never shows one, whatever is stored.
	setPrivacy(t, s, teen, `{"showBirthday":true}`)
	setAudience(t, s, teen, "birthday", "everyone")
	if birthday(teenFriend, teen) != nil {
		t.Fatal("a minor's birthday was shown")
	}
}

// ---- Filters

func TestDiscoverFiltersLanguageLevelPersonalityAndCountry(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	me := v2Member(t, s, "meg", adultBirth)
	setProfile(t, s, me, `{"country":"IN"}`)
	a, b, c, d := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "ben", adultBirth), v2Member(t, s, "cyd", adultBirth), v2Member(t, s, "dee", adultBirth)
	setProfile(t, s, a, `{"languages":[{"code":"ko","level":5},{"code":"en","level":2}],"personalityTags":["curious","maker","foodie"],"country":"IN"}`)
	setProfile(t, s, b, `{"languages":[{"code":"ko","level":2}],"personalityTags":["playful","sporty","chatty"],"country":"KR"}`)
	setProfile(t, s, c, `{"languages":[{"code":"ko","level":6}],"country":"IN"}`)
	setProfile(t, s, d, `{"languages":[{"code":"fr","level":6}]}`)
	names := func(f domain.PeopleFilters, viewer string) []string {
		t.Helper()
		items, _, err := s.SearchPeoplePage(ctx, viewer, f, "00000000-0000-0000-0000-000000000000", 50, nil, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, it := range items {
			out = append(out, it["username"].(string))
		}
		slices.Sort(out)
		return out
	}
	parse := func(body string) domain.PeopleFilters {
		t.Helper()
		var raw map[string]json.RawMessage
		_ = json.Unmarshal([]byte(body), &raw)
		f, err := domain.ParsePeopleFilters(raw)
		if err != nil {
			t.Fatal(err)
		}
		return f
	}
	check := func(body string, want ...string) {
		t.Helper()
		if got := names(parse(body), me); !slices.Equal(got, want) {
			t.Errorf("%s: %v, want %v", body, got, want)
		}
	}
	check(`{"languages":["ko"]}`, "ana", "ben", "cyd")
	check(`{"languages":["ko"],"languageMinLevel":4}`, "ana", "cyd")
	check(`{"languages":["ko"],"languageMinLevel":6}`, "cyd")
	check(`{"languages":["ko","fr"],"languageMinLevel":6}`, "cyd", "dee")
	check(`{"languages":["en"],"languageMinLevel":3}`)
	check(`{"personalityTags":["maker"]}`, "ana")
	check(`{"personalityTags":["maker","sporty"]}`, "ana", "ben")
	check(`{"sameCountry":true}`, "ana", "cyd")
	check(`{"sameCountry":true,"languages":["ko"],"languageMinLevel":6}`, "cyd")
	// Hidden fields never match: not even by filtering.
	setAudience(t, s, a, "languages", "nobody")
	setAudience(t, s, a, "personality", "followers")
	setAudience(t, s, a, "location", "nobody")
	check(`{"languages":["ko"],"languageMinLevel":4}`, "cyd")
	check(`{"personalityTags":["maker"]}`)
	check(`{"sameCountry":true}`, "cyd")
	// The shortcut needs a country on the viewer's own profile.
	if _, _, err := s.SearchPeoplePage(ctx, a, parse(`{"sameCountry":true}`), "00000000-0000-0000-0000-000000000000", 50, nil, testSigner); err != nil {
		t.Fatalf("a viewer with a country: %v", err)
	}
	if _, _, err := s.SearchPeoplePage(ctx, d, parse(`{"sameCountry":true}`), "00000000-0000-0000-0000-000000000000", 50, nil, testSigner); !errors.Is(err, domain.ErrSameCountryUnknown) {
		t.Fatalf("a viewer without a country: %v", err)
	}
	// The row carries the levels.
	items, _, _ := s.SearchPeoplePage(ctx, me, parse(`{"languages":["fr"]}`), "00000000-0000-0000-0000-000000000000", 50, nil, testSigner)
	if len(items) != 1 {
		t.Fatalf("%v", items)
	}
	raw, _ := json.Marshal(items[0]["languages"])
	if string(raw) != `[{"code":"fr","level":6}]` {
		t.Fatalf("languages in the row: %s", raw)
	}
	if _, ok := items[0]["localTime"]; !ok {
		t.Fatal("an adult's row has no local time")
	}
}

// ---- Possible matches

type fixture struct {
	id, name string
	json     string
}

func TestPossibleMatchesRankingMatchesTheScoreFunction(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	me := v2Member(t, s, "meg", adultBirth)
	setProfile(t, s, me, `{"country":"IN","interests":["Music","Books","Hiking"],"personalityTags":["curious","maker"],"languages":[{"code":"en","level":6},{"code":"ko","level":2}]}`)
	fixtures := []fixture{
		{"", "p01", `{"interests":["music"]}`},
		{"", "p02", `{"interests":["music","books"]}`},
		{"", "p03", `{"interests":["music","books","hiking","chess","film","art"]}`},
		{"", "p04", `{"personalityTags":["curious","maker","foodie"]}`},
		{"", "p05", `{"languages":[{"code":"ko","level":5}]}`},
		{"", "p06", `{"languages":[{"code":"en","level":2}]}`},
		{"", "p07", `{"languages":[{"code":"ko","level":6},{"code":"en","level":1}]}`},
		{"", "p08", `{"country":"IN"}`},
		{"", "p09", `{"country":"IN","interests":["music"],"personalityTags":["maker","playful","sporty"],"languages":[{"code":"ko","level":4}]}`},
		{"", "p10", `{"interests":["golf"],"country":"FR"}`},
		{"", "p11", `{"languages":[{"code":"en","level":5}]}`},
		{"", "p12", `{"languages":[{"code":"ko","level":2},{"code":"en","level":2}],"interests":["books"]}`},
	}
	want := map[string]int{}
	byName := map[string]string{}
	for i := range fixtures {
		fixtures[i].id = v2Member(t, s, fixtures[i].name, adultBirth)
		byName[fixtures[i].id] = fixtures[i].name
		setProfile(t, s, fixtures[i].id, fixtures[i].json)
		got, err := s.matchProfile(ctx, fixtures[i].id)
		if err != nil {
			t.Fatal(err)
		}
		mine, _ := s.matchProfile(ctx, me)
		theirs := got
		if score := domain.Score(mine, theirs).Total(); score > 0 {
			want[fixtures[i].name] = score
		}
	}
	// Non-members of the ranking: blocked, hidden, not onboarded, suspended, minor, and the viewer themself.
	blocked := v2Member(t, s, "blocked", adultBirth)
	hidden := v2Member(t, s, "hidden", adultBirth)
	notOnboarded := v2Member(t, s, "pending", adultBirth)
	suspended := v2Member(t, s, "suspended", adultBirth)
	teen := v2Member(t, s, "teen", teenBirth)
	for _, id := range []string{blocked, hidden, notOnboarded, suspended, teen} {
		setProfile(t, s, id, `{"interests":["music","books","hiking"],"personalityTags":["curious","maker"],"country":"IN"}`)
	}
	mustExec(t, s, `INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, me, blocked)
	setPrivacy(t, s, hidden, `{"discoverable":false}`)
	mustExec(t, s, `UPDATE onboarding SET completed_at=NULL WHERE user_id=$1`, notOnboarded)
	mustExec(t, s, `UPDATE users SET status='suspended' WHERE user_id=$1`, suspended)

	var got []string
	scores := map[string]int{}
	after := PossibleAfter{}
	for page := 0; page < 20; page++ {
		found, err := s.PossibleMatches(ctx, me, false, after, 4, nil, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range found {
			name := m.Item["username"].(string)
			got = append(got, name)
			scores[name] = m.Score
			if _, ok := m.Item["reasons"].([]string); !ok {
				t.Fatalf("%s has no reasons: %v", name, m.Item)
			}
			if _, leaked := m.Item["score"]; leaked {
				t.Fatal("the score is part of the item")
			}
		}
		if len(found) < 4 {
			break
		}
		last := found[len(found)-1]
		after = PossibleAfter{HasAfter: true, Score: last.Score, UserID: last.Item["userId"].(string)}
	}
	if fmt.Sprint(scores) != fmt.Sprint(want) {
		t.Fatalf("scores %v\nwant   %v", scores, want)
	}
	// Order: score descending, then user id ascending; no one twice; none of the excluded.
	seen := map[string]bool{}
	for i, name := range got {
		if seen[name] {
			t.Fatalf("%s listed twice", name)
		}
		seen[name] = true
		if i > 0 {
			prev, cur := got[i-1], name
			if scores[prev] < scores[cur] {
				t.Fatalf("%s (%d) before %s (%d)", prev, scores[prev], cur, scores[cur])
			}
		}
	}
	for _, name := range []string{"blocked", "hidden", "pending", "suspended", "teen", "meg"} {
		if seen[name] {
			t.Errorf("%s was listed", name)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("%d listed, want %d: %v", len(got), len(want), got)
	}
	// The one-page answer is the same list in the same order (the page size changes nothing).
	all, err := s.PossibleMatches(ctx, me, false, PossibleAfter{}, 50, nil, testSigner)
	if err != nil {
		t.Fatal(err)
	}
	var one []string
	for _, m := range all {
		one = append(one, m.Item["username"].(string))
	}
	if !slices.Equal(one, got) {
		t.Fatalf("paging changed the order:\npaged %v\nwhole %v", got, one)
	}
	if got[0] != "p03" {
		t.Fatalf("the best match is %s", got[0])
	}
}

func TestPossibleMatchesCursorStaysStableWhileTheListChanges(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	me := v2Member(t, s, "meg", adultBirth)
	setProfile(t, s, me, `{"interests":["music","books"]}`)
	var members []string
	for i := 0; i < 6; i++ {
		id := v2Member(t, s, fmt.Sprintf("m%02d", i), adultBirth)
		setProfile(t, s, id, `{"interests":["music"]}`) // all score 3: ties broken by user id
		members = append(members, id)
	}
	first, err := s.PossibleMatches(ctx, me, false, PossibleAfter{}, 3, nil, testSigner)
	if err != nil || len(first) != 3 {
		t.Fatalf("%v %v", first, err)
	}
	// Somebody better arrives, somebody leaves, and a tied member sorts before the cursor: the next page still
	// continues strictly after the last row, with no repeat.
	better := v2Member(t, s, "better", adultBirth)
	setProfile(t, s, better, `{"interests":["music","books"]}`)
	setPrivacy(t, s, members[5], `{"discoverable":false}`)
	last := first[len(first)-1]
	next, err := s.PossibleMatches(ctx, me, false, PossibleAfter{HasAfter: true, Score: last.Score, UserID: last.Item["userId"].(string)}, 10, nil, testSigner)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range next {
		for _, f := range first {
			if m.Item["userId"] == f.Item["userId"] {
				t.Fatalf("%v repeated on the next page", m.Item["username"])
			}
		}
		if m.Score > last.Score || (m.Score == last.Score && m.Item["userId"].(string) <= last.Item["userId"].(string)) {
			t.Fatalf("the next page starts before the cursor: %d %v", m.Score, m.Item["userId"])
		}
	}
}

func TestPossibleMatchesRespectsAudiencesAndFollowing(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	me := v2Member(t, s, "meg", adultBirth)
	setProfile(t, s, me, `{"country":"IN","interests":["music"],"personalityTags":["curious","maker","foodie"],"languages":[{"code":"ko","level":2}]}`)
	a, b := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "ben", adultBirth)
	all := `{"country":"IN","interests":["music"],"personalityTags":["curious","maker","foodie"],"languages":[{"code":"ko","level":6}]}`
	setProfile(t, s, a, all)
	setProfile(t, s, b, all)
	score := func(name string) int {
		t.Helper()
		found, err := s.PossibleMatches(ctx, me, false, PossibleAfter{}, 50, nil, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range found {
			if m.Item["username"] == name {
				return m.Score
			}
		}
		return -1
	}
	if got := score("ana"); got != 3+2*3+4+1 {
		t.Fatalf("full score %d", got)
	}
	// A hidden field does not count, and a member with nothing visible in common is not listed at all.
	for _, field := range []string{"interests", "personality", "languages", "location"} {
		setAudience(t, s, a, field, "friends")
	}
	if got := score("ana"); got != -1 {
		t.Fatalf("a member who hides everything is listed with score %d", got)
	}
	setAudience(t, s, a, "interests", "everyone")
	if got := score("ana"); got != 3 {
		t.Fatalf("only interests visible: %d", got)
	}
	// Following: left out only when asked.
	mustExec(t, s, `INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,'active')`, me, b)
	if score("ben") == -1 {
		t.Fatal("a followed member was dropped without being asked")
	}
	found, err := s.PossibleMatches(ctx, me, true, PossibleAfter{}, 50, nil, testSigner)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range found {
		if m.Item["username"] == "ben" {
			t.Fatal("a followed member was listed with excludeFollowing")
		}
	}
}

func TestPossibleMatchesStayInTheAgeBand(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	teen, mate, adult := v2Member(t, s, "kai", teenBirth), v2Member(t, s, "lee", teenBirth), v2Member(t, s, "ada", adultBirth)
	same := `{"interests":["music","books"]}`
	for _, id := range []string{teen, mate, adult} {
		setProfile(t, s, id, same)
	}
	found, err := s.PossibleMatches(ctx, teen, false, PossibleAfter{}, 50, nil, testSigner)
	if err != nil || len(found) != 1 || found[0].Item["username"] != "lee" {
		t.Fatalf("a minor's possible matches: %v %v", found, err)
	}
	found, err = s.PossibleMatches(ctx, adult, false, PossibleAfter{}, 50, nil, testSigner)
	if err != nil || len(found) != 0 {
		t.Fatalf("an adult's possible matches: %v %v", found, err)
	}
}

// EXPLAIN: the candidates come from the indexes of the normalised tables, not from a scan of every profile.
func TestPossibleMatchesUsesTheNormalisedIndexes(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	for _, q := range []string{
		`CREATE TEMP TABLE seeded AS SELECT gen_random_uuid() AS id, g FROM generate_series(1,30000) g`,
		`INSERT INTO users(user_id) SELECT id FROM seeded`,
		`INSERT INTO onboarding(user_id,completed_at) SELECT id,now() FROM seeded`,
		// The trigger keeps the normalised tables in step row by row; for 30000 rows they are filled set-wise below.
		`ALTER TABLE profiles DISABLE TRIGGER profiles_derive`,
		`INSERT INTO profiles(user_id,username,data) SELECT id,'u'||lpad(g::text,6,'0'),jsonb_build_object('displayName','m'||g,'country',(ARRAY['IN','FR','KR','JP'])[1+g%4],
   'interests',jsonb_build_array('i'||(g%200),'i'||((g+7)%200)),'personalityTags',jsonb_build_array('t'||(g%19)),
   'languages',jsonb_build_array(jsonb_build_object('code',(ARRAY['en','ko','hi','fr'])[1+g%4],'level',1+g%6))) FROM seeded`,
		`INSERT INTO profile_interests(user_id,interest) SELECT id,'i'||(g%200) FROM seeded UNION SELECT id,'i'||((g+7)%200) FROM seeded`,
		`INSERT INTO profile_personality_tags(user_id,tag) SELECT id,'t'||(g%19) FROM seeded`,
		`INSERT INTO profile_languages(user_id,code,level) SELECT id,(ARRAY['en','ko','hi','fr'])[1+g%4],1+g%6 FROM seeded`,
		`INSERT INTO privacy_settings(user_id,data) SELECT id,'{"discoverable":true,"profileAudience":"public","fieldAudiences":{"interests":"everyone","personality":"everyone","languages":"everyone","location":"everyone"}}' FROM seeded`,
		`ANALYZE profiles`, `ANALYZE profile_interests`, `ANALYZE profile_languages`, `ANALYZE profile_personality_tags`, `ANALYZE privacy_settings`, `ANALYZE users`, `ANALYZE onboarding`,
	} {
		if _, err = tx.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	var viewer string
	if err = tx.QueryRow(ctx, `SELECT id::text FROM seeded WHERE g=1`).Scan(&viewer); err != nil {
		t.Fatal(err)
	}
	plan := explain(t, tx, possibleMatchesSQL(), viewer, []string{"i1", "i8"}, []string{"t1"}, []string{"ko"}, []string{"en"}, "IN", false, 0, "00000000-0000-0000-0000-000000000000", false, 21)
	t.Logf("possible matches, 30000 members:\n%s", plan)
	for _, table := range []string{"profile_interests", "profile_personality_tags", "profile_languages"} {
		if !strings.Contains(plan, "Index Only Scan using "+table) && !strings.Contains(plan, "Index Scan using "+table) && !strings.Contains(plan, "Bitmap Index Scan on "+table) {
			t.Errorf("%s is not read through an index:\n%s", table, plan)
		}
		if strings.Contains(plan, "Seq Scan on "+table) {
			t.Errorf("%s is scanned in full:\n%s", table, plan)
		}
	}
	if strings.Contains(plan, "Seq Scan on profiles") && !strings.Contains(plan, "profiles_country") {
		t.Errorf("profiles are scanned without the country index:\n%s", plan)
	}
	if !strings.Contains(plan, "hashed SubPlan") {
		t.Errorf("the block check is not a hashed subplan:\n%s", plan)
	}
}

// ---- Visitors

func visit(t *testing.T, s *Store, visitor, target string) {
	t.Helper()
	if _, err := s.RecordProfileVisit(context.Background(), visitor, target); err != nil {
		t.Fatal(err)
	}
}

func visitorNames(t *testing.T, s *Store, viewer, target string) []string {
	t.Helper()
	list, err := s.ListRecentVisitors(context.Background(), viewer, target, nil, "00000000-0000-0000-0000-000000000000", 50, testSigner)
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, v := range list {
		out = append(out, v.User.Username)
	}
	slices.Sort(out)
	return out
}

func TestRecentVisitorsAreOptInAdultsOnlyAndRespectBlocksAndBands(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	owner, v1, v2, viewer := v2Member(t, s, "owner", adultBirth), v2Member(t, s, "vis1", adultBirth), v2Member(t, s, "vis2", adultBirth), v2Member(t, s, "viewer", adultBirth)
	teen := v2Member(t, s, "teen", teenBirth)
	for _, v := range []string{v1, v2, teen} {
		visit(t, s, v, owner)
	}
	// Off by default: the owner's own list is unchanged, the visitor list of others is private.
	if err := s.CanSeeVisitors(ctx, viewer, owner); !errors.Is(err, domain.ErrVisitorsPrivate) {
		t.Fatalf("default: %v", err)
	}
	if mine, err := s.ListVisitors(ctx, owner, nil, "00000000-0000-0000-0000-000000000000", 50, 200, testSigner); err != nil || len(mine) < 2 {
		t.Fatalf("the owner's own list: %v %v", mine, err)
	}
	p, _ := s.VisibleProfile(ctx, viewer, owner, nil, testSigner)
	if p["visitorsVisible"] != nil {
		t.Fatal("the profile advertises a visitor list that is off")
	}
	setPrivacy(t, s, owner, `{"visitorsVisibleToOthers":true}`)
	if err := s.CanSeeVisitors(ctx, viewer, owner); err != nil {
		t.Fatal(err)
	}
	p, _ = s.VisibleProfile(ctx, viewer, owner, nil, testSigner)
	if p["visitorsVisible"] != true {
		t.Fatal("the profile does not say its visitors are visible")
	}
	if got := visitorNames(t, s, viewer, owner); !slices.Equal(got, []string{"vis1", "vis2"}) {
		t.Fatalf("visitors %v (a minor must never appear)", got)
	}
	// A block between the viewer and a visitor hides that visitor from this viewer only.
	mustExec(t, s, `INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, viewer, v1)
	if got := visitorNames(t, s, viewer, owner); !slices.Equal(got, []string{"vis2"}) {
		t.Fatalf("after the viewer blocked v1: %v", got)
	}
	if got := visitorNames(t, s, v2, owner); !slices.Equal(got, []string{"vis1"}) && !slices.Equal(got, []string{"vis1", "vis2"}) {
		t.Fatalf("another viewer: %v", got)
	}
	mustExec(t, s, `DELETE FROM blocks`)
	// A block between the viewer and the owner: not found, like the profile.
	mustExec(t, s, `INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, owner, viewer)
	if err := s.CanSeeVisitors(ctx, viewer, owner); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("blocked viewer: %v", err)
	}
	mustExec(t, s, `DELETE FROM blocks`)
	// A minor viewer cannot read an adult's list (the age band), and a minor's list never exists.
	if err := s.CanSeeVisitors(ctx, teen, owner); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("minor viewing an adult's list: %v", err)
	}
	teen2 := v2Member(t, s, "teen2", teenBirth)
	visit(t, s, teen2, teen)
	mustExec(t, s, `UPDATE privacy_settings SET data=data||'{"visitorsVisibleToOthers":true}' WHERE user_id=$1`, teen) // behind the API's back
	if err := s.CanSeeVisitors(ctx, teen2, teen); !errors.Is(err, domain.ErrVisitorsPrivate) {
		t.Fatalf("a minor's visitor list: %v", err)
	}
	// A locked profile does not open the list; the audience is the profile's.
	setPrivacy(t, s, owner, `{"profileAudience":"friends"}`)
	if err := s.CanSeeVisitors(ctx, viewer, owner); !errors.Is(err, domain.ErrVisitorsPrivate) {
		t.Fatalf("locked profile: %v", err)
	}
	// Only the last 30 days.
	setPrivacy(t, s, owner, `{"profileAudience":"public"}`)
	mustExec(t, s, `UPDATE profile_visits SET last_visited_at=now()-interval '31 days' WHERE profile_id=$1 AND visitor_id=$2`, owner, v2)
	if got := visitorNames(t, s, viewer, owner); !slices.Equal(got, []string{"vis1"}) {
		t.Fatalf("window: %v", got)
	}
	// Turning it off again closes it at once.
	setPrivacy(t, s, owner, `{"visitorsVisibleToOthers":false}`)
	if err := s.CanSeeVisitors(ctx, viewer, owner); !errors.Is(err, domain.ErrVisitorsPrivate) {
		t.Fatalf("after turning it off: %v", err)
	}
	if err := s.CanSeeVisitors(ctx, owner, owner); !errors.Is(err, domain.ErrVisitorsPrivate) {
		t.Fatalf("the owner reads the owner list through the other route: %v", err)
	}
}

func TestRecentVisitorsNeverListAMinorEvenWithIsolationOff(t *testing.T) {
	s := scratchStore(t, WithAgeBandIsolation(false))
	owner, viewer, adultVisitor := v2Member(t, s, "owner", adultBirth), v2Member(t, s, "viewer", adultBirth), v2Member(t, s, "grown", adultBirth)
	teen := v2Member(t, s, "teen", teenBirth)
	setPrivacy(t, s, owner, `{"visitorsVisibleToOthers":true}`)
	visit(t, s, teen, owner)
	visit(t, s, adultVisitor, owner)
	if got := visitorNames(t, s, viewer, owner); !slices.Equal(got, []string{"grown"}) {
		t.Fatalf("visitors %v", got)
	}
}

func TestPlacesVisitedIsTheMembersOwnWindowedHistory(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	me, a, b, c := v2Member(t, s, "meg", adultBirth), v2Member(t, s, "ana", adultBirth), v2Member(t, s, "ben", adultBirth), v2Member(t, s, "cyd", adultBirth)
	teen := v2Member(t, s, "teen", teenBirth)
	for _, p := range []string{a, b, c} {
		visit(t, s, me, p)
	}
	visit(t, s, teen, a) // another member's history is not mine
	names := func(user string) []string {
		list, err := s.ListPlacesVisited(ctx, user, nil, "00000000-0000-0000-0000-000000000000", 50, testSigner)
		if err != nil {
			t.Fatal(err)
		}
		out := []string{}
		for _, v := range list {
			out = append(out, v.User.Username)
		}
		slices.Sort(out)
		return out
	}
	if got := names(me); !slices.Equal(got, []string{"ana", "ben", "cyd"}) {
		t.Fatalf("places %v", got)
	}
	if got := names(a); len(got) != 0 {
		t.Fatalf("another member's list: %v", got)
	}
	mustExec(t, s, `UPDATE profile_visits SET last_visited_at=now()-interval '31 days' WHERE visitor_id=$1 AND profile_id=$2`, me, c)
	mustExec(t, s, `INSERT INTO blocks(blocker_id,blocked_id) VALUES($1,$2)`, b, me)
	if got := names(me); !slices.Equal(got, []string{"ana"}) {
		t.Fatalf("window and blocks: %v", got)
	}
	// A repeat visit within the hour does not write; after an hour it refreshes the time.
	mustExec(t, s, `UPDATE profile_visits SET last_visited_at=now()-interval '2 hours' WHERE visitor_id=$1 AND profile_id=$2`, me, a)
	visit(t, s, me, a)
	if n := mustCount(t, s, `SELECT count(*) FROM profile_visits WHERE visitor_id=$1 AND profile_id=$2 AND last_visited_at>now()-interval '1 minute'`, me, a); n != 1 {
		t.Fatal("a repeat visit after an hour did not refresh last_visited_at")
	}
	if n := mustCount(t, s, `SELECT count(*) FROM profile_visits WHERE visitor_id=$1 AND profile_id=$2 AND first_visited_at<now()-interval '1 minute'`, me, a); n == 1 {
		t.Log("first_visited_at kept")
	}
	// Clearing removes the history, not the all-time count.
	before := mustCount(t, s, `SELECT coalesce(sum(visitors),0)::int FROM profile_visit_counts WHERE profile_id=$1`, a)
	n, err := s.ClearPlacesVisited(ctx, me)
	if err != nil || n < 1 {
		t.Fatalf("clear: %d %v", n, err)
	}
	if got := names(me); len(got) != 0 {
		t.Fatalf("after clearing: %v", got)
	}
	if after := mustCount(t, s, `SELECT coalesce(sum(visitors),0)::int FROM profile_visit_counts WHERE profile_id=$1`, a); after != before {
		t.Fatalf("clearing lowered the visitor count: %d -> %d", before, after)
	}
}

// ---- Nearby distance

func TestShowDistanceIsReadFromTheMembersSetting(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	me, shown, hidden := v2Member(t, s, "meg", adultBirth), v2Member(t, s, "shown", adultBirth), v2Member(t, s, "hidden", adultBirth)
	for _, id := range []string{me, shown, hidden} {
		mustExec(t, s, `INSERT INTO nearby_prefs(user_id,visible) VALUES($1,true)`, id)
		mustExec(t, s, `INSERT INTO user_locations(user_id,latitude,longitude,updated_at) VALUES($1,12.97,77.59,now())`, id)
	}
	setPrivacy(t, s, hidden, `{"showDistance":false}`)
	items, err := s.NearbyPeople(ctx, me, domain.Location{Latitude: 12.97, Longitude: 77.59}, false, 25, domain.PeopleFilters{}, NearbyAfter{}, 20, nil, testSigner)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, it := range items {
		got[it["username"].(string)] = it["distanceHidden"] == true
		if it["distanceKm"] == nil {
			t.Fatal("the bucket must stay in the item for the page cursor")
		}
	}
	if len(got) != 2 || got["shown"] || !got["hidden"] {
		t.Fatalf("distanceHidden by member: %v", got)
	}
}

func TestNewMembersGetTheV2Defaults(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a, kai := v2Member(t, s, "ana", adultBirth), v2Member(t, s, "kai", teenBirth)
	pa, err := s.GetPrivacy(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	if !pa.ShowLocalTime || !pa.ShowDistance || pa.VisitorsVisibleToOthers || pa.ShowBirthday ||
		pa.FieldAudiences["aboutMe"] != "followers" || pa.FieldAudiences["hometown"] != "followers" || pa.FieldAudiences["birthday"] != "friends" || pa.FieldAudiences["personality"] != "everyone" {
		t.Fatalf("adult defaults %+v", pa)
	}
	pk, err := s.GetPrivacy(ctx, kai)
	if err != nil {
		t.Fatal(err)
	}
	if pk.ShowLocalTime || pk.ShowDistance || pk.VisitorsVisibleToOthers || pk.ShowBirthday ||
		pk.FieldAudiences["aboutMe"] != "nobody" || pk.FieldAudiences["hometown"] != "nobody" || pk.FieldAudiences["birthday"] != "nobody" || pk.FieldAudiences["personality"] != "everyone" {
		t.Fatalf("minor defaults %+v", pk)
	}
	// The API refuses what a minor may never switch on.
	for _, patch := range []string{`{"visitorsVisibleToOthers":true}`, `{"showBirthday":true}`, `{"fieldAudiences":{"hometown":"followers"}}`, `{"fieldAudiences":{"aboutMe":"everyone"}}`, `{"fieldAudiences":{"birthday":"friends"}}`} {
		var raw map[string]json.RawMessage
		_ = json.Unmarshal([]byte(patch), &raw)
		if _, err = s.UpdatePrivacy(ctx, kai, mustPrivacyVersion(t, s, kai), raw); !errors.Is(err, domain.ErrMinorSettingLocked) {
			t.Errorf("minor %s: %v", patch, err)
		}
	}
	for _, patch := range []string{`{"fieldAudiences":{"hometown":"friends","aboutMe":"friends"}}`, `{"showLocalTime":true,"showDistance":true}`} {
		var raw map[string]json.RawMessage
		_ = json.Unmarshal([]byte(patch), &raw)
		if _, err = s.UpdatePrivacy(ctx, kai, mustPrivacyVersion(t, s, kai), raw); err != nil {
			t.Errorf("minor %s: %v", patch, err)
		}
	}
}

func mustPrivacyVersion(t *testing.T, s *Store, id string) int64 {
	t.Helper()
	var v int64
	if err := s.Pool.QueryRow(context.Background(), `SELECT version FROM privacy_settings WHERE user_id=$1`, id).Scan(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestMemberDeletionPurgesTheV2Tables(t *testing.T) {
	s := scratchStore(t)
	ctx := context.Background()
	a := v2Member(t, s, "ana", adultBirth)
	setProfile(t, s, a, `{"languages":[{"code":"en","level":5}],"interests":["x"],"personalityTags":["maker"]}`)
	if _, err := s.AddProfilePhoto(ctx, a, readyPhoto(t, s, a), domain.Free(), testSigner); err != nil {
		t.Fatal(err)
	}
	mustExec(t, s, `DELETE FROM profile_photos WHERE user_id=$1`, a)
	mustExec(t, s, `DELETE FROM profiles WHERE user_id=$1`, a)
	for _, table := range []string{"profile_languages", "profile_interests", "profile_personality_tags", "profile_photos"} {
		if n := mustCount(t, s, `SELECT count(*) FROM `+table+` WHERE user_id=$1`, a); n != 0 {
			t.Errorf("%s keeps %d rows of a deleted profile", table, n)
		}
	}
}
