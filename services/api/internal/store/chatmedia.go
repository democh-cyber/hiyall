package store

import (
	"context"
	"errors"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Encrypted chat attachments: the table holds only what the server needs to authorize, size-check and
// expire opaque ciphertext objects (migration 0023, docs/security/14-encrypted-chat-attachments.md).

// BlobKey is the object key of a blob in the chat bucket: random, no user or conversation names.
func BlobKey(blobID string) string { return "chat/" + blobID }

// blobPeerSQL is the other member of conversation row c, for caller $1.
const blobPeerSQL = `CASE WHEN c.user_low_id=$1::uuid THEN c.user_high_id ELSE c.user_low_id END`

// blobReachable is true while conversation row c is active and its members, caller $1 and the peer, may
// still reach each other (not blocked, same age band, both active and onboarded): the 404 conditions of
// every blob route.
const blobReachable = `c.status='active' AND $1::uuid IN (c.user_low_id,c.user_high_id) AND NOT interaction_barred($1::uuid,` + blobPeerSQL + `) AND ` + `EXISTS(SELECT 1 FROM users mu JOIN onboarding mo ON mo.user_id=mu.user_id WHERE mu.user_id=` + blobPeerSQL + ` AND mu.status='active' AND mo.completed_at IS NOT NULL)`

// peerMayReceiveImages is the sender's gate: the peer has sent a message in the conversation, or the two
// are friends. It stops strangers from pushing unsolicited images; the peer replying is the consent.
func peerMayReceiveImages(ctx context.Context, q querier, conversationID, sender, peer string) error {
	var allowed bool
	err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=$1 AND sender_id=$3 AND NOT aux)
 OR EXISTS(SELECT 1 FROM friendships WHERE user_low_id=least($2::uuid,$3::uuid) AND user_high_id=greatest($2::uuid,$3::uuid) AND status='accepted')`, conversationID, sender, peer).Scan(&allowed)
	if err != nil {
		return err
	}
	if !allowed {
		return domain.ErrAttachmentsNotAllowed
	}
	return nil
}

var (
	errBlobQuota   = &domain.PolicyError{Status: 429, Code: "QUOTA", Message: "You've sent a lot of photos today. Try again later."}
	errBlobPending = &domain.PolicyError{Status: 429, Code: "RATE_LIMITED", Message: "Finish your current uploads first"}
)

// CreateBlobSlot reserves an upload slot for one ciphertext blob. The caller must belong to an active
// conversation, not be barred from the peer, pass canMessage, and the peer must have replied or be a
// friend. Quotas are per member, from e: BlobsPerDay and BlobBytesPerDay over a rolling 24 hours counted by
// creation time whatever became of the blob (deleting one never frees quota), and PendingBlobs
// not yet completed. Both accounts are locked in order, so one member's slots are serialized and the
// counts below cannot be raced past.
func (s *Store) CreateBlobSlot(ctx context.Context, user, conversationID string, b domain.NewBlob, e domain.Entitlements) (id, key string, err error) {
	var peer string
	err = s.Pool.QueryRow(ctx, `SELECT (CASE WHEN user_low_id=$2 THEN user_high_id ELSE user_low_id END)::text FROM conversations WHERE conversation_id=$1 AND $2 IN (user_low_id,user_high_id)`, conversationID, user).Scan(&peer)
	if err != nil {
		return "", "", mapped(err)
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockPair(ctx, tx, user, peer); err != nil {
			return err
		}
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM conversations WHERE conversation_id=$1`, conversationID).Scan(&status); err != nil {
			return mapped(err)
		}
		if status != "active" {
			return domain.ErrNotFound
		}
		if err := canMessage(ctx, tx, user, peer); err != nil {
			return err
		}
		if err := peerMayReceiveImages(ctx, tx, conversationID, user, peer); err != nil {
			return err
		}
		var count, pending int
		var bytes int64
		var firstPending *time.Time
		if err := tx.QueryRow(ctx, `SELECT count(*),coalesce(sum(size_bytes),0),count(*) FILTER (WHERE state='pending' AND expires_at>now()),min(expires_at) FILTER (WHERE state='pending' AND expires_at>now())
 FROM chat_blobs WHERE uploader_id=$1 AND created_at>now()-interval '24 hours'`, user).Scan(&count, &bytes, &pending, &firstPending); err != nil {
			return err
		}
		if pending >= e.PendingBlobs {
			// A slot frees when the oldest pending one expires, or sooner when it is completed.
			wait := time.Second
			if firstPending != nil {
				var seconds float64
				if err := tx.QueryRow(ctx, `SELECT extract(epoch FROM $1::timestamptz-now())`, *firstPending).Scan(&seconds); err != nil {
					return err
				}
				wait = time.Duration(math.Ceil(max(seconds, 1))) * time.Second
			}
			return domain.RetryAfter(errBlobPending, wait)
		}
		if count >= e.BlobsPerDay || bytes+b.SizeBytes > e.BlobBytesPerDay {
			wait, err := blobQuotaWait(ctx, tx, user, count, bytes, b.SizeBytes, e)
			if err != nil {
				return err
			}
			return domain.RetryAfter(errBlobQuota, wait)
		}
		id = uuid.NewString()
		key = BlobKey(id)
		_, err := tx.Exec(ctx, `INSERT INTO chat_blobs(blob_id,uploader_id,conversation_id,role,size_bytes,ct_sha256,object_key,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,now()+$8::interval)`, id, user, conversationID, b.Role, b.SizeBytes, b.CtSha256, key, domain.UnattachedBlobTTL)
		return err
	})
	if err != nil {
		return "", "", err
	}
	return id, key, nil
}

