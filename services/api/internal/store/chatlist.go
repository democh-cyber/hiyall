package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Pinned chats, deleted ("hidden") chats and their close (migration 0049, docs/api/26-chat-voice-video-and-list.md).
// Every one of them is a column of the caller's own conversation_members row: the peer's row is never touched
// and the peer learns nothing. (A message of the peer's that arrives later clears hidden_at on both rows, in
// SendMessage.)

const (
	// pinnedListCap bounds the pinned chats the first page carries. A member can pin ChatPinsMax, but a chat that
	// was pinned, then became unreachable (a block) and is reachable again can leave more than that visible.
	pinnedListCap = 50
	// HiddenListMax is how many deleted chats the Deleted-chats list returns, ClosedIDsMax how many closed ones.
	HiddenListMax = 100
	ClosedIDsMax  = 200
	// ClosedIDsWindow is how long a closed chat's id stays in the hidden listing, so a device that was offline when
	// the job ran still learns to wipe its local history.
	ClosedIDsWindow = 90 * 24 * time.Hour
)

// ErrPinLimit is the refusal of a pin past the member's ChatPinsMax.
func ErrPinLimit(max int) error {
	return &domain.PolicyError{Status: 409, Code: "PIN_LIMIT", Message: fmt.Sprintf("You can pin up to %d chats", max)}
}

// unhideOwn brings the caller's own row of a conversation back from the Deleted chats (and reopens a closed one).
func unhideOwn(ctx context.Context, tx pgx.Tx, user, conversationID string) error {
	_, err := tx.Exec(ctx, `UPDATE conversation_members SET hidden_at=NULL,closed_at=NULL WHERE conversation_id=$2 AND user_id=$1 AND hidden_at IS NOT NULL`, user, conversationID)
	return err
}

// pinnable is the chats of the caller that are in their visible list (what conversationSelect shows, not hidden,
// the conversation active); it is what the pin limit counts, so a pinned chat that became unreachable frees its slot.
const pinnableSQL = `FROM conversation_members m
 JOIN conversations c ON c.conversation_id=m.conversation_id
 WHERE m.user_id=$1 AND c.status='active' AND m.hidden_at IS NULL
 AND (c.kind='group' OR EXISTS(SELECT 1 FROM users u WHERE u.user_id=m.peer_id AND u.status='active') AND NOT interaction_barred($1::uuid,m.peer_id))`

// SetConversationPin pins or unpins the caller's side of a conversation and returns pinned_at (nil when unpinned).
// Pinning needs a chat in the caller's visible list (otherwise ErrNotFound, whatever the reason) and is idempotent:
// pinning a pinned chat keeps its pinned_at. At most e.ChatPinsMax chats are pinned: the count and the update are
// one transaction under the member's own lock, so two pins at the same time cannot both pass at max-1.
// Unpinning is allowed on any chat of the caller.
func (s *Store) SetConversationPin(ctx context.Context, user, conversationID string, pinned bool, e domain.Entitlements) (*time.Time, error) {
	var at *time.Time
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		at = nil
		if err := lockQuota(ctx, tx, "chatpin", user); err != nil {
			return err
		}
		if !pinned {
			tag, err := tx.Exec(ctx, `UPDATE conversation_members SET pinned_at=NULL WHERE user_id=$1 AND conversation_id=$2`, user, conversationID)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return domain.ErrNotFound
			}
			return nil
		}
		var current *time.Time
		if err := tx.QueryRow(ctx, `SELECT m.pinned_at `+pinnableSQL+` AND m.conversation_id=$2`, user, conversationID).Scan(&current); err != nil {
			return mapped(err)
		}
		if current != nil {
			at = current
			return nil
		}
		var count int
		if err := tx.QueryRow(ctx, `SELECT count(*) `+pinnableSQL+` AND m.pinned_at IS NOT NULL`, user).Scan(&count); err != nil {
			return err
		}
		if count >= e.ChatPinsMax {
			return ErrPinLimit(e.ChatPinsMax)
		}
		return tx.QueryRow(ctx, `UPDATE conversation_members SET pinned_at=now() WHERE user_id=$1 AND conversation_id=$2 RETURNING pinned_at`, user, conversationID).Scan(&at)
	})
	if err != nil {
		return nil, err
	}
	return at, nil
}

