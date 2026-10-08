package store

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5"

	"kairova/services/api/internal/domain"
)

// Signer turns an object key into a short-lived URL. Store methods take one so
// URLs are only minted for media the viewer was just authorized to see.
type Signer func(key string) string

// friendsWith is true when viewer $1 and user x are friends.
func friendsWith(x string) string {
	return `EXISTS(SELECT 1 FROM friendships fr WHERE fr.user_low_id=least($1::uuid,` + x + `) AND fr.user_high_id=greatest($1::uuid,` + x + `) AND fr.status='accepted')`
}

// visibleTo is the full check that viewer $1 may see content by author a with
// audience col, used for single reads. Feeds use the cheaper per-author form.
func visibleTo(author, audience string) string {
	return `EXISTS(SELECT 1 FROM users au WHERE au.user_id=` + author + ` AND au.status='active')
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=` + author + `) OR (b.blocker_id=` + author + ` AND b.blocked_id=$1))
 AND (` + author + `=$1 OR ` + audience + `='public'
  OR (` + audience + `='followers' AND (EXISTS(SELECT 1 FROM follows vf WHERE vf.follower_id=$1 AND vf.followee_id=` + author + ` AND vf.state='active') OR ` + friendsWith(author) + `))
  OR (` + audience + `='friends' AND ` + friendsWith(author) + `))`
}

// circle lists the viewer's own account plus everyone they follow or are
// friends with, minus muted, blocked or inactive accounts, with whether each
// is a friend. One row per author.
const circle = `rel AS (
 SELECT followee_id AS id,false AS friend FROM follows WHERE follower_id=$1 AND state='active'
 UNION ALL SELECT CASE WHEN user_low_id=$1 THEN user_high_id ELSE user_low_id END,true FROM friendships WHERE (user_low_id=$1 OR user_high_id=$1) AND status='accepted'
), circle AS (
 SELECT r.id,bool_or(r.friend) AS friend,false AS self FROM rel r JOIN users u ON u.user_id=r.id AND u.status='active'
 WHERE NOT EXISTS(SELECT 1 FROM user_controls m WHERE m.actor_id=$1 AND m.target_id=r.id AND m.control='mute' AND (m.until IS NULL OR m.until>now()))
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=r.id) OR (b.blocker_id=r.id AND b.blocked_id=$1))
 GROUP BY r.id
 UNION ALL SELECT $1::uuid,true,true
)`

// audienceFor admits content in the circle query given the author row c.
func audienceFor(col string) string {
	return `(c.self OR ` + col + `='public' OR ` + col + `='followers' OR (` + col + `='friends' AND c.friend))`
}

// CreateUpload records a pending upload that expires in an hour if never
// completed. At most 50 uploads may be pending per account.
func (s *Store) CreateUpload(ctx context.Context, owner, purpose, contentType string, size int64) (string, string, error) {
	id := newID()
	key := "uploads/" + owner + "/" + id
	tag, err := s.Pool.Exec(ctx, `INSERT INTO media_assets(media_id,owner_id,purpose,content_type,size_bytes,upload_key,expires_at)
 SELECT $1,$2,$3,$4,$5,$6,now()+interval '1 hour'
 WHERE (SELECT count(*) FROM media_assets WHERE owner_id=$2 AND status='pending' AND expires_at>now())<50`, id, owner, purpose, contentType, size, key)
	if err == nil && tag.RowsAffected() == 0 {
		return "", "", &domain.PolicyError{Status: 429, Code: "RATE_LIMITED", Message: "Finish your current uploads first"}
	}
	return id, key, err
}

type PendingUpload struct {
	Key, ContentType, Purpose string
	Size                      int64
}

func (s *Store) PendingUpload(ctx context.Context, owner, id string) (PendingUpload, error) {
	var u PendingUpload
	err := s.Pool.QueryRow(ctx, `SELECT upload_key,content_type,purpose,size_bytes FROM media_assets WHERE media_id=$1 AND owner_id=$2 AND status='pending' AND expires_at>now()`, id, owner).
		Scan(&u.Key, &u.ContentType, &u.Purpose, &u.Size)
	return u, mapped(err)
}