// blobQuotaWait is how long until enough of the member's oldest blobs leave the 24 hour window for a new
// one of size bytes to fit under both the count and the byte cap.
func blobQuotaWait(ctx context.Context, q querier, user string, count int, bytes, size int64, e domain.Entitlements) (time.Duration, error) {
	rows, err := q.Query(ctx, `SELECT size_bytes,extract(epoch FROM created_at+interval '24 hours'-now()) FROM chat_blobs
 WHERE uploader_id=$1 AND created_at>now()-interval '24 hours' ORDER BY created_at,blob_id`, user)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	wait := time.Second
	for rows.Next() {
		var sz int64
		var seconds float64
		if err = rows.Scan(&sz, &seconds); err != nil {
			return 0, err
		}
		// Dropping this oldest blob and every one before it from the window.
		count--
		bytes -= sz
		wait = time.Duration(math.Ceil(max(seconds, 1))) * time.Second
		if count < e.BlobsPerDay && bytes+size <= e.BlobBytesPerDay {
			return wait, nil
		}
	}
	return wait, rows.Err()
}

// BlobUpload is a blob its uploader may finish.
type BlobUpload struct {
	State, Key string
	Size       int64
}

// PendingBlob finds the caller's own blob for completing it. Anyone else's blob, one in a closed or barred
// conversation, or an unknown id is ErrNotFound; an expired or deleted blob is ErrBlobExpired.
func (s *Store) PendingBlob(ctx context.Context, user, blobID string) (BlobUpload, error) {
	var u BlobUpload
	var key *string
	var expired bool
	err := s.Pool.QueryRow(ctx, `SELECT b.state,b.object_key,b.size_bytes,b.expires_at<=now()
 FROM chat_blobs b JOIN conversations c ON c.conversation_id=b.conversation_id
 WHERE b.blob_id=$2 AND b.uploader_id=$1 AND `+blobReachable, user, blobID).Scan(&u.State, &key, &u.Size, &expired)
	if err != nil {
		return u, mapped(err)
	}
	if u.State == "deleted" || expired {
		return u, domain.ErrBlobExpired
	}
	if key != nil {
		u.Key = *key
	}
	return u, nil
}

