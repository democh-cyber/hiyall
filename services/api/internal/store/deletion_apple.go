package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/realtime"
)

// Account deletion for a member whose Sign in with Apple authorization cannot be revoked by the server, and the
// operator's side of it (round-3 audit API-1). A member who signs in with Apple, or has Apple linked, must have the
// authorization revoked at deletion (App Store guideline 5.1.1(v)); the server needs a fresh authorization code
// from the app for that. When the app cannot get one even after re-authenticating (the member re-signed in with
// Google, the web has no code) the deletion must still go ahead: the member is never locked in. The authorization
// is then queued as a 'manual' apple_revocations row for an operator to revoke by hand and mark done.

// ScheduleDeletionManualApple schedules the deletion and, in the same transaction, queues a manual revocation for
// every identity of the account that holds an Apple authorization. A member without one is simply deleted. Asking
// again changes nothing (an existing row, such as a sealed token the purge retries, is kept).
func (s *Store) ScheduleDeletionManualApple(ctx context.Context, user string) (DeletionState, error) {
	return s.scheduleDeletion(ctx, user, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO apple_revocations(issuer,subject,status,user_id,reason)
 SELECT issuer,subject,'manual',$1::uuid,'the app could not obtain a Sign in with Apple authorization code' FROM auth_identities
  WHERE user_id=$1 AND (sign_in_provider='apple.com' OR apple_linked)
 ON CONFLICT (issuer,subject) DO NOTHING`, user)
		return err
	})
}

// AdminScheduleDeletion is `admin schedule-deletion`: the support-driven deletion, as the console role (which has no
// access to the member tables) through admin_schedule_deletion. It audits the action itself and queues manual Apple
// revocations like ScheduleDeletionManualApple. It returns when the grace period ends.
func (s *Store) AdminScheduleDeletion(ctx context.Context, user, actor, reason string) (time.Time, error) {
	notice, _ := json.Marshal(realtime.DisconnectEvent(user))
	var due time.Time
	err := s.Pool.QueryRow(ctx, `SELECT admin_schedule_deletion($1::uuid,$2,$3,$4,$5)`, user, actor, reason, realtime.Channel, string(notice)).Scan(&due)
	return due, MapSafetyError(err)
}

// AppleRevocationCase is a manual revocation waiting for an operator.
type AppleRevocationCase struct {
	RevocationID string    `json:"revocationId"`
	Issuer       string    `json:"issuer"`
	Subject      string    `json:"subject"`
	UserID       string    `json:"userId"`
	Reason       string    `json:"reason"`
	CreatedAt    time.Time `json:"createdAt"`
}

// ManualAppleRevocations lists the revocations an operator still has to do by hand, oldest first.
func (s *Store) ManualAppleRevocations(ctx context.Context, limit int) ([]AppleRevocationCase, error) {
	rows, err := s.Pool.Query(ctx, `SELECT revocation_id::text,issuer,subject,coalesce(user_id::text,''),coalesce(reason,''),created_at
 FROM apple_revocations WHERE status='manual' ORDER BY created_at,revocation_id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AppleRevocationCase, error) {
		var c AppleRevocationCase
		return c, row.Scan(&c.RevocationID, &c.Issuer, &c.Subject, &c.UserID, &c.Reason, &c.CreatedAt)
	})
	if out == nil && err == nil {
		out = []AppleRevocationCase{}
	}
	return out, mapped(err)
}

// MarkAppleRevoked removes a manual revocation once the operator revoked the authorization in Apple's console.
// hook runs in the same transaction, where the console writes its audit entry; the row is gone only if that
// entry was written.
func (s *Store) MarkAppleRevoked(ctx context.Context, id string, hook func(ctx context.Context, tx pgx.Tx, c AppleRevocationCase) error) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var c AppleRevocationCase
		err := tx.QueryRow(ctx, `DELETE FROM apple_revocations WHERE revocation_id=$1 AND status='manual'
 RETURNING revocation_id::text,issuer,subject,coalesce(user_id::text,''),coalesce(reason,''),created_at`, id).Scan(&c.RevocationID, &c.Issuer, &c.Subject, &c.UserID, &c.Reason, &c.CreatedAt)
		if err != nil {
			return mapped(err)
		}
		if hook != nil {
			return hook(ctx, tx, c)
		}
		return nil
	})
}

// PendingCase is a quarantine case still 'pending' after its hour: the evidence objects may never have been written.
type PendingCase struct {
	CaseID, MediaID, UserID, Result, OriginalKey, FullKey string
	CreatedAt                                             time.Time
}

// PendingCasesDue lists pending cases older than an hour (pending_cases_due).
func (s *Store) PendingCasesDue(ctx context.Context, limit int) ([]PendingCase, error) {
	rows, err := s.Pool.Query(ctx, `SELECT case_id::text,media_id::text,user_id::text,result,original_key,coalesce(full_key,''),created_at FROM pending_cases_due($1)`, limit)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (PendingCase, error) {
		var c PendingCase
		return c, row.Scan(&c.CaseID, &c.MediaID, &c.UserID, &c.Result, &c.OriginalKey, &c.FullKey, &c.CreatedAt)
	})
	return out, mapped(err)
}

// DropPendingCase removes a pending case whose objects are gone (drop_pending_case, audited in the function).
func (s *Store) DropPendingCase(ctx context.Context, caseID, actor string) (bool, error) {
	var dropped bool
	err := s.Pool.QueryRow(ctx, `SELECT drop_pending_case($1::uuid,$2)`, caseID, actor).Scan(&dropped)
	return dropped, mapped(err)
}

// ActivatePendingCase opens a pending case whose objects are all there.
func (s *Store) ActivatePendingCase(ctx context.Context, caseID string) error {
	return s.ActivateQuarantine(ctx, caseID)
}

// KnownCaseMedia says which of the media ids have a case row (any status), for the orphan evidence check.
func (s *Store) KnownCaseMedia(ctx context.Context, mediaIDs []string) (map[string]bool, error) {
	known := map[string]bool{}
	if len(mediaIDs) == 0 {
		return known, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT media_id::text FROM content_cases WHERE media_id = ANY($1::uuid[])`, mediaIDs)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	for _, id := range ids {
		known[id] = true
	}
	return known, mapped(err)
}

// QueueStats are the counts behind the gauges hiyall_pending_approvals and friends.
type QueueStats struct {
	PendingApprovals     int
	OldestPendingSeconds float64
	ManualAppleRevokes   int
	PendingCases         int
}

// SafetyQueueStats reads safety_queue_stats.
func (s *Store) SafetyQueueStats(ctx context.Context) (QueueStats, error) {
	var q QueueStats
	err := s.Pool.QueryRow(ctx, `SELECT pending_approvals,oldest_pending_seconds,manual_apple_revocations,pending_cases FROM safety_queue_stats()`).
		Scan(&q.PendingApprovals, &q.OldestPendingSeconds, &q.ManualAppleRevokes, &q.PendingCases)
	return q, mapped(err)
}
