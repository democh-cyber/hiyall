package store

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

const maxDevices, maxOneTimeKeys = 10, 100

// RegisterDevice is idempotent for the same keys. A device id or identity key
// already bound to other keys is a conflict, never an overwrite.
func (s *Store) RegisterDevice(ctx context.Context, d domain.Device) (domain.Device, error) {
	d, _, err := s.RegisterDeviceNew(ctx, d)
	return d, err
}

// FirstContactMessages is how many conversation messages (not reactions) a member may send in a
// conversation before the other person has sent one of their own.
const FirstContactMessages = 3

// StaleDeviceAfter is how long a chat device may go unseen before maintenance revokes it (shortened from 90 days
// by audit CHAT-N1: a dormant device otherwise holds undelivered ciphertext, and a slot, for a quarter).
const StaleDeviceAfter = 14 * 24 * time.Hour

// DormantDeviceAfter is how long a device that is over the undelivered-envelope cap may have gone without
// polling before a send revokes it (inside the send's transaction), so one forgotten or orphaned device cannot
// refuse every message addressed to its owner (CHAT-N1).
const DormantDeviceAfter = 7 * 24 * time.Hour

// BackloggedDeviceIdle is how long a device holding more than half the cap may have gone without polling before
// the hourly sweep revokes it (RevokeBackloggedDevices).
const BackloggedDeviceIdle = 3 * 24 * time.Hour

// RevokedDevice names a device the relay revoked for being dormant, and its owner.
type RevokedDevice struct{ DeviceID, UserID string }

// DevicesRevoked is the answer to a send that found a dormant device over the backlog cap and revoked it. The
// revocation is committed; the sender is told DEVICES_CHANGED (it errors.Is domain.ErrDevicesChanged) and
// encrypts again for the remaining devices. The caller signals the owners of Devices.
type DevicesRevoked struct{ Devices []RevokedDevice }

func (*DevicesRevoked) Error() string { return domain.ErrDevicesChanged.Error() }
func (*DevicesRevoked) Unwrap() error { return domain.ErrDevicesChanged }

// RegisterDeviceNew is RegisterDevice that also reports whether the device is new to the account
// (the caller then tells the owner's other devices).
func (s *Store) RegisterDeviceNew(ctx context.Context, d domain.Device) (domain.Device, bool, error) {
	created := false
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var active bool
		if err := tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, d.UserID).Scan(&active); err != nil || !active {
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
			// The device now belongs to the session that registered it last (a sign-in on the same phone).
			_, err = tx.Exec(ctx, `UPDATE devices SET last_seen_at=now(),display_name=$2,platform=$3,session_id=coalesce(NULLIF($4,'')::uuid,session_id) WHERE device_id=$1`, d.DeviceID, d.DisplayName, d.Platform, d.SessionID)
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
		if _, err = tx.Exec(ctx, `INSERT INTO devices(device_id,user_id,identity_key,signing_key,signature,platform,display_name,session_id) VALUES($1,$2,$3,$4,$5,$6,$7,NULLIF($8,'')::uuid)`, d.DeviceID, d.UserID, d.IdentityKey, d.SigningKey, d.Signature, d.Platform, d.DisplayName, d.SessionID); err != nil {
			return err
		}
		created = true
		return nil
	})
	if err != nil {
		return d, false, err
	}
	registered, err := s.device(ctx, d.UserID, d.DeviceID)
	return registered, created, err
}

// RevokeStaleDevices revokes at most batch active devices not seen for olderThan, drops their
// unclaimed keys and undelivered ciphertext, and so frees the per-account device cap. A device
// that comes back after this gets 404 from the inbox and registers a fresh identity.
func (s *Store) RevokeStaleDevices(ctx context.Context, olderThan time.Duration, batch int) (int64, error) {
	var total int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `UPDATE devices SET revoked_at=now(),push_provider=NULL,push_token=NULL WHERE device_id IN (
 SELECT device_id FROM devices WHERE revoked_at IS NULL AND last_seen_at<now()-$1::interval ORDER BY last_seen_at LIMIT $2 FOR UPDATE SKIP LOCKED) RETURNING device_id::text`, olderThan, batch)
		if err != nil {
			return err
		}
		ids := []string{}
		for rows.Next() {
			var id string
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err = rows.Err(); err != nil || len(ids) == 0 {
			return err
		}
		if err = dropDeviceMaterial(ctx, tx, ids); err != nil {
			return err
		}
		total = int64(len(ids))
		return nil
	})
	return total, err
}

// dropDeviceMaterial deletes what a revoked device must not keep on the relay: its unclaimed keys and the
// ciphertext nobody has picked up.
func dropDeviceMaterial(ctx context.Context, tx pgx.Tx, ids []string) error {
	for _, statement := range []string{
		`DELETE FROM one_time_keys WHERE device_id=ANY($1::uuid[])`,
		`DELETE FROM fallback_keys WHERE device_id=ANY($1::uuid[])`,
		`DELETE FROM message_envelopes WHERE recipient_device_id=ANY($1::uuid[]) AND delivered_at IS NULL`,
	} {
		if _, err := tx.Exec(ctx, statement, ids); err != nil {
			return err
		}
	}
	return nil
}

