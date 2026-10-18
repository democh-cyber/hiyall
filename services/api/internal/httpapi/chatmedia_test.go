package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// blobEnv is two members with a device each, an active conversation, and a Memory chat store.
type blobEnv struct {
	*socialHarness
	chat          *media.Memory
	a, b          testDevice
	convo         string
	aPath, bPath  string
	messagesPathA string
}

// newBlobEnv sets alice and bob up in one conversation. Neither has replied and they are not friends, so
// nobody may send an image yet; env.open() lifts that.
func newBlobEnv(t *testing.T) *blobEnv {
	t.Helper()
	h := newSocialHarness(t)
	e := &blobEnv{socialHarness: h, chat: media.NewMemory()}
	h.api.ChatMedia = e.chat
	h.policy(alice, "messagesFrom", "everyone")
	h.policy(bob, "messagesFrom", "everyone")
	e.a, e.b = h.register(alice), h.register(bob)
	e.convo = h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data["conversationId"].(string)
	e.messagesPathA = "/v1/conversations/" + e.convo + "/messages"
	return e
}

// open makes images allowed in e.convo: bob replies to a first message.
func (e *blobEnv) open() {
	e.t.Helper()
	e.expect(e.send(alice, "POST", e.messagesPathA, message(e.a, e.b)), 200, "")
	e.expect(e.send(bob, "POST", e.messagesPathA, message(e.b, e.a)), 200, "")
}

func ctOf(data []byte) string {
	sum := sha256.Sum256(data)
	return base64.StdEncoding.EncodeToString(sum[:])
}

func noise(n int) []byte {
	data := make([]byte, n)
	_, _ = rand.Read(data)
	return data
}

// slot asks for an upload slot for content.
func (e *blobEnv) slot(user, convo, role string, content []byte) reply {
	e.t.Helper()
	return e.send(user, "POST", "/v1/conversations/"+convo+"/blobs", map[string]any{"role": role, "sizeBytes": len(content), "ctSha256": ctOf(content)})
}

// put stores the bytes where a slot's signed URL points, as the object store would after a valid PUT.
func (e *blobEnv) put(slot reply, content []byte) {
	e.t.Helper()
	key := strings.TrimPrefix(slot.data["uploadUrl"].(string), "memory://put/")
	if err := e.chat.Put(e.ctx, key, content, "application/octet-stream"); err != nil {
		e.t.Fatal(err)
	}
}

// uploaded runs slot, PUT and complete, and returns the blob id.
func (e *blobEnv) uploaded(user, convo, role string, content []byte) string {
	e.t.Helper()
	got := e.expect(e.slot(user, convo, role, content), 201, "")
	e.put(got, content)
	id := got.data["blobId"].(string)
	e.expect(e.call(user, "POST", "/v1/blobs/"+id+"/complete"), 200, "")
	return id
}

func (e *blobEnv) sendBlobs(user string, from, to testDevice, convo string, ids ...string) reply {
	e.t.Helper()
	m := message(from, to)
	if ids != nil {
		m["blobIds"] = ids
	}
	return e.send(user, "POST", "/v1/conversations/"+convo+"/messages", m)
}

type blobRow struct {
	state, role                 string
	key, message, held          *string
	size                        int64
	expires                     time.Time
	uploader, conversation, sha string
}

func (e *blobEnv) row(id string) blobRow {
	e.t.Helper()
	var r blobRow
	err := e.db.Pool.QueryRow(e.ctx, `SELECT state,role,object_key,message_id::text,held_report_id::text,size_bytes,expires_at,uploader_id::text,conversation_id::text,encode(ct_sha256,'base64') FROM chat_blobs WHERE blob_id=$1`, id).
		Scan(&r.state, &r.role, &r.key, &r.message, &r.held, &r.size, &r.expires, &r.uploader, &r.conversation, &r.sha)
	if err != nil {
		e.t.Fatalf("blob %s: %v", id, err)
	}
	return r
}

