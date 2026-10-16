package store

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/realtime"
)

// Account deletion (docs/api/22-account-deletion-and-export.md).
//
//	active --ScheduleDeletion--> pending_deletion --(30 days)--> deleting --(purge finished)--> deleted
//	                                   |
//	                                   +--CancelDeletion--> active
//
// A pending member is out of every other member's view at once (every read that wants a live account
// says status='active'), has no sessions and no live sockets, and may sign in again only to cancel.
// The purge job (PurgeDeletedAccounts) removes what the member made and what was made about them; what
// stays, and why, is the retention table in the docs. The users row itself stays as a tombstone with no
// personal data: the retained reports and held evidence reference it.

// DeletionState is the member's deletion status: DueAt is the end of the grace period, CanCancel
// whether it is still running.
type DeletionState struct {
	Pending     bool       `json:"pending"`
	ScheduledAt *time.Time `json:"scheduledAt"`
	DueAt       *time.Time `json:"dueAt"`
	CanCancel   bool       `json:"canCancel"`
}

// DeletionStatus reads the status of an active or pending account.
func (s *Store) DeletionStatus(ctx context.Context, user string) (DeletionState, error) {
	var d DeletionState
	var status string
	err := s.Pool.QueryRow(ctx, `SELECT status,deletion_scheduled_at,deletion_due_at,coalesce(deletion_due_at>now(),false) FROM users WHERE user_id=$1 AND status IN ('active','pending_deletion')`, user).
		Scan(&status, &d.ScheduledAt, &d.DueAt, &d.CanCancel)
	if err != nil {
		return DeletionState{}, mapped(err)
	}
	d.Pending = status == "pending_deletion"
	d.CanCancel = d.Pending && d.CanCancel
	return d, nil
}

// Username is the account's current username; the deletion confirmation must match it.
func (s *Store) Username(ctx context.Context, user string) (string, error) {
	var name string
	err := s.Pool.QueryRow(ctx, `SELECT p.username FROM profiles p JOIN users u USING(user_id) WHERE p.user_id=$1 AND u.status IN ('active','pending_deletion')`, user).Scan(&name)
	return name, mapped(err)
}

// ScheduleDeletion moves an active account to pending_deletion, due in domain.DeletionGrace. In the same
// transaction every session is revoked (also the sign-ins this server never saw, through the identity's
// watermark, so none of them can reopen the account), push tokens are cleared and every API node is told
// to close the account's live sockets (NOTIFY is transactional, as in suspend). Asking again while pending
// changes nothing: the first request's due date stands.
func (s *Store) ScheduleDeletion(ctx context.Context, user string) (DeletionState, error) {
	return s.scheduleDeletion(ctx, user, nil)
}

// scheduleDeletion is ScheduleDeletion with a step that runs in the same transaction after the account is
// scheduled (or was already pending), such as queueing a manual Apple revocation (deletion_apple.go).
func (s *Store) scheduleDeletion(ctx context.Context, user string, also func(context.Context, pgx.Tx) error) (DeletionState, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := scheduleDeletionTx(ctx, tx, user); err != nil {
			return err
		}
		if also != nil {
			return also(ctx, tx)
		}
		return nil
	})
	if err != nil {
		return DeletionState{}, err
	}
	return s.DeletionStatus(ctx, user)
}

