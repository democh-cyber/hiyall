package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

const (
	uploadURLLifetime = 15 * time.Minute
	// Read URLs outlive a feed session but not much more; clients cache bytes
	// by media id, so a refreshed URL doesn't refetch.
	readURLLifetime = time.Hour
)

// uploadPurposes are what a photo upload may be for; an avatar is attached through the profile.
var uploadPurposes = map[string]bool{"post": true, "story": true, "avatar": true}

// signer mints read URLs for media the store just authorized.
func (a *API) signer(ctx context.Context) store.Signer {
	return func(key string) string {
		if a.Media == nil || key == "" {
			return ""
		}
		u, err := a.Media.PresignGet(ctx, key, readURLLifetime)
		if err != nil {
			return ""
		}
		return u
	}
}

func postKey(p domain.Post) (time.Time, string)       { return p.SortAt, p.PostID }
func commentKey(c domain.Comment) (time.Time, string) { return c.CreatedAt, c.CommentID }

// mediaSlotWait is how long an upload waits for a processing slot before it is told to retry.
const mediaSlotWait = 4 * time.Second

// errMediaBusy is answered as 503 MEDIA_BUSY with Retry-After when every processing slot stayed busy.
var errMediaBusy = errors.New("media processing busy")

var mediaBusy = metrics.NewCounter("hiyall_media_busy_total", "Photo uploads refused with 503 because every processing slot stayed busy.")

// SetMediaSlots sets how many uploads this node decodes at once (MEDIA_PROCESS_SLOTS, default 2). Decode
// memory is about media.ProcessHeapBudget per slot. Call it before serving.
func (a *API) SetMediaSlots(n int) {
	if n < 1 {
		n = 1
	}
	a.mediaSlots = make(chan struct{}, n)
}

// completeUpload turns an uploaded object into stored variants. Decoding is
// CPU-heavy and memory-heavy, so at most cap(a.mediaSlots) run at once per node; at scale this
// moves to a media worker behind a queue.
func (a *API) completeUpload(ctx context.Context, owner, id string) (map[string]any, error) {
	upload, err := a.Store.PendingUpload(ctx, owner, id)
	if err != nil {
		return nil, err
	}
	slots := a.mediaSlots
	wait := time.NewTimer(mediaSlotWait)
	defer wait.Stop()
	select {
	case slots <- struct{}{}:
		defer func() { <-slots }()
	case <-wait.C:
		// Every slot has been busy for the whole wait: say so and let the app retry (the photo stays pending).
		mediaBusy.Inc()
		return nil, errMediaBusy
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	data, err := a.Media.Get(ctx, upload.Key, upload.Size)
	if err != nil {
		return nil, &domain.ValidationError{Field: "upload", Message: "upload the photo first, at the size you declared"}
	}
	out, err := media.Process(data)
	if err != nil {
		_ = a.Media.Delete(ctx, upload.Key)
		return nil, &domain.PolicyError{Status: 415, Code: "UNSUPPORTED_MEDIA", Message: "That photo couldn’t be read. Try a JPEG, PNG or WebP."}
	}
	// Scan before anything is stored for display. A scanner that cannot answer leaves the upload pending
	// (fail closed); a flag or a match quarantines it and never reaches the variants below.
	if a.Scanner != nil {
		res, scanErr := a.Scanner.Scan(ctx, media.ScanInput{Original: data, Full: out.Full})
		if scanErr != nil {
			slog.Error("upload scan failed; the photo stays unavailable", "mediaId", id, "reason", scanErr.Error())
			return nil, &domain.PolicyError{Status: 503, Code: "SCAN_UNAVAILABLE", Message: "We couldn’t check that photo right now. Try again in a moment."}
		}
		if res.Verdict != media.Clean {
			return nil, a.quarantineUpload(ctx, owner, id, upload, data, out, res)
		}
	}
	full, thumb := "media/"+id+"/full.jpg", "media/"+id+"/thumb.jpg"
	if err = a.Media.Put(ctx, full, out.Full, "image/jpeg"); err == nil {
		err = a.Media.Put(ctx, thumb, out.Thumb, "image/jpeg")
	}
	if err != nil {
		return nil, err
	}
	// The original may carry location metadata; only the re-encoded copies stay.
	if err = a.Media.Delete(ctx, upload.Key); err != nil {
		slog.Warn("original upload not deleted", "mediaId", id, "reason", scrubURLs(err.Error()))
	}
	if err = a.Store.MediaReady(ctx, owner, id, out.Width, out.Height, full, thumb, int64(len(out.Full)+len(out.Thumb))); err != nil {
		return nil, err
	}
	sign := a.signer(ctx)
	return map[string]any{"mediaId": id, "status": "ready", "width": out.Width, "height": out.Height, "url": sign(full), "thumbUrl": sign(thumb)}, nil
}

// Media uploads, posts, the feed, reactions, comments, saves and stories. The per-account content and list
// limits are taken by the route table before these run (router.go); uploads take theirs after the storage
// check below, so a node without storage answers 503 first.

func (a *API) respond(w http.ResponseWriter, r *http.Request, value any, err error) {
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, value)
}

