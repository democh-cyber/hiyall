package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"hiyall/services/api/internal/domain"
)

// Per-member limits on photos, posts and stories (docs/api/16-pulse-and-media.md#limits-and-quotas).

const (
	postLimitMessage   = "You’ve reached today’s limit of 20 posts. Try again later."
	storyLimitMessage  = "You’ve reached today’s limit of 30 stories. Try again later."
	uploadLimitMessage = "You’ve reached today’s photo upload limit. Try again later."
	storageFullMessage = "Your photo storage is full. Delete some posts or stories to free space."
)

// limitReply keeps the status, the Retry-After header and the raw body of a response.
type limitReply struct {
	status int
	retry  string
	body   []byte
}

func (h *socialHarness) limited(user, method, path string, payload any) limitReply {
	raw, _ := json.Marshal(payload)
	status, header, body := h.full(user, method, path, "application/json", string(raw))
	return limitReply{status, header.Get("Retry-After"), body}
}

// slotCall asks for a photo upload slot, with the per-account limiter reset so only the quotas answer.
func (h *socialHarness) slotCall(user, purpose string, size int64) limitReply {
	h.t.Helper()
	h.api.uploads.reset(user)
	return h.limited(user, "POST", "/v1/media/uploads", map[string]any{"purpose": purpose, "contentType": "image/jpeg", "sizeBytes": size})
}

func (h *socialHarness) postCall(user, body string) limitReply {
	h.t.Helper()
	h.api.content.reset(user)
	return h.limited(user, "POST", "/v1/posts", map[string]any{"body": body, "audience": "public", "mediaIds": []string{}})
}

func (h *socialHarness) storyCall(user, body string) limitReply {
	h.t.Helper()
	h.api.content.reset(user)
	return h.limited(user, "POST", "/v1/stories", map[string]any{"body": body, "audience": "public"})
}

func (r limitReply) wantCreated(t *testing.T) {
	t.Helper()
	if r.status != 201 {
		t.Fatalf("got %d %s, want 201", r.status, r.body)
	}
}

// retrySeconds is the Retry-After the refusal carried.
func (r limitReply) retrySeconds(t *testing.T) int {
	t.Helper()
	n, err := strconv.Atoi(r.retry)
	if err != nil || n < 1 {
		t.Fatalf("Retry-After %q", r.retry)
	}
	return n
}

