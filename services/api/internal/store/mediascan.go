package store

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/metrics"
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
	// RetentionDays is how long the evidence is held (EVIDENCE_RETENTION_DAYS); 0 means DefaultEvidenceRetentionDays.
	RetentionDays int
}

// DefaultEvidenceRetentionDays is one year, pending counsel (audit LEGAL-2). Migration 0041 makes it the
// column default of content_cases.hold_until too; existing cases keep the hold_until they have.
const DefaultEvidenceRetentionDays = 365

// ScannerActor is the actor recorded for what the scanner did on its own.
const ScannerActor = "system:upload-scanner"

// BeginQuarantine, in one transaction: marks the pending upload quarantined (never served, never attachable,
// never cleaned up), opens the operator case as 'pending' with the evidence record and, for a match, suspends the
// uploader and ends their sessions pending review. It returns the case id. The case is written BEFORE the evidence
// objects, so an object in the evidence bucket never exists without a case that names it (round-3 audit API-6/7);
// the caller writes the objects and then calls ActivateQuarantine. A case left pending (the objects could not be
// written, or the process died) is swept by the console after an hour (SweepPendingCases). The photo is not sent
// anywhere: the objects stay in the bucket under the hold prefix.
func (s *Store) BeginQuarantine(ctx context.Context, q Quarantine) (string, error) {
	caseID := newID()
	signals, _ := json.Marshal(q.Signals)
	if q.Signals == nil {
		signals = []byte(`{}`)
	}
	days := q.RetentionDays
	if days <= 0 {
		days = DefaultEvidenceRetentionDays
	}
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE media_assets SET status='quarantined',scan_result=$3,scanned_at=now(),attached=false,variants=NULL,upload_key=$4,expires_at=now()+make_interval(days=>$5::int)
 WHERE media_id=$1 AND owner_id=$2 AND status='pending'`, q.MediaID, q.Owner, q.Result, q.OriginalKey, days)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		suspended := q.Result == "match"
		// Only the columns the API role may insert (grants.sql): the status is 'pending' by default and a trigger
		// forces it, and the release, report and legal-hold columns cannot be named (migration 0046).
		if _, err = tx.Exec(ctx, `INSERT INTO content_cases(case_id,media_id,user_id,purpose,result,scanner,signals,original_sha256,original_bytes,content_type,original_key,full_key,suspended_user,hold_until)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,nullif($12,''),$13,now()+make_interval(days=>$14::int))`,
			caseID, q.MediaID, q.Owner, q.Purpose, q.Result, q.Scanner, signals, q.OriginalSHA256, q.OriginalBytes, q.ContentType, q.OriginalKey, q.FullKey, suspended, days); err != nil {
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

// ActivateQuarantine opens a pending case once its evidence objects are stored (activate_quarantine_case; the API
// role can run it and still cannot read or change a case).
func (s *Store) ActivateQuarantine(ctx context.Context, caseID string) error {
	_, err := s.Pool.Exec(ctx, `SELECT activate_quarantine_case($1::uuid)`, caseID)
	return err
}

// QuarantineMedia is BeginQuarantine and ActivateQuarantine in one step, for a caller that has already written
// the objects (tests, tools). The upload path writes the case first and the objects second.
func (s *Store) QuarantineMedia(ctx context.Context, q Quarantine) (string, error) {
	caseID, err := s.BeginQuarantine(ctx, q)
	if err != nil {
		return "", err
	}
	return caseID, s.ActivateQuarantine(ctx, caseID)
}

// Sign in with Apple revocations that could not be completed at deletion time. The token is sealed by the
// caller; the store never sees it in the clear.

// QueueAppleRevocation keeps a sealed refresh token for every identity of the account, to be retried by the purge.
func (s *Store) QueueAppleRevocation(ctx context.Context, user string, sealed []byte) error {
	_, err := s.Pool.Exec(ctx, `INSERT INTO apple_revocations(issuer,subject,token_sealed) SELECT issuer,subject,$2 FROM auth_identities WHERE user_id=$1
 ON CONFLICT (issuer,subject) DO UPDATE SET token_sealed=excluded.token_sealed,status='queued',reason=NULL,created_at=now()`, user, sealed)
	return err
}

// PendingAppleRevocation returns the sealed token queued for an identity, or nil.
func (s *Store) PendingAppleRevocation(ctx context.Context, issuer, subject string) ([]byte, error) {
	var sealed []byte
	// A 'manual' row has no token: the purge skips Apple for it and an operator revokes by hand.
	err := s.Pool.QueryRow(ctx, `SELECT token_sealed FROM apple_revocations WHERE issuer=$1 AND subject=$2 AND status='queued'`, issuer, subject).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return sealed, err
}

// DoneAppleRevocation forgets a queued token once Apple has revoked it.
func (s *Store) DoneAppleRevocation(ctx context.Context, issuer, subject string) error {
	_, err := s.Pool.Exec(ctx, `DELETE FROM apple_revocations WHERE issuer=$1 AND subject=$2 AND status='queued'`, issuer, subject)
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
cases:
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
		// The case row is locked FOR SHARE (hold_lock_for_purge) from before the first object delete until the case is
		// marked purged, in one transaction: a report or a legal hold, which update the row, wait for it, so none can
		// land between the check and the delete (round-4 DB N8). A report opened in the reports table does not touch
		// the row, so the check is also repeated before each object.
		finished, err := s.purgeHeldCase(ctx, objects, d.id, keys)
		if err != nil {
			return done, err
		}
		if finished {
			done++
		} else {
			continue cases
		}
	}
	return done, nil
}

// purgeHeldCase deletes the objects of one case under the row lock and marks it purged; false when the hold stopped
// being releasable (nothing was deleted for the objects after that point).
func (s *Store) purgeHeldCase(ctx context.Context, objects HeldObjects, caseID string, keys []string) (bool, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	for _, k := range keys {
		var still bool
		// The first call takes the lock; the later ones (the lock is held) are the per-object re-check.
		if err = tx.QueryRow(ctx, `SELECT hold_lock_for_purge($1::uuid)`, caseID).Scan(&still); err != nil {
			return false, err
		}
		if !still {
			slog.Warn("held evidence kept: the hold is no longer releasable", "caseId", caseID)
			purgeRecheckKept.Inc()
			return false, nil
		}
		if err = objects.Delete(ctx, k); err != nil {
			return false, err
		}
	}
	var marked bool
	if err = tx.QueryRow(ctx, `SELECT mark_hold_purged($1)`, caseID).Scan(&marked); err != nil {
		return false, err
	}
	if err = tx.Commit(ctx); err != nil {
		return false, err
	}
	return marked, nil
}

var purgeRecheckKept = metrics.NewCounter("hiyall_evidence_purge_kept_total", "Held-evidence purges stopped because the hold stopped being releasable between the list and the delete.")

// RecordSignInProvider stores how the person signed in (Firebase's sign_in_provider claim, such as apple.com or
// google.com) and whether Apple is linked to the Firebase user, on the identity row. Account deletion needs it:
// Sign in with Apple must be revoked with a fresh authorization code (audit API-8). A write only when the value
// changed, so a settled identity costs one cheap read-free UPDATE that touches no row.
func (s *Store) RecordSignInProvider(ctx context.Context, issuer, subject, provider string, appleLinked bool) error {
	_, err := s.Pool.Exec(ctx, `UPDATE auth_identities SET sign_in_provider=$3,apple_linked=$4
 WHERE issuer=$1 AND subject=$2 AND (sign_in_provider IS DISTINCT FROM $3 OR apple_linked IS DISTINCT FROM $4)`, issuer, subject, provider, appleLinked)
	return err
}

// HasAppleAuthorization says whether the member holds a Sign in with Apple authorization that deleting the
// account must revoke: any of their identities signed in with apple.com or has Apple linked. Identities not
// seen since the release have neither flag yet and count as not Apple until their next sign-in.
func (s *Store) HasAppleAuthorization(ctx context.Context, user string) (bool, error) {
	var has bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM auth_identities WHERE user_id=$1 AND (sign_in_provider='apple.com' OR apple_linked))`, user).Scan(&has)
	return has, err
}

