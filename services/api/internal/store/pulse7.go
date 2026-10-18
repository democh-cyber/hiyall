package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Search over public post and story text, the "everyone" story list and My activity
// (docs/api/27-stories-notices-support.md).

// searchCandidates is how many matching rows one search page examines before the audience rules are applied. A page
// that finds fewer than a full page of visible rows among them still hands back a cursor to carry on after the last
// candidate examined (each page counts against the day and the page limit), so one word that matches a million
// posts cannot make a request walk the table.
const searchCandidates = 100

// searchWindow is how far back a post search looks: a search is for what people are saying now.
const searchWindow = 180 * 24 * time.Hour

// SearchResume is where the next page of a search carries on: after the row (At, ID). Zero when the results ended.
type SearchResume struct {
	At time.Time
	ID string
}

// SearchPosts pages posts whose text matches q (Postgres full text, the 'simple' configuration: every word, no
// stemming), newest first, that the viewer may see: the audience rules of a single read, blocks, the age band,
// muted and inactive authors. topic narrows to one topic.
func (s *Store) SearchPosts(ctx context.Context, viewer, q string, topic *string, afterAt *time.Time, afterID string, limit int, sign Signer) ([]domain.Post, *SearchResume, error) {
	rows, err := s.Pool.Query(ctx, `WITH cand AS (
  SELECT p.post_id,p.author_id,p.audience,p.created_at FROM posts p
  WHERE p.deleted_at IS NULL AND to_tsvector('simple',p.body)@@plainto_tsquery('simple',$2) AND ($3::text IS NULL OR p.topic=$3)
  AND p.created_at>now()-$6::interval AND ($4::timestamptz IS NULL OR (p.created_at,p.post_id)<($4,$5::uuid))
  ORDER BY p.created_at DESC,p.post_id DESC LIMIT $7)
 SELECT c.post_id::text,c.created_at,
  (`+visibleTo("c.author_id", "c.audience")+` AND NOT EXISTS(SELECT 1 FROM user_controls m WHERE m.actor_id=$1 AND m.target_id=c.author_id AND m.control='mute' AND (m.until IS NULL OR m.until>now()))) AS ok
 FROM cand c ORDER BY c.created_at DESC,c.post_id DESC`, viewer, q, topic, afterAt, afterID, searchWindow.String(), searchCandidates)
	if err != nil {
		return nil, nil, err
	}
	ids, resume, err := pickVisible(rows, limit)
	if err != nil {
		return nil, nil, err
	}
	posts, err := s.hydrate(ctx, viewer, ids, sign)
	return posts, resume, err
}

