package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Group chat (migration 0052, docs/api/29-group-chat.md). A group is a conversation of kind 'group': its messages,
// envelopes, blobs, read pointers and per-member flags are the ordinary ones. This file is the roster: creating a
// group, inviting, accepting, leaving, removing, renaming, the lists, the group send and the clean-ups.
//
// Locking. Every operation that changes or depends on the roster takes the conversation row FOR UPDATE first, then
// the accounts of everyone involved in id order (lockUsers). Direct-chat code takes accounts first and its own
// conversation row second, but never a group's conversation row, so the two orders cannot form a cycle.

// GroupEntitlements is what the group code needs to know about limits that may differ per member.
type GroupEntitlements func(user string) domain.Entitlements

// LimitsOf is the Limits block of a Group for entitlements e.
func limitsOf(e domain.Entitlements) domain.GroupLimits {
	return domain.GroupLimits{MaxMembers: e.GroupMembersMax, InviteExpiryDays: int(domain.GroupInviteTTL / (24 * time.Hour)), NameMax: domain.GroupNameMax, MaxGroupsPerMember: e.GroupsPerMemberMax}
}

// ConversationKind is "direct" or "group"; ErrNotFound for an unknown id.
func (s *Store) ConversationKind(ctx context.Context, id string) (string, error) {
	var kind string
	err := s.Pool.QueryRow(ctx, `SELECT kind FROM conversations WHERE conversation_id=$1`, id).Scan(&kind)
	return kind, mapped(err)
}

// groupHeader is the locked row of a group.
type groupHeader struct {
	status, name, owner string
}

// lockGroup locks a group's conversation row and reads it. ErrNotFound when there is no such group.
func lockGroup(ctx context.Context, tx pgx.Tx, id string) (groupHeader, error) {
	var h groupHeader
	err := tx.QueryRow(ctx, `SELECT c.status,g.name,g.owner_id::text FROM conversations c JOIN chat_groups g ON g.conversation_id=c.conversation_id
 WHERE c.conversation_id=$1 AND c.kind='group' FOR UPDATE OF c`, id).Scan(&h.status, &h.name, &h.owner)
	return h, mapped(err)
}

// lockUsers locks the given accounts in id order (FOR NO KEY UPDATE, like lockPair) and returns the ones that are active
// and have finished onboarding.
func lockUsers(ctx context.Context, tx pgx.Tx, ids []string) (map[string]bool, error) {
	rows, err := tx.Query(ctx, `SELECT u.user_id::text FROM users u JOIN onboarding o ON o.user_id=u.user_id AND o.completed_at IS NOT NULL
 WHERE u.user_id=ANY($1::uuid[]) AND u.status='active' ORDER BY u.user_id FOR NO KEY UPDATE OF u`, ids)
	if err != nil {
		return nil, err
	}
	found := map[string]bool{}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		found[id] = true
	}
	rows.Close()
	return found, rows.Err()
}

func activeMemberIDs(ctx context.Context, q querier, id string) ([]string, error) {
	rows, err := q.Query(ctx, `SELECT user_id::text FROM chat_group_members WHERE conversation_id=$1 AND state='active' ORDER BY user_id`, id)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

func pendingIDs(ctx context.Context, q querier, id string) ([]string, error) {
	rows, err := q.Query(ctx, `SELECT user_id::text FROM chat_group_members WHERE conversation_id=$1 AND state='invited' AND expires_at>now() ORDER BY user_id`, id)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// groupCount is how many open groups the member is in or invited to (an expired invite or a closed group does not count).
func groupCount(ctx context.Context, q querier, user string) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM chat_group_members gm JOIN conversations c ON c.conversation_id=gm.conversation_id
 WHERE gm.user_id=$1 AND c.status='active' AND (gm.state='active' OR gm.expires_at>now())`, user).Scan(&n)
	return n, err
}

// recordGroupEvent appends a membership event.
func recordGroupEvent(ctx context.Context, tx pgx.Tx, group, kind string, actor, subject, message *string, name *string) error {
	_, err := tx.Exec(ctx, `INSERT INTO chat_group_events(event_id,conversation_id,kind,actor_id,subject_id,message_id,name) VALUES($1,$2,$3,$4,$5,$6,$7)`,
		newID(), group, kind, actor, subject, message, name)
	return err
}

func strp(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// closeGroup closes a group: no more messages, pending invites cancelled.
func closeGroup(ctx context.Context, tx pgx.Tx, id string) error {
	tag, err := tx.Exec(ctx, `UPDATE conversations SET status='closed' WHERE conversation_id=$1 AND status<>'closed'`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `DELETE FROM chat_group_members WHERE conversation_id=$1 AND state='invited'`, id); err != nil {
		return err
	}
	return recordGroupEvent(ctx, tx, id, "closed", nil, nil, nil, nil)
}

// closeIfTooSmall closes the group when fewer than two people are active and nobody is left to answer an invite.
// With force (a leave or a removal just took someone out) pending invites do not keep it open.
func closeIfTooSmall(ctx context.Context, tx pgx.Tx, id string, force bool) (closed bool, err error) {
	var active, pending int
	if err = tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE state='active'),count(*) FILTER (WHERE state='invited' AND expires_at>now()) FROM chat_group_members WHERE conversation_id=$1`, id).Scan(&active, &pending); err != nil {
		return false, err
	}
	if active >= 2 || (!force && pending > 0) {
		return false, nil
	}
	return true, closeGroup(ctx, tx, id)
}

// ---- who may be invited

