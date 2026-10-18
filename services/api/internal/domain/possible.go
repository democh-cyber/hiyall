package domain

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Possible matches rank the people a member may like. The score is a weighted count of what two members have
// in common, and it is the same formula in SQL (store.PossibleMatches) and here, which the tests hold equal:
//
//	3 per shared interest (counted up to MatchMaxInterests)
//	2 per shared personality tag (counted up to MatchMaxTags)
//	4 for each direction of complementary languages: they are at LanguageFluentMin or above in a language I am
//	  still learning (my level at most LanguageLearningMax), and the other way round (so 0, 4 or 8)
//	1 for the same country
//
// A field only counts when the other member shows it to everyone (the field audience of interests, personality,
// languages and location is "everyone"), so a hidden field can never be inferred from the order of the list.
// Results are ordered by score descending, then user id ascending, and paged by that pair.
const (
	MatchWeightInterest    = 3
	MatchWeightPersonality = 2
	MatchWeightLanguage    = 4
	MatchWeightCountry     = 1
	MatchMaxInterests      = 5
	MatchMaxTags           = 5
	// MatchMaxScore is the largest possible score.
	MatchMaxScore = MatchWeightInterest*MatchMaxInterests + MatchWeightPersonality*MatchMaxTags + 2*MatchWeightLanguage + MatchWeightCountry
)

// MatchProfile is what a score reads about one member: lower-case interests, personality tag ids, language
// codes (lower case) with their level, and the country code ("" when unknown or hidden).
type MatchProfile struct {
	Interests []string
	Tags      []string
	Languages map[string]int
	Country   string
}

// MatchScore is the parts of a score.
type MatchScore struct {
	SharedInterests int
	SharedTags      int
	// LearnFromThem: they can help me with a language I am learning. TeachThem: I can help them.
	LearnFromThem, TeachThem bool
	SameCountry              bool
}

// Score compares me with them, where them is already reduced to the fields they show to everyone.
func Score(me, them MatchProfile) MatchScore {
	var s MatchScore
	s.SharedInterests = min(shared(me.Interests, them.Interests), MatchMaxInterests)
	s.SharedTags = min(shared(me.Tags, them.Tags), MatchMaxTags)
	for code, mine := range me.Languages {
		if theirs, ok := them.Languages[code]; ok {
			if mine <= LanguageLearningMax && theirs >= LanguageFluentMin {
				s.LearnFromThem = true
			}
			if theirs <= LanguageLearningMax && mine >= LanguageFluentMin {
				s.TeachThem = true
			}
		}
	}
	s.SameCountry = me.Country != "" && me.Country == them.Country
	return s
}

func shared(a, b []string) int {
	in := make(map[string]bool, len(a))
	for _, v := range a {
		in[strings.ToLower(v)] = true
	}
	seen := map[string]bool{}
	n := 0
	for _, v := range b {
		v = strings.ToLower(v)
		if in[v] && !seen[v] {
			seen[v] = true
			n++
		}
	}
	return n
}

// Total is the weighted score.
func (s MatchScore) Total() int {
	total := MatchWeightInterest*s.SharedInterests + MatchWeightPersonality*s.SharedTags
	if s.LearnFromThem {
		total += MatchWeightLanguage
	}
	if s.TeachThem {
		total += MatchWeightLanguage
	}
	if s.SameCountry {
		total += MatchWeightCountry
	}
	return total
}

// Reasons are the kinds of thing two members share, for the "why you may like them" line: interests,
// personality, languages, country, in that order of weight per item. Never the score.
func (s MatchScore) Reasons() []string {
	out := []string{}
	if s.SharedInterests > 0 {
		out = append(out, "interests")
	}
	if s.SharedTags > 0 {
		out = append(out, "personality")
	}
	if s.LearnFromThem || s.TeachThem {
		out = append(out, "languages")
	}
	if s.SameCountry {
		out = append(out, "country")
	}
	return out
}

// PossibleMatchesPerPage is the page size of the possible matches list; the Home strip asks for
// PossibleMatchesStrip of them.
const (
	PossibleMatchesPerPage = 20
	PossibleMatchesStrip   = 12
)

// PossibleRequest is the body of POST /v1/discovery/possible-matches. Every key is optional.
type PossibleRequest struct {
	// Limit is the page size, 1 to PossibleMatchesPerPage (the default).
	Limit int
	// ExcludeFollowing leaves out people the viewer already follows or has asked to follow.
	ExcludeFollowing bool
	Cursor           string
}

// ParsePossibleRequest reads the body; an unknown key is refused.
func ParsePossibleRequest(body map[string]json.RawMessage) (PossibleRequest, error) {
	req := PossibleRequest{Limit: PossibleMatchesPerPage}
	for key, raw := range body {
		switch key {
		case "limit":
			n, err := strconv.Atoi(string(raw))
			if err != nil || strconv.Itoa(n) != string(raw) || n < 1 || n > PossibleMatchesPerPage {
				return req, invalid(key, fmt.Sprintf("must be a whole number from 1 to %d", PossibleMatchesPerPage))
			}
			req.Limit = n
		case "excludeFollowing":
			if string(raw) != "true" && string(raw) != "false" {
				return req, invalid(key, "must be true or false")
			}
			req.ExcludeFollowing = string(raw) == "true"
		case "cursor":
			var v string
			if json.Unmarshal(raw, &v) != nil || len(v) > 2048 || !CleanLine(v) {
				return req, invalid(key, "invalid cursor")
			}
			req.Cursor = v
		default:
			return req, invalid(key, "unsupported field")
		}
	}
	return req, nil
}
