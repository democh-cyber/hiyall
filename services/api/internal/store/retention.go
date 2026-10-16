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

// reportedMessageIDs is a CTE (name "evidence", column id) with the ids of the messages named in the evidence of
// any report (reports.evidence is an array of objects with a messageId). It is read once per statement, from the
// reports that carry evidence only (reports_with_evidence, migration 0044), and joined as a hash set: asking
// "is this message in some report's evidence" per message with a containment test scans every such report for
// every message (round-3 audit DB-NEW-4). Messages named as a report's target are looked up by reports_target.
const reportedMessageIDs = `evidence AS MATERIALIZED (
  SELECT DISTINCT ev->>'messageId' AS id FROM reports r
  CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.evidence)='array' THEN r.evidence ELSE '[]'::jsonb END) ev WHERE r.evidence IS NOT NULL)`

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
//
// One run is one pass over the old messages in (created_at, message_id) order, in windows of retentionChunk rows
// examined from a cursor (messages_age_key). The rows that stay (each member's latest message, reported ones)
// are therefore looked at once per run, not once per chunk as when every chunk began again at the oldest row
// (round-3 audit N11).
func (s *Store) PurgeMessageMetadata(ctx context.Context, retain time.Duration) (int64, error) {
	var total int64
	afterTS, afterID := "-infinity", "00000000-0000-0000-0000-000000000000"
	for ctx.Err() == nil {
		var examined, deleted int64
		var lastTS, lastID *string
		err := s.Pool.QueryRow(ctx, `WITH `+reportedMessageIDs+`,
 win AS MATERIALIZED (SELECT m.ctid AS tid,m.message_id,m.created_at,m.conversation_id,m.sender_id,m.aux FROM messages m
  WHERE m.created_at<now()-$1::interval AND (m.created_at,m.message_id)>($2::timestamptz,$3::uuid) ORDER BY m.created_at,m.message_id LIMIT $4),
 del AS (DELETE FROM messages WHERE ctid IN (SELECT w.tid FROM win w
  WHERE NOT EXISTS(SELECT 1 FROM message_envelopes e WHERE e.message_id=w.message_id AND e.delivered_at IS NULL)
  AND NOT EXISTS(SELECT 1 FROM chat_blobs b WHERE b.message_id=w.message_id)
  AND NOT EXISTS(SELECT 1 FROM reports r WHERE r.target_type='message' AND r.target_id=w.message_id)
  AND NOT EXISTS(SELECT 1 FROM evidence WHERE evidence.id=w.message_id::text)
  AND (w.aux OR EXISTS(SELECT 1 FROM messages n WHERE n.conversation_id=w.conversation_id AND n.sender_id=w.sender_id AND NOT n.aux AND (n.created_at,n.message_id)>(w.created_at,w.message_id)))) RETURNING 1)
 SELECT (SELECT count(*) FROM win),(SELECT count(*) FROM del),
  (SELECT created_at::text FROM win ORDER BY created_at DESC,message_id DESC LIMIT 1),(SELECT message_id::text FROM win ORDER BY created_at DESC,message_id DESC LIMIT 1)`,
			retain, afterTS, afterID, retentionChunk).Scan(&examined, &deleted, &lastTS, &lastID)
		total += deleted
		if err != nil || examined < retentionChunk || lastTS == nil {
			return total, err
		}
		afterTS, afterID = *lastTS, *lastID
	}
	return total, ctx.Err()
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
//
// A recount is only right if nobody changes the counters between reading the rows and writing the result, or the
// repair overwrites a bump that committed in between (and makes drift instead of fixing it). So each chunk is one
// transaction: it makes sure the counter rows exist (an uncommitted insert by a concurrent follow is waited for
// here), locks them in user id order, and only then, in a statement with a fresh snapshot, recounts and writes.
// A transaction that changed an edge and has not committed holds its counter rows, so the lock waits for it; one
// whose counter bump has not run yet is behind this lock, and its bump lands on top of the repaired value. A
// deadlock with such a transaction is retried once by inTx.
func (s *Store) ReconcileSocialCounters(ctx context.Context, every time.Duration) (int64, error) {
	return s.reconcile(ctx, "social_counters", every, func(ctx context.Context, after string, size int) (string, int, int64, error) {
		var last *string
		var seen int
		var repaired int64
		err := s.inTx(ctx, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO social_counters(user_id) SELECT user_id FROM (SELECT user_id FROM users WHERE user_id>$1::uuid ORDER BY user_id LIMIT $2) b ORDER BY user_id ON CONFLICT (user_id) DO NOTHING`, after, size); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `SELECT 1 FROM social_counters WHERE user_id IN (SELECT user_id FROM users WHERE user_id>$1::uuid ORDER BY user_id LIMIT $2) ORDER BY user_id FOR UPDATE`, after, size); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `WITH b AS (SELECT user_id FROM users WHERE user_id>$1::uuid ORDER BY user_id LIMIT $2),
 fix AS (UPDATE social_counters c SET followers=v.followers,following=v.following,friends=v.friends,updated_at=now()
  FROM profile_social_counts v WHERE v.user_id=c.user_id AND c.user_id IN (SELECT user_id FROM b)
  AND (c.followers<>v.followers OR c.following<>v.following OR c.friends<>v.friends) RETURNING 1)
 SELECT (SELECT user_id::text FROM b ORDER BY user_id DESC LIMIT 1),(SELECT count(*) FROM b)::int,(SELECT count(*) FROM fix)`, after, size).Scan(&last, &seen, &repaired)
		})
		if err != nil {
			return "", 0, 0, err
		}
		if last == nil {
			return after, seen, repaired, nil
		}
		return *last, seen, repaired, nil
	})
}

// scanStepLocked is scanStep in one transaction that first runs lock (a SELECT ... FOR UPDATE over the chunk's
// counter rows, same parameters) so the recount cannot overwrite a bump that commits in between; see
// ReconcileSocialCounters. inTx retries it once after a deadlock.
func (s *Store) scanStepLocked(ctx context.Context, lock, sql, after string, size int) (last string, seen int, repaired int64, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, lock, after, size); err != nil {
			return err
		}
		var l *string
		if err := tx.QueryRow(ctx, sql, after, size).Scan(&l, &seen, &repaired); err != nil {
			return err
		}
		last = after
		if l != nil {
			last = *l
		}
		return nil
	})
	return last, seen, repaired, err
}

// ReconcilePostCounters recomputes every post's reaction and comment counts from the reactions and comments
// themselves and repairs a drifted counter by adjusting slot 0 (the other slots are left as they are). Once a week.
func (s *Store) ReconcilePostCounters(ctx context.Context, every time.Duration) (int64, error) {
	return s.reconcile(ctx, "post_counters", every, func(ctx context.Context, after string, size int) (string, int, int64, error) {
		return s.scanStepLocked(ctx, `SELECT 1 FROM post_counters WHERE post_id IN (SELECT post_id FROM posts WHERE post_id>$1::uuid ORDER BY post_id LIMIT $2) ORDER BY post_id,slot FOR UPDATE`, `WITH b AS (SELECT post_id FROM posts WHERE post_id>$1::uuid ORDER BY post_id LIMIT $2),
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