func (e *blobEnv) count(where string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT count(*) FROM chat_blobs WHERE `+where, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

func (e *blobEnv) url(user, convo, id string) reply {
	e.t.Helper()
	e.api.blobURLs.reset(user)
	return e.call(user, "GET", "/v1/conversations/"+convo+"/blobs/"+id+"/url")
}

func TestChatBlobEndToEnd(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(5000)

	// The slot: a signed PUT whose headers carry the content type and the checksum the store will enforce.
	made := e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	id := made.data["blobId"].(string)
	if !domain.IsID(id) || made.data["method"] != "PUT" || made.data["uploadUrl"] != "memory://put/chat/"+id {
		t.Fatalf("slot %v", made.data)
	}
	headers := made.data["headers"].(map[string]any)
	if len(headers) != 2 || headers["Content-Type"] != "application/octet-stream" || headers["x-amz-checksum-sha256"] != ctOf(content) {
		t.Fatalf("headers %v", headers)
	}
	// The signed URL pins the declared ciphertext size; it is not a header the client sets.
	if e.chat.Signed["chat/"+id] != 5000 {
		t.Fatalf("signed size %d, want 5000", e.chat.Signed["chat/"+id])
	}
	if at, err := time.Parse(time.RFC3339Nano, made.data["expiresAt"].(string)); err != nil || time.Until(at) < 14*time.Minute || time.Until(at) > 16*time.Minute {
		t.Fatalf("expiresAt %v %v", made.data["expiresAt"], err)
	}
	if r := e.row(id); r.state != "pending" || r.role != "full" || r.size != 5000 || r.sha != ctOf(content) || r.message != nil || r.uploader != alice || r.conversation != e.convo ||
		r.key == nil || *r.key != "chat/"+id || time.Until(r.expires) > time.Hour || time.Until(r.expires) < 59*time.Minute {
		t.Fatalf("pending row %+v", r)
	}
	// Nothing can be downloaded or sent before it is complete.
	e.expect(e.url(alice, e.convo, id), 409, "BLOB_NOT_READY")
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id), 409, "BLOB_NOT_READY")

	// Completing needs the object; then it is uploaded, still unattached and expiring in an hour.
	e.expect(e.call(alice, "POST", "/v1/blobs/"+id+"/complete"), 409, "BLOB_NOT_READY")
	e.put(made, content)
	done := e.expect(e.call(alice, "POST", "/v1/blobs/"+id+"/complete"), 200, "").data
	if done["blobId"] != id || done["state"] != "uploaded" || len(done) != 2 {
		t.Fatalf("complete %v", done)
	}
	if again := e.expect(e.call(alice, "POST", "/v1/blobs/"+id+"/complete"), 200, "").data; again["state"] != "uploaded" {
		t.Fatalf("second complete %v", again)
	}
	if r := e.row(id); r.state != "uploaded" || r.message != nil || time.Until(r.expires) > time.Hour {
		t.Fatalf("uploaded row %+v", r)
	}

	// Sending claims it: linked to the message and kept for 30 days from now.
	thumb := e.uploaded(alice, e.convo, "thumb", noise(300))
	sent := e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id, thumb), 200, "").data
	for _, blob := range []string{id, thumb} {
		r := e.row(blob)
		if r.message == nil || *r.message != sent["messageId"] || r.state != "uploaded" || time.Until(r.expires) < 29*24*time.Hour+23*time.Hour || time.Until(r.expires) > 30*24*time.Hour {
			t.Fatalf("linked row %+v (message %v)", r, sent["messageId"])
		}
	}

	// The peer and the uploader each get a short-lived signed GET with the ciphertext size.
	for _, user := range []string{bob, alice} {
		status, header, body := e.full(user, "GET", "/v1/conversations/"+e.convo+"/blobs/"+id+"/url", "", "")
		if status != 200 || header.Get("Cache-Control") != "no-store" {
			t.Fatalf("%s: %d %v", user, status, header)
		}
		var got struct{ Data map[string]any }
		if err := json.Unmarshal(body, &got); err != nil || got.Data["url"] != "memory://get/chat/"+id || got.Data["sizeBytes"] != float64(5000) || len(got.Data) != 3 {
			t.Fatalf("%s: url %s", user, body)
		}
		if at, err := time.Parse(time.RFC3339Nano, got.Data["expiresAt"].(string)); err != nil || time.Until(at) < 4*time.Minute || time.Until(at) > 5*time.Minute {
			t.Fatalf("download expiry %v %v", got.Data["expiresAt"], err)
		}
		e.api.blobURLs.reset(user)
	}
	// Slots and completions are no-store too.
	if _, header, _ := e.full(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", "application/json", `{}`); header.Get("Cache-Control") != "no-store" {
		t.Fatal("slot response is cacheable")
	}

	// The envelopes and inbox are unchanged: ciphertext only, no blob fields.
	for _, item := range items(e.ok(bob, "GET", "/v1/devices/"+e.b.id+"/inbox")) {
		for field := range item {
			if strings.Contains(strings.ToLower(field), "blob") {
				t.Fatalf("inbox leaks %s", field)
			}
		}
	}

	// The uploader can delete; the peer then gets 410, and a second delete is fine.
	e.expect(e.call(bob, "DELETE", "/v1/blobs/"+id), 404, "NOT_FOUND")
	if got := e.expect(e.call(alice, "DELETE", "/v1/blobs/"+id), 200, "").data; got["deleted"] != true {
		t.Fatalf("delete %v", got)
	}
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+id), 200, "")
	e.expect(e.url(bob, e.convo, id), 410, "BLOB_EXPIRED")
	if r := e.row(id); r.state != "deleted" || r.key != nil {
		t.Fatalf("deleted row %+v", r)
	}
	if e.chat.Has("chat/" + id) {
		t.Fatal("object kept after delete")
	}
}

func TestChatBlobAuthorization(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	// A second conversation, alice and cara, with its own blob.
	carol := e.register(cara)
	other := e.expect(e.send(alice, "POST", "/v1/conversations", map[string]string{"userId": cara}), 200, "").data["conversationId"].(string)
	e.expect(e.send(cara, "POST", "/v1/conversations/"+other+"/messages", message(carol, e.a)), 200, "")
	content := noise(1000)
	id := e.uploaded(alice, e.convo, "full", content)
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id), 200, "")
	pending := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
	staged := e.uploaded(alice, e.convo, "thumb", noise(200)) // uploaded but not sent

	// Slots: only members of the conversation.
	e.expect(e.slot(cara, e.convo, "full", content), 404, "NOT_FOUND")
	e.expect(e.slot(bob, other, "full", content), 404, "NOT_FOUND")
	e.expect(e.slot(alice, uuid.NewString(), "full", content), 404, "NOT_FOUND")
	e.expect(e.slot(bob, e.convo, "full", content), 201, "")

	// Downloads: both members, nobody else, not through another conversation, not unsent blobs for the peer.
	e.expect(e.url(alice, e.convo, id), 200, "")
	e.expect(e.url(bob, e.convo, id), 200, "")
	e.expect(e.url(cara, e.convo, id), 404, "NOT_FOUND")
	e.expect(e.url(alice, other, id), 404, "NOT_FOUND")
	e.expect(e.url(cara, other, id), 404, "NOT_FOUND")
	e.expect(e.url(alice, e.convo, uuid.NewString()), 404, "NOT_FOUND")
	e.expect(e.url(bob, e.convo, staged), 404, "NOT_FOUND")
	e.expect(e.url(bob, e.convo, pending), 404, "NOT_FOUND")
	e.expect(e.url(alice, e.convo, staged), 409, "BLOB_NOT_READY")
	e.expect(e.url(alice, e.convo, pending), 409, "BLOB_NOT_READY")
	// Ids are canonical only.
	e.expect(e.call(alice, "GET", "/v1/conversations/"+e.convo+"/blobs/"+strings.ToUpper(id)+"/url"), 404, "NOT_FOUND")
	e.expect(e.call(alice, "POST", "/v1/blobs/"+strings.ToUpper(pending)+"/complete"), 404, "NOT_FOUND")
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+strings.ReplaceAll(pending, "-", "")), 404, "NOT_FOUND")

	// Complete and delete belong to the uploader.
	e.expect(e.call(bob, "POST", "/v1/blobs/"+pending+"/complete"), 404, "NOT_FOUND")
	e.expect(e.call(cara, "POST", "/v1/blobs/"+pending+"/complete"), 404, "NOT_FOUND")
	e.expect(e.call(alice, "POST", "/v1/blobs/"+uuid.NewString()+"/complete"), 404, "NOT_FOUND")
	e.expect(e.call(cara, "DELETE", "/v1/blobs/"+id), 404, "NOT_FOUND")
	e.expect(e.call(bob, "DELETE", "/v1/blobs/"+staged), 404, "NOT_FOUND")
	if e.row(staged).state != "uploaded" {
		t.Fatal("a stranger deleted a blob")
	}

	// Muting or restricting the sender never blocks a download.
	e.ok(bob, "POST", "/v1/users/"+alice+"/mute")
	e.ok(bob, "POST", "/v1/users/"+alice+"/restrict")
	e.expect(e.url(bob, e.convo, id), 200, "")
	e.ok(bob, "DELETE", "/v1/users/"+alice+"/mute")
	e.ok(bob, "DELETE", "/v1/users/"+alice+"/restrict")

	// Expired blobs are gone for members (410) and invisible to others.
	e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 second' WHERE blob_id=$1`, id)
	e.expect(e.url(bob, e.convo, id), 410, "BLOB_EXPIRED")
	e.expect(e.url(alice, e.convo, id), 410, "BLOB_EXPIRED")
	e.expect(e.url(cara, e.convo, id), 404, "NOT_FOUND")
	e.exec(`UPDATE chat_blobs SET expires_at=now()+interval '1 day' WHERE blob_id=$1`, id)
	e.expect(e.url(bob, e.convo, id), 200, "")
	// A pending slot that expired cannot be completed.
	e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 second' WHERE blob_id=$1`, pending)
	e.expect(e.call(alice, "POST", "/v1/blobs/"+pending+"/complete"), 410, "BLOB_EXPIRED")
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")

	// A closed conversation is 404 everywhere, for members too.
	e.exec(`UPDATE conversations SET status='closed' WHERE conversation_id=$1`, e.convo)
	e.expect(e.slot(alice, e.convo, "full", content), 404, "NOT_FOUND")
	e.expect(e.url(bob, e.convo, id), 404, "NOT_FOUND")
	e.expect(e.url(alice, e.convo, id), 404, "NOT_FOUND")
	e.expect(e.call(alice, "POST", "/v1/blobs/"+staged+"/complete"), 404, "NOT_FOUND")
	e.exec(`UPDATE conversations SET status='active' WHERE conversation_id=$1`, e.convo)
	e.expect(e.url(bob, e.convo, id), 200, "")
}

// Blocks and age bands bar a pair: every blob route answers 404 in both directions, while the conversation
// row is untouched (age bands) or closed (blocks).
func TestChatBlobBlockedAndAgeBarredPairs(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(e *blobEnv)
		undo  func(e *blobEnv)
	}{
		{"alice blocked bob", func(e *blobEnv) { e.ok(alice, "POST", "/v1/users/"+bob+"/block") }, func(e *blobEnv) { e.ok(alice, "DELETE", "/v1/users/"+bob+"/block") }},
		{"bob blocked alice", func(e *blobEnv) { e.ok(bob, "POST", "/v1/users/"+alice+"/block") }, func(e *blobEnv) { e.ok(bob, "DELETE", "/v1/users/"+alice+"/block") }},
		{"bob is a minor", func(e *blobEnv) { e.setAge(bob, 15) }, func(e *blobEnv) { e.setAge(bob, 30) }},
		{"alice is a minor", func(e *blobEnv) { e.setAge(alice, 16) }, func(e *blobEnv) { e.setAge(alice, 30) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newBlobEnv(t)
			e.open()
			content := noise(500)
			id := e.uploaded(alice, e.convo, "full", content)
			e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id), 200, "")
			mine := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
			theirs := e.expect(e.slot(bob, e.convo, "full", content), 201, "").data["blobId"].(string)
			tc.setup(e)
			for _, user := range []string{alice, bob} {
				e.expect(e.slot(user, e.convo, "full", content), 404, "NOT_FOUND")
				e.expect(e.url(user, e.convo, id), 404, "NOT_FOUND")
			}
			e.expect(e.call(alice, "POST", "/v1/blobs/"+mine+"/complete"), 404, "NOT_FOUND")
			e.expect(e.call(bob, "POST", "/v1/blobs/"+theirs+"/complete"), 404, "NOT_FOUND")
			tc.undo(e)
			if strings.Contains(tc.name, "blocked") {
				// A lifted block leaves the conversation closed, as for messages.
				e.expect(e.slot(alice, e.convo, "full", content), 404, "NOT_FOUND")
				return
			}
			e.api.blobSlots.reset(alice)
			e.expect(e.slot(alice, e.convo, "full", content), 201, "")
			e.expect(e.url(bob, e.convo, id), 200, "")
		})
	}
}

