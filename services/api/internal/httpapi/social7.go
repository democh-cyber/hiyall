package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/store"
)

// Wave 7 social features (docs/api/27-stories-notices-support.md): topics, voice clips, threaded comments, post and
// story search, the Everyone stories list, My activity, notification choices, the notice board, in-app support and
// the profile visit notice.

// queryPtr is the value of a query parameter, nil when it is absent.
func queryPtr(r *http.Request, name string) *string {
	if !r.URL.Query().Has(name) {
		return nil
	}
	v := r.URL.Query().Get(name)
	return &v
}

// ---- Voice clips.

// completeVoice validates an uploaded voice clip and stores it as it is: an audio-only MP4 of at most the member's
// PulseVoiceSeconds. There is no transcoding and no scanner step (the scanner is image based); a file that is not
// a valid clip is refused with 415 and its upload deleted.
func (a *API) completeVoice(ctx context.Context, owner, id string, upload store.PendingUpload) (map[string]any, error) {
	data, err := a.Media.Get(ctx, upload.Key, upload.Size)
	if err != nil {
		return nil, &domain.ValidationError{Field: "upload", Message: "upload the voice note first, at the size you declared"}
	}
	seconds := a.entitlementsFor(ctx, owner).PulseVoiceSeconds
	ms, err := media.ValidateAudio(data, seconds)
	switch {
	case err == media.ErrAudioTooLong:
		_ = a.Media.Delete(ctx, upload.Key)
		return nil, domain.ErrVoiceTooLong
	case err != nil:
		_ = a.Media.Delete(ctx, upload.Key)
		return nil, &domain.PolicyError{Status: 415, Code: "UNSUPPORTED_MEDIA", Message: "That voice note couldn’t be read. Record it again."}
	}
	key := "media/" + id + "/voice.m4a"
	if err = a.Media.Put(ctx, key, data, "audio/mp4"); err != nil {
		return nil, err
	}
	if err = a.Media.Delete(ctx, upload.Key); err != nil {
		slog.Warn("original voice upload not deleted", "mediaId", id, "reason", scrubURLs(err.Error()))
	}
	if err = a.Store.MediaReadyAudio(ctx, owner, id, ms, key, int64(len(data))); err != nil {
		return nil, err
	}
	return map[string]any{"mediaId": id, "status": "ready", "durationMs": ms, "url": a.signer(ctx)(key)}, nil
}

// ---- Comments.

// commentSignals wakes the people a new comment is about: the post's author (once) and the author of the comment
// that was replied to. Whether a push goes out is the dispatcher's decision (mutes, blocks, age band, choices).
func (a *API) commentSignals(ctx context.Context, actor string, res store.CommentResult) {
	if res.Hidden {
		return
	}
	if res.PostAuthor != actor && res.RepliedTo != res.PostAuthor {
		a.signal(ctx, "activity", nil, res.PostAuthor)
		a.wakeFrom("comment", actor, res.PostAuthor)
	}
	if res.RepliedTo != "" {
		a.signal(ctx, "activity", nil, res.RepliedTo)
		a.wakeFrom("reply", actor, res.RepliedTo)
	}
}

// ---- Topics, the Everyone stories list, search.

func (a *API) topics(w http.ResponseWriter, r *http.Request, _ store.Principal) {
	a.ok(w, r, map[string]any{"items": domain.Topics})
}

func storyItemKey(s domain.StoryItem) (time.Time, string) { return s.CreatedAt, s.StoryID }

// exploreStories is GET /v1/stories/explore?topic=: public stories that are up now, newest first.
func (a *API) exploreStories(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	topic, err := domain.ParseTopic(queryPtr(r, "topic"))
	if err != nil {
		a.error(w, r, err)
		return
	}
	kind := "stories_explore"
	if topic != nil {
		kind += ":" + *topic
	}
	sign := a.signer(ctx)
	paged(a, w, r, p, kind, func(pg page) ([]domain.StoryItem, error) {
		return a.Store.ExploreStories(ctx, p.UserID, topic, pg.before, pg.id, pg.limit, sign)
	}, storyItemKey, nil)
}