// inviteCheck decides whether inviter may add invitee: the inviter chats with or follows them, the invitee's messagesFrom
// choice, blocks and age band (canMessage), and the invitee's own group limit. A refusal is always CannotAddError.
func inviteCheck(ctx context.Context, tx pgx.Tx, inviter, invitee string, counts map[string]int, limitOf GroupEntitlements) error {
	refuse := &domain.CannotAddError{UserID: invitee}
	var known bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM conversations c WHERE c.kind='direct' AND c.status='active' AND c.user_low_id=least($1::uuid,$2::uuid) AND c.user_high_id=greatest($1::uuid,$2::uuid))
 OR EXISTS(SELECT 1 FROM follows WHERE follower_id=$1 AND followee_id=$2 AND state='active')`, inviter, invitee).Scan(&known); err != nil {
		return err
	}
	if !known {
		return refuse
	}
	if err := canMessage(ctx, tx, inviter, invitee); err != nil {
		var policy *domain.PolicyError
		if errors.Is(err, domain.ErrNotFound) || errors.As(err, &policy) {
			return refuse
		}
		return err
	}
	if counts[invitee] >= limitOf(invitee).GroupsPerMemberMax {
		return refuse
	}
	return nil
}

// inviteesOK checks every new invitee against the inviter, the group's people (active and pending, besides the invitee
// themself) and each other.
func inviteesOK(ctx context.Context, tx pgx.Tx, inviter string, invitees, existing []string, limitOf GroupEntitlements) error {
	counts := map[string]int{}
	rows, err := tx.Query(ctx, `SELECT gm.user_id::text,count(*) FROM chat_group_members gm JOIN conversations c ON c.conversation_id=gm.conversation_id
 WHERE gm.user_id=ANY($1::uuid[]) AND c.status='active' AND (gm.state='active' OR gm.expires_at>now()) GROUP BY gm.user_id`, invitees)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		var n int
		if err = rows.Scan(&id, &n); err != nil {
			rows.Close()
			return err
		}
		counts[id] = n
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, id := range invitees {
		if err = inviteCheck(ctx, tx, inviter, id, counts, limitOf); err != nil {
			return err
		}
	}
	// No block and no age-band difference between any two people who would share the group.
	var a, b string
	err = tx.QueryRow(ctx, `SELECT x.id::text,y.id::text FROM unnest($1::uuid[]) x(id) JOIN unnest($2::uuid[]||$1::uuid[]) y(id) ON x.id<>y.id
 WHERE interaction_barred(x.id,y.id) ORDER BY x.id,y.id LIMIT 1`, invitees, existing).Scan(&a, &b)
	if err == nil {
		// Name the one who is being invited (the other may be a member the inviter cannot see).
		return &domain.CannotAddError{UserID: a}
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	return nil
}

// ---- create, invite, accept, decline

// GroupChange is what a mutation did, for the caller to signal: the accounts whose lists changed.
type GroupChange struct {
	Group  domain.Group
	Notify []string
}

// CreateGroup makes a group with its creator as owner and active member and invites the others.
func (s *Store) CreateGroup(ctx context.Context, creator string, g domain.NewGroup, e domain.Entitlements, limitOf GroupEntitlements, sign Signer) (GroupChange, error) {
	id := newID()
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		all := append([]string{creator}, g.MemberIDs...)
		found, err := lockUsers(ctx, tx, all)
		if err != nil {
			return err
		}
		if !found[creator] {
			return domain.ErrNotFound
		}
		for _, m := range g.MemberIDs {
			if !found[m] || m == creator {
				return &domain.CannotAddError{UserID: m}
			}
		}
		if err = lockQuota(ctx, tx, "group", creator); err != nil {
			return err
		}
		if err = bumpDaily(ctx, tx, creator, domain.DailyGroupsCreated, e.GroupsCreatedPerDay); err != nil {
			return err
		}
		mine, err := groupCount(ctx, tx, creator)
		if err != nil {
			return err
		}
		if mine >= e.GroupsPerMemberMax {
			return domain.ErrGroupLimit
		}
		if len(g.MemberIDs)+1 > e.GroupMembersMax {
			return domain.ErrGroupFull
		}
		for range g.MemberIDs {
			if err = bumpDaily(ctx, tx, creator, domain.DailyGroupInvites, e.GroupInvitesPerDay); err != nil {
				return err
			}
		}
		if err = inviteesOK(ctx, tx, creator, g.MemberIDs, []string{creator}, limitOf); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO conversations(conversation_id,kind,created_by,status) VALUES($1,'group',$2,'active')`, id, creator); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO chat_groups(conversation_id,name,owner_id) VALUES($1,$2,$3)`, id, g.Name, creator); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO chat_group_members(conversation_id,user_id,state,role,invited_by,joined_at) VALUES($1,$2,'active','owner',$2,now())`, id, creator); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at) VALUES($1,$2,NULL,now())`, id, creator); err != nil {
			return err
		}
		for _, m := range g.MemberIDs {
			if _, err = tx.Exec(ctx, `INSERT INTO chat_group_members(conversation_id,user_id,state,invited_by,expires_at) VALUES($1,$2,'invited',$3,now()+$4::interval)`, id, m, creator, domain.GroupInviteTTL); err != nil {
				return err
			}
		}
		return recordGroupEvent(ctx, tx, id, "created", &creator, nil, nil, nil)
	})
	if err != nil {
		return GroupChange{}, err
	}
	grp, err := s.GetGroup(ctx, creator, id, e, sign)
	return GroupChange{Group: grp, Notify: g.MemberIDs}, err
}

// InviteToGroup lets the owner invite more people.
func (s *Store) InviteToGroup(ctx context.Context, owner, id string, userIDs []string, e domain.Entitlements, limitOf GroupEntitlements, sign Signer) (GroupChange, error) {
	var added []string
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		added = nil
		h, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		members, err := activeMemberIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if !contains(members, owner) {
			return domain.ErrNotFound
		}
		if h.owner != owner {
			return domain.ErrGroupNotOwner
		}
		if h.status != "active" {
			return domain.ErrConversationClosed
		}
		pending, err := pendingIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if _, err = lockUsers(ctx, tx, append(append(append([]string{}, members...), pending...), userIDs...)); err != nil {
			return err
		}
		// Expired invites are gone before anything is counted or invited again.
		if _, err = tx.Exec(ctx, `DELETE FROM chat_group_members WHERE conversation_id=$1 AND state='invited' AND expires_at<=now()`, id); err != nil {
			return err
		}
		fresh := []string{}
		for _, u := range userIDs {
			if !contains(members, u) && !contains(pending, u) && u != owner {
				fresh = append(fresh, u)
			}
		}
		if len(fresh) == 0 {
			return nil
		}
		if len(members)+len(pending)+len(fresh) > e.GroupMembersMax {
			return domain.ErrGroupFull
		}
		if err = lockQuota(ctx, tx, "group", owner); err != nil {
			return err
		}
		for range fresh {
			if err = bumpDaily(ctx, tx, owner, domain.DailyGroupInvites, e.GroupInvitesPerDay); err != nil {
				return err
			}
		}
		if err = inviteesOK(ctx, tx, owner, fresh, append(append([]string{}, members...), pending...), limitOf); err != nil {
			return err
		}
		for _, u := range fresh {
			if _, err = tx.Exec(ctx, `INSERT INTO chat_group_members(conversation_id,user_id,state,invited_by,expires_at) VALUES($1,$2,'invited',$3,now()+$4::interval)`, id, u, owner, domain.GroupInviteTTL); err != nil {
				return err
			}
		}
		added = fresh
		return nil
	})
	if err != nil {
		return GroupChange{}, err
	}
	grp, err := s.GetGroup(ctx, owner, id, e, sign)
	return GroupChange{Group: grp, Notify: added}, err
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// AcceptGroupInvite makes an invited person an active member, in the same transaction that stores their encrypted
// join message for everyone already in the group. Anything that stops the join (an expired invite, a group that closed,
// a block since, the person's group limit) is ErrNotFound for the invite, so nothing is revealed.
func (s *Store) AcceptGroupInvite(ctx context.Context, user, id string, control *domain.GroupControl, e domain.Entitlements, sign Signer) (GroupChange, error) {
	var recipients []string
	var dormant []RevokedDevice
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		recipients, dormant = nil, nil
		h, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		var state string
		var expires *time.Time
		if err = tx.QueryRow(ctx, `SELECT state,expires_at FROM chat_group_members WHERE conversation_id=$1 AND user_id=$2`, id, user).Scan(&state, &expires); err != nil {
			return mapped(err)
		}
		if state != "invited" || h.status != "active" || expires == nil || !expires.After(time.Now()) {
			return domain.ErrNotFound
		}
		members, err := activeMemberIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(members) >= e.GroupMembersMax {
			return domain.ErrGroupFull
		}
		if _, err = lockUsers(ctx, tx, append(append([]string{}, members...), user)); err != nil {
			return err
		}
		var barred bool
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM unnest($2::uuid[]) m(id) WHERE interaction_barred($1::uuid,m.id))`, user, members).Scan(&barred); err != nil {
			return err
		}
		if barred {
			return domain.ErrNotFound
		}
		active, err := groupCount(ctx, tx, user)
		if err != nil {
			return err
		}
		// The invite itself is counted in groupCount; accepting does not add a group.
		if active > e.GroupsPerMemberMax {
			return domain.ErrGroupLimit
		}
		var revoked []RevokedDevice
		if revoked, err = storeGroupControl(ctx, tx, user, id, control, members, e); err != nil {
			return err
		}
		if len(revoked) > 0 {
			dormant = revoked
			return nil
		}
		if _, err = tx.Exec(ctx, `UPDATE chat_group_members SET state='active',expires_at=NULL,joined_at=now() WHERE conversation_id=$1 AND user_id=$2`, id, user); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO conversation_members(conversation_id,user_id,peer_id,sort_at) VALUES($1,$2,NULL,now()) ON CONFLICT DO NOTHING`, id, user); err != nil {
			return err
		}
		var mid *string
		if control != nil {
			mid = &control.MessageID
		}
		recipients = members
		return recordGroupEvent(ctx, tx, id, "joined", &user, &user, mid, nil)
	})
	if err == nil && len(dormant) > 0 {
		return GroupChange{}, &DevicesRevoked{Devices: dormant}
	}
	if err != nil {
		return GroupChange{}, err
	}
	grp, err := s.GetGroup(ctx, user, id, e, sign)
	return GroupChange{Group: grp, Notify: recipients}, err
}

// DeclineGroupInvite deletes the caller's invite. The group closes if it is left with fewer than two active
// members and no one else to answer.
func (s *Store) DeclineGroupInvite(ctx context.Context, user, id string) (notify []string, err error) {
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		notify = nil
		if _, err := lockGroup(ctx, tx, id); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM chat_group_members WHERE conversation_id=$1 AND user_id=$2 AND state='invited'`, id, user)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}
		if notify, err = activeMemberIDs(ctx, tx, id); err != nil {
			return err
		}
		_, err = closeIfTooSmall(ctx, tx, id, false)
		return err
	})
	return notify, err
}

