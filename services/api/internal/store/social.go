package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
	"kairova/services/api/internal/domain"
)

// querier is satisfied by both the pool and a transaction.
type querier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

const blockedBetween = `EXISTS(SELECT 1 FROM blocks WHERE (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1))`

// lockPair locks both accounts in id order so reciprocal actions cannot deadlock.
// Inactive accounts and blocked pairs are indistinguishable from missing ones.
func lockPair(ctx context.Context, tx pgx.Tx, a, b string) error {
	rows, err := tx.Query(ctx, `SELECT user_id FROM users WHERE user_id IN ($1,$2) AND status='active' ORDER BY user_id FOR UPDATE`, a, b)
	if err != nil {
		return err
	}
	count := 0
	for rows.Next() {
		count++
	}
	rows.Close()
	if rows.Err() != nil {
		return rows.Err()
	}
	if count != 2 {
		return domain.ErrNotFound
	}
	var blocked bool
	if err = tx.QueryRow(ctx, `SELECT `+blockedBetween, a, b).Scan(&blocked); err != nil {
		return err
	}
	if blocked {
		return domain.ErrNotFound
	}
	return nil
}

func normalizePrivacy(data []byte) (domain.Privacy, error) {
	var p domain.Privacy
	if err := json.Unmarshal(data, &p); err != nil {
		return p, err
	}
	if p.FieldAudiences == nil {
		p.FieldAudiences = map[string]string{}
	}
	for _, field := range domain.Fields {
		if p.FieldAudiences[field] == "" {
			p.FieldAudiences[field] = "nobody"
		}
	}
	return p, nil
}

func privacyOf(ctx context.Context, q querier, id string) (domain.Privacy, error) {
	var data []byte
	if err := q.QueryRow(ctx, `SELECT data FROM privacy_settings WHERE user_id=$1`, id).Scan(&data); err != nil {
		return domain.Privacy{}, mapped(err)
	}
	return normalizePrivacy(data)
}

// relationship describes viewer→target state; capabilities need the target's policy.
func relationship(ctx context.Context, q querier, viewer, target string, policy domain.Privacy) (domain.Relationship, error) {
	var rel domain.Relationship
	var status, requester, requestID *string
	err := q.QueryRow(ctx, `SELECT coalesce(fo.state,'none'),
  EXISTS(SELECT 1 FROM follows WHERE follower_id=$2 AND followee_id=$1 AND state='active'),
  f.status, f.requested_by::text, f.friendship_id::text,
  EXISTS(SELECT 1 FROM user_controls WHERE actor_id=$1 AND target_id=$2 AND control='mute' AND (until IS NULL OR until>now())),
  EXISTS(SELECT 1 FROM user_controls WHERE actor_id=$1 AND target_id=$2 AND control='restrict')
 FROM (SELECT 1) x
 LEFT JOIN follows fo ON fo.follower_id=$1 AND fo.followee_id=$2 AND fo.state<>'removed'
 LEFT JOIN friendships f ON f.user_low_id=least($1::uuid,$2::uuid) AND f.user_high_id=greatest($1::uuid,$2::uuid)`, viewer, target).Scan(&rel.Following, &rel.FollowedBy, &status, &requester, &requestID, &rel.Muted, &rel.Restricted)
	if err != nil {
		return rel, err
	}
	rel.Friendship = "none"
	if status != nil {
		switch {
		case *status == "accepted":
			rel.Friendship = "accepted"
		case *status == "pending" && *requester == viewer:
			rel.Friendship, rel.FriendRequestID = "pending_outgoing", requestID
		case *status == "pending":
			rel.Friendship, rel.FriendRequestID = "pending_incoming", requestID
		}
	}
	rel.CanFollow = rel.Following == "none" && policy.FollowPolicy != "nobody"
	if rel.Friendship == "none" {
		rel.CanFriendRequest, err = canRequest(ctx, q, viewer, target, policy, rel)
	}
	return rel, err
}

