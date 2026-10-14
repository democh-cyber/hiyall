package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
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

// completeUpload turns an uploaded object into stored variants. Decoding is
// CPU-heavy, so at most len(a.mediaSlots) run at once per node; at scale this
// moves to a media worker behind a queue.
func (a *API) completeUpload(ctx context.Context, owner, id string) (map[string]any, error) {
	upload, err := a.Store.PendingUpload(ctx, owner, id)
	if err != nil {
		return nil, err
	}
	select {
	case a.mediaSlots <- struct{}{}:
		defer func() { <-a.mediaSlots }()
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

// pulseRoute serves media uploads, posts, the feed, reactions, comments,
// saves and stories.
func (a *API) pulseRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n, method := len(parts), r.Method
	if n < 2 || parts[0] != "v1" {
		return false
	}
	sign := a.signer(ctx)
	respond := func(value any, err error) {
		if err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, value)
	}
	created := func(value any, err error) {
		if err != nil {
			a.error(w, r, err)
			return
		}
		a.write(w, r, http.StatusCreated, map[string]any{"success": true, "data": value})
	}
	body := func() ([]byte, bool) {
		raw, err := decode(w, r)
		if err != nil {
			a.error(w, r, err)
			return nil, false
		}
		data, _ := json.Marshal(raw)
		return data, true
	}
	allow := func(l *keyedLimiter) bool {
		if l.allow(p.UserID) {
			return true
		}
		w.Header().Set("Retry-After", "5")
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
		return false
	}
	needMedia := func() bool {
		if a.Media != nil {
			return true
		}
		a.failure(w, r, 503, "MEDIA_UNAVAILABLE", "Photo uploads aren’t available right now")
		return false
	}
	posts := func(fetch func(pg page) ([]domain.Post, error), kind string) {
		paged(a, w, r, p, kind, fetch, postKey, nil)
	}

	switch {
	case n == 3 && parts[1] == "media" && parts[2] == "uploads" && method == "POST":
		if !needMedia() || !allow(a.uploads) {
			return true
		}
		raw, ok := body()
		if !ok {
			return true
		}
		var in struct {
			Purpose     string `json:"purpose"`
			ContentType string `json:"contentType"`
			SizeBytes   int64  `json:"sizeBytes"`
		}
		if strictDecode(raw, &in) != nil || !uploadPurposes[in.Purpose] {
			a.failure(w, r, 422, "VALIDATION", "send purpose (post, story or avatar), contentType and sizeBytes")
			return true
		}
		if !media.ContentTypes[in.ContentType] {
			a.failure(w, r, 415, "UNSUPPORTED_MEDIA", "Photos must be JPEG, PNG or WebP")
			return true
		}
		if in.SizeBytes < 1 || in.SizeBytes > media.MaxUploadBytes {
			a.failure(w, r, 413, "TOO_LARGE", "Photos can be up to 15 MB")
			return true
		}
		id, key, err := a.Store.CreateUpload(ctx, p.UserID, in.Purpose, in.ContentType, in.SizeBytes, a.entitlementsFor(ctx, p.UserID))
		if err != nil {
			a.error(w, r, err)
			return true
		}
		url, headers, err := a.Media.PresignPut(ctx, key, in.ContentType, in.SizeBytes, uploadURLLifetime)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		flat := map[string]string{}
		for k := range headers {
			flat[k] = headers.Get(k)
		}
		created(map[string]any{"mediaId": id, "uploadUrl": url, "method": "PUT", "headers": flat, "expiresAt": time.Now().Add(uploadURLLifetime).UTC()}, nil)
	case n == 4 && parts[1] == "media" && isID(parts[2]) && parts[3] == "complete" && method == "POST":
		if !needMedia() {
			return true
		}
		respond(a.completeUpload(ctx, p.UserID, parts[2]))
	case n == 2 && parts[1] == "feed" && method == "GET":
		mode := r.URL.Query().Get("mode")
		if mode == "" {
			mode = "following"
		}
		if mode != "following" && mode != "everyone" {
			a.failure(w, r, 422, "VALIDATION", "mode must be following or everyone")
			return true
		}
		posts(func(pg page) ([]domain.Post, error) {
			return a.Store.Feed(ctx, p.UserID, mode, pg.before, pg.id, pg.limit, sign)
		}, "feed:"+mode)
	case n == 2 && parts[1] == "posts" && method == "POST":
		if !allow(a.content) {
			return true
		}
		raw, ok := body()
		if !ok {
			return true
		}
		in, err := domain.ParsePost(raw)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		id, err := a.Store.CreatePost(ctx, p.UserID, in, a.entitlementsFor(ctx, p.UserID))
		if err != nil {
			a.error(w, r, err)
			return true
		}
		created(a.Store.Post(ctx, p.UserID, id, sign))
	case n == 3 && parts[1] == "posts" && isID(parts[2]) && method == "GET":
		respond(a.Store.Post(ctx, p.UserID, parts[2], sign))
	case n == 3 && parts[1] == "posts" && isID(parts[2]) && method == "DELETE":
		respond(map[string]bool{"deleted": true}, a.Store.DeletePost(ctx, p.UserID, parts[2]))
	case n == 4 && parts[1] == "posts" && isID(parts[2]) && parts[3] == "reaction" && method == "PUT":
		if !allow(a.content) {
			return true
		}
		raw, ok := body()
		if !ok {
			return true
		}
		var in struct {
			Reaction string `json:"reaction"`
		}
		if strictDecode(raw, &in) != nil || !domain.Reactions[in.Reaction] {
			a.failure(w, r, 422, "VALIDATION", "reaction must be heart, fire, laugh, wow or sad")
			return true
		}
		author, err := a.Store.SetReaction(ctx, p.UserID, parts[2], in.Reaction)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if author != p.UserID {
			a.signal(ctx, "activity", nil, author)
		}
		a.ok(w, r, map[string]string{"reaction": in.Reaction})
	case n == 4 && parts[1] == "posts" && isID(parts[2]) && parts[3] == "reaction" && method == "DELETE":
		respond(map[string]any{"reaction": nil}, a.Store.RemoveReaction(ctx, p.UserID, parts[2]))
	case n == 4 && parts[1] == "posts" && isID(parts[2]) && parts[3] == "save" && (method == "PUT" || method == "DELETE"):
		respond(map[string]bool{"saved": method == "PUT"}, a.Store.SetSaved(ctx, p.UserID, parts[2], method == "PUT"))
	case n == 4 && parts[1] == "posts" && isID(parts[2]) && parts[3] == "comments" && method == "GET":
		paged(a, w, r, p, "comments:"+parts[2], func(pg page) ([]domain.Comment, error) {
			return a.Store.Comments(ctx, p.UserID, parts[2], pg.before, pg.id, pg.limit, sign)
		}, commentKey, nil)
	case n == 4 && parts[1] == "posts" && isID(parts[2]) && parts[3] == "comments" && method == "POST":
		if !allow(a.content) {
			return true
		}
		raw, ok := body()
		if !ok {
			return true
		}
		in, err := domain.ParseComment(raw)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		comment, author, hidden, err := a.Store.AddComment(ctx, p.UserID, parts[2], in, sign, a.entitlementsFor(ctx, p.UserID))
		if err != nil {
			a.error(w, r, err)
			return true
		}
		if author != p.UserID && !hidden {
			a.signal(ctx, "activity", nil, author)
		}
		created(comment, nil)
	case n == 3 && parts[1] == "comments" && isID(parts[2]) && method == "DELETE":
		respond(map[string]bool{"deleted": true}, a.Store.DeleteComment(ctx, p.UserID, parts[2]))
	case n == 4 && parts[1] == "users" && isID(parts[2]) && parts[3] == "posts" && method == "GET":
		posts(func(pg page) ([]domain.Post, error) {
			return a.Store.UserPosts(ctx, p.UserID, parts[2], pg.before, pg.id, pg.limit, sign)
		}, "posts:"+parts[2])
	case n == 3 && parts[1] == "me" && parts[2] == "saved" && method == "GET":
		posts(func(pg page) ([]domain.Post, error) {
			return a.Store.Saved(ctx, p.UserID, pg.before, pg.id, pg.limit, sign)
		}, "saved")
	case n == 2 && parts[1] == "stories" && method == "POST":
		if !allow(a.content) {
			return true
		}
		raw, ok := body()
		if !ok {
			return true
		}
		in, err := domain.ParseStory(raw)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		id, err := a.Store.CreateStory(ctx, p.UserID, in, a.entitlementsFor(ctx, p.UserID))
		created(map[string]string{"storyId": id}, err)
	case n == 3 && parts[1] == "stories" && parts[2] == "tray" && method == "GET":
		groups, err := a.Store.StoryTray(ctx, p.UserID, sign)
		respond(map[string]any{"items": groups}, err)
	case n == 3 && parts[1] == "me" && parts[2] == "stories" && method == "GET":
		if !allow(a.lists) {
			return true
		}
		paged(a, w, r, p, "my_stories", func(pg page) ([]domain.Story, error) {
			return a.Store.MyStories(ctx, p.UserID, pg.before, pg.id, pg.limit, sign)
		}, func(s domain.Story) (time.Time, string) { return s.CreatedAt, s.StoryID }, nil)
	case n == 4 && parts[1] == "users" && isID(parts[2]) && parts[3] == "stories" && method == "GET":
		if !allow(a.lists) {
			return true
		}
		paged(a, w, r, p, "stories:"+parts[2], func(pg page) ([]domain.Story, error) {
			return a.Store.UserStories(ctx, p.UserID, parts[2], pg.before, pg.id, pg.limit, sign)
		}, func(s domain.Story) (time.Time, string) { return s.CreatedAt, s.StoryID }, nil)
	case n == 3 && parts[1] == "stories" && isID(parts[2]) && method == "DELETE":
		if !allow(a.content) {
			return true
		}
		respond(map[string]bool{"deleted": true}, a.Store.DeleteStory(ctx, p.UserID, parts[2]))
	case n == 4 && parts[1] == "stories" && isID(parts[2]) && parts[3] == "view" && method == "POST":
		respond(map[string]bool{"viewed": true}, a.Store.ViewStory(ctx, p.UserID, parts[2]))
	case n == 4 && parts[1] == "stories" && isID(parts[2]) && parts[3] == "viewers" && method == "GET":
		if !allow(a.lists) {
			return true
		}
		paged(a, w, r, p, "viewers:"+parts[2], func(pg page) ([]domain.Connection, error) {
			return a.Store.StoryViewers(ctx, p.UserID, parts[2], pg.before, pg.id, pg.limit, sign)
		}, connectionKey, nil)
	default:
		return false
	}
	return true
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
	if err := a.Media.Put(ctx, originalKey, original, upload.ContentType); err != nil {
		return err
	}
	if err := a.Media.Put(ctx, fullKey, out.Full, "image/jpeg"); err != nil {
		return err
	}
	caseID, err := a.Store.QuarantineMedia(ctx, store.Quarantine{
		MediaID: id, Owner: owner, Purpose: upload.Purpose, Result: string(res.Verdict), Scanner: res.Scanner, Signals: res.Signals,
		OriginalSHA256: media.SHA256Hex(original), OriginalBytes: int64(len(original)), ContentType: upload.ContentType, OriginalKey: originalKey, FullKey: fullKey,
	})
	if err != nil {
		return err
	}
	slog.Warn("upload quarantined", "caseId", caseID, "mediaId", id, "result", string(res.Verdict), "scanner", res.Scanner)
	if err = a.Media.Delete(ctx, upload.Key); err != nil {
		slog.Warn("quarantined upload not removed from the upload prefix", "mediaId", id, "reason", err.Error())
	}
	if res.Verdict == media.Match {
		a.endSessions(ctx, owner, "", "")
	}
	return &domain.PolicyError{Status: 422, Code: "UPLOAD_REJECTED", Message: "That photo can’t be used."}
}
