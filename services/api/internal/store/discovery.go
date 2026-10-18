package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

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
	if q.FieldAudiences["personality"] == "everyone" {
		tags := p.PersonalityTags
		if tags == nil {
			tags = []string{}
		}
		item["personalityTags"] = tags
	}
	// The member's local time, only when they chose to show it (computed from their stored zone, never the zone).
	if q.ShowLocalTime {
		if lt := domain.LocalTimeFor(p.Timezone, time.Now()); lt != nil {
			item["localTime"] = lt
		}
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
// and an unknown age never matches it. The age and gender filters never narrow a candidate who is a minor (they pass those
// two predicates), and are refused outright for a viewer who is a minor (domain.ErrFilterNotAvailable). The online filter is the one exception to "everyone": see onlineFilterSQL. Within a
// collection any value may match; dimensions combine with AND.
func peopleFilterSQL(n int) string {
	return fmt.Sprintf(`AND ($%[1]d='' OR (q.data->'fieldAudiences'->>'location'='everyone' AND p.data->>'country'=$%[1]d))
 AND ($%[2]d='' OR (q.data->'fieldAudiences'->>'vibe'='everyone' AND lower(p.data->>'currentVibe')=lower($%[2]d)))
 AND (cardinality($%[3]d::text[])=0 OR (q.data->'fieldAudiences'->>'interests'='everyone' AND EXISTS(SELECT 1 FROM profile_interests pi WHERE pi.user_id=p.user_id AND pi.interest=ANY($%[3]d::text[]))))
 AND (cardinality($%[4]d::text[])=0 OR (q.data->'fieldAudiences'->>'languages'='everyone' AND EXISTS(SELECT 1 FROM profile_languages pl WHERE pl.user_id=p.user_id AND pl.code=ANY($%[4]d::text[]) AND pl.level>=$%[9]d::int)))
 AND (cardinality($%[10]d::text[])=0 OR (q.data->'fieldAudiences'->>'personality'='everyone' AND EXISTS(SELECT 1 FROM profile_personality_tags pt WHERE pt.user_id=p.user_id AND pt.tag=ANY($%[10]d::text[]))))
 AND ($%[5]d::int=0 AND $%[6]d::int=0 OR EXISTS(SELECT 1 FROM member_ages mi WHERE mi.user_id=p.user_id AND mi.birth_date>(now() AT TIME ZONE 'UTC')::date-make_interval(years=>18))
  OR q.data->'fieldAudiences'->>'age'='everyone' AND EXISTS(SELECT 1 FROM member_ages ma WHERE ma.user_id=p.user_id
  AND ($%[5]d::int=0 OR ma.birth_date<=(now() AT TIME ZONE 'UTC')::date-make_interval(years=>$%[5]d::int))
  AND ($%[6]d::int=0 OR ma.birth_date>(now() AT TIME ZONE 'UTC')::date-make_interval(years=>$%[6]d::int+1))))
 AND ($%[7]d::text='' OR EXISTS(SELECT 1 FROM member_ages mi WHERE mi.user_id=p.user_id AND mi.birth_date>(now() AT TIME ZONE 'UTC')::date-make_interval(years=>18))
  OR (q.data->'fieldAudiences'->>'gender'='everyone' AND p.data->>'gender'=$%[7]d::text))
 AND (NOT $%[8]d::boolean OR `+onlineFilterSQL+`)`, n, n+1, n+2, n+3, n+4, n+5, n+6, n+7, n+8, n+9)
}

// filterParams is how many placeholders peopleFilterSQL takes, starting at its n: country, vibe, interests, languages,
// age minimum, age maximum, gender, online, language minimum level, personality tags (see peopleFilterArgs).
const filterParams = 10

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
	languageMin          int
	personality          []string
}

