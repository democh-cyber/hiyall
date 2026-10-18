package httpapi

import (
	"bytes"
	"context"
	"fmt"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/push"
)

// ---- Voice and video blobs (docs/api/26-chat-voice-video-and-list.md) ----

// slotOf asks for a slot of an exact declared size without holding any bytes (the slot only reserves and signs).
func (e *blobEnv) slotOf(user, role string, size int64) reply {
	e.t.Helper()
	e.api.blobSlots.reset(user)
	return e.send(user, "POST", "/v1/conversations/"+e.convo+"/blobs", map[string]any{"role": role, "sizeBytes": size, "ctSha256": ctOf([]byte("x"))})
}

func TestVoiceAndVideoBlobCapsPerRole(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	// Voice 8 MiB and video 40 MiB are accepted to the byte; one more is 413. Thumb and full are unchanged.
	e.expect(e.slotOf(alice, "voice", 8<<20), 201, "")
	e.expect(e.slotOf(alice, "voice", 8<<20+1), 413, "TOO_LARGE")
	e.expect(e.slotOf(alice, "video", 40<<20), 201, "")
	e.expect(e.slotOf(alice, "video", 40<<20+1), 413, "TOO_LARGE")
	e.expect(e.slotOf(alice, "full", 4<<20), 201, "")
	e.expect(e.slotOf(alice, "full", 4<<20+1), 413, "TOO_LARGE")
	e.expect(e.slotOf(alice, "thumb", 256<<10), 201, "")
	e.expect(e.slotOf(alice, "thumb", 256<<10+1), 413, "TOO_LARGE")
	// A voice blob is not allowed to be as large as a video: the role is what picks the cap.
	e.expect(e.slotOf(alice, "voice", 9<<20), 413, "TOO_LARGE")
	// Unknown roles and too-small sizes are validation errors.
	for _, role := range []string{"", "audio", "movie", "VOICE", "Video", "poster"} {
		e.expect(e.slotOf(alice, role, 1000), 422, "VALIDATION")
	}
	e.expect(e.slotOf(alice, "voice", 31), 422, "VALIDATION")
	e.expect(e.slotOf(alice, "video", 31), 422, "VALIDATION")
	// The refusal says which roles exist.
	status, _, body := e.full(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", "application/json", fmt.Sprintf(`{"role":"audio","sizeBytes":100,"ctSha256":%q}`, ctOf([]byte("x"))))
	if status != 422 || !strings.Contains(string(body), "must be full, thumb, voice or video") {
		t.Fatalf("role error: %d %s", status, body)
	}
	// What was stored carries the role and the declared size, and nothing about kind or duration.
	var role string
	var size int64
	if err := e.db.Pool.QueryRow(e.ctx, `SELECT role,size_bytes FROM chat_blobs WHERE role='video'`).Scan(&role, &size); err != nil || size != 40<<20 {
		t.Fatalf("video row %q %d %v", role, size, err)
	}
}

func TestVoiceAndVideoCapsComeFromEntitlements(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	tier := domain.Free()
	e.api.Entitlements = func(_ context.Context, user string) domain.Entitlements {
		x := tier
		if user == bob {
			// A larger tier for bob only.
			x.VideoMaxBlobBytes = 60 << 20
			x.VoiceMaxBlobBytes = 16 << 20
		}
		return x
	}
	tier.VideoMaxBlobBytes = 1 << 20
	tier.VoiceMaxBlobBytes = 64 << 10
	e.expect(e.slotOf(alice, "video", 1<<20), 201, "")
	e.expect(e.slotOf(alice, "video", 1<<20+1), 413, "TOO_LARGE")
	e.expect(e.slotOf(alice, "voice", 64<<10), 201, "")
	e.expect(e.slotOf(alice, "voice", 64<<10+1), 413, "TOO_LARGE")
	// full and thumb are not entitlements.
	e.expect(e.slotOf(alice, "full", 4<<20), 201, "")
	// bob's own entitlements apply to bob.
	e.expect(e.slotOf(bob, "video", 60<<20), 201, "")
	e.expect(e.slotOf(bob, "video", 60<<20+1), 413, "TOO_LARGE")
	e.expect(e.slotOf(bob, "voice", 16<<20), 201, "")
	e.expect(e.slotOf(bob, "voice", 16<<20+1), 413, "TOO_LARGE")
}

func TestVideoBytesCountAgainstTheDailyQuotaAndPendingCap(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	// 7 videos of 40 MiB are 280 MiB: they fit under the 300 MiB daily byte quota. The 8th does not.
	for i := 0; i < 7; i++ {
		e.expect(e.slotOf(alice, "video", 40<<20), 201, "")
	}
	e.api.blobSlots.reset(alice)
	status, header, body := e.full(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", "application/json", fmt.Sprintf(`{"role":"video","sizeBytes":%d,"ctSha256":%q}`, 40<<20, ctOf([]byte("x"))))
	if status != 429 || !strings.Contains(string(body), `"QUOTA"`) {
		t.Fatalf("8th video: %d %s", status, body)
	}
	if n, err := strconv.Atoi(header.Get("Retry-After")); err != nil || n < 1 || n > 24*3600 {
		t.Fatalf("Retry-After %q", header.Get("Retry-After"))
	}
	// The message is about media, not photos.
	if strings.Contains(string(body), "photos") || !strings.Contains(string(body), "media") {
		t.Fatalf("quota message %s", body)
	}
	// What still fits is accepted: 20 MiB of voice would not be, but 8 MiB does (280+8 <= 300).
	e.expect(e.slotOf(alice, "voice", 8<<20), 201, "")
	// 288 MiB used, 12 MiB left: a 13 MiB video is over, a small thumb is fine.
	e.expect(e.slotOf(alice, "video", 13<<20), 429, "QUOTA")
	e.expect(e.slotOf(alice, "thumb", 4000), 201, "")
	// The peer's budget is separate.
	e.expect(e.slotOf(bob, "video", 40<<20), 201, "")

	// The pending cap (10 slots not completed) covers voice and video like photos.
	p := newBlobEnv(t)
	p.open()
	for i := 0; i < domain.Free().PendingBlobs; i++ {
		p.expect(p.slotOf(alice, "voice", 1000), 201, "")
	}
	p.expect(p.slotOf(alice, "voice", 1000), 429, "RATE_LIMITED")
	p.expect(p.slotOf(alice, "video", 1000), 429, "RATE_LIMITED")
}

func TestVoiceAndVideoShareThePhotoGate(t *testing.T) {
	e := newBlobEnv(t)
	for _, role := range []string{"voice", "video", "thumb", "full"} {
		status, _, body := e.full(alice, "POST", "/v1/conversations/"+e.convo+"/blobs", "application/json", fmt.Sprintf(`{"role":%q,"sizeBytes":1000,"ctSha256":%q}`, role, ctOf([]byte("x"))))
		if status != 403 || !strings.Contains(string(body), `"ATTACHMENTS_NOT_ALLOWED"`) || !strings.Contains(string(body), "photos, voice messages and videos") {
			t.Fatalf("%s before a reply: %d %s", role, status, body)
		}
		e.api.blobSlots.reset(alice)
	}
	// Alice writing is not a reply; once bob has written, both roles are open to alice.
	e.expect(e.send(alice, "POST", e.messagesPathA, message(e.a, e.b)), 200, "")
	e.expect(e.slotOf(alice, "voice", 1000), 403, "ATTACHMENTS_NOT_ALLOWED")
	e.expect(e.send(bob, "POST", e.messagesPathA, message(e.b, e.a)), 200, "")
	e.expect(e.slotOf(alice, "voice", 1000), 201, "")
	e.expect(e.slotOf(alice, "video", 1000), 201, "")
	// The gate is checked again when a voice message is sent: friendship or reply gone is not possible for a reply,
	// but a member who is barred in between cannot link anything.
	voice := e.uploaded(alice, e.convo, "voice", noise(2000))
	e.ok(bob, "POST", "/v1/users/"+alice+"/block")
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, voice), 404, "NOT_FOUND")
	if e.row(voice).message != nil {
		t.Fatal("voice blob linked into a refused message")
	}
}