type searchCursor struct {
	User  string    `json:"u"`
	Query string    `json:"q"`
	At    time.Time `json:"a"`
	After string    `json:"i"`
	Exp   int64     `json:"e"`
	Page  int       `json:"p"`
}

const searchCursorPrefix = "pulse-search\x00"

// searchPulse is GET /v1/search/pulse?q=&scope=posts|stories&topic=&cursor=: Postgres full text search over the
// text of posts or active stories the member may see. Every page counts against the member's PulseSearchPagesPerDay,
// the cursor is bound to the member and the search, and a search reads at most MaxSearchPages pages.
func (a *API) searchPulse(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, q := r.Context(), r.URL.Query()
	text, err := domain.ParseSearchQuery(q.Get("q"))
	if err != nil {
		a.error(w, r, err)
		return
	}
	scope := q.Get("scope")
	if scope == "" {
		scope = "posts"
	}
	if scope != "posts" && scope != "stories" {
		a.failure(w, r, 422, "VALIDATION", "scope must be posts or stories")
		return
	}
	topic, err := domain.ParseTopic(queryPtr(r, "topic"))
	if err != nil {
		a.error(w, r, err)
		return
	}
	if err = a.Store.BumpDaily(ctx, p.UserID, domain.DailyPulseSearchPages, a.entitlementsFor(ctx, p.UserID).PulseSearchPagesPerDay); err != nil {
		a.error(w, r, err)
		return
	}
	topicName := ""
	if topic != nil {
		topicName = *topic
	}
	sum := sha256.Sum256([]byte(scope + "\x00" + topicName + "\x00" + strings.ToLower(text)))
	query := hex.EncodeToString(sum[:])
	var after *time.Time
	afterID, page := "00000000-0000-0000-0000-000000000000", 0
	if raw := q.Get("cursor"); raw != "" {
		var c searchCursor
		if !openCursor(a, searchCursorPrefix, raw, &c) || c.User != p.UserID || c.Query != query || c.Exp <= time.Now().Unix() || c.Page <= 0 || c.Page >= domain.MaxSearchPages || !isID(c.After) {
			a.failure(w, r, 422, "INVALID_CURSOR", "Start a new search")
			return
		}
		at := c.At
		after, afterID, page = &at, c.After, c.Page
	}
	var items any
	var resume *store.SearchResume
	sign := a.signer(ctx)
	if scope == "stories" {
		items, resume, err = a.Store.SearchStories(ctx, p.UserID, text, topic, after, afterID, 20, sign)
	} else {
		items, resume, err = a.Store.SearchPosts(ctx, p.UserID, text, topic, after, afterID, 20, sign)
	}
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if resume != nil && page+1 < domain.MaxSearchPages {
		next = sealCursor(a, searchCursorPrefix, searchCursor{User: p.UserID, Query: query, At: resume.At, After: resume.ID, Exp: time.Now().Add(15 * time.Minute).Unix(), Page: page + 1})
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil, "scope": scope})
}

// ---- My activity.

func (a *API) myActivityComments(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	sign := a.signer(ctx)
	paged(a, w, r, p, "activity_comments", func(pg page) ([]domain.ActivityComment, error) {
		return a.Store.MyComments(ctx, p.UserID, pg.before, pg.id, pg.limit, sign)
	}, func(c domain.ActivityComment) (time.Time, string) { return c.CreatedAt, c.CommentID }, nil)
}

func (a *API) myActivityReactions(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	sign := a.signer(ctx)
	paged(a, w, r, p, "activity_reactions", func(pg page) ([]domain.ActivityReaction, error) {
		return a.Store.MyReactions(ctx, p.UserID, pg.before, pg.id, pg.limit, sign)
	}, func(x domain.ActivityReaction) (time.Time, string) { return x.CreatedAt, x.PostID }, nil)
}