func TestChatBlobGateNeedsReplyOrFriendship(t *testing.T) {
	e := newBlobEnv(t)
	content := noise(400)
	// Strangers: neither has written and they are not friends.
	e.expect(e.slot(alice, e.convo, "full", content), 403, "ATTACHMENTS_NOT_ALLOWED")
	e.expect(e.slot(bob, e.convo, "full", content), 403, "ATTACHMENTS_NOT_ALLOWED")
	// Alice's own message is not a reply from bob.
	e.expect(e.send(alice, "POST", e.messagesPathA, message(e.a, e.b)), 200, "")
	e.expect(e.slot(alice, e.convo, "full", content), 403, "ATTACHMENTS_NOT_ALLOWED")
	e.expect(e.slot(bob, e.convo, "full", content), 201, "") // alice has written to bob, so bob may answer with a photo
	// Bob replies: now alice may send images too.
	e.expect(e.send(bob, "POST", e.messagesPathA, message(e.b, e.a)), 200, "")
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")

	// Friends skip the reply: alice and cara.
	carol := e.register(cara)
	other := e.expect(e.send(alice, "POST", "/v1/conversations", map[string]string{"userId": cara}), 200, "").data["conversationId"].(string)
	e.expect(e.slot(alice, other, "full", content), 403, "ATTACHMENTS_NOT_ALLOWED")
	e.ok(alice, "POST", "/v1/users/"+cara+"/friend-requests")
	e.expect(e.slot(alice, other, "full", content), 403, "ATTACHMENTS_NOT_ALLOWED") // a pending request is not a friendship
	e.ok(cara, "POST", "/v1/users/"+alice+"/friend-requests")
	id := e.uploaded(alice, other, "full", content)
	e.expect(e.slot(cara, other, "full", content), 201, "")
	// The gate is checked again when the message is sent: unfriending in between stops it.
	e.ok(alice, "DELETE", "/v1/users/"+cara+"/friendship")
	m := message(e.a, carol)
	m["blobIds"] = []string{id}
	e.expect(e.send(alice, "POST", "/v1/conversations/"+other+"/messages", m), 403, "ATTACHMENTS_NOT_ALLOWED")
	if e.row(id).message != nil || e.count(`message_id IS NOT NULL`) != 0 {
		t.Fatal("blob linked despite the refusal")
	}
	// A text message still goes through.
	e.expect(e.send(alice, "POST", "/v1/conversations/"+other+"/messages", message(e.a, carol)), 200, "")

	// canMessage still applies on top: a member who allows nobody gets no photo slots from strangers.
	e.policy(cara, "messagesFrom", "nobody")
	e.expect(e.slot(alice, other, "full", content), 403, "MESSAGES_NOT_ALLOWED")
}

func TestChatBlobValidationAndSizeCaps(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	path := "/v1/conversations/" + e.convo + "/blobs"
	hash := ctOf(noise(10))
	body := func(role string, size any, sha any) map[string]any {
		return map[string]any{"role": role, "sizeBytes": size, "ctSha256": sha}
	}
	post := func(payload any) reply {
		e.api.blobSlots.reset(alice)
		return e.send(alice, "POST", path, payload)
	}
	// Caps per role: full 4 MiB, thumb 256 KiB.
	e.expect(post(body("full", 4<<20, hash)), 201, "")
	e.expect(post(body("full", 4<<20+1, hash)), 413, "TOO_LARGE")
	e.expect(post(body("thumb", 256<<10, hash)), 201, "")
	e.expect(post(body("thumb", 256<<10+1, hash)), 413, "TOO_LARGE")
	e.expect(post(body("full", 32, hash)), 201, "")
	e.expect(post(body("full", 31, hash)), 422, "VALIDATION")
	for _, size := range []any{0, -5, 1.5, "1000", nil, true, json.RawMessage("1e3"), []int{1}} {
		if got := post(body("full", size, hash)); got.status != 422 {
			t.Fatalf("size %v: %d %s", size, got.status, got.code)
		}
	}
	for _, role := range []string{"", "poster", "audio", "FULL", "Full", "VIDEO", "voice "} {
		e.expect(post(body(role, 1000, hash)), 422, "VALIDATION")
	}
	good := ctOf(noise(100))
	raw, _ := base64.StdEncoding.DecodeString(good)
	for name, sha := range map[string]any{
		"urlsafe":  strings.NewReplacer("+", "-", "/", "_").Replace(base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xfb, 0xff}, 16))),
		"unpadded": strings.TrimRight(good, "="), "short": base64.StdEncoding.EncodeToString(raw[:16]), "long": base64.StdEncoding.EncodeToString(append(raw, 1)),
		"empty": "", "null": nil, "number": 5, "garbage": "not base64!", "hex": fmt.Sprintf("%x", raw),
	} {
		if got := post(body("full", 1000, sha)); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("hash %s: %d %s", name, got.status, got.code)
		}
	}
	e.expect(post(map[string]any{"role": "full", "sizeBytes": 1000}), 422, "VALIDATION")
	e.expect(post(map[string]any{"role": "full", "sizeBytes": 1000, "ctSha256": hash, "messageId": uuid.NewString()}), 422, "VALIDATION")
	e.expect(post(map[string]any{}), 422, "VALIDATION")
	// The body must be JSON.
	e.api.blobSlots.reset(alice)
	if status, _, _ := e.full(alice, "POST", path, "text/plain", "{}"); status != 422 {
		t.Fatalf("non-JSON body: %d", status)
	}
}