// RevokeBackloggedDevices revokes at most batch active devices that hold more than half of cap undelivered
// envelopes and have not polled for idle (CHAT-N1): a device that is nearly full and silent is on its way to
// refusing its owner's inbound chat, so it goes before it does. Like any revocation it drops the keys and the
// ciphertext and frees the device slot; it is recorded as removed ("inactive") so the owner's other devices
// show it.
func (s *Store) RevokeBackloggedDevices(ctx context.Context, cap int, idle time.Duration, batch int) (int64, error) {
	if cap <= 0 {
		return 0, nil
	}
	var total int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `UPDATE devices SET revoked_at=now(),push_provider=NULL,push_token=NULL,revoked_by_other=true,revoked_reason='inactive' WHERE device_id IN (
 SELECT d.device_id FROM devices d WHERE d.revoked_at IS NULL AND d.last_seen_at<now()-$1::interval
 AND (SELECT count(*) FROM (SELECT 1 FROM message_envelopes WHERE recipient_device_id=d.device_id AND delivered_at IS NULL LIMIT $2) q)>=$2
 ORDER BY d.last_seen_at LIMIT $3 FOR UPDATE OF d SKIP LOCKED) RETURNING device_id::text`, idle, cap/2+1, batch)
		if err != nil {
			return err
		}
		ids := []string{}
		for rows.Next() {
			var id string
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err = rows.Err(); err != nil || len(ids) == 0 {
			return err
		}
		total = int64(len(ids))
		return dropDeviceMaterial(ctx, tx, ids)
	})
	return total, err
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

// RevokeDevice drops the device's unclaimed keys and undelivered ciphertext. bySession is the auth session that
// asks for it: when that is not the session the device registered under (another phone of the account, or a
// stolen credential), the removal is recorded in revoked_by_other so the owner's remaining devices can show it
// (RemovedDevices), also when they missed the realtime signal. It reports that fact so the caller can push, and
// the device that session registered (callerDevice, "" when none), which already knows and gets no push (CHAT-N7).
func (s *Store) RevokeDevice(ctx context.Context, user, id, bySession string) (byOther bool, callerDevice string, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=now(),push_provider=NULL,push_token=NULL,
 revoked_by_other=(session_id IS DISTINCT FROM NULLIF($3,'')::uuid) WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL`, id, user, bySession)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		if err = dropDeviceMaterial(ctx, tx, []string{id}); err != nil {
			return err
		}
		if bySession != "" {
			// The device registered under the asking session, if it is still active (none: the caller has no chat
			// device, or it is the one just revoked).
			err = tx.QueryRow(ctx, `SELECT device_id::text FROM devices WHERE user_id=$1 AND session_id=$2::uuid AND revoked_at IS NULL ORDER BY created_at LIMIT 1`, user, bySession).Scan(&callerDevice)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		return tx.QueryRow(ctx, `SELECT revoked_by_other FROM devices WHERE device_id=$1`, id).Scan(&byOther)
	})
	return byOther, callerDevice, err
}

// RemovedDevice is a device of the account that someone other than its own session removed.
type RemovedDevice struct {
	DeviceID  string    `json:"deviceId"`
	RemovedAt time.Time `json:"removedAt"`
	// Reason is "inactive" when the relay removed a device that had stopped polling while its backlog grew
	// (CHAT-N1), omitted for a removal by one of the owner's other sessions.
	Reason string `json:"reason,omitempty"`
}

// RemovedWindow is how long a removal stays listed.
const RemovedWindow = 30 * 24 * time.Hour

// RemovedDevices lists the account's devices removed by another session in the last RemovedWindow, newest
// first (at most 20). Only the owner reads it; it names ids and times, nothing else.
func (s *Store) RemovedDevices(ctx context.Context, user string) ([]RemovedDevice, error) {
	rows, err := s.Pool.Query(ctx, `SELECT device_id::text,revoked_at,coalesce(revoked_reason,'') FROM devices WHERE user_id=$1 AND revoked_by_other AND revoked_at>now()-$2::interval ORDER BY revoked_at DESC LIMIT 20`, user, RemovedWindow)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (RemovedDevice, error) {
		var r RemovedDevice
		return r, row.Scan(&r.DeviceID, &r.RemovedAt, &r.Reason)
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
		// The same key id twice in one request, or one the device already holds, adds nothing (ON CONFLICT DO
		// NOTHING below), so neither counts toward the cap (CHAT-N7).
		fresh := make([]domain.OneTimeKey, 0, len(upload.OneTimeKeys))
		seen := map[string]bool{}
		for _, k := range upload.OneTimeKeys {
			if err := k.Validate(user, deviceID, signing); err != nil {
				return err
			}
			if !seen[k.KeyID] {
				seen[k.KeyID] = true
				fresh = append(fresh, k)
			}
		}
		upload.OneTimeKeys = fresh
		if upload.FallbackKey != nil {
			if err := upload.FallbackKey.Validate(user, deviceID, signing); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM one_time_keys WHERE device_id=$1`, deviceID).Scan(&count); err != nil {
			return err
		}
		if len(upload.OneTimeKeys) > 0 {
			ids := make([]string, len(upload.OneTimeKeys))
			for i, k := range upload.OneTimeKeys {
				ids[i] = k.KeyID
			}
			var held int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM one_time_keys WHERE device_id=$1 AND key_id=ANY($2::text[])`, deviceID, ids).Scan(&held); err != nil {
				return err
			}
			if count+len(upload.OneTimeKeys)-held > maxOneTimeKeys {
				return &domain.ValidationError{Field: "oneTimeKeys", Message: "a device holds at most 100 unclaimed keys"}
			}
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

// canMessage applies the target's messagesFrom setting. The default is "everyone": anyone who is
// not blocked, active, onboarded and in the same age band (the barrier above, which behaves like a block) may
// message them, with no friendship or follow needed. "friends", "followers" and "nobody" are
// still honoured for members who set them through the API. Once the target has written in the
// conversation, the actor may always reply.
func canMessage(ctx context.Context, q querier, actor, target string) error {
	if actor == target {
		return &domain.ValidationError{Field: "userId", Message: "choose another account"}
	}
	var visible, replied bool
	err := q.QueryRow(ctx, `SELECT `+memberSQL("$2::uuid")+` AND `+memberSQL("$1::uuid")+` AND NOT `+barredBetween+`,
 EXISTS(SELECT 1 FROM messages m JOIN conversations c USING(conversation_id) WHERE m.sender_id=$2 AND NOT m.aux AND c.user_low_id=least($1::uuid,$2::uuid) AND c.user_high_id=greatest($1::uuid,$2::uuid))`, actor, target).Scan(&visible, &replied)
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
	if policy.MessagesFrom == "everyone" {
		return nil
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

// HaveExchangedMessages reports whether the pair's conversation has ever held a message, in either
// direction. It is what makes opening a conversation a "new contact" for the stricter limiter.
func (s *Store) HaveExchangedMessages(ctx context.Context, a, b string) (bool, error) {
	var exchanged bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM messages m JOIN conversations c USING(conversation_id) WHERE NOT m.aux AND c.user_low_id=least($1::uuid,$2::uuid) AND c.user_high_id=greatest($1::uuid,$2::uuid))`, a, b).Scan(&exchanged)
	return exchanged, err
}