func peopleFilterArgs(f domain.PeopleFilters) filterArgs {
	a := filterArgs{country: f.Country, vibe: f.Vibe, interests: make([]string, len(f.Interests)), languages: f.Languages, gender: f.Gender, online: f.Online, languageMin: f.LanguageMinLevel, personality: f.PersonalityTags}
	if a.personality == nil {
		a.personality = []string{}
	}
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
	return []any{a.country, a.vibe, a.interests, a.languages, a.ageMin, a.ageMax, a.gender, a.online, a.languageMin, a.personality}
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

// SearchCandidateCap is the most discoverable members one page of people search examines, in user id order,
// before the filters and privacy checks narrow them (audit D8): a selective filter, or a viewer who is barred
// from most of the table (a minor), can no longer make one request walk every member. The statement timeout
// still bounds anything slower than that; a page that finds nothing within the cap simply ends the list.
const SearchCandidateCap = 5000

// SearchPeople lists discoverable members. Every active member who has finished
// onboarding is eligible; what a member shows is decided by their own stored
// settings, which are read in the same statement as the candidate predicates so
// hidden fields cannot be inferred by changing search filters. A keyset page is
// bounded and all privacy and block checks are repeated on every page.
func (s *Store) SearchPeople(ctx context.Context, viewer string, f domain.PeopleFilters, after string, limit int, online Presence, sign Signer) ([]map[string]any, error) {
	items, _, err := s.SearchPeoplePage(ctx, viewer, f, after, limit, online, sign)
	return items, err
}

// SearchPeoplePage is SearchPeople that also says where to continue when the page ended because the candidate
// cap was reached and not because the members ran out: resume is then the last candidate examined (the user id
// the next page starts after), otherwise "". A page can be short, even empty, and still have more behind it (a
// selective filter, or a minor viewer barred from most of the table); the caller offers resume as the next
// cursor, so the list does not end early (round-3 audit D8 residual).
func (s *Store) SearchPeoplePage(ctx context.Context, viewer string, f domain.PeopleFilters, after string, limit int, online Presence, sign Signer) (items []map[string]any, resume string, err error) {
	if f, err = s.resolveFilters(ctx, viewer, f); err != nil {
		return nil, "", err
	}
	if f.UsesAgeOrGender() {
		minor, err := s.IsMinor(ctx, viewer)
		if err != nil {
			return nil, "", err
		}
		if minor {
			return nil, "", domain.ErrFilterNotAvailable
		}
		if ageFilterCannotMatch(s.AgeBandIsolation, minor, f) {
			return []map[string]any{}, "", nil
		}
	}
	mine, err := s.viewerInterests(ctx, viewer)
	if err != nil {
		return nil, "", err
	}
	args := append([]any{viewer, after}, peopleFilterArgs(f).list()...)
	// meta is one row whatever the page holds, so an empty page still learns whether the cap was reached.
	rows, err := s.Pool.Query(ctx, `
 WITH cand AS MATERIALIZED (SELECT q0.user_id FROM privacy_settings q0 WHERE q0.user_id>$2::uuid AND q0.user_id<>$1::uuid
  AND q0.data->>'discoverable'='true' AND q0.data->>'profileAudience'='public' ORDER BY q0.user_id LIMIT `+strconv.Itoa(SearchCandidateCap)+`),
 meta AS (SELECT CASE WHEN count(*)=`+strconv.Itoa(SearchCandidateCap)+` THEN (SELECT user_id::text FROM cand ORDER BY user_id DESC LIMIT 1) END AS resume FROM cand),
 res AS (SELECT p.user_id,p.username,p.data,q.data AS policy,`+avatarThumbKey("av")+` AS avatar FROM cand JOIN profiles p USING(user_id)
 JOIN users u USING(user_id) JOIN privacy_settings q USING(user_id)
 JOIN onboarding o ON o.user_id=p.user_id AND o.completed_at IS NOT NULL`+avatarJoin("av", "p")+`
 WHERE p.user_id<>$1 AND p.user_id>$2::uuid AND u.status='active'
 AND q.data->>'discoverable'='true' AND q.data->>'profileAudience'='public'
 AND `+notBarred("$1::uuid", "p.user_id")+`
 `+peopleFilterSQL(3)+`
 ORDER BY p.user_id LIMIT $`+strconv.Itoa(3+filterParams)+`)
 SELECT res.user_id::text,res.username,res.data,res.policy,res.avatar,meta.resume FROM meta LEFT JOIN res ON true ORDER BY res.user_id`, append(args, limit)...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	var audiences []string
	for rows.Next() {
		var id, username *string
		var data, policy []byte
		var avatar, next *string
		if err = rows.Scan(&id, &username, &data, &policy, &avatar, &next); err != nil {
			return nil, "", err
		}
		if next != nil {
			resume = *next
		}
		if id == nil {
			continue // the one row of an empty page
		}
		var p domain.Profile
		var q domain.Privacy
		if err = json.Unmarshal(data, &p); err != nil {
			return nil, "", err
		}
		if err = json.Unmarshal(policy, &q); err != nil {
			return nil, "", err
		}
		result = append(result, discoveryItem(*id, *username, p, q, avatarURL(sign, avatar), mine))
		audiences = append(audiences, q.OnlineAudience)
	}
	if err = rows.Err(); err != nil {
		return nil, "", err
	}
	rows.Close()
	return result, resume, s.addPresence(ctx, viewer, result, audiences, online)
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