// MediaReady stores processed variants. Unattached media expires after a day.
func (s *Store) MediaReady(ctx context.Context, owner, id string, width, height int, full, thumb string, size int64) error {
	variants, _ := json.Marshal(map[string]string{"full": full, "thumb": thumb})
	tag, err := s.Pool.Exec(ctx, `UPDATE media_assets SET status='ready',width=$3,height=$4,variants=$5,size_bytes=$6,expires_at=now()+interval '1 day'
 WHERE media_id=$1 AND owner_id=$2 AND status='pending'`, id, owner, width, height, variants, size)
	if err == nil && tag.RowsAffected() == 0 {
		err = domain.ErrNotFound
	}
	return err
}

// claimMedia locks the caller's ready, unattached media of a purpose and marks
// it attached. Every id must qualify.
func claimMedia(ctx context.Context, tx pgx.Tx, owner, purpose string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	tag, err := tx.Exec(ctx, `UPDATE media_assets SET attached=true WHERE media_id IN (
 SELECT media_id FROM media_assets WHERE media_id=ANY($1::uuid[]) AND owner_id=$2 AND purpose=$3 AND status='ready' AND NOT attached FOR UPDATE)`, ids, owner, purpose)
	if err != nil {
		return err
	}
	if int(tag.RowsAffected()) != len(ids) {
		return domain.ErrMediaNotReady
	}
	return nil
}

func (s *Store) CreatePost(ctx context.Context, author string, p domain.NewPost) (string, error) {
	id := newID()
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := claimMedia(ctx, tx, author, "post", p.MediaIDs); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO posts(post_id,author_id,body,audience) VALUES($1,$2,$3,$4)`, id, author, p.Body, p.Audience); err != nil {
			return err
		}
		batch := &pgx.Batch{}
		for i, m := range p.MediaIDs {
			batch.Queue(`INSERT INTO post_media(post_id,position,media_id) VALUES($1,$2,$3)`, id, i, m)
		}
		return tx.SendBatch(ctx, batch).Close()
	})
	return id, err
}

// DeletePost tombstones the post; its media is queued for object deletion.
func (s *Store) DeletePost(ctx context.Context, author, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE posts SET deleted_at=now() WHERE post_id=$1 AND author_id=$2 AND deleted_at IS NULL`, id, author)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		_, err = tx.Exec(ctx, `UPDATE media_assets SET status='deleted',deleted_at=now() WHERE media_id IN (SELECT media_id FROM post_media WHERE post_id=$1)`, id)
		return err
	})
}

type postKey struct {
	at time.Time
	id string
}

// Feed returns a page of posts for the viewer, newest first. "following" is
// the viewer's circle (self, follows, friends); "everyone" is recent public
// posts. Muted and blocked accounts never appear.
func (s *Store) Feed(ctx context.Context, viewer, mode string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.Post, error) {
	var rows pgx.Rows
	var err error
	if mode == "everyone" {
		rows, err = s.Pool.Query(ctx, `SELECT p.post_id::text,p.created_at FROM posts p JOIN users u ON u.user_id=p.author_id AND u.status='active'
 WHERE p.deleted_at IS NULL AND p.audience='public' AND ($2::timestamptz IS NULL OR (p.created_at,p.post_id)<($2,$3::uuid))
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=p.author_id) OR (b.blocker_id=p.author_id AND b.blocked_id=$1))
 AND NOT EXISTS(SELECT 1 FROM user_controls m WHERE m.actor_id=$1 AND m.target_id=p.author_id AND m.control='mute' AND (m.until IS NULL OR m.until>now()))
 ORDER BY p.created_at DESC,p.post_id DESC LIMIT $4`, viewer, before, beforeID, limit)
	} else {
		// One bounded index probe per author; the audience filter sits inside
		// the probe so hidden posts can't crowd out visible ones.
		rows, err = s.Pool.Query(ctx, `WITH `+circle+`
 SELECT p.post_id::text,p.created_at FROM circle c CROSS JOIN LATERAL (
  SELECT p.post_id,p.created_at FROM posts p WHERE p.author_id=c.id AND p.deleted_at IS NULL AND `+audienceFor("p.audience")+`
  AND ($2::timestamptz IS NULL OR (p.created_at,p.post_id)<($2,$3::uuid))
  ORDER BY p.created_at DESC,p.post_id DESC LIMIT $4) p
 ORDER BY p.created_at DESC,p.post_id DESC LIMIT $4`, viewer, before, beforeID, limit)
	}
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (string, error) {
		var id string
		var at time.Time
		return id, row.Scan(&id, &at)
	})
	if err != nil {
		return nil, err
	}
	return s.hydrate(ctx, viewer, ids, sign)
}