// ---- rename, remove, leave

// controlRecipients computes the accounts a control message must be sealed for: members, minus anyone the sender is barred from.
func storeGroupControl(ctx context.Context, tx pgx.Tx, user, group string, control *domain.GroupControl, recipientUsers []string, e domain.Entitlements) ([]RevokedDevice, error) {
	others := make([]string, 0, len(recipientUsers))
	for _, u := range recipientUsers {
		if u != user {
			others = append(others, u)
		}
	}
	senderDevice := ""
	if control != nil {
		senderDevice = control.SenderDeviceID
	}
	expected, owners, err := expectedDevices(ctx, tx, user, senderDevice, others)
	if err != nil {
		return nil, err
	}
	peerDevices := 0
	for _, owner := range owners {
		if owner != user {
			peerDevices++
		}
	}
	if control == nil {
		if peerDevices > 0 {
			return nil, &domain.ValidationError{Field: "control", Message: "send the encrypted membership message"}
		}
		return nil, nil
	}
	var senderOK bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=$1 AND user_id=$2 AND revoked_at IS NULL)`, control.SenderDeviceID, user).Scan(&senderOK); err != nil {
		return nil, err
	}
	if !senderOK {
		return nil, domain.ErrNotFound
	}
	var stored string
	err = tx.QueryRow(ctx, `SELECT sender_id::text FROM messages WHERE message_id=$1`, control.MessageID).Scan(&stored)
	if err == nil {
		return nil, &domain.ValidationError{Field: "messageId", Message: "already used"}
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if len(expected) == 0 || len(control.Envelopes) != len(expected) {
		return nil, domain.ErrDevicesChanged
	}
	got := make([]string, 0, len(control.Envelopes))
	for _, env := range control.Envelopes {
		got = append(got, env.DeviceID)
	}
	sort.Strings(got)
	for i := range got {
		if got[i] != expected[i] {
			return nil, domain.ErrDevicesChanged
		}
	}
	dormant, err := checkGroupBacklog(ctx, tx, user, expected, owners, e)
	if err != nil || len(dormant) > 0 {
		return dormant, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,aux) VALUES($1,$2,$3,$4,true)`, control.MessageID, group, user, control.SenderDeviceID); err != nil {
		return nil, err
	}
	return nil, insertEnvelopes(ctx, tx, control.MessageID, control.Envelopes)
}

func insertEnvelopes(ctx context.Context, tx pgx.Tx, messageID string, envelopes []domain.Envelope) error {
	batch := &pgx.Batch{}
	for _, env := range envelopes {
		batch.Queue(`INSERT INTO message_envelopes(message_id,recipient_device_id,envelope_type,ciphertext) VALUES($1,$2,$3,$4)`, messageID, env.DeviceID, env.Type, env.Ciphertext)
	}
	return tx.SendBatch(ctx, batch).Close()
}

