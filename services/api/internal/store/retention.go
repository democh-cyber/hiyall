package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Retention and reconcile jobs of the hourly maintenance loop (audit D11, F21). The periods are the ones
// docs/legal/data-retention.md states; change them together. Every job is an idempotent loop of small
// statements that drains its backlog and returns how many rows it handled.
const (
	// NotificationRetention is how long in-app notifications are kept.
	NotificationRetention = 90 * 24 * time.Hour
	// ReportRetention is how long a closed report (and the actions taken on it) is kept after it closed,
	// unless it holds encrypted evidence (chat_blobs.held_report_id), which keeps it until the hold ends.
	ReportRetention = 180 * 24 * time.Hour
	// DeletedContentBlankAfter is when the text of a soft-deleted post, comment or space entry is blanked.
	DeletedContentBlankAfter = 24 * time.Hour
	// DeletedContentRetention is when a soft-deleted post, comment or space entry is deleted for good.
	DeletedContentRetention = 30 * 24 * time.Hour
	// MessageMetadataRetention is how long a message's metadata row (id, sender, time; never content) is kept.
	MessageMetadataRetention = 180 * 24 * time.Hour
	// MediaTombstoneRetention is how long a finished photo row (objects gone, keys cleared) is kept.
	MediaTombstoneRetention = 30 * 24 * time.Hour
	// ReconcileEvery is how often each counter is recomputed from the rows it summarises.
	ReconcileEvery = 7 * 24 * time.Hour
)

// retentionChunk is how many rows one retention statement touches.
const retentionChunk = 1000

// drain repeats step while it handles a full chunk, and returns the total. It stops when ctx ends.
func drain(ctx context.Context, step func() (int64, error)) (int64, error) {
	var total int64
	for ctx.Err() == nil {
		n, err := step()
		total += n
		if err != nil || n < retentionChunk {
			return total, err
		}
	}
	return total, ctx.Err()
}

// openReportAgainst is true when an open report names the row (alias a, id column col): content under an open
// report is kept as it is until the report is closed.
func openReportAgainst(alias, col string) string {
	return `NOT EXISTS(SELECT 1 FROM reports rp WHERE rp.target_id=` + alias + `.` + col + ` AND rp.status='open')`
}

// PurgeNotifications deletes notifications older than retain.
func (s *Store) PurgeNotifications(ctx context.Context, retain time.Duration) (int64, error) {
	return drain(ctx, func() (int64, error) {
		tag, err := s.Pool.Exec(ctx, `DELETE FROM notifications WHERE ctid IN (SELECT ctid FROM notifications WHERE created_at<now()-$1::interval ORDER BY created_at LIMIT $2)`, retain, retentionChunk)
		return tag.RowsAffected(), err
	})
}

// PurgeClosedReports deletes reports that were closed more than retain ago, with the moderation actions taken
// on them, unless they hold encrypted evidence (chat_blobs.held_report_id): a hold keeps the report until
// staff release it. Open reports are never touched.
func (s *Store) PurgeClosedReports(ctx context.Context, retain time.Duration) (int64, error) {
	return drain(ctx, func() (int64, error) {
		var n int64
		err := s.Pool.QueryRow(ctx, `WITH gone AS (
  SELECT r.report_id FROM reports r WHERE r.status<>'open' AND r.resolved_at<now()-$1::interval
  AND NOT EXISTS(SELECT 1 FROM chat_blobs b WHERE b.held_report_id=r.report_id) ORDER BY r.resolved_at LIMIT $2),
 acts AS (DELETE FROM moderation_actions WHERE report_id IN (SELECT report_id FROM gone)),
 del AS (DELETE FROM reports WHERE report_id IN (SELECT report_id FROM gone) RETURNING 1)
 SELECT count(*) FROM del`, retain, retentionChunk).Scan(&n)
		return n, err
	})
}