func TestVideoMessageLinksVideoAndThumbTogether(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	video, poster := noise(9000), noise(700)
	v := e.uploaded(alice, e.convo, "video", video)
	p := e.uploaded(alice, e.convo, "thumb", poster)
	sent := e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, v, p), 200, "").data
	for _, id := range []string{v, p} {
		r := e.row(id)
		if r.message == nil || *r.message != sent["messageId"] || time.Until(r.expires) < 29*24*time.Hour {
			t.Fatalf("blob %s not linked for 30 days: %+v", id, r)
		}
	}
	if r := e.row(v); r.role != "video" || r.size != 9000 {
		t.Fatalf("video row %+v", r)
	}
	// The peer can fetch both; the descriptor (kind, duration, mime) is inside the ciphertext, never here.
	for _, id := range []string{v, p} {
		got := e.expect(e.url(bob, e.convo, id), 200, "").data
		if got["url"] != "memory://get/chat/"+id {
			t.Fatalf("url %v", got)
		}
	}
	if e.expect(e.url(bob, e.convo, v), 200, "").data["sizeBytes"] != float64(9000) {
		t.Fatal("video size")
	}
	// A voice message is one blob. A second message cannot claim the same blobs again.
	voice := e.uploaded(bob, e.convo, "voice", noise(3000))
	e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, voice), 200, "")
	e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, voice), 409, "BLOB_NOT_READY")
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, v), 409, "BLOB_NOT_READY")
	// At most four blobs per message, whatever their roles.
	var five []string
	for i := 0; i < 5; i++ {
		five = append(five, e.uploaded(alice, e.convo, "thumb", noise(100)))
	}
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, five...), 422, "VALIDATION")
	e.expect(e.sendBlobs(alice, e.a, e.b, e.convo, five[:4]...), 200, "")
}