// HideConversation deletes the chat from the caller's list: hidden_at is set (the earlier one is kept when it
// was hidden already), the pin is cleared, the unread count stays. No message, blob or row of the peer is touched.
// Not a member, or a chat already closed (out of the list for good): ErrNotFound.
func (s *Store) HideConversation(ctx context.Context, user, conversationID string) (time.Time, error) {
	var at time.Time
	err := s.Pool.QueryRow(ctx, `UPDATE conversation_members SET hidden_at=coalesce(hidden_at,now()),pinned_at=NULL
 WHERE user_id=$1 AND conversation_id=$2 AND closed_at IS NULL RETURNING hidden_at`, user, conversationID).Scan(&at)
	return at, mapped(err)
}

// RestoreConversation brings a deleted chat back into the caller's list. Only a chat that is hidden, not closed and
// still inside its restore window can be restored; anything else (not hidden, closed, expired, not a member) is
// ErrNotFound.
func (s *Store) RestoreConversation(ctx context.Context, user, conversationID string) error {
	tag, err := s.Pool.Exec(ctx, `UPDATE conversation_members SET hidden_at=NULL
 WHERE user_id=$1 AND conversation_id=$2 AND hidden_at IS NOT NULL AND closed_at IS NULL AND hidden_at>now()-$3::interval`, user, conversationID, domain.HiddenChatRetention)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return nil
}

// PinnedConversations is the caller's pinned chats in their list, most recent activity first.
func (s *Store) PinnedConversations(ctx context.Context, user string, sign Signer, online Presence) ([]domain.Conversation, error) {
	return s.conversationList(ctx, user, sign, online, conversationSelect+` AND c.status='active' AND m.hidden_at IS NULL AND m.pinned_at IS NOT NULL
 ORDER BY m.sort_at DESC,m.conversation_id DESC LIMIT $2`, pinnedListCap)
}

// HiddenConversations is the caller's Deleted chats: hidden, not closed, hidden less than 30 days ago, with a peer they
// may still reach, most recently hidden first. closedIDs are the conversations closed for the caller in the last 90
// days (newest first, at most ClosedIDsMax): the app wipes its local history for them.
func (s *Store) HiddenConversations(ctx context.Context, user string, sign Signer, online Presence) (items []domain.Conversation, closedIDs []string, err error) {
	items, err = s.conversationList(ctx, user, sign, online, conversationSelect+` AND c.status='active' AND m.hidden_at IS NOT NULL AND m.closed_at IS NULL
 AND m.hidden_at>now()-interval '30 days'
 ORDER BY m.hidden_at DESC,m.conversation_id DESC LIMIT $2`, HiddenListMax)
	if err != nil {
		return nil, nil, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT conversation_id::text FROM conversation_members WHERE user_id=$1 AND closed_at>now()-$3::interval
 ORDER BY closed_at DESC,conversation_id DESC LIMIT $2`, user, ClosedIDsMax, ClosedIDsWindow)
	if err != nil {
		return nil, nil, err
	}
	closedIDs, err = pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, nil, err
	}
	if closedIDs == nil {
		closedIDs = []string{}
	}
	return items, closedIDs, nil
}

// conversationList runs one conversationSelect-based query (its last parameter $2 is a row limit) and fills in
// shared interests and presence like ListConversations.
func (s *Store) conversationList(ctx context.Context, user string, sign Signer, online Presence, query string, limit int) ([]domain.Conversation, error) {
	rows, err := s.Pool.Query(ctx, query, user, limit)
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

// CloseExpiredHiddenChats closes, for the member only, every chat whose hidden_at is older than retention and
// that is not closed yet: closed_at=now() and unread_count=0, at most batch rows a call (it returns how many, so
// the maintenance loop continues while full batches remain). The server keeps no message for a member (ciphertext
// envelopes expire by themselves), so closing only takes the chat out of the Deleted-chats list for good and
// makes it unrestorable; the app wipes its local history for the ids the hidden listing reports. A later message
// from the peer reopens it as a visible chat (SendMessage), and so does the member opening it.
func (s *Store) CloseExpiredHiddenChats(ctx context.Context, retention time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE conversation_members SET closed_at=now(),unread_count=0
 WHERE (conversation_id,user_id) IN (SELECT conversation_id,user_id FROM conversation_members
  WHERE hidden_at IS NOT NULL AND closed_at IS NULL AND hidden_at<now()-$1::interval ORDER BY hidden_at LIMIT $2)
 AND hidden_at IS NOT NULL AND closed_at IS NULL`, retention, batch)
	return tag.RowsAffected(), err
}