func (a *API) created(w http.ResponseWriter, r *http.Request, value any, err error) {
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.write(w, r, http.StatusCreated, map[string]any{"success": true, "data": value})
}

// jsonBody reads a JSON object body and returns it re-encoded for the strict domain parsers.
func (a *API) jsonBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	raw, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return nil, false
	}
	data, _ := json.Marshal(raw)
	return data, true
}

// idempotencyHeader names the optional client key on creating a post, a story or a space entry (docs/api/16).
const idempotencyHeader = "Idempotency-Key"

// idempotency reads the optional Idempotency-Key: a UUID the client makes once per attempt and reuses on every
// retry. body is what the request creates from; the same key with another body is refused by the store.
func (a *API) idempotency(w http.ResponseWriter, r *http.Request, body []byte) (store.Idem, bool) {
	raw := r.Header.Get(idempotencyHeader)
	if raw == "" {
		return store.Idem{}, true
	}
	key, err := uuid.Parse(raw)
	if err != nil || len(raw) != 36 {
		a.failure(w, r, 422, "VALIDATION", "Idempotency-Key must be a UUID")
		return store.Idem{}, false
	}
	sum := sha256.Sum256(body)
	return store.Idem{Key: key.String(), Hash: sum[:]}, true
}

// markReplay says on the response that it repeats an earlier one.
func markReplay(w http.ResponseWriter, replayed bool) {
	if replayed {
		w.Header().Set("Idempotent-Replayed", "true")
	}
}

func (a *API) needMedia(w http.ResponseWriter, r *http.Request) bool {
	if a.Media != nil {
		return true
	}
	a.failure(w, r, 503, "MEDIA_UNAVAILABLE", "Photo uploads aren’t available right now")
	return false
}

func (a *API) uploadMedia(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	if !a.needMedia(w, r) || !a.admit(w, r, p, limitUploads) {
		return
	}
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	var in struct {
		Purpose     string `json:"purpose"`
		ContentType string `json:"contentType"`
		SizeBytes   int64  `json:"sizeBytes"`
	}
	if strictDecode(raw, &in) != nil || !uploadPurposes[in.Purpose] {
		a.failure(w, r, 422, "VALIDATION", "send purpose (post, story or avatar), contentType and sizeBytes")
		return
	}
	if !media.ContentTypes[in.ContentType] {
		a.failure(w, r, 415, "UNSUPPORTED_MEDIA", "Photos must be JPEG, PNG or WebP")
		return
	}
	if in.SizeBytes < 1 || in.SizeBytes > media.MaxUploadBytes {
		a.failure(w, r, 413, "TOO_LARGE", "Photos can be up to 15 MB")
		return
	}
	id, key, err := a.Store.CreateUpload(ctx, p.UserID, in.Purpose, in.ContentType, in.SizeBytes, a.entitlementsFor(ctx, p.UserID))
	if err != nil {
		a.error(w, r, err)
		return
	}
	url, headers, err := a.Media.PresignPut(ctx, key, in.ContentType, in.SizeBytes, uploadURLLifetime)
	if err != nil {
		a.error(w, r, err)
		return
	}
	flat := map[string]string{}
	for k := range headers {
		flat[k] = headers.Get(k)
	}
	a.created(w, r, map[string]any{"mediaId": id, "uploadUrl": url, "method": "PUT", "headers": flat, "expiresAt": time.Now().Add(uploadURLLifetime).UTC()}, nil)
}

func (a *API) completeMedia(w http.ResponseWriter, r *http.Request, p store.Principal) {
	if !a.needMedia(w, r) {
		return
	}
	value, err := a.completeUpload(r.Context(), p.UserID, r.PathValue("mediaId"))
	if errors.Is(err, errMediaBusy) {
		w.Header().Set("Retry-After", "5")
		a.failure(w, r, 503, "MEDIA_BUSY", "We’re processing a lot of photos right now. Try again in a few seconds.")
		return
	}
	a.respond(w, r, value, err)
}