// expectedDevices lists the active devices a message from user (sending from senderDevice) must be sealed for: every
// device of each of others the sender is not barred from, and the sender's other devices. It returns the device ids in
// order and their owners.
func expectedDevices(ctx context.Context, tx pgx.Tx, user, senderDevice string, others []string) ([]string, map[string]string, error) {
	var sender any
	if senderDevice != "" {
		sender = senderDevice
	}
	rows, err := tx.Query(ctx, `SELECT d.device_id::text,d.user_id::text FROM devices d JOIN users u ON u.user_id=d.user_id AND u.status='active'
 WHERE d.revoked_at IS NULL AND ((d.user_id=ANY($1::uuid[]) AND NOT interaction_barred($2::uuid,d.user_id)) OR (d.user_id=$2::uuid AND d.device_id IS DISTINCT FROM $3::uuid))
 ORDER BY d.device_id`, others, user, sender)
	if err != nil {
		return nil, nil, err
	}
	var expected []string
	owners := map[string]string{}
	for rows.Next() {
		var id, owner string
		if err = rows.Scan(&id, &owner); err != nil {
			rows.Close()
			return nil, nil, err
		}
		expected = append(expected, id)
		owners[id] = owner
	}
	rows.Close()
	return expected, owners, rows.Err()
}

// checkGroupBacklog applies the relay's backlog caps to a group send exactly as a direct send does: no device holds more than
// ChatBacklogPerDevice undelivered envelopes and no one sender more than ChatBacklogPerSenderPerDevice on one device.
// A dormant device found at its cap is revoked in this transaction (the caller then answers DEVICES_CHANGED).
func checkGroupBacklog(ctx context.Context, tx pgx.Tx, user string, expected []string, owners map[string]string, e domain.Entitlements) ([]RevokedDevice, error) {
	total, perSender := e.ChatBacklogPerDevice, e.ChatBacklogPerSenderPerDevice
	if total <= 0 && perSender <= 0 {
		return nil, nil
	}
	counts, err := backlogCounts(ctx, tx, user, expected, owners, total, perSender)
	if err != nil {
		return nil, err
	}
	var peerFull, ownFull, senderFull bool
	var overCap, senderFullIDs []string
	for _, id := range expected {
		c := counts[id]
		own := owners[id] == user
		if total > 0 && c.all >= total {
			overCap = append(overCap, id)
			if own {
				ownFull = true
			} else {
				peerFull = true
			}
		}
		if perSender > 0 && !own && c.mine >= perSender {
			senderFull = true
			senderFullIDs = append(senderFullIDs, id)
		}
	}
	if len(overCap) > 0 || len(senderFullIDs) > 0 {
		dormant, err := revokeDormant(ctx, tx, overCap, senderFullIDs)
		if err != nil {
			return nil, err
		}
		if len(dormant) > 0 {
			return dormant, nil
		}
	}
	switch {
	case peerFull || senderFull:
		return nil, domain.RetryAfter(domain.ErrRecipientBacklog, time.Minute)
	case ownFull:
		return nil, domain.RetryAfter(domain.ErrOwnBacklog, time.Minute)
	}
	return nil, nil
}

