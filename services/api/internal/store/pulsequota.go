package store

import (
	"context"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Per-member limits on photos, posts and stories (docs/api/16-pulse-and-media.md#limits-and-quotas). The
// numbers come from the member's domain.Entitlements, passed in by the caller. Like the chat quotas
// they count by creation time over a rolling 24 hours whatever became of the item afterwards, so
// deleting never refunds. Each check runs in the transaction that inserts, behind a per-member
// advisory lock, so two concurrent requests cannot both pass at count N-1.

// lockQuota takes a transaction-scoped advisory lock for one kind of item of one member ("upload",
// "post", "story" or "chat", the conversations they start); the next request of that kind from the same member waits for this commit.
func lockQuota(ctx context.Context, tx pgx.Tx, kind, user string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "pulse-"+kind+"\x1f"+user)
	return err
}

// windowWait is how long until enough of the member's oldest counted items leave the 24 hour window for
// fits to hold. list selects (size, seconds until the item leaves the window) of the window's items,
// oldest first, for $1 = user; count and bytes are the window's totals now.
func windowWait(ctx context.Context, q querier, list, user string, count int, bytes int64, fits func(count int, bytes int64) bool) (time.Duration, error) {
	rows, err := q.Query(ctx, list, user)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	wait := time.Second
	for rows.Next() {
		var size int64
		var seconds float64
		if err = rows.Scan(&size, &seconds); err != nil {
			return 0, err
		}
		// Dropping this item and every older one from the window.
		count--
		bytes -= size
		wait = time.Duration(math.Ceil(max(seconds, 1))) * time.Second
		if fits(count, bytes) {
			return wait, nil
		}
	}
	return wait, rows.Err()
}

// checkItemQuota refuses a new post (table posts) or story (table stories) when the member already has
// limit in the window, counting deleted ones. The caller holds the member's lock for that kind.
func checkItemQuota(ctx context.Context, tx pgx.Tx, table, owner string, limit int, refusal *domain.PolicyError) error {
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE author_id=$1 AND created_at>now()-interval '24 hours'`, owner).Scan(&count); err != nil {
		return err
	}
	if count < limit {
		return nil
	}
	id := map[string]string{"posts": "post_id", "stories": "story_id"}[table]
	wait, err := windowWait(ctx, tx, `SELECT 0::bigint,extract(epoch FROM created_at+interval '24 hours'-now()) FROM `+table+`
 WHERE author_id=$1 AND created_at>now()-interval '24 hours' ORDER BY created_at,`+id, owner, count, 0,
		func(count int, _ int64) bool { return count < limit })
	if err != nil {
		return err
	}
	return domain.RetryAfter(refusal, wait)
}

// checkUploadQuota refuses a new upload slot of size declared bytes when the member has used their
// upload slots or declared bytes in the window (all purposes, whatever became of the uploads), or when
// their live storage plus size would pass the storage cap. Live storage is the sum of size_bytes of
// their ready media, attached or not: the stored size of the re-encoded variants, which deleting a post,
// a story or the avatar frees. The caller holds the member's "upload" lock.
func checkUploadQuota(ctx context.Context, tx pgx.Tx, owner string, size int64, e domain.Entitlements) error {
	var count int
	var bytes, stored int64
	if err := tx.QueryRow(ctx, `SELECT count(*),coalesce(sum(declared_bytes),0) FROM media_assets WHERE owner_id=$1 AND created_at>now()-interval '24 hours'`, owner).Scan(&count, &bytes); err != nil {
		return err
	}
	if count >= e.UploadsPerDay || bytes+size > e.UploadBytesPerDay {
		wait, err := windowWait(ctx, tx, `SELECT declared_bytes,extract(epoch FROM created_at+interval '24 hours'-now()) FROM media_assets
 WHERE owner_id=$1 AND created_at>now()-interval '24 hours' ORDER BY created_at,media_id`, owner, count, bytes,
			func(count int, bytes int64) bool { return count < e.UploadsPerDay && bytes+size <= e.UploadBytesPerDay })
		if err != nil {
			return err
		}
		return domain.RetryAfter(domain.ErrUploadQuota, wait)
	}
	if err := tx.QueryRow(ctx, `SELECT coalesce(sum(size_bytes),0) FROM media_assets WHERE owner_id=$1 AND status='ready'`, owner).Scan(&stored); err != nil {
		return err
	}
	if stored+size > e.StorageBytes {
		return domain.ErrStorageFull
	}
	return nil
}

// checkNewChatQuota refuses a new conversation when the member has already started
// e.NewConversationsPerDay in the window. It counts conversations the member created (created_by, the
// first opener) by creation time, so deleting or closing one never refunds, and reopening an existing
// one never reaches it. Only the member's own conversations are scanned, through the per-member
// indexes on user_low_id and user_high_id. The caller holds the member's "chat" lock.
func checkNewChatQuota(ctx context.Context, tx pgx.Tx, owner string, e domain.Entitlements) error {
	const mine = ` FROM conversations WHERE created_by=$1 AND (user_low_id=$1 OR user_high_id=$1) AND created_at>now()-interval '24 hours'`
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*)`+mine, owner).Scan(&count); err != nil {
		return err
	}
	if count < e.NewConversationsPerDay {
		return nil
	}
	wait, err := windowWait(ctx, tx, `SELECT 0::bigint,extract(epoch FROM created_at+interval '24 hours'-now())`+mine+` ORDER BY created_at,conversation_id`, owner, count, 0,
		func(count int, _ int64) bool { return count < e.NewConversationsPerDay })
	if err != nil {
		return err
	}
	return domain.RetryAfter(domain.ErrNewChatsQuota, wait)
}