func scheduleDeletionTx(ctx context.Context, tx pgx.Tx, user string) error {
	var status string
	if err := tx.QueryRow(ctx, `SELECT status FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, user).Scan(&status); err != nil {
		return mapped(err)
	}
	if status == "pending_deletion" {
		return nil
	}
	if status != "active" {
		return domain.ErrNotFound
	}
	for _, statement := range []string{
		`UPDATE users SET status='pending_deletion',deletion_scheduled_at=now(),deletion_due_at=now()+$2::interval WHERE user_id=$1`,
		`UPDATE sessions SET revoked_at=coalesce(revoked_at,now()) WHERE user_id=$1`,
		`UPDATE auth_identities SET sessions_revoked_before=now() WHERE user_id=$1`,
		`UPDATE devices SET push_provider=NULL,push_token=NULL WHERE user_id=$1`,
	} {
		args := []any{user}
		if strings.Contains(statement, "$2") {
			args = append(args, domain.DeletionGrace)
		}
		if _, err := tx.Exec(ctx, statement, args...); err != nil {
			return err
		}
	}
	notice, _ := json.Marshal(realtime.DisconnectEvent(user))
	_, err := tx.Exec(ctx, `SELECT pg_notify($1,$2)`, realtime.Channel, string(notice))
	return err
}

// CancelDeletion returns a pending account to active while the grace period runs. After DueAt the purge
// may already have started, so it answers ErrDeletionClosed; an account that is not pending is not found.
func (s *Store) CancelDeletion(ctx context.Context, user string) (DeletionState, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var status string
		var open bool
		if err := tx.QueryRow(ctx, `SELECT status,coalesce(deletion_due_at>now(),false) FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, user).Scan(&status, &open); err != nil {
			return mapped(err)
		}
		if status != "pending_deletion" {
			return domain.ErrNotFound
		}
		if !open {
			return domain.ErrDeletionClosed
		}
		if _, err := tx.Exec(ctx, `UPDATE users SET status='active',deletion_scheduled_at=NULL,deletion_due_at=NULL WHERE user_id=$1`, user); err != nil {
			return err
		}
		// The account stays: nothing is left for an operator to revoke by hand (deletion_apple.go).
		_, err := tx.Exec(ctx, `DELETE FROM apple_revocations WHERE user_id=$1 AND status='manual'`, user)
		return err
	})
	if err != nil {
		return DeletionState{}, err
	}
	return s.DeletionStatus(ctx, user)
}

// SessionAuthTime is when the person last signed in interactively on this session: the Firebase auth_time
// carried in the session id. known is false for sessions that do not have one (development sessions, other
// identity providers).
func (s *Store) SessionAuthTime(ctx context.Context, sessionID string) (at time.Time, known bool, err error) {
	var issuer, sid *string
	if err = s.Pool.QueryRow(ctx, `SELECT issuer,external_sid FROM sessions WHERE session_id=$1`, sessionID).Scan(&issuer, &sid); err != nil {
		return at, false, mapped(err)
	}
	if issuer == nil || sid == nil {
		return at, false, nil
	}
	// "fb:<subject>:<auth_time>"
	cut := strings.LastIndex(*sid, ":")
	if cut < 3 {
		return at, false, nil
	}
	seconds, ok := firebaseAuthTime(*issuer, (*sid)[3:cut], *sid)
	if !ok {
		return at, false, nil
	}
	return time.Unix(seconds, 0), true, nil
}

// IdentityDeleter removes the person's account at the identity provider (the Firebase user), so the same
// sign-in cannot create a new member by accident. DeleteIdentity must succeed when the account is already
// gone; the purge calls it again after a failure.
type IdentityDeleter interface {
	DeleteIdentity(ctx context.Context, issuer, subject string) error
}

