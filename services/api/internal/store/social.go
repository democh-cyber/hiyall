package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// querier is satisfied by both the pool and a transaction.
type querier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

// barredBetween is true when $1 and $2 may not see or reach each other: a block in either
// direction or, while age-band isolation is on, different age bands (interaction_barred,
// migration 0017). Every place that used to check only blocks between two members uses it,
// so a cross-band attempt looks exactly like a block. The safety lists of real blocks do not.
const barredBetween = `interaction_barred($1::uuid,$2::uuid)`

// lockPair locks both accounts in id order so reciprocal actions cannot deadlock.
// Inactive accounts, accounts that have not finished onboarding (their profile is hidden too)
// and barred pairs (blocked, or in different age bands) are indistinguishable from missing ones.
func lockPair(ctx context.Context, tx pgx.Tx, a, b string) error {
	rows, err := tx.Query(ctx, `SELECT u.user_id FROM users u JOIN onboarding o ON o.user_id=u.user_id AND o.completed_at IS NOT NULL WHERE u.user_id IN ($1,$2) AND u.status='active' ORDER BY u.user_id FOR NO KEY UPDATE OF u`, a, b)
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
	var barred bool
	if err = tx.QueryRow(ctx, `SELECT `+barredBetween, a, b).Scan(&barred); err != nil {
		return err
	}
	if barred {
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
func (s *Store) Follow(ctx context.Context, actor, target string, e domain.Entitlements) (string, error) {
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
		if err = capDaily(ctx, tx, actor, domain.DailyFollows, e.FollowsPerDay); err != nil {
			return err
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
		return nil
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
		return nil
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
		return nil
	})
}

// RemoveFollower lets an owner drop an active follower without blocking them.
func (s *Store) RemoveFollower(ctx context.Context, owner, follower string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE follows SET state='removed',removed_at=now() WHERE follower_id=$2 AND followee_id=$1 AND state='active'`, owner, follower)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return nil
	})
}

var friendRequestSelect = `SELECT f.friendship_id::text,f.status,f.created_at,
 s.user_id::text,s.username,coalesce(s.data->>'displayName',''),` + avatarThumbKey("sav") + `,
 r.user_id::text,r.username,coalesce(r.data->>'displayName',''),` + avatarThumbKey("rav") + `
 FROM friendships f
 JOIN profiles s ON s.user_id=f.requested_by
 JOIN profiles r ON r.user_id=CASE WHEN f.requested_by=f.user_low_id THEN f.user_high_id ELSE f.user_low_id END` + avatarJoin("sav", "s") + avatarJoin("rav", "r")

func scanFriendRequest(row pgx.Row, sign Signer) (domain.FriendRequest, error) {
	var f domain.FriendRequest
	var sender, recipient *string
	err := row.Scan(&f.RequestID, &f.Status, &f.CreatedAt, &f.Sender.UserID, &f.Sender.Username, &f.Sender.DisplayName, &sender, &f.Recipient.UserID, &f.Recipient.Username, &f.Recipient.DisplayName, &recipient)
	f.Sender.AvatarURL, f.Recipient.AvatarURL = avatarURL(sign, sender), avatarURL(sign, recipient)
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
	return nil
}

// SendFriendRequest is idempotent, and accepts instead when the target already asked.
func (s *Store) SendFriendRequest(ctx context.Context, actor, target string, sign Signer, e domain.Entitlements) (domain.FriendRequest, error) {
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
		// The cooldown lasts 7 days from the decline; the refusal says how long is left.
		var remaining *int64
		err = tx.QueryRow(ctx, `SELECT ceil(extract(epoch FROM responded_at+interval '7 days'-now()))::bigint FROM friendships WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid) AND status='declined' AND requested_by=$1 AND responded_at>now()-interval '7 days'`, actor, target).Scan(&remaining)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if remaining != nil {
			return domain.RetryAfter(domain.ErrRequestCooldown, time.Duration(*remaining)*time.Second)
		}
		if !rel.CanFriendRequest {
			return domain.ErrRequestNotAllowed
		}
		// Sending counts against the day whatever becomes of the request: cancelling it refunds nothing, so
		// cancel-and-resend cannot be used to ask the same people again and again.
		if err = capDaily(ctx, tx, actor, domain.DailyFriendRequests, e.FriendRequestsPerDay); err != nil {
			return err
		}
		id = newID()
		if _, err = tx.Exec(ctx, `INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES($1,least($2::uuid,$3::uuid),greatest($2::uuid,$3::uuid),$2,'pending')
 ON CONFLICT (user_low_id,user_high_id) DO UPDATE SET friendship_id=excluded.friendship_id,requested_by=excluded.requested_by,status='pending',created_at=now(),responded_at=NULL,updated_at=now()`, id, actor, target); err != nil {
			return err
		}
		if err = notify(ctx, tx, target, actor, "friend.requested", id); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return domain.FriendRequest{}, err
	}
	return scanFriendRequest(s.Pool.QueryRow(ctx, friendRequestSelect+` WHERE f.friendship_id=$1`, id), sign)
}

// RespondFriendRequest is recipient-only; anyone else sees the request as missing.
func (s *Store) RespondFriendRequest(ctx context.Context, actor, id string, accept bool, sign Signer) (domain.FriendRequest, error) {
	var requester string
	err := s.Pool.QueryRow(ctx, `SELECT requested_by::text FROM friendships WHERE friendship_id=$1 AND status='pending' AND $2 IN (user_low_id,user_high_id) AND requested_by<>$2 AND NOT interaction_barred($2::uuid,requested_by)`, id, actor).Scan(&requester)
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
	return scanFriendRequest(s.Pool.QueryRow(ctx, friendRequestSelect+` WHERE f.friendship_id=$1`, id), sign)
}

// CancelFriendRequest is requester-only.
func (s *Store) CancelFriendRequest(ctx context.Context, actor, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		var recipient string
		err := tx.QueryRow(ctx, `UPDATE friendships SET status='cancelled',updated_at=now() WHERE friendship_id=$1 AND requested_by=$2 AND status='pending'
 AND NOT interaction_barred($2::uuid,CASE WHEN user_low_id=$2 THEN user_high_id ELSE user_low_id END)
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
		return nil
	})
}

