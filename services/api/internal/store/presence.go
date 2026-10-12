package store

import (
	"context"
	"time"

	"hiyall/services/api/internal/domain"
)

// presenceTarget is one member whose presence is being resolved and the audience they chose for it
// (their onlineAudience; last seen has no control of its own and follows it). The audience is applied with
// domain.Relationship.Allows like every other: "everyone" admits anyone who can see the member at all,
// "friends" accepted friends only, "followers" friends and active followers, "nobody" (or anything unknown)
// no one. The member themself is always admitted.
type presenceTarget struct{ ID, Audience string }

// sessionActivity returns, for each member that has one, the latest last_seen_at over their usable
// sessions (not revoked, not expired). One query for any number of members.
func sessionActivity(ctx context.Context, q querier, ids []string) (map[string]time.Time, error) {
	active := map[string]time.Time{}
	if len(ids) == 0 {
		return active, nil
	}
	rows, err := q.Query(ctx, `SELECT user_id::text,max(last_seen_at) FROM sessions WHERE user_id=ANY($1::uuid[]) AND revoked_at IS NULL AND expires_at>now() GROUP BY user_id`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var at time.Time
		if err = rows.Scan(&id, &at); err != nil {
			return nil, err
		}
		active[id] = at
	}
	return active, rows.Err()
}

// presenceFor resolves what viewer may be told about each target's presence, for any number of members
// in at most two queries (relationships, only for targets whose audience is not "everyone" or "nobody",
// and session activity, only for members the viewer is admitted to and who are not connected right now)
// plus the in-process hub check live. A target the viewer is not admitted to is simply absent from the
// result, which is exactly what a member who is offline with no session looks like, so hidden and offline
// cannot be told apart. Callers pass only members the viewer can already see (blocked and age-barred
// pairs are excluded by the queries that produce them), so this adds no way to probe for a member.
// It reads sessions and relationships only: it records no profile visit.
func (s *Store) presenceFor(ctx context.Context, q querier, viewer string, targets []presenceTarget, live Presence) (map[string]domain.Presence, error) {
	result := make(map[string]domain.Presence, len(targets))
	admitted := make([]string, 0, len(targets))
	var related []presenceTarget
	for _, t := range targets {
		switch {
		case t.ID == viewer || t.Audience == "everyone":
			admitted = append(admitted, t.ID)
		case t.Audience == "friends" || t.Audience == "followers":
			related = append(related, t)
		}
	}
	if len(related) > 0 {
		ids := make([]string, len(related))
		for i, t := range related {
			ids[i] = t.ID
		}
		// The same two facts relationship reads, for many members at once.
		rows, err := q.Query(ctx, `SELECT t.id::text,coalesce(fo.state,'none'),f.status
 FROM unnest($2::uuid[]) t(id)
 LEFT JOIN follows fo ON fo.follower_id=$1 AND fo.followee_id=t.id AND fo.state<>'removed'
 LEFT JOIN friendships f ON f.user_low_id=least($1::uuid,t.id) AND f.user_high_id=greatest($1::uuid,t.id)`, viewer, ids)
		if err != nil {
			return nil, err
		}
		rels := map[string]domain.Relationship{}
		for rows.Next() {
			var id, following string
			var status *string
			if err = rows.Scan(&id, &following, &status); err != nil {
				rows.Close()
				return nil, err
			}
			rel := domain.Relationship{Following: following, Friendship: "none"}
			if status != nil && *status == "accepted" {
				rel.Friendship = "accepted"
			}
			rels[id] = rel
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return nil, err
		}
		for _, t := range related {
			if rels[t.ID].Allows(t.Audience) {
				admitted = append(admitted, t.ID)
			}
		}
	}
	var ask []string
	for _, id := range admitted {
		if live != nil && live(id) {
			result[id] = domain.Presence{Online: true}
			continue
		}
		ask = append(ask, id)
	}
	active, err := sessionActivity(ctx, q, ask)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	for _, id := range ask {
		var last *time.Time
		if at, ok := active[id]; ok {
			last = &at
		}
		if p := domain.ResolvePresence(false, last, now); p.Online || p.LastSeenAt != nil {
			result[id] = p
		}
	}
	return result, nil
}

// setPresence writes a resolved presence onto a person payload: online true, or else lastSeenAt as an
// RFC 3339 UTC string, and nothing at all when there is nothing to show.
func setPresence(item map[string]any, p domain.Presence) {
	if p.Online {
		item["online"] = true
	} else if p.LastSeenAt != nil {
		item["lastSeenAt"] = p.LastSeenAt.UTC().Format(time.RFC3339)
	}
}

// addPresence resolves presence for the members behind items (items[i] is a person payload whose userId is
// ids[i] and whose onlineAudience is audiences[i]) in one batch and writes it onto them.
func (s *Store) addPresence(ctx context.Context, viewer string, items []map[string]any, audiences []string, live Presence) error {
	targets := make([]presenceTarget, len(items))
	for i, item := range items {
		targets[i] = presenceTarget{ID: item["userId"].(string), Audience: audiences[i]}
	}
	found, err := s.presenceFor(ctx, s.Pool, viewer, targets, live)
	if err != nil {
		return err
	}
	for _, item := range items {
		setPresence(item, found[item["userId"].(string)])
	}
	return nil
}

func (s *Store) withPresence(ctx context.Context, viewer string, c domain.Conversation, online Presence) (domain.Conversation, error) {
	one := []domain.Conversation{c}
	err := s.fillPresence(ctx, viewer, one, online)
	return one[0], err
}

// fillPresence sets presence on the peers of conversations the caller can already see (the conversation
// queries leave out blocked and age-barred pairs), for the whole page in one batch. The peer's audience
// came with the row. It records no visit and reads no profile.
func (s *Store) fillPresence(ctx context.Context, viewer string, cs []domain.Conversation, live Presence) error {
	if len(cs) == 0 {
		return nil
	}
	targets := make([]presenceTarget, len(cs))
	for i, c := range cs {
		targets[i] = presenceTarget{ID: c.Peer.UserID, Audience: c.PeerOnlineAudience}
	}
	found, err := s.presenceFor(ctx, s.Pool, viewer, targets, live)
	if err != nil {
		return err
	}
	for i := range cs {
		p := found[cs[i].Peer.UserID]
		cs[i].Peer.Online, cs[i].Peer.LastSeenAt = p.Online, p.LastSeenAt
	}
	return nil
}