func (a *API) feed(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	mode := r.URL.Query().Get("mode")
	if mode == "" {
		mode = "following"
	}
	if mode != "following" && mode != "everyone" {
		a.failure(w, r, 422, "VALIDATION", "mode must be following or everyone")
		return
	}
	sign := a.signer(ctx)
	paged(a, w, r, p, "feed:"+mode, func(pg page) ([]domain.Post, error) {
		return a.Store.Feed(ctx, p.UserID, mode, pg.before, pg.id, pg.limit, sign)
	}, postKey, nil)
}

func (a *API) createPost(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	idem, ok := a.idempotency(w, r, raw)
	if !ok {
		return
	}
	in, err := domain.ParsePost(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	id, replayed, err := a.Store.CreatePostOnce(ctx, p.UserID, in, a.entitlementsFor(ctx, p.UserID), idem)
	if err != nil {
		a.error(w, r, err)
		return
	}
	markReplay(w, replayed)
	value, err := a.Store.Post(ctx, p.UserID, id, a.signer(ctx))
	a.created(w, r, value, err)
}

func (a *API) getPost(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	value, err := a.Store.Post(ctx, p.UserID, r.PathValue("postId"), a.signer(ctx))
	a.respond(w, r, value, err)
}

func (a *API) deletePost(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]bool{"deleted": true}, a.Store.DeletePost(r.Context(), p.UserID, r.PathValue("postId")))
}

func (a *API) setReaction(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	var in struct {
		Reaction string `json:"reaction"`
	}
	if strictDecode(raw, &in) != nil || !domain.Reactions[in.Reaction] {
		a.failure(w, r, 422, "VALIDATION", "reaction must be heart, fire, laugh, wow or sad")
		return
	}
	author, err := a.Store.SetReaction(ctx, p.UserID, r.PathValue("postId"), in.Reaction)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if author != p.UserID {
		a.signal(ctx, "activity", nil, author)
	}
	a.ok(w, r, map[string]string{"reaction": in.Reaction})
}

func (a *API) removeReaction(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]any{"reaction": nil}, a.Store.RemoveReaction(r.Context(), p.UserID, r.PathValue("postId")))
}

// savePost is PUT (save) and DELETE (unsave) /v1/posts/{postId}/save.
func (a *API) savePost(w http.ResponseWriter, r *http.Request, p store.Principal) {
	save := r.Method == http.MethodPut
	a.respond(w, r, map[string]bool{"saved": save}, a.Store.SetSaved(r.Context(), p.UserID, r.PathValue("postId"), save))
}

func (a *API) postComments(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("postId")
	sign := a.signer(ctx)
	paged(a, w, r, p, "comments:"+id, func(pg page) ([]domain.Comment, error) {
		return a.Store.Comments(ctx, p.UserID, id, pg.before, pg.id, pg.limit, sign)
	}, commentKey, nil)
}

func (a *API) addComment(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	in, err := domain.ParseComment(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	comment, author, hidden, err := a.Store.AddComment(ctx, p.UserID, r.PathValue("postId"), in, a.signer(ctx), a.entitlementsFor(ctx, p.UserID))
	if err != nil {
		a.error(w, r, err)
		return
	}
	if author != p.UserID && !hidden {
		a.signal(ctx, "activity", nil, author)
	}
	a.created(w, r, comment, nil)
}

func (a *API) deleteComment(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]bool{"deleted": true}, a.Store.DeleteComment(r.Context(), p.UserID, r.PathValue("commentId")))
}

func (a *API) userPosts(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("userId")
	sign := a.signer(ctx)
	paged(a, w, r, p, "posts:"+id, func(pg page) ([]domain.Post, error) {
		return a.Store.UserPosts(ctx, p.UserID, id, pg.before, pg.id, pg.limit, sign)
	}, postKey, nil)
}

func (a *API) savedPosts(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	sign := a.signer(ctx)
	paged(a, w, r, p, "saved", func(pg page) ([]domain.Post, error) {
		return a.Store.Saved(ctx, p.UserID, pg.before, pg.id, pg.limit, sign)
	}, postKey, nil)
}

