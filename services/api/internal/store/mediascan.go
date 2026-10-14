package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
)

// Quarantine records an upload the scanner matched or flagged (docs/security/16-csam-and-illegal-content.md).
type Quarantine struct {
	MediaID, Owner, Purpose string
	Result, Scanner         string // result: "flagged" or "match"
	Signals                 map[string]string
	OriginalSHA256          string
	OriginalBytes           int64
	ContentType             string
	OriginalKey, FullKey    string // the hold/ keys the objects were written to
}

// ScannerActor is the actor recorded for what the scanner did on its own.
const ScannerActor = "system:upload-scanner"

// QuarantineMedia, in one transaction: marks the pending upload quarantined (never served, never
// attachable, never cleaned up), opens the operator case with the evidence record and, for a match,
// suspends the uploader and ends their sessions pending review. It returns the case id. The photo is
// not sent anywhere: the objects stay in the bucket under the hold prefix.
func (s *Store) QuarantineMedia(ctx context.Context, q Quarantine) (string, error) {
	caseID := newID()
	signals, _ := json.Marshal(q.Signals)
	if q.Signals == nil {
		signals = []byte(`{}`)
	}
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE media_assets SET status='quarantined',scan_result=$3,scanned_at=now(),attached=false,variants=NULL,upload_key=$4,expires_at=now()+interval '90 days'
 WHERE media_id=$1 AND owner_id=$2 AND status='pending'`, q.MediaID, q.Owner, q.Result, q.OriginalKey)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		suspended := q.Result == "match"
		if _, err = tx.Exec(ctx, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,signals,original_sha256,original_bytes,content_type,original_key,full_key,suspended_user)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,nullif($12,''),$13)`,
			caseID, q.MediaID, q.Owner, q.Purpose, q.Result, q.Scanner, signals, q.OriginalSHA256, q.OriginalBytes, q.ContentType, q.OriginalKey, q.FullKey, suspended); err != nil {
			return err
		}
		if !suspended {
			return nil
		}
		if _, err = tx.Exec(ctx, `INSERT INTO moderation_actions(action_id,actor,subject_id,action_type,note) VALUES($1,$2,$3,'suspend',$4)`,
			newID(), ScannerActor, q.Owner, "upload scanner match; content case "+caseID); err != nil {
			return err
		}
		return suspend(ctx, tx, q.Owner)
	})
	if err != nil {
		return "", err
	}
	return caseID, nil
}

// Sign in with Apple revocations that could not be completed at deletion time. The token is sealed by the
// caller; the store never sees it in the clear.

// QueueAppleRevocation keeps a sealed refresh token for every identity of the account, to be retried by the purge.
func (s *Store) QueueAppleRevocation(ctx context.Context, user string, sealed []byte) error {
	_, err := s.Pool.Exec(ctx, `INSERT INTO apple_revocations(issuer,subject,token_sealed) SELECT issuer,subject,$2 FROM auth_identities WHERE user_id=$1
 ON CONFLICT (issuer,subject) DO UPDATE SET token_sealed=excluded.token_sealed,created_at=now()`, user, sealed)
	return err
}

// PendingAppleRevocation returns the sealed token queued for an identity, or nil.
func (s *Store) PendingAppleRevocation(ctx context.Context, issuer, subject string) ([]byte, error) {
	var sealed []byte
	err := s.Pool.QueryRow(ctx, `SELECT token_sealed FROM apple_revocations WHERE issuer=$1 AND subject=$2`, issuer, subject).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return sealed, err
}

// DoneAppleRevocation forgets a queued token once Apple has revoked it.
func (s *Store) DoneAppleRevocation(ctx context.Context, issuer, subject string) error {
	_, err := s.Pool.Exec(ctx, `DELETE FROM apple_revocations WHERE issuer=$1 AND subject=$2`, issuer, subject)
	return err
}

// HeldObjects deletes objects under the hold prefix. media.Store satisfies it.
type HeldObjects interface {
	Delete(ctx context.Context, keys ...string) error
}

// PurgeReleasedHolds removes the held objects of released holds whose retention window (hold_until) is over, at
// most batch cases per call, and records each as purged. The database decides what is due and re-checks every
// condition (held_objects_due, mark_hold_purged: the API role has no other access to cases). Objects first,
// the record after: a failed delete leaves the case due, and the next run tries again. Keys outside the hold
// prefix are never deleted. It returns how many cases were finished.
func (s *Store) PurgeReleasedHolds(ctx context.Context, objects HeldObjects, batch int) (int64, error) {
	rows, err := s.Pool.Query(ctx, `SELECT case_id::text,original_key,coalesce(full_key,'') FROM held_objects_due($1)`, batch)
	if err != nil {
		return 0, err
	}
	type due struct{ id, original, full string }
	var work []due
	for rows.Next() {
		var d due
		if err = rows.Scan(&d.id, &d.original, &d.full); err != nil {
			rows.Close()
			return 0, err
		}
		work = append(work, d)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, err
	}
	var done int64
	for _, d := range work {
		var keys []string
		for _, k := range []string{d.original, d.full} {
			if k != "" {
				if !strings.HasPrefix(k, media.HoldPrefix) {
					return done, errors.New("held object key outside the hold prefix")
				}
				keys = append(keys, k)
			}
		}
		if err = objects.Delete(ctx, keys...); err != nil {
			return done, err
		}
		var marked bool
		if err = s.Pool.QueryRow(ctx, `SELECT mark_hold_purged($1)`, d.id).Scan(&marked); err != nil {
			return done, err
		}
		if marked {
			done++
		}
	}
	return done, nil
}