// ListFriendRequests pages pending requests, newest first. The friendship row stores its two members as
// (user_low_id, user_high_id), so "requests I received" and "requests I sent" are each two sargable probes,
// one per side, on the partial pending indexes (migration 0006); the two short pages are merged here.
func (s *Store) ListFriendRequests(ctx context.Context, actor string, incoming bool, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.FriendRequest, error) {
	result := []domain.FriendRequest{}
	for _, side := range []string{"user_low_id", "user_high_id"} {
		// incoming: the other member sent it (requested_by<>actor); outgoing: the actor did.
		rows, err := s.Pool.Query(ctx, friendRequestSelect+`
 JOIN users su ON su.user_id=s.user_id AND su.status='active'
 JOIN users ru ON ru.user_id=r.user_id AND ru.status='active'
 WHERE f.status='pending' AND f.`+side+`=$1 AND (f.requested_by=$1)=NOT $2
 AND `+notBarred("$1::uuid", "CASE WHEN $2 THEN s.user_id ELSE r.user_id END")+`
 AND ($3::timestamptz IS NULL OR (f.created_at,f.friendship_id)<($3,$4::uuid))
 ORDER BY f.created_at DESC,f.friendship_id DESC LIMIT $5`, actor, incoming, before, beforeID, limit)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			f, err := scanFriendRequest(rows, sign)
			if err != nil {
				rows.Close()
				return nil, err
			}
			result = append(result, f)
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return nil, err
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if !result[i].CreatedAt.Equal(result[j].CreatedAt) {
			return result[i].CreatedAt.After(result[j].CreatedAt)
		}
		return result[i].RequestID > result[j].RequestID
	})
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

