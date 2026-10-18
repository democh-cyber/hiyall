package store

import (
	"context"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// PushAudience is PushAudienceFor for a push that is not a kind of its own: the category decides which choice applies.
func (s *Store) PushAudience(ctx context.Context, recipient, actor, conversation, category string) (ok bool, name string, err error) {
	return s.PushAudienceFor(ctx, recipient, actor, conversation, category, "")
}

// PushPref names the notification choice a push kind falls under ("" for kinds that are not social): follows,
// friend_requests (requests and invitations), comments, replies, reactions or visits.
func PushPref(kind string) string {
	switch kind {
	case "follow", "follow_request", "follow_accepted":
		return "follows"
	case "friend_request", "friend_accepted", "space_invite":
		return "friend_requests"
	case "comment":
		return "comments"
	case "reply":
		return "replies"
	case "reaction":
		return "reactions"
	case "visit", "visit_anon":
		return "visits"
	}
	return ""
}

// PushAudienceFor answers, for one prospective push, whether recipient may be pushed to
// at all and what the actor is called. It is the database half of internal/push's rules:
//
//   - both accounts are active and have finished onboarding (a suspended, banned,
//     deactivated or deleting account is never pushed to or about);
//   - they may interact: no block either way and, while age-band isolation is on, the same band;
//   - the recipient has not muted or restricted the actor, and neither restricted the other
//     (the same rule that keeps a restricted person's messages quiet);
//   - the member has not switched pushes off (the master switch), nor this category: chat, or the kind's own choice
//     (follows, friend requests, comments, replies, reactions, profile visits: PushPref). A security push ignores
//     every choice. The "support" kind is about the recipient only (no actor) and obeys the master switch alone;
//   - for chat, the conversation is active, the recipient is in it with the actor, and has not muted it.
//
// The name is returned only when all of that holds AND the member has not chosen to hide names (hideNames: the
// default for a member under 18), which is also when the recipient can already see who the actor is (their
// profile card and Activity show it). With names hidden the payload is the generic line.
func (s *Store) PushAudienceFor(ctx context.Context, recipient, actor, conversation, category, kind string) (ok bool, name string, err error) {
	if kind == "support" {
		err = s.Pool.QueryRow(ctx, `SELECT '' FROM (SELECT 1) x LEFT JOIN notification_prefs np ON np.user_id=$1
 WHERE `+memberSQL("$1::uuid")+` AND coalesce(np.enabled,true)`, recipient).Scan(&name)
		if err == pgx.ErrNoRows {
			return false, "", nil
		}
		return err == nil, "", err
	}
	var conv any
	if conversation != "" {
		conv = conversation
	}
	err = s.Pool.QueryRow(ctx, `SELECT CASE WHEN coalesce(np.hide_names,age_band($1)=$6) THEN '' ELSE coalesce(nullif(p.data->>'displayName',''),p.username) END
 FROM profiles p
 LEFT JOIN notification_prefs np ON np.user_id=$1
 WHERE p.user_id=$2 AND `+memberSQL("$1::uuid")+` AND `+memberSQL("$2::uuid")+`
 AND NOT `+barredBetween+`
 AND NOT `+quietFrom("$1::uuid", "$2::uuid")+` AND NOT `+restrictedPair("$1::uuid", "$2::uuid")+`
 AND CASE WHEN $3='security' THEN true WHEN NOT coalesce(np.enabled,true) THEN false WHEN $3='chat' THEN coalesce(np.chat,true)
  ELSE CASE $5 WHEN 'follows' THEN coalesce(np.follows,true) WHEN 'friend_requests' THEN coalesce(np.friend_requests,true)
   WHEN 'comments' THEN coalesce(np.comments,true) WHEN 'replies' THEN coalesce(np.replies,true) WHEN 'reactions' THEN coalesce(np.reactions,true)
   WHEN 'visits' THEN coalesce(np.visits,false) ELSE coalesce(np.social,true) END END
 AND ($4::uuid IS NULL OR EXISTS(SELECT 1 FROM conversation_members m JOIN conversations c ON c.conversation_id=m.conversation_id
  WHERE m.conversation_id=$4 AND m.user_id=$1 AND c.status='active' AND (m.muted_until IS NULL OR m.muted_until<=now())
  AND (m.peer_id=$2 OR (c.kind='group' AND EXISTS(SELECT 1 FROM chat_group_members ag WHERE ag.conversation_id=c.conversation_id AND ag.user_id=$2 AND ag.state='active')))))`,
		recipient, actor, category, conv, PushPref(kind), domain.BandMinor).Scan(&name)
	if err == pgx.ErrNoRows {
		return false, "", nil
	}
	return err == nil, name, err
}

// ClearPushToken forgets a token the provider reported dead. It only clears the device
// that still holds that exact token, so a token the app has since refreshed survives.
func (s *Store) ClearPushToken(ctx context.Context, deviceID, provider, token string) error {
	_, err := s.Pool.Exec(ctx, `UPDATE devices SET push_provider=NULL,push_token=NULL WHERE device_id=$1 AND push_provider=$2 AND push_token=$3`, deviceID, provider, token)
	return err
}

// NotificationPrefs returns the member's push choices; without a row every choice has its default (all on but
// profile visits, names hidden for a member under 18).
func (s *Store) NotificationPrefs(ctx context.Context, user string) (domain.NotificationPrefs, error) {
	var p domain.NotificationPrefs
	err := s.Pool.QueryRow(ctx, `SELECT coalesce(np.enabled,true),coalesce(np.chat,true),coalesce(np.follows,true),coalesce(np.comments,true),coalesce(np.reactions,true),
  coalesce(np.replies,true),coalesce(np.friend_requests,true),coalesce(np.visits,false),coalesce(np.hide_names,age_band($1)=$2)
 FROM (SELECT 1) x LEFT JOIN notification_prefs np ON np.user_id=$1`, user, domain.BandMinor).
		Scan(&p.Enabled, &p.Chat, &p.Follows, &p.Comments, &p.Reactions, &p.Replies, &p.FriendRequests, &p.Visits, &p.HideNames)
	p.Social = p.Follows || p.Comments || p.Reactions || p.Replies || p.FriendRequests
	return p, err
}

// SetNotificationPrefs applies a partial update and returns the result. The legacy "social" choice sets every social
// category that the same patch does not name (profile visits excepted).
func (s *Store) SetNotificationPrefs(ctx context.Context, user string, patch domain.NotificationPatch) (domain.NotificationPrefs, error) {
	if patch.Social != nil {
		for _, field := range []**bool{&patch.Follows, &patch.Comments, &patch.Reactions, &patch.Replies, &patch.FriendRequests} {
			if *field == nil {
				*field = patch.Social
			}
		}
	}
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO notification_prefs(user_id,enabled,chat,follows,comments,reactions,replies,friend_requests,visits,hide_names)
 VALUES($1,coalesce($2,true),coalesce($3,true),coalesce($4,true),coalesce($5,true),coalesce($6,true),coalesce($7,true),coalesce($8,true),coalesce($9,false),$10)
 ON CONFLICT (user_id) DO UPDATE SET enabled=coalesce($2,notification_prefs.enabled),chat=coalesce($3,notification_prefs.chat),follows=coalesce($4,notification_prefs.follows),
  comments=coalesce($5,notification_prefs.comments),reactions=coalesce($6,notification_prefs.reactions),replies=coalesce($7,notification_prefs.replies),
  friend_requests=coalesce($8,notification_prefs.friend_requests),visits=coalesce($9,notification_prefs.visits),hide_names=coalesce($10,notification_prefs.hide_names),updated_at=now()`,
			user, patch.Enabled, patch.Chat, patch.Follows, patch.Comments, patch.Reactions, patch.Replies, patch.FriendRequests, patch.Visits, patch.HideNames)
		if err != nil {
			return err
		}
		// The legacy umbrella mirrors the categories.
		_, err = tx.Exec(ctx, `UPDATE notification_prefs SET social=(follows OR comments OR reactions OR replies OR friend_requests) WHERE user_id=$1`, user)
		return err
	})
	if err != nil {
		return domain.NotificationPrefs{}, err
	}
	return s.NotificationPrefs(ctx, user)
}