// UserPosts pages one author's posts that the viewer may see.
func (s *Store) UserPosts(ctx context.Context, viewer, author string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.Post, error) {
	rows, err := s.Pool.Query(ctx, `SELECT p.post_id::text FROM posts p WHERE p.author_id=$2 AND p.deleted_at IS NULL
 AND ($3::timestamptz IS NULL OR (p.created_at,p.post_id)<($3,$4::uuid)) AND `+visibleTo("p.author_id", "p.audience")+`
 ORDER BY p.created_at DESC,p.post_id DESC LIMIT $5`, viewer, author, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	return s.hydrate(ctx, viewer, ids, sign)
}

// Post returns one post if the viewer may see it.
func (s *Store) Post(ctx context.Context, viewer, id string, sign Signer) (domain.Post, error) {
	if err := s.canSeePost(ctx, s.Pool, viewer, id); err != nil {
		return domain.Post{}, err
	}
	posts, err := s.hydrate(ctx, viewer, []string{id}, sign)
	if err != nil || len(posts) == 0 {
		return domain.Post{}, mapped(errors.Join(err, domain.ErrNotFound))
	}
	return posts[0], nil
}

// canSeePost returns ErrNotFound for missing, deleted and hidden posts alike.
func (s *Store) canSeePost(ctx context.Context, q querier, viewer, id string) error {
	var ok bool
	err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM posts p WHERE p.post_id=$2 AND p.deleted_at IS NULL AND `+visibleTo("p.author_id", "p.audience")+`)`, viewer, id).Scan(&ok)
	if err == nil && !ok {
		err = domain.ErrNotFound
	}
	return err
}

// hydrate loads full cards for already-authorized post ids, keeping order.
// Five batched queries per page regardless of page size.
func (s *Store) hydrate(ctx context.Context, viewer string, ids []string, sign Signer) ([]domain.Post, error) {
	if len(ids) == 0 {
		return []domain.Post{}, nil
	}
	byID := map[string]*domain.Post{}
	rows, err := s.Pool.Query(ctx, `SELECT p.post_id::text,p.body,p.audience,p.created_at,p.edited_at,a.user_id::text,a.username,coalesce(a.data->>'displayName','')
 FROM posts p JOIN profiles a ON a.user_id=p.author_id WHERE p.post_id=ANY($1::uuid[])`, ids)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		p := &domain.Post{Media: []domain.MediaView{}}
		if err = rows.Scan(&p.PostID, &p.Body, &p.Audience, &p.CreatedAt, &p.EditedAt, &p.Author.UserID, &p.Author.Username, &p.Author.DisplayName); err != nil {
			rows.Close()
			return nil, err
		}
		p.SortAt, p.Mine = p.CreatedAt, p.Author.UserID == viewer
		byID[p.PostID] = p
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	scan := func(sql string, each func(pgx.Rows) error, args ...any) error {
		r, err := s.Pool.Query(ctx, sql, args...)
		if err != nil {
			return err
		}
		defer r.Close()
		for r.Next() {
			if err := each(r); err != nil {
				return err
			}
		}
		return r.Err()
	}
	err = scan(`SELECT pm.post_id::text,m.media_id::text,m.variants,coalesce(m.width,0),coalesce(m.height,0) FROM post_media pm JOIN media_assets m ON m.media_id=pm.media_id
 WHERE pm.post_id=ANY($1::uuid[]) AND m.status='ready' ORDER BY pm.post_id,pm.position`, func(r pgx.Rows) error {
		var post string
		var v domain.MediaView
		var variants map[string]string
		if err := r.Scan(&post, &v.MediaID, &variants, &v.Width, &v.Height); err != nil {
			return err
		}
		v.URL, v.ThumbURL = sign(variants["full"]), sign(variants["thumb"])
		if p := byID[post]; p != nil {
			p.Media = append(p.Media, v)
		}
		return nil
	}, ids)
	if err == nil {
		err = scan(`SELECT post_id::text,sum(reactions)::int,sum(comments)::int FROM post_counters WHERE post_id=ANY($1::uuid[]) GROUP BY post_id`, func(r pgx.Rows) error {
			var post string
			var reactions, comments int
			if err := r.Scan(&post, &reactions, &comments); err != nil {
				return err
			}
			if p := byID[post]; p != nil {
				p.Reactions, p.Comments = max(reactions, 0), max(comments, 0)
			}
			return nil
		}, ids)
	}
	if err == nil {
		err = scan(`SELECT post_id::text,reaction FROM post_reactions WHERE user_id=$1 AND post_id=ANY($2::uuid[])`, func(r pgx.Rows) error {
			var post, reaction string
			if err := r.Scan(&post, &reaction); err != nil {
				return err
			}
			if p := byID[post]; p != nil {
				p.MyReaction = &reaction
			}
			return nil
		}, viewer, ids)
	}
	if err == nil {
		err = scan(`SELECT post_id::text FROM saved_posts WHERE user_id=$1 AND post_id=ANY($2::uuid[])`, func(r pgx.Rows) error {
			var post string
			if err := r.Scan(&post); err != nil {
				return err
			}
			if p := byID[post]; p != nil {
				p.Saved = true
			}
			return nil
		}, viewer, ids)
	}
	if err != nil {
		return nil, err
	}
	result := make([]domain.Post, 0, len(ids))
	for _, id := range ids {
		if p := byID[id]; p != nil {
			result = append(result, *p)
		}
	}
	return result, nil
}

// bump adds to a post's counters on one of its 8 slots.
func bump(ctx context.Context, tx pgx.Tx, post string, reactions, comments int) error {
	if reactions == 0 && comments == 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `INSERT INTO post_counters(post_id,slot,reactions,comments) VALUES($1,$2,$3,$4)
 ON CONFLICT (post_id,slot) DO UPDATE SET reactions=post_counters.reactions+excluded.reactions,comments=post_counters.comments+excluded.comments`,
		post, rand.IntN(8), reactions, comments)
	return err
}

func postAuthor(ctx context.Context, tx pgx.Tx, post string) (string, error) {
	var author string
	err := tx.QueryRow(ctx, `SELECT author_id::text FROM posts WHERE post_id=$1`, post).Scan(&author)
	return author, mapped(err)
}

// SetReaction sets or changes the viewer's reaction and returns the post's
// author so they can be signalled.
func (s *Store) SetReaction(ctx context.Context, viewer, post, reaction string) (string, error) {
	var author string
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := s.canSeePost(ctx, tx, viewer, post); err != nil {
			return err
		}
		var inserted bool
		err := tx.QueryRow(ctx, `INSERT INTO post_reactions(post_id,user_id,reaction) VALUES($1,$2,$3)
 ON CONFLICT (post_id,user_id) DO UPDATE SET reaction=excluded.reaction RETURNING xmax=0`, post, viewer, reaction).Scan(&inserted)
		if err != nil {
			return err
		}
		if author, err = postAuthor(ctx, tx, post); err != nil {
			return err
		}
		if !inserted {
			return nil
		}
		if err = bump(ctx, tx, post, 1, 0); err != nil {
			return err
		}
		if author != viewer {
			return notify(ctx, tx, author, viewer, "post.reacted", post)
		}
		return nil
	})
	return author, err
}

func (s *Store) RemoveReaction(ctx context.Context, viewer, post string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM post_reactions WHERE post_id=$1 AND user_id=$2`, post, viewer)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return bump(ctx, tx, post, -1, 0)
	})
}