func TestVoiceAndVideoBlobsAreShareableAsReportEvidence(t *testing.T) {
	e := newBlobEnv(t)
	e.open()
	voice := e.uploaded(bob, e.convo, "voice", noise(2500))
	voiceMessage := e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, voice), 200, "").data["messageId"].(string)
	video := e.uploaded(bob, e.convo, "video", noise(7000))
	poster := e.uploaded(bob, e.convo, "thumb", noise(600))
	videoMessage := e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, video, poster), 200, "").data["messageId"].(string)
	photo := e.uploaded(bob, e.convo, "full", noise(900))
	photoMessage := e.expect(e.sendBlobs(bob, e.b, e.a, e.convo, photo), 200, "").data["messageId"].(string)
	at := time.Now().UTC()
	report := func(evidence []map[string]any) reply {
		e.api.reports.reset(alice)
		return e.send(alice, "POST", "/v1/reports", map[string]any{"targetType": "conversation", "targetId": e.convo, "reasonCode": "sexual_content", "evidence": evidence, "disclosureConsent": true})
	}
	msg := func(id string, ids ...string) map[string]any {
		return map[string]any{"messageId": id, "text": "Sent a message. Update Hiyall to view it.", "sentAt": at,
			"attachments": []map[string]any{{"blobIds": ids, "descriptor": map[string]any{"v": 1, "key": "k", "kind": "video"}}}}
	}
	held := func() int { return e.count(`held_report_id IS NOT NULL`) }

	// Blob ids of another message are refused, nothing is stored or held.
	for name, evidence := range map[string][]map[string]any{
		"video under the voice message":  {msg(voiceMessage, video)},
		"voice under the video message":  {msg(videoMessage, voice)},
		"poster under the photo message": {msg(photoMessage, poster)},
		"video plus a stray voice":       {msg(videoMessage, video, poster, voice)},
		"a blob nobody sent":             {msg(videoMessage, uuid.NewString())},
	} {
		if got := report(evidence); got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("%s: %d %s", name, got.status, got.code)
		}
		if held() != 0 {
			t.Fatalf("%s: a refused report held blobs", name)
		}
	}
	// A report naming the voice blob and the video + thumb pair holds exactly those three.
	made := e.expect(report([]map[string]any{msg(voiceMessage, voice), msg(videoMessage, video, poster)}), 201, "").data
	id := made["report"].(map[string]any)["reportId"].(string)
	for _, blob := range []string{voice, video, poster} {
		if r := e.row(blob); r.held == nil || *r.held != id {
			t.Fatalf("blob %s not held: %+v", blob, r)
		}
	}
	if e.row(photo).held != nil || held() != 3 {
		t.Fatal("the hold reached further than the evidence")
	}
	// The moderation listing shows roles, sizes and hashes only.
	blobs, err := e.db.HeldBlobs(e.ctx, id)
	if err != nil || len(blobs) != 3 {
		t.Fatalf("held %v %v", blobs, err)
	}
	roles := map[string]int64{}
	for _, b := range blobs {
		roles[b.Role] = b.SizeBytes
	}
	if roles["voice"] != 2500 || roles["video"] != 7000 || roles["thumb"] != 600 {
		t.Fatalf("held roles %v", roles)
	}
	// Held blobs survive the uploader's delete like held photos.
	e.expect(e.call(bob, "DELETE", "/v1/blobs/"+video), 200, "")
	if r := e.row(video); r.state != "uploaded" || !e.chat.Has("chat/"+video) {
		t.Fatalf("held video was deleted: %+v", r)
	}
}

// ---- Pins, deleted chats and the list ----

type chatPeer struct{ user, convo string }

// chatsWith makes owner open a conversation with n new members; chat i is the i-th newest (sort_at = i+1 hours ago).
func (h *socialHarness) chatsWith(owner string, n int) []chatPeer {
	h.t.Helper()
	peers := make([]chatPeer, n)
	for i := range peers {
		id := uuid.NewString()
		h.user(id, "lp"+strings.ReplaceAll(id, "-", "")[:12])
		h.policy(id, "messagesFrom", "everyone")
		h.api.firstChats.reset(owner)
		convo := h.expect(h.send(owner, "POST", "/v1/conversations", map[string]string{"userId": id}), 200, "").data["conversationId"].(string)
		h.exec(`UPDATE conversation_members SET sort_at=now()-make_interval(hours=>$2) WHERE conversation_id=$1`, convo, i+1)
		peers[i] = chatPeer{id, convo}
	}
	return peers
}

func (h *socialHarness) pin(user, convo string, pinned bool) reply {
	h.t.Helper()
	h.api.graph.reset(user)
	return h.send(user, "PUT", "/v1/conversations/"+convo+"/pin", map[string]any{"pinned": pinned})
}

func convoIDs(data map[string]any) []string {
	out := []string{}
	for _, c := range items(data) {
		out = append(out, c["conversationId"].(string))
	}
	return out
}

func (h *socialHarness) listPage(user, query string) map[string]any {
	h.t.Helper()
	h.api.lists.reset(user)
	return h.ok(user, "GET", "/v1/conversations"+query)
}