// canRequest applies the target's requestsFrom setting. "friends" means friends of
// friends, since existing friends cannot send another request.
func canRequest(ctx context.Context, q querier, actor, target string, policy domain.Privacy, rel domain.Relationship) (bool, error) {
	switch policy.RequestsFrom {
	case "everyone":
		return true, nil
	case "followers":
		return rel.Following == "active", nil
	case "friends":
		var mutual bool
		err := q.QueryRow(ctx, `SELECT EXISTS(
 SELECT 1 FROM friendships a JOIN friendships b
  ON (CASE WHEN a.user_low_id=$1 THEN a.user_high_id ELSE a.user_low_id END)=(CASE WHEN b.user_low_id=$2 THEN b.user_high_id ELSE b.user_low_id END)
 JOIN users m ON m.user_id=(CASE WHEN a.user_low_id=$1 THEN a.user_high_id ELSE a.user_low_id END) AND m.status='active'
 WHERE a.status='accepted' AND b.status='accepted' AND $1 IN (a.user_low_id,a.user_high_id) AND $2 IN (b.user_low_id,b.user_high_id))`, actor, target).Scan(&mutual)
		return mutual, err
	}
	return false, nil
}

// notify records activity for recipient. Activity from someone the recipient
// muted or restricted is still listed (requests must stay answerable) but
// arrives already read, so it never raises the badge.
func notify(ctx context.Context, tx pgx.Tx, recipient, actor, event, target string) error {
	_, err := tx.Exec(ctx, `INSERT INTO notifications(notification_id,recipient_id,actor_id,event,target_id,read_at)
 VALUES($1,$2,$3,$4,$5,CASE WHEN `+quietFrom("$2::uuid", "$3::uuid")+` THEN now() END)
 ON CONFLICT (recipient_id,actor_id,event) DO UPDATE SET target_id=excluded.target_id,created_at=now(),read_at=excluded.read_at`, newID(), recipient, actor, event, target)
	return err
}

func unnotify(ctx context.Context, tx pgx.Tx, recipient, actor, event string) error {
	_, err := tx.Exec(ctx, `DELETE FROM notifications WHERE recipient_id=$1 AND actor_id=$2 AND event=$3`, recipient, actor, event)
	return err
}

func (s *Store) inTx(ctx context.Context, work func(pgx.Tx) error) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = work(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func noSelf(actor, target string) error {
	if actor == target {
		return &domain.ValidationError{Field: "userId", Message: "choose another account"}
	}
	return nil
}

// Follow returns the resulting state: active, or pending when the target approves followers.
func (s *Store) Follow(ctx context.Context, actor, target string) (string, error) {
	if err := noSelf(actor, target); err != nil {
		return "", err
	}
	state := ""
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockPair(ctx, tx, actor, target); err != nil {
			return err
		}
		policy, err := privacyOf(ctx, tx, target)
		if err != nil {
			return err
		}
		rel, err := relationship(ctx, tx, actor, target, policy)
		if err != nil {
			return err
		}
		if rel.Following != "none" {
			state = rel.Following
			return nil
		}
		state = "active"
		switch policy.FollowPolicy {
		case "nobody":
			return domain.ErrFollowNotAllowed
		case "approval":
			if !rel.Friends() {
				state = "pending"
			}
		}
		if _, err = tx.Exec(ctx, `INSERT INTO follows(follower_id,followee_id,state) VALUES($1,$2,$3)
 ON CONFLICT (follower_id,followee_id) DO UPDATE SET state=excluded.state,created_at=now(),removed_at=NULL`, actor, target, state); err != nil {
			return err
		}
		event := "follow.started"
		if state == "pending" {
			event = "follow.requested"
		}
		if err = notify(ctx, tx, target, actor, event, actor); err != nil {
			return err
		}
		return appendEvent(ctx, tx, actor, "follow.changed", 0)
	})
	return state, err
}

// Unfollow also withdraws a pending request. It is idempotent.
func (s *Store) Unfollow(ctx context.Context, actor, target string) error {
	if err := noSelf(actor, target); err != nil {
		return err
	}
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE follows SET state='removed',removed_at=now() WHERE follower_id=$1 AND followee_id=$2 AND state<>'removed'`, actor, target)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		if err = unnotify(ctx, tx, target, actor, "follow.requested"); err != nil {
			return err
		}
		return appendEvent(ctx, tx, actor, "follow.changed", 0)
	})
}

// RespondFollowRequest approves or declines a pending follower of owner.
func (s *Store) RespondFollowRequest(ctx context.Context, owner, follower string, accept bool) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		if accept {
			if err := lockPair(ctx, tx, owner, follower); err != nil {
				return err
			}
		}
		next := "removed"
		if accept {
			next = "active"
		}
		tag, err := tx.Exec(ctx, `UPDATE follows SET state=$3,created_at=CASE WHEN $3='active' THEN now() ELSE created_at END,removed_at=CASE WHEN $3='removed' THEN now() END WHERE follower_id=$2 AND followee_id=$1 AND state='pending'`, owner, follower, next)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		if err = unnotify(ctx, tx, owner, follower, "follow.requested"); err != nil {
			return err
		}
		if accept {
			if err = notify(ctx, tx, follower, owner, "follow.accepted", owner); err != nil {
				return err
			}
		}
		return appendEvent(ctx, tx, owner, "follow.changed", 0)
	})
}

// RemoveFollower lets an owner drop an active follower without blocking them.
func (s *Store) RemoveFollower(ctx context.Context, owner, follower string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE follows SET state='removed',removed_at=now() WHERE follower_id=$2 AND followee_id=$1 AND state='active'`, owner, follower)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return appendEvent(ctx, tx, owner, "follow.changed", 0)
	})
}