func (s *Store) SetSaved(ctx context.Context, viewer, post string, saved bool) error {
	if !saved {
		_, err := s.Pool.Exec(ctx, `DELETE FROM saved_posts WHERE user_id=$1 AND post_id=$2`, viewer, post)
		return err
	}
	if err := s.canSeePost(ctx, s.Pool, viewer, post); err != nil {
		return err
	}
	_, err := s.Pool.Exec(ctx, `INSERT INTO saved_posts(user_id,post_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, viewer, post)
	return err
}

// Saved pages the viewer's saved posts, newest save first, rechecking access:
// a post that became hidden drops out of the list.
func (s *Store) Saved(ctx context.Context, viewer string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.Post, error) {
	rows, err := s.Pool.Query(ctx, `SELECT p.post_id::text,s.saved_at FROM saved_posts s JOIN posts p ON p.post_id=s.post_id
 WHERE s.user_id=$1 AND p.deleted_at IS NULL AND ($2::timestamptz IS NULL OR (s.saved_at,s.post_id)<($2,$3::uuid)) AND `+visibleTo("p.author_id", "p.audience")+`
 ORDER BY s.saved_at DESC,s.post_id DESC LIMIT $4`, viewer, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	saved := map[string]time.Time{}
	ids, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (string, error) {
		var id string
		var at time.Time
		err := row.Scan(&id, &at)
		saved[id] = at
		return id, err
	})
	if err != nil {
		return nil, err
	}
	posts, err := s.hydrate(ctx, viewer, ids, sign)
	for i := range posts {
		posts[i].SortAt = saved[posts[i].PostID]
	}
	return posts, err
}

// Comments pages a post's comments oldest first. Hidden comments (from people
// the author restricted) are shown only to their writer.
func (s *Store) Comments(ctx context.Context, viewer, post string, after *time.Time, afterID string, limit int) ([]domain.Comment, error) {
	if err := s.canSeePost(ctx, s.Pool, viewer, post); err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT c.comment_id::text,c.post_id::text,c.parent_id::text,c.body,c.created_at,a.user_id::text,a.username,coalesce(a.data->>'displayName',''),p.author_id=$1
 FROM comments c JOIN posts p ON p.post_id=c.post_id JOIN profiles a ON a.user_id=c.author_id JOIN users u ON u.user_id=c.author_id AND u.status='active'
 WHERE c.post_id=$2 AND c.deleted_at IS NULL AND (NOT c.hidden OR c.author_id=$1)
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=c.author_id) OR (b.blocker_id=c.author_id AND b.blocked_id=$1))
 AND ($3::timestamptz IS NULL OR (c.created_at,c.comment_id)>($3,$4::uuid))
 ORDER BY c.created_at,c.comment_id LIMIT $5`, viewer, post, after, afterID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Comment, error) {
		var c domain.Comment
		var postOwner bool
		err := row.Scan(&c.CommentID, &c.PostID, &c.ParentID, &c.Body, &c.CreatedAt, &c.Author.UserID, &c.Author.Username, &c.Author.DisplayName, &postOwner)
		c.Mine = c.Author.UserID == viewer
		c.CanDelete = c.Mine || postOwner
		return c, err
	})
}

