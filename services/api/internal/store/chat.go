package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"kairova/services/api/internal/domain"
)

const maxDevices, maxOneTimeKeys = 10, 100

// RegisterDevice is idempotent for the same keys. A device id or identity key
// already bound to other keys is a conflict, never an overwrite.
func (s *Store) RegisterDevice(ctx context.Context, d domain.Device) (domain.Device, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var active bool
		if err := tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR UPDATE`, d.UserID).Scan(&active); err != nil || !active {
			return domain.ErrNotFound
		}
		var owner, identity, signing string
		var revoked bool
		err := tx.QueryRow(ctx, `SELECT user_id::text,identity_key,signing_key,revoked_at IS NOT NULL FROM devices WHERE device_id=$1 OR identity_key=$2 LIMIT 1`, d.DeviceID, d.IdentityKey).Scan(&owner, &identity, &signing, &revoked)
		switch {
		case err == nil:
			if owner != d.UserID || identity != d.IdentityKey || signing != d.SigningKey || revoked {
				return domain.ErrDeviceConflict
			}
			_, err = tx.Exec(ctx, `UPDATE devices SET last_seen_at=now(),display_name=$2,platform=$3 WHERE device_id=$1`, d.DeviceID, d.DisplayName, d.Platform)
			return err
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		var count int
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id=$1 AND revoked_at IS NULL`, d.UserID).Scan(&count); err != nil {
			return err
		}
		if count >= maxDevices {
			return domain.ErrTooManyDevices
		}
		if _, err = tx.Exec(ctx, `INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform,display_name) VALUES($1,$2,$3,$4,$5,$6,$7)`, d.DeviceID, d.UserID, d.IdentityKey, d.SigningKey, d.Signature, d.Platform, d.DisplayName); err != nil {
			return err
		}
		return appendEvent(ctx, tx, d.UserID, "device.added", 0)
	})
	if err != nil {
		return d, err
	}
	return s.device(ctx, d.UserID, d.DeviceID)
}

const deviceColumns = `device_id::text,user_id::text,identity_key,signing_key,signature,platform,display_name,created_at`

func scanDevice(row pgx.Row) (domain.Device, error) {
	var d domain.Device
	err := row.Scan(&d.DeviceID, &d.UserID, &d.IdentityKey, &d.SigningKey, &d.Signature, &d.Platform, &d.DisplayName, &d.CreatedAt)
	return d, mapped(err)
}

func (s *Store) device(ctx context.Context, user, id string) (domain.Device, error) {
	return scanDevice(s.Pool.QueryRow(ctx, `SELECT `+deviceColumns+` FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL`, id, user))
}