// wantQuota checks the whole refusal: 429 QUOTA with the message, nothing but the standard envelope, and
// a Retry-After only when the limit lifts by itself.
func (r limitReply) wantQuota(t *testing.T, message string, withRetry bool) {
	t.Helper()
	if r.status != 429 {
		t.Fatalf("got %d %s, want 429", r.status, r.body)
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(r.body, &body); err != nil || len(body) != 3 || body["success"] == nil || body["error"] == nil || body["meta"] == nil || string(body["success"]) != "false" {
		t.Fatalf("envelope %s (%v)", r.body, err)
	}
	var fail map[string]string
	if err := json.Unmarshal(body["error"], &fail); err != nil || len(fail) != 2 || fail["code"] != "QUOTA" || fail["message"] != message {
		t.Fatalf("error %s, want QUOTA %q", body["error"], message)
	}
	var meta map[string]any
	if err := json.Unmarshal(body["meta"], &meta); err != nil || len(meta) != 2 || meta["requestId"] == nil || meta["serverTime"] == nil {
		t.Fatalf("meta %s", body["meta"])
	}
	if withRetry {
		r.retrySeconds(t)
	} else if r.retry != "" {
		t.Fatalf("Retry-After %q on a limit that does not lift by itself", r.retry)
	}
}

func (r limitReply) wantRetryAbout(t *testing.T, seconds int) {
	t.Helper()
	if got := r.retrySeconds(t); got < seconds-120 || got > seconds+5 {
		t.Fatalf("Retry-After %d, want about %d", got, seconds)
	}
}

// addPosts and addStories insert rows directly, age ago (oldest first, a millisecond apart).
func (h *socialHarness) addPosts(author string, n int, age string, deleted bool) {
	h.t.Helper()
	h.exec(`INSERT INTO posts(post_id,author_id,body,audience,created_at,deleted_at)
 SELECT gen_random_uuid(),$1,'p '||g,'public',now()-$3::interval+g*interval '1 millisecond',CASE WHEN $4 THEN now() END FROM generate_series(1,$2::int) g`, author, n, age, deleted)
}

func (h *socialHarness) addStories(author string, n int, age string, deleted bool) {
	h.t.Helper()
	h.exec(`INSERT INTO stories(story_id,author_id,body,audience,created_at,expires_at,deleted_at)
 SELECT gen_random_uuid(),$1,'s '||g,'public',now()-$3::interval+g*interval '1 millisecond',now()+interval '1 hour',CASE WHEN $4 THEN now() END FROM generate_series(1,$2::int) g`, author, n, age, deleted)
}

// addMedia inserts photo rows directly: n of them, age ago, of a status, with a stored and a declared size.
func (h *socialHarness) addMedia(owner, purpose, status string, n int, stored, declared int64, age string) {
	h.t.Helper()
	h.exec(`INSERT INTO media_assets(media_id,owner_id,purpose,status,content_type,size_bytes,declared_bytes,upload_key,expires_at,created_at,deleted_at)
 SELECT gen_random_uuid(),$1,$2,$3,'image/jpeg',$4,$5,'uploads/x',now()+interval '1 day',now()-$6::interval+g*interval '1 millisecond',CASE WHEN $3='deleted' THEN now() END FROM generate_series(1,$7::int) g`,
		owner, purpose, status, stored, declared, age, n)
}

func (h *socialHarness) countOf(sql string, args ...any) int {
	h.t.Helper()
	var n int
	if err := h.db.Pool.QueryRow(h.ctx, sql, args...).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

func TestUploadSlotsPerDayCountEveryPurposeWhateverBecameOfThem(t *testing.T) {
	h := newSocialHarness(t)
	withMedia(h)
	// 48 slots already used: never completed and since deleted, so they hold no storage and no pending slot.
	h.addMedia(alice, "post", "deleted", 48, 1000, 1000, "2 hours")
	h.slotCall(alice, "post", 1000).wantCreated(t)
	// An avatar slot is the 50th and counts like any other.
	h.slotCall(alice, "avatar", 1000).wantCreated(t)
	for _, purpose := range []string{"post", "story", "avatar"} {
		h.slotCall(alice, purpose, 1000).wantQuota(t, uploadLimitMessage, true)
	}
	// Deleting or abandoning slots frees nothing.
	h.exec(`UPDATE media_assets SET status='deleted',deleted_at=now() WHERE owner_id=$1`, alice)
	h.slotCall(alice, "post", 1000).wantQuota(t, uploadLimitMessage, true)
	// Other members have their own budget, a minor's is the same as an adult's.
	h.slotCall(bob, "post", 1000).wantCreated(t)
	h.setAge(cara, 15)
	h.addMedia(cara, "post", "deleted", 50, 1, 1, "1 hour")
	h.slotCall(cara, "post", 1000).wantQuota(t, uploadLimitMessage, true)

	// The window slides: the wait is until the oldest slot leaves it, and once it has the member can upload again.
	h.exec(`UPDATE media_assets SET created_at=now()-interval '23 hours' WHERE media_id=(SELECT media_id FROM media_assets WHERE owner_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	h.slotCall(alice, "post", 1000).wantRetryAbout(t, 3600)
	h.exec(`UPDATE media_assets SET created_at=now()-interval '25 hours' WHERE media_id=(SELECT media_id FROM media_assets WHERE owner_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	h.slotCall(alice, "post", 1000).wantCreated(t)
	h.slotCall(alice, "post", 1000).wantQuota(t, uploadLimitMessage, true)
}

func TestUploadBytesPerDayAreTheDeclaredSizes(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	const size = media15
	// Twenty 15 MiB slots are exactly 300 MiB.
	for i := range 20 {
		if i == 0 {
			h.slotCall(alice, "post", size).wantCreated(t)
		} else {
			h.slotCall(alice, []string{"post", "story", "avatar"}[i%3], size).wantCreated(t)
		}
	}
	over := h.slotCall(alice, "post", 1)
	over.wantQuota(t, uploadLimitMessage, true)
	over.wantRetryAbout(t, 24*3600)
	// The wait is until enough of the oldest slots have left: here the oldest, 22 hours old, frees 15 MiB.
	h.exec(`UPDATE media_assets SET created_at=now()-interval '1 hour'`)
	h.exec(`UPDATE media_assets SET created_at=now()-interval '22 hours' WHERE media_id=(SELECT media_id FROM media_assets ORDER BY created_at LIMIT 1)`)
	h.slotCall(alice, "post", size).wantRetryAbout(t, 2*3600)
	h.exec(`UPDATE media_assets SET created_at=now()-interval '25 hours' WHERE created_at<now()-interval '21 hours'`)
	h.slotCall(alice, "post", size).wantCreated(t)
	// Someone else is unaffected.
	h.slotCall(bob, "post", size).wantCreated(t)

	// A finished upload keeps counting the size that was declared, not the smaller stored one.
	h.exec(`DELETE FROM media_assets`)
	data := photo(t, 60, 40)
	id := h.upload(store, alice, "post", data)
	var declared, stored int64
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT declared_bytes,size_bytes FROM media_assets WHERE media_id=$1`, id).Scan(&declared, &stored); err != nil || declared != int64(len(data)) || stored == declared {
		t.Fatalf("declared %d stored %d (%v), photo is %d bytes", declared, stored, err, len(data))
	}
}

// media15 is the largest photo upload (media.MaxUploadBytes) as an untyped constant.
const media15 = 15 << 20

func TestPostsPerDayCountDeletedAndTextOnlyPosts(t *testing.T) {
	h := newSocialHarness(t)
	var first string
	for i := range 20 {
		id := h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": fmt.Sprintf("post %d", i), "audience": "public", "mediaIds": []string{}}), 201, "").data["postId"].(string)
		if first == "" {
			first = id
		}
	}
	h.postCall(alice, "one too many").wantQuota(t, postLimitMessage, true)
	if n := h.countOf(`SELECT count(*) FROM posts WHERE author_id=$1`, alice); n != 20 {
		t.Fatalf("%d posts stored", n)
	}
	h.postCall(alice, "one too many").wantRetryAbout(t, 24*3600)
	// Deleting posts does not refund the day's count.
	h.ok(alice, "DELETE", "/v1/posts/"+first)
	h.postCall(alice, "still too many").wantQuota(t, postLimitMessage, true)
	h.exec(`UPDATE posts SET deleted_at=now() WHERE author_id=$1`, alice)
	h.postCall(alice, "all deleted").wantQuota(t, postLimitMessage, true)
	// Members are independent; a minor has the same limit.
	h.postCall(bob, "mine").wantCreated(t)
	h.setAge(cara, 14)
	h.addPosts(cara, 19, "1 hour", false)
	h.postCall(cara, "twentieth").wantCreated(t)
	h.postCall(cara, "twenty-first").wantQuota(t, postLimitMessage, true)

	// The window slides: the wait is until the oldest post leaves it.
	h.exec(`UPDATE posts SET created_at=now()-interval '23 hours' WHERE post_id=(SELECT post_id FROM posts WHERE author_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	h.postCall(alice, "later").wantRetryAbout(t, 3600)
	h.exec(`UPDATE posts SET created_at=now()-interval '25 hours' WHERE post_id=(SELECT post_id FROM posts WHERE author_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	h.postCall(alice, "now it fits").wantCreated(t)
	h.postCall(alice, "and now it does not").wantQuota(t, postLimitMessage, true)
}

func TestStoriesPerDayCountDeletedAndTextOnlyStories(t *testing.T) {
	h := newSocialHarness(t)
	var first string
	for i := range 30 {
		got := h.storyCall(alice, fmt.Sprintf("story %d", i))
		got.wantCreated(t)
		if first == "" {
			var made struct{ Data map[string]string }
			_ = json.Unmarshal(got.body, &made)
			first = made.Data["storyId"]
		}
	}
	h.storyCall(alice, "one too many").wantQuota(t, storyLimitMessage, true)
	h.ok(alice, "DELETE", "/v1/stories/"+first)
	h.storyCall(alice, "still too many").wantQuota(t, storyLimitMessage, true)
	h.exec(`UPDATE stories SET deleted_at=now() WHERE author_id=$1`, alice)
	h.storyCall(alice, "all deleted").wantQuota(t, storyLimitMessage, true)
	// A story limit does not touch posts, and the other way round.
	h.postCall(alice, "a post").wantCreated(t)
	h.storyCall(bob, "mine").wantCreated(t)
	h.setAge(cara, 16)
	h.addStories(cara, 29, "1 hour", false)
	h.storyCall(cara, "thirtieth").wantCreated(t)
	h.storyCall(cara, "thirty-first").wantQuota(t, storyLimitMessage, true)

	h.exec(`UPDATE stories SET created_at=now()-interval '23 hours' WHERE story_id=(SELECT story_id FROM stories WHERE author_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	h.storyCall(alice, "later").wantRetryAbout(t, 3600)
	h.exec(`UPDATE stories SET created_at=now()-interval '25 hours' WHERE story_id=(SELECT story_id FROM stories WHERE author_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	h.storyCall(alice, "now it fits").wantCreated(t)
}

// A post or story that carries a photo is checked against the limit too, and a refused one leaves its
// photo unattached for the member to use later.
func TestPostAndStoryWithPhotosAreLimitedAndKeepTheirPhoto(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	h.addPosts(alice, 20, "1 hour", false)
	h.addStories(alice, 30, "1 hour", false)
	pic := h.upload(store, alice, "post", photo(t, 30, 30))
	h.expect(h.send(alice, "POST", "/v1/posts", map[string]any{"body": "", "audience": "public", "mediaIds": []string{pic}}), 429, "QUOTA")
	story := h.upload(store, alice, "story", photo(t, 30, 30))
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"mediaId": story, "audience": "public"}), 429, "QUOTA")
	for _, id := range []string{pic, story} {
		if status, attached := h.avatarState(id); status != "ready" || attached {
			t.Fatalf("refused photo is %s attached=%v", status, attached)
		}
	}
	// Once the day frees room the same photos post fine.
	h.exec(`UPDATE posts SET created_at=now()-interval '2 days' WHERE author_id=$1`, alice)
	h.exec(`UPDATE stories SET created_at=now()-interval '2 days' WHERE author_id=$1`, alice)
	h.post(alice, "public", "", pic)
	h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"mediaId": story, "audience": "public"}), 201, "")
}

func TestStorageCapCountsReadyPhotosAndFreesOnDelete(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	capacity := domain.Free().StorageBytes
	// Unattached ready photos count; pending, deleted and other members' photos do not.
	h.addMedia(alice, "post", "ready", 1, capacity-100, 1000, "1 hour")
	h.addMedia(alice, "post", "pending", 1, capacity, 1000, "1 hour")
	h.addMedia(alice, "post", "deleted", 1, capacity, 1000, "1 hour")
	h.addMedia(bob, "post", "ready", 1, capacity, 1000, "1 hour")
	h.slotCall(alice, "post", 101).wantQuota(t, storageFullMessage, false)
	h.slotCall(alice, "avatar", 101).wantQuota(t, storageFullMessage, false)
	h.slotCall(alice, "post", 100).wantCreated(t)
	h.slotCall(bob, "post", 1).wantQuota(t, storageFullMessage, false)

	// Deleting a post frees its photo; so does deleting a story.
	h.exec(`DELETE FROM media_assets`)
	pic := h.upload(store, alice, "post", photo(t, 40, 40))
	post := h.post(alice, "public", "with a photo", pic)
	h.exec(`UPDATE media_assets SET size_bytes=$2 WHERE media_id=$1`, pic, capacity-100)
	h.slotCall(alice, "post", 101).wantQuota(t, storageFullMessage, false)
	h.ok(alice, "DELETE", "/v1/posts/"+post)
	h.slotCall(alice, "post", 101).wantCreated(t)

	pic = h.upload(store, alice, "story", photo(t, 40, 40))
	story := h.expect(h.send(alice, "POST", "/v1/stories", map[string]any{"mediaId": pic, "audience": "public"}), 201, "").data["storyId"].(string)
	h.exec(`UPDATE media_assets SET size_bytes=$2 WHERE media_id=$1`, pic, capacity-100)
	h.slotCall(alice, "post", 101).wantQuota(t, storageFullMessage, false)
	h.ok(alice, "DELETE", "/v1/stories/"+story)
	h.slotCall(alice, "post", 101).wantCreated(t)

	// Replacing a profile photo releases the old one the same way.
	avatar := h.upload(store, alice, "avatar", avatarPhoto(t))
	h.expect(h.setAvatar(alice, avatar), 200, "")
	h.exec(`UPDATE media_assets SET size_bytes=$2 WHERE media_id=$1`, avatar, capacity-100)
	h.slotCall(alice, "post", 101).wantQuota(t, storageFullMessage, false)
	h.expect(h.setAvatar(alice, nil), 200, "")
	h.slotCall(alice, "post", 101).wantCreated(t)
}

// Storage is measured as what is stored: both variants of the re-encoded photo.
func TestStorageIsTheSizeOfTheStoredVariants(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	id := h.upload(store, alice, "post", photo(t, 200, 100))
	var stored int64
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT size_bytes FROM media_assets WHERE media_id=$1`, id).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	want := int64(len(store.Objects["media/"+id+"/full.jpg"]) + len(store.Objects["media/"+id+"/thumb.jpg"]))
	if want == 0 || stored != want {
		t.Fatalf("stored size %d, want %d", stored, want)
	}
}

// Parallel requests from one member cannot pass the limit together: the check and the insert are one
// transaction behind the member's lock.
func TestQuotasHoldUnderParallelRequests(t *testing.T) {
	h := newSocialHarness(t)
	withMedia(h)
	h.api.content = newKeyedLimiter(1000, 1000, 4096)
	h.api.uploads = newKeyedLimiter(1000, 1000, 4096)
	h.api.clients = newKeyedLimiter(100000, 100000, 16384)
	count := func(n int, call func(i int) limitReply, message string) (created int) {
		results := make([]limitReply, n)
		var wg sync.WaitGroup
		for i := range n {
			wg.Add(1)
			go func() { defer wg.Done(); results[i] = call(i) }()
		}
		wg.Wait()
		for _, r := range results {
			switch r.status {
			case 201:
				created++
			case 429:
				r.wantQuota(t, message, true)
			default:
				t.Errorf("status %d %s", r.status, r.body)
			}
		}
		return created
	}
	post := func(i int) limitReply {
		return h.limited(alice, "POST", "/v1/posts", map[string]any{"body": fmt.Sprint("p", i), "audience": "public", "mediaIds": []string{}})
	}
	if got := count(40, post, postLimitMessage); got != 20 {
		t.Fatalf("%d of 40 parallel posts succeeded, want exactly 20", got)
	}
	if n := h.countOf(`SELECT count(*) FROM posts WHERE author_id=$1`, alice); n != 20 {
		t.Fatalf("%d posts stored", n)
	}
	story := func(i int) limitReply {
		return h.limited(alice, "POST", "/v1/stories", map[string]any{"body": fmt.Sprint("s", i), "audience": "public"})
	}
	if got := count(45, story, storyLimitMessage); got != 30 {
		t.Fatalf("%d of 45 parallel stories succeeded, want exactly 30", got)
	}
	// Posts and stories of different members do not wait on each other's limit.
	if got := count(25, func(i int) limitReply {
		return h.limited([]string{bob, cara}[i%2], "POST", "/v1/posts", map[string]any{"body": fmt.Sprint("q", i), "audience": "public", "mediaIds": []string{}})
	}, postLimitMessage); got != 25 {
		t.Fatalf("%d of 25 posts by two members succeeded", got)
	}
	// Upload slots: 30 of the day's 50 are used, so exactly 20 of 40 parallel slots succeed.
	h.addMedia(alice, "post", "deleted", 30, 10, 10, "1 hour")
	slot := func(i int) limitReply {
		return h.limited(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 1000})
	}
	if got := count(40, slot, uploadLimitMessage); got != 20 {
		t.Fatalf("%d of 40 parallel upload slots succeeded, want exactly 20", got)
	}
	if n := h.countOf(`SELECT count(*) FROM media_assets WHERE owner_id=$1 AND status='pending'`, alice); n != 20 {
		t.Fatalf("%d pending slots", n)
	}
}

// The quota refusal is the standard envelope and leaks nothing about the member's items.
func TestQuotaRefusalsCarryNoExtraData(t *testing.T) {
	h := newSocialHarness(t)
	withMedia(h)
	h.addPosts(alice, 20, "1 hour", false)
	h.addMedia(alice, "post", "ready", 1, domain.Free().StorageBytes, 10, "1 hour")
	for name, r := range map[string]limitReply{
		"post":    h.postCall(alice, "x"),
		"storage": h.slotCall(alice, "post", 10),
	} {
		var body map[string]any
		if err := json.Unmarshal(r.body, &body); err != nil || body["data"] != nil {
			t.Fatalf("%s: %s", name, r.body)
		}
		for _, secret := range []string{alice, "uploads/", "media_assets", "author_id"} {
			if strings.Contains(string(r.body), secret) {
				t.Fatalf("%s refusal mentions %q: %s", name, secret, r.body)
			}
		}
	}
}

// The upload slot answer is the same shape as before, the signed URL pins the declared size, and the
// size is never handed to the client as a header to set.
func TestUploadSlotAnswerShapeAndSignedSize(t *testing.T) {
	h := newSocialHarness(t)
	store := withMedia(h)
	made := h.expect(h.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 123456}), 201, "").data
	if len(made) != 5 || made["method"] != "PUT" {
		t.Fatalf("slot %v", made)
	}
	headers := made["headers"].(map[string]any)
	if len(headers) != 1 || headers["Content-Type"] != "image/jpeg" {
		t.Fatalf("headers %v", headers)
	}
	key := strings.TrimPrefix(made["uploadUrl"].(string), "memory://put/")
	if store.Signed[key] != 123456 {
		t.Fatalf("signed size %d, want the declared 123456", store.Signed[key])
	}
}

// Every limit is data from the member's entitlements: a larger tier lets more through, a smaller one
// stops earlier, and members not covered by the resolver stay on Free.
func TestLimitsComeFromTheEntitlementsResolver(t *testing.T) {
	h := newSocialHarness(t)
	withMedia(h)
	big, small := domain.Free(), domain.Free()
	big.PostsPerDay, big.StoriesPerDay, big.UploadsPerDay, big.UploadBytesPerDay, big.StorageBytes = 25, 35, 60, 1<<40, 1<<40
	small.PostsPerDay, small.StoriesPerDay, small.UploadsPerDay, small.PendingUploads, small.UploadBytesPerDay, small.StorageBytes = 2, 1, 3, 2, 5000, 100
	var seen sync.Map
	h.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		seen.Store(user, true)
		switch user {
		case alice:
			return big
		case bob:
			return small
		}
		return domain.Free()
	}

	// The larger tier: the 21st post, the 31st story and the 51st upload slot go through.
	h.addPosts(alice, 20, "1 hour", false)
	h.postCall(alice, "21st").wantCreated(t)
	h.addStories(alice, 30, "1 hour", false)
	h.storyCall(alice, "31st").wantCreated(t)
	h.addMedia(alice, "post", "deleted", 50, 1, 1, "1 hour")
	h.slotCall(alice, "post", 15<<20).wantCreated(t)
	h.addPosts(alice, 4, "1 hour", false)
	h.postCall(alice, "26th").wantQuota(t, "You’ve reached today’s limit of 25 posts. Try again later.", true)

	// The smaller tier stops earlier, with its own numbers in the message.
	h.postCall(bob, "1").wantCreated(t)
	h.postCall(bob, "2").wantCreated(t)
	h.postCall(bob, "3").wantQuota(t, "You’ve reached today’s limit of 2 posts. Try again later.", true)
	h.storyCall(bob, "1").wantCreated(t)
	h.storyCall(bob, "2").wantQuota(t, "You’ve reached today’s limit of 1 story. Try again later.", true)
	h.slotCall(bob, "post", 100).wantCreated(t)
	h.slotCall(bob, "post", 100).wantCreated(t)
	// Pending cap of 2.
	h.expect(h.send(bob, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 100}), 429, "RATE_LIMITED")
	h.exec(`UPDATE media_assets SET status='deleted',deleted_at=now() WHERE owner_id=$1`, bob)
	h.slotCall(bob, "post", 100).wantCreated(t)
	h.slotCall(bob, "post", 100).wantQuota(t, uploadLimitMessage, true) // 3 slots a day, 4th
	h.exec(`DELETE FROM media_assets WHERE owner_id=$1`, bob)
	h.slotCall(bob, "post", 5001).wantQuota(t, uploadLimitMessage, true) // bytes per day
	h.addMedia(bob, "post", "ready", 1, 100, 1, "30 hours")
	h.slotCall(bob, "post", 1).wantQuota(t, storageFullMessage, false) // storage

	// Anyone else is Free.
	h.addPosts(cara, 20, "1 hour", false)
	h.postCall(cara, "21st").wantQuota(t, postLimitMessage, true)
	for _, user := range []string{alice, bob, cara} {
		if _, ok := seen.Load(user); !ok {
			t.Fatalf("the resolver was not asked about %s", user)
		}
	}
}

// The chat quotas and the retention of linked blobs come from the entitlements too.
func TestChatBlobLimitsComeFromTheEntitlementsResolver(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(100)
	tiny := domain.Free()
	tiny.BlobsPerDay, tiny.PendingBlobs, tiny.LinkedBlobRetention = 2, 1, 48*time.Hour
	generous := domain.Free()
	generous.BlobsPerDay = 101
	e.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		switch user {
		case alice:
			return tiny
		case bob:
			return generous
		}
		return domain.Free()
	}
	// Alice: one pending slot at a time, two a day, and a linked blob is kept two days.
	first := e.uploaded(alice, e.convo, "full", content)
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 429, "RATE_LIMITED")
	e.exec(`UPDATE chat_blobs SET state='deleted',object_key=NULL,deleted_at=now() WHERE uploader_id=$1 AND state='pending'`, alice)
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 429, "QUOTA")
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, first), 200, "")
	if r := e.row(first); r.expires.Before(time.Now().Add(47*time.Hour)) || r.expires.After(time.Now().Add(48*time.Hour)) {
		t.Fatalf("linked blob expires %v, want in two days", r.expires)
	}
	// Bob has more than the 100 a day Free allows.
	e.exec(`INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,role,size_bytes,ct_sha256,state,deleted_at,expires_at)
 SELECT gen_random_uuid(),$1,$2,'full',100,decode(repeat('00',32),'hex'),'deleted',now(),now()+interval '1 day' FROM generate_series(1,100)`, bob, e.convo)
	e.expect(e.slot(bob, e.convo, "full", content), 201, "")
	e.api.blobSlots.reset(bob)
	e.expect(e.slot(bob, e.convo, "full", content), 429, "QUOTA")
}