const friendRequestSelect = `SELECT f.friendship_id::text,f.status,f.created_at,
 s.user_id::text,s.username,coalesce(s.data->>'displayName',''),
 r.user_id::text,r.username,coalesce(r.data->>'displayName','')
 FROM friendships f
 JOIN profiles s ON s.user_id=f.requested_by
 JOIN profiles r ON r.user_id=CASE WHEN f.requested_by=f.user_low_id THEN f.user_high_id ELSE f.user_low_id END`

func scanFriendRequest(row pgx.Row) (domain.FriendRequest, error) {
	var f domain.FriendRequest
	err := row.Scan(&f.RequestID, &f.Status, &f.CreatedAt, &f.Sender.UserID, &f.Sender.Username, &f.Sender.DisplayName, &f.Recipient.UserID, &f.Recipient.Username, &f.Recipient.DisplayName)
	return f, mapped(err)
}

func acceptFriend(ctx context.Context, tx pgx.Tx, id, recipient, requester string) error {
	if _, err := tx.Exec(ctx, `UPDATE friendships SET status='accepted',responded_at=now(),updated_at=now() WHERE friendship_id=$1 AND status='pending'`, id); err != nil {
		return err
	}
	if err := unnotify(ctx, tx, recipient, requester, "friend.requested"); err != nil {
		return err
	}
	if err := notify(ctx, tx, requester, recipient, "friend.accepted", recipient); err != nil {
		return err
	}
	return appendEvent(ctx, tx, recipient, "friendship.changed", 0)
}

// SendFriendRequest is idempotent, and accepts instead when the target already asked.
func (s *Store) SendFriendRequest(ctx context.Context, actor, target string) (domain.FriendRequest, error) {
	if err := noSelf(actor, target); err != nil {
		return domain.FriendRequest{}, err
	}
	var id string
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockPair(ctx, tx, actor, target); err != nil {
			return err
		}
		policy, err := privacyOf(ctx, tx, target)
		if err != nil {
			return err
		}
		rel, err := relationship(ctx, tx, actor, target, policy)
		if err != nil {
			return err
		}
		switch rel.Friendship {
		case "pending_incoming":
			id = *rel.FriendRequestID
			return acceptFriend(ctx, tx, id, actor, target)
		case "pending_outgoing":
			id = *rel.FriendRequestID
			return nil
		case "accepted":
			return tx.QueryRow(ctx, `SELECT friendship_id::text FROM friendships WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`, actor, target).Scan(&id)
		}
		var cooling bool
		err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM friendships WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid) AND status='declined' AND requested_by=$1 AND responded_at>now()-interval '7 days')`, actor, target).Scan(&cooling)
		if err != nil {
			return err
		}
		if cooling {
			return domain.ErrRequestCooldown
		}
		if !rel.CanFriendRequest {
			return domain.ErrRequestNotAllowed
		}
		id = newID()
		if _, err = tx.Exec(ctx, `INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES($1,least($2::uuid,$3::uuid),greatest($2::uuid,$3::uuid),$2,'pending')
 ON CONFLICT (user_low_id,user_high_id) DO UPDATE SET friendship_id=excluded.friendship_id,requested_by=excluded.requested_by,status='pending',created_at=now(),responded_at=NULL,updated_at=now()`, id, actor, target); err != nil {
			return err
		}
		if err = notify(ctx, tx, target, actor, "friend.requested", id); err != nil {
			return err
		}
		return appendEvent(ctx, tx, actor, "friendship.changed", 0)
	})
	if err != nil {
		return domain.FriendRequest{}, err
	}
	return scanFriendRequest(s.Pool.QueryRow(ctx, friendRequestSelect+` WHERE f.friendship_id=$1`, id))
}

// RespondFriendRequest is recipient-only; anyone else sees the request as missing.
func (s *Store) RespondFriendRequest(ctx context.Context, actor, id string, accept bool) (domain.FriendRequest, error) {
	var requester string
	err := s.Pool.QueryRow(ctx, `SELECT requested_by::text FROM friendships WHERE friendship_id=$1 AND status='pending' AND $2 IN (user_low_id,user_high_id) AND requested_by<>$2`, id, actor).Scan(&requester)
	if err != nil {
		return domain.FriendRequest{}, mapped(err)
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if accept {
			if err := lockPair(ctx, tx, actor, requester); err != nil {
				return err
			}
		}
		// Recheck under lock: the request may have been cancelled or replaced meanwhile.
		var still bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM friendships WHERE friendship_id=$1 AND status='pending' AND requested_by=$2 FOR UPDATE)`, id, requester).Scan(&still); err != nil {
			return err
		}
		if !still {
			return domain.ErrNotFound
		}
		if accept {
			return acceptFriend(ctx, tx, id, actor, requester)
		}
		if _, err := tx.Exec(ctx, `UPDATE friendships SET status='declined',responded_at=now(),updated_at=now() WHERE friendship_id=$1`, id); err != nil {
			return err
		}
		return unnotify(ctx, tx, actor, requester, "friend.requested")
	})
	if err != nil {
		return domain.FriendRequest{}, err
	}
	return scanFriendRequest(s.Pool.QueryRow(ctx, friendRequestSelect+` WHERE f.friendship_id=$1`, id))
}