// OrphanItem is an object under hold/ that no case row names (the evidence sweep's finding).
type OrphanItem struct {
	Key          string    `json:"key"`
	MediaID      string    `json:"mediaId"`
	LastModified time.Time `json:"lastModified"`
}

// OrphanReport is the console's last orphan check, kept in the database so every console node answers alike.
type OrphanReport struct {
	CheckedAt *time.Time   `json:"checkedAt"`
	Items     []OrphanItem `json:"items"`
	Complete  bool         `json:"complete"`
}

// SaveOrphanReport replaces the stored report (evidence_orphan_report, one row).
func (s *Store) SaveOrphanReport(ctx context.Context, r OrphanReport) error {
	items, err := json.Marshal(r.Items)
	if err != nil {
		return err
	}
	if r.Items == nil {
		items = []byte(`[]`)
	}
	_, err = s.Pool.Exec(ctx, `INSERT INTO evidence_orphan_report(id,checked_at,complete,items) VALUES(true,coalesce($1,now()),$2,$3)
 ON CONFLICT (id) DO UPDATE SET checked_at=excluded.checked_at,complete=excluded.complete,items=excluded.items`, r.CheckedAt, r.Complete, items)
	return err
}

// LoadOrphanReport reads the stored report; before the first sweep it is empty and not checked.
func (s *Store) LoadOrphanReport(ctx context.Context) (OrphanReport, error) {
	r := OrphanReport{Items: []OrphanItem{}}
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT checked_at,complete,items FROM evidence_orphan_report WHERE id`).Scan(&r.CheckedAt, &r.Complete, &raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, nil
	}
	if err != nil {
		return r, err
	}
	if err = json.Unmarshal(raw, &r.Items); err != nil {
		return r, err
	}
	if r.Items == nil {
		r.Items = []OrphanItem{}
	}
	return r, nil
}

// RecordUploadLeftover remembers an object in the upload prefix that could not be removed after the photo was
// quarantined: the media row no longer names it (its upload key now points at the evidence), so without this record
// nothing would ever remove it.
func (s *Store) RecordUploadLeftover(ctx context.Context, key, mediaID string) error {
	_, err := s.Pool.Exec(ctx, `INSERT INTO quarantine_upload_leftovers(object_key,media_id) VALUES($1,$2::uuid) ON CONFLICT DO NOTHING`, key, mediaID)
	return err
}

// PurgeUploadLeftovers removes the recorded objects (a delete of an absent object succeeds) and forgets them. It
// returns how many it finished.
func (s *Store) PurgeUploadLeftovers(ctx context.Context, objects HeldObjects, batch int) (int64, error) {
	rows, err := s.Pool.Query(ctx, `SELECT object_key FROM quarantine_upload_leftovers ORDER BY recorded_at LIMIT $1`, batch)
	if err != nil {
		return 0, err
	}
	keys, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return 0, err
	}
	var done int64
	for _, k := range keys {
		if strings.HasPrefix(k, media.HoldPrefix) {
			// Never the evidence: a recorded key must be an upload key.
			if _, err = s.Pool.Exec(ctx, `DELETE FROM quarantine_upload_leftovers WHERE object_key=$1`, k); err != nil {
				return done, err
			}
			continue
		}
		if err = objects.Delete(ctx, k); err != nil {
			return done, err
		}
		if _, err = s.Pool.Exec(ctx, `DELETE FROM quarantine_upload_leftovers WHERE object_key=$1`, k); err != nil {
			return done, err
		}
		done++
	}
	return done, nil
}