// PurgeDeletedAccounts runs the purge for up to batch accounts that are past their grace period or
// partway through it, and returns how many it worked on. Each account is handled under its own advisory
// lock (so two API nodes never purge the same one), in steps that are safe to repeat: a crash, a storage
// outage or an identity provider error leaves the account in status 'deleting' and the next run carries on.
// The account's database rows go in one transaction; its objects are removed by the media cleanup and
// PurgeChatBlobs, which pick up what the purge marked deleted, and the account becomes 'deleted' on the
// first run that finds nothing of theirs left in object storage bookkeeping. A cancelled or active
// account is never selected: every step re-reads the status under a row lock.
func (s *Store) PurgeDeletedAccounts(ctx context.Context, deleter IdentityDeleter, batch int) (int64, error) {
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM users WHERE (status='pending_deletion' AND deletion_due_at<=now()) OR status='deleting' ORDER BY deletion_due_at,user_id LIMIT $1`, batch)
	if err != nil {
		return 0, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return 0, err
	}
	var worked int64
	var failures []error
	for _, id := range ids {
		done, err := s.purgeAccount(ctx, id, deleter)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		if done {
			worked++
		}
	}
	return worked, errors.Join(failures...)
}

// purgeAccount advances one account. done is false when another node holds it or it is not purgeable.
func (s *Store) purgeAccount(ctx context.Context, id string, deleter IdentityDeleter) (done bool, err error) {
	conn, err := s.Pool.Acquire(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Release()
	var locked bool
	if err = conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtextextended('account-purge:'||$1::text,0))`, id).Scan(&locked); err != nil || !locked {
		return false, err
	}
	defer func() {
		// Release on a fresh context: a cancelled request must not leave the lock on a pooled connection.
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(hashtextextended('account-purge:'||$1::text,0))`, id)
	}()

	started := false
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		var status string
		var due bool
		if err := tx.QueryRow(ctx, `SELECT status,coalesce(deletion_due_at<=now(),false) FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&status, &due); err != nil {
			return mapped(err)
		}
		switch {
		case status == "pending_deletion" && due:
			if _, err := tx.Exec(ctx, `UPDATE users SET status='deleting' WHERE user_id=$1`, id); err != nil {
				return err
			}
		case status != "deleting":
			return nil // cancelled, or not due yet
		}
		started = true
		return nil
	})
	if err != nil || !started {
		return false, err
	}
	// The account is 'deleting' from here on, durably: the content goes in bounded batches, each in its
	// own transaction (see purge.go), and a crash resumes at the next run.
	if err = s.purgeContent(ctx, id); err != nil {
		if errors.Is(err, errPurgeFenced) {
			return false, nil
		}
		return false, err
	}

	// The identity provider account, then the bookkeeping that proves it.
	rows, err := s.Pool.Query(ctx, `SELECT issuer,subject FROM auth_identities WHERE user_id=$1 AND provider_deleted_at IS NULL`, id)
	if err != nil {
		return false, err
	}
	type identity struct{ issuer, subject string }
	identities, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (identity, error) {
		var i identity
		return i, row.Scan(&i.issuer, &i.subject)
	})
	if err != nil {
		return false, err
	}
	for _, i := range identities {
		if deleter != nil {
			if err = deleter.DeleteIdentity(ctx, i.issuer, i.subject); err != nil {
				return false, errors.New("identity provider account not deleted; the purge retries it on the next run")
			}
		}
		if _, err = s.Pool.Exec(ctx, `UPDATE auth_identities SET provider_deleted_at=now() WHERE issuer=$1 AND subject=$2 AND user_id=$3`, i.issuer, i.subject, id); err != nil {
			return false, err
		}
	}

	// Finished once no file or file record of theirs is left to remove. The content statements run once more
	// first (cheap: nothing is left but what the cleanups released since).
	if err = s.purgeContent(ctx, id); err != nil {
		if errors.Is(err, errPurgeFenced) {
			return false, nil
		}
		return false, err
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&status); err != nil || status != "deleting" {
			return mapped(err)
		}
		var drained bool
		if err := tx.QueryRow(ctx, `SELECT NOT EXISTS(SELECT 1 FROM media_assets WHERE owner_id=$1 AND status<>'quarantined')
 AND NOT EXISTS(SELECT 1 FROM chat_blobs b WHERE b.held_report_id IS NULL AND (b.uploader_id=$1 OR b.conversation_id IN (`+memberConversations+`)))
 AND NOT EXISTS(SELECT 1 FROM auth_identities WHERE user_id=$1 AND provider_deleted_at IS NULL)`, id).Scan(&drained); err != nil || !drained {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE users SET status='deleted' WHERE user_id=$1`, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO deleted_users(user_id) VALUES($1) ON CONFLICT DO NOTHING`, id)
		return err
	})
	return err == nil, err
}

