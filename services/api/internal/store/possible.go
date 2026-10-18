package store

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// PossibleMatch is one person in the possible-matches list: the usual Discover item (see discoveryItem) with
// "reasons" added, and the score the page cursor continues from. The score is never sent to a client.
type PossibleMatch struct {
	Item  map[string]any
	Score int
}

// PossibleAfter is the keyset position of a possible-matches page: the score and user id of the last person
// already returned. HasAfter false starts at the beginning.
type PossibleAfter struct {
	HasAfter bool
	Score    int
	UserID   string
}

// PossibleCountryCap bounds how many same-country members one page considers as candidates by country alone
// (the only signal here that is not read through one of the small normalised tables), in user id order. A member who
// shares an interest, a tag or a language with the viewer is found through those, whatever the cap.
const PossibleCountryCap = 3000

// possibleMatchesSQL ranks members for viewer $1. $2 interests (lower case), $3 personality tags, $4 the viewer's
// languages they are still learning (level up to domain.LanguageLearningMax), $5 the languages they are fluent in
// (domain.LanguageFluentMin and above), $6 their country ("" for none), $7/$8/$9 the keyset position (is there
// one, score, user id), $10 whether to leave out people the viewer already follows (or has asked to follow), $11
// the limit. The weights and the rules are domain.Score; a member's field counts only when its audience is
// "everyone". Candidates come from the indexed tables (profile_interests, profile_personality_tags,
// profile_languages(code, level, user_id) and the country index), are narrowed by eligibility and the age/block
// barrier (notBarred), scored once, and paged by (score desc, user id asc).
func possibleMatchesSQL() string {
	return `
WITH hits AS (
  SELECT user_id FROM profile_interests WHERE interest=ANY($2::text[])
  UNION SELECT user_id FROM profile_personality_tags WHERE tag=ANY($3::text[])
  UNION SELECT user_id FROM profile_languages WHERE code=ANY($4::text[]) AND level>=` + strconv.Itoa(domain.LanguageFluentMin) + `
  UNION SELECT user_id FROM profile_languages WHERE code=ANY($5::text[]) AND level<=` + strconv.Itoa(domain.LanguageLearningMax) + `
  UNION (SELECT user_id FROM profiles WHERE $6::text<>'' AND data->>'country'=$6::text ORDER BY user_id LIMIT ` + strconv.Itoa(PossibleCountryCap) + `)
), cand AS MATERIALIZED (
  SELECT h.user_id FROM hits h
  JOIN users u ON u.user_id=h.user_id AND u.status='active'
  JOIN onboarding o ON o.user_id=h.user_id AND o.completed_at IS NOT NULL
  WHERE h.user_id<>$1::uuid AND ` + notBarred("$1::uuid", "h.user_id") + `
  AND (NOT $10::boolean OR NOT EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1::uuid AND f.followee_id=h.user_id AND f.state IN ('active','pending')))
), scored AS (
  SELECT p.user_id,p.username,p.data,q.data AS policy,
   CASE WHEN q.data->'fieldAudiences'->>'interests'='everyone' THEN least(` + strconv.Itoa(domain.MatchMaxInterests) + `,(SELECT count(*) FROM profile_interests i WHERE i.user_id=p.user_id AND i.interest=ANY($2::text[]))) ELSE 0 END AS si,
   CASE WHEN q.data->'fieldAudiences'->>'personality'='everyone' THEN least(` + strconv.Itoa(domain.MatchMaxTags) + `,(SELECT count(*) FROM profile_personality_tags t WHERE t.user_id=p.user_id AND t.tag=ANY($3::text[]))) ELSE 0 END AS st,
   coalesce(q.data->'fieldAudiences'->>'languages'='everyone' AND EXISTS(SELECT 1 FROM profile_languages l WHERE l.user_id=p.user_id AND l.code=ANY($4::text[]) AND l.level>=` + strconv.Itoa(domain.LanguageFluentMin) + `),false) AS learn,
   coalesce(q.data->'fieldAudiences'->>'languages'='everyone' AND EXISTS(SELECT 1 FROM profile_languages l WHERE l.user_id=p.user_id AND l.code=ANY($5::text[]) AND l.level<=` + strconv.Itoa(domain.LanguageLearningMax) + `),false) AS teach,
   coalesce($6::text<>'' AND q.data->'fieldAudiences'->>'location'='everyone' AND p.data->>'country'=$6::text,false) AS country
  FROM cand c JOIN profiles p ON p.user_id=c.user_id
  JOIN privacy_settings q ON q.user_id=c.user_id AND q.data->>'discoverable'='true' AND q.data->>'profileAudience'='public'
), ranked AS (
  SELECT s.*,(` + strconv.Itoa(domain.MatchWeightInterest) + `*si+` + strconv.Itoa(domain.MatchWeightPersonality) + `*st+(CASE WHEN learn THEN ` + strconv.Itoa(domain.MatchWeightLanguage) + ` ELSE 0 END)+(CASE WHEN teach THEN ` + strconv.Itoa(domain.MatchWeightLanguage) + ` ELSE 0 END)+(CASE WHEN country THEN ` + strconv.Itoa(domain.MatchWeightCountry) + ` ELSE 0 END))::int AS score FROM scored s
)
SELECT r.user_id::text,r.username,r.data,r.policy,r.score,r.si,r.st,r.learn,r.teach,r.country,` + avatarThumbKey("av") + `
FROM ranked r JOIN profiles pa ON pa.user_id=r.user_id` + avatarJoin("av", "pa") + `
WHERE r.score>0 AND (NOT $7::boolean OR r.score<$8::int OR (r.score=$8::int AND r.user_id>$9::uuid))
ORDER BY r.score DESC,r.user_id ASC LIMIT $11`
}

