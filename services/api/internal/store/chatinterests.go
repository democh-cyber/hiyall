package store

import (
	"context"
	"encoding/json"

	"hiyall/services/api/internal/domain"
)

func (s *Store) withSharedInterests(ctx context.Context, viewer string, c domain.Conversation) (domain.Conversation, error) {
	one := []domain.Conversation{c}
	err := s.fillSharedInterests(ctx, viewer, one)
	return one[0], err
}

// fillSharedInterests sets SharedInterests on conversations the caller can already see (the conversation
// queries leave out blocked and age-barred pairs), so a new chat can start from what two people have in common.
//
// It is a read-only lookup of the profile rows plus, only for peers with something in common, the peers'
// privacy settings and relationship to the caller, all in two statements however many conversations there are. It never goes through the profile view, so it records no
// visit and touches no visitor counter. The peer's interests are used only when the peer's profile audience
// and "interests" field audience both admit the caller, exactly as the profile does; otherwise the list stays
// empty, which is also what "nothing in common" looks like.
func (s *Store) fillSharedInterests(ctx context.Context, viewer string, cs []domain.Conversation) error {
	if len(cs) == 0 {
		return nil
	}
	ids := []string{viewer}
	for _, c := range cs {
		ids = append(ids, c.Peer.UserID)
	}
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text,CASE WHEN jsonb_typeof(data->'interests')='array' THEN data->'interests' ELSE '[]'::jsonb END FROM profiles WHERE user_id=ANY($1::uuid[])`, ids)
	if err != nil {
		return err
	}
	interests := map[string][]string{}
	for rows.Next() {
		var id string
		var raw []byte
		if err = rows.Scan(&id, &raw); err != nil {
			rows.Close()
			return err
		}
		var list []string
		if json.Unmarshal(raw, &list) == nil {
			interests[id] = list
		}
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	// Peers with something in common need their privacy settings and relationship to the viewer, read for all of
	// them in one statement (audit D10) instead of two queries per conversation.
	var shared []string
	common := make([][]string, len(cs))
	for i := range cs {
		cs[i].SharedInterests = []string{}
		common[i] = domain.SharedInterests(interests[viewer], interests[cs[i].Peer.UserID])
		if len(common[i]) > 0 {
			shared = append(shared, cs[i].Peer.UserID)
		}
	}
	if len(shared) == 0 {
		return nil
	}
	admitted, err := s.interestsVisibleTo(ctx, viewer, shared)
	if err != nil {
		return err
	}
	for i := range cs {
		if len(common[i]) > 0 && admitted[cs[i].Peer.UserID] {
			cs[i].SharedInterests = common[i]
		}
	}
	return nil
}

// interestsVisibleTo reports, for each of peers, whether the viewer may see that peer's interests: the peer's
// profile audience and "interests" field audience must both admit the viewer's relationship (an accepted
// friendship, an active follow of the peer), with the rule of domain.Relationship.Allows. A peer without
// settings is never admitted.
func (s *Store) interestsVisibleTo(ctx context.Context, viewer string, peers []string) (map[string]bool, error) {
	rows, err := s.Pool.Query(ctx, `SELECT q.user_id::text,coalesce(q.data->>'profileAudience',''),coalesce(q.data->'fieldAudiences'->>'interests','nobody'),
  EXISTS(SELECT 1 FROM friendships f WHERE f.user_low_id=least($1::uuid,q.user_id) AND f.user_high_id=greatest($1::uuid,q.user_id) AND f.status='accepted'),
  EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1::uuid AND fo.followee_id=q.user_id AND fo.state='active')
 FROM privacy_settings q WHERE q.user_id=ANY($2::uuid[])`, viewer, peers)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	admitted := map[string]bool{}
	for rows.Next() {
		var id, profile, field string
		var friend, following bool
		if err = rows.Scan(&id, &profile, &field, &friend, &following); err != nil {
			return nil, err
		}
		rel := domain.Relationship{Friendship: "none", Following: "none"}
		if friend {
			rel.Friendship = "accepted"
		}
		if following {
			rel.Following = "active"
		}
		admitted[id] = rel.Allows(profile) && rel.Allows(field)
	}
	return admitted, rows.Err()
}
