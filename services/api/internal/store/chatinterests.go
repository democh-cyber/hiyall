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
// It is a read-only lookup of two profile rows plus, only for peers with something in common, the peer's
// privacy settings and relationship to the caller. It never goes through the profile view, so it records no
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
	for i := range cs {
		cs[i].SharedInterests = []string{}
		common := domain.SharedInterests(interests[viewer], interests[cs[i].Peer.UserID])
		if len(common) == 0 {
			continue
		}
		policy, err := privacyOf(ctx, s.Pool, cs[i].Peer.UserID)
		if err != nil {
			return err
		}
		rel, err := relationship(ctx, s.Pool, viewer, cs[i].Peer.UserID, policy)
		if err != nil {
			return err
		}
		if rel.Allows(policy.ProfileAudience) && rel.Allows(policy.FieldAudiences["interests"]) {
			cs[i].SharedInterests = common
		}
	}
	return nil
}
