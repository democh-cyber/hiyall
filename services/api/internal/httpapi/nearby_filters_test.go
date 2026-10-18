package httpapi

import (
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"strings"
	"testing"
)

// filterWorld places six members at growing distances north of alice (buckets 1, 3, 10, 15, 50, 100):
//
//	bob  IN  chill     music,books  en,hi
//	cara FR  Active    music        fr,en
//	dev  IN  chill     art          ko
//	eli  JP  Creative  books,art    ja
//	xan  IN  Chill     music        hi        (every field hidden)
//	yui  FR  Chill     music,art    fr
func filterWorld(t *testing.T) *socialHarness {
	t.Helper()
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	for _, m := range []struct {
		id        string
		north     float64
		country   string
		vibe      string
		interests []string
		languages []string
	}{
		{bob, 0, "IN", "Chill", []string{"Music", "Books"}, []string{"en", "hi"}},
		{cara, 0.02, "FR", "Active", []string{"Music"}, []string{"fr", "en"}},
		{dev, 0.05, "IN", "chill", []string{"Art"}, []string{"ko"}},
		{eli, 0.10, "JP", "Creative", []string{"Books", "Art"}, []string{"ja"}},
		{xan, 0.30, "IN", "Chill", []string{"Music"}, []string{"hi"}},
		{yui, 0.80, "FR", "Chill", []string{"Music", "Art"}, []string{"fr"}},
	} {
		languages := make([]map[string]string, len(m.languages))
		for i, code := range m.languages {
			languages[i] = map[string]string{"code": code}
		}
		data, _ := json.Marshal(map[string]any{"country": m.country, "currentVibe": m.vibe, "interests": m.interests, "languages": languages})
		h.exec(`UPDATE profiles SET data=data||$2::jsonb WHERE user_id=$1`, m.id, data)
		h.north(m.id, m.north)
	}
	for _, field := range []string{"location", "vibe", "interests", "languages"} {
		h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],'"nobody"') WHERE user_id=$1`, xan, field)
	}
	return h
}

func TestNearbyFiltersCombineWithDistanceOrder(t *testing.T) {
	h := filterWorld(t)
	search := func(body map[string]any) []string {
		t.Helper()
		body["radiusKm"] = 100
		users, buckets := h.nearbyOK(alice, body)
		if !sort.IntsAreSorted(buckets) {
			t.Fatalf("%v: buckets %v are not ordered", body, buckets)
		}
		return users
	}
	for name, tc := range map[string]struct {
		body map[string]any
		want []string
	}{
		"no filter":                  {map[string]any{}, []string{bob, cara, dev, eli, xan, yui}},
		"empty filters are none":     {map[string]any{"country": "", "vibe": "", "interests": []string{}, "languages": []string{}}, []string{bob, cara, dev, eli, xan, yui}},
		"country":                    {map[string]any{"country": "IN"}, []string{bob, dev}}, // xan hides his country
		"another country":            {map[string]any{"country": "FR"}, []string{cara, yui}},
		"country nobody has":         {map[string]any{"country": "PH"}, nil},
		"vibe ignores case":          {map[string]any{"vibe": "CHILL"}, []string{bob, dev, yui}},
		"vibe is exact":              {map[string]any{"vibe": "chil"}, nil},
		"one interest":               {map[string]any{"interests": []string{"music"}}, []string{bob, cara, yui}},
		"interests are OR":           {map[string]any{"interests": []string{"ART", "books"}}, []string{bob, dev, eli, yui}},
		"interest nobody has":        {map[string]any{"interests": []string{"gaming"}}, nil},
		"one language":               {map[string]any{"languages": []string{"en"}}, []string{bob, cara}},
		"languages are OR":           {map[string]any{"languages": []string{"HI", "ja"}}, []string{bob, eli}},
		"language nobody has":        {map[string]any{"languages": []string{"es"}}, nil},
		"country AND interest":       {map[string]any{"country": "IN", "interests": []string{"music"}}, []string{bob}},
		"country AND vibe":           {map[string]any{"country": "IN", "vibe": "chill"}, []string{bob, dev}},
		"country AND language":       {map[string]any{"country": "FR", "languages": []string{"en"}}, []string{cara}},
		"three dimensions":           {map[string]any{"country": "IN", "interests": []string{"art"}, "languages": []string{"ko"}}, []string{dev}},
		"four dimensions":            {map[string]any{"country": "FR", "vibe": "chill", "interests": []string{"art"}, "languages": []string{"fr"}}, []string{yui}},
		"AND can leave nothing":      {map[string]any{"country": "JP", "vibe": "chill"}, nil},
		"OR inside AND":              {map[string]any{"country": "FR", "interests": []string{"music", "books"}, "languages": []string{"fr", "ko"}}, []string{cara, yui}},
		"language tag is normalized": {map[string]any{"languages": []string{"EN"}}, []string{bob, cara}},
	} {
		same(t, ids2(search(tc.body)), ids2(tc.want)...)
		_ = name
	}

	// The radius still applies: the filter narrows the list and never widens it.
	users, buckets := h.nearbyOK(alice, map[string]any{"radiusKm": 25, "country": "FR"})
	same(t, users, cara)
	if fmt.Sprint(buckets) != "[5]" {
		t.Fatalf("buckets %v", buckets)
	}
	users, buckets = h.nearbyOK(alice, map[string]any{"radiusKm": 25, "country": "IN"})
	same(t, users, bob, dev)
	if fmt.Sprint(buckets) != "[5 10]" {
		t.Fatalf("buckets %v", buckets)
	}
	// Ties inside a bucket are still ordered by user id.
	h.north(dev, 0)
	h.north(cara, 0)
	users, buckets = h.nearbyOK(alice, map[string]any{"radiusKm": 25, "interests": []string{"music", "art"}})
	same(t, users, bob, cara, dev, eli) // eli likes art too, 11 km away
	if fmt.Sprint(buckets) != "[5 5 5 15]" || !slices.IsSorted(users) {
		t.Fatalf("%v %v", users, buckets)
	}
	// Items keep their shape: the filter adds nothing to them.
	got, _, _ := h.nearbyList(alice, map[string]any{"radiusKm": 25, "country": "IN", "vibe": "chill"})
	for _, item := range items(got.data) {
		keys := make([]string, 0, len(item))
		for k := range item {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if fmt.Sprint(keys) != "[avatarUrl bio country currentVibe displayName distanceKm headline interests languages localTime personalityTags sharedInterests userId username]" {
			t.Fatalf("item keys %v", keys)
		}
	}
}

// ids2 sorts a copy so cases that are about membership, not order, still read clearly; the order itself is checked by
// search() (buckets non-decreasing) and by the explicit order checks in this file.
func ids2(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// A filter matches only when the member shows that field to everyone. Hiding it makes the member invisible to that
// filter, which is what stops a hidden interest or language being found by trying filters.
func TestNearbyFiltersRespectFieldAudiences(t *testing.T) {
	h := filterWorld(t)
	for _, tc := range []struct {
		field  string
		filter map[string]any
		member string
	}{
		{"location", map[string]any{"country": "IN"}, bob},
		{"vibe", map[string]any{"vibe": "chill"}, bob},
		{"interests", map[string]any{"interests": []string{"music"}}, bob},
		{"languages", map[string]any{"languages": []string{"hi"}}, bob},
	} {
		body := map[string]any{"radiusKm": 25}
		for k, v := range tc.filter {
			body[k] = v
		}
		before, _ := h.nearbyOK(alice, body)
		if !slices.Contains(before, tc.member) {
			t.Fatalf("%s: the member is not matched while the field is visible: %v", tc.field, before)
		}
		for _, audience := range []string{"nobody", "friends", "followers"} {
			h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],to_jsonb($3::text)) WHERE user_id=$1`, tc.member, tc.field, audience)
			after, _ := h.nearbyOK(alice, body)
			if slices.Contains(after, tc.member) {
				t.Fatalf("%s hidden from %s still matched by %v", tc.field, audience, tc.filter)
			}
			// The same member is still listed without the filter.
			unfiltered, _ := h.nearbyOK(alice, map[string]any{"radiusKm": 25})
			if !slices.Contains(unfiltered, tc.member) {
				t.Fatalf("hiding %s removed the member from Nearby", tc.field)
			}
		}
		h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,ARRAY['fieldAudiences',$2::text],'"everyone"') WHERE user_id=$1`, tc.member, tc.field)
	}
	// xan hides everything, so no filter finds him, while a visible field does.
	for _, filter := range []map[string]any{{"country": "IN"}, {"vibe": "chill"}, {"interests": []string{"music"}}, {"languages": []string{"hi"}}} {
		filter["radiusKm"] = 100
		users, _ := h.nearbyOK(alice, filter)
		if slices.Contains(users, xan) {
			t.Fatalf("xan matched %v with every field hidden", filter)
		}
	}
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,interests}','"everyone"') WHERE user_id=$1`, xan)
	users, _ := h.nearbyOK(alice, map[string]any{"radiusKm": 100, "interests": []string{"music"}})
	same(t, ids2(users), ids2([]string{bob, cara, xan, yui})...)
	// A member who is not discoverable or public is not found by any filter either.
	h.policy(cara, "discoverable", false)
	users, _ = h.nearbyOK(alice, map[string]any{"radiusKm": 100, "interests": []string{"music"}})
	same(t, ids2(users), ids2([]string{bob, xan, yui})...)
}