var connectionSources = map[string]string{
	"followers":       `SELECT follower_id,created_at FROM follows WHERE followee_id=$1 AND state='active'`,
	"following":       `SELECT followee_id,created_at FROM follows WHERE follower_id=$1 AND state='active'`,
	"friends":         `SELECT CASE WHEN user_low_id=$1 THEN user_high_id ELSE user_low_id END,coalesce(responded_at,updated_at) FROM friendships WHERE $1 IN (user_low_id,user_high_id) AND status='accepted'`,
	"follow_requests": `SELECT follower_id,created_at FROM follows WHERE followee_id=$1 AND state='pending'`,
}

// CanSeeConnections gates another person's followers and following lists. The owner always may.
// Anyone else needs the owner's profile audience and the owner's "connections" field audience to admit
// them; for an adult owner that field starts at "followers", so a viewer with an active follow on the
// owner (and a friend) may open the lists, while a pending request, an unfollow, a block or the other
// age band does not. A minor's field starts at "friends" (domain.ApplyMinorDefaults).
func (s *Store) CanSeeConnections(ctx context.Context, viewer, owner string) error {
	return s.canSeeConnectionList(ctx, viewer, owner, false)
}

// CanSeeFriends gates another person's friends list. It is stricter: the connections audience applies as
// for the other lists, except that "followers" is read as "friends", so the accepted friendships of a
// member are listed to their friends (and the member) only, however many people follow them. An owner who
// has opened the field to "everyone" through the API still opens it to everyone, as before.
func (s *Store) CanSeeFriends(ctx context.Context, viewer, owner string) error {
	return s.canSeeConnectionList(ctx, viewer, owner, true)
}