func TestPinLimitIsolationAndValidation(t *testing.T) {
	h := newSocialHarness(t)
	chats := h.chatsWith(alice, 7)
	max := domain.Free().ChatPinsMax
	if max != 5 {
		t.Fatalf("Free pins %d", max)
	}
	var firstAt string
	for i := 0; i < max; i++ {
		got := h.expect(h.pin(alice, chats[i].convo, true), 200, "").data
		if got["pinned"] != true || got["pinnedAt"] == nil || len(got) != 2 {
			t.Fatalf("pin %d: %v", i, got)
		}
		if i == 0 {
			firstAt = got["pinnedAt"].(string)
		}
	}
	// The 6th is refused with PIN_LIMIT and the message names the number.
	h.api.graph.reset(alice)
	status, _, body := h.full(alice, "PUT", "/v1/conversations/"+chats[5].convo+"/pin", "application/json", `{"pinned":true}`)
	if status != 409 || !strings.Contains(string(body), `"PIN_LIMIT"`) || !strings.Contains(string(body), "You can pin up to 5 chats") {
		t.Fatalf("6th pin: %d %s", status, body)
	}
	// Pinning a pinned chat is fine at the limit and keeps its pinnedAt.
	again := h.expect(h.pin(alice, chats[0].convo, true), 200, "").data
	if again["pinnedAt"] != firstAt {
		t.Fatalf("pinnedAt moved: %v -> %v", firstAt, again["pinnedAt"])
	}
	// Unpinning frees a slot; unpinning a chat that is not pinned is fine too.
	off := h.expect(h.pin(alice, chats[1].convo, false), 200, "").data
	if off["pinned"] != false || off["pinnedAt"] != nil {
		t.Fatalf("unpin %v", off)
	}
	h.expect(h.pin(alice, chats[1].convo, false), 200, "")
	h.expect(h.pin(alice, chats[5].convo, true), 200, "")
	h.expect(h.pin(alice, chats[6].convo, true), 409, "PIN_LIMIT")

	// Per member: the peer sees nothing, and has a budget of their own.
	single := h.ok(chats[0].user, "GET", "/v1/conversations/"+chats[0].convo)
	if single["pinnedAt"] != nil {
		t.Fatalf("the peer sees a pin: %v", single)
	}
	if mine := h.ok(alice, "GET", "/v1/conversations/"+chats[0].convo); mine["pinnedAt"] != firstAt {
		t.Fatalf("own view %v", mine["pinnedAt"])
	}
	h.expect(h.pin(chats[0].user, chats[0].convo, true), 200, "")
	if got := h.ok(alice, "GET", "/v1/conversations/"+chats[0].convo); got["pinnedAt"] != firstAt {
		t.Fatalf("the peer's pin changed mine: %v", got["pinnedAt"])
	}

	// Strict body: exactly {"pinned": true|false}.
	path := "/v1/conversations/" + chats[2].convo + "/pin"
	for name, body := range map[string]string{
		"empty": `{}`, "string": `{"pinned":"true"}`, "null": `{"pinned":null}`, "number": `{"pinned":1}`,
		"extra": `{"pinned":true,"x":1}`, "other key": `{"pin":true}`, "array": `[true]`, "not json": `nope`,
	} {
		h.api.graph.reset(alice)
		if status, _, _ := h.full(alice, "PUT", path, "application/json", body); status != 422 {
			t.Fatalf("%s: %d", name, status)
		}
	}
	h.api.graph.reset(alice)
	if status, _, _ := h.full(alice, "PUT", path, "text/plain", `{"pinned":true}`); status != 422 {
		t.Fatalf("text/plain: %d", status)
	}
	// Not a member, unknown and malformed ids are 404; the wrong method does not pin.
	h.expect(h.pin(cara, chats[2].convo, true), 404, "NOT_FOUND")
	h.expect(h.pin(alice, uuid.NewString(), true), 404, "NOT_FOUND")
	h.api.graph.reset(alice)
	h.expect(h.send(alice, "PUT", "/v1/conversations/not-an-id/pin", map[string]any{"pinned": true}), 404, "NOT_FOUND")
	if status, _, _ := h.full(alice, "POST", path, "application/json", `{"pinned":true}`); status == 200 {
		t.Fatal("POST pinned")
	}
	// Unpinning a chat of somebody else's is 404 as well.
	h.expect(h.pin(cara, chats[2].convo, false), 404, "NOT_FOUND")
	// The per-account limiter answers 429 with Retry-After.
	h.api.graph.reset(alice)
	limited := false
	for i := 0; i < 40 && !limited; i++ {
		status, header, _ := h.full(alice, "PUT", path, "application/json", `{"pinned":false}`)
		if status == 429 {
			limited = header.Get("Retry-After") != ""
		}
	}
	if !limited {
		t.Fatal("pin is not rate limited")
	}
}