// RevokeDevice drops the device's unclaimed keys and undelivered ciphertext.
func (s *Store) RevokeDevice(ctx context.Context, user, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=now(),push_provider=NULL,push_token=NULL WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL`, id, user)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		for _, statement := range []string{
			`DELETE FROM one_time_keys WHERE device_id=$1`,
			`DELETE FROM fallback_keys WHERE device_id=$1`,
			`DELETE FROM message_envelopes WHERE recipient_device_id=$1 AND delivered_at IS NULL`,
		} {
			if _, err = tx.Exec(ctx, statement, id); err != nil {
				return err
			}
		}
		return appendEvent(ctx, tx, user, "device.revoked", 0)
	})
}

func (s *Store) devices(ctx context.Context, q querier, user string) ([]domain.Device, error) {
	rows, err := q.Query(ctx, `SELECT `+deviceColumns+` FROM devices WHERE user_id=$1 AND revoked_at IS NULL ORDER BY created_at,device_id`, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Device{}
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, d)
	}
	return result, rows.Err()
}

// MyDevices adds last activity, which only the owner may see.
func (s *Store) MyDevices(ctx context.Context, user string) ([]domain.Device, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+deviceColumns+`,last_seen_at FROM devices WHERE user_id=$1 AND revoked_at IS NULL ORDER BY created_at,device_id`, user)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Device, error) {
		var d domain.Device
		var seen time.Time
		err := row.Scan(&d.DeviceID, &d.UserID, &d.IdentityKey, &d.SigningKey, &d.Signature, &d.Platform, &d.DisplayName, &d.CreatedAt, &seen)
		d.LastSeenAt = &seen
		return d, err
	})
}

// UploadKeys stores signed one-time keys (bounded) and replaces the fallback key.
func (s *Store) UploadKeys(ctx context.Context, user, deviceID string, upload domain.KeyUpload) (int, error) {
	count := 0
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var signing string
		if err := tx.QueryRow(ctx, `SELECT signing_key FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL FOR UPDATE`, deviceID, user).Scan(&signing); err != nil {
			return mapped(err)
		}
		for _, k := range upload.OneTimeKeys {
			if err := k.Validate(user, deviceID, signing); err != nil {
				return err
			}
		}
		if upload.FallbackKey != nil {
			if err := upload.FallbackKey.Validate(user, deviceID, signing); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM one_time_keys WHERE device_id=$1`, deviceID).Scan(&count); err != nil {
			return err
		}
		if count+len(upload.OneTimeKeys) > maxOneTimeKeys {
			return &domain.ValidationError{Field: "oneTimeKeys", Message: "a device holds at most 100 unclaimed keys"}
		}
		for _, k := range upload.OneTimeKeys {
			tag, err := tx.Exec(ctx, `INSERT INTO one_time_keys(device_id,key_id,public_key,signature) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`, deviceID, k.KeyID, k.PublicKey, k.Signature)
			if err != nil {
				return err
			}
			count += int(tag.RowsAffected())
		}
		if k := upload.FallbackKey; k != nil {
			if _, err := tx.Exec(ctx, `INSERT INTO fallback_keys(device_id,key_id,public_key,signature) VALUES($1,$2,$3,$4)
 ON CONFLICT (device_id) DO UPDATE SET key_id=excluded.key_id,public_key=excluded.public_key,signature=excluded.signature,updated_at=now()`, deviceID, k.KeyID, k.PublicKey, k.Signature); err != nil {
				return err
			}
		}
		return nil
	})
	return count, err
}

func (s *Store) KeyCount(ctx context.Context, user, deviceID string) (int, bool, error) {
	var count int
	var fallback bool
	err := s.Pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM one_time_keys WHERE device_id=d.device_id),EXISTS(SELECT 1 FROM fallback_keys WHERE device_id=d.device_id)
 FROM devices d WHERE d.device_id=$1 AND d.user_id=$2 AND d.revoked_at IS NULL`, deviceID, user).Scan(&count, &fallback)
	return count, fallback, mapped(err)
}

// canMessage applies the target's messagesFrom setting. Once the target has
// written in the conversation, the actor may always reply.
func canMessage(ctx context.Context, q querier, actor, target string) error {
	if actor == target {
		return &domain.ValidationError{Field: "userId", Message: "choose another account"}
	}
	var visible, replied bool
	err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$2 AND status='active') AND EXISTS(SELECT 1 FROM users WHERE user_id=$1 AND status='active') AND NOT `+blockedBetween+`,
 EXISTS(SELECT 1 FROM messages m JOIN conversations c USING(conversation_id) WHERE m.sender_id=$2 AND c.user_low_id=least($1::uuid,$2::uuid) AND c.user_high_id=greatest($1::uuid,$2::uuid))`, actor, target).Scan(&visible, &replied)
	if err != nil {
		return err
	}
	if !visible {
		return domain.ErrNotFound
	}
	if replied {
		return nil
	}
	policy, err := privacyOf(ctx, q, target)
	if err != nil {
		return err
	}
	rel, err := relationship(ctx, q, actor, target, policy)
	if err != nil {
		return err
	}
	if !rel.Allows(policy.MessagesFrom) {
		return domain.ErrMessagesNotAllowed
	}
	return nil
}

// PeerDevices lists another person's devices only to someone allowed to message them.
func (s *Store) PeerDevices(ctx context.Context, actor, target string) ([]domain.Device, error) {
	if actor != target {
		if err := canMessage(ctx, s.Pool, actor, target); err != nil {
			return nil, err
		}
	}
	return s.devices(ctx, s.Pool, target)
}