// CancelFriendRequest is requester-only.
func (s *Store) CancelFriendRequest(ctx context.Context, actor, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var recipient string
		err := tx.QueryRow(ctx, `UPDATE friendships SET status='cancelled',updated_at=now() WHERE friendship_id=$1 AND requested_by=$2 AND status='pending'
 RETURNING (CASE WHEN user_low_id=$2 THEN user_high_id ELSE user_low_id END)::text`, id, actor).Scan(&recipient)
		if err != nil {
			return mapped(err)
		}
		return unnotify(ctx, tx, recipient, actor, "friend.requested")
	})
}

// Unfriend is idempotent.
func (s *Store) Unfriend(ctx context.Context, actor, target string) error {
	if err := noSelf(actor, target); err != nil {
		return err
	}
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE friendships SET status='removed',updated_at=now() WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid) AND status='accepted'`, actor, target)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return appendEvent(ctx, tx, actor, "friendship.changed", 0)
	})
}

func (s *Store) ListFriendRequests(ctx context.Context, actor string, incoming bool, before *time.Time, beforeID string, limit int) ([]domain.FriendRequest, error) {
	rows, err := s.Pool.Query(ctx, friendRequestSelect+`
 JOIN users su ON su.user_id=s.user_id AND su.status='active'
 JOIN users ru ON ru.user_id=r.user_id AND ru.status='active'
 WHERE f.status='pending' AND (CASE WHEN $2 THEN r.user_id=$1 ELSE s.user_id=$1 END)
 AND ($3::timestamptz IS NULL OR (f.created_at,f.friendship_id)<($3,$4::uuid))
 ORDER BY f.created_at DESC,f.friendship_id DESC LIMIT $5`, actor, incoming, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.FriendRequest{}
	for rows.Next() {
		f, err := scanFriendRequest(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, f)
	}
	return result, rows.Err()
}

var connectionSources = map[string]string{
	"followers":       `SELECT follower_id,created_at FROM follows WHERE followee_id=$1 AND state='active'`,
	"following":       `SELECT followee_id,created_at FROM follows WHERE follower_id=$1 AND state='active'`,
	"friends":         `SELECT CASE WHEN user_low_id=$1 THEN user_high_id ELSE user_low_id END,coalesce(responded_at,updated_at) FROM friendships WHERE $1 IN (user_low_id,user_high_id) AND status='accepted'`,
	"follow_requests": `SELECT follower_id,created_at FROM follows WHERE followee_id=$1 AND state='pending'`,
}

// CanSeeConnections gates another person's friends/followers/following lists.
func (s *Store) CanSeeConnections(ctx context.Context, viewer, owner string) error {
	if viewer == owner {
		return nil
	}
	var visible bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$2 AND status='active') AND NOT `+blockedBetween, viewer, owner).Scan(&visible); err != nil {
		return err
	}
	if !visible {
		return domain.ErrNotFound
	}
	policy, err := privacyOf(ctx, s.Pool, owner)
	if err != nil {
		return err
	}
	rel, err := relationship(ctx, s.Pool, viewer, owner, policy)
	if err != nil {
		return err
	}
	if !rel.Allows(policy.ProfileAudience) || !rel.Allows(policy.FieldAudiences["connections"]) {
		return domain.ErrConnectionsPrivate
	}
	return nil
}