func TestConcurrentPinsCannotPassTheLimit(t *testing.T) {
	h := newSocialHarness(t)
	chats := h.chatsWith(alice, 9)
	h.api.graph.reset(alice)
	var wg sync.WaitGroup
	results := make([]reply, len(chats))
	for i := range chats {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i] = h.send(alice, "PUT", "/v1/conversations/"+chats[i].convo+"/pin", map[string]any{"pinned": true})
		}()
	}
	wg.Wait()
	okCount, full := 0, 0
	for _, r := range results {
		switch {
		case r.status == 200:
			okCount++
		case r.status == 409 && r.code == "PIN_LIMIT":
			full++
		default:
			t.Fatalf("unexpected %d %s", r.status, r.code)
		}
	}
	if okCount != 5 || full != 4 {
		t.Fatalf("%d pinned, %d refused: want 5 and 4", okCount, full)
	}
	var n int
	h.exec(`SELECT 1`)
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM conversation_members WHERE user_id=$1 AND pinned_at IS NOT NULL`, alice).Scan(&n); err != nil || n != 5 {
		t.Fatalf("%d rows pinned (%v)", n, err)
	}
}

func TestListLeadsWithPinnedChatsAndPagesTheRest(t *testing.T) {
	h := newSocialHarness(t)
	c := h.chatsWith(alice, 8) // c[0] is the newest, c[7] the oldest
	h.expect(h.pin(alice, c[6].convo, true), 200, "")
	h.expect(h.pin(alice, c[3].convo, true), 200, "")

	first := h.listPage(alice, "?limit=3")
	same(t, convoIDs(first), c[3].convo, c[6].convo, c[0].convo, c[1].convo, c[2].convo) // pinned by recency, then the page
	if first["hasMore"] != true || first["nextCursor"] == nil {
		t.Fatalf("first page %v", first)
	}
	for i, item := range items(first) {
		if (i < 2) != (item["pinnedAt"] != nil) {
			t.Fatalf("item %d pinnedAt %v", i, item["pinnedAt"])
		}
	}
	second := h.listPage(alice, "?limit=3&cursor="+url.QueryEscape(first["nextCursor"].(string)))
	same(t, convoIDs(second), c[4].convo, c[5].convo, c[7].convo) // never a pinned chat again
	if second["hasMore"] != false || second["nextCursor"] != nil {
		t.Fatalf("second page %v", second)
	}
	// Without a limit and with pins at the end of the list, the pinned still lead.
	all := h.listPage(alice, "")
	same(t, convoIDs(all), c[3].convo, c[6].convo, c[0].convo, c[1].convo, c[2].convo, c[4].convo, c[5].convo, c[7].convo)
	// A cursor made for the list still works for the same account only.
	h.api.lists.reset(bob)
	h.expect(h.send(bob, "GET", "/v1/conversations?cursor="+url.QueryEscape(first["nextCursor"].(string)), nil), 422, "INVALID_CURSOR")
	// A pinned chat is not repeated by a limit of 1 either: page through everything.
	seen := map[string]int{}
	query := "?limit=1"
	for pages := 0; pages < 20; pages++ {
		page := h.listPage(alice, query)
		for _, id := range convoIDs(page) {
			seen[id]++
		}
		if page["nextCursor"] == nil {
			break
		}
		query = "?limit=1&cursor=" + url.QueryEscape(page["nextCursor"].(string))
	}
	if len(seen) != 8 {
		t.Fatalf("saw %d chats: %v", len(seen), seen)
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("chat %s listed %d times", id, n)
		}
	}
	// The peer's list has no pins.
	for _, item := range items(h.listPage(c[3].user, "")) {
		if item["pinnedAt"] != nil {
			t.Fatalf("peer sees a pin: %v", item)
		}
	}
}

func TestPinNeedsAVisibleChatAndBarredPinsFreeTheirSlot(t *testing.T) {
	h := newSocialHarness(t)
	c := h.chatsWith(alice, 7)
	// A deleted chat cannot be pinned.
	h.expect(h.call(alice, "POST", "/v1/conversations/"+c[0].convo+"/hide"), 200, "")
	h.expect(h.pin(alice, c[0].convo, true), 404, "NOT_FOUND")
	// A blocked peer's chat cannot be pinned.
	h.ok(c[1].user, "POST", "/v1/users/"+alice+"/block")
	h.expect(h.pin(alice, c[1].convo, true), 404, "NOT_FOUND")
	// A member in the other age band is barred like a block.
	h.ageAt(alice, 30)
	h.ageAt(c[2].user, 15)
	h.expect(h.pin(alice, c[2].convo, true), 404, "NOT_FOUND")

	// A pinned chat that becomes unreachable leaves the list and does not use up the limit.
	h.expect(h.pin(alice, c[3].convo, true), 200, "")
	h.expect(h.pin(alice, c[4].convo, true), 200, "")
	h.expect(h.pin(alice, c[5].convo, true), 200, "")
	h.expect(h.pin(alice, c[6].convo, true), 200, "")
	h.ok(c[3].user, "POST", "/v1/users/"+alice+"/block")
	for _, id := range convoIDs(h.listPage(alice, "")) {
		if id == c[3].convo {
			t.Fatal("a blocked pinned chat is listed")
		}
	}
	// Three more chats to pin: with c[3] gone only 3 count, so two more fit.
	extra := h.chatsWith(alice, 3)
	h.expect(h.pin(alice, extra[0].convo, true), 200, "")
	h.expect(h.pin(alice, extra[1].convo, true), 200, "")
	h.expect(h.pin(alice, extra[2].convo, true), 409, "PIN_LIMIT")
}

func TestHideRestoreAndTheDeletedChatsList(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	convo := strings.TrimPrefix(path, "/v1/conversations/")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	h.expect(h.pin(alice, convo, true), 200, "")
	messages := func() int {
		var n int
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM messages WHERE conversation_id=$1`, convo).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := messages()

	hidden := h.expect(h.call(alice, "POST", path+"/hide"), 200, "").data
	if hidden["hidden"] != true || hidden["hiddenAt"] == nil || hidden["restoreUntil"] == nil || len(hidden) != 3 {
		t.Fatalf("hide %v", hidden)
	}
	hiddenAt, _ := time.Parse(time.RFC3339Nano, hidden["hiddenAt"].(string))
	restoreUntil, _ := time.Parse(time.RFC3339Nano, hidden["restoreUntil"].(string))
	if d := restoreUntil.Sub(hiddenAt); d != 30*24*time.Hour {
		t.Fatalf("restore window %v", d)
	}
	// Nothing but alice's own row changed: messages stay, unread stays, the pin is gone, bob sees nothing.
	if messages() != before {
		t.Fatal("hiding touched messages")
	}
	var unread int
	var pinned *time.Time
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT unread_count,pinned_at FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, convo, alice).Scan(&unread, &pinned); err != nil || unread != 1 || pinned != nil {
		t.Fatalf("alice's row unread=%d pinned=%v %v", unread, pinned, err)
	}
	var bobHidden int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM conversation_members WHERE conversation_id=$1 AND user_id=$2 AND (hidden_at IS NOT NULL OR closed_at IS NOT NULL)`, convo, bob).Scan(&bobHidden); err != nil || bobHidden != 0 {
		t.Fatalf("bob's row changed: %d %v", bobHidden, err)
	}
	if same := convoIDs(h.listPage(bob, "")); len(same) != 1 || same[0] != convo {
		t.Fatalf("bob's list %v", same)
	}
	// Idempotent: hiding again keeps the earlier hiddenAt.
	time.Sleep(15 * time.Millisecond)
	if again := h.expect(h.call(alice, "POST", path+"/hide"), 200, "").data; again["hiddenAt"] != hidden["hiddenAt"] {
		t.Fatalf("hiddenAt moved: %v -> %v", hidden["hiddenAt"], again["hiddenAt"])
	}
	// Out of the list; in the single GET with hiddenAt and restoreUntil.
	if got := convoIDs(h.listPage(alice, "")); len(got) != 0 {
		t.Fatalf("hidden chat listed: %v", got)
	}
	single := h.ok(alice, "GET", path)
	if single["hiddenAt"] != hidden["hiddenAt"] || single["restoreUntil"] != hidden["restoreUntil"] || single["pinnedAt"] != nil {
		t.Fatalf("single %v", single)
	}
	if visible := h.ok(bob, "GET", path); visible["hiddenAt"] != nil || visible["restoreUntil"] != nil {
		t.Fatalf("bob's single %v", visible)
	}
	// The Deleted-chats list.
	h.api.lists.reset(alice)
	list := h.ok(alice, "GET", "/v1/conversations/hidden")
	if len(items(list)) != 1 || items(list)[0]["conversationId"] != convo || items(list)[0]["hiddenAt"] != hidden["hiddenAt"] || items(list)[0]["restoreUntil"] != hidden["restoreUntil"] {
		t.Fatalf("hidden list %v", list)
	}
	if closed, ok := list["closedIds"].([]any); !ok || len(closed) != 0 || list["retentionDays"] != float64(30) || len(list) != 3 {
		t.Fatalf("hidden list envelope %v", list)
	}
	// Bob's Deleted-chats list is empty.
	h.api.lists.reset(bob)
	if len(items(h.ok(bob, "GET", "/v1/conversations/hidden"))) != 0 {
		t.Fatal("bob has a deleted chat")
	}
	// Restore brings it back; again is 404 (it is not hidden); the pin does not come back.
	h.api.graph.reset(alice)
	if got := h.expect(h.call(alice, "POST", path+"/restore"), 200, "").data; got["hidden"] != false || len(got) != 1 {
		t.Fatalf("restore %v", got)
	}
	h.expect(h.call(alice, "POST", path+"/restore"), 404, "NOT_FOUND")
	got := h.listPage(alice, "")
	if len(items(got)) != 1 || items(got)[0]["pinnedAt"] != nil || items(got)[0]["hiddenAt"] != nil || items(got)[0]["unreadCount"] != float64(1) {
		t.Fatalf("restored list %v", got)
	}
	h.api.lists.reset(alice)
	if len(items(h.ok(alice, "GET", "/v1/conversations/hidden"))) != 0 {
		t.Fatal("restored chat still in Deleted chats")
	}

	// Membership: a stranger and an unknown or malformed id are 404.
	h.expect(h.call(cara, "POST", path+"/hide"), 404, "NOT_FOUND")
	h.expect(h.call(cara, "POST", path+"/restore"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/conversations/"+uuid.NewString()+"/hide"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/conversations/nope/hide"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", "/v1/conversations/nope/restore"), 404, "NOT_FOUND")
	// Wrong methods do not do it.
	if r := h.call(alice, "GET", path+"/hide"); r.status == 200 {
		t.Fatal("GET hide")
	}
	if r := h.call(alice, "DELETE", path+"/restore"); r.status == 200 {
		t.Fatal("DELETE restore")
	}
	if h.call(alice, "GET", "/v1/conversations/hidden").status != 200 {
		t.Fatal("hidden list route")
	}
}

func TestHiddenListHonoursBlocksAgeBandsAndTheNewestFirstOrder(t *testing.T) {
	h := newSocialHarness(t)
	c := h.chatsWith(alice, 4)
	for _, i := range []int{2, 0, 3, 1} {
		h.expect(h.call(alice, "POST", "/v1/conversations/"+c[i].convo+"/hide"), 200, "")
		h.api.graph.reset(alice)
		time.Sleep(10 * time.Millisecond)
	}
	list := func() []string {
		h.api.lists.reset(alice)
		return convoIDs(h.ok(alice, "GET", "/v1/conversations/hidden"))
	}
	same(t, list(), c[1].convo, c[3].convo, c[0].convo, c[2].convo) // most recently hidden first
	// A peer who blocked alice, or who is in the other age band, is not listed.
	h.ok(c[1].user, "POST", "/v1/users/"+alice+"/block")
	h.ageAt(alice, 30)
	h.ageAt(c[0].user, 15)
	same(t, list(), c[3].convo, c[2].convo)
	// At most 100 are listed.
	for i := 0; i < 101; i++ {
		id := uuid.NewString()
		h.user(id, fmt.Sprintf("bulk%d", i))
		var convo string
		if err := h.db.Pool.QueryRow(h.ctx, `INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) VALUES(gen_random_uuid(),least($1::uuid,$2::uuid),greatest($1::uuid,$2::uuid),$1,'active') RETURNING conversation_id::text`, alice, id).Scan(&convo); err != nil {
			t.Fatal(err)
		}
		h.exec(`INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at,hidden_at) VALUES($1,$2,$3,now(),now()),($1,$3,$2,now(),NULL)`, convo, alice, id)
	}
	if n := len(list()); n != 100 {
		t.Fatalf("listed %d, want 100", n)
	}
}

func TestHiddenChatClosesAfterThirtyDays(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	convo := strings.TrimPrefix(path, "/v1/conversations/")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	h.expect(h.call(alice, "POST", path+"/hide"), 200, "")
	other := h.chatsWith(alice, 1)[0]
	h.expect(h.call(alice, "POST", "/v1/conversations/"+other.convo+"/hide"), 200, "")
	age := func(c string, days int) {
		h.exec(`UPDATE conversation_members SET hidden_at=now()-make_interval(days=>$3) WHERE conversation_id=$1 AND user_id=$2`, c, alice, days)
	}
	hiddenList := func() map[string]any {
		h.api.lists.reset(alice)
		return h.ok(alice, "GET", "/v1/conversations/hidden")
	}

	// Inside the window nothing is closed.
	age(convo, 29)
	age(other.convo, 29)
	if n, err := h.db.CloseExpiredHiddenChats(h.ctx, domain.HiddenChatRetention, 5000); err != nil || n != 0 {
		t.Fatalf("closed %d %v", n, err)
	}
	if len(items(hiddenList())) != 2 {
		t.Fatal("29 day old chats left the list")
	}
	// Past it: before the job runs the chat is already out of the list and cannot be restored.
	age(convo, 31)
	age(other.convo, 31)
	if got := hiddenList(); len(items(got)) != 0 || len(got["closedIds"].([]any)) != 0 {
		t.Fatalf("expired but not closed yet: %v", got)
	}
	h.api.graph.reset(alice)
	h.expect(h.call(alice, "POST", path+"/restore"), 404, "NOT_FOUND")

	// The job closes them: one batch of 1, then the rest; unread goes to zero; a second run does nothing.
	if n, err := h.db.CloseExpiredHiddenChats(h.ctx, domain.HiddenChatRetention, 1); err != nil || n != 1 {
		t.Fatalf("batch of 1 closed %d %v", n, err)
	}
	if n, err := h.db.CloseExpiredHiddenChats(h.ctx, domain.HiddenChatRetention, 5000); err != nil || n != 1 {
		t.Fatalf("rest closed %d %v", n, err)
	}
	if n, err := h.db.CloseExpiredHiddenChats(h.ctx, domain.HiddenChatRetention, 5000); err != nil || n != 0 {
		t.Fatalf("second run closed %d %v", n, err)
	}
	var unread int
	var closed *time.Time
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT unread_count,closed_at FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, convo, alice).Scan(&unread, &closed); err != nil || unread != 0 || closed == nil {
		t.Fatalf("closed row unread=%d closed=%v %v", unread, closed, err)
	}
	// The peer's row is not closed.
	var bobClosed int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM conversation_members WHERE conversation_id=$1 AND closed_at IS NOT NULL AND user_id=$2`, convo, bob).Scan(&bobClosed); err != nil || bobClosed != 0 {
		t.Fatalf("bob's row closed: %d %v", bobClosed, err)
	}
	got := hiddenList()
	if len(items(got)) != 0 {
		t.Fatalf("closed chats listed: %v", got)
	}
	ids := map[string]bool{}
	for _, id := range got["closedIds"].([]any) {
		ids[id.(string)] = true
	}
	if len(ids) != 2 || !ids[convo] || !ids[other.convo] {
		t.Fatalf("closedIds %v", got["closedIds"])
	}
	// Closed: not restorable, not hideable again, not in the main list, not counted.
	h.api.graph.reset(alice)
	h.expect(h.call(alice, "POST", path+"/restore"), 404, "NOT_FOUND")
	h.expect(h.call(alice, "POST", path+"/hide"), 404, "NOT_FOUND")
	h.expect(h.pin(alice, convo, true), 404, "NOT_FOUND")
	if len(convoIDs(h.listPage(alice, ""))) != 0 {
		t.Fatal("closed chat listed")
	}
	if got := h.ok(alice, "GET", "/v1/conversations/unread"); got["messages"] != float64(0) {
		t.Fatalf("closed chat counts: %v", got)
	}
	// closedIds are kept for 90 days only.
	h.exec(`UPDATE conversation_members SET closed_at=now()-interval '91 days' WHERE conversation_id=$1 AND user_id=$2`, other.convo, alice)
	if got := hiddenList()["closedIds"].([]any); len(got) != 1 || got[0] != convo {
		t.Fatalf("closedIds after 91 days %v", got)
	}
	// A message from the peer reopens it as a fresh visible chat on both rows and clears the closed id.
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	var open int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM conversation_members WHERE conversation_id=$1 AND hidden_at IS NULL AND closed_at IS NULL`, convo).Scan(&open); err != nil || open != 2 {
		t.Fatalf("%d rows open (%v)", open, err)
	}
	got = h.listPage(alice, "")
	if len(items(got)) != 1 || items(got)[0]["conversationId"] != convo || items(got)[0]["unreadCount"] != float64(1) || items(got)[0]["hiddenAt"] != nil {
		t.Fatalf("reopened list %v", got)
	}
	if ids := hiddenList()["closedIds"].([]any); len(ids) != 0 {
		t.Fatalf("closedIds after reopening %v", ids)
	}
	// Account rows of a deleted chat carry the constraint: closed without hidden is impossible.
	if _, err := h.db.Pool.Exec(h.ctx, `UPDATE conversation_members SET closed_at=now() WHERE conversation_id=$1 AND user_id=$2`, convo, alice); err == nil {
		t.Fatal("a closed chat that is not hidden was accepted")
	}
}

func TestMessagesBringAHiddenChatBackButReactionsDoNot(t *testing.T) {
	h := newSocialHarness(t)
	var mu sync.Mutex
	now := time.Now()
	log, _ := pushing(t, h, func(c *push.Config) { c.Now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now } })
	path, phone, bobPhone := friendsWithChat(h)
	convo := strings.TrimPrefix(path, "/v1/conversations/")
	h.token(phone, "alice-phone-token")
	h.token(bobPhone, "bob-phone-token")
	hiddenAt := func(user string) *time.Time {
		var at *time.Time
		if err := h.db.Pool.QueryRow(h.ctx, `SELECT hidden_at FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, convo, user).Scan(&at); err != nil {
			t.Fatal(err)
		}
		return at
	}
	hide := func(user string) {
		h.api.graph.reset(user)
		h.expect(h.call(user, "POST", path+"/hide"), 200, "")
	}

	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	log.wait(t, 1)
	hide(alice)
	// A reaction does not bring it back (and never pushes).
	h.expect(h.send(bob, "POST", path+"/messages", auxMessage(bobPhone, phone)), 200, "")
	if hiddenAt(alice) == nil {
		t.Fatal("a reaction brought the chat back")
	}
	log.quiet(t, 1, "reaction")
	// A real message does, on both rows, and pushes like any message to a chat that is not hidden (the push
	// throttle of one chat has passed by then).
	mu.Lock()
	now = now.Add(10 * time.Minute)
	mu.Unlock()
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	log.wait(t, 2)
	if hiddenAt(alice) != nil {
		t.Fatal("a message did not bring the chat back")
	}
	if got := h.listPage(alice, ""); len(items(got)) != 1 || items(got)[0]["unreadCount"] != float64(2) {
		t.Fatalf("list after a message %v", got)
	}

	// Alice answers (lifting bob's first-contact cap), then both hide; bob's message brings the chat back for
	// both rows (the sender's too).
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	hide(alice)
	hide(bob)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	if hiddenAt(alice) != nil || hiddenAt(bob) != nil {
		t.Fatal("a message left a row hidden")
	}
	// Alice's own message while she has it deleted brings it back for her as well.
	hide(alice)
	h.expect(h.send(alice, "POST", path+"/messages", message(phone, bobPhone)), 200, "")
	if hiddenAt(alice) != nil {
		t.Fatal("sending did not bring the chat back")
	}
	// Opening the chat on purpose un-hides the opener's row only.
	hide(alice)
	hide(bob)
	h.api.firstChats.reset(alice)
	opened := h.expect(h.send(alice, "POST", "/v1/conversations", map[string]string{"userId": bob}), 200, "").data
	if opened["conversationId"] != convo || opened["hiddenAt"] != nil {
		t.Fatalf("open %v", opened)
	}
	if hiddenAt(alice) != nil || hiddenAt(bob) == nil {
		t.Fatalf("opening changed the wrong rows: alice %v bob %v", hiddenAt(alice), hiddenAt(bob))
	}
}

