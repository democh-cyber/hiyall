package main

import (
	"context"
	"time"

	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/store"
)

// retentionJobs are the hourly jobs that enforce docs/legal/data-retention.md (audit D11) and the weekly
// counter reconciles (audit F21). They run behind the maintenance leader lock like every other job; each drains
// its own backlog, and the reconcile jobs do nothing until a week has passed since their last pass.
func retentionJobs(db *store.Store) []maintenance.Job {
	longJob := 20 * time.Minute
	return []maintenance.Job{
		{Name: "notification retention", Run: func(ctx context.Context) (int64, error) {
			return db.PurgeNotifications(ctx, store.NotificationRetention)
		}},
		{Name: "closed report retention", Run: func(ctx context.Context) (int64, error) { return db.PurgeClosedReports(ctx, store.ReportRetention) }},
		{Name: "deleted content blanking", Run: func(ctx context.Context) (int64, error) {
			return db.BlankDeletedContent(ctx, store.DeletedContentBlankAfter)
		}},
		{Name: "deleted content purge", Timeout: longJob, Run: func(ctx context.Context) (int64, error) {
			return db.PurgeDeletedContent(ctx, store.DeletedContentRetention)
		}},
		{Name: "message metadata retention", Timeout: longJob, Run: func(ctx context.Context) (int64, error) {
			return db.PurgeMessageMetadata(ctx, store.MessageMetadataRetention)
		}},
		{Name: "media tombstone purge", Run: func(ctx context.Context) (int64, error) {
			return db.PurgeMediaTombstones(ctx, store.MediaTombstoneRetention)
		}},
		{Name: "social counter reconcile", Timeout: longJob, Run: func(ctx context.Context) (int64, error) {
			return db.ReconcileSocialCounters(ctx, store.ReconcileEvery)
		}},
		{Name: "post counter reconcile", Timeout: longJob, Run: func(ctx context.Context) (int64, error) {
			return db.ReconcilePostCounters(ctx, store.ReconcileEvery)
		}},
		{Name: "space member count reconcile", Timeout: longJob, Run: func(ctx context.Context) (int64, error) {
			return db.ReconcileSpaceMemberCounts(ctx, store.ReconcileEvery)
		}},
	}
}
