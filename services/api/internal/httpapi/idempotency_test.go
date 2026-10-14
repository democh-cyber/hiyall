package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

type idemReply struct {
	status   int
	code     string
	data     map[string]any
	replayed string
}

func (h *socialHarness) withKey(actor, path, key, body string) idemReply {
	h.t.Helper()
	r := httptest.NewRequest("POST", path, bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+actor)
	if key != "" {
		r.Header.Set("Idempotency-Key", key)
	}
	r.RemoteAddr = "127.0.0.1:50000"
	w := httptest.NewRecorder()
	h.api.Handler().ServeHTTP(w, r)
	var env struct {
		Data  map[string]any    `json:"data"`
		Error map[string]string `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &env); err != nil {
		h.t.Fatalf("%s: %s", path, w.Body.String())
	}
	return idemReply{w.Code, env.Error["code"], env.Data, w.Header().Get("Idempotent-Replayed")}
}

func TestPostsStoriesAndEntriesAreIdempotent(t *testing.T) {
	h := newSocialHarness(t)

	// A post: the retry returns the same post, 201, and nothing new is made.
	key := uuid.NewString()
	first := h.withKey(alice, "/v1/posts", key, `{"body":"once","audience":"public"}`)
	if first.status != 201 || first.replayed != "" {
		t.Fatalf("first: %+v", first)
	}
	again := h.withKey(alice, "/v1/posts", key, `{"body":"once","audience":"public"}`)
	if again.status != 201 || again.replayed != "true" || again.data["postId"] != first.data["postId"] || again.data["body"] != "once" {
		t.Fatalf("retry: %+v want the post %v", again, first.data["postId"])
	}
	if n := h.count(`SELECT count(*) FROM posts WHERE author_id=$1 AND body='once'`, alice); n != 1 {
		t.Fatalf("%d posts", n)
	}
	// The same key for another body, another kind of item, or by another member.
	if got := h.withKey(alice, "/v1/posts", key, `{"body":"other","audience":"public"}`); got.status != 422 || got.code != "IDEMPOTENCY_KEY_REUSED" {
		t.Fatalf("other body: %+v", got)
	}
	if got := h.withKey(alice, "/v1/stories", key, `{"body":"once","audience":"public"}`); got.status != 422 || got.code != "IDEMPOTENCY_KEY_REUSED" {
		t.Fatalf("other kind: %+v", got)
	}
	if got := h.withKey(bob, "/v1/posts", key, `{"body":"once","audience":"public"}`); got.status != 201 || got.replayed != "" || got.data["postId"] == first.data["postId"] {
		t.Fatalf("another member's key space: %+v", got)
	}
	// Without a key every request creates; a key that is not a UUID is refused before anything is made.
	h.withKey(alice, "/v1/posts", "", `{"body":"no key","audience":"public"}`)
	h.withKey(alice, "/v1/posts", "", `{"body":"no key","audience":"public"}`)
	if n := h.count(`SELECT count(*) FROM posts WHERE body='no key'`); n != 2 {
		t.Fatalf("%d posts without a key", n)
	}
	for _, bad := range []string{"abc", "{" + uuid.NewString() + "}", "urn:uuid:" + uuid.NewString()} {
		if got := h.withKey(alice, "/v1/posts", bad, `{"body":"bad key","audience":"public"}`); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("key %q: %+v", bad, got)
		}
	}
	if n := h.count(`SELECT count(*) FROM posts WHERE body='bad key'`); n != 0 {
		t.Fatal("a refused key made a post")
	}

	// A story.
	skey := uuid.NewString()
	story := h.withKey(alice, "/v1/stories", skey, `{"body":"hello","audience":"public"}`)
	storyAgain := h.withKey(alice, "/v1/stories", skey, `{"body":"hello","audience":"public"}`)
	if story.status != 201 || storyAgain.status != 201 || storyAgain.replayed != "true" || story.data["storyId"] != storyAgain.data["storyId"] {
		t.Fatalf("story: %+v %+v", story, storyAgain)
	}
	if n := h.count(`SELECT count(*) FROM stories WHERE author_id=$1`, alice); n != 1 {
		t.Fatalf("%d stories", n)
	}

	// A space entry; the key is scoped to the space.
	id := makeSpace(h, alice, "community", "public", 10, nil)
	ekey := uuid.NewString()
	entry := h.withKey(alice, "/v1/spaces/"+id+"/entries", ekey, `{"body":"hi"}`)
	entryAgain := h.withKey(alice, "/v1/spaces/"+id+"/entries", ekey, `{"body":"hi"}`)
	if entry.status != 201 || entryAgain.status != 201 || entryAgain.replayed != "true" || entry.data["entryId"] != entryAgain.data["entryId"] {
		t.Fatalf("entry: %+v %+v", entry, entryAgain)
	}
	if n := h.count(`SELECT count(*) FROM space_entries WHERE space_id=$1`, id); n != 1 {
		t.Fatalf("%d entries", n)
	}
	other := makeSpace(h, alice, "community", "public", 10, nil)
	if got := h.withKey(alice, "/v1/spaces/"+other+"/entries", ekey, `{"body":"hi"}`); got.status != 422 || got.code != "IDEMPOTENCY_KEY_REUSED" {
		t.Fatalf("another space: %+v", got)
	}

	// A refused create leaves no key behind: the retry, once the cause is gone, is a fresh attempt.
	rkey := uuid.NewString()
	if got := h.withKey(alice, "/v1/posts", rkey, `{"body":"","audience":"public"}`); got.status != 422 {
		t.Fatalf("invalid post: %+v", got)
	}
	if n := h.count(`SELECT count(*) FROM idempotency_keys WHERE key=$1`, rkey); n != 0 {
		t.Fatal("a refused request kept its key")
	}
	if got := h.withKey(alice, "/v1/posts", rkey, `{"body":"fixed","audience":"public"}`); got.status != 201 || got.replayed != "" {
		t.Fatalf("after the fix: %+v", got)
	}
}

// Two requests with the same key at once create one post; both answer 201 with the same id.
func TestConcurrentDuplicatesCreateOnce(t *testing.T) {
	h := newSocialHarness(t)
	key := uuid.NewString()
	var wg sync.WaitGroup
	replies := make([]idemReply, 6)
	for i := range replies {
		wg.Add(1)
		go func() {
			defer wg.Done()
			replies[i] = h.withKey(alice, "/v1/posts", key, `{"body":"race","audience":"public"}`)
		}()
	}
	wg.Wait()
	replayed := 0
	for _, got := range replies {
		if got.status != 201 || got.data["postId"] != replies[0].data["postId"] {
			t.Fatalf("%+v vs %+v", got, replies[0])
		}
		if got.replayed == "true" {
			replayed++
		}
	}
	if replayed != len(replies)-1 {
		t.Fatalf("%d of %d were replays", replayed, len(replies))
	}
	if n := h.count(`SELECT count(*) FROM posts WHERE body='race'`); n != 1 {
		t.Fatalf("%d posts", n)
	}
}

func TestIdempotencyKeysExpireAfterADay(t *testing.T) {
	h := newSocialHarness(t)
	for _, age := range []string{"25 hours", "23 hours", "3 days"} {
		h.exec(`INSERT INTO idempotency_keys(user_id,key,scope,request_hash,ref_id,created_at) VALUES($1,gen_random_uuid(),'post','\x00',gen_random_uuid(),now()-$2::interval)`, alice, age)
	}
	n, err := h.db.PurgeIdempotencyKeys(h.ctx, 24*time.Hour, 1)
	if err != nil || n != 1 {
		t.Fatalf("batch of one: %d %v", n, err)
	}
	if n, err = h.db.PurgeIdempotencyKeys(h.ctx, 24*time.Hour, 100); err != nil || n != 1 {
		t.Fatalf("the rest: %d %v", n, err)
	}
	if left := h.count(`SELECT count(*) FROM idempotency_keys`); left != 1 {
		t.Fatalf("%d keys left, want the 23 hour one", left)
	}
}