// ListConnections hides inactive accounts and anyone blocked by or blocking the
// owner or the viewer, so lists never resurface a blocked person.
func (s *Store) ListConnections(ctx context.Context, kind, viewer, owner string, before *time.Time, beforeID string, limit int) ([]domain.Connection, error) {
	source, ok := connectionSources[kind]
	if !ok {
		return nil, domain.ErrNotFound
	}
	rows, err := s.Pool.Query(ctx, `WITH c(other,since) AS (`+source+`)
 SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),c.since FROM c
 JOIN users u ON u.user_id=c.other AND u.status='active'
 JOIN profiles p ON p.user_id=c.other
 WHERE NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id IN ($1,$2) AND b.blocked_id=c.other) OR (b.blocker_id=c.other AND b.blocked_id IN ($1,$2)))
 AND ($3::timestamptz IS NULL OR (c.since,c.other)<($3,$4::uuid))
 ORDER BY c.since DESC,c.other DESC LIMIT $5`, owner, viewer, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Connection{}
	for rows.Next() {
		var c domain.Connection
		if err = rows.Scan(&c.User.UserID, &c.User.Username, &c.User.DisplayName, &c.Since); err != nil {
			return nil, err
		}
		result = append(result, c)
	}
	return result, rows.Err()
}

const visibleNotifications = `FROM notifications n
 JOIN users u ON u.user_id=n.actor_id AND u.status='active'
 JOIN profiles p ON p.user_id=n.actor_id
 WHERE n.recipient_id=$1 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=n.actor_id) OR (b.blocker_id=n.actor_id AND b.blocked_id=$1))`

func (s *Store) ListNotifications(ctx context.Context, recipient string, unreadOnly bool, before *time.Time, beforeID string, limit int) ([]domain.Notification, error) {
	rows, err := s.Pool.Query(ctx, `SELECT n.notification_id::text,n.event,n.target_id::text,n.created_at,n.read_at,p.user_id::text,p.username,coalesce(p.data->>'displayName','') `+visibleNotifications+`
 AND (NOT $2 OR n.read_at IS NULL)
 AND ($3::timestamptz IS NULL OR (n.created_at,n.notification_id)<($3,$4::uuid))
 ORDER BY n.created_at DESC,n.notification_id DESC LIMIT $5`, recipient, unreadOnly, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Notification{}
	for rows.Next() {
		var n domain.Notification
		var actor domain.UserSummary
		if err = rows.Scan(&n.NotificationID, &n.Event, &n.TargetID, &n.CreatedAt, &n.ReadAt, &actor.UserID, &actor.Username, &actor.DisplayName); err != nil {
			return nil, err
		}
		labels := domain.NotificationCopy[n.Event]
		n.Type, n.TargetType = labels[0], labels[1]
		n.Text = actor.Name() + " " + labels[2]
		n.Actors = []domain.UserSummary{actor}
		n.Count = 1
		result = append(result, n)
	}
	return result, rows.Err()
}

func (s *Store) UnreadNotifications(ctx context.Context, recipient string) (int, error) {
	var count int
	err := s.Pool.QueryRow(ctx, `SELECT count(*) `+visibleNotifications+` AND n.read_at IS NULL`, recipient).Scan(&count)
	return count, err
}

func (s *Store) MarkNotificationRead(ctx context.Context, recipient, id string) error {
	tag, err := s.Pool.Exec(ctx, `UPDATE notifications SET read_at=coalesce(read_at,now()) WHERE notification_id=$1 AND recipient_id=$2`, id, recipient)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (s *Store) MarkAllNotificationsRead(ctx context.Context, recipient string) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE notifications SET read_at=now() WHERE recipient_id=$1 AND read_at IS NULL`, recipient)
	return tag.RowsAffected(), err
}
