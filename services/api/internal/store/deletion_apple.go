package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/realtime"
)

// Account deletion for a member whose Sign in with Apple authorization cannot be revoked by the server, and the
// operator's side of it (round-3 audit API-1, round-4 N-4). A member who signs in with Apple, or has Apple linked,
// must have the authorization revoked at deletion (App Store guideline 5.1.1(v)); the server needs a fresh
// authorization code from the app for that. When the app cannot get one even after re-authenticating (the member
// re-signed in with Google, the web has no code) the deletion must still go ahead: the member is never locked in.
//
// Nobody at Hiyall can revoke the authorization instead: Apple's revoke call needs the member's own token and the
// developer portal has no per-user revoke. The member does it themselves in Apple ID settings (Settings > Apple ID >
// Sign in with Apple > Hiyall > Stop using Apple ID), and the API tells them so in the deletion response
// (appleAction). The queue row is a record that they were told ('member_informed', removed after 90 days). A deletion
// that support schedules cannot tell the member in the app, so its row is 'manual': an operator tells the member and
// acknowledges it.

// ScheduleDeletionManualApple schedules the deletion and, in the same transaction, records for every identity of the
// account that holds an Apple authorization that the member was told to remove it themselves. A member without one is
// simply deleted. Asking again changes nothing (an existing row, such as a sealed token the purge retries, is kept).
func (s *Store) ScheduleDeletionManualApple(ctx context.Context, user string) (DeletionState, error) {
	state, _, err := s.ScheduleDeletionManualAppleNotify(ctx, user)
	return state, err
}

// ScheduleDeletionManualAppleNotify is ScheduleDeletionManualApple that also returns the push tokens cleared (see
// ScheduleDeletionNotify).
func (s *Store) ScheduleDeletionManualAppleNotify(ctx context.Context, user string) (DeletionState, []PushTarget, error) {
	return s.scheduleDeletion(ctx, user, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO apple_revocations(issuer,subject,status,user_id,reason)
 SELECT issuer,subject,'member_informed',$1::uuid,'the app could not obtain a Sign in with Apple authorization code; the member was told to remove Hiyall in Apple ID settings' FROM auth_identities
  WHERE user_id=$1 AND (sign_in_provider='apple.com' OR apple_linked)
 ON CONFLICT (issuer,subject) DO NOTHING`, user)
		return err
	})
}

// AdminScheduleDeletion is `admin schedule-deletion`: the support-driven deletion, as the console role (which has no
// access to the member tables) through admin_schedule_deletion. actor is the e-mail address of an active administrator
// (never a shell user such as cli:root: the function refuses anything else). It works for a suspended, banned or
// deactivated member too (an erasure request), audits the action itself, and queues a 'manual' Apple record for an
// operator to tell the member. It returns when the grace period ends.
func (s *Store) AdminScheduleDeletion(ctx context.Context, user, actor, reason string) (time.Time, error) {
	notice, _ := json.Marshal(realtime.DisconnectEvent(user))
	var due time.Time
	err := s.Pool.QueryRow(ctx, `SELECT admin_schedule_deletion($1::uuid,$2,$3,$4,$5)`, user, actor, reason, realtime.Channel, string(notice)).Scan(&due)
	return due, MapSafetyError(err)
}

// AppleRevocationCase is a manual revocation waiting for an operator.
type AppleRevocationCase struct {
	RevocationID string `json:"revocationId"`
	Issuer       string `json:"issuer"`
	Subject      string `json:"subject"`
	UserID       string `json:"userId"`
	// Status is 'manual' (an operator has to tell the member) or 'member_informed' (the app told them; a record).
	Status    string    `json:"status"`
	Reason    string    `json:"reason"`
	CreatedAt time.Time `json:"createdAt"`
}

// ManualAppleRevocations lists the Apple records, 'manual' ones first (those need an operator), oldest first. Despite
// the name it also lists 'member_informed' records, for visibility.
func (s *Store) ManualAppleRevocations(ctx context.Context, limit int) ([]AppleRevocationCase, error) {
	rows, err := s.Pool.Query(ctx, `SELECT revocation_id::text,issuer,subject,coalesce(user_id::text,''),status,coalesce(reason,''),created_at
 FROM apple_revocations WHERE status IN ('manual','member_informed') ORDER BY (status='manual') DESC,created_at,revocation_id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AppleRevocationCase, error) {
		var c AppleRevocationCase
		return c, row.Scan(&c.RevocationID, &c.Issuer, &c.Subject, &c.UserID, &c.Status, &c.Reason, &c.CreatedAt)
	})
	if out == nil && err == nil {
		out = []AppleRevocationCase{}
	}
	return out, mapped(err)
}

// AcknowledgeAppleRevocation removes an Apple record once an operator has dealt with it (told the member, for a 'manual'
// one) through apple_revocation_acknowledge, which writes the audit entry in the same transaction. The console role has
// no DELETE on the table.
func (s *Store) AcknowledgeAppleRevocation(ctx context.Context, id, operatorID, reason string) (AppleRevocationCase, error) {
	var c AppleRevocationCase
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := SetSafetyContext(ctx, tx); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT revocation_id::text,issuer,subject,coalesce(user_id::text,''),status,coalesce(reason,''),created_at FROM apple_revocations WHERE revocation_id=$1`, id).
			Scan(&c.RevocationID, &c.Issuer, &c.Subject, &c.UserID, &c.Status, &c.Reason, &c.CreatedAt); err != nil {
			return mapped(err)
		}
		_, err := tx.Exec(ctx, `SELECT apple_revocation_acknowledge($1::uuid,$2::uuid,$3)`, id, operatorID, reason)
		return MapSafetyError(err)
	})
	return c, err
}

// PruneAppleRecords removes 'member_informed' records older than days (never fewer than 30) and returns how many.
func (s *Store) PruneAppleRecords(ctx context.Context, days int) (int64, error) {
	var n int64
	err := s.Pool.QueryRow(ctx, `SELECT apple_revocations_prune($1)`, days).Scan(&n)
	return n, mapped(err)
}

// AppleRecordRetentionDays is how long a 'member_informed' record is kept.
const AppleRecordRetentionDays = 90

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