// PeerDevices lists another person's devices only to someone allowed to message them.
func (s *Store) PeerDevices(ctx context.Context, actor, target string) ([]domain.Device, error) {
	if actor != target {
		if err := canMessage(ctx, s.Pool, actor, target); err != nil {
			return nil, err
		}
	}
	list, err := s.devices(ctx, s.Pool, target)
	if actor != target {
		// A display name ("Aditya's iPhone") is for the owner only; a peer needs keys, not names.
		for i := range list {
			list[i].DisplayName = ""
		}
	}
	return list, err
}

// Key claim caps, per rolling hour. A claimer may claim at most ClaimsPerPairHour keys of
// one device (more is 429 KEY_CLAIMS_LIMITED); a device hands out at most
// OneTimeClaimsPerDeviceHour one-time keys to everyone together, after which claimers get
// its fallback key, so nobody can drain a device's one-time keys and nobody can stop
// others from starting a chat with a popular member either.
const (
	ClaimsPerPairHour          = 10
	OneTimeClaimsPerDeviceHour = 100
)

var ErrKeyClaimsLimited = &domain.PolicyError{Status: 429, Code: "KEY_CLAIMS_LIMITED", Message: "Too many key requests for this device. Try again later."}

// ClaimKey hands out each one-time key exactly once; the fallback key is reused
// only when none remain or the device's hourly one-time budget is spent. Claims are
// serialized per device and recorded in key_claims for the caps above.
func (s *Store) ClaimKey(ctx context.Context, actor, target, deviceID string) (domain.ClaimedKey, error) {
	claimed := domain.ClaimedKey{DeviceID: deviceID}
	// Your own other devices are always reachable; anyone else needs messaging access.
	if actor != target {
		if err := canMessage(ctx, s.Pool, actor, target); err != nil {
			return claimed, err
		}
	}
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var locked string
		if err := tx.QueryRow(ctx, `SELECT device_id::text FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL FOR UPDATE`, deviceID, target).Scan(&locked); err != nil {
			return mapped(err)
		}
		var pair, oneTime int
		var wait int64
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE claimer_id=$2),count(*) FILTER (WHERE one_time),
 coalesce(ceil(extract(epoch FROM min(claimed_at) FILTER (WHERE claimer_id=$2)+interval '1 hour'-now())),1)::bigint
 FROM key_claims WHERE device_id=$1 AND claimed_at>now()-interval '1 hour'`, deviceID, actor).Scan(&pair, &oneTime, &wait); err != nil {
			return err
		}
		if pair >= ClaimsPerPairHour {
			// The budget gains a claim when the claimer's oldest claim in the window is an hour old.
			return domain.RetryAfter(ErrKeyClaimsLimited, time.Duration(wait)*time.Second)
		}
		err := pgx.ErrNoRows
		if oneTime < OneTimeClaimsPerDeviceHour {
			err = tx.QueryRow(ctx, `DELETE FROM one_time_keys WHERE (device_id,key_id)=(SELECT device_id,key_id FROM one_time_keys WHERE device_id=$1 ORDER BY created_at,key_id LIMIT 1 FOR UPDATE SKIP LOCKED)
 RETURNING key_id,public_key,signature`, deviceID).Scan(&claimed.KeyID, &claimed.PublicKey, &claimed.Signature)
		}
		if errors.Is(err, pgx.ErrNoRows) {
			claimed.Fallback = true
			err = tx.QueryRow(ctx, `SELECT key_id,public_key,signature FROM fallback_keys WHERE device_id=$1`, deviceID).Scan(&claimed.KeyID, &claimed.PublicKey, &claimed.Signature)
		}
		if err != nil {
			return mapped(err)
		}
		_, err = tx.Exec(ctx, `INSERT INTO key_claims(claimer_id,device_id,one_time) VALUES($1,$2,$3)`, actor, deviceID, !claimed.Fallback)
		return err
	})
	return claimed, err
}

// PurgeKeyClaims deletes at most batch claim records older than a day; the caps look back an hour.
func (s *Store) PurgeKeyClaims(ctx context.Context, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM key_claims WHERE ctid IN (SELECT ctid FROM key_claims WHERE claimed_at<now()-interval '1 day' ORDER BY claimed_at LIMIT $1)`, batch)
	return tag.RowsAffected(), err
}