// PurgeDeletedIdentities removes the identity rows of accounts purged more than retain ago (24 hours): until
// then a token minted before the purge resolves to the deleted account and is refused. At most batch per call.
func (s *Store) PurgeDeletedIdentities(ctx context.Context, retain time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM auth_identities WHERE ctid IN (SELECT a.ctid FROM auth_identities a JOIN deleted_users d ON d.user_id=a.user_id
 WHERE a.provider_deleted_at IS NOT NULL AND d.deleted_at<now()-$1::interval LIMIT $2)`, retain, batch)
	return tag.RowsAffected(), err
}

// deleteEdges is one batch of the purge's delete of a member's follows or friendships. Each deleted row fires the
// counter trigger, which reads the other member's status and bumps both members' counter rows. Two things have to
// hold for those counters to stay right, and neither does by itself:
//
//  1. The other members' user rows are locked first (FOR NO KEY UPDATE, in id order, the lock a status change takes).
//     Otherwise a neighbour restored from a suspension while this batch runs counts the edge as present (its trigger
//     scanned before this batch committed) while this batch's trigger counts it against a neighbour it still sees
//     suspended: the member being deleted keeps a follower that no row backs. With the lock one of the two runs
//     entirely first, and the second sees the first's result.
//  2. Then every counter row the batch touches is locked once, in id order, so a thousand rows do not take them
//     pair by pair in row order and deadlock with a transaction that takes the same rows the other way round.
//
// The user rows come before the counter rows everywhere (a status change holds its user row while its trigger takes
// counter rows). The order is guaranteed by data dependency and not by the order the executor happens to start
// the CTEs: "locked" reads "people" (its condition needs people's row count), and the DELETE reads "locked" (its
// condition needs locked's row count; true for any count, so an empty "locked" still lets the delete run). A
// data-modifying CTE runs to completion whether or not the statement reads it, and a CTE a node depends on is run
// before that node, so people, then locked, then the delete (whose triggers fire when the statement ends).
func deleteEdges(table, a, b string) string {
	return `WITH picked AS MATERIALIZED (SELECT ctid AS tid,` + a + ` AS a,` + b + ` AS b FROM ` + table + ` WHERE ` + a + `=$1 OR ` + b + `=$1 LIMIT $2),
 people AS MATERIALIZED (SELECT u.user_id FROM users u WHERE u.user_id<>$1 AND u.user_id IN (SELECT a FROM picked UNION SELECT b FROM picked) ORDER BY u.user_id FOR NO KEY UPDATE),
 locked AS MATERIALIZED (SELECT c.user_id FROM social_counters c WHERE c.user_id IN (SELECT a FROM picked UNION SELECT b FROM picked) AND (SELECT count(*) FROM people)>=0 ORDER BY c.user_id FOR UPDATE),
 del AS (DELETE FROM ` + table + ` WHERE ctid IN (SELECT tid FROM picked) AND (SELECT count(*) FROM locked)>=0 RETURNING 1)
 SELECT (SELECT count(*) FROM locked)*0+(SELECT count(*) FROM del)`
}

// memberConversations selects the conversations account $1 is in.
const memberConversations = `SELECT conversation_id FROM conversations WHERE $1::uuid IN (user_low_id,user_high_id)`

// retainedReport is true for report row r when the purge must keep it whole: it is still open, or it holds
// encrypted evidence (chat_blobs.held_report_id), which stays for as long as the hold does.
const retainedReport = `(r.status='open' OR EXISTS(SELECT 1 FROM chat_blobs hb WHERE hb.held_report_id=r.report_id))`

// purgeContent deletes what an account in status 'deleting' made and what exists about them, in bounded
// batches (see purge.go): each statement is cut to at most purgeBatch rows per transaction and repeated until
// it runs dry, and every transaction first checks the account is still 'deleting'. Every statement is safe to
// run again, so the purge repeats it until the file records have drained. Order follows the foreign keys. What
// it leaves, all without personal data once the rest is gone (see the retention table in the docs): the users
// row, reports and their evidence while retained, the chat rows those hold, and the media and attachment rows
// still waiting for their objects to be removed.
func (s *Store) purgeContent(ctx context.Context, id string) error {
	run := func(statements ...string) error {
		for _, statement := range statements {
			if err := s.purgeStatement(ctx, id, statement, false); err != nil {
				return err
			}
		}
		return nil
	}
	// Sign-in state. The identity row stays for now (see PurgeDeletedIdentities).
	if err := run(
		`DELETE FROM sessions WHERE user_id=$1`,
		`DELETE FROM key_claims WHERE claimer_id=$1 OR device_id IN (SELECT device_id FROM devices WHERE user_id=$1)`,
		`DELETE FROM notification_prefs WHERE user_id=$1`,
		`UPDATE devices SET push_provider=NULL,push_token=NULL WHERE user_id=$1 AND push_token IS NOT NULL`,
	); err != nil {
		return err
	}

	// Pulse. Reactions and comments on other people's posts leave the counters with them: the counter
	// adjustment and the delete are one statement, so a repeated run never subtracts twice.
	if err := s.purgeStatement(ctx, id, `WITH del AS (DELETE FROM post_reactions WHERE ctid IN (SELECT ctid FROM post_reactions WHERE user_id=$1 LIMIT $2) RETURNING post_id),
 adj AS (INSERT INTO post_counters(post_id,slot,reactions,comments) SELECT d.post_id,0,-count(*),0 FROM del d JOIN posts p ON p.post_id=d.post_id WHERE p.author_id<>$1 GROUP BY d.post_id
  ON CONFLICT (post_id,slot) DO UPDATE SET reactions=post_counters.reactions+excluded.reactions RETURNING 1)
 SELECT count(*) FROM del`, false); err != nil {
		return err
	}
	// Their comments go, leaf first (until none is left); one that others replied to stays as an empty,
	// deleted placeholder so the thread keeps its shape.
	if err := s.purgeStatement(ctx, id, `WITH del AS (DELETE FROM comments c WHERE c.ctid IN (SELECT c2.ctid FROM comments c2 WHERE c2.author_id=$1 AND NOT EXISTS(SELECT 1 FROM comments k WHERE k.parent_id=c2.comment_id) LIMIT $2)
  RETURNING c.post_id,c.hidden,c.deleted_at),
 adj AS (INSERT INTO post_counters(post_id,slot,reactions,comments) SELECT d.post_id,0,0,-count(*) FROM del d JOIN posts p ON p.post_id=d.post_id WHERE p.author_id<>$1 AND NOT d.hidden AND d.deleted_at IS NULL GROUP BY d.post_id
  ON CONFLICT (post_id,slot) DO UPDATE SET comments=post_counters.comments+excluded.comments RETURNING 1)
 SELECT count(*) FROM del`, true); err != nil {
		return err
	}
	if err := s.purgeStatement(ctx, id, `WITH o AS (SELECT comment_id,deleted_at AS was FROM comments WHERE author_id=$1 AND (body<>'' OR deleted_at IS NULL) LIMIT $2),
 upd AS (UPDATE comments c SET body='',deleted_at=coalesce(c.deleted_at,now()) FROM o WHERE c.comment_id=o.comment_id RETURNING c.post_id,c.hidden,o.was),
 adj AS (INSERT INTO post_counters(post_id,slot,reactions,comments) SELECT u.post_id,0,0,-count(*) FROM upd u JOIN posts p ON p.post_id=u.post_id WHERE p.author_id<>$1 AND NOT u.hidden AND u.was IS NULL GROUP BY u.post_id
  ON CONFLICT (post_id,slot) DO UPDATE SET comments=post_counters.comments+excluded.comments RETURNING 1)
 SELECT count(*) FROM upd`, false); err != nil {
		return err
	}
	if err := run(
		// Threads under their own posts are flattened first: the parent foreign key would otherwise reject a
		// batch that deletes a parent before its replies.
		`UPDATE comments SET parent_id=NULL WHERE post_id IN (SELECT post_id FROM posts WHERE author_id=$1) AND parent_id IS NOT NULL`,
		`DELETE FROM comments WHERE post_id IN (SELECT post_id FROM posts WHERE author_id=$1)`,
		`DELETE FROM post_reactions WHERE post_id IN (SELECT post_id FROM posts WHERE author_id=$1)`,
		`DELETE FROM saved_posts WHERE post_id IN (SELECT post_id FROM posts WHERE author_id=$1) OR user_id=$1`,
		`DELETE FROM post_counters WHERE post_id IN (SELECT post_id FROM posts WHERE author_id=$1)`,
		`DELETE FROM post_media WHERE post_id IN (SELECT post_id FROM posts WHERE author_id=$1)`,
		`DELETE FROM posts WHERE author_id=$1`,
		`DELETE FROM story_views WHERE viewer_id=$1`,
		`DELETE FROM story_views WHERE story_id IN (SELECT story_id FROM stories WHERE author_id=$1)`, // so deleting a popular story is not one huge cascade
		`DELETE FROM stories WHERE author_id=$1`,
		// Photos: whatever is not deleted yet is released for the media cleanup (MediaGarbage), which removes
		// the objects and clears the keys; the row itself goes on the first pass after that.
		`UPDATE media_assets SET attached=false,expires_at=now()-interval '1 second' WHERE owner_id=$1 AND status NOT IN ('deleted','quarantined') AND (attached OR expires_at>=now())`, // quarantined photos stay under their evidence hold
		`DELETE FROM media_assets WHERE owner_id=$1 AND status='deleted' AND variants IS NULL`,
	); err != nil {
		return err
	}

	// Relationships and activity, in both directions. Deleting a follow or friendship updates the other
	// member's counters through the triggers of migration 0033; the member's own counter row goes last.
	if err := run(
		`DELETE FROM notifications WHERE recipient_id=$1 OR actor_id=$1`,
		deleteEdges("follows", "follower_id", "followee_id"),
		deleteEdges("friendships", "user_low_id", "user_high_id"),
		`DELETE FROM social_counters WHERE user_id=$1`,
		`DELETE FROM blocks WHERE blocker_id=$1 OR blocked_id=$1`,
		`DELETE FROM user_controls WHERE actor_id=$1 OR target_id=$1`,
		`DELETE FROM profile_visits WHERE profile_id=$1 OR visitor_id=$1`,
		`DELETE FROM profile_visit_counts WHERE profile_id=$1`,
		`DELETE FROM user_locations WHERE user_id=$1`,
		`DELETE FROM nearby_prefs WHERE user_id=$1`,
		`DELETE FROM member_daily_counts WHERE user_id=$1`,
	); err != nil {
		return err
	}

	if err := s.purgeSpaces(ctx, id); err != nil {
		return err
	}

	// Reports. Open reports and reports that hold evidence stay whole; a resolved report that led to a
	// moderation action against someone else stays without the reporter's text; the rest goes.
	if err := run(
		`DELETE FROM moderation_actions ma WHERE ma.subject_id=$1 AND NOT EXISTS(SELECT 1 FROM reports r WHERE r.report_id=ma.report_id AND `+retainedReport+`)`,
		`DELETE FROM reports r WHERE (r.reporter_id=$1 OR r.subject_id=$1) AND NOT `+retainedReport+`
 AND NOT EXISTS(SELECT 1 FROM moderation_actions ma WHERE ma.report_id=r.report_id AND ma.subject_id<>$1)`,
		`UPDATE reports r SET description=NULL,evidence=NULL,disclosure_consent=false WHERE r.reporter_id=$1 AND NOT `+retainedReport+` AND (description IS NOT NULL OR evidence IS NOT NULL)`,
	); err != nil {
		return err
	}

	// Chat. The server holds no readable content: this is the ciphertext still in transit, the attachments
	// (their objects go through PurgeChatBlobs), message metadata and conversation membership. A held
	// attachment keeps its message and conversation rows, nothing else.
	if err := s.purgeTx(ctx, id, func(tx pgx.Tx) error {
		_, err := DeleteUserChatBlobs(ctx, tx, id)
		return err
	}); err != nil {
		return err
	}
	if err := run(
		// Two statements and not one with OR: each is answered by an index (the primary key, and
		// message_envelopes_recipient from migration 0039); the OR made it a scan of the whole table.
		`DELETE FROM message_envelopes WHERE message_id IN (SELECT message_id FROM messages WHERE conversation_id IN (`+memberConversations+`))`,
		`DELETE FROM message_envelopes WHERE recipient_device_id IN (SELECT device_id FROM devices WHERE user_id=$1)`,
		// The other member's attachments in these conversations go too; their rows stay until the objects
		// are gone and the two days they count towards that member's daily quota have passed.
		`UPDATE chat_blobs SET state='deleted',deleted_at=now() WHERE state<>'deleted' AND held_report_id IS NULL AND conversation_id IN (`+memberConversations+`)`,
		`DELETE FROM chat_blobs WHERE held_report_id IS NULL AND state='deleted' AND object_key IS NULL
 AND (uploader_id=$1 OR (conversation_id IN (`+memberConversations+`) AND created_at<now()-interval '2 days'))`,
		// A message a report names (as its target or in its evidence) keeps its metadata row, like one with a held attachment.
		// The ids named in report evidence are read once per statement (reportedMessageIDs); a message a report
		// targets is found through reports_target.
		`WITH `+reportedMessageIDs+`,
 del AS (DELETE FROM messages m WHERE m.ctid IN (SELECT m2.ctid FROM messages m2 WHERE m2.conversation_id IN (`+memberConversations+`)
  AND NOT EXISTS(SELECT 1 FROM chat_blobs b WHERE b.message_id=m2.message_id)
  AND NOT EXISTS(SELECT 1 FROM reports er WHERE er.target_type='message' AND er.target_id=m2.message_id)
  AND NOT EXISTS(SELECT 1 FROM evidence WHERE evidence.id=m2.message_id::text) LIMIT $2) RETURNING 1)
 SELECT count(*) FROM del`,
		`DELETE FROM conversation_members WHERE user_id=$1 OR peer_id=$1`,
		`DELETE FROM conversations c WHERE $1::uuid IN (c.user_low_id,c.user_high_id)
 AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.conversation_id=c.conversation_id) AND NOT EXISTS(SELECT 1 FROM chat_blobs b WHERE b.conversation_id=c.conversation_id)`,
		// Key material. A device that signed a retained message keeps only its public keys.
		`DELETE FROM one_time_keys WHERE device_id IN (SELECT device_id FROM devices WHERE user_id=$1)`,
		`DELETE FROM fallback_keys WHERE device_id IN (SELECT device_id FROM devices WHERE user_id=$1)`,
		`DELETE FROM devices d WHERE d.user_id=$1 AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.sender_device_id=d.device_id)`,
		`UPDATE devices SET display_name='',revoked_at=coalesce(revoked_at,now()) WHERE user_id=$1 AND (display_name<>'' OR revoked_at IS NULL)`,
	); err != nil {
		return err
	}

	// The profile, last: nothing above reads it.
	return run(
		`DELETE FROM privacy_settings WHERE user_id=$1`,
		`DELETE FROM profiles WHERE user_id=$1`,
		`DELETE FROM onboarding WHERE user_id=$1`,
		`DELETE FROM member_ages WHERE user_id=$1`,
		`DELETE FROM discovery_eligibility WHERE user_id=$1`,
		`DELETE FROM idempotency_keys WHERE user_id=$1`,
	)
}

// purgeSpaces removes the member from every space. A space they own passes to its longest-standing active
// member (admins and moderators first) so a community does not vanish with its founder; one with nobody
// else in it is deleted with its entries, and its child spaces become top-level. Each space is handled in its
// own transactions, and a space's entries and members go in batches.
func (s *Store) purgeSpaces(ctx context.Context, id string) error {
	rows, err := s.Pool.Query(ctx, `SELECT space_id::text FROM spaces WHERE owner_id=$1`, id)
	if err != nil {
		return err
	}
	owned, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, space := range owned {
		handed := false
		err := s.purgeTx(ctx, id, func(tx pgx.Tx) error {
			var successor string
			err := tx.QueryRow(ctx, `SELECT m.user_id::text FROM space_members m JOIN users u ON u.user_id=m.user_id AND u.status='active'
 WHERE m.space_id=$1 AND m.user_id<>$2 AND m.state='active' ORDER BY (m.role='admin') DESC,(m.role='moderator') DESC,m.created_at,m.user_id LIMIT 1`, space, id).Scan(&successor)
			if errors.Is(err, pgx.ErrNoRows) {
				return nil
			}
			if err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `UPDATE space_members SET role='owner' WHERE space_id=$1 AND user_id=$2`, space, successor); err != nil {
				return err
			}
			handed = true
			_, err = tx.Exec(ctx, `UPDATE spaces SET owner_id=$2 WHERE space_id=$1`, space, successor)
			return err
		})
		if err != nil {
			return err
		}
		if handed {
			continue
		}
		for _, statement := range []string{
			`DELETE FROM notifications WHERE target_id=$1`,
			`DELETE FROM space_entries WHERE space_id=$1`,
			`DELETE FROM space_members WHERE space_id=$1`,
			`UPDATE spaces SET parent_id=NULL WHERE parent_id=$1`,
			`DELETE FROM spaces WHERE space_id=$1`,
		} {
			if err = s.purgeStatementArgs(ctx, id, statement, false, space); err != nil {
				return err
			}
		}
	}
	if err = s.purgeStatement(ctx, id, `DELETE FROM space_entries WHERE author_id=$1`, false); err != nil {
		return err
	}
	// Leaving every space lowers its member count in the same statement that removes the membership.
	return s.purgeStatement(ctx, id, `WITH del AS (DELETE FROM space_members WHERE ctid IN (SELECT ctid FROM space_members WHERE user_id=$1 LIMIT $2) RETURNING space_id,state),
 upd AS (UPDATE spaces s SET member_count=greatest(s.member_count-d.n,1) FROM (SELECT space_id,count(*)::int AS n FROM del WHERE state='active' GROUP BY space_id) d WHERE s.space_id=d.space_id RETURNING 1)
 SELECT count(*) FROM del`, false)
}

// ClaimExport records that the member is downloading their data now, if the last export was more than
// domain.ExportInterval ago, and returns the previous time so a failed export can hand the claim back
// (ReleaseExport). Otherwise it answers 429 RATE_LIMITED with the wait.
func (s *Store) ClaimExport(ctx context.Context, user string) (previous *time.Time, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		var wait float64
		var last *time.Time
		if err := tx.QueryRow(ctx, `SELECT last_export_at,coalesce(extract(epoch FROM last_export_at+$2::interval-now()),0) FROM users WHERE user_id=$1 AND status='active' FOR NO KEY UPDATE`, user, domain.ExportInterval).Scan(&last, &wait); err != nil {
			return mapped(err)
		}
		if wait > 0 {
			return domain.RetryAfter(domain.ErrExportLimited, time.Duration(wait*float64(time.Second)))
		}
		previous = last
		_, err := tx.Exec(ctx, `UPDATE users SET last_export_at=now() WHERE user_id=$1`, user)
		return err
	})
	return previous, err
}

// ReleaseExport gives back the claim of an export that did not finish.
func (s *Store) ReleaseExport(ctx context.Context, user string, previous *time.Time) {
	if _, err := s.Pool.Exec(context.WithoutCancel(ctx), `UPDATE users SET last_export_at=$2 WHERE user_id=$1`, user, previous); err != nil {
		slog.Warn("export claim not released", "reason", strconv.Quote(logscrub.Err(err)))
	}
}