// ---- Notification choices.

func (a *API) getNotificationPrefs(w http.ResponseWriter, r *http.Request, p store.Principal) {
	prefs, err := a.Store.NotificationPrefs(r.Context(), p.UserID)
	a.respond(w, r, prefs, err)
}

func (a *API) patchNotificationPrefs(w http.ResponseWriter, r *http.Request, p store.Principal) {
	raw, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return
	}
	patch, err := domain.ParseNotificationPrefs(raw)
	if err != nil {
		a.error(w, r, err)
		return
	}
	prefs, err := a.Store.SetNotificationPrefs(r.Context(), p.UserID, patch)
	a.respond(w, r, prefs, err)
}

// visitNotice is called after a profile visit was recorded for the first time. It creates the owner's Activity
// item and wakes them, when they opted in (the choice is off by default).
func (a *API) visitNotice(ctx context.Context, visitor, owner string) {
	created, named, err := a.Store.VisitNotice(ctx, visitor, owner)
	if err != nil {
		slog.Warn("profile visit notice not recorded", "reason", logscrub.Err(err))
		return
	}
	if !created {
		return
	}
	a.signal(ctx, "activity", nil, owner)
	kind := "visit_anon"
	if named {
		kind = "visit"
	}
	a.wakeFrom(kind, visitor, owner)
}

// ---- Notice board.

func noticeKey(n domain.Notice) (time.Time, string) { return n.PublishedAt, n.NoticeID }

func (a *API) listNotices(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, locale := r.Context(), r.URL.Query().Get("locale")
	sum, err := a.Store.NoticeSummary(ctx, p.UserID, locale)
	if err != nil {
		a.error(w, r, err)
		return
	}
	paged(a, w, r, p, "notices", func(pg page) ([]domain.Notice, error) {
		return a.Store.ListNotices(ctx, p.UserID, locale, pg.before, pg.id, pg.limit)
	}, noticeKey, map[string]any{"unreadCount": sum.UnreadCount, "unreadMore": sum.UnreadMore, "pinned": sum.Pinned})
}

func (a *API) noticeSummary(w http.ResponseWriter, r *http.Request, p store.Principal) {
	sum, err := a.Store.NoticeSummary(r.Context(), p.UserID, r.URL.Query().Get("locale"))
	a.respond(w, r, sum, err)
}

func (a *API) markNoticesSeen(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]bool{"seen": true}, a.Store.MarkNoticesSeen(r.Context(), p.UserID))
}

// ---- Support.

func supportThreadKey(t domain.SupportThread) (time.Time, string)   { return t.LastMessageAt, t.ThreadID }
func supportMessageKey(m domain.SupportMessage) (time.Time, string) { return m.CreatedAt, m.MessageID }

func (a *API) supportThreads(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	unread, err := a.Store.SupportUnread(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	paged(a, w, r, p, "support_threads", func(pg page) ([]domain.SupportThread, error) {
		return a.Store.SupportThreads(ctx, p.UserID, pg.before, pg.id, pg.limit)
	}, supportThreadKey, map[string]any{"unreadCount": unread})
}

func (a *API) supportUnread(w http.ResponseWriter, r *http.Request, p store.Principal) {
	n, err := a.Store.SupportUnread(r.Context(), p.UserID)
	a.respond(w, r, map[string]int{"unreadCount": n}, err)
}

func (a *API) createSupportThread(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return
	}
	category, body, err := supportFields(raw, true)
	if err != nil {
		a.error(w, r, err)
		return
	}
	id, err := a.Store.CreateSupportThread(ctx, p.UserID, category, body, a.entitlementsFor(ctx, p.UserID))
	if err != nil {
		a.error(w, r, err)
		return
	}
	thread, err := a.Store.SupportThread(ctx, p.UserID, id)
	a.created(w, r, thread, err)
}