// pickVisible reads (id, created_at, ok) candidates in order and keeps the first limit that are ok. When another one
// follows, the resume point is the last one kept; when the candidates ran out at the cap with room to spare, it is the
// last candidate examined; otherwise nil.
func pickVisible(rows pgx.Rows, limit int) ([]string, *SearchResume, error) {
	defer rows.Close()
	var ids []string
	var last, lastKept SearchResume
	seen := 0
	more := false
	for rows.Next() {
		var id string
		var at time.Time
		var ok bool
		if err := rows.Scan(&id, &at, &ok); err != nil {
			return nil, nil, err
		}
		seen++
		last = SearchResume{at, id}
		if !ok {
			continue
		}
		if len(ids) == limit {
			more = true
			continue
		}
		ids = append(ids, id)
		lastKept = last
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	switch {
	case more:
		return ids, &lastKept, nil
	case seen >= searchCandidates:
		return ids, &last, nil
	}
	return ids, nil, nil
}

// SearchStories is SearchPosts over the active stories.
func (s *Store) SearchStories(ctx context.Context, viewer, q string, topic *string, afterAt *time.Time, afterID string, limit int, sign Signer) ([]domain.StoryItem, *SearchResume, error) {
	rows, err := s.Pool.Query(ctx, `WITH cand AS (
  SELECT st.story_id,st.author_id,st.audience,st.created_at FROM stories st
  WHERE st.deleted_at IS NULL AND st.expires_at>now() AND to_tsvector('simple',st.body)@@plainto_tsquery('simple',$2) AND ($3::text IS NULL OR st.topic=$3)
  AND ($4::timestamptz IS NULL OR (st.created_at,st.story_id)<($4,$5::uuid))
  ORDER BY st.created_at DESC,st.story_id DESC LIMIT $6)
 SELECT c.story_id::text,c.created_at,
  (`+visibleTo("c.author_id", "c.audience")+` AND NOT EXISTS(SELECT 1 FROM user_controls m WHERE m.actor_id=$1 AND m.target_id=c.author_id AND m.control='mute' AND (m.until IS NULL OR m.until>now()))) AS ok
 FROM cand c ORDER BY c.created_at DESC,c.story_id DESC`, viewer, q, topic, afterAt, afterID, searchCandidates)
	if err != nil {
		return nil, nil, err
	}
	ids, resume, err := pickVisible(rows, limit)
	if err != nil {
		return nil, nil, err
	}
	items, err := s.storyItems(ctx, viewer, ids, sign)
	return items, resume, err
}

// ExploreStories pages the public stories that are up now from people the viewer does not already see in their
// tray, newest first: the "Everyone" tab of the stories screen. Muted, blocked, other-band and inactive authors never
// appear, and neither do the viewer's own stories (the tray has them).
func (s *Store) ExploreStories(ctx context.Context, viewer string, topic *string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.StoryItem, error) {
	rows, err := s.Pool.Query(ctx, `SELECT st.story_id::text FROM stories st JOIN users u ON u.user_id=st.author_id AND u.status='active'
 WHERE st.deleted_at IS NULL AND st.expires_at>now() AND st.audience='public' AND st.author_id<>$1 AND ($2::text IS NULL OR st.topic=$2)
 AND ($3::timestamptz IS NULL OR (st.created_at,st.story_id)<($3,$4::uuid))
 AND `+notBarred("$1::uuid", "st.author_id")+`
 AND NOT EXISTS(SELECT 1 FROM user_controls m WHERE m.actor_id=$1 AND m.target_id=st.author_id AND m.control='mute' AND (m.until IS NULL OR m.until>now()))
 ORDER BY st.created_at DESC,st.story_id DESC LIMIT $5`, viewer, topic, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	return s.storyItems(ctx, viewer, ids, sign)
}

// storyItems loads already-authorized stories with their authors, keeping the order of ids.
func (s *Store) storyItems(ctx context.Context, viewer string, ids []string, sign Signer) ([]domain.StoryItem, error) {
	items := []domain.StoryItem{}
	if len(ids) == 0 {
		return items, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT st.story_id::text,st.body,st.background,st.text_style,st.audience,st.created_at,st.expires_at,m.media_id::text,m.variants,coalesce(m.width,0),coalesce(m.height,0),
  EXISTS(SELECT 1 FROM story_views v WHERE v.story_id=st.story_id AND v.viewer_id=$1),st.topic,vm.media_id::text,st.voice_ms,vm.variants,
  a.user_id::text,a.username,coalesce(a.data->>'displayName',''),`+avatarThumbKey("av")+`
 FROM stories st JOIN profiles a ON a.user_id=st.author_id`+avatarJoin("av", "a")+`
 LEFT JOIN media_assets m ON m.media_id=st.media_id AND m.status='ready'
 LEFT JOIN media_assets vm ON vm.media_id=st.voice_media_id AND vm.status='ready'
 WHERE st.story_id=ANY($2::uuid[]) AND st.deleted_at IS NULL`, viewer, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byID := map[string]domain.StoryItem{}
	for rows.Next() {
		var it domain.StoryItem
		var mediaID, voiceID, avatar *string
		var variants, voiceVariants map[string]string
		var voiceMs *int
		var w, h int
		if err = rows.Scan(&it.StoryID, &it.Body, &it.Background, &it.TextStyle, &it.Audience, &it.CreatedAt, &it.ExpiresAt, &mediaID, &variants, &w, &h,
			&it.Seen, &it.Topic, &voiceID, &voiceMs, &voiceVariants, &it.Author.UserID, &it.Author.Username, &it.Author.DisplayName, &avatar); err != nil {
			return nil, err
		}
		it.Author.AvatarURL = avatarURL(sign, avatar)
		if mediaID != nil {
			it.Media = &domain.MediaView{MediaID: *mediaID, URL: sign(variants["full"]), ThumbURL: sign(variants["thumb"]), Width: w, Height: h}
		}
		it.Voice = voiceView(sign, voiceID, voiceMs, voiceVariants)
		byID[it.StoryID] = it
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	for _, id := range ids {
		if it, ok := byID[id]; ok {
			items = append(items, it)
		}
	}
	return items, nil
}

// ---- My activity.

// activityPosts reads, for post ids, whether the viewer may still see each and a short card for the ones they may.
// A post that is deleted, hidden by a block, in the other age band or from an inactive account is "removed", with
// nothing else about it.
func (s *Store) activityPosts(ctx context.Context, viewer string, ids []string, sign Signer) (map[string]domain.ActivityPost, error) {
	out := map[string]domain.ActivityPost{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT p.post_id::text,left(p.body,140),p.topic,p.voice_media_id IS NOT NULL,EXISTS(SELECT 1 FROM post_media pm WHERE pm.post_id=p.post_id),
  a.user_id::text,a.username,coalesce(a.data->>'displayName',''),`+avatarThumbKey("av")+`
 FROM posts p JOIN profiles a ON a.user_id=p.author_id`+avatarJoin("av", "a")+`
 WHERE p.post_id=ANY($2::uuid[]) AND p.deleted_at IS NULL AND `+visibleTo("p.author_id", "p.audience"), viewer, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var post domain.ActivityPost
		var avatar *string
		var author domain.UserSummary
		if err = rows.Scan(&post.PostID, &post.Excerpt, &post.Topic, &post.HasVoice, &post.HasMedia, &author.UserID, &author.Username, &author.DisplayName, &avatar); err != nil {
			return nil, err
		}
		author.AvatarURL = avatarURL(sign, avatar)
		post.State, post.Author = "available", &author
		out[post.PostID] = post
	}
	return out, rows.Err()
}

// MyComments pages the comments the viewer wrote, newest first, with the post each belongs to ("removed" when the
// post is gone or no longer visible). Deleted comments are not listed.
func (s *Store) MyComments(ctx context.Context, viewer string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.ActivityComment, error) {
	rows, err := s.Pool.Query(ctx, `SELECT c.comment_id::text,c.post_id::text,c.parent_id::text,c.body,c.created_at FROM comments c
 WHERE c.author_id=$1 AND c.deleted_at IS NULL AND c.body<>'' AND ($2::timestamptz IS NULL OR (c.created_at,c.comment_id)<($2,$3::uuid))
 ORDER BY c.created_at DESC,c.comment_id DESC LIMIT $4`, viewer, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.ActivityComment, error) {
		var c domain.ActivityComment
		return c, row.Scan(&c.CommentID, &c.PostID, &c.ParentID, &c.Body, &c.CreatedAt)
	})
	if err != nil {
		return nil, err
	}
	ids := make([]string, len(items))
	for i, c := range items {
		ids[i] = c.PostID
	}
	posts, err := s.activityPosts(ctx, viewer, ids, sign)
	if err != nil {
		return nil, err
	}
	for i := range items {
		items[i].Post = removedOr(posts, items[i].PostID)
	}
	return items, nil
}

// MyReactions pages the posts the viewer reacted to, newest reaction first.
func (s *Store) MyReactions(ctx context.Context, viewer string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.ActivityReaction, error) {
	rows, err := s.Pool.Query(ctx, `SELECT r.post_id::text,r.reaction,r.created_at FROM post_reactions r
 WHERE r.user_id=$1 AND ($2::timestamptz IS NULL OR (r.created_at,r.post_id)<($2,$3::uuid))
 ORDER BY r.created_at DESC,r.post_id DESC LIMIT $4`, viewer, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.ActivityReaction, error) {
		var r domain.ActivityReaction
		return r, row.Scan(&r.PostID, &r.Reaction, &r.CreatedAt)
	})
	if err != nil {
		return nil, err
	}
	ids := make([]string, len(items))
	for i, r := range items {
		ids[i] = r.PostID
	}
	posts, err := s.activityPosts(ctx, viewer, ids, sign)
	if err != nil {
		return nil, err
	}
	for i := range items {
		items[i].Post = removedOr(posts, items[i].PostID)
	}
	return items, nil
}

func removedOr(posts map[string]domain.ActivityPost, id string) domain.ActivityPost {
	if p, ok := posts[id]; ok {
		return p
	}
	return domain.ActivityPost{PostID: id, State: "removed"}
}