// Migration 0024 on top of 0023: the indexes the limits count with, and the declared size column, in a scratch schema.
func TestMigration0024PulseQuotaIndexes(t *testing.T) {
	ctx, db := connectTestDB(t)
	pulse, err := os.ReadFile("../../../../database/migrations/0010_pulse.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../../../../database/migrations/0024_pulse_quota_indexes.sql")
	if err != nil {
		t.Fatal(err)
	}
	table := func(name string) string {
		start := strings.Index(string(pulse), "CREATE TABLE IF NOT EXISTS "+name+" (")
		if start < 0 {
			t.Fatalf("%s not found in 0010", name)
		}
		return string(pulse)[start : start+strings.Index(string(pulse)[start:], "\n);")+3]
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	const owner, media = "019a4000-0000-7000-8000-000000000f31", "019a4000-0000-7000-8000-000000000f32"
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_24`,
		`SET LOCAL search_path = migration_scratch_24`,
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`INSERT INTO users VALUES ('` + owner + `')`,
		table("media_assets"),
		table("posts"),
		table("stories"),
		// A photo that exists before the migration: declared size is unknown, so it takes the stored size.
		`INSERT INTO media_assets(media_id,owner_id,purpose,content_type,size_bytes,upload_key,expires_at) VALUES ('` + media + `','` + owner + `','post','image/jpeg',777,'k',now())`,
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	for run := 0; run < 2; run++ { // applying it again changes nothing
		if _, err = tx.Exec(ctx, string(migration)); err != nil {
			t.Fatalf("migration run %d: %v", run+1, err)
		}
	}
	var declared int64
	if err = tx.QueryRow(ctx, `SELECT declared_bytes FROM media_assets`).Scan(&declared); err != nil || declared != 777 {
		t.Fatalf("backfilled declared_bytes %d (%v)", declared, err)
	}
	if _, err = tx.Exec(ctx, `SAVEPOINT s; INSERT INTO media_assets(media_id,owner_id,purpose,content_type,size_bytes,upload_key,expires_at) VALUES (gen_random_uuid(),'`+owner+`','post','image/jpeg',1,'k',now())`); err == nil {
		t.Fatal("a row without declared_bytes was accepted")
	}
	if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	// Plain (not partial) indexes on the author and creation time.
	for name, columns := range map[string]string{"posts_author_created": "author_id, created_at", "stories_author_created": "author_id, created_at"} {
		var def string
		var partial bool
		if err = tx.QueryRow(ctx, `SELECT pg_get_indexdef(i.indexrelid),i.indpred IS NOT NULL FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname=$1 AND c.relnamespace='migration_scratch_24'::regnamespace`, name).Scan(&def, &partial); err != nil || partial || !strings.Contains(def, "("+columns+")") {
			t.Fatalf("index %s: %q partial=%v (%v)", name, def, partial, err)
		}
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	// The real test database has it applied on top of 0023, and the scratch schema left nothing behind.
	var applied, leaked bool
	if err = db.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0023_chat_blobs.sql') AND EXISTS(SELECT 1 FROM schema_migrations WHERE version='0024_pulse_quota_indexes.sql')`).Scan(&applied); err != nil || !applied {
		t.Fatalf("0024 not applied after 0023: %v", err)
	}
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_24.posts') IS NOT NULL`).Scan(&leaked); err != nil || leaked {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