func (s *Store) canSeeConnectionList(ctx context.Context, viewer, owner string, friendsList bool) error {
	if viewer == owner {
		return nil
	}
	var visible bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users u JOIN onboarding o USING(user_id) WHERE u.user_id=$2 AND u.status='active' AND o.completed_at IS NOT NULL) AND NOT `+barredBetween, viewer, owner).Scan(&visible); err != nil {
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
	audience := policy.FieldAudiences["connections"]
	if friendsList && audience == "followers" {
		audience = "friends"
	}
	if !rel.Allows(policy.ProfileAudience) || !rel.Allows(audience) {
		return domain.ErrConnectionsPrivate
	}
	return nil
}

// ListConnections hides inactive accounts and anyone barred from the owner or the viewer
// (blocked in either direction, or in the other age band), so lists never resurface them.
func (s *Store) ListConnections(ctx context.Context, kind, viewer, owner string, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.Connection, error) {
	source, ok := connectionSources[kind]
	if !ok {
		return nil, domain.ErrNotFound
	}
	rows, err := s.Pool.Query(ctx, `WITH c(other,since) AS (`+source+`)
 SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,c.since,coalesce(vf.state,'none') FROM c
 JOIN users u ON u.user_id=c.other AND u.status='active'
 JOIN profiles p ON p.user_id=c.other`+avatarJoin("av", "p")+`
 LEFT JOIN follows vf ON vf.follower_id=$2 AND vf.followee_id=c.other AND vf.state<>'removed'
 WHERE `+notBarred("$1::uuid", "c.other")+` AND `+notBarred("$2::uuid", "c.other")+`
 AND ($3::timestamptz IS NULL OR (c.since,c.other)<($3,$4::uuid))
 ORDER BY c.since DESC,c.other DESC LIMIT $5`, owner, viewer, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Connection{}
	for rows.Next() {
		var c domain.Connection
		var avatar *string
		var following string
		if err = rows.Scan(&c.User.UserID, &c.User.Username, &c.User.DisplayName, &avatar, &c.Since, &following); err != nil {
			return nil, err
		}
		c.User.AvatarURL, c.Following = avatarURL(sign, avatar), &following
		result = append(result, c)
	}
	return result, rows.Err()
}

// ListVisitors pages the members who opened the owner's own profile, newest first visit first. Only the
// owner's own list exists: there is no way to ask for someone else's. Inactive accounts and anyone barred
// from the owner (blocked in either direction, or in the other age band) are left out. limitTotal
// (the member's VisitorListLimit) is how many of the most recent visitors the list ever returns, across
// all its pages; the cap is applied after those exclusions.
func (s *Store) ListVisitors(ctx context.Context, owner string, before *time.Time, beforeID string, limit, limitTotal int, sign Signer) ([]domain.Visitor, error) {
	limitTotal = max(limitTotal, 0)
	rows, err := s.Pool.Query(ctx, `WITH v AS (
  SELECT pv.visitor_id,pv.first_visited_at FROM profile_visits pv
  JOIN users u ON u.user_id=pv.visitor_id AND u.status='active'
  WHERE pv.profile_id=$1 AND `+notBarred("$1::uuid", "pv.visitor_id")+`
  ORDER BY pv.first_visited_at DESC,pv.visitor_id DESC LIMIT $2)
 SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,v.first_visited_at,coalesce(vf.state,'none') FROM v
 JOIN profiles p ON p.user_id=v.visitor_id`+avatarJoin("av", "p")+`
 LEFT JOIN follows vf ON vf.follower_id=$1 AND vf.followee_id=v.visitor_id AND vf.state<>'removed'
 WHERE ($3::timestamptz IS NULL OR (v.first_visited_at,v.visitor_id)<($3,$4::uuid))
 ORDER BY v.first_visited_at DESC,v.visitor_id DESC LIMIT $5`, owner, limitTotal, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Visitor{}
	for rows.Next() {
		var v domain.Visitor
		var avatar *string
		if err = rows.Scan(&v.User.UserID, &v.User.Username, &v.User.DisplayName, &avatar, &v.FirstVisitedAt, &v.Following); err != nil {
			return nil, err
		}
		v.User.AvatarURL = avatarURL(sign, avatar)
		result = append(result, v)
	}
	return result, rows.Err()
}

const notificationsFrom = `FROM notifications n
 JOIN users u ON u.user_id=n.actor_id AND u.status='active'
 JOIN profiles p ON p.user_id=n.actor_id`

var notificationsWhere = `
 WHERE n.recipient_id=$1 AND ` + notBarred("$1::uuid", "n.actor_id")
var visibleNotifications = notificationsFrom + notificationsWhere

func (s *Store) ListNotifications(ctx context.Context, recipient string, unreadOnly bool, before *time.Time, beforeID string, limit int, sign Signer) ([]domain.Notification, error) {
	rows, err := s.Pool.Query(ctx, `SELECT n.notification_id::text,n.event,n.target_id::text,n.created_at,n.read_at,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+` `+notificationsFrom+avatarJoin("av", "p")+notificationsWhere+`
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
		var avatar *string
		if err = rows.Scan(&n.NotificationID, &n.Event, &n.TargetID, &n.CreatedAt, &n.ReadAt, &actor.UserID, &actor.Username, &actor.DisplayName, &avatar); err != nil {
			return nil, err
		}
		actor.AvatarURL = avatarURL(sign, avatar)
		labels := domain.NotificationCopy[n.Event]
		n.Type, n.TargetType = labels[0], labels[1]
		n.Text = actor.Name() + " " + labels[2]
		n.Actors = []domain.UserSummary{actor}
		n.Count = 1
		result = append(result, n)
	}
	return result, rows.Err()
}

// BadgeCap is the largest unread count the API reports: the badge shows "99+" beyond it, so counting
// stops at BadgeCap+1 rows however many notifications are waiting.
const BadgeCap = 99

// UnreadBadge counts the recipient's unread, visible notifications up to BadgeCap+1 rows. The count it
// returns never exceeds BadgeCap; more is true when there are more than that.
func (s *Store) UnreadBadge(ctx context.Context, recipient string) (count int, more bool, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT count(*) FROM (SELECT 1 `+visibleNotifications+` AND n.read_at IS NULL LIMIT $2) x`, recipient, BadgeCap+1).Scan(&count)
	if count > BadgeCap {
		count, more = BadgeCap, true
	}
	return count, more, err
}

// UnreadNotifications is UnreadBadge without the "more" flag, capped at BadgeCap.
func (s *Store) UnreadNotifications(ctx context.Context, recipient string) (int, error) {
	count, _, err := s.UnreadBadge(ctx, recipient)
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