// AddComment applies the post author's commentsFrom setting. It returns the
// comment and the post's author, and whether the comment is hidden.
func (s *Store) AddComment(ctx context.Context, viewer, post string, in domain.NewComment) (domain.Comment, string, bool, error) {
	var c domain.Comment
	var author string
	var hidden bool
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := s.canSeePost(ctx, tx, viewer, post); err != nil {
			return err
		}
		var err error
		if author, err = postAuthor(ctx, tx, post); err != nil {
			return err
		}
		if author != viewer {
			var allowed bool
			err = tx.QueryRow(ctx, `SELECT CASE coalesce(q.data->>'commentsFrom','friends')
  WHEN 'everyone' THEN true
  WHEN 'followers' THEN EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=$2 AND f.state='active') OR `+friendsWith("$2::uuid")+`
  WHEN 'friends' THEN `+friendsWith("$2::uuid")+`
  ELSE false END,
 EXISTS(SELECT 1 FROM user_controls rc WHERE rc.actor_id=$2 AND rc.target_id=$1 AND rc.control='restrict')
 FROM privacy_settings q WHERE q.user_id=$2`, viewer, author).Scan(&allowed, &hidden)
			if err != nil {
				return mapped(err)
			}
			if !allowed {
				return domain.ErrCommentsNotAllowed
			}
		}
		if in.ParentID != nil {
			var ok bool
			if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM comments WHERE comment_id=$1 AND post_id=$2 AND deleted_at IS NULL)`, *in.ParentID, post).Scan(&ok); err != nil {
				return err
			}
			if !ok {
				return &domain.ValidationError{Field: "parentId", Message: "reply to a comment on this post"}
			}
		}
		c = domain.Comment{CommentID: newID(), PostID: post, ParentID: in.ParentID, Body: in.Body, Mine: true, CanDelete: true}
		err = tx.QueryRow(ctx, `INSERT INTO comments(comment_id,post_id,author_id,parent_id,body,hidden) VALUES($1,$2,$3,$4,$5,$6) RETURNING created_at`,
			c.CommentID, post, viewer, in.ParentID, in.Body, hidden).Scan(&c.CreatedAt)
		if err != nil {
			return err
		}
		if err = tx.QueryRow(ctx, `SELECT user_id::text,username,coalesce(data->>'displayName','') FROM profiles WHERE user_id=$1`, viewer).
			Scan(&c.Author.UserID, &c.Author.Username, &c.Author.DisplayName); err != nil {
			return err
		}
		if hidden {
			return nil
		}
		if err = bump(ctx, tx, post, 0, 1); err != nil {
			return err
		}
		if author != viewer {
			return notify(ctx, tx, author, viewer, "post.commented", post)
		}
		return nil
	})
	return c, author, hidden, err
}

// DeleteComment lets the writer or the post's author remove a comment.
func (s *Store) DeleteComment(ctx context.Context, viewer, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var post string
		var hidden bool
		err := tx.QueryRow(ctx, `UPDATE comments c SET deleted_at=now() FROM posts p
 WHERE c.comment_id=$1 AND c.deleted_at IS NULL AND p.post_id=c.post_id AND (c.author_id=$2 OR p.author_id=$2)
 RETURNING c.post_id::text,c.hidden`, id, viewer).Scan(&post, &hidden)
		if err != nil {
			return mapped(err)
		}
		if hidden {
			return nil
		}
		return bump(ctx, tx, post, 0, -1)
	})
}

// CreateStory publishes a story that lives for 24 hours.
func (s *Store) CreateStory(ctx context.Context, author string, in domain.NewStory) (string, error) {
	id := newID()
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var media []string
		if in.MediaID != nil {
			media = []string{*in.MediaID}
		}
		if err := claimMedia(ctx, tx, author, "story", media); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO stories(story_id,author_id,media_id,body,background,audience,expires_at) VALUES($1,$2,$3,$4,$5,$6,now()+$7::interval)`,
			id, author, in.MediaID, in.Body, in.Background, in.Audience, domain.StoryLifetime)
		return err
	})
	return id, err
}