// ClaimKey hands out each one-time key exactly once; the fallback key is reused
// only when none remain.
func (s *Store) ClaimKey(ctx context.Context, actor, target, deviceID string) (domain.ClaimedKey, error) {
	claimed := domain.ClaimedKey{DeviceID: deviceID}
	// Your own other devices are always reachable; anyone else needs messaging access.
	if actor != target {
		if err := canMessage(ctx, s.Pool, actor, target); err != nil {
			return claimed, err
		}
	}
	var exists bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL)`, deviceID, target).Scan(&exists); err != nil {
		return claimed, err
	}
	if !exists {
		return claimed, domain.ErrNotFound
	}
	err := s.Pool.QueryRow(ctx, `DELETE FROM one_time_keys WHERE (device_id,key_id)=(SELECT device_id,key_id FROM one_time_keys WHERE device_id=$1 ORDER BY created_at,key_id LIMIT 1 FOR UPDATE SKIP LOCKED)
 RETURNING key_id,public_key,signature`, deviceID).Scan(&claimed.KeyID, &claimed.PublicKey, &claimed.Signature)
	if errors.Is(err, pgx.ErrNoRows) {
		claimed.Fallback = true
		err = s.Pool.QueryRow(ctx, `SELECT key_id,public_key,signature FROM fallback_keys WHERE device_id=$1`, deviceID).Scan(&claimed.KeyID, &claimed.PublicKey, &claimed.Signature)
	}
	return claimed, mapped(err)
}

// receiptsOn is true when both members allow read receipts; it is reciprocal.
const receiptsOn = `coalesce((mq.data->>'readReceipts')::boolean,false) AND coalesce((pq.data->>'readReceipts')::boolean,false)`

// conversationSelect reads the caller's member row ($1) and joins the peer's.
const conversationSelect = `SELECT c.conversation_id::text,c.status,c.created_at,c.last_message_at,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),
 m.unread_count,m.read_at,CASE WHEN ` + receiptsOn + ` THEN pm.read_at END,m.sort_at
 FROM conversation_members m
 JOIN conversations c ON c.conversation_id=m.conversation_id
 JOIN conversation_members pm ON pm.conversation_id=m.conversation_id AND pm.user_id=m.peer_id
 JOIN profiles p ON p.user_id=m.peer_id
 JOIN users u ON u.user_id=p.user_id AND u.status='active'
 JOIN privacy_settings mq ON mq.user_id=m.user_id
 JOIN privacy_settings pq ON pq.user_id=m.peer_id
 WHERE m.user_id=$1
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=p.user_id) OR (b.blocker_id=p.user_id AND b.blocked_id=$1))`

func scanConversation(row pgx.Row) (domain.Conversation, error) {
	var c domain.Conversation
	err := row.Scan(&c.ConversationID, &c.Status, &c.CreatedAt, &c.LastMessageAt, &c.Peer.UserID, &c.Peer.Username, &c.Peer.DisplayName, &c.UnreadCount, &c.ReadAt, &c.PeerReadAt, &c.SortAt)
	return c, mapped(err)
}

// OpenConversation returns the pair's direct conversation, creating or reopening it.
func (s *Store) OpenConversation(ctx context.Context, actor, target string) (domain.Conversation, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := noSelf(actor, target); err != nil {
			return err
		}
		if err := lockPair(ctx, tx, actor, target); err != nil {
			return err
		}
		var status string
		err := tx.QueryRow(ctx, `SELECT status FROM conversations WHERE user_low_id=least($1::uuid,$2::uuid) AND user_high_id=greatest($1::uuid,$2::uuid)`, actor, target).Scan(&status)
		if err == nil && status == "active" {
			return nil
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if err := canMessage(ctx, tx, actor, target); err != nil {
			return err
		}
		var id string
		var created time.Time
		if err = tx.QueryRow(ctx, `INSERT INTO conversations(conversation_id,user_low_id,user_high_id,created_by,status) VALUES($1,least($2::uuid,$3::uuid),greatest($2::uuid,$3::uuid),$2,'active')
 ON CONFLICT (user_low_id,user_high_id) DO UPDATE SET status='active' RETURNING conversation_id::text,created_at`, newID(), actor, target).Scan(&id, &created); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at) VALUES($1,$2,$3,$4),($1,$3,$2,$4) ON CONFLICT DO NOTHING`, id, actor, target, created)
		return err
	})
	if err != nil {
		return domain.Conversation{}, err
	}
	return scanConversation(s.Pool.QueryRow(ctx, conversationSelect+` AND m.peer_id=$2`, actor, target))
}