func (a *API) createStory(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	idem, ok := a.idempotency(w, r, raw)
	if !ok {
		return
	}
	in, err := domain.ParseStory(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	id, replayed, err := a.Store.CreateStoryOnce(ctx, p.UserID, in, a.entitlementsFor(ctx, p.UserID), idem)
	if err == nil {
		markReplay(w, replayed)
	}
	a.created(w, r, map[string]string{"storyId": id}, err)
}

func (a *API) storyTray(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	groups, err := a.Store.StoryTray(ctx, p.UserID, a.signer(ctx))
	a.respond(w, r, map[string]any{"items": groups}, err)
}

func storyKey(s domain.Story) (time.Time, string) { return s.CreatedAt, s.StoryID }

func (a *API) myStories(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	sign := a.signer(ctx)
	paged(a, w, r, p, "my_stories", func(pg page) ([]domain.Story, error) {
		return a.Store.MyStories(ctx, p.UserID, pg.before, pg.id, pg.limit, sign)
	}, storyKey, nil)
}

func (a *API) userStories(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("userId")
	sign := a.signer(ctx)
	paged(a, w, r, p, "stories:"+id, func(pg page) ([]domain.Story, error) {
		return a.Store.UserStories(ctx, p.UserID, id, pg.before, pg.id, pg.limit, sign)
	}, storyKey, nil)
}

func (a *API) deleteStory(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]bool{"deleted": true}, a.Store.DeleteStory(r.Context(), p.UserID, r.PathValue("storyId")))
}

func (a *API) viewStory(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]bool{"viewed": true}, a.Store.ViewStory(r.Context(), p.UserID, r.PathValue("storyId")))
}

func (a *API) storyViewers(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("storyId")
	sign := a.signer(ctx)
	paged(a, w, r, p, "viewers:"+id, func(pg page) ([]domain.Connection, error) {
		return a.Store.StoryViewers(ctx, p.UserID, id, pg.before, pg.id, pg.limit, sign)
	}, connectionKey, nil)
}

func strictDecode(raw []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if d.More() {
		return errors.New("trailing data")
	}
	return nil
}

// quarantineUpload keeps a flagged or matched upload for review: the exact bytes and the processed copy are
// written under the hold prefix (never deleted by the cleanup, never signed for members), the store marks
// the media quarantined, opens the operator case and, for a match, suspends the uploader. Nothing is sent
// anywhere. The member gets a plain refusal that does not say what was found.
func (a *API) quarantineUpload(ctx context.Context, owner, id string, upload store.PendingUpload, original []byte, out media.Processed, res media.ScanResult) error {
	originalKey, fullKey := media.HoldKeys(id)
	// The evidence bucket's token can write but not read or delete, so the API cannot be made to destroy
	// what it just kept. In development it is the media bucket under hold/.
	evidence := a.evidenceStore()
	// The case row goes first, as 'pending', and the objects second: an object in the bucket then never exists
	// without a case that names it. If a write fails the case stays pending and the console's sweep drops it once an
	// hour has passed and the objects are missing (round-3 audit API-6/7).
	caseID, err := a.Store.BeginQuarantine(ctx, store.Quarantine{
		MediaID: id, Owner: owner, Purpose: upload.Purpose, Result: string(res.Verdict), Scanner: res.Scanner, Signals: res.Signals,
		OriginalSHA256: media.SHA256Hex(original), OriginalBytes: int64(len(original)), ContentType: upload.ContentType, OriginalKey: originalKey, FullKey: fullKey,
		RetentionDays: a.safe.retentionDays,
	})
	if err != nil {
		return err
	}
	if res.Verdict == media.Match {
		// The uploader is already suspended in the database; close their live sockets whatever happens next.
		defer a.endSessions(ctx, owner, "", "")
	}
	if err := evidence.Put(ctx, originalKey, original, upload.ContentType); err != nil {
		return err
	}
	if err := evidence.Put(ctx, fullKey, out.Full, "image/jpeg"); err != nil {
		return err
	}
	if err = a.Store.ActivateQuarantine(ctx, caseID); err != nil {
		return err
	}
	a.quarantineAlert(ctx, caseID, id, string(res.Verdict))
	if err = a.Media.Delete(ctx, upload.Key); err != nil {
		slog.Warn("quarantined upload not removed from the upload prefix", "mediaId", id, "reason", err.Error())
	}
	return &domain.PolicyError{Status: 422, Code: "UPLOAD_REJECTED", Message: "That photo can’t be used."}
}