func TestChatBlobQuotasDoNotResetWhenBlobsAreDeleted(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(100)
	fill := func(n int, size int64, state string) {
		e.exec(`INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,role,size_bytes,ct_sha256,state,object_key,deleted_at,expires_at)
 SELECT gen_random_uuid(),$1,$2,'full',$3,decode(repeat('00',32),'hex'),$4,CASE WHEN $4='deleted' THEN NULL ELSE 'chat/x' END,CASE WHEN $4='deleted' THEN now() END,now()+interval '1 day' FROM generate_series(1,$5::int)`,
			alice, e.convo, size, state, n)
	}
	retryAfter := func(user string) int {
		e.api.blobSlots.reset(user)
		status, header, _ := e.full(user, "POST", "/v1/conversations/"+e.convo+"/blobs", "application/json", fmt.Sprintf(`{"role":"full","sizeBytes":%d,"ctSha256":%q}`, len(content), ctOf(content)))
		if status != 429 {
			t.Fatalf("status %d, want 429", status)
		}
		n, err := strconv.Atoi(header.Get("Retry-After"))
		if err != nil {
			t.Fatalf("Retry-After %q", header.Get("Retry-After"))
		}
		return n
	}

	// Count: 99 deleted blobs and one real one that is deleted again make 100 in the window.
	fill(99, 100, "deleted")
	id := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+id), 200, "")
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 429, "QUOTA")
	// The peer's budget is separate.
	e.expect(e.slot(bob, e.convo, "full", content), 201, "")
	// Deleting more changes nothing; the oldest blob leaving the window does. The wait is until it does.
	e.exec(`UPDATE chat_blobs SET created_at=now()-interval '23 hours' WHERE blob_id=(SELECT blob_id FROM chat_blobs WHERE uploader_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	if wait := retryAfter(alice); wait < 3500 || wait > 3601 {
		t.Fatalf("Retry-After %d, want about an hour", wait)
	}
	e.exec(`UPDATE chat_blobs SET created_at=now()-interval '25 hours' WHERE blob_id=(SELECT blob_id FROM chat_blobs WHERE uploader_id=$1 ORDER BY created_at LIMIT 1)`, alice)
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")

	// Bytes: 300 MiB in the window, however much of it was deleted, leaves no room.
	e.exec(`DELETE FROM chat_blobs`)
	e.api.blobSlots.reset(alice)
	fill(75, 4<<20, "deleted")
	e.expect(e.slot(alice, e.convo, "thumb", content), 429, "QUOTA")
	e.exec(`UPDATE chat_blobs SET size_bytes=size_bytes-1 WHERE blob_id=(SELECT blob_id FROM chat_blobs LIMIT 1)`)
	e.api.blobSlots.reset(alice)
	// One byte of room is not enough for 100 bytes.
	e.expect(e.slot(alice, e.convo, "full", content), 429, "QUOTA")
	e.exec(`UPDATE chat_blobs SET size_bytes=size_bytes-1000 WHERE blob_id=(SELECT blob_id FROM chat_blobs LIMIT 1)`)
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	// The bytes limit also leaves the wait to the blobs that must leave the window: here the oldest, 22 hours old.
	e.exec(`DELETE FROM chat_blobs`)
	fill(75, 4<<20, "deleted")
	e.exec(`UPDATE chat_blobs SET created_at=now()-interval '1 hour'`)
	e.exec(`UPDATE chat_blobs SET created_at=now()-interval '22 hours' WHERE blob_id=(SELECT blob_id FROM chat_blobs LIMIT 1)`)
	if wait := retryAfter(alice); wait < 2*3600-120 || wait > 2*3600+5 {
		t.Fatalf("bytes Retry-After %d, want about 2 hours", wait)
	}
	e.exec(`UPDATE chat_blobs SET created_at=now()-interval '25 hours' WHERE created_at<now()-interval '21 hours'`)
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")
}

func TestChatBlobPendingCap(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(100)
	var first string
	for i := 0; i < domain.Free().PendingBlobs; i++ {
		id := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
		if first == "" {
			first = id
		}
	}
	over := e.send(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", map[string]any{"role": "full", "sizeBytes": 100, "ctSha256": ctOf(content)})
	e.expect(over, 429, "RATE_LIMITED")
	_, header, _ := e.full(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", "application/json", fmt.Sprintf(`{"role":"full","sizeBytes":100,"ctSha256":%q}`, ctOf(content)))
	if n, err := strconv.Atoi(header.Get("Retry-After")); err != nil || n < 1 || n > 3600 {
		t.Fatalf("Retry-After %q", header.Get("Retry-After"))
	}
	// Another member has their own cap, and completing one frees a slot.
	e.expect(e.slot(bob, e.convo, "full", content), 201, "")
	e.chat.Put(e.ctx, "chat/"+first, content, "")
	e.expect(e.call(alice, "POST", "/v1/blobs/"+first+"/complete"), 200, "")
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	// Expired slots stop counting.
	e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 minute' WHERE uploader_id=$1 AND state='pending'`, alice)
	e.api.blobSlots.reset(alice)
	e.expect(e.slot(alice, e.convo, "full", content), 201, "")
}

func TestChatBlobRateLimits(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	// Slot creation, completion and delete share a budget; refused bodies count too.
	limited := 0
	for i := 0; i < 80; i++ {
		got := e.send(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", map[string]any{})
		if got.status == 429 {
			limited++
			e.expect(got, 429, "RATE_LIMITED")
		} else if got.status != 422 {
			t.Fatalf("status %d", got.status)
		}
	}
	if limited == 0 {
		t.Fatal("slot requests never limited")
	}
	e.expect(e.call(alice, "POST", "/v1/blobs/"+uuid.NewString()+"/complete"), 429, "RATE_LIMITED")
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+uuid.NewString()), 429, "RATE_LIMITED")
	// Another member is unaffected, and the download budget is separate.
	e.expect(e.slot(bob, e.convo, "full", noise(100)), 201, "")
	e.expect(e.call(alice, "GET", "/v1/conversations/"+e.convo+"/blobs/"+uuid.NewString()+"/url"), 404, "NOT_FOUND")
	limited = 0
	for i := 0; i < 120; i++ {
		if e.call(alice, "GET", "/v1/conversations/"+e.convo+"/blobs/"+uuid.NewString()+"/url").status == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("download URLs never limited")
	}
	status, header, _ := e.full(alice, "GET", "/v1/conversations/"+e.convo+"/blobs/"+uuid.NewString()+"/url", "", "")
	if status != 429 || header.Get("Retry-After") == "" {
		t.Fatalf("%d %v", status, header)
	}
}

func TestChatBlobCompleteChecksTheStoredSize(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	// A different size than declared: the object is removed, the slot is dead and a new one must be asked for.
	content := noise(200)
	made := e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	id := made.data["blobId"].(string)
	e.put(made, noise(199))
	e.expect(e.call(alice, "POST", "/v1/blobs/"+id+"/complete"), 409, "BLOB_SIZE_MISMATCH")
	if e.chat.Has("chat/"+id) || e.row(id).state != "deleted" || e.row(id).key != nil {
		t.Fatalf("mismatched upload kept: %+v", e.row(id))
	}
	e.expect(e.call(alice, "POST", "/v1/blobs/"+id+"/complete"), 410, "BLOB_EXPIRED")
	// The quota still counts it.
	if n := e.count(`uploader_id=$1`, alice); n != 1 {
		t.Fatalf("rows %d", n)
	}
	// Larger than declared fails the same way.
	made = e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	e.put(made, noise(201))
	e.expect(e.call(alice, "POST", "/v1/blobs/"+made.data["blobId"].(string)+"/complete"), 409, "BLOB_SIZE_MISMATCH")

	// A matching upload completes, also when the store reports a size (a large object the test does not allocate).
	big := e.expect(e.slot(alice, e.convo, "full", noise(100)), 201, "")
	bigID := big.data["blobId"].(string)
	e.chat.Objects["chat/"+bigID] = []byte("small")
	e.chat.Sizes["chat/"+bigID] = 100
	e.expect(e.call(alice, "POST", "/v1/blobs/"+bigID+"/complete"), 200, "")

	// Deleting a pending slot, then completing it, is gone.
	gone := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+gone), 200, "")
	e.expect(e.call(alice, "POST", "/v1/blobs/"+gone+"/complete"), 410, "BLOB_EXPIRED")
}

