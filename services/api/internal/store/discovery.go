package store

import (
	"context"
	"encoding/json"
	"strings"

	"kairova/services/api/internal/domain"
)

// EligibleAdult must be checked for the searching principal as well as targets.
// No date of birth, age band, or assurance metadata is sent to the consumer.
func (s *Store) EligibleAdult(ctx context.Context, id string) (bool, error) {
	var eligible bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM discovery_eligibility e JOIN users u USING(user_id) WHERE e.user_id=$1 AND u.status='active' AND e.age_group='adult' AND e.confirmed_at<=now() AND e.valid_until>now())`, id).Scan(&eligible)
	return eligible, err
}

// Candidate predicates and field hydration run against one PostgreSQL snapshot.
// Hidden fields cannot be inferred by changing search filters. A keyset page is
// bounded and all privacy/block/eligibility checks are repeated on every page.
func (s *Store) SearchPeople(ctx context.Context, viewer string, f domain.PeopleFilters, after string, limit int) ([]map[string]any, error) {
	interests := make([]string, len(f.Interests))
	for i, v := range f.Interests {
		interests[i] = strings.ToLower(v)
	}
	rows, err := s.Pool.Query(ctx, `
 SELECT p.user_id::text,p.username,p.data,q.data FROM profiles p
 JOIN users u USING(user_id) JOIN privacy_settings q USING(user_id)
 JOIN discovery_eligibility e USING(user_id)
 WHERE p.user_id<>$1 AND p.user_id>$2::uuid AND u.status='active'
 AND e.age_group='adult' AND e.confirmed_at<=now() AND e.valid_until>now()
 AND EXISTS(SELECT 1 FROM discovery_eligibility ve JOIN users vu USING(user_id) WHERE ve.user_id=$1 AND vu.status='active' AND ve.age_group='adult' AND ve.confirmed_at<=now() AND ve.valid_until>now())
 AND q.data->>'discoverable'='true' AND q.data->>'profileAudience'='public'
 AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=p.user_id) OR (b.blocker_id=p.user_id AND b.blocked_id=$1))
 AND ($3='' OR (q.data->'fieldAudiences'->>'location'='everyone' AND p.data->>'country'=$3))
 AND ($4='' OR (q.data->'fieldAudiences'->>'vibe'='everyone' AND lower(p.data->>'currentVibe')=lower($4)))
 AND (cardinality($5::text[])=0 OR (q.data->'fieldAudiences'->>'interests'='everyone' AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p.data->'interests')='array' THEN p.data->'interests' ELSE '[]'::jsonb END) i WHERE lower(i)=ANY($5::text[]))))
 AND (cardinality($6::text[])=0 OR (q.data->'fieldAudiences'->>'languages'='everyone' AND EXISTS(SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p.data->'languages')='array' THEN p.data->'languages' ELSE '[]'::jsonb END) l WHERE lower(CASE WHEN jsonb_typeof(l)='string' THEN l#>>'{}' ELSE l->>'code' END)=ANY($6::text[]))))
 ORDER BY p.user_id LIMIT $7`, viewer, after, f.Country, f.Vibe, interests, f.Languages, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	for rows.Next() {
		var id, username string
		var data, policy []byte
		if err = rows.Scan(&id, &username, &data, &policy); err != nil {
			return nil, err
		}
		var p domain.Profile
		var q domain.Privacy
		if err = json.Unmarshal(data, &p); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(policy, &q); err != nil {
			return nil, err
		}
		item := map[string]any{"userId": id, "username": username, "displayName": p.DisplayName, "headline": p.Headline, "bio": p.Bio}
		if q.FieldAudiences["interests"] == "everyone" {
			item["interests"] = p.Interests
		}
		if q.FieldAudiences["languages"] == "everyone" {
			item["languages"] = p.Languages
		}
		if q.FieldAudiences["vibe"] == "everyone" {
			item["currentVibe"] = p.CurrentVibe
		}
		if q.FieldAudiences["location"] == "everyone" && p.Country != nil {
			item["country"] = *p.Country
		}
		result = append(result, item)
	}
	return result, rows.Err()
}