func (a *API) getSupportThread(w http.ResponseWriter, r *http.Request, p store.Principal) {
	thread, err := a.Store.SupportThread(r.Context(), p.UserID, r.PathValue("threadId"))
	a.respond(w, r, thread, err)
}

// supportMessages lists a thread, oldest first. Opening the first page marks the thread read.
func (a *API) supportMessages(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, id := r.Context(), r.PathValue("threadId")
	if _, err := a.Store.SupportThread(ctx, p.UserID, id); err != nil {
		a.error(w, r, err)
		return
	}
	if r.URL.Query().Get("cursor") == "" {
		if err := a.Store.MarkSupportRead(ctx, p.UserID, id); err != nil {
			a.error(w, r, err)
			return
		}
	}
	paged(a, w, r, p, "support_messages:"+id, func(pg page) ([]domain.SupportMessage, error) {
		return a.Store.SupportMessages(ctx, p.UserID, id, pg.before, pg.id, pg.limit)
	}, supportMessageKey, nil)
}

func (a *API) addSupportMessage(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	raw, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return
	}
	_, body, err := supportFields(raw, false)
	if err != nil {
		a.error(w, r, err)
		return
	}
	msg, err := a.Store.AddSupportMessage(ctx, p.UserID, r.PathValue("threadId"), body, a.entitlementsFor(ctx, p.UserID))
	a.created(w, r, msg, err)
}

func (a *API) closeSupportThread(w http.ResponseWriter, r *http.Request, p store.Principal) {
	a.respond(w, r, map[string]bool{"closed": true}, a.Store.CloseSupportThread(r.Context(), p.UserID, r.PathValue("threadId")))
}

// supportFields reads {category?, body}; the category is required when a thread is being opened.
func supportFields(raw map[string]json.RawMessage, needCategory bool) (category, body string, err error) {
	for name := range raw {
		if name != "body" && (name != "category" || !needCategory) {
			return "", "", &domain.ValidationError{Field: name, Message: "field is not accepted"}
		}
	}
	var b string
	if json.Unmarshal(raw["body"], &b) != nil {
		return "", "", &domain.ValidationError{Field: "body", Message: "must be text"}
	}
	if body, err = domain.ParseSupportBody(b); err != nil {
		return "", "", err
	}
	if needCategory {
		var c string
		if json.Unmarshal(raw["category"], &c) != nil {
			return "", "", &domain.ValidationError{Field: "category", Message: "must be text"}
		}
		if category, err = domain.ParseSupportCategory(c); err != nil {
			return "", "", err
		}
	}
	return category, body, nil
}

// supportPushEvery is how often a node looks for staff replies that still need their push.
const supportPushEvery = 20 * time.Second

// supportNobody is the actor of a "support" push, which is about no member.
const supportNobody = "00000000-0000-0000-0000-000000000000"

// RunSupportPush sends the content-free "Support replied" push for staff messages written in the admin console,
// which has no push sender of its own: each message waits in support_messages until a node claims it (SKIP LOCKED, so
// exactly one does), and its member's sockets get a "support" wake-up. It returns when ctx ends.
func (a *API) RunSupportPush(ctx context.Context) {
	tick := time.NewTicker(supportPushEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			a.PushSupportOnce(ctx)
		}
	}
}

// PushSupportOnce does one pass of RunSupportPush.
func (a *API) PushSupportOnce(ctx context.Context) {
	users, err := a.Store.ClaimSupportPushes(ctx, 100)
	if err != nil {
		if ctx.Err() == nil {
			slog.Warn("support push claim failed", "reason", logscrub.Err(err))
		}
		return
	}
	for _, u := range users {
		a.signal(ctx, "support", nil, u)
		a.wake(push.Notice{Kind: "support", Actor: supportNobody, Recipient: u})
	}
}