// RenameGroup lets the owner rename the group; control is the encrypted rename message for everyone in it.
func (s *Store) RenameGroup(ctx context.Context, owner, id, name string, control *domain.GroupControl, e domain.Entitlements, sign Signer) (GroupChange, error) {
	var members []string
	var dormant []RevokedDevice
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		members, dormant = nil, nil
		h, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		if members, err = activeMemberIDs(ctx, tx, id); err != nil {
			return err
		}
		if !contains(members, owner) {
			return domain.ErrNotFound
		}
		if h.owner != owner {
			return domain.ErrGroupNotOwner
		}
		if h.status != "active" {
			return domain.ErrConversationClosed
		}
		if _, err = lockUsers(ctx, tx, members); err != nil {
			return err
		}
		if dormant, err = storeGroupControl(ctx, tx, owner, id, control, members, e); err != nil || len(dormant) > 0 {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE chat_groups SET name=$2 WHERE conversation_id=$1`, id, name); err != nil {
			return err
		}
		var mid *string
		if control != nil {
			mid = &control.MessageID
		}
		return recordGroupEvent(ctx, tx, id, "renamed", &owner, nil, mid, &name)
	})
	if err == nil && len(dormant) > 0 {
		return GroupChange{}, &DevicesRevoked{Devices: dormant}
	}
	if err != nil {
		return GroupChange{}, err
	}
	grp, err := s.GetGroup(ctx, owner, id, e, sign)
	return GroupChange{Group: grp, Notify: members}, err
}

// dropMember deletes a member's rows of a group and the ciphertext still waiting for their devices (except the control
// message that tells them, keep).
func dropMember(ctx context.Context, tx pgx.Tx, group, user, keep string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM chat_group_members WHERE conversation_id=$1 AND user_id=$2`, group, user); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, group, user); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM message_envelopes e USING messages m, devices d
 WHERE e.message_id=m.message_id AND e.recipient_device_id=d.device_id AND m.conversation_id=$1 AND d.user_id=$2 AND e.delivered_at IS NULL
 AND (NULLIF($3::text,'') IS NULL OR m.message_id::text<>$3::text)`, group, user, keep)
	return err
}

// RemoveGroupMember lets the owner remove an active member (control: the encrypted removal message for everyone in
// the group, the removed person included) or cancel a pending invite (no control).
func (s *Store) RemoveGroupMember(ctx context.Context, owner, id, subject string, control *domain.GroupControl, e domain.Entitlements, sign Signer) (GroupChange, error) {
	var members []string
	var dormant []RevokedDevice
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		members, dormant = nil, nil
		h, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		if members, err = activeMemberIDs(ctx, tx, id); err != nil {
			return err
		}
		if !contains(members, owner) {
			return domain.ErrNotFound
		}
		if h.owner != owner {
			return domain.ErrGroupNotOwner
		}
		if subject == owner {
			return &domain.ValidationError{Field: "userId", Message: "use leave to leave the group"}
		}
		if !contains(members, subject) {
			// A pending invite is cancelled; nobody else knew of it.
			tag, err := tx.Exec(ctx, `DELETE FROM chat_group_members WHERE conversation_id=$1 AND user_id=$2 AND state='invited'`, id, subject)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return domain.ErrNotFound
			}
			_, err = closeIfTooSmall(ctx, tx, id, false)
			return err
		}
		if h.status != "active" {
			return domain.ErrConversationClosed
		}
		if _, err = lockUsers(ctx, tx, members); err != nil {
			return err
		}
		if dormant, err = storeGroupControl(ctx, tx, owner, id, control, members, e); err != nil || len(dormant) > 0 {
			return err
		}
		keep := ""
		var mid *string
		if control != nil {
			keep, mid = control.MessageID, &control.MessageID
		}
		if err = dropMember(ctx, tx, id, subject, keep); err != nil {
			return err
		}
		if err = recordGroupEvent(ctx, tx, id, "removed", &owner, &subject, mid, nil); err != nil {
			return err
		}
		_, err = closeIfTooSmall(ctx, tx, id, true)
		return err
	})
	if err == nil && len(dormant) > 0 {
		return GroupChange{}, &DevicesRevoked{Devices: dormant}
	}
	if err != nil {
		return GroupChange{}, err
	}
	grp, err := s.GetGroup(ctx, owner, id, e, sign)
	return GroupChange{Group: grp, Notify: members}, err
}

// LeaveGroup removes the caller from the group. The owner names newOwner when two or more others remain.
func (s *Store) LeaveGroup(ctx context.Context, user, id, newOwner string, control *domain.GroupControl, e domain.Entitlements) (notify []string, err error) {
	var dormant []RevokedDevice
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		notify, dormant = nil, nil
		h, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		members, err := activeMemberIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if !contains(members, user) {
			return domain.ErrNotFound
		}
		others := 0
		for _, m := range members {
			if m != user {
				others++
			}
		}
		if h.owner == user && others >= 2 {
			if newOwner == "" || newOwner == user || !contains(members, newOwner) {
				return &domain.ValidationError{Field: "newOwnerId", Message: "choose who takes over the group"}
			}
		}
		if _, err = lockUsers(ctx, tx, members); err != nil {
			return err
		}
		recipients := members
		if h.status != "active" {
			// Nobody is left to tell in a closed group.
			recipients, control = nil, nil
		}
		if dormant, err = storeGroupControl(ctx, tx, user, id, control, recipients, e); err != nil || len(dormant) > 0 {
			return err
		}
		keep := ""
		var mid *string
		if control != nil {
			keep, mid = control.MessageID, &control.MessageID
		}
		if err = dropMember(ctx, tx, id, user, keep); err != nil {
			return err
		}
		if err = recordGroupEvent(ctx, tx, id, "left", &user, &user, mid, nil); err != nil {
			return err
		}
		notify = others2(members, user)
		closed, err := closeIfTooSmall(ctx, tx, id, true)
		if err != nil || closed {
			return err
		}
		if h.owner == user {
			if _, err = tx.Exec(ctx, `UPDATE chat_groups SET owner_id=$2 WHERE conversation_id=$1`, id, newOwner); err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `UPDATE chat_group_members SET role=CASE WHEN user_id=$2 THEN 'owner' ELSE 'member' END WHERE conversation_id=$1 AND state='active'`, id, newOwner); err != nil {
				return err
			}
			return recordGroupEvent(ctx, tx, id, "owner_changed", &user, &newOwner, nil, nil)
		}
		return nil
	})
	if err == nil && len(dormant) > 0 {
		return nil, &DevicesRevoked{Devices: dormant}
	}
	return notify, err
}

func others2(members []string, user string) []string {
	var out []string
	for _, m := range members {
		if m != user {
			out = append(out, m)
		}
	}
	return out
}

// ---- reading groups

const groupColumns = `c.conversation_id::text,c.status,c.created_at,c.last_message_at,g.name,g.owner_id::text,gm.state,
 coalesce(m.unread_count,0),m.read_at,CASE WHEN m.muted_until>now() THEN m.muted_until END,m.pinned_at,m.hidden_at,coalesce(m.sort_at,c.created_at)`

const groupFrom = ` FROM conversations c JOIN chat_groups g ON g.conversation_id=c.conversation_id
 JOIN chat_group_members gm ON gm.conversation_id=c.conversation_id AND gm.user_id=$1 AND (gm.state='active' OR gm.expires_at>now())
 LEFT JOIN conversation_members m ON m.conversation_id=c.conversation_id AND m.user_id=$1
 WHERE c.kind='group'`

// groupsWhere runs a group query for viewer ($1; more arguments follow) and fills in members, pending invites and limits.
func (s *Store) groupsWhere(ctx context.Context, viewer string, e domain.Entitlements, sign Signer, suffix string, args ...any) ([]domain.Group, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+groupColumns+groupFrom+suffix, append([]any{viewer}, args...)...)
	if err != nil {
		return nil, err
	}
	var groups []domain.Group
	for rows.Next() {
		var g domain.Group
		if err = rows.Scan(&g.GroupID, &g.Status, &g.CreatedAt, &g.LastMessageAt, &g.Name, &g.OwnerID, &g.MyState, &g.UnreadCount, &g.ReadAt, &g.MutedUntil, &g.PinnedAt, &g.HiddenAt, &g.SortAt); err != nil {
			rows.Close()
			return nil, err
		}
		g.ConversationID, g.Kind = g.GroupID, "group"
		g.Members, g.Pending, g.Limits = []domain.GroupMember{}, []domain.GroupPending{}, limitsOf(e)
		if g.HiddenAt != nil {
			until := g.HiddenAt.Add(domain.HiddenChatRetention)
			g.RestoreUntil = &until
		}
		groups = append(groups, g)
	}
	rows.Close()
	if err = rows.Err(); err != nil || len(groups) == 0 {
		return groups, err
	}
	ids := make([]string, len(groups))
	index := map[string]int{}
	for i, g := range groups {
		ids[i] = g.GroupID
		index[g.GroupID] = i
	}
	mrows, err := s.Pool.Query(ctx, `SELECT gm.conversation_id::text,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,gm.role,gm.joined_at
 FROM chat_group_members gm JOIN users u ON u.user_id=gm.user_id AND u.status='active'
 JOIN profiles p ON p.user_id=gm.user_id`+avatarJoin("av", "p")+`
 WHERE gm.conversation_id=ANY($2::uuid[]) AND gm.state='active' AND NOT interaction_barred($1::uuid,gm.user_id)
 ORDER BY gm.conversation_id,gm.joined_at,gm.user_id`, viewer, ids)
	if err != nil {
		return nil, err
	}
	for mrows.Next() {
		var gid string
		var m domain.GroupMember
		var avatar *string
		if err = mrows.Scan(&gid, &m.UserID, &m.Username, &m.DisplayName, &avatar, &m.Role, &m.JoinedAt); err != nil {
			mrows.Close()
			return nil, err
		}
		m.AvatarURL = avatarURL(sign, avatar)
		g := &groups[index[gid]]
		g.Members = append(g.Members, m)
	}
	mrows.Close()
	if err = mrows.Err(); err != nil {
		return nil, err
	}
	prows, err := s.Pool.Query(ctx, `SELECT gm.conversation_id::text,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,gm.invited_at,gm.expires_at
 FROM chat_group_members gm JOIN users u ON u.user_id=gm.user_id AND u.status='active'
 JOIN profiles p ON p.user_id=gm.user_id`+avatarJoin("av", "p")+`
 WHERE gm.conversation_id=ANY($2::uuid[]) AND gm.state='invited' AND gm.expires_at>now() AND NOT interaction_barred($1::uuid,gm.user_id)
 ORDER BY gm.conversation_id,gm.invited_at,gm.user_id`, viewer, ids)
	if err != nil {
		return nil, err
	}
	for prows.Next() {
		var gid string
		var p domain.GroupPending
		var avatar *string
		if err = prows.Scan(&gid, &p.UserID, &p.Username, &p.DisplayName, &avatar, &p.InvitedAt, &p.ExpiresAt); err != nil {
			prows.Close()
			return nil, err
		}
		p.AvatarURL = avatarURL(sign, avatar)
		g := &groups[index[gid]]
		if g.MyState == "active" {
			g.Pending = append(g.Pending, p)
		}
	}
	prows.Close()
	if err = prows.Err(); err != nil {
		return nil, err
	}
	for i := range groups {
		groups[i].MemberCount = len(groups[i].Members)
	}
	return groups, nil
}

// ListGroups is the caller's groups that are not deleted from their list: pinned first, then newest activity first.
func (s *Store) ListGroups(ctx context.Context, user string, e domain.Entitlements, sign Signer) ([]domain.Group, error) {
	groups, err := s.groupsWhere(ctx, user, e, sign, ` AND gm.state='active' AND m.hidden_at IS NULL
 ORDER BY (m.pinned_at IS NOT NULL) DESC,m.sort_at DESC,c.conversation_id DESC LIMIT 200`)
	if groups == nil && err == nil {
		groups = []domain.Group{}
	}
	return groups, err
}

// HiddenGroups is the caller's deleted groups still inside their 30 days, most recently deleted first.
func (s *Store) HiddenGroups(ctx context.Context, user string, e domain.Entitlements, sign Signer) ([]domain.Group, error) {
	groups, err := s.groupsWhere(ctx, user, e, sign, ` AND gm.state='active' AND m.hidden_at IS NOT NULL AND m.closed_at IS NULL AND m.hidden_at>now()-interval '30 days'
 ORDER BY m.hidden_at DESC,c.conversation_id DESC LIMIT 100`)
	if groups == nil && err == nil {
		groups = []domain.Group{}
	}
	return groups, err
}

// GetGroup is one group for a member (with the newest membership events) or an invited person (without them).
func (s *Store) GetGroup(ctx context.Context, user, id string, e domain.Entitlements, sign Signer) (domain.Group, error) {
	groups, err := s.groupsWhere(ctx, user, e, sign, ` AND c.conversation_id=$2`, id)
	if err != nil {
		return domain.Group{}, err
	}
	if len(groups) == 0 {
		return domain.Group{}, domain.ErrNotFound
	}
	g := groups[0]
	if g.MyState != "active" {
		g.Pending, g.Events = []domain.GroupPending{}, nil
		return g, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT event_id::text,kind,actor_id::text,subject_id::text,message_id::text,name,created_at FROM chat_group_events
 WHERE conversation_id=$2 AND (actor_id IS NULL OR NOT interaction_barred($1::uuid,actor_id)) AND (subject_id IS NULL OR NOT interaction_barred($1::uuid,subject_id))
 ORDER BY created_at DESC,event_id DESC LIMIT $3`, user, id, domain.GroupEventsShown)
	if err != nil {
		return g, err
	}
	events, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.GroupEvent, error) {
		var ev domain.GroupEvent
		return ev, row.Scan(&ev.EventID, &ev.Kind, &ev.ActorID, &ev.SubjectID, &ev.MessageID, &ev.Name, &ev.At)
	})
	if err != nil {
		return g, err
	}
	// Oldest first.
	for i, j := 0, len(events)-1; i < j; i, j = i+1, j-1 {
		events[i], events[j] = events[j], events[i]
	}
	if events == nil {
		events = []domain.GroupEvent{}
	}
	g.Events = events
	return g, nil
}