func (s *Store) DeleteStory(ctx context.Context, author, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var media *string
		err := tx.QueryRow(ctx, `UPDATE stories SET deleted_at=now() WHERE story_id=$1 AND author_id=$2 AND deleted_at IS NULL RETURNING media_id::text`, id, author).Scan(&media)
		if err != nil {
			return mapped(err)
		}
		if media != nil {
			_, err = tx.Exec(ctx, `UPDATE media_assets SET status='deleted',deleted_at=now() WHERE media_id=$1`, *media)
		}
		return err
	})
}

// StoryTray returns active stories from the viewer's circle that they may see,
// grouped by author: own first, then authors with unseen stories, newest first.
func (s *Store) StoryTray(ctx context.Context, viewer string, sign Signer) ([]domain.StoryGroup, error) {
	rows, err := s.Pool.Query(ctx, `WITH `+circle+`
 SELECT st.story_id::text,st.body,st.background,st.audience,st.created_at,st.expires_at,m.media_id::text,m.variants,coalesce(m.width,0),coalesce(m.height,0),
  a.user_id::text,a.username,coalesce(a.data->>'displayName',''),c.self,
  EXISTS(SELECT 1 FROM story_views v WHERE v.story_id=st.story_id AND v.viewer_id=$1),
  CASE WHEN c.self THEN (SELECT count(*) FROM story_views v WHERE v.story_id=st.story_id)::int END
 FROM circle c
 JOIN stories st ON st.author_id=c.id AND st.deleted_at IS NULL AND st.expires_at>now() AND `+audienceFor("st.audience")+`
 JOIN profiles a ON a.user_id=c.id
 LEFT JOIN media_assets m ON m.media_id=st.media_id AND m.status='ready'
 ORDER BY st.created_at
 LIMIT 1500`, viewer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	groups := map[string]*domain.StoryGroup{}
	var order []string
	for rows.Next() {
		var st domain.Story
		var mediaID *string
		var variants map[string]string
		var w, h int
		var author domain.UserSummary
		var self bool
		if err = rows.Scan(&st.StoryID, &st.Body, &st.Background, &st.Audience, &st.CreatedAt, &st.ExpiresAt, &mediaID, &variants, &w, &h,
			&author.UserID, &author.Username, &author.DisplayName, &self, &st.Seen, &st.ViewCount); err != nil {
			return nil, err
		}
		if mediaID != nil {
			st.Media = &domain.MediaView{MediaID: *mediaID, URL: sign(variants["full"]), ThumbURL: sign(variants["thumb"]), Width: w, Height: h}
		}
		g := groups[author.UserID]
		if g == nil {
			g = &domain.StoryGroup{Author: author, Mine: self, AllSeen: true}
			groups[author.UserID] = g
			order = append(order, author.UserID)
		}
		g.Stories = append(g.Stories, st)
		g.AllSeen = g.AllSeen && (st.Seen || self)
		g.Latest = st.CreatedAt
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	result := make([]domain.StoryGroup, 0, len(order))
	for _, id := range order {
		result = append(result, *groups[id])
	}
	rank := func(g domain.StoryGroup) int {
		switch {
		case g.Mine:
			return 0
		case !g.AllSeen:
			return 1
		}
		return 2
	}
	sortGroups(result, func(a, b domain.StoryGroup) bool {
		if rank(a) != rank(b) {
			return rank(a) < rank(b)
		}
		return a.Latest.After(b.Latest)
	})
	return result, nil
}

func sortGroups(g []domain.StoryGroup, less func(a, b domain.StoryGroup) bool) {
	for i := 1; i < len(g); i++ {
		for j := i; j > 0 && less(g[j], g[j-1]); j-- {
			g[j], g[j-1] = g[j-1], g[j]
		}
	}
}

// ViewStory records the viewer once; viewing your own story is not counted.
func (s *Store) ViewStory(ctx context.Context, viewer, id string) error {
	var ok bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM stories st WHERE st.story_id=$2 AND st.deleted_at IS NULL AND st.expires_at>now() AND `+visibleTo("st.author_id", "st.audience")+`)`, viewer, id).Scan(&ok)
	if err != nil {
		return err
	}
	if !ok {
		return domain.ErrNotFound
	}
	_, err = s.Pool.Exec(ctx, `INSERT INTO story_views(story_id,viewer_id) SELECT $1,$2 FROM stories WHERE story_id=$1 AND author_id<>$2 ON CONFLICT DO NOTHING`, id, viewer)
	return err
}

// StoryViewers pages who saw the author's own story, most recent first.
func (s *Store) StoryViewers(ctx context.Context, author, id string, before *time.Time, beforeID string, limit int) ([]domain.Connection, error) {
	var mine bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM stories WHERE story_id=$1 AND author_id=$2 AND deleted_at IS NULL)`, id, author).Scan(&mine); err != nil {
		return nil, err
	}
	if !mine {
		return nil, domain.ErrNotFound
	}
	rows, err := s.Pool.Query(ctx, `SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),v.viewed_at FROM story_views v
 JOIN profiles p ON p.user_id=v.viewer_id JOIN users u ON u.user_id=v.viewer_id AND u.status='active'
 WHERE v.story_id=$1 AND ($2::timestamptz IS NULL OR (v.viewed_at,v.viewer_id)<($2,$3::uuid))
 ORDER BY v.viewed_at DESC,v.viewer_id DESC LIMIT $4`, id, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Connection, error) {
		var c domain.Connection
		return c, row.Scan(&c.User.UserID, &c.User.Username, &c.User.DisplayName, &c.Since)
	})
}