func TestUnreadBadgeLeavesOutDeletedChats(t *testing.T) {
	h := newSocialHarness(t)
	path, phone, bobPhone := friendsWithChat(h)
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	h.expect(h.send(bob, "POST", path+"/messages", message(bobPhone, phone)), 200, "")
	if got := h.ok(alice, "GET", "/v1/conversations/unread"); got["messages"] != float64(2) || got["conversations"] != float64(1) {
		t.Fatalf("unread %v", got)
	}
	h.expect(h.call(alice, "POST", path+"/hide"), 200, "")
	if got := h.ok(alice, "GET", "/v1/conversations/unread"); got["messages"] != float64(0) || got["conversations"] != float64(0) {
		t.Fatalf("unread of a deleted chat counts: %v", got)
	}
	if got := h.ok(bob, "GET", "/v1/conversations/unread"); got["messages"] != float64(0) {
		t.Fatalf("bob %v", got)
	}
	h.api.graph.reset(alice)
	h.expect(h.call(alice, "POST", path+"/restore"), 200, "")
	if got := h.ok(alice, "GET", "/v1/conversations/unread"); got["messages"] != float64(2) {
		t.Fatalf("unread after restore %v", got)
	}
}

func TestChatListFeaturesNeedAuthentication(t *testing.T) {
	h := newSocialHarness(t)
	c := h.chatsWith(alice, 1)[0]
	anonymous := func(method, path string) int {
		r := httptest.NewRequest(method, path, bytes.NewBufferString("{}"))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "127.0.0.1:50000"
		w := httptest.NewRecorder()
		h.api.Handler().ServeHTTP(w, r)
		return w.Code
	}
	for _, call := range [][2]string{{"PUT", "/pin"}, {"POST", "/hide"}, {"POST", "/restore"}} {
		if got := anonymous(call[0], "/v1/conversations/"+c.convo+call[1]); got != 401 {
			t.Fatalf("%s %s without a token: %d", call[0], call[1], got)
		}
	}
	if got := anonymous("GET", "/v1/conversations/hidden"); got != 401 {
		t.Fatalf("hidden list without a token: %d", got)
	}
}