func TestSendLinksBlobsAtomically(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	carol := e.register(cara)
	other := e.expect(e.send(alice, "POST", "/v1/conversations", map[string]string{"userId": cara}), 200, "").data["conversationId"].(string)
	e.expect(e.send(cara, "POST", "/v1/conversations/"+other+"/messages", message(carol, e.a)), 200, "")
	messages := func() int {
		var n int
		if err := e.db.Pool.QueryRow(e.ctx, `SELECT count(*) FROM messages`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	content := noise(300)
	good := e.uploaded(alice, e.convo, "full", content)
	good2 := e.uploaded(alice, e.convo, "thumb", content)
	theirs := e.uploaded(bob, e.convo, "full", content)
	elsewhere := e.uploaded(alice, other, "full", content)
	unfinished := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
	expired := e.uploaded(alice, e.convo, "full", content)
	e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 second' WHERE blob_id=$1`, expired)
	before := messages()

	// Every refusal is 409 BLOB_NOT_READY (unknown and foreign look alike) and stores nothing, not even the
	// blobs that were fine.
	for name, ids := range map[string][]string{
		"unknown":         {good, uuid.NewString()},
		"foreign":         {good, theirs},
		"other chat":      {good, elsewhere},
		"not completed":   {good, unfinished},
		"expired":         {good, expired},
		"only unknown":    {uuid.NewString()},
		"only foreign":    {theirs},
		"only other":      {elsewhere},
		"only unfinished": {unfinished},
	} {
		e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, ids...), 409, "BLOB_NOT_READY")
		if messages() != before || e.row(good).message != nil {
			t.Fatalf("%s: a refused send left state behind", name)
		}
	}
	if n := len(items(e.ok(bob, "GET", "/v1/devices/"+e.b.id+"/inbox"))); n != 1 {
		t.Fatalf("a refused message reached the inbox (%d items)", n)
	}

	// Malformed id lists are 422 and checked before any state is read.
	for name, ids := range map[string][]any{
		"duplicates": {good, good},
		"too many":   {good, good2, theirs, elsewhere, unfinished},
		"upper case": {strings.ToUpper(good)},
		"no hyphens": {strings.ReplaceAll(good, "-", "")},
		"not an id":  {"nope"},
		"number":     {5},
	} {
		m := message(e.a, e.b)
		m["blobIds"] = ids
		if got := e.send(alice, "POST", e.messagesPathA, m); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("%s: %d %s", name, got.status, got.code)
		}
	}
	for _, value := range []any{nil, []string{}} {
		m := message(e.a, e.b)
		m["blobIds"] = value
		e.expect(e.send(alice, "POST", e.messagesPathA, m), 200, "")
	}

	// Four is the most one message can carry.
	four := []string{good, good2, e.uploaded(alice, e.convo, "full", content), e.uploaded(alice, e.convo, "thumb", content)}
	first := e.sendBlobs(alice, e.a, e.b, e.convo, four...)
	e.expect(first, 200, "")
	messageID := first.data["messageId"].(string)
	linked := e.row(good)
	if linked.message == nil || *linked.message != messageID {
		t.Fatalf("not linked: %+v", linked)
	}
	if e.count(`message_id=$1`, messageID) != 4 {
		t.Fatal("not every blob linked")
	}

	// A claimed blob cannot go in a second message, nor can a stranger's or the peer's claim it.
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, good), 409, "BLOB_NOT_READY")
	e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, good), 409, "BLOB_NOT_READY")
	if *e.row(good).message != messageID {
		t.Fatal("the blob moved to another message")
	}

	// A retry with the same messageId is idempotent: same answer, no relinking, whether or not the blobs
	// are still available and whatever ids the retry carries.
	raw := map[string]any{"messageId": messageID, "senderDeviceId": e.a.id, "envelopes": envelopes(e.b), "blobIds": four}
	again := e.expect(e.send(alice, "POST", e.messagesPathA, raw), 200, "").data
	if again["createdAt"] != first.data["createdAt"] {
		t.Fatalf("retry changed the message: %v", again)
	}
	expires := e.row(good).expires
	e.exec(`UPDATE chat_blobs SET state='deleted',deleted_at=now() WHERE blob_id=$1`, good)
	raw["blobIds"] = []string{good}
	e.expect(e.send(alice, "POST", e.messagesPathA, raw), 200, "")
	raw["blobIds"] = []string{theirs}
	e.expect(e.send(alice, "POST", e.messagesPathA, raw), 200, "")
	if r := e.row(good); !r.expires.Equal(expires) || *r.message != messageID || e.row(theirs).message != nil {
		t.Fatalf("a retry relinked something: %+v", r)
	}
	// The retry of someone else's messageId is still refused as before.
	raw["blobIds"] = nil
	raw["senderDeviceId"] = e.b.id
	raw["envelopes"] = envelopes(e.a)
	e.expect(e.send(bob, "POST", e.messagesPathA, raw), 422, "VALIDATION")

	// The refused message earlier did not consume its blobs: they still send.
	e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, theirs), 200, "")
}

// Linking sets the 30 day retention; unattached uploads only live an hour.
func TestBlobRetentionWindows(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	id := e.uploaded(alice, e.convo, "full", noise(100))
	var untilExpiry time.Duration
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT expires_at-now() FROM chat_blobs WHERE blob_id=$1`, id).Scan(&untilExpiry); err != nil || untilExpiry > time.Hour || untilExpiry < 59*time.Minute {
		t.Fatalf("unattached lives %v (%v)", untilExpiry, err)
	}
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id), 200, "")
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT expires_at-now() FROM chat_blobs WHERE blob_id=$1`, id).Scan(&untilExpiry); err != nil || untilExpiry > 30*24*time.Hour || untilExpiry < 30*24*time.Hour-time.Minute {
		t.Fatalf("linked lives %v (%v)", untilExpiry, err)
	}
}

// brokenStore is a chat store whose operations can be made to fail, with an error text that would leak if logged.
type brokenStore struct {
	*media.Memory
	mu                          sync.Mutex
	presign, stat, remove, sign bool
}

const leakyText = "https://leak.example/chat/secret?X-Amz-Signature=deadbeef&X-Amz-Credential=AKIAEXAMPLE"

func (b *brokenStore) failing(flag *bool) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return *flag
}
func (b *brokenStore) set(flag *bool, on bool) { b.mu.Lock(); *flag = on; b.mu.Unlock() }
func (b *brokenStore) PresignPutChecksum(ctx context.Context, key, contentType, sum string, size int64, ttl time.Duration) (string, http.Header, error) {
	if b.failing(&b.presign) {
		return "", nil, errors.New(leakyText)
	}
	return b.Memory.PresignPutChecksum(ctx, key, contentType, sum, size, ttl)
}
func (b *brokenStore) PresignGet(ctx context.Context, key string, ttl time.Duration) (string, error) {
	if b.failing(&b.sign) {
		return "", errors.New(leakyText)
	}
	return b.Memory.PresignGet(ctx, key, ttl)
}
func (b *brokenStore) Stat(ctx context.Context, key string) (int64, error) {
	if b.failing(&b.stat) {
		return 0, errors.New(leakyText)
	}
	return b.Memory.Stat(ctx, key)
}
func (b *brokenStore) Delete(ctx context.Context, keys ...string) error {
	if b.failing(&b.remove) {
		return errors.New(leakyText)
	}
	return b.Memory.Delete(ctx, keys...)
}

func TestChatMediaIsUnavailableWithoutAStore(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	id := e.uploaded(alice, e.convo, "full", noise(100))
	e.api.ChatMedia = nil
	for _, r := range []reply{
		e.slot(alice, e.convo, "full", noise(100)),
		e.call(alice, "POST", "/v1/blobs/"+id+"/complete"),
		e.call(alice, "GET", "/v1/conversations/"+e.convo+"/blobs/"+id+"/url"),
		e.call(alice, "DELETE", "/v1/blobs/"+id),
		e.call(cara, "GET", "/v1/conversations/"+e.convo+"/blobs/"+id+"/url"),
	} {
		e.expect(r, 503, "CHAT_MEDIA_UNAVAILABLE")
	}
	// Text chat and the other media are unaffected.
	e.expect(e.send(alice, "POST", e.messagesPathA, message(e.a, e.b)), 200, "")
	e.expect(e.send(alice, "POST", "/v1/media/uploads", map[string]any{"purpose": "post", "contentType": "image/jpeg", "sizeBytes": 10}), 503, "MEDIA_UNAVAILABLE")
}