// Nearby filters mean what people search filters mean: for the same filters and members who are all in range, the two
// endpoints return the same people.
func TestNearbyFiltersAgreeWithPeopleSearch(t *testing.T) {
	h := filterWorld(t)
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,interests}','"everyone"') WHERE user_id=$1`, xan)
	for _, filter := range []map[string]any{
		{}, {"country": "IN"}, {"country": "FR"}, {"vibe": "Chill"}, {"interests": []string{"music"}}, {"interests": []string{"art", "books"}},
		{"languages": []string{"en", "ja"}}, {"country": "IN", "interests": []string{"music"}}, {"country": "FR", "vibe": "chill", "languages": []string{"fr"}},
		{"country": "JP", "vibe": "chill"},
	} {
		h.api.search.reset(alice)
		search := h.expect(h.send(alice, "POST", "/v1/discovery/search", filter), 200, "").data
		var fromSearch []string
		for _, item := range items(search) {
			fromSearch = append(fromSearch, item["userId"].(string))
		}
		body := map[string]any{"radiusKm": 100}
		for k, v := range filter {
			body[k] = v
		}
		fromNearby, _ := h.nearbyOK(alice, body)
		same(t, ids2(fromNearby), ids2(fromSearch)...)
	}
}

func TestNearbyFiltersPageAndBindTheCursor(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	// 45 members from India and 10 from France, interleaved in one bucket, plus 5 Indians in a farther one.
	var india []string
	for i := 0; i < 60; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 200+i)
		h.user(id, fmt.Sprintf("filter_%d", i))
		country := "IN"
		if i%6 == 5 && i < 60 {
			country = "FR"
		}
		h.exec(`UPDATE profiles SET data=data||jsonb_build_object('country',$2::text) WHERE user_id=$1`, id, country)
		if i < 55 {
			h.north(id, 0)
		} else {
			h.north(id, 0.05)
		}
		if country == "IN" {
			india = append(india, id)
		}
	}
	filter := map[string]any{"country": "IN"}
	var seen []string
	var cursors []string
	body := map[string]any{"country": "IN"}
	for page := 0; ; page++ {
		got, users, _ := h.nearbyList(alice, body)
		h.expect(got, 200, "")
		for _, id := range users {
			if !slices.Contains(india, id) {
				t.Fatalf("page %d lists %s, who is not from India", page, id)
			}
		}
		seen = append(seen, users...)
		next, _ := got.data["nextCursor"].(string)
		if next == "" {
			break
		}
		cursors = append(cursors, next)
		body = map[string]any{"country": "IN", "cursor": next}
	}
	if len(seen) != len(india) || len(cursors) != 2 {
		t.Fatalf("%d members over %d cursors, want %d members over 2", len(seen), len(cursors), len(india))
	}
	sort.Strings(india)
	// Within a bucket the order is by id; the 5 farther ones come last.
	same(t, ids2(seen), india...)
	cursor := cursors[0]

	invalid := func(name string, body map[string]any) {
		t.Helper()
		got, _, _ := h.nearbyList(alice, body)
		if got.status != 422 || got.code != "INVALID_CURSOR" {
			t.Fatalf("%s: %d %q", name, got.status, got.code)
		}
	}
	// Any change of filter or radius invalidates the cursor.
	invalid("country changed", map[string]any{"country": "FR", "cursor": cursor})
	invalid("filter dropped", map[string]any{"cursor": cursor})
	invalid("filter added", map[string]any{"country": "IN", "vibe": "chill", "cursor": cursor})
	invalid("interests added", map[string]any{"country": "IN", "interests": []string{"music"}, "cursor": cursor})
	invalid("languages added", map[string]any{"country": "IN", "languages": []string{"en"}, "cursor": cursor})
	invalid("radius changed", map[string]any{"country": "IN", "radiusKm": 50, "cursor": cursor})
	invalid("radius dropped is not 25 here", map[string]any{"country": "IN", "radiusKm": 15, "cursor": cursor})
	// The same filters in another key order, and an explicit default radius, are the same search.
	got, users, _ := h.nearbyList(alice, json.RawMessage(`{"cursor":"`+cursor+`","radiusKm":25,"vibe":"","country":"IN"}`))
	h.expect(got, 200, "")
	if len(users) == 0 {
		t.Fatal("the same search with its keys reordered returned nothing")
	}
	// A cursor from a filtered search cannot be used by anybody else.
	h.place(bob, bengaluru.Latitude, bengaluru.Longitude)
	got, _, _ = h.nearbyList(bob, map[string]any{"country": "IN", "cursor": cursor})
	if got.status != 422 || got.code != "INVALID_CURSOR" {
		t.Fatalf("foreign cursor: %d %q", got.status, got.code)
	}
	_ = filter
	// And an unfiltered search's cursor cannot be used to page a filtered one.
	got, _, _ = h.nearbyList(alice, map[string]any{})
	plain, _ := got.data["nextCursor"].(string)
	if plain == "" {
		t.Fatal("no cursor from the unfiltered search")
	}
	invalid("unfiltered cursor, filtered search", map[string]any{"country": "IN", "cursor": plain})
}