// MediaGarbage lists object keys to delete: abandoned or never-attached
// uploads past expiry, and media marked deleted. Purged rows keep only their
// tombstone, so nothing is returned twice.
func (s *Store) MediaGarbage(ctx context.Context, batch int) ([]string, int64, error) {
	// Keys are read before the update clears them.
	rows, err := s.Pool.Query(ctx, `WITH gone AS (
  (SELECT media_id,upload_key,variants FROM media_assets WHERE status<>'deleted' AND NOT attached AND expires_at<now() ORDER BY expires_at LIMIT $1)
  UNION ALL
  (SELECT media_id,upload_key,variants FROM media_assets WHERE status='deleted' AND variants IS NOT NULL ORDER BY deleted_at LIMIT $1)
 ), purged AS (
  UPDATE media_assets m SET status='deleted',deleted_at=coalesce(m.deleted_at,now()),variants=NULL FROM gone g WHERE m.media_id=g.media_id
  RETURNING m.media_id
 ) SELECT g.upload_key,g.variants FROM gone g JOIN purged USING(media_id)`, batch)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var keys []string
	var purged int64
	for rows.Next() {
		var upload string
		var variants map[string]string
		if err = rows.Scan(&upload, &variants); err != nil {
			return nil, 0, err
		}
		purged++
		keys = append(keys, upload)
		for _, k := range variants {
			keys = append(keys, k)
		}
	}
	return keys, purged, rows.Err()
}

// PurgeStories deletes stories a day after they expire (views go with them)
// and marks their media for deletion.
func (s *Store) PurgeStories(ctx context.Context, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `WITH gone AS (
  DELETE FROM stories WHERE story_id IN (SELECT story_id FROM stories WHERE expires_at<now()-interval '1 day' ORDER BY expires_at LIMIT $1)
  RETURNING media_id
 ) UPDATE media_assets SET status='deleted',deleted_at=now() WHERE media_id IN (SELECT media_id FROM gone WHERE media_id IS NOT NULL)`, batch)
	return tag.RowsAffected(), err
}