func (s *Store) Conversation(ctx context.Context, user, id string) (domain.Conversation, error) {
	return scanConversation(s.Pool.QueryRow(ctx, conversationSelect+` AND m.conversation_id=$2`, user, id))
}

func (s *Store) ListConversations(ctx context.Context, user string, before *time.Time, beforeID string, limit int) ([]domain.Conversation, error) {
	rows, err := s.Pool.Query(ctx, conversationSelect+` AND c.status='active'
 AND ($2::timestamptz IS NULL OR (m.sort_at,m.conversation_id)<($2,$3::uuid))
 ORDER BY m.sort_at DESC,m.conversation_id DESC LIMIT $4`, user, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Conversation{}
	for rows.Next() {
		c, err := scanConversation(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, c)
	}
	return result, rows.Err()
}

// SendMessage stores one ciphertext per recipient device. The device set must be
// exactly the peer's devices plus the sender's other devices, so no device is
// silently skipped and none can be injected.
// It returns the peer so callers can signal without another lookup.
func (s *Store) SendMessage(ctx context.Context, user, conversationID string, m domain.SendMessage) (created time.Time, peer string, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT (CASE WHEN user_low_id=$2 THEN user_high_id ELSE user_low_id END)::text FROM conversations WHERE conversation_id=$1 AND $2 IN (user_low_id,user_high_id)`, conversationID, user).Scan(&peer)
	if err != nil {
		return created, "", mapped(err)
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockPair(ctx, tx, user, peer); err != nil {
			return err
		}
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM conversations WHERE conversation_id=$1 FOR UPDATE`, conversationID).Scan(&status); err != nil {
			return err
		}
		if status != "active" {
			return domain.ErrConversationClosed
		}
		var sender string
		err := tx.QueryRow(ctx, `SELECT sender_id::text FROM messages WHERE message_id=$1`, m.MessageID).Scan(&sender)
		if err == nil {
			if sender != user {
				return &domain.ValidationError{Field: "messageId", Message: "already used"}
			}
			return tx.QueryRow(ctx, `SELECT created_at FROM messages WHERE message_id=$1`, m.MessageID).Scan(&created)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if err := canMessage(ctx, tx, user, peer); err != nil {
			return err
		}
		var senderOK bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL)`, m.SenderDeviceID, user).Scan(&senderOK); err != nil {
			return err
		}
		if !senderOK {
			return domain.ErrNotFound
		}
		rows, err := tx.Query(ctx, `SELECT device_id::text FROM devices WHERE revoked_at IS NULL AND (user_id=$1 OR (user_id=$2 AND device_id<>$3)) ORDER BY device_id`, peer, user, m.SenderDeviceID)
		if err != nil {
			return err
		}
		expected := []string{}
		for rows.Next() {
			var id string
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			expected = append(expected, id)
		}
		rows.Close()
		got := make([]string, 0, len(m.Envelopes))
		for _, e := range m.Envelopes {
			got = append(got, e.DeviceID)
		}
		sort.Strings(got)
		if len(expected) == 0 || len(got) != len(expected) {
			return domain.ErrDevicesChanged
		}
		for i := range got {
			if got[i] != expected[i] {
				return domain.ErrDevicesChanged
			}
		}
		if err = tx.QueryRow(ctx, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id) VALUES($1,$2,$3,$4) RETURNING created_at`, m.MessageID, conversationID, user, m.SenderDeviceID).Scan(&created); err != nil {
			return err
		}
		batch := &pgx.Batch{}
		for _, e := range m.Envelopes {
			batch.Queue(`INSERT INTO message_envelopes(message_id,recipient_device_id,envelope_type,ciphertext) VALUES($1,$2,$3,$4)`, m.MessageID, e.DeviceID, e.Type, e.Ciphertext)
		}
		if err = tx.SendBatch(ctx, batch).Close(); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE conversations SET last_message_at=$2 WHERE conversation_id=$1`, conversationID, created); err != nil {
			return err
		}
		// The sender has read up to their own message; the peer has one more unread.
		_, err = tx.Exec(ctx, `UPDATE conversation_members SET sort_at=$2,
 unread_count=CASE WHEN user_id=$3 THEN 0 ELSE unread_count+1 END,
 read_at=CASE WHEN user_id=$3 THEN greatest(read_at,$2) ELSE read_at END
 WHERE conversation_id=$1`, conversationID, created, user)
		return err
	})
	return created, peer, err
}

// MarkRead moves the caller's read pointer forward to upTo (never past now) and
// recounts what remains unread. It reports the peer and whether anything changed.
func (s *Store) MarkRead(ctx context.Context, user, conversationID string, upTo time.Time) (peer string, readAt time.Time, changed bool, err error) {
	err = s.Pool.QueryRow(ctx, `UPDATE conversation_members m SET read_at=least($3::timestamptz,now()),
 unread_count=(SELECT count(*) FROM (SELECT 1 FROM messages x WHERE x.conversation_id=m.conversation_id AND x.sender_id<>m.user_id AND x.created_at>least($3::timestamptz,now()) LIMIT 999) q)
 WHERE m.user_id=$1 AND m.conversation_id=$2 AND (m.read_at IS NULL OR m.read_at<least($3::timestamptz,now()))
 RETURNING m.peer_id::text,m.read_at`, user, conversationID, upTo).Scan(&peer, &readAt)
	if err == nil {
		return peer, readAt, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", time.Time{}, false, err
	}
	// Nothing moved: either already read that far, or not a member.
	var at *time.Time
	err = s.Pool.QueryRow(ctx, `SELECT peer_id::text,read_at FROM conversation_members WHERE user_id=$1 AND conversation_id=$2`, user, conversationID).Scan(&peer, &at)
	if err != nil {
		return "", time.Time{}, false, mapped(err)
	}
	if at != nil {
		readAt = *at
	}
	return peer, readAt, false, nil
}

// ReadReceiptsShared reports whether both people allow read receipts and typing.
func (s *Store) ReadReceiptsShared(ctx context.Context, a, b string) (bool, error) {
	var on bool
	err := s.Pool.QueryRow(ctx, `SELECT coalesce(bool_and(coalesce((data->>'readReceipts')::boolean,false)),false) AND count(*)=2 FROM privacy_settings WHERE user_id IN ($1,$2)`, a, b).Scan(&on)
	return on, err
}

// Unread totals the caller's unread messages across active conversations.
func (s *Store) Unread(ctx context.Context, user string) (domain.UnreadSummary, error) {
	var u domain.UnreadSummary
	err := s.Pool.QueryRow(ctx, `SELECT coalesce(sum(m.unread_count),0)::int,count(*)::int FROM conversation_members m JOIN conversations c ON c.conversation_id=m.conversation_id
 WHERE m.user_id=$1 AND m.unread_count>0 AND c.status='active'`, user).Scan(&u.Messages, &u.Conversations)
	return u, err
}

// SetPushToken attaches a push token to one of the caller's devices. A token
// moved from another device (reinstall) is detached from it first.
func (s *Store) SetPushToken(ctx context.Context, user, deviceID, provider, token string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		if token != "" {
			if _, err := tx.Exec(ctx, `UPDATE devices SET push_provider=NULL,push_token=NULL WHERE push_provider=$1 AND push_token=$2 AND device_id<>$3`, provider, token, deviceID); err != nil {
				return err
			}
		}
		var p, t any
		if token != "" {
			p, t = provider, token
		}
		tag, err := tx.Exec(ctx, `UPDATE devices SET push_provider=$3,push_token=$4 WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL`, deviceID, user, p, t)
		if err == nil && tag.RowsAffected() == 0 {
			err = domain.ErrNotFound
		}
		return err
	})
}

// PushTarget is one device to wake with a content-free push.
type PushTarget struct {
	UserID, DeviceID, Provider, Token string
}

// PushTargets lists active devices with push tokens for the given users.
func (s *Store) PushTargets(ctx context.Context, users []string) ([]PushTarget, error) {
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text,device_id::text,push_provider,push_token FROM devices WHERE user_id=ANY($1::uuid[]) AND revoked_at IS NULL AND push_token IS NOT NULL`, users)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (PushTarget, error) {
		var t PushTarget
		return t, row.Scan(&t.UserID, &t.DeviceID, &t.Provider, &t.Token)
	})
}