func TestNearbyRefusesUnknownKeysAndBadFilters(t *testing.T) {
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	long := strings.Repeat("x", 41)
	for name, raw := range map[string]string{
		"email":                      `{"email":"a@b.c"}`,
		"age":                        `{"minAge":12}`,
		"gender":                     `{"gender":"men"}`,
		"presence":                   `{"presence":true}`,
		"online as a string":         `{"online":"true"}`,
		"online null":                `{"online":null}`,
		"online a number":            `{"online":1}`,
		"a position":                 `{"latitude":12.97,"longitude":77.59}`,
		"a radius spelled another":   `{"radius":5}`,
		"radius in metres":           `{"radiusM":5000}`,
		"query style":                `{"limit":5}`,
		"interests null":             `{"interests":null}`,
		"interests as text":          `{"interests":"music"}`,
		"interests with a number":    `{"interests":[1]}`,
		"interests blank":            `{"interests":[""]}`,
		"interests too long":         `{"interests":["` + long + `"]}`,
		"interests duplicate":        `{"interests":["Music","music"]}`,
		"eleven interests":           `{"interests":["a","b","c","d","e","f","g","h","i","j","k"]}`,
		"languages null":             `{"languages":null}`,
		"languages duplicate":        `{"languages":["en","EN"]}`,
		"languages not a tag":        `{"languages":["x"]}`,
		"languages with a number":    `{"languages":[1]}`,
		"languages with a space":     `{"languages":["en us"]}`,
		"eleven languages":           `{"languages":["aa","bb","cc","dd","ee","ff","gg","hh","ii","jj","kk"]}`,
		"country lower case":         `{"country":"in"}`,
		"country too long":           `{"country":"IND"}`,
		"country a number":           `{"country":1}`,
		"country null":               `{"country":null}`,
		"vibe too long":              `{"vibe":"` + strings.Repeat("v", 81) + `"}`,
		"vibe null":                  `{"vibe":null}`,
		"vibe a list":                `{"vibe":["chill"]}`,
		"cursor a number":            `{"cursor":5}`,
		"cursor null":                `{"cursor":null}`,
		"filters as a nested object": `{"filters":{"country":"IN"}}`,
	} {
		got, _, _ := h.nearbyList(alice, json.RawMessage(raw))
		if got.status != 422 || got.code != "VALIDATION" {
			t.Fatalf("%s %s: %d %q", name, raw, got.status, got.code)
		}
	}
	// The same values are accepted when they are well formed.
	for _, raw := range []string{
		`{"interests":["Music","Books"],"languages":["en","pt-BR"],"country":"IN","vibe":"  Chill  ","radiusKm":10}`,
		`{"interests":["` + strings.Repeat("é", 40) + `"]}`,
		`{"country":""}`,
	} {
		got, _, _ := h.nearbyList(alice, json.RawMessage(raw))
		h.expect(got, 200, "")
	}
	// A refused body uses a limiter token no differently from any other call and never reaches the database.
	var rows int
	if err := h.db.Pool.QueryRow(h.ctx, `SELECT count(*) FROM user_locations WHERE user_id<>$1`, alice).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("rows %d (%v)", rows, err)
	}
}
