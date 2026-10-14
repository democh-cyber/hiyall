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
	failed := []string{} // rows that failed this run: skipped, so one poisoned row cannot starve the rest
	var failures int
	for finished < int64(batch) && ctx.Err() == nil {
		n, bad, err := s.purgeMediaChunk(ctx, objects, failed)
		if err != nil {
			return finished, err
		}
		finished += n
		failures += len(bad)
		failed = append(failed, bad...)
		if n == 0 {
			break // nothing more could be finished (either nothing is left, or only failing rows)
		}
	}
	if failures > 0 {
		return finished, errors.New("some photo objects were not removed; they are retried on the next run")
	}
	return finished, ctx.Err()
}

type mediaRow struct {
	id       string
	keys     []string
	finished bool
}

func (s *Store) purgeMediaChunk(ctx context.Context, objects MediaObjects, skip []string) (finished int64, failed []string, err error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, nil, err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `SELECT media_id::text,upload_key,variants FROM media_assets
 WHERE ((status NOT IN ('deleted','quarantined') AND NOT attached AND expires_at<now()) OR (status='deleted' AND variants IS NOT NULL))
 AND media_id::text<>ALL($2::text[])
 ORDER BY coalesce(deleted_at,expires_at),media_id LIMIT $1 FOR UPDATE SKIP LOCKED`, mediaChunk, skip)
	if err != nil {
		return 0, nil, err
	}
	var claimed []*mediaRow
	for rows.Next() {
		var id string
		var upload *string
		var variants map[string]string
		if err = rows.Scan(&id, &upload, &variants); err != nil {
			rows.Close()
			return 0, nil, err
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
		return 0, nil, err
	}
	if len(claimed) == 0 {
		return 0, nil, nil
	}
	var done []string
	for _, row := range claimed {
		if len(row.keys) > 0 {
			if derr := objects.Delete(ctx, row.keys...); derr != nil {
				// The code is logged, never the error text: it can carry a URL.
				slog.Warn("photo object not removed", "mediaId", row.id, "reason", media.ErrorCode(derr))
				failed = append(failed, row.id)
				continue
			}
		}
		done = append(done, row.id)
	}
	if len(done) > 0 {
		if _, err = tx.Exec(ctx, `UPDATE media_assets SET status='deleted',deleted_at=coalesce(deleted_at,now()),variants=NULL WHERE media_id=ANY($1::uuid[])`, done); err != nil {
			return 0, failed, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return 0, failed, err
	}
	return int64(len(done)), failed, nil
}