// GroupInvites lists the caller's pending, still acceptable invites, newest first.
func (s *Store) GroupInvites(ctx context.Context, user string, sign Signer) ([]domain.GroupInvite, error) {
	rows, err := s.Pool.Query(ctx, `SELECT c.conversation_id::text,g.name,gm.invited_at,gm.expires_at,
 ip.user_id::text,ip.username,coalesce(ip.data->>'displayName',''),`+avatarThumbKey("iav")+`
 FROM chat_group_members gm JOIN conversations c ON c.conversation_id=gm.conversation_id AND c.kind='group' AND c.status='active'
 JOIN chat_groups g ON g.conversation_id=c.conversation_id
 JOIN profiles ip ON ip.user_id=gm.invited_by`+avatarJoin("iav", "ip")+`
 JOIN users iu ON iu.user_id=gm.invited_by AND iu.status='active'
 WHERE gm.user_id=$1 AND gm.state='invited' AND gm.expires_at>now() AND NOT interaction_barred($1::uuid,gm.invited_by)
 AND NOT EXISTS(SELECT 1 FROM chat_group_members a WHERE a.conversation_id=c.conversation_id AND a.state='active' AND interaction_barred($1::uuid,a.user_id))
 ORDER BY gm.invited_at DESC,c.conversation_id DESC LIMIT 100`, user)
	if err != nil {
		return nil, err
	}
	var invites []domain.GroupInvite
	for rows.Next() {
		var in domain.GroupInvite
		var avatar *string
		if err = rows.Scan(&in.GroupID, &in.Name, &in.InvitedAt, &in.ExpiresAt, &in.InvitedBy.UserID, &in.InvitedBy.Username, &in.InvitedBy.DisplayName, &avatar); err != nil {
			rows.Close()
			return nil, err
		}
		in.InvitedBy.AvatarURL = avatarURL(sign, avatar)
		in.Members = []domain.UserSummary{}
		invites = append(invites, in)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if invites == nil {
		return []domain.GroupInvite{}, nil
	}
	ids := make([]string, len(invites))
	index := map[string]int{}
	for i, in := range invites {
		ids[i] = in.GroupID
		index[in.GroupID] = i
	}
	mrows, err := s.Pool.Query(ctx, `SELECT gm.conversation_id::text,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`
 FROM chat_group_members gm JOIN users u ON u.user_id=gm.user_id AND u.status='active' JOIN profiles p ON p.user_id=gm.user_id`+avatarJoin("av", "p")+`
 WHERE gm.conversation_id=ANY($1::uuid[]) AND gm.state='active' ORDER BY gm.conversation_id,gm.joined_at,gm.user_id`, ids)
	if err != nil {
		return nil, err
	}
	for mrows.Next() {
		var gid string
		var u domain.UserSummary
		var avatar *string
		if err = mrows.Scan(&gid, &u.UserID, &u.Username, &u.DisplayName, &avatar); err != nil {
			mrows.Close()
			return nil, err
		}
		u.AvatarURL = avatarURL(sign, avatar)
		in := &invites[index[gid]]
		in.Members = append(in.Members, u)
	}
	mrows.Close()
	if err = mrows.Err(); err != nil {
		return nil, err
	}
	for i := range invites {
		invites[i].MemberCount = len(invites[i].Members)
	}
	return invites, nil
}

// ---- messages

// SendGroupMessage stores one ciphertext per recipient device of a group message. The device set must be exactly the
// devices of every active member the sender is not barred from (except the sending device) plus the sender's other devices.
// It returns the accounts to signal and whether the message is quiet (no push).
func (s *Store) SendGroupMessage(ctx context.Context, user, id string, m domain.SendMessage, e domain.Entitlements) (created time.Time, recipients []string, quiet bool, err error) {
	var dormant []RevokedDevice
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		dormant, created, recipients, quiet = nil, time.Time{}, nil, false
		if SendTxHook != nil {
			if err := SendTxHook("begin"); err != nil {
				return err
			}
		}
		h, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		members, err := activeMemberIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if !contains(members, user) {
			return domain.ErrNotFound
		}
		found, err := lockUsers(ctx, tx, members)
		if err != nil {
			return err
		}
		if !found[user] {
			return domain.ErrNotFound
		}
		if h.status != "active" {
			return domain.ErrConversationClosed
		}
		var sender string
		var storedAux bool
		err = tx.QueryRow(ctx, `SELECT sender_id::text,aux FROM messages WHERE message_id=$1`, m.MessageID).Scan(&sender, &storedAux)
		if err == nil {
			if sender != user {
				return &domain.ValidationError{Field: "messageId", Message: "already used"}
			}
			quiet = storedAux
			recipients = others2(members, user)
			return tx.QueryRow(ctx, `SELECT created_at FROM messages WHERE message_id=$1`, m.MessageID).Scan(&created)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if limit := e.ChatMessagesPerConversationPerDay; limit > 0 {
			var sent int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM (SELECT 1 FROM messages WHERE conversation_id=$1 AND created_at>now()-interval '24 hours' AND sender_id=$2 LIMIT $3) q`, id, user, limit).Scan(&sent); err != nil {
				return err
			}
			if sent >= limit {
				var wait int64
				if err := tx.QueryRow(ctx, `SELECT coalesce(ceil(extract(epoch FROM min(created_at)+interval '24 hours'-now())),60)::bigint FROM messages WHERE conversation_id=$1 AND created_at>now()-interval '24 hours' AND sender_id=$2`, id, user).Scan(&wait); err != nil {
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
		expected, owners, err := expectedDevices(ctx, tx, user, m.SenderDeviceID, others2(members, user))
		if err != nil {
			return err
		}
		peerDevices := 0
		reached := map[string]bool{}
		for _, owner := range owners {
			if owner != user {
				peerDevices++
				reached[owner] = true
			}
		}
		if peerDevices == 0 {
			return domain.ErrGroupWaiting
		}
		got := make([]string, 0, len(m.Envelopes))
		for _, env := range m.Envelopes {
			got = append(got, env.DeviceID)
		}
		sort.Strings(got)
		if len(got) != len(expected) {
			return domain.ErrDevicesChanged
		}
		for i := range got {
			if got[i] != expected[i] {
				return domain.ErrDevicesChanged
			}
		}
		if dormant, err = checkGroupBacklog(ctx, tx, user, expected, owners, e); err != nil || len(dormant) > 0 {
			return err
		}
		if err = tx.QueryRow(ctx, `INSERT INTO messages(message_id,conversation_id,sender_id,sender_device_id,aux) VALUES($1,$2,$3,$4,$5) RETURNING created_at`, m.MessageID, id, user, m.SenderDeviceID, m.Aux != "").Scan(&created); err != nil {
			return err
		}
		if len(m.BlobIDs) > 0 {
			if err = claimBlobs(ctx, tx, user, id, m.MessageID, m.BlobIDs, e); err != nil {
				return err
			}
		}
		if err = insertEnvelopes(ctx, tx, m.MessageID, m.Envelopes); err != nil {
			return err
		}
		for u := range reached {
			recipients = append(recipients, u)
		}
		sort.Strings(recipients)
		if m.Aux != "" {
			quiet = true
			return nil
		}
		if _, err = tx.Exec(ctx, `UPDATE conversations SET last_message_at=$2 WHERE conversation_id=$1`, id, created); err != nil {
			return err
		}
		// The sender has read up to their own message; everyone the sender can reach has one more unread, and the chat
		// comes back for any member who had deleted it from their list.
		_, err = tx.Exec(ctx, `UPDATE conversation_members SET sort_at=$2,hidden_at=NULL,closed_at=NULL,
 unread_count=CASE WHEN user_id=$3 THEN 0 ELSE unread_count+1 END,
 read_at=CASE WHEN user_id=$3 THEN greatest(read_at,$2) ELSE read_at END
 WHERE conversation_id=$1 AND (user_id=$3 OR NOT interaction_barred($3::uuid,user_id))`, id, created, user)
		return err
	})
	if err == nil && len(dormant) > 0 {
		return time.Time{}, nil, false, &DevicesRevoked{Devices: dormant}
	}
	return created, recipients, quiet, err
}

// ---- who may reach whom

// sharesGroup reports whether actor may use target's devices and keys because of a group: target is an active member
// of an open group and actor is an active member or has an unexpired invite to it.
func sharesGroup(ctx context.Context, q querier, actor, target string) (bool, error) {
	var shared bool
	err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM chat_group_members t
 JOIN conversations c ON c.conversation_id=t.conversation_id AND c.kind='group' AND c.status='active'
 JOIN chat_group_members a ON a.conversation_id=t.conversation_id AND a.user_id=$1
 WHERE t.user_id=$2 AND t.state='active' AND (a.state='active' OR a.expires_at>now()))`, actor, target).Scan(&shared)
	return shared, err
}

// canReach is canMessage with the group exemption: people who share a group may start the sessions its messages need
// even when the target's messagesFrom choice would refuse a stranger. Blocks, age bands and visibility still apply.
func canReach(ctx context.Context, q querier, actor, target string) error {
	err := canMessage(ctx, q, actor, target)
	if err == nil || !errors.Is(err, domain.ErrMessagesNotAllowed) {
		return err
	}
	shared, serr := sharesGroup(ctx, q, actor, target)
	if serr != nil {
		return serr
	}
	if shared {
		return nil
	}
	return err
}

// ---- clean-up

// ExpireGroupInvites deletes invites past their expiry, at most batch a call, and closes the groups that are left
// with fewer than two active members and no pending invite. It returns the invites deleted.
func (s *Store) ExpireGroupInvites(ctx context.Context, batch int) (int64, error) {
	var total int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		total = 0
		rows, err := tx.Query(ctx, `DELETE FROM chat_group_members WHERE (conversation_id,user_id) IN (
 SELECT conversation_id,user_id FROM chat_group_members WHERE state='invited' AND expires_at<=now() ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED)
 RETURNING conversation_id::text`, batch)
		if err != nil {
			return err
		}
		groups := map[string]bool{}
		for rows.Next() {
			var id string
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			groups[id] = true
			total++
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return err
		}
		for id := range groups {
			// Lock the group before judging it, like every roster change.
			var status string
			if err = tx.QueryRow(ctx, `SELECT status FROM conversations WHERE conversation_id=$1 FOR UPDATE`, id).Scan(&status); err != nil {
				return mapped(err)
			}
			if status != "active" {
				continue
			}
			if _, err = closeIfTooSmall(ctx, tx, id, false); err != nil {
				return err
			}
		}
		return nil
	})
	return total, err
}

// PurgeGroupEvents deletes membership events older than domain.GroupEventRetention, at most batch a call.
func (s *Store) PurgeGroupEvents(ctx context.Context, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM chat_group_events WHERE ctid IN (SELECT ctid FROM chat_group_events WHERE created_at<now()-$1::interval ORDER BY created_at LIMIT $2)`, domain.GroupEventRetention, batch)
	return tag.RowsAffected(), err
}

