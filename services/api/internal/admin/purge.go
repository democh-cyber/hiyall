package admin

import (
	"context"
	"errors"

	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/media"
)

// Removing the objects of released evidence holds (docs/security/16-csam-and-illegal-content.md section 9).
// It is the console's job, not the API's: the public API's token for the evidence bucket can write but not
// read or delete, so nothing that serves members can destroy evidence. This job holds the only delete
// credential (ADMIN_EVIDENCE_DELETE_*), runs on a timer in `admin serve` or by hand as `admin purge-holds`, and
// removes only what the database says is due: a released hold whose retention window is over, with no legal
// hold, open report or open case behind it (held_objects_due, mark_hold_purged).

// ErrNoEvidenceDelete is returned when the delete credential is not configured.
var ErrNoEvidenceDelete = errors.New("ADMIN_EVIDENCE_DELETE_* is not set: no credential to remove held evidence")

// PurgeLockKey is the advisory lock that makes one console instance run the timer.
const PurgeLockKey int64 = 4917305

// PurgeHolds removes the objects of up to batch due holds and records each. It returns how many cases it finished.
func (s *Service) PurgeHolds(ctx context.Context, batch int) (int64, error) {
	if s.EvidenceDelete == nil {
		return 0, ErrNoEvidenceDelete
	}
	return s.Store.PurgeReleasedHolds(ctx, s.EvidenceDelete, batch)
}

// PurgeJobs is the timer's job list for the delete credential. Each hold is re-checked in the database
// immediately before every object is deleted (store.PurgeReleasedHolds), so a report opened after the list was read
// keeps its evidence.
func (s *Service) PurgeJobs() []maintenance.Job {
	return []maintenance.Job{{Name: "released hold purge", Run: func(ctx context.Context) (int64, error) { return s.PurgeHolds(ctx, 50) }}}
}

// NewEvidenceStores builds the read-only evidence client and the delete client from the configuration. Either
// may be nil: reading falls back to the media bucket, and without the delete credential nothing is purged.
func NewEvidenceStores(ctx context.Context, c Config) (reader, deleter media.Store, err error) {
	if c.EvidenceEndpoint == "" {
		return nil, nil, nil
	}
	cfg := media.S3Config{Endpoint: c.EvidenceEndpoint, AccessKey: c.EvidenceAccessKey, SecretKey: c.EvidenceSecretKey, Bucket: c.EvidenceBucket, Region: c.EvidenceRegion, Secure: c.EvidenceSecure, NoCreate: true}
	r, err := media.NewS3(ctx, cfg)
	if err != nil {
		return nil, nil, errors.New("evidence storage unavailable; check ADMIN_EVIDENCE_* configuration")
	}
	reader = r
	if c.EvidenceDeleteAccessKey != "" {
		cfg.AccessKey, cfg.SecretKey = c.EvidenceDeleteAccessKey, c.EvidenceDeleteSecretKey
		d, err := media.NewS3(ctx, cfg)
		if err != nil {
			return nil, nil, errors.New("evidence storage unavailable; check ADMIN_EVIDENCE_DELETE_* configuration")
		}
		deleter = d
	}
	return reader, deleter, nil
}
