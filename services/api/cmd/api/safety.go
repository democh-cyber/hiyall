package main

import (
	"context"
	"errors"
	"log/slog"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// wireSafety applies the trust-and-safety settings that are not part of a feature's own setup: the Nearby
// offset key, the photo processing and export slots, and the evidence store for quarantined originals
// (docs/security/16-csam-and-illegal-content.md). It returns the store whose held objects the API's own
// maintenance may delete: nil when evidence has a bucket of its own, because the API's token there cannot
// delete, and the console's purge job (admin purge-holds) does it instead.
func wireSafety(ctx context.Context, cfg config.Config, api *httpapi.API) (heldObjects media.Store, err error) {
	if cfg.NearbyOffsetKey != nil {
		store.SetNearbyOffsetKey(cfg.NearbyOffsetKey)
	} else {
		slog.Warn("NEARBY_OFFSET_KEY is not set: Nearby offsets use a random key that dies with this process (development only)")
	}
	if cfg.NearbyOffsetKeyPrevious != nil {
		slog.Info("NEARBY_OFFSET_KEY_PREVIOUS is set and ignored: offsets are recomputed under the current key, never looked up")
	}
	api.SetMediaSlots(cfg.MediaProcessSlots)
	api.SetExportConcurrency(cfg.ExportConcurrency)
	if cfg.MediaEndpoint == "" {
		return nil, nil
	}
	if !cfg.EvidenceSeparate() {
		if cfg.Env == "production" {
			slog.Warn("quarantined photos are kept in the media bucket, where this API's token can delete them (EVIDENCE_ALLOW_SHARED_BUCKET=true)")
		}
		api.SetEvidence(nil, cfg.EvidenceRetentionDays)
		return api.Media, nil
	}
	// The API's token for the evidence bucket is write-only: it never reads or deletes, and never creates the bucket.
	evidence, err := media.NewS3(ctx, media.S3Config{Endpoint: cfg.EvidenceEndpoint, AccessKey: cfg.EvidenceAccessKey, SecretKey: cfg.EvidenceSecretKey, Bucket: cfg.EvidenceBucket, Region: cfg.EvidenceRegion, Secure: cfg.EvidenceSecure, NoCreate: true})
	if err != nil {
		return nil, errors.New("evidence storage unavailable; check EVIDENCE_* configuration")
	}
	api.SetEvidence(evidence, cfg.EvidenceRetentionDays)
	slog.Info("quarantined originals go to the evidence bucket", "bucket", cfg.EvidenceBucket, "retentionDays", cfg.EvidenceRetentionDays)
	return nil, nil
}