// receiptsOn is true when both members allow read receipts and neither has
// restricted the other; it is reciprocal.
var receiptsOn = `coalesce((mq.data->>'readReceipts')::boolean,false) AND coalesce((pq.data->>'readReceipts')::boolean,false) AND NOT ` + restrictedPair("m.user_id", "m.peer_id")

// conversationSelect reads the caller's member row ($1) and joins the peer's.
var conversationSelect = `SELECT c.conversation_id::text,c.status,c.created_at,c.last_message_at,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),` + avatarThumbKey("av") + `,
 m.unread_count,m.read_at,CASE WHEN ` + receiptsOn + ` THEN pm.read_at END,m.sort_at,
 CASE WHEN m.muted_until>now() THEN m.muted_until END,coalesce(pq.data->>'onlineAudience','nobody')
 FROM conversation_members m
 JOIN conversations c ON c.conversation_id=m.conversation_id
 JOIN conversation_members pm ON pm.conversation_id=m.conversation_id AND pm.user_id=m.peer_id
 JOIN profiles p ON p.user_id=m.peer_id` + avatarJoin("av", "p") + `
 JOIN users u ON u.user_id=p.user_id AND u.status='active'
 JOIN privacy_settings mq ON mq.user_id=m.user_id
 JOIN privacy_settings pq ON pq.user_id=m.peer_id
 WHERE m.user_id=$1
 AND NOT interaction_barred($1::uuid,p.user_id)`

func scanConversation(row pgx.Row, sign Signer) (domain.Conversation, error) {
	var c domain.Conversation
	var avatar *string
	c.SharedInterests = []string{}
	err := row.Scan(&c.ConversationID, &c.Status, &c.CreatedAt, &c.LastMessageAt, &c.Peer.UserID, &c.Peer.Username, &c.Peer.DisplayName, &avatar, &c.UnreadCount, &c.ReadAt, &c.PeerReadAt, &c.SortAt, &c.MutedUntil, &c.PeerOnlineAudience)
	c.Peer.AvatarURL = avatarURL(sign, avatar)
	return c, mapped(err)
}