// ExpireEnvelopes deletes delivered envelope rows after deliveredTTL and
// undelivered ciphertext after undeliveredTTL, at most batch rows per call.
func (s *Store) ExpireEnvelopes(ctx context.Context, deliveredTTL, undeliveredTTL time.Duration, batch int) (int64, error) {
	var total int64
	for _, q := range []struct {
		sql string
		ttl time.Duration
	}{
		{`DELETE FROM message_envelopes WHERE ctid IN (SELECT ctid FROM message_envelopes WHERE created_at<now()-$1::interval AND delivered_at IS NOT NULL ORDER BY created_at LIMIT $2)`, deliveredTTL},
		{`DELETE FROM message_envelopes WHERE ctid IN (SELECT ctid FROM message_envelopes WHERE created_at<now()-$1::interval AND delivered_at IS NULL ORDER BY created_at LIMIT $2)`, undeliveredTTL},
	} {
		tag, err := s.Pool.Exec(ctx, q.sql, q.ttl, batch)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// Inbox returns undelivered ciphertext for one of the caller's devices, oldest first.
func (s *Store) Inbox(ctx context.Context, user, deviceID string, limit int) ([]domain.InboxItem, error) {
	// last_seen_at is a coarse hint; writing it at most every five minutes keeps
	// frequent inbox reads from turning into row writes.
	var exists bool
	err := s.Pool.QueryRow(ctx, `WITH d AS (SELECT device_id,last_seen_at FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL),
 touched AS (UPDATE devices SET last_seen_at=now() WHERE device_id IN (SELECT device_id FROM d WHERE last_seen_at<now()-interval '5 minutes'))
 SELECT EXISTS(SELECT 1 FROM d)`, deviceID, user).Scan(&exists)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, domain.ErrNotFound
	}
	rows, err := s.Pool.Query(ctx, `SELECT m.message_id::text,m.conversation_id::text,m.sender_id::text,m.sender_device_id::text,sd.identity_key,e.envelope_type,e.ciphertext,m.created_at
 FROM message_envelopes e JOIN messages m USING(message_id) JOIN devices sd ON sd.device_id=m.sender_device_id
 WHERE e.recipient_device_id=$1 AND e.delivered_at IS NULL
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$2 AND b.blocked_id=m.sender_id) OR (b.blocker_id=m.sender_id AND b.blocked_id=$2))
 ORDER BY e.created_at,m.message_id LIMIT $3`, deviceID, user, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.InboxItem{}
	for rows.Next() {
		var i domain.InboxItem
		if err = rows.Scan(&i.MessageID, &i.ConversationID, &i.SenderID, &i.SenderDeviceID, &i.SenderIdentity, &i.Type, &i.Ciphertext, &i.CreatedAt); err != nil {
			return nil, err
		}
		result = append(result, i)
	}
	return result, rows.Err()
}

// Ack marks envelopes delivered and deletes their ciphertext from the server.
func (s *Store) Ack(ctx context.Context, user, deviceID string, ids []string) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE message_envelopes e SET delivered_at=now(),ciphertext=NULL FROM devices d
 WHERE d.device_id=e.recipient_device_id AND d.user_id=$2 AND e.recipient_device_id=$1 AND e.message_id=ANY($3::uuid[]) AND e.delivered_at IS NULL`, deviceID, user, ids)
	return tag.RowsAffected(), err
}