// BlobUploaded marks a pending blob uploaded. It stays unattached, so it expires an hour from now unless a
// message claims it. It reports false when the blob was not pending (another complete won, or it was deleted).
func (s *Store) BlobUploaded(ctx context.Context, user, blobID string) (bool, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE chat_blobs SET state='uploaded',uploaded_at=now(),expires_at=now()+$3::interval
 WHERE blob_id=$2 AND uploader_id=$1 AND state='pending' AND expires_at>now()`, user, blobID, domain.UnattachedBlobTTL)
	return tag.RowsAffected() == 1, err
}

// DeleteBlob marks the uploader's blob deleted and returns its object key so the caller can remove the
// object at once; the clean-up job removes it later if that fails. A held blob (evidence in a report) is
// left alone and reported as not deleted, an unknown or foreign id is ErrNotFound, and deleting twice is fine.
func (s *Store) DeleteBlob(ctx context.Context, user, blobID string) (key string, deleted bool, err error) {
	var held bool
	var state string
	var objectKey *string
	err = s.Pool.QueryRow(ctx, `SELECT state,object_key,held_report_id IS NOT NULL FROM chat_blobs WHERE blob_id=$2 AND uploader_id=$1`, user, blobID).Scan(&state, &objectKey, &held)
	if err != nil {
		return "", false, mapped(err)
	}
	if held {
		return "", false, nil
	}
	tag, err := s.Pool.Exec(ctx, `UPDATE chat_blobs SET state='deleted',deleted_at=now() WHERE blob_id=$2 AND uploader_id=$1 AND state<>'deleted' AND held_report_id IS NULL`, user, blobID)
	if err != nil {
		return "", false, err
	}
	if tag.RowsAffected() == 1 && objectKey != nil {
		key = *objectKey
	}
	return key, true, nil
}

// BlobObjectRemoved records that a deleted blob's object is gone from the chat bucket.
func (s *Store) BlobObjectRemoved(ctx context.Context, blobIDs ...string) error {
	_, err := s.Pool.Exec(ctx, `UPDATE chat_blobs SET object_key=NULL WHERE blob_id=ANY($1::uuid[]) AND state='deleted' AND held_report_id IS NULL`, blobIDs)
	return err
}

// BlobDownload is what a download URL is minted for.
type BlobDownload struct {
	Key  string
	Size int64
}

// BlobForDownload authorizes reading a blob: the caller belongs to the active conversation, is not barred
// from the peer, and the blob is uploaded, linked to a message and unexpired. Muting or restricting the
// sender does not matter. A blob that is not linked yet exists only for its uploader (ErrBlobNotReady);
// everyone else gets ErrNotFound. Expired or deleted is ErrBlobExpired.
func (s *Store) BlobForDownload(ctx context.Context, user, conversationID, blobID string) (BlobDownload, error) {
	var d BlobDownload
	var state string
	var key *string
	var linked, mine, expired bool
	err := s.Pool.QueryRow(ctx, `SELECT b.state,b.object_key,b.size_bytes,b.message_id IS NOT NULL,b.uploader_id=$1,b.expires_at<=now()
 FROM chat_blobs b JOIN conversations c ON c.conversation_id=b.conversation_id
 WHERE b.blob_id=$3 AND b.conversation_id=$2 AND `+blobReachable, user, conversationID, blobID).Scan(&state, &key, &d.Size, &linked, &mine, &expired)
	if err != nil {
		return d, mapped(err)
	}
	switch {
	case !linked && !mine:
		return d, domain.ErrNotFound
	case state == "deleted" || expired:
		return d, domain.ErrBlobExpired
	case !linked || state != "uploaded" || key == nil:
		return d, domain.ErrBlobNotReady
	}
	d.Key = *key
	return d, nil
}

// linkBlobs claims the blobs of a message inside its send transaction: every id must be an uploaded, unclaimed,
// unexpired blob of the sender in this conversation, otherwise BLOB_NOT_READY (unknown and foreign ids look
// the same). The sender must still pass the images gate. The message row exists already, as the foreign key
// needs. Linking starts the sender's LinkedBlobRetention (30 days on Free).
func linkBlobs(ctx context.Context, tx pgx.Tx, user, peer, conversationID, messageID string, blobIDs []string, e domain.Entitlements) error {
	if err := peerMayReceiveImages(ctx, tx, conversationID, user, peer); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `UPDATE chat_blobs SET message_id=$1,expires_at=now()+$5::interval
 WHERE blob_id=ANY($2::uuid[]) AND uploader_id=$3 AND conversation_id=$4 AND state='uploaded' AND message_id IS NULL AND expires_at>now()`,
		messageID, blobIDs, user, conversationID, e.LinkedBlobRetention)
	if err != nil {
		return err
	}
	if int(tag.RowsAffected()) != len(blobIDs) {
		return domain.ErrBlobNotReady
	}
	return nil
}

// holdEvidenceBlobs validates the attachments of a report's evidence messages and holds their blobs. Every
// blob id must belong to the evidence message it is listed under, in the reported conversation. The rows are
// locked first, so the clean-up job cannot delete one between the check and the hold.
func holdEvidenceBlobs(ctx context.Context, tx pgx.Tx, reportID, conversationID string, evidence []domain.Evidence) error {
	var held []string
	for _, e := range evidence {
		for _, a := range e.Attachments {
			held = append(held, a.BlobIDs...)
		}
	}
	if len(held) == 0 {
		return nil
	}
	rows, err := tx.Query(ctx, `SELECT blob_id FROM chat_blobs WHERE blob_id=ANY($1::uuid[]) ORDER BY blob_id FOR UPDATE`, held)
	if err != nil {
		return err
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, e := range evidence {
		for _, a := range e.Attachments {
			var matching int
			if err = tx.QueryRow(ctx, `SELECT count(*) FROM chat_blobs WHERE blob_id=ANY($1::uuid[]) AND message_id=$2 AND conversation_id=$3`, a.BlobIDs, e.MessageID, conversationID).Scan(&matching); err != nil {
				return err
			}
			if matching != len(a.BlobIDs) {
				return &domain.ValidationError{Field: "evidence", Message: "attachments must belong to the shared message"}
			}
		}
	}
	// A blob already purged has no object left to hold; one held by an earlier report keeps that hold.
	_, err = tx.Exec(ctx, `UPDATE chat_blobs SET held_report_id=$1 WHERE blob_id=ANY($2::uuid[]) AND state<>'deleted' AND held_report_id IS NULL`, reportID, held)
	return err
}

// HeldBlobs lists the blobs held for a report, for the moderation tool: ids, sizes and hashes only.
func (s *Store) HeldBlobs(ctx context.Context, reportID string) ([]domain.BlobInfo, error) {
	rows, err := s.Pool.Query(ctx, `SELECT blob_id::text,role,size_bytes,encode(ct_sha256,'base64'),state FROM chat_blobs WHERE held_report_id=$1 ORDER BY created_at,blob_id`, reportID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.BlobInfo, error) {
		var b domain.BlobInfo
		return b, row.Scan(&b.BlobID, &b.Role, &b.SizeBytes, &b.CtSha256, &b.State)
	})
}

// ChatObjects is the part of the chat object store the clean-up needs.
type ChatObjects interface {
	Delete(ctx context.Context, keys ...string) error
}

// PurgeChatBlobs removes the objects of expired and deleted blobs, at most about batch of each kind per call,
// and clears their keys. A blob is expired 30 days after its message (1 hour unattached). Blobs held for a
// report are skipped. A storage failure leaves the row marked deleted with its key, so the next run retries
// it; the bucket's own lifecycle rule is the final safety net. It returns the objects removed, so the
// maintenance loop keeps going while full batches remain.
func (s *Store) PurgeChatBlobs(ctx context.Context, objects ChatObjects, batch int) (int64, error) {
	rows, err := s.Pool.Query(ctx, `WITH gone AS (
  (SELECT blob_id FROM chat_blobs WHERE state<>'deleted' AND expires_at<now() AND held_report_id IS NULL ORDER BY expires_at LIMIT $1)
  UNION ALL
  (SELECT blob_id FROM chat_blobs WHERE state='deleted' AND object_key IS NOT NULL AND held_report_id IS NULL ORDER BY deleted_at LIMIT $1)
 ) UPDATE chat_blobs b SET state='deleted',deleted_at=coalesce(b.deleted_at,now()) FROM gone
 WHERE b.blob_id=gone.blob_id AND b.held_report_id IS NULL RETURNING b.blob_id::text,b.object_key`, batch)
	if err != nil {
		return 0, err
	}
	type target struct{ id, key string }
	var targets []target
	for rows.Next() {
		var t target
		var key *string
		if err = rows.Scan(&t.id, &key); err != nil {
			rows.Close()
			return 0, err
		}
		if key != nil {
			t.key = *key
			targets = append(targets, t)
		}
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, err
	}
	var removed []string
	var failure error
	for _, t := range targets {
		if err = objects.Delete(ctx, t.key); err != nil {
			failure = err
			continue
		}
		removed = append(removed, t.id)
	}
	if len(removed) > 0 {
		if err = s.BlobObjectRemoved(ctx, removed...); err != nil {
			return 0, err
		}
	}
	// Only removals count, so a store that keeps failing ends the maintenance loop instead of spinning on the same rows.
	if failure != nil {
		return int64(len(removed)), errors.New("some chat objects were not removed; they are retried on the next run")
	}
	return int64(len(removed)), nil
}

// PurgeChatBlobTombstones deletes the rows of blobs whose object is gone once they no longer count towards
// any quota window (two days after creation).
func (s *Store) PurgeChatBlobTombstones(ctx context.Context, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM chat_blobs WHERE ctid IN (SELECT ctid FROM chat_blobs WHERE state='deleted' AND object_key IS NULL AND held_report_id IS NULL AND created_at<now()-interval '2 days' ORDER BY created_at LIMIT $1)`, batch)
	return tag.RowsAffected(), err
}

// DeleteUserChatBlobs is the hook for account deletion, which does not exist yet: it marks every blob the
// user uploaded deleted (held evidence excepted), and the clean-up job removes the objects. Account deletion
// must call it in its own transaction before it removes anything the blobs reference.
func DeleteUserChatBlobs(ctx context.Context, tx pgx.Tx, user string) (int64, error) {
	tag, err := tx.Exec(ctx, `UPDATE chat_blobs SET state='deleted',deleted_at=now() WHERE uploader_id=$1 AND state<>'deleted' AND held_report_id IS NULL`, user)
	return tag.RowsAffected(), err
}