// PossibleMatches lists up to limit members the viewer may like, best first, after the position in after. It is
// the same eligibility as people search (active, onboarded, discoverable, public, not the viewer, not blocked and
// in the viewer's age band), and uses the members' own audiences like it (see domain.Score). The viewer must pass
// limit one above the page they want to learn whether another page exists, as the search does.
func (s *Store) PossibleMatches(ctx context.Context, viewer string, excludeFollowing bool, after PossibleAfter, limit int, online Presence, sign Signer) ([]PossibleMatch, error) {
	me, err := s.matchProfile(ctx, viewer)
	if err != nil {
		return nil, err
	}
	var learning, fluent []string
	for code, level := range me.Languages {
		if level <= domain.LanguageLearningMax {
			learning = append(learning, code)
		}
		if level >= domain.LanguageFluentMin {
			fluent = append(fluent, code)
		}
	}
	for _, list := range []*[]string{&me.Interests, &me.Tags, &learning, &fluent} {
		if *list == nil {
			*list = []string{}
		}
	}
	afterID := after.UserID
	if afterID == "" {
		afterID = "00000000-0000-0000-0000-000000000000"
	}
	mine, err := s.viewerInterests(ctx, viewer)
	if err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, possibleMatchesSQL(), viewer, me.Interests, me.Tags, learning, fluent, me.Country, after.HasAfter, after.Score, afterID, excludeFollowing, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []PossibleMatch
	var audiences []string
	for rows.Next() {
		var id, username string
		var data, policy []byte
		var score, si, st int
		var learn, teach, country bool
		var avatar *string
		if err = rows.Scan(&id, &username, &data, &policy, &score, &si, &st, &learn, &teach, &country, &avatar); err != nil {
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
		item := discoveryItem(id, username, p, q, avatarURL(sign, avatar), mine)
		item["reasons"] = domain.MatchScore{SharedInterests: si, SharedTags: st, LearnFromThem: learn, TeachThem: teach, SameCountry: country}.Reasons()
		result = append(result, PossibleMatch{Item: item, Score: score})
		audiences = append(audiences, q.OnlineAudience)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	items := make([]map[string]any, len(result))
	for i := range result {
		items[i] = result[i].Item
	}
	if err = s.addPresence(ctx, viewer, items, audiences, online); err != nil {
		return nil, err
	}
	return result, nil
}

// matchProfile reads what the ranking compares for the viewer: their own interests, personality tags,
// languages with levels and country, from the normalised tables and the profile (their own fields count whatever
// audience they gave them).
func (s *Store) matchProfile(ctx context.Context, user string) (domain.MatchProfile, error) {
	me := domain.MatchProfile{Languages: map[string]int{}}
	var country *string
	if err := s.Pool.QueryRow(ctx, `SELECT data->>'country' FROM profiles WHERE user_id=$1`, user).Scan(&country); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return me, domain.ErrNotFound
		}
		return me, err
	}
	if country != nil {
		me.Country = *country
	}
	rows, err := s.Pool.Query(ctx, `SELECT 'i',interest,0 FROM profile_interests WHERE user_id=$1
 UNION ALL SELECT 't',tag,0 FROM profile_personality_tags WHERE user_id=$1
 UNION ALL SELECT 'l',code,level FROM profile_languages WHERE user_id=$1`, user)
	if err != nil {
		return me, err
	}
	defer rows.Close()
	for rows.Next() {
		var kind, value string
		var level int
		if err = rows.Scan(&kind, &value, &level); err != nil {
			return me, err
		}
		switch kind {
		case "i":
			me.Interests = append(me.Interests, value)
		case "t":
			me.Tags = append(me.Tags, value)
		default:
			me.Languages[value] = level
		}
	}
	return me, rows.Err()
}