// Storage failures answer 503 and log a code only: never a signed URL, a key, a hash or the error's own text.
func TestChatMediaLogsNoSecrets(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	var logs lockedBuffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previous) })
	store := &brokenStore{Memory: e.chat}
	e.api.ChatMedia = store
	content := noise(700)

	// A normal flow, then each storage operation failing in turn.
	id := e.uploaded(alice, e.convo, "full", content)
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id), 200, "")
	e.expect(e.url(bob, e.convo, id), 200, "")

	store.set(&store.presign, true)
	e.expect(e.slot(alice, e.convo, "full", content), 503, "CHAT_MEDIA_UNAVAILABLE")
	store.set(&store.presign, false)
	if e.count(`uploader_id=$1 AND state='pending'`, alice) != 0 {
		t.Fatal("a slot whose URL could not be signed stays pending")
	}
	made := e.expect(e.slot(alice, e.convo, "full", content), 201, "")
	e.put(made, content)
	store.set(&store.stat, true)
	e.expect(e.call(alice, "POST", "/v1/blobs/"+made.data["blobId"].(string)+"/complete"), 503, "CHAT_MEDIA_UNAVAILABLE")
	store.set(&store.stat, false)
	store.set(&store.sign, true)
	e.expect(e.url(bob, e.convo, id), 503, "CHAT_MEDIA_UNAVAILABLE")
	store.set(&store.sign, false)
	store.set(&store.remove, true)
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+id), 200, "")
	store.set(&store.remove, false)

	out := logs.String()
	for _, secret := range []string{"memory://", "X-Amz", "x-amz", "Signature", "AKIA", "leak.example", "secret", ctOf(content), "deadbeef", "chat/" + id, "uploadUrl", "ctSha256"} {
		if strings.Contains(out, secret) {
			t.Fatalf("log output contains %q:\n%s", secret, out)
		}
	}
	if !strings.Contains(out, "chat media storage failed") {
		t.Fatalf("storage failures were not logged:\n%s", out)
	}
	// The failed removal left the row for the clean-up job to retry.
	if r := e.row(id); r.state != "deleted" || r.key == nil {
		t.Fatalf("row %+v", r)
	}
	e.exec(`UPDATE chat_blobs SET deleted_at=now()-interval '1 hour' WHERE blob_id=$1`, id)
	if n, err := e.db.PurgeChatBlobs(e.ctx, e.chat, 100); err != nil || n != 1 {
		t.Fatalf("purge %d %v", n, err)
	}
	if r := e.row(id); r.key != nil || e.chat.Has("chat/"+id) {
		t.Fatalf("row after purge %+v", r)
	}
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}
func (l *lockedBuffer) String() string { l.mu.Lock(); defer l.mu.Unlock(); return l.b.String() }

func TestChatBlobCleanup(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(200)
	send := func() string {
		id := e.uploaded(alice, e.convo, "full", content)
		e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, id), 200, "")
		return id
	}
	live := send()
	expiredLinked := send()
	held := send()
	deleted := send()
	unattached := e.uploaded(alice, e.convo, "full", content)
	abandoned := e.expect(e.slot(alice, e.convo, "full", content), 201, "").data["blobId"].(string)
	e.put(e.expect(e.slot(alice, e.convo, "full", content), 201, ""), content) // a stray object without a row: left alone
	e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 day' WHERE blob_id=ANY($1::uuid[])`, []string{expiredLinked, held, unattached, abandoned})
	report := e.makeReport(held)
	e.expect(e.call(alice, "DELETE", "/v1/blobs/"+deleted), 200, "")
	// Simulate the immediate removal having failed, so the clean-up has the deleted blob's object to remove.
	e.chat.Put(e.ctx, "chat/"+deleted, content, "")
	e.exec(`UPDATE chat_blobs SET object_key='chat/'||blob_id::text WHERE blob_id=$1`, deleted)
	e.chat.Put(e.ctx, "chat/"+abandoned, content, "")

	n, err := e.db.PurgeChatBlobs(e.ctx, e.chat, 100)
	if err != nil || n != 4 {
		t.Fatalf("purged %d %v", n, err)
	}
	for name, id := range map[string]string{"expired linked": expiredLinked, "unattached": unattached, "abandoned": abandoned, "deleted": deleted} {
		if r := e.row(id); r.state != "deleted" || r.key != nil || e.chat.Has("chat/"+id) {
			t.Fatalf("%s: %+v object=%v", name, r, e.chat.Has("chat/"+id))
		}
	}
	// A live blob and a held one (even though expired) are untouched, row and object.
	for name, id := range map[string]string{"live": live, "held": held} {
		if r := e.row(id); r.state != "uploaded" || r.key == nil || !e.chat.Has("chat/"+id) {
			t.Fatalf("%s: %+v", name, r)
		}
	}
	if e.row(held).held == nil || *e.row(held).held != report {
		t.Fatal("hold lost")
	}
	// A second run has nothing to do.
	if n, err := e.db.PurgeChatBlobs(e.ctx, e.chat, 100); err != nil || n != 0 {
		t.Fatalf("second purge %d %v", n, err)
	}
	e.expect(e.url(bob, e.convo, expiredLinked), 410, "BLOB_EXPIRED")

	// The batch limit applies, and a failing store leaves rows for the next run.
	for i := 0; i < 3; i++ {
		e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 hour' WHERE blob_id=$1`, send())
	}
	store := &brokenStore{Memory: e.chat}
	store.set(&store.remove, true)
	if n, err := e.db.PurgeChatBlobs(e.ctx, store, 100); err == nil || n != 0 {
		t.Fatalf("failing store: %d %v", n, err)
	}
	if e.count(`state='deleted' AND object_key IS NOT NULL`) != 3 {
		t.Fatal("rows lost their key although the objects stayed")
	}
	store.set(&store.remove, false)
	if n, err := e.db.PurgeChatBlobs(e.ctx, store, 2); err != nil || n != 2 {
		t.Fatalf("batch of 2 purged %d %v", n, err)
	}
	if n, err := e.db.PurgeChatBlobs(e.ctx, store, 2); err != nil || n != 1 {
		t.Fatalf("rest purged %d %v", n, err)
	}

	// Tombstones outlive the quota window, then go; held rows stay.
	if n, err := e.db.PurgeChatBlobTombstones(e.ctx, 100); err != nil || n != 0 {
		t.Fatalf("fresh tombstones purged: %d %v", n, err)
	}
	e.exec(`UPDATE chat_blobs SET created_at=now()-interval '3 days',deleted_at=now()-interval '2 days',expires_at=now()-interval '2 days'`)
	if n, err := e.db.PurgeChatBlobTombstones(e.ctx, 100); err != nil || n < 5 {
		t.Fatalf("tombstones purged %d %v", n, err)
	}
	if e.count(`blob_id=$1`, held) != 1 || e.count(`blob_id=$1`, live) != 1 {
		t.Fatal("tombstone purge removed a live or held row")
	}
	if e.count(`state='deleted'`) != 0 {
		t.Fatal("tombstones left")
	}
}

// makeReport has alice report the conversation with the blobs of the messages they belong to as evidence.
func (e *blobEnv) makeReport(blobIDs ...string) string {
	e.t.Helper()
	e.api.reports.reset(alice)
	var evidence []map[string]any
	for _, id := range blobIDs {
		evidence = append(evidence, map[string]any{"messageId": *e.row(id).message, "text": "Sent a photo. Update Hiyall to view it.", "sentAt": time.Now().UTC(),
			"attachments": []map[string]any{{"blobIds": []string{id}, "descriptor": map[string]any{"v": 1, "key": "AAAA", "mime": "image/jpeg"}}}})
	}
	made := e.expect(e.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": e.convo, "reasonCode": "sexual_content", "evidence": evidence, "disclosureConsent": true}), 201, "").data
	return made["report"].(map[string]any)["reportId"].(string)
}

func TestBlockingDeletesThePairsBlobsExceptHeldEvidence(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(200)
	sent := e.uploaded(alice, e.convo, "full", content)
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, sent), 200, "")
	evidence := e.uploaded(bob, e.convo, "full", content)
	e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, evidence), 200, "")
	staged := e.uploaded(alice, e.convo, "thumb", content)
	slot := e.expect(e.slot(bob, e.convo, "thumb", content), 201, "").data["blobId"].(string)
	// A blob of another conversation is not touched.
	e.register(cara)
	other := e.expect(e.send(alice, "POST", "/v1/conversations", map[string]string{"userId": cara}), 200, "").data["conversationId"].(string)
	e.ok(alice, "POST", "/v1/users/"+cara+"/friend-requests")
	e.ok(cara, "POST", "/v1/users/"+alice+"/friend-requests")
	elsewhere := e.uploaded(alice, other, "full", content)
	report := e.makeReport(evidence)

	e.ok(alice, "POST", "/v1/users/"+bob+"/block")
	for name, id := range map[string]string{"sent": sent, "staged": staged, "slot": slot} {
		if r := e.row(id); r.state != "deleted" || r.key == nil {
			t.Fatalf("%s after block: %+v (the object is for the clean-up job to remove)", name, r)
		}
	}
	if r := e.row(evidence); r.state != "uploaded" || r.held == nil || *r.held != report {
		t.Fatalf("held evidence after block: %+v", r)
	}
	if r := e.row(elsewhere); r.state != "uploaded" {
		t.Fatalf("another conversation's blob changed: %+v", r)
	}
	if n, err := e.db.PurgeChatBlobs(e.ctx, e.chat, 100); err != nil || n != 3 {
		t.Fatalf("purge %d %v", n, err)
	}
	if e.chat.Has("chat/"+sent) || e.chat.Has("chat/"+staged) || !e.chat.Has("chat/"+evidence) || !e.chat.Has("chat/"+elsewhere) {
		t.Fatalf("objects left: %v", e.chat.Keys())
	}
}

