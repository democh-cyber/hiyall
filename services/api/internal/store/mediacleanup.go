package store

import (
	"context"
	"errors"
	"log/slog"

	"hiyall/services/api/internal/media"
)

// MediaObjects is the object storage the media cleanup removes from (media.Store satisfies it).
type MediaObjects interface {
	Delete(ctx context.Context, keys ...string) error
}

// mediaChunk is how many photo rows one cleanup transaction claims. Each row's locks are held while its
// objects are removed from storage, so the chunk is small.
const mediaChunk = 50

// PurgeMedia removes the stored objects of photos nobody needs any more: uploads that were never attached
// and have expired, and photos marked deleted (replaced avatars, deleted posts and stories, purged
// accounts). It returns how many photo rows were finished, at most about batch.
//
// The order is what keeps photos from being orphaned (audit D3): the rows are claimed FOR UPDATE SKIP
// LOCKED (two nodes never take the same ones), their objects are deleted FIRST, one row at a time, and only
// the rows whose objects are all gone are then marked deleted with their keys cleared. A failed delete
// leaves its row untouched, so the next run finds it again; the others in the chunk are not held back. A row
// is never marked finished while an object remains, and the account purge only sees media_assets rows
// drain once they are finished, so "drained" means no photo objects are left.
//
// A quarantined photo (scanner match, held as evidence) is never touched here.
//
// A non-nil error means some objects could not be removed; the rest of the work still happened.
func (s *Store) PurgeMedia(ctx context.Context, objects MediaObjects, batch int) (int64, error) {
	var finished int64
	var failures int
	cur := mediaCursor{at: "-infinity", id: "00000000-0000-0000-0000-000000000000"}
	for finished < int64(batch) && ctx.Err() == nil {
		n, bad, next, more, err := s.purgeMediaChunk(ctx, objects, cur)
		if err != nil {
			return finished, err
		}
		finished += n
		failures += bad
		if !more {
			break // nothing is left after the cursor
		}
		cur = next
	}
	if failures > 0 {
		return finished, errors.New("some photo objects were not removed; they are retried on the next run")
	}
	return finished, ctx.Err()
}

// mediaCursor is the keyset position of a cleanup run: the (time, id) of the last row a chunk looked at. A row
// that failed or that another node had locked is behind the cursor for the rest of this run and is found again by
// the next one, so one poisoned row cannot starve the rest and no list of skipped ids has to be carried.
type mediaCursor struct{ at, id string }

type mediaRow struct {
	id       string
	keys     []string
	finished bool
}

// purgeMediaChunk claims the next mediaChunk rows after cur. The two kinds of work are each read in index order
// from the cursor (media_cleanup_expired and media_cleanup_deleted, migration 0044) and merged, so the chunk costs
// its own size however large the backlog is; the old single query with an OR and ORDER BY coalesce(...) sorted the
// whole backlog for every chunk of 50. Ordering is the same as before: oldest first, by expiry for an expired
// upload and by deletion time for a deleted photo.
func (s *Store) purgeMediaChunk(ctx context.Context, objects MediaObjects, cur mediaCursor) (finished int64, failed int, next mediaCursor, more bool, err error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, 0, cur, false, err
	}
	defer tx.Rollback(ctx)
	cand, err := tx.Query(ctx, `SELECT media_id::text,k::text FROM (
  (SELECT media_id,expires_at AS k FROM media_assets WHERE status NOT IN ('deleted','quarantined') AND NOT attached AND expires_at<now()
    AND (expires_at,media_id)>($2::timestamptz,$3::uuid) ORDER BY expires_at,media_id LIMIT $1)
  UNION ALL
  (SELECT media_id,deleted_at FROM media_assets WHERE status='deleted' AND variants IS NOT NULL
    AND (deleted_at,media_id)>($2::timestamptz,$3::uuid) ORDER BY deleted_at,media_id LIMIT $1)) c
 ORDER BY k,media_id LIMIT $1`, mediaChunk, cur.at, cur.id)
	if err != nil {
		return 0, 0, cur, false, err
	}
	var ids []string
	next = cur
	for cand.Next() {
		var id, k string
		if err = cand.Scan(&id, &k); err != nil {
			cand.Close()
			return 0, 0, cur, false, err
		}
		ids = append(ids, id)
		next = mediaCursor{at: k, id: id}
	}
	cand.Close()
	if err = cand.Err(); err != nil || len(ids) == 0 {
		return 0, 0, cur, false, err
	}
	// Claim them (a row another node holds is skipped) and read what is needed to remove the objects.
	rows, err := tx.Query(ctx, `SELECT media_id::text,upload_key,variants FROM media_assets
 WHERE media_id=ANY($1::uuid[]) AND ((status NOT IN ('deleted','quarantined') AND NOT attached AND expires_at<now()) OR (status='deleted' AND variants IS NOT NULL))
 ORDER BY media_id FOR UPDATE SKIP LOCKED`, ids)
	if err != nil {
		return 0, 0, cur, false, err
	}
	var claimed []*mediaRow
	for rows.Next() {
		var id string
		var upload *string
		var variants map[string]string
		if err = rows.Scan(&id, &upload, &variants); err != nil {
			rows.Close()
			return 0, 0, cur, false, err
		}
		row := &mediaRow{id: id}
		if upload != nil && *upload != "" {
			row.keys = append(row.keys, *upload)
		}
		for _, k := range variants {
			row.keys = append(row.keys, k)
		}
		claimed = append(claimed, row)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, 0, cur, false, err
	}
	var done []string
	for _, row := range claimed {
		if len(row.keys) > 0 {
			if derr := objects.Delete(ctx, row.keys...); derr != nil {
				// The code is logged, never the error text: it can carry a URL.
				slog.Warn("photo object not removed", "mediaId", row.id, "reason", media.ErrorCode(derr))
				failed++
				continue
			}
		}
		done = append(done, row.id)
	}
	if len(done) > 0 {
		if _, err = tx.Exec(ctx, `UPDATE media_assets SET status='deleted',deleted_at=coalesce(deleted_at,now()),variants=NULL WHERE media_id=ANY($1::uuid[])`, done); err != nil {
			return 0, failed, cur, false, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return 0, failed, cur, false, err
	}
	return int64(len(done)), failed, next, len(ids) == mediaChunk, nil
}