// OpenConversation returns the pair's direct conversation, creating or reopening it.
// The peer carries presence (see ConversationPeer and fillPresence), resolved with online, the hub check.
// Creating a conversation (no row yet) counts against the member's daily e.NewConversationsPerDay, after
// the privacy, block and age-band checks; reopening an existing one never does.
func (s *Store) OpenConversation(ctx context.Context, actor, target string, e domain.Entitlements, sign Signer, online Presence) (domain.Conversation, error) {
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
		// Only a pair with no row yet is a new conversation: a closed one (after a block) that is
		// reactivated keeps its creator and its date, so it is a reopening.
		if errors.Is(err, pgx.ErrNoRows) {
			if err := lockQuota(ctx, tx, "chat", actor); err != nil {
				return err
			}
			if err := checkNewChatQuota(ctx, tx, actor, e); err != nil {
				return err
			}
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
	c, err := scanConversation(s.Pool.QueryRow(ctx, conversationSelect+` AND m.peer_id=$2`, actor, target), sign)
	if err != nil {
		return c, err
	}
	c, err = s.withSharedInterests(ctx, actor, c)
	if err != nil {
		return c, err
	}
	return s.withPresence(ctx, actor, c, online)
}

// Conversation is one of the caller's conversations without presence (the realtime typing path only
// needs the peer's id and the status).
func (s *Store) Conversation(ctx context.Context, user, id string, sign Signer) (domain.Conversation, error) {
	c, err := scanConversation(s.Pool.QueryRow(ctx, conversationSelect+` AND m.conversation_id=$2`, user, id), sign)
	if err != nil {
		return c, err
	}
	return s.withSharedInterests(ctx, user, c)
}

// ConversationFor is Conversation as the API serves it: the peer carries presence.
func (s *Store) ConversationFor(ctx context.Context, user, id string, sign Signer, online Presence) (domain.Conversation, error) {
	c, err := s.Conversation(ctx, user, id, sign)
	if err != nil {
		return c, err
	}
	return s.withPresence(ctx, user, c, online)
}

func (s *Store) ListConversations(ctx context.Context, user string, before *time.Time, beforeID string, limit int, sign Signer, online Presence) ([]domain.Conversation, error) {
	rows, err := s.Pool.Query(ctx, conversationSelect+` AND c.status='active'
 AND ($2::timestamptz IS NULL OR (m.sort_at,m.conversation_id)<($2,$3::uuid))
 ORDER BY m.sort_at DESC,m.conversation_id DESC LIMIT $4`, user, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.Conversation{}
	for rows.Next() {
		c, err := scanConversation(rows, sign)
		if err != nil {
			return nil, err
		}
		result = append(result, c)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if err = s.fillSharedInterests(ctx, user, result); err != nil {
		return nil, err
	}
	return result, s.fillPresence(ctx, user, result, online)
}

// SendMessage stores one ciphertext per recipient device. The device set must be
// exactly the peer's devices plus the sender's other devices, so no device is
// silently skipped and none can be injected.
// It returns the peer so callers can signal without another lookup.
// SendMessage relays one message. quiet reports that the peer muted this chat
// or muted/restricted the sender, so no push should be sent.
func (s *Store) SendMessage(ctx context.Context, user, conversationID string, m domain.SendMessage, e domain.Entitlements) (created time.Time, peer string, quiet bool, err error) {
	err = s.Pool.QueryRow(ctx, `SELECT (CASE WHEN user_low_id=$2 THEN user_high_id ELSE user_low_id END)::text FROM conversations WHERE conversation_id=$1 AND $2 IN (user_low_id,user_high_id)`, conversationID, user).Scan(&peer)
	if err != nil {
		return created, "", false, mapped(err)
	}
	var dormant []RevokedDevice
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
		var storedAux bool
		err := tx.QueryRow(ctx, `SELECT sender_id::text,aux FROM messages WHERE message_id=$1`, m.MessageID).Scan(&sender, &storedAux)
		if err == nil {
			if sender != user {
				return &domain.ValidationError{Field: "messageId", Message: "already used"}
			}
			// A replay is answered from the stored row; a reaction stays quiet (no push) on every retry.
			quiet = storedAux
			return tx.QueryRow(ctx, `SELECT created_at FROM messages WHERE message_id=$1`, m.MessageID).Scan(&created)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if err := canMessage(ctx, tx, user, peer); err != nil {
			return err
		}
		// First-contact cap: until the peer has sent a message of their own in this conversation (a reaction
		// or noop of theirs is not one), the sender gets FirstContactMessages messages. Every message counts,
		// those marked aux too: the relay cannot see kinds, so an aux hint would otherwise be a way round the
		// cap (re-audit CHAT-3). Reactions and the noop only make sense once the peer has written, when the
		// cap no longer applies. The cheap test comes first (is there a message of the peer's: one index
		// probe), then a count that stops at the cap, so nothing scans the conversation under the row locks.
		var peerWrote bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=$1 AND sender_id=$2 AND NOT aux)`, conversationID, peer).Scan(&peerWrote); err != nil {
			return err
		}
		if !peerWrote {
			var mine int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM (SELECT 1 FROM messages WHERE conversation_id=$1 AND sender_id=$2 LIMIT $3) q`, conversationID, user, FirstContactMessages).Scan(&mine); err != nil {
				return err
			}
			if mine >= FirstContactMessages {
				return domain.ErrAwaitingReply
			}
		}
		// Daily quota per sender per conversation: every message counts, reactions included. It reads the last
		// 24 hours of this conversation through messages_conversation and stops at the limit.
		if limit := e.ChatMessagesPerConversationPerDay; limit > 0 {
			var sent int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM (SELECT 1 FROM messages WHERE conversation_id=$1 AND created_at>now()-interval '24 hours' AND sender_id=$2 LIMIT $3) q`, conversationID, user, limit).Scan(&sent); err != nil {
				return err
			}
			if sent >= limit {
				var wait int64
				if err := tx.QueryRow(ctx, `SELECT coalesce(ceil(extract(epoch FROM min(created_at)+interval '24 hours'-now())),60)::bigint FROM messages WHERE conversation_id=$1 AND created_at>now()-interval '24 hours' AND sender_id=$2`, conversationID, user).Scan(&wait); err != nil {
					return err
				}
				return domain.RetryAfter(domain.ErrChatDailyLimit, time.Duration(max(wait, 1))*time.Second)
			}
		}
		var senderOK bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL)`, m.SenderDeviceID, user).Scan(&senderOK); err != nil {
			return err
		}
		if !senderOK {
			return domain.ErrNotFound
		}
		rows, err := tx.Query(ctx, `SELECT device_id::text,user_id::text FROM devices WHERE revoked_at IS NULL AND (user_id=$1 OR (user_id=$2 AND device_id<>$3)) ORDER BY device_id`, peer, user, m.SenderDeviceID)
		if err != nil {
			return err
		}
		expected := []string{}
		ownDevice := map[string]bool{}
		deviceOwner := map[string]string{}
		for rows.Next() {
			var id, owner string
			if err = rows.Scan(&id, &owner); err != nil {
				rows.Close()
				return err
			}
			expected = append(expected, id)
			ownDevice[id] = owner == user
			deviceOwner[id] = owner
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
		// Backlog caps. No device holds more than ChatBacklogPerDevice undelivered envelopes, and no one sender
		// has more than ChatBacklogPerSenderPerDevice waiting on one recipient device (so one account cannot
		// fill a victim's device alone; the sender's own other devices are exempt from that second cap, they
		// all belong to one person). Envelopes of senders barred from the device's owner (a block, or the age
		// band) are never delivered (Inbox leaves them out), so they do not count. lockPair holds the row of
		// every account whose devices are named here (the sender's and the peer's) until commit, and every
		// send that stores an envelope for one of them takes that lock, so the counts below cannot be outrun
		// by a concurrent send and the caps are exact. The counts walk envelopes_inbox, partial on
		// undelivered rows, and stop at their cap.
		total, perSender := e.ChatBacklogPerDevice, e.ChatBacklogPerSenderPerDevice
		if total > 0 || perSender > 0 {
			owners := make([]string, len(expected))
			for i, id := range expected {
				owners[i] = deviceOwner[id]
			}
			// A cap of 0 is "off": the count then stops at once and its result is not compared.
			stop := func(limit int) int {
				if limit <= 0 {
					return 1
				}
				return limit
			}
			full, err := tx.Query(ctx, `SELECT d.id::text,
 (SELECT count(*) FROM (SELECT 1 FROM message_envelopes e JOIN messages m ON m.message_id=e.message_id WHERE e.recipient_device_id=d.id AND e.delivered_at IS NULL AND m.sender_id=$3 LIMIT $4) q),
 (SELECT count(*) FROM (SELECT 1 FROM message_envelopes e JOIN messages m ON m.message_id=e.message_id WHERE e.recipient_device_id=d.id AND e.delivered_at IS NULL AND NOT interaction_barred(d.owner,m.sender_id) LIMIT $2) q)
 FROM unnest($1::uuid[],$5::uuid[]) AS d(id,owner)`, expected, stop(total), user, stop(perSender), owners)
			if err != nil {
				return err
			}
			var peerFull, ownFull, senderFull bool
			var overCap []string
			for full.Next() {
				var id string
				var mine, all int
				if err = full.Scan(&id, &mine, &all); err != nil {
					full.Close()
					return err
				}
				switch {
				case total > 0 && all >= total:
					overCap = append(overCap, id)
					if ownDevice[id] {
						ownFull = true
					} else {
						peerFull = true
					}
				case perSender > 0 && !ownDevice[id] && mine >= perSender:
					senderFull = true
				}
			}
			full.Close()
			if err = full.Err(); err != nil {
				return err
			}
			if len(overCap) > 0 {
				// A device that is over the cap and has not polled for DormantDeviceAfter is not coming back soon
				// (a reinstall leaves such a device behind, a phone in a drawer is one): revoke it here, in the
				// send, instead of refusing every message to its owner. The send is answered DEVICES_CHANGED and
				// the client, which already retries once, encrypts for the devices that remain. The revocation
				// commits (this function returns nil); a device that polled in the meantime is left alone.
				gone, err := tx.Query(ctx, `UPDATE devices SET revoked_at=now(),push_provider=NULL,push_token=NULL,revoked_by_other=true,revoked_reason='inactive'
 WHERE device_id=ANY($1::uuid[]) AND revoked_at IS NULL AND last_seen_at<now()-$2::interval RETURNING device_id::text,user_id::text`, overCap, DormantDeviceAfter)
				if err != nil {
					return err
				}
				for gone.Next() {
					var d RevokedDevice
					if err = gone.Scan(&d.DeviceID, &d.UserID); err != nil {
						gone.Close()
						return err
					}
					dormant = append(dormant, d)
				}
				gone.Close()
				if err = gone.Err(); err != nil {
					return err
				}
				if len(dormant) > 0 {
					ids := make([]string, len(dormant))
					for i, d := range dormant {
						ids[i] = d.DeviceID
					}
					return dropDeviceMaterial(ctx, tx, ids)
				}
			}
			switch {
			case peerFull || senderFull:
				return domain.RetryAfter(domain.ErrRecipientBacklog, time.Minute)
			case ownFull:
				return domain.RetryAfter(domain.ErrOwnBacklog, time.Minute)
			}
		}
		if err = tx.QueryRow(ctx, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,aux) VALUES($1,$2,$3,$4,$5) RETURNING created_at`, m.MessageID, conversationID, user, m.SenderDeviceID, m.Aux != "").Scan(&created); err != nil {
			return err
		}
		// Claim the attachments in this transaction: any mismatch rolls the whole message back.
		if len(m.BlobIDs) > 0 {
			if err = linkBlobs(ctx, tx, user, peer, conversationID, m.MessageID, m.BlobIDs, e); err != nil {
				return err
			}
		}
		batch := &pgx.Batch{}
		for _, e := range m.Envelopes {
			batch.Queue(`INSERT INTO message_envelopes(message_id,recipient_device_id,envelope_type,ciphertext) VALUES($1,$2,$3,$4)`, m.MessageID, e.DeviceID, e.Type, e.Ciphertext)
		}
		if err = tx.SendBatch(ctx, batch).Close(); err != nil {
			return err
		}
		if m.Aux != "" {
			// An auxiliary message (a reaction) is delivered but is not a conversation turn: it does not
			// reorder the list (last_message_at, sort_at), is never unread for the peer, and the sender's
			// read pointer stays where it is. It never pushes either, so the caller is told to stay quiet.
			quiet = true
			return nil
		}
		if _, err = tx.Exec(ctx, `UPDATE conversations SET last_message_at=$2 WHERE conversation_id=$1`, conversationID, created); err != nil {
			return err
		}
		// The sender has read up to their own message; the peer has one more unread.
		// Both rows are named by their primary key (conversation_id, user_id): two index probes.
		rows, err = tx.Query(ctx, `UPDATE conversation_members SET sort_at=$2,
 unread_count=CASE WHEN user_id=$3 THEN 0 ELSE unread_count+1 END,
 read_at=CASE WHEN user_id=$3 THEN greatest(read_at,$2) ELSE read_at END
 WHERE conversation_id=$1 AND user_id IN ($3::uuid,$4::uuid)
 RETURNING user_id=$3,coalesce(muted_until>now(),false) OR `+quietFrom("user_id", "$3::uuid"), conversationID, created, user, peer)
		if err != nil {
			return err
		}
		for rows.Next() {
			var sender, silenced bool
			if err = rows.Scan(&sender, &silenced); err != nil {
				break
			}
			if !sender {
				quiet = silenced
			}
		}
		rows.Close()
		if err == nil {
			err = rows.Err()
		}
		return err
	})
	if err == nil && len(dormant) > 0 {
		return time.Time{}, peer, false, &DevicesRevoked{Devices: dormant}
	}
	return created, peer, quiet, err
}

// MarkRead moves the caller's read pointer forward to upTo (never past now) and
// recounts what remains unread. It reports the peer and whether anything changed.
func (s *Store) MarkRead(ctx context.Context, user, conversationID string, upTo time.Time) (peer string, readAt time.Time, changed bool, err error) {
	err = s.Pool.QueryRow(ctx, `UPDATE conversation_members m SET read_at=least($3::timestamptz,now()),
 unread_count=(SELECT count(*) FROM (SELECT 1 FROM messages x WHERE x.conversation_id=m.conversation_id AND x.sender_id<>m.user_id AND NOT x.aux AND x.created_at>least($3::timestamptz,now()) LIMIT 999) q)
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
	err := s.Pool.QueryRow(ctx, `SELECT coalesce(bool_and(coalesce((data->>'readReceipts')::boolean,false)),false) AND count(*)=2 AND NOT `+restrictedPair("$1::uuid", "$2::uuid")+` AND NOT `+barredBetween+`
 FROM privacy_settings WHERE user_id IN ($1,$2)`, a, b).Scan(&on)
	return on, err
}

// Unread totals the caller's unread messages across active conversations,
// leaving out muted chats and people the caller restricted.
func (s *Store) Unread(ctx context.Context, user string) (domain.UnreadSummary, error) {
	var u domain.UnreadSummary
	err := s.Pool.QueryRow(ctx, `SELECT coalesce(sum(m.unread_count),0)::int,count(*)::int FROM conversation_members m JOIN conversations c ON c.conversation_id=m.conversation_id
 WHERE m.user_id=$1 AND m.unread_count>0 AND c.status='active' AND (m.muted_until IS NULL OR m.muted_until<=now())
 AND NOT EXISTS(SELECT 1 FROM user_controls rc WHERE rc.actor_id=$1 AND rc.target_id=m.peer_id AND rc.control='restrict')
 AND NOT interaction_barred($1::uuid,m.peer_id)`, user).Scan(&u.Messages, &u.Conversations)
	return u, err
}

// ErrPushTokenInUse answers a token another account already holds. It names nobody.
var ErrPushTokenInUse = &domain.PolicyError{Status: 409, Code: "PUSH_TOKEN_IN_USE", Message: "This push token cannot be used for this device."}

// StalePushHolderAfter is how long another account's device must have been unseen before a push token it holds
// may be handed to the install that presents it (see SetPushToken).
const StalePushHolderAfter = 24 * time.Hour

// SetPushToken attaches a push token to one of the caller's devices. A token
// moved from another of the caller's own devices (reinstall) is detached from
// it first. A token held by a different account is not taken over while that
// holder is alive (that would let one account silence another's pushes, or collect them): the call is
// refused with 409 and logged without the token or the other account.
//
// The one exception is a stale holder: a token is a secret of one install, so the caller presenting it is that
// install, and a device of another account that holds it and has not been seen for StalePushHolderAfter is what
// a previous sign-in on this same phone left behind (it signed out offline, or the app was reinstalled). That
// row is revoked (keys and undelivered ciphertext dropped, like any revocation) and the token is accepted.
// A holder seen within the day, which a phone in use always is (the inbox poll touches last_seen_at every
// five minutes), still refuses.
func (s *Store) SetPushToken(ctx context.Context, user, deviceID, provider, token string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		if token != "" {
			rows, err := tx.Query(ctx, `UPDATE devices SET revoked_at=now(),push_provider=NULL,push_token=NULL
 WHERE push_provider=$1 AND push_token=$2 AND user_id<>$3 AND revoked_at IS NULL AND last_seen_at<now()-$4::interval RETURNING device_id::text`, provider, token, user, StalePushHolderAfter)
			if err != nil {
				return err
			}
			var stale []string
			for rows.Next() {
				var id string
				if err = rows.Scan(&id); err != nil {
					rows.Close()
					return err
				}
				stale = append(stale, id)
			}
			rows.Close()
			if err = rows.Err(); err != nil {
				return err
			}
			if len(stale) > 0 {
				for _, statement := range []string{
					`DELETE FROM one_time_keys WHERE device_id=ANY($1::uuid[])`,
					`DELETE FROM fallback_keys WHERE device_id=ANY($1::uuid[])`,
					`DELETE FROM message_envelopes WHERE recipient_device_id=ANY($1::uuid[]) AND delivered_at IS NULL`,
				} {
					if _, err = tx.Exec(ctx, statement, stale); err != nil {
						return err
					}
				}
				slog.Info("push token held by a stale device of another account; that device was revoked", "device", deviceID, "revoked", len(stale))
			}
			var foreign bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM devices WHERE push_provider=$1 AND push_token=$2 AND user_id<>$3 AND revoked_at IS NULL)`, provider, token, user).Scan(&foreign); err != nil {
				return err
			}
			if foreign {
				slog.Warn("push token held by another account; refused", "device", deviceID)
				return ErrPushTokenInUse
			}
			if _, err := tx.Exec(ctx, `UPDATE devices SET push_provider=NULL,push_token=NULL WHERE push_provider=$1 AND push_token=$2 AND user_id=$4 AND device_id<>$3`, provider, token, deviceID, user); err != nil {
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
	rows, err := s.Pool.Query(ctx, `SELECT m.message_id::text,m.conversation_id::text,m.sender_id::text,m.sender_device_id::text,sd.identity_key,e.envelope_type,e.ciphertext,m.created_at,m.aux
 FROM message_envelopes e JOIN messages m USING(message_id) JOIN devices sd ON sd.device_id=m.sender_device_id
 WHERE e.recipient_device_id=$1 AND e.delivered_at IS NULL
 AND NOT interaction_barred($2::uuid,m.sender_id)
 ORDER BY e.created_at,m.message_id LIMIT $3`, deviceID, user, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []domain.InboxItem{}
	for rows.Next() {
		var i domain.InboxItem
		if err = rows.Scan(&i.MessageID, &i.ConversationID, &i.SenderID, &i.SenderDeviceID, &i.SenderIdentity, &i.Type, &i.Ciphertext, &i.CreatedAt, &i.Aux); err != nil {
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