func TestReportEvidenceHoldsAttachments(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	content := noise(300)
	photo := e.uploaded(bob, e.convo, "full", content)
	thumb := e.uploaded(bob, e.convo, "thumb", content)
	first := e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, photo, thumb), 200, "").data["messageId"].(string)
	second := e.uploaded(bob, e.convo, "full", content)
	secondMessage := e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, second), 200, "").data["messageId"].(string)
	text := e.expect(e.send(bob, "POST", e.messagesPathA, message(e.b, e.a)), 200, "").data["messageId"].(string)
	unsent := e.uploaded(bob, e.convo, "full", content)
	at := time.Now().UTC()
	descriptor := map[string]any{"v": 1, "key": "k", "mime": "image/jpeg", "blobs": map[string]any{"full": photo}}
	report := func(evidence []map[string]any, consent bool) reply {
		e.api.reports.reset(alice)
		return e.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": e.convo, "reasonCode": "sexual_content", "evidence": evidence, "disclosureConsent": consent})
	}
	msg := func(id string, attachments ...map[string]any) map[string]any {
		m := map[string]any{"messageId": id, "text": "Sent a photo. Update Hiyall to view it.", "sentAt": at}
		if attachments != nil {
			m["attachments"] = attachments
		}
		return m
	}
	att := func(ids ...string) map[string]any { return map[string]any{"blobIds": ids, "descriptor": descriptor} }
	reports := func() int {
		var n int
		if err := e.db.Pool.QueryRow(e.ctx, `SELECT count(*) FROM reports`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	// Anything that does not tie the blobs to the evidence message in this chat is refused, and nothing is stored or held.
	for name, evidence := range map[string][]map[string]any{
		"another message's blob":   {msg(first, att(second))},
		"unsent blob":              {msg(first, att(unsent))},
		"unknown blob":             {msg(first, att(uuid.NewString()))},
		"blob of a text message":   {msg(text, att(photo))},
		"one good one stray":       {msg(first, att(photo, second))},
		"no ids":                   {msg(first, att())},
		"duplicate ids":            {msg(first, att(photo, photo))},
		"five ids":                 {msg(first, att(photo, thumb, photo, thumb, photo))},
		"five attachments":         {msg(first, att(photo), att(photo), att(photo), att(photo), att(photo))},
		"descriptor is a string":   {msg(first, map[string]any{"blobIds": []string{photo}, "descriptor": "key"})},
		"descriptor is null":       {msg(first, map[string]any{"blobIds": []string{photo}, "descriptor": nil})},
		"descriptor missing":       {msg(first, map[string]any{"blobIds": []string{photo}})},
		"descriptor is an array":   {msg(first, map[string]any{"blobIds": []string{photo}, "descriptor": []int{1}})},
		"descriptor too large":     {msg(first, map[string]any{"blobIds": []string{photo}, "descriptor": map[string]any{"pad": strings.Repeat("x", 5000)}})},
		"non-canonical blob id":    {msg(first, att(strings.ToUpper(photo)))},
		"unknown attachment field": {msg(first, map[string]any{"blobIds": []string{photo}, "descriptor": descriptor, "extra": 1})},
	} {
		if got := report(evidence, true); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("%s: %d %s", name, got.status, got.code)
		}
		if reports() != 0 || e.count(`held_report_id IS NOT NULL`) != 0 {
			t.Fatalf("%s: refused report left state behind", name)
		}
	}
	// Attachments need the reporter's consent like the text does.
	e.expect(report([]map[string]any{msg(first, att(photo, thumb))}, false), 422, "VALIDATION")

	// A valid report holds exactly the named blobs.
	made := e.expect(report([]map[string]any{msg(first, att(photo, thumb)), msg(secondMessage, att(second)), msg(text)}, true), 201, "").data
	id := made["report"].(map[string]any)["reportId"].(string)
	for _, blob := range []string{photo, thumb, second} {
		if r := e.row(blob); r.held == nil || *r.held != id {
			t.Fatalf("blob %s not held: %+v", blob, r)
		}
	}
	if e.row(unsent).held != nil || e.count(`held_report_id=$1`, id) != 3 {
		t.Fatal("the hold reached further than the evidence")
	}
	queue, err := e.db.ReportQueue(e.ctx, 10)
	if err != nil || len(queue) != 1 || len(queue[0].Blobs) != 3 || len(queue[0].Evidence) != 3 {
		t.Fatalf("queue %+v %v", queue, err)
	}
	for _, b := range queue[0].Blobs {
		if b.CtSha256 != ctOf(content) || b.SizeBytes != 300 || b.State != "uploaded" {
			t.Fatalf("held blob %+v", b)
		}
	}
	// The descriptor is stored with the evidence as given; the blob rows carry no key.
	if got := queue[0].Evidence[0].Attachments; len(got) != 1 || len(got[0].BlobIDs) != 2 || !strings.Contains(string(got[0].Descriptor), `"key"`) {
		t.Fatalf("evidence %+v", queue[0].Evidence[0])
	}

	// Held blobs ignore uploader delete, block and retention.
	e.expect(e.call(bob, "DELETE", "/v1/blobs/"+photo), 200, "")
	if r := e.row(photo); r.state != "uploaded" || !e.chat.Has("chat/"+photo) {
		t.Fatalf("held blob deleted by its uploader: %+v", r)
	}
	e.expect(e.call(bob, "DELETE", "/v1/blobs/"+unsent), 200, "")
	if e.row(unsent).state != "deleted" {
		t.Fatal("an unheld blob survived its delete")
	}
	e.ok(bob, "POST", "/v1/users/"+alice+"/block")
	e.exec(`UPDATE chat_blobs SET expires_at=now()-interval '1 day'`)
	if n, err := e.db.PurgeChatBlobs(e.ctx, e.chat, 100); err != nil || n != 0 { // the deleted unsent blob's object went at once; the held ones stay
		t.Fatalf("purge %d %v", n, err)
	}
	for _, blob := range []string{photo, thumb, second} {
		if r := e.row(blob); r.state != "uploaded" || r.key == nil || !e.chat.Has("chat/"+blob) {
			t.Fatalf("held blob %s lost: %+v", blob, r)
		}
	}
	// Moderation never needs to fetch or decrypt anything from the table: ids, sizes and hashes only.
	held, err := e.db.HeldBlobs(e.ctx, id)
	if err != nil || len(held) != 3 {
		t.Fatalf("held %v %v", held, err)
	}

	// A repeat report while the first is open is the old report and holds nothing new.
	e.exec(`UPDATE conversations SET status='active'`)
	e.exec(`DELETE FROM blocks`)
	dup := e.expect(report([]map[string]any{msg(first, att(photo))}, true), 200, "").data
	if dup["duplicate"] != true {
		t.Fatalf("duplicate %v", dup)
	}
}

// A report with text evidence only keeps working exactly as before.
func TestTextOnlyReportsAreUnchanged(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	id := e.expect(e.send(bob, "POST", e.messagesPathA, message(e.b, e.a)), 200, "").data["messageId"].(string)
	made := e.expect(e.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": e.convo, "reasonCode": "harassment",
		"evidence": []map[string]any{{"messageId": id, "text": "hello", "sentAt": time.Now().UTC()}}, "disclosureConsent": true}), 201, "").data
	if made["duplicate"] != false {
		t.Fatalf("report %v", made)
	}
	queue, err := e.db.ReportQueue(e.ctx, 10)
	if err != nil || len(queue) != 1 || len(queue[0].Blobs) != 0 || len(queue[0].Evidence) != 1 || len(queue[0].Evidence[0].Attachments) != 0 {
		t.Fatalf("queue %+v %v", queue, err)
	}
	var stored string
	if err = e.db.Pool.QueryRow(e.ctx, `SELECT evidence::text FROM reports`).Scan(&stored); err != nil || strings.Contains(stored, "attachments") {
		t.Fatalf("stored evidence %s %v", stored, err)
	}
}