// purgeGroups takes an account being deleted out of every group it is in or invited to (account.go calls it inside the
// purge). Each group is handled in its own transaction: the person's membership goes, a `member_deleted` event tells the
// others (the person can no longer send a message), the invites they sent are cancelled, the group passes to its
// longest-standing member when they owned it, and it closes when fewer than two active members remain.
func (s *Store) purgeGroups(ctx context.Context, id string) error {
	rows, err := s.Pool.Query(ctx, `SELECT conversation_id::text FROM chat_group_members WHERE user_id=$1 OR invited_by=$1`, id)
	if err != nil {
		return err
	}
	groups, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, group := range groups {
		err = s.purgeTx(ctx, id, func(tx pgx.Tx) error {
			h, err := lockGroup(ctx, tx, group)
			if errors.Is(err, domain.ErrNotFound) {
				return nil
			}
			if err != nil {
				return err
			}
			var state string
			err = tx.QueryRow(ctx, `SELECT state FROM chat_group_members WHERE conversation_id=$1 AND user_id=$2`, group, id).Scan(&state)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			if _, err = tx.Exec(ctx, `DELETE FROM chat_group_members WHERE conversation_id=$1 AND state='invited' AND invited_by=$2 AND user_id<>$2`, group, id); err != nil {
				return err
			}
			if state == "" {
				_, err = closeIfTooSmall(ctx, tx, group, false)
				return err
			}
			if err = dropMember(ctx, tx, group, id, ""); err != nil {
				return err
			}
			if state == "active" {
				if err = recordGroupEvent(ctx, tx, group, "member_deleted", nil, &id, nil, nil); err != nil {
					return err
				}
			}
			closed, err := closeIfTooSmall(ctx, tx, group, state == "active")
			if err != nil || closed || state != "active" || h.owner != id {
				return err
			}
			var successor string
			if err = tx.QueryRow(ctx, `SELECT user_id::text FROM chat_group_members WHERE conversation_id=$1 AND state='active' ORDER BY joined_at,user_id LIMIT 1`, group).Scan(&successor); err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `UPDATE chat_groups SET owner_id=$2 WHERE conversation_id=$1`, group, successor); err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `UPDATE chat_group_members SET role=CASE WHEN user_id=$2 THEN 'owner' ELSE 'member' END WHERE conversation_id=$1 AND state='active'`, group, successor); err != nil {
				return err
			}
			return recordGroupEvent(ctx, tx, group, "owner_changed", nil, &successor, nil, nil)
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// cancelGroupInvitesBetween cancels the invites one of two people sent the other when one blocks the other (the groups
// themselves carry on: the pair stop seeing each other in them), and closes a group that was only waiting on them.
func cancelGroupInvitesBetween(ctx context.Context, tx pgx.Tx, a, b string) error {
	rows, err := tx.Query(ctx, `DELETE FROM chat_group_members WHERE state='invited' AND ((user_id=$1 AND invited_by=$2) OR (user_id=$2 AND invited_by=$1)) RETURNING conversation_id::text`, a, b)
	if err != nil {
		return err
	}
	groups, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, id := range groups {
		if _, err = lockGroup(ctx, tx, id); err != nil {
			return err
		}
		if _, err = closeIfTooSmall(ctx, tx, id, false); err != nil {
			return err
		}
	}
	return nil
}