// BlankDeletedContent empties the text of posts, comments and space entries that were soft-deleted more than
// after ago (the row stays until PurgeDeletedContent, so threads and counters keep their shape). Content that
// an open report names is left alone.
func (s *Store) BlankDeletedContent(ctx context.Context, after time.Duration) (int64, error) {
	var total int64
	for _, q := range []struct{ table, key string }{{"posts", "post_id"}, {"comments", "comment_id"}, {"space_entries", "entry_id"}} {
		n, err := drain(ctx, func() (int64, error) {
			tag, err := s.Pool.Exec(ctx, `UPDATE `+q.table+` SET body='' WHERE ctid IN (SELECT ctid FROM `+q.table+` x WHERE x.deleted_at IS NOT NULL AND x.deleted_at<now()-$1::interval AND x.body<>''
 AND `+openReportAgainst("x", q.key)+` ORDER BY x.deleted_at LIMIT $2)`, after, retentionChunk)
			return tag.RowsAffected(), err
		})
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// PurgeDeletedContent deletes posts, comments and space entries that were soft-deleted more than retain ago,
// together with what hangs on them (a post's comments, reactions, saves, counters and photo links; the photo
// rows themselves are released by the delete and removed by the media cleanup). A comment that others replied
// to stays until its replies are gone. Content that an open report names is kept.
func (s *Store) PurgeDeletedContent(ctx context.Context, retain time.Duration) (int64, error) {
	var total int64
	n, err := drain(ctx, func() (int64, error) { return s.purgeDeletedPosts(ctx, retain) })
	total += n
	if err != nil {
		return total, err
	}
	// Leaf comments first; deleting a leaf can expose its parent, so go on until a pass finds none.
	for ctx.Err() == nil {
		tag, err := s.Pool.Exec(ctx, `DELETE FROM comments WHERE ctid IN (SELECT ctid FROM comments c WHERE c.deleted_at IS NOT NULL AND c.deleted_at<now()-$1::interval
 AND NOT EXISTS(SELECT 1 FROM comments k WHERE k.parent_id=c.comment_id) AND `+openReportAgainst("c", "comment_id")+` ORDER BY c.deleted_at LIMIT $2)`, retain, retentionChunk)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() == 0 {
			break
		}
	}
	n, err = drain(ctx, func() (int64, error) {
		tag, err := s.Pool.Exec(ctx, `DELETE FROM space_entries WHERE ctid IN (SELECT ctid FROM space_entries e WHERE e.deleted_at IS NOT NULL AND e.deleted_at<now()-$1::interval
 AND `+openReportAgainst("e", "entry_id")+` ORDER BY e.deleted_at LIMIT $2)`, retain, retentionChunk)
		return tag.RowsAffected(), err
	})
	return total + n, err
}

// purgeDeletedPosts deletes one chunk of old soft-deleted posts with their dependants, in one transaction.
func (s *Store) purgeDeletedPosts(ctx context.Context, retain time.Duration) (int64, error) {
	var n int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT post_id::text FROM posts p WHERE p.deleted_at IS NOT NULL AND p.deleted_at<now()-$1::interval AND `+openReportAgainst("p", "post_id")+` ORDER BY p.deleted_at LIMIT $2`, retain, 100)
		if err != nil {
			return err
		}
		var ids []string
		for rows.Next() {
			var id string
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err = rows.Err(); err != nil || len(ids) == 0 {
			return err
		}
		for _, stmt := range []string{
			// The parent foreign key would reject a delete that removes a parent before its replies.
			`UPDATE comments SET parent_id=NULL WHERE post_id=ANY($1::uuid[]) AND parent_id IS NOT NULL`,
			`DELETE FROM comments WHERE post_id=ANY($1::uuid[])`,
			`DELETE FROM post_reactions WHERE post_id=ANY($1::uuid[])`,
			`DELETE FROM saved_posts WHERE post_id=ANY($1::uuid[])`,
			`DELETE FROM post_counters WHERE post_id=ANY($1::uuid[])`,
			`DELETE FROM post_media WHERE post_id=ANY($1::uuid[])`,
		} {
			if _, err = tx.Exec(ctx, stmt, ids); err != nil {
				return err
			}
		}
		tag, err := tx.Exec(ctx, `DELETE FROM posts WHERE post_id=ANY($1::uuid[])`, ids)
		n = tag.RowsAffected()
		return err
	})
	// A chunk shorter than retentionChunk would end drain after one pass, so report a full chunk while
	// posts remain: the caller only needs "more to do" here.
	if n > 0 {
		n = retentionChunk
	}
	return n, err
}

// PurgeMessageMetadata deletes message metadata rows older than retain once nothing needs them: no envelope
// is still waiting for a device to receive it (both sides have it), no attachment hangs on it, and no report
// names it as evidence. A conversation always keeps each member's latest real (non-reaction) message, because
// the "has the peer replied" rule reads it.
func (s *Store) PurgeMessageMetadata(ctx context.Context, retain time.Duration) (int64, error) {
	return drain(ctx, func() (int64, error) {
		tag, err := s.Pool.Exec(ctx, `WITH evidence AS MATERIALIZED (
  SELECT DISTINCT ev->>'messageId' AS id FROM reports r
  CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.evidence)='array' THEN r.evidence ELSE '[]'::jsonb END) ev WHERE r.evidence IS NOT NULL)
 DELETE FROM messages WHERE ctid IN (SELECT m.ctid FROM messages m WHERE m.created_at<now()-$1::interval
  AND NOT EXISTS(SELECT 1 FROM message_envelopes e WHERE e.message_id=m.message_id AND e.delivered_at IS NULL)
  AND NOT EXISTS(SELECT 1 FROM chat_blobs b WHERE b.message_id=m.message_id)
  AND NOT EXISTS(SELECT 1 FROM reports r WHERE r.target_type='message' AND r.target_id=m.message_id)
  AND NOT EXISTS(SELECT 1 FROM evidence WHERE evidence.id=m.message_id::text)
  AND (m.aux OR EXISTS(SELECT 1 FROM messages n WHERE n.conversation_id=m.conversation_id AND n.sender_id=m.sender_id AND NOT n.aux AND (n.created_at,n.message_id)>(m.created_at,m.message_id)))
  ORDER BY m.created_at LIMIT $2)`, retain, retentionChunk)
		return tag.RowsAffected(), err
	})
}

// PurgeMediaTombstones deletes the rows of photos whose objects are gone (status deleted, keys cleared) more
// than retain ago. A row something still points at (a post's photo link, a story, a quarantine case) stays.
func (s *Store) PurgeMediaTombstones(ctx context.Context, retain time.Duration) (int64, error) {
	return drain(ctx, func() (int64, error) {
		tag, err := s.Pool.Exec(ctx, `DELETE FROM media_assets WHERE ctid IN (SELECT m.ctid FROM media_assets m WHERE m.status='deleted' AND m.variants IS NULL AND m.deleted_at<now()-$1::interval
  AND NOT EXISTS(SELECT 1 FROM post_media pm WHERE pm.media_id=m.media_id)
  AND NOT EXISTS(SELECT 1 FROM stories st WHERE st.media_id=m.media_id)
  AND NOT EXISTS(SELECT 1 FROM content_cases cc WHERE cc.media_id=m.media_id)
  ORDER BY m.deleted_at LIMIT $2)`, retain, retentionChunk)
		return tag.RowsAffected(), err
	})
}

// reconcileChunk is how many parent rows one reconcile statement recomputes.
const reconcileChunk = 500

// reconcile walks a table in key order, recomputing counters that are kept by write-time maintenance, and
// remembers its place in reconcile_state so a restart or a new leader carries on. Once a pass finishes it
// waits every before starting the next. step receives the key to continue after ("" at the start) and the
// chunk size, and returns the last key it examined, how many rows it examined and how many counters it repaired.
func (s *Store) reconcile(ctx context.Context, job string, every time.Duration, step func(ctx context.Context, after string, size int) (last string, seen int, repaired int64, err error)) (int64, error) {
	var cursor *string
	var finished bool
	var recent bool
	if err := s.Pool.QueryRow(ctx, `INSERT INTO reconcile_state(job) VALUES($1) ON CONFLICT (job) DO UPDATE SET job=excluded.job
 RETURNING cursor,finished_at IS NOT NULL,coalesce(finished_at>now()-$2::interval,false)`, job, every).Scan(&cursor, &finished, &recent); err != nil {
		return 0, err
	}
	if finished {
		if recent {
			return 0, nil
		}
		if _, err := s.Pool.Exec(ctx, `UPDATE reconcile_state SET cursor=NULL,started_at=now(),finished_at=NULL WHERE job=$1`, job); err != nil {
			return 0, err
		}
		cursor = nil
	}
	after := "00000000-0000-0000-0000-000000000000"
	if cursor != nil && *cursor != "" {
		after = *cursor
	}
	var total int64
	for ctx.Err() == nil {
		last, seen, repaired, err := step(ctx, after, reconcileChunk)
		total += repaired
		if err != nil {
			return total, err
		}
		if seen < reconcileChunk {
			_, err = s.Pool.Exec(ctx, `UPDATE reconcile_state SET cursor=NULL,finished_at=now() WHERE job=$1`, job)
			return total, err
		}
		after = last
		if _, err = s.Pool.Exec(ctx, `UPDATE reconcile_state SET cursor=$2 WHERE job=$1`, job, after); err != nil {
			return total, err
		}
	}
	return total, ctx.Err()
}

// scanStep runs a reconcile statement that returns (last key, rows examined, counters repaired).
func (s *Store) scanStep(ctx context.Context, sql, after string, size int) (string, int, int64, error) {
	var last *string
	var seen int
	var repaired int64
	if err := s.Pool.QueryRow(ctx, sql, after, size).Scan(&last, &seen, &repaired); err != nil {
		return "", 0, 0, err
	}
	if last == nil {
		return after, seen, repaired, nil
	}
	return *last, seen, repaired, nil
}

// ReconcileSocialCounters recomputes followers, following and friends of every member from the follow and
// friendship rows (the profile_social_counts view) and repairs any counter that drifted. Once a week.
func (s *Store) ReconcileSocialCounters(ctx context.Context, every time.Duration) (int64, error) {
	return s.reconcile(ctx, "social_counters", every, func(ctx context.Context, after string, size int) (string, int, int64, error) {
		return s.scanStep(ctx, `WITH b AS (SELECT user_id FROM users WHERE user_id>$1::uuid ORDER BY user_id LIMIT $2),
 fix AS (INSERT INTO social_counters(user_id,followers,following,friends)
  SELECT v.user_id,v.followers,v.following,v.friends FROM profile_social_counts v LEFT JOIN social_counters c ON c.user_id=v.user_id
  WHERE v.user_id IN (SELECT user_id FROM b) AND (coalesce(c.followers,0)<>v.followers OR coalesce(c.following,0)<>v.following OR coalesce(c.friends,0)<>v.friends)
  ON CONFLICT (user_id) DO UPDATE SET followers=excluded.followers,following=excluded.following,friends=excluded.friends,updated_at=now() RETURNING 1)
 SELECT (SELECT user_id::text FROM b ORDER BY user_id DESC LIMIT 1),(SELECT count(*) FROM b)::int,(SELECT count(*) FROM fix)`, after, size)
	})
}

// ReconcilePostCounters recomputes every post's reaction and comment counts from the reactions and comments
// themselves and repairs a drifted counter by adjusting slot 0 (the other slots are left as they are). Once a week.
func (s *Store) ReconcilePostCounters(ctx context.Context, every time.Duration) (int64, error) {
	return s.reconcile(ctx, "post_counters", every, func(ctx context.Context, after string, size int) (string, int, int64, error) {
		return s.scanStep(ctx, `WITH b AS (SELECT post_id FROM posts WHERE post_id>$1::uuid ORDER BY post_id LIMIT $2),
 a AS (SELECT b.post_id,
   (SELECT count(*) FROM post_reactions r WHERE r.post_id=b.post_id) AS reactions,
   (SELECT count(*) FROM comments c WHERE c.post_id=b.post_id AND NOT c.hidden AND c.deleted_at IS NULL) AS comments FROM b),
 cur AS (SELECT pc.post_id,sum(pc.reactions) AS r,sum(pc.comments) AS c,
   coalesce(sum(pc.reactions) FILTER (WHERE pc.slot<>0),0) AS r_other,coalesce(sum(pc.comments) FILTER (WHERE pc.slot<>0),0) AS c_other
  FROM post_counters pc WHERE pc.post_id IN (SELECT post_id FROM b) GROUP BY pc.post_id),
 fix AS (INSERT INTO post_counters(post_id,slot,reactions,comments)
  SELECT a.post_id,0,(a.reactions-coalesce(cur.r_other,0))::int,(a.comments-coalesce(cur.c_other,0))::int FROM a LEFT JOIN cur USING(post_id)
  WHERE a.reactions<>coalesce(cur.r,0) OR a.comments<>coalesce(cur.c,0)
  ON CONFLICT (post_id,slot) DO UPDATE SET reactions=excluded.reactions,comments=excluded.comments RETURNING 1)
 SELECT (SELECT post_id::text FROM b ORDER BY post_id DESC LIMIT 1),(SELECT count(*) FROM b)::int,(SELECT count(*) FROM fix)`, after, size)
	})
}

// ReconcileSpaceMemberCounts recomputes spaces.member_count from the active memberships (never below 1, the
// owner). Once a week.
func (s *Store) ReconcileSpaceMemberCounts(ctx context.Context, every time.Duration) (int64, error) {
	return s.reconcile(ctx, "space_member_counts", every, func(ctx context.Context, after string, size int) (string, int, int64, error) {
		return s.scanStep(ctx, `WITH b AS (SELECT space_id FROM spaces WHERE space_id>$1::uuid ORDER BY space_id LIMIT $2),
 a AS (SELECT b.space_id,greatest((SELECT count(*) FROM space_members m WHERE m.space_id=b.space_id AND m.state='active'),1)::int AS n FROM b),
 fix AS (UPDATE spaces s SET member_count=a.n FROM a WHERE s.space_id=a.space_id AND s.member_count<>a.n RETURNING 1)
 SELECT (SELECT space_id::text FROM b ORDER BY space_id DESC LIMIT 1),(SELECT count(*) FROM b)::int,(SELECT count(*) FROM fix)`, after, size)
	})
}