// Account deletion does not exist yet; its hook marks a user's unheld blobs deleted.
func TestAccountDeletionHookMarksBlobsDeleted(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	keep := e.uploaded(alice, e.convo, "full", noise(100))
	gone := e.uploaded(alice, e.convo, "thumb", noise(100))
	mine := e.uploaded(bob, e.convo, "full", noise(100))
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, keep), 200, "")
	rep := e.makeReport(keep)
	tx, err := e.db.Pool.Begin(e.ctx)
	if err != nil {
		t.Fatal(err)
	}
	n, err := store.DeleteUserChatBlobs(e.ctx, tx, alice)
	if err != nil || n != 1 {
		t.Fatalf("marked %d %v", n, err)
	}
	if err = tx.Commit(e.ctx); err != nil {
		t.Fatal(err)
	}
	if e.row(gone).state != "deleted" || e.row(keep).state != "uploaded" || e.row(mine).state != "uploaded" || *e.row(keep).held != rep {
		t.Fatal("the hook touched the wrong rows")
	}
}

// Migration 0023 on top of 0022: the table, its constraints and its foreign keys, in a scratch schema.
func TestMigration0023ChatBlobs(t *testing.T) {
	ctx, db := connectTestDB(t)
	migration, err := os.ReadFile("../../../../database/migrations/0023_chat_blobs.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	const (
		user, peer, convo, msg, report = "019a4000-0000-7000-8000-000000000f21", "019a4000-0000-7000-8000-000000000f22",
			"019a4000-0000-7000-8000-000000000f31", "019a4000-0000-7000-8000-000000000f41", "019a4000-0000-7000-8000-000000000f51"
	)
	for _, statement := range []string{
		`CREATE SCHEMA migration_scratch_23`,
		`SET LOCAL search_path = migration_scratch_23`,
		// The referenced tables reduced to their keys.
		`CREATE TABLE users(user_id uuid PRIMARY KEY)`,
		`CREATE TABLE conversations(conversation_id uuid PRIMARY KEY)`,
		`CREATE TABLE messages(message_id uuid PRIMARY KEY)`,
		`CREATE TABLE reports(report_id uuid PRIMARY KEY)`,
		`INSERT INTO users VALUES ('` + user + `'),('` + peer + `')`,
		`INSERT INTO conversations VALUES ('` + convo + `')`,
		`INSERT INTO messages VALUES ('` + msg + `')`,
		`INSERT INTO reports VALUES ('` + report + `')`,
		string(migration),
	} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	insert := func(extra string) string {
		// extra overrides columns: role, size, sha, state, key, deleted_at, uploaded_at, message, held, user.
		return `INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,message_id,role,size_bytes,ct_sha256,state,object_key,uploaded_at,deleted_at,held_report_id,expires_at) ` + extra
	}
	good := func(id string) string {
		return insert(`VALUES ('` + id + `','` + user + `','` + convo + `',NULL,'full',1000,decode(repeat('ab',32),'hex'),'pending','chat/` + id + `',NULL,NULL,NULL,now())`)
	}
	if _, err = tx.Exec(ctx, good("019a4000-0000-7000-8000-000000000a01")); err != nil {
		t.Fatalf("a valid row was refused: %v", err)
	}
	refused := func(name, statement string) {
		t.Helper()
		if _, err := tx.Exec(ctx, `SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, statement); err == nil {
			t.Fatalf("%s accepted", name)
		}
		if _, err := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
			t.Fatal(err)
		}
	}
	row := func(id, role, size, sha, state, key, uploaded, deleted string) string {
		return insert(`VALUES ('` + id + `','` + user + `','` + convo + `',NULL,` + role + `,` + size + `,` + sha + `,` + state + `,` + key + `,` + uploaded + `,` + deleted + `,NULL,now())`)
	}
	const hash, k, nothing = `decode(repeat('ab',32),'hex')`, `'chat/x'`, `NULL`
	id := func(n int) string { return fmt.Sprintf("019a4000-0000-7000-8000-000000000b%02d", n) }
	refused("role video", row(id(1), `'video'`, `1000`, hash, `'pending'`, k, nothing, nothing))
	refused("size below the minimum", row(id(2), `'full'`, `31`, hash, `'pending'`, k, nothing, nothing))
	refused("size above 4 MiB", row(id(3), `'full'`, `4194305`, hash, `'pending'`, k, nothing, nothing))
	refused("short hash", row(id(4), `'full'`, `1000`, `decode(repeat('ab',31),'hex')`, `'pending'`, k, nothing, nothing))
	refused("unknown state", row(id(5), `'full'`, `1000`, hash, `'gone'`, k, nothing, nothing))
	refused("deleted without a time", row(id(6), `'full'`, `1000`, hash, `'deleted'`, nothing, nothing, nothing))
	refused("pending without a key", row(id(7), `'full'`, `1000`, hash, `'pending'`, nothing, nothing, nothing))
	refused("uploaded without a time", row(id(8), `'full'`, `1000`, hash, `'uploaded'`, k, nothing, nothing))
	refused("unknown uploader", strings.Replace(good(id(9)), user, "019a4000-0000-7000-8000-00000000dead", 1))
	refused("unknown conversation", strings.Replace(good(id(10)), convo, "019a4000-0000-7000-8000-00000000dead", 1))
	refused("duplicate id", good("019a4000-0000-7000-8000-000000000a01"))
	for _, ok := range []string{
		row(id(20), `'thumb'`, `32`, hash, `'pending'`, k, nothing, nothing),
		row(id(21), `'full'`, `4194304`, hash, `'uploaded'`, k, `now()`, nothing),
		row(id(22), `'full'`, `1000`, hash, `'deleted'`, nothing, nothing, `now()`),
	} {
		if _, err = tx.Exec(ctx, ok); err != nil {
			t.Fatalf("valid row refused: %v", err)
		}
	}

	// Foreign keys: a conversation or message with blobs cannot be deleted, a purged report only releases its hold.
	if _, err = tx.Exec(ctx, `UPDATE chat_blobs SET message_id=$1,held_report_id=$2 WHERE blob_id=$3`, msg, report, "019a4000-0000-7000-8000-000000000a01"); err != nil {
		t.Fatal(err)
	}
	refused("deleting a message with blobs", `DELETE FROM messages`)
	refused("deleting a conversation with blobs", `DELETE FROM conversations`)
	if _, err = tx.Exec(ctx, `DELETE FROM reports`); err != nil {
		t.Fatalf("a report with held blobs cannot be purged: %v", err)
	}
	var held int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM chat_blobs WHERE held_report_id IS NOT NULL`).Scan(&held); err != nil || held != 0 {
		t.Fatalf("hold survived its report: %d %v", held, err)
	}
	// The indexes the quota, the clean-up and the evidence checks use.
	var indexes int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM pg_indexes WHERE schemaname='migration_scratch_23' AND tablename='chat_blobs' AND indexname IN ('chat_blobs_uploader','chat_blobs_expiry','chat_blobs_removal','chat_blobs_message','chat_blobs_conversation','chat_blobs_held')`).Scan(&indexes); err != nil || indexes != 6 {
		t.Fatalf("indexes %d %v", indexes, err)
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	// The real test database has it applied on top of 0022, and the scratch schema left nothing behind.
	var applied, leaked bool
	if err = db.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0022_avatar_media.sql') AND EXISTS(SELECT 1 FROM schema_migrations WHERE version='0023_chat_blobs.sql')`).Scan(&applied); err != nil || !applied {
		t.Fatalf("0023 not applied after 0022: %v", err)
	}
	if err = db.Pool.QueryRow(ctx, `SELECT to_regclass('migration_scratch_23.chat_blobs') IS NOT NULL`).Scan(&leaked); err != nil || leaked {
		t.Fatalf("scratch schema leaked (%v)", err)
	}
}
