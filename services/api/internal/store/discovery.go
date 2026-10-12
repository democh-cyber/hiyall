package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Presence reports whether a member currently has a live realtime connection on this node
// (the in-process hub check; session activity is read from the database, see presenceFor).
// A nil Presence means nobody is connected, which is how a node without a realtime hub
// behaves. It is only ever asked about members the viewer may already be told about.
type Presence func(userID string) bool

// discoveryItem is the one projection of a person in people search and Nearby.
// Collections appear only when their field audience is "everyone", exactly as
// in a public profile. Presence (`online: true`, or else `lastSeenAt`) is added afterwards, for the whole
// page at once, by Store.addPresence. avatarUrl is a signed thumbnail of the profile photo, or null.
func discoveryItem(id, username string, p domain.Profile, q domain.Privacy, avatar *string, mine []string) map[string]any {
	item := map[string]any{"userId": id, "username": username, "displayName": p.DisplayName, "avatarUrl": avatar, "headline": p.Headline, "bio": p.Bio}
	if q.FieldAudiences["interests"] == "everyone" {
		item["interests"] = p.Interests
		if len(mine) > 0 {
			// sharedInterests follows the very same audience check as interests: what a viewer
			// cannot see of a member can never be inferred from what they have in common.
			// Spelled as the viewer typed them, at most domain.MaxSharedInterests (see domain.SharedInterests).
			item["sharedInterests"] = domain.SharedInterests(mine, p.Interests)
		} else {
			item["sharedInterests"] = []string{}
		}
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
	return item
}

// peopleFilterSQL is the filter predicate of people search and Nearby, so the two
// cannot drift apart. p is profiles and q is privacy_settings, and $1 is the viewer. n is the number of
// the first of eight parameters: country, vibe, interests (lower-cased text[]) and
// languages (text[]), age minimum, age maximum (int, 0 for none), gender and online (boolean), see peopleFilterArgs. A filter matches only when that member's audience for the
// field is "everyone", so a hidden field can never be inferred by filtering (the age
// filter needs fieldAudiences.age "everyone" too); it works on the private birth date (member_age(p.user_id) between the two ages,
// written as bounds on birth_date so it is one key lookup per candidate rather than a function call)
// and an unknown age never matches it. The online filter is the one exception to "everyone": see onlineFilterSQL. Within a
// collection any value may match; dimensions combine with AND.
func peopleFilterSQL(n int) string {
	return fmt.Sprintf(`AND ($%[1]d='' OR (q.data->'fieldAudiences'->>'location'='everyone' AND p.data->>'country'=$%[1]d))
 AND ($%[2]d='' OR (q.data->'fieldAudiences'->>'vibe'='everyone' AND lower(p.data->>'currentVibe')=lower($%[2]d)))
 AND (cardinality($%[3]d::text[])=0 OR (q.data->'fieldAudiences'->>'interests'='everyone' AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p.data->'interests')='array' THEN p.data->'interests' ELSE '[]'::jsonb END) i WHERE lower(i)=ANY($%[3]d::text[]))))
 AND (cardinality($%[4]d::text[])=0 OR (q.data->'fieldAudiences'->>'languages'='everyone' AND EXISTS(SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p.data->'languages')='array' THEN p.data->'languages' ELSE '[]'::jsonb END) l WHERE lower(CASE WHEN jsonb_typeof(l)='string' THEN l#>>'{}' ELSE l->>'code' END)=ANY($%[4]d::text[]))))
 AND ($%[5]d::int=0 AND $%[6]d::int=0 OR q.data->'fieldAudiences'->>'age'='everyone' AND EXISTS(SELECT 1 FROM member_ages ma WHERE ma.user_id=p.user_id
  AND ($%[5]d::int=0 OR ma.birth_date<=(now() AT TIME ZONE 'UTC')::date-make_interval(years=>$%[5]d::int))
  AND ($%[6]d::int=0 OR ma.birth_date>(now() AT TIME ZONE 'UTC')::date-make_interval(years=>$%[6]d::int+1))))
 AND ($%[7]d::text='' OR (q.data->'fieldAudiences'->>'gender'='everyone' AND p.data->>'gender'=$%[7]d::text))
 AND (NOT $%[8]d::boolean OR `+onlineFilterSQL+`)`, n, n+1, n+2, n+3, n+4, n+5, n+6, n+7)
}

// onlineFilterSQL is the predicate of the Online filter, for a viewer $1 and a candidate p with
// settings q. Candidates match only when
//
//  1. their onlineAudience admits the viewer, with exactly the rule of the per-row flag
//     (domain.Relationship.Allows): "everyone" always, "friends" an accepted friend, "followers"
//     an accepted friend or an active follower, "nobody" and anything unknown never; and
//  2. one of their usable sessions (not revoked, not expired) was active within
//     domain.PresenceOnlineWindow.
//
// Live realtime connections are held per node in memory and cannot be asked in SQL, so a member who
// is connected but has had no session activity for longer than the window is not matched by the
// filter, although a row that is returned always carries the precise flag (hub or session). The
// filter is therefore a precise subset of "online now", never a superset, and it reveals nothing the
// flag would not: a hidden audience simply never matches, like an offline member.
var onlineFilterSQL = fmt.Sprintf(`(
  (q.data->>'onlineAudience'='everyone'
   OR (q.data->>'onlineAudience'='friends' AND EXISTS(SELECT 1 FROM friendships f WHERE f.user_low_id=least($1::uuid,p.user_id) AND f.user_high_id=greatest($1::uuid,p.user_id) AND f.status='accepted'))
   OR (q.data->>'onlineAudience'='followers' AND (
     EXISTS(SELECT 1 FROM friendships f WHERE f.user_low_id=least($1::uuid,p.user_id) AND f.user_high_id=greatest($1::uuid,p.user_id) AND f.status='accepted')
     OR EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1::uuid AND fo.followee_id=p.user_id AND fo.state='active'))))
  AND EXISTS(SELECT 1 FROM sessions se WHERE se.user_id=p.user_id AND se.revoked_at IS NULL AND se.expires_at>now() AND se.last_seen_at>now()-interval '%d seconds'))`, int(domain.PresenceOnlineWindow.Seconds()))

// filterArgs are the values peopleFilterSQL takes, in order. The slices are never
// nil: a NULL array would make the predicate unknown and drop every row.
type filterArgs struct {
	country, vibe        string
	interests, languages []string
	ageMin, ageMax       int
	gender               string
	online               bool
}

func peopleFilterArgs(f domain.PeopleFilters) filterArgs {
	a := filterArgs{country: f.Country, vibe: f.Vibe, interests: make([]string, len(f.Interests)), languages: f.Languages, gender: f.Gender, online: f.Online}
	for i, v := range f.Interests {
		a.interests[i] = strings.ToLower(v)
	}
	if a.languages == nil {
		a.languages = []string{}
	}
	if f.AgeMin != nil {
		a.ageMin = *f.AgeMin
	}
	if f.AgeMax != nil {
		a.ageMax = *f.AgeMax
	}
	return a
}

// list is the arguments in the order of the placeholders.
func (a filterArgs) list() []any {
	return []any{a.country, a.vibe, a.interests, a.languages, a.ageMin, a.ageMax, a.gender, a.online}
}

// ageFilterCannotMatch reports that the viewer's own age band makes an age filter impossible
// while age-band isolation is on: a minor asking for 18 and over, or an adult asking for
// 17 and under, can only get nobody. Answering that without a query keeps such a request
// from scanning every member for nothing.
func ageFilterCannotMatch(isolation, minorViewer bool, f domain.PeopleFilters) bool {
	if !isolation {
		return false
	}
	return (minorViewer && f.AgeMin != nil && *f.AgeMin >= domain.AdultAge) || (!minorViewer && f.AgeMax != nil && *f.AgeMax < domain.AdultAge)
}

// SearchPeople lists discoverable members. Every active member who has finished
// onboarding is eligible; what a member shows is decided by their own stored
// settings, which are read in the same statement as the candidate predicates so
// hidden fields cannot be inferred by changing search filters. A keyset page is
// bounded and all privacy and block checks are repeated on every page.
func (s *Store) SearchPeople(ctx context.Context, viewer string, f domain.PeopleFilters, after string, limit int, online Presence, sign Signer) ([]map[string]any, error) {
	if s.AgeBandIsolation && (f.AgeMin != nil || f.AgeMax != nil) {
		var minor bool
		if err := s.Pool.QueryRow(ctx, `SELECT age_band($1)=$2`, viewer, domain.BandMinor).Scan(&minor); err != nil {
			return nil, err
		}
		if ageFilterCannotMatch(true, minor, f) {
			return []map[string]any{}, nil
		}
	}
	mine, err := s.viewerInterests(ctx, viewer)
	if err != nil {
		return nil, err
	}
	args := append([]any{viewer, after}, peopleFilterArgs(f).list()...)
	rows, err := s.Pool.Query(ctx, `
 SELECT p.user_id::text,p.username,p.data,q.data,`+avatarThumbKey("av")+` FROM profiles p
 JOIN users u USING(user_id) JOIN privacy_settings q USING(user_id)
 JOIN onboarding o ON o.user_id=p.user_id AND o.completed_at IS NOT NULL`+avatarJoin("av", "p")+`
 WHERE p.user_id<>$1 AND p.user_id>$2::uuid AND u.status='active'
 AND q.data->>'discoverable'='true' AND q.data->>'profileAudience'='public'
 AND NOT interaction_barred($1::uuid,p.user_id)
 `+peopleFilterSQL(3)+`
 ORDER BY p.user_id LIMIT $11`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	var audiences []string
	for rows.Next() {
		var id, username string
		var data, policy []byte
		var avatar *string
		if err = rows.Scan(&id, &username, &data, &policy, &avatar); err != nil {
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
		result = append(result, discoveryItem(id, username, p, q, avatarURL(sign, avatar), mine))
		audiences = append(audiences, q.OnlineAudience)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	return result, s.addPresence(ctx, viewer, result, audiences, online)
}

// viewerInterests is the viewer's own interests as they typed them: one read of one profile row, used to
// mark what a page of people has in common with them (discoveryItem). It is read once per page, so
// listing costs no query per person, and it is nil when there are none.
func (s *Store) viewerInterests(ctx context.Context, viewer string) ([]string, error) {
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT CASE WHEN jsonb_typeof(data->'interests')='array' THEN data->'interests' ELSE '[]'::jsonb END FROM profiles WHERE user_id=$1`, viewer).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var list []string
	_ = json.Unmarshal(raw, &list)
	return list, nil
}
