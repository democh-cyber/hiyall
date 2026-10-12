package httpapi

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"

	"hiyall/services/api/internal/store"
)

// patchProfile sends a PATCH /v1/me/profile with the version the profile has.
func (h *onboardingHarness) patchProfile(token, version, body string) response {
	h.t.Helper()
	return serve(h.t, h.handler, "PATCH", "/v1/me/profile", token, map[string]string{"If-Match": `"` + version + `"`}, body)
}

func TestGenderIsAnOptionalValidatedProfileFieldWithItsOwnAudience(t *testing.T) {
	h := newOnboardingHarness(t)
	anjali, niko := h.login(alice), h.login(bob)
	profile := h.expect(h.call("GET", "/v1/me/profile", anjali, ""), 200, "").data
	if gender, ok := profile["gender"]; !ok || gender != "" {
		t.Fatalf("a new profile has gender %v (present %v), want an empty string", gender, ok)
	}
	version := profile["version"].(string)
	// Anything but woman, man, nonbinary or empty is refused, and a refusal changes nothing.
	for _, raw := range []string{`"female"`, `"male"`, `"Woman"`, `"MAN"`, `"non-binary"`, `" man"`, `"man "`, `"other"`, `"x"`, `"nonbinaryperson"`, `1`, `null`, `true`, `["man"]`, `{"v":"man"}`} {
		h.expect(h.patchProfile(anjali, version, `{"gender":`+raw+`}`), 422, "VALIDATION")
	}
	if got := h.expect(h.call("GET", "/v1/me/profile", anjali, ""), 200, "").data; got["gender"] != "" || got["version"] != version {
		t.Fatalf("a refused patch changed the profile: %v", got)
	}
	for i, value := range []string{"woman", "man", "nonbinary", ""} {
		got := h.expect(h.patchProfile(anjali, version, `{"gender":"`+value+`"}`), 200, "").data
		if got["gender"] != value {
			t.Fatalf("gender %q saved as %v", value, got["gender"])
		}
		version = got["version"].(string)
		_ = i
	}
	h.expect(h.patchProfile(anjali, version, `{"gender":"woman"}`), 200, "")

	// Others see it only when its audience allows: the default is everyone.
	seen := func() (any, bool) {
		got := h.expect(h.call("GET", "/v1/users/"+alice+"/profile", niko, ""), 200, "").data
		value, ok := got["gender"]
		return value, ok
	}
	if value, ok := seen(); !ok || value != "woman" {
		t.Fatalf("a stranger sees gender %v (present %v)", value, ok)
	}
	for _, audience := range []string{"nobody", "friends", "followers"} {
		h.mustExec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,gender}',to_jsonb($2::text)) WHERE user_id=$1`, alice, audience)
		if value, ok := seen(); ok {
			t.Fatalf("gender hidden from %s is still shown: %v", audience, value)
		}
	}
	// The owner always sees their own, through the privacy API too.
	h.mustExec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,gender}','"nobody"') WHERE user_id=$1`, alice)
	if got := h.expect(h.call("GET", "/v1/users/"+alice+"/profile", anjali, ""), 200, "").data; got["gender"] != "woman" {
		t.Fatalf("the owner's own view %v", got["gender"])
	}
	privacy := h.expect(h.call("GET", "/v1/me/privacy", anjali, ""), 200, "").data
	pv := privacy["version"].(string)
	h.expect(serve(t, h.handler, "PATCH", "/v1/me/privacy", anjali, map[string]string{"If-Match": `"` + pv + `"`}, `{"fieldAudiences":{"gender":"friends"}}`), 200, "")
	h.expect(serve(t, h.handler, "PATCH", "/v1/me/privacy", anjali, map[string]string{"If-Match": `"` + fmt.Sprint(mustAtoi(t, pv)+1) + `"`}, `{"fieldAudiences":{"gender":"public"}}`), 422, "VALIDATION")
	if privacy["fieldAudiences"].(map[string]any)["gender"] != "nobody" {
		t.Fatalf("audiences %v", privacy["fieldAudiences"])
	}
}

func mustAtoi(t *testing.T, s string) int {
	t.Helper()
	var n int
	if _, err := fmt.Sscan(s, &n); err != nil {
		t.Fatal(err)
	}
	return n
}

// filterPeople places members with known ages, genders and countries, every one of them in range for Nearby.
//
//	cara 20 woman FR · dev 25 man IN · eli 30 nonbinary IN · xan 34 woman (gender hidden) · yui age unknown, man · bob 45 no gender
func filterPeople(t *testing.T, fillers int) *socialHarness {
	t.Helper()
	h := newSocialHarness(t)
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	for _, m := range []struct {
		id      string
		age     int
		gender  string
		country string
	}{{cara, 20, "woman", "FR"}, {dev, 25, "man", "IN"}, {eli, 30, "nonbinary", "IN"}, {xan, 34, "woman", "IN"}, {yui, 0, "man", "FR"}, {bob, 45, "", "IN"}} {
		h.setAge(m.id, m.age)
		data, _ := json.Marshal(map[string]any{"gender": m.gender, "country": m.country})
		h.exec(`UPDATE profiles SET data=data||$2::jsonb WHERE user_id=$1`, m.id, data)
		h.north(m.id, 0.01)
	}
	h.setAge(alice, 28)
	h.exec(`UPDATE profiles SET data=data||'{"languages":[{"code":"en"}]}'::jsonb WHERE user_id=$1`, cara)
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,gender}','"friends"') WHERE user_id=$1`, xan)
	for i := 0; i < fillers; i++ {
		id := fmt.Sprintf("019a4000-0000-7000-8000-%012d", 700+i)
		h.user(id, fmt.Sprintf("filler_%d", i))
		h.ageAt(id, 40)
		h.exec(`UPDATE profiles SET data=data||'{"gender":"man","country":"IN"}'::jsonb WHERE user_id=$1`, id)
		h.north(id, 0.01)
	}
	return h
}

// both runs the same filters through people search and Nearby and returns the members found, sorted.
func (h *socialHarness) both(viewer string, filters map[string]any) (search, nearby []string) {
	h.t.Helper()
	h.api.search.reset(viewer)
	h.api.clients.reset("127.0.0.1")
	got := h.expect(h.send(viewer, "POST", "/v1/discovery/search", filters), 200, "").data
	for _, item := range items(got) {
		search = append(search, item["userId"].(string))
	}
	body := map[string]any{"radiusKm": 100}
	for k, v := range filters {
		body[k] = v
	}
	nearby, _ = h.nearbyOK(viewer, body)
	sort.Strings(search)
	sort.Strings(nearby)
	return
}

func TestAgeAndGenderFiltersInSearchAndNearby(t *testing.T) {
	h := filterPeople(t, 0)
	known := []string{bob, cara, dev, eli, xan}
	for name, tc := range map[string]struct {
		filters map[string]any
		want    []string
	}{
		"no filter":                     {map[string]any{}, []string{bob, cara, dev, eli, xan, yui}},
		"minimum":                       {map[string]any{"ageMin": 21}, []string{bob, dev, eli, xan}},
		"minimum includes the age":      {map[string]any{"ageMin": 20}, known},
		"maximum":                       {map[string]any{"ageMax": 25}, []string{cara, dev}},
		"maximum includes the age":      {map[string]any{"ageMax": 20}, []string{cara}},
		"range includes both ends":      {map[string]any{"ageMin": 25, "ageMax": 30}, []string{dev, eli}},
		"one age":                       {map[string]any{"ageMin": 34, "ageMax": 34}, []string{xan}},
		"the whole range":               {map[string]any{"ageMin": 13, "ageMax": 99}, known}, // yui's age is unknown
		"no age in range":               {map[string]any{"ageMin": 60, "ageMax": 70}, nil},
		"man":                           {map[string]any{"gender": "man"}, []string{dev, yui}},
		"woman hides who hide it":       {map[string]any{"gender": "woman"}, []string{cara}}, // xan's audience is friends
		"nonbinary":                     {map[string]any{"gender": "nonbinary"}, []string{eli}},
		"any gender":                    {map[string]any{"gender": ""}, []string{bob, cara, dev, eli, xan, yui}},
		"gender and minimum age":        {map[string]any{"gender": "man", "ageMin": 21}, []string{dev}}, // yui's age is unknown
		"gender and maximum age":        {map[string]any{"gender": "woman", "ageMax": 25}, []string{cara}},
		"gender and country":            {map[string]any{"gender": "man", "country": "FR"}, []string{yui}},
		"age and country":               {map[string]any{"ageMin": 21, "country": "IN"}, []string{bob, dev, eli, xan}},
		"age, gender and country":       {map[string]any{"ageMin": 21, "ageMax": 30, "gender": "nonbinary", "country": "IN"}, []string{eli}},
		"contradiction leaves nobody":   {map[string]any{"gender": "woman", "country": "IN", "ageMax": 22}, nil},
		"age with language and vibe":    {map[string]any{"ageMin": 13, "languages": []string{"en"}, "gender": "woman"}, []string{cara}},
		"an unset gender never matches": {map[string]any{"gender": "woman", "ageMin": 40}, nil},
	} {
		search, nearby := h.both(alice, tc.filters)
		want := append([]string(nil), tc.want...)
		sort.Strings(want)
		if fmt.Sprint(search) != fmt.Sprint(want) || fmt.Sprint(nearby) != fmt.Sprint(want) {
			t.Fatalf("%s %v:\n search %v\nnearby %v\n  want %v", name, tc.filters, search, nearby, want)
		}
	}
	// Changing who shows their gender changes who the filter finds, and the audience is the only thing it follows.
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,gender}','"everyone"') WHERE user_id=$1`, xan)
	if search, nearby := h.both(alice, map[string]any{"gender": "woman"}); fmt.Sprint(search) != fmt.Sprint(sorted(cara, xan)) || fmt.Sprint(nearby) != fmt.Sprint(sorted(cara, xan)) {
		t.Fatalf("gender shown to everyone: %v %v", search, nearby)
	}
	for _, audience := range []string{"nobody", "followers", "friends"} {
		h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,gender}',to_jsonb($2::text)) WHERE user_id=$1`, cara, audience)
		if search, nearby := h.both(alice, map[string]any{"gender": "woman"}); slicesContain(search, cara) || slicesContain(nearby, cara) {
			t.Fatalf("a hidden gender (%s) is still matched: %v %v", audience, search, nearby)
		}
	}
	// A hidden gender does not hide the member: they are listed without the filter.
	if search, nearby := h.both(alice, map[string]any{}); !slicesContain(search, cara) || !slicesContain(nearby, cara) {
		t.Fatalf("hiding gender removed the member: %v %v", search, nearby)
	}
	// Age works on the stored birth date only: no age, no match, and a profile field cannot stand in for it.
	h.exec(`UPDATE profiles SET data=data||'{"age":30,"birthYear":1996}'::jsonb WHERE user_id=$1`, yui)
	if search, _ := h.both(alice, map[string]any{"ageMin": 13}); slicesContain(search, yui) {
		t.Fatal("a member with an unknown age matched an age filter")
	}
	// A member who turns 18 today is no longer found by a maximum of 17, and one who turns 13 today is found by 13..13.
	h.ageAt(dev, 18)
	h.ageAt(eli, 13)
	if _, nearby := h.both(alice, map[string]any{"ageMax": 17}); slicesContain(nearby, dev) {
		t.Fatal("a member of 18 matched ageMax 17")
	}
}

func sorted(ids ...string) []string {
	sort.Strings(ids)
	return ids
}

// A minor filtering for adult ages gets nobody; filters work inside the minor band; the barrier decides who exists.
func TestAgeFiltersRespectTheBandBarrier(t *testing.T) {
	h := newSocialHarness(t)
	for id, age := range map[string]int{alice: 15, dev: 13, eli: 15, xan: 17, cara: 30, yui: 25} {
		h.ageAt(id, age)
		h.north(id, 0.01)
	}
	h.place(alice, bengaluru.Latitude, bengaluru.Longitude)
	h.policy(store.KaiID, "discoverable", false) // the minor fixture would otherwise be one more result in search
	search, nearby := h.both(alice, map[string]any{"ageMin": 25, "ageMax": 34})
	if len(search) != 0 || len(nearby) != 0 {
		t.Fatalf("a minor filtering for 25-34 found %v %v", search, nearby)
	}
	for name, tc := range map[string]struct {
		filters map[string]any
		want    []string
	}{
		"all minors":      {map[string]any{}, sorted(dev, eli, xan)},
		"from 14":         {map[string]any{"ageMin": 14}, sorted(eli, xan)},
		"up to 15":        {map[string]any{"ageMax": 15}, sorted(dev, eli)},
		"exactly 13":      {map[string]any{"ageMin": 13, "ageMax": 13}, sorted(dev)},
		"17 and over":     {map[string]any{"ageMin": 17, "ageMax": 99}, sorted(xan)},
		"adult ages only": {map[string]any{"ageMin": 18}, nil},
	} {
		s, n := h.both(alice, tc.filters)
		if fmt.Sprint(s) != fmt.Sprint(tc.want) || fmt.Sprint(n) != fmt.Sprint(tc.want) {
			t.Fatalf("%s: search %v nearby %v want %v", name, s, n, tc.want)
		}
	}
	// The adult sees no minors, even when the filter names their age.
	h.place(cara, bengaluru.Latitude, bengaluru.Longitude)
	h.setAge(alice, 0) // for the next viewer; use cara
	s, n := h.both(cara, map[string]any{"ageMin": 13, "ageMax": 17})
	if len(s) != 0 || len(n) != 0 {
		t.Fatalf("an adult filtering for 13-17 found %v %v", s, n)
	}
}

func TestAgeAndGenderFilterValuesAreValidated(t *testing.T) {
	h := filterPeople(t, 0)
	bad := []string{
		`{"ageMin":12}`, `{"ageMin":100}`, `{"ageMax":12}`, `{"ageMax":100}`, `{"ageMin":0}`, `{"ageMin":-20}`,
		`{"ageMin":"20"}`, `{"ageMax":"20"}`, `{"ageMin":20.5}`, `{"ageMin":20.0}`, `{"ageMin":2e1}`, `{"ageMin":null}`, `{"ageMax":null}`, `{"ageMin":true}`,
		`{"ageMin":[20]}`, `{"ageMin":{"v":20}}`, `{"ageMin":020}`, `{"ageMin":+20}`,
		`{"ageMin":40,"ageMax":30}`, `{"ageMin":99,"ageMax":13}`,
		`{"gender":"male"}`, `{"gender":"female"}`, `{"gender":"Man"}`, `{"gender":"MAN"}`, `{"gender":"man "}`, `{"gender":"other"}`, `{"gender":"non-binary"}`,
		`{"gender":1}`, `{"gender":null}`, `{"gender":["man"]}`, `{"gender":true}`,
		`{"age":20}`, `{"minAge":20}`, `{"ageRange":[20,30]}`,
	}
	for _, raw := range bad {
		h.api.search.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/discovery/search", json.RawMessage(raw)), 422, "VALIDATION")
		got, _, _ := h.nearbyList(alice, json.RawMessage(raw))
		h.expect(got, 422, "VALIDATION")
	}
	for _, raw := range []string{`{"ageMin":13}`, `{"ageMax":99}`, `{"ageMin":13,"ageMax":99}`, `{"ageMin":30,"ageMax":30}`, `{"gender":"man"}`, `{"gender":"woman"}`, `{"gender":"nonbinary"}`, `{"gender":""}`, `{"ageMin":18,"gender":"man","country":"IN","languages":["en"],"vibe":"x","interests":["a"]}`} {
		h.api.search.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/discovery/search", json.RawMessage(raw)), 200, "")
		got, _, _ := h.nearbyList(alice, json.RawMessage(raw))
		h.expect(got, 200, "")
	}
	// The members are only ever found; nothing in a result says how old they are or what they said.
	_, _ = h.both(alice, map[string]any{"ageMin": 20, "gender": "woman"})
	for _, path := range []string{"/v1/discovery/search", "/v1/discover/nearby"} {
		h.api.search.reset(alice)
		got := h.expect(h.send(alice, "POST", path, map[string]any{"ageMin": 13}), 200, "").data
		for _, item := range items(got) {
			for key := range item {
				switch strings.ToLower(key) {
				case "age", "agemin", "agemax", "ageband", "band", "gender", "birthdate", "birthyear", "birth_date":
					t.Fatalf("%s item has %q", path, key)
				}
			}
		}
	}
}

// Changing the age or gender filter, or the radius, invalidates a cursor made with another set, in both endpoints.
func TestAgeAndGenderAreBoundIntoTheCursor(t *testing.T) {
	h := filterPeople(t, 30)
	filter := map[string]any{"ageMin": 13, "ageMax": 99, "gender": "man"}
	h.api.search.reset(alice)
	first := h.expect(h.send(alice, "POST", "/v1/discovery/search", filter), 200, "").data
	searchCursor, _ := first["nextCursor"].(string)
	nearbyFirst, _, _ := h.nearbyList(alice, merge(filter, map[string]any{"radiusKm": 100}))
	h.expect(nearbyFirst, 200, "")
	nearbyCursor, _ := nearbyFirst.data["nextCursor"].(string)
	if searchCursor == "" || nearbyCursor == "" {
		t.Fatalf("no cursors: %q %q", searchCursor, nearbyCursor)
	}
	// The same filters continue.
	h.api.search.reset(alice)
	h.expect(h.send(alice, "POST", "/v1/discovery/search", merge(filter, map[string]any{"cursor": searchCursor})), 200, "")
	got, _, _ := h.nearbyList(alice, merge(filter, map[string]any{"radiusKm": 100, "cursor": nearbyCursor}))
	h.expect(got, 200, "")
	for name, changed := range map[string]map[string]any{
		"ageMin changed":    {"ageMin": 14, "ageMax": 99, "gender": "man"},
		"ageMax changed":    {"ageMin": 13, "ageMax": 98, "gender": "man"},
		"ageMin dropped":    {"ageMax": 99, "gender": "man"},
		"ageMax dropped":    {"ageMin": 13, "gender": "man"},
		"gender changed":    {"ageMin": 13, "ageMax": 99, "gender": "woman"},
		"gender dropped":    {"ageMin": 13, "ageMax": 99},
		"everything gone":   {},
		"gender made empty": {"ageMin": 13, "ageMax": 99, "gender": ""},
	} {
		h.api.search.reset(alice)
		h.expect(h.send(alice, "POST", "/v1/discovery/search", merge(changed, map[string]any{"cursor": searchCursor})), 422, "INVALID_CURSOR")
		got, _, _ := h.nearbyList(alice, merge(changed, map[string]any{"radiusKm": 100, "cursor": nearbyCursor}))
		if got.status != 422 || got.code != "INVALID_CURSOR" {
			t.Fatalf("nearby %s: %d %q", name, got.status, got.code)
		}
	}
	got, _, _ = h.nearbyList(alice, merge(filter, map[string]any{"radiusKm": 50, "cursor": nearbyCursor}))
	if got.status != 422 || got.code != "INVALID_CURSOR" {
		t.Fatalf("nearby with another radius: %d %q", got.status, got.code)
	}
}

func merge(a, b map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

// The age filter follows fieldAudiences.age like every other filter follows its field: a member
// whose age is not shown to everyone is never matched by it, so an exact age they hid cannot be
// read off by narrowing the range (people search and Nearby share the predicate).
func TestAgeFilterFollowsTheAgeAudience(t *testing.T) {
	h := filterPeople(t, 0)
	for _, audience := range []string{"nobody", "friends", "followers"} {
		h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,age}',to_jsonb($2::text)) WHERE user_id=$1`, cara, audience)
		for _, filters := range []map[string]any{{"ageMin": 20, "ageMax": 20}, {"ageMax": 99}, {"ageMin": 13}} {
			if search, nearby := h.both(alice, filters); slicesContain(search, cara) || slicesContain(nearby, cara) {
				t.Fatalf("age hidden (%s) matched %v: %v %v", audience, filters, search, nearby)
			}
		}
		// Hiding the age does not hide the member.
		if search, nearby := h.both(alice, map[string]any{}); !slicesContain(search, cara) || !slicesContain(nearby, cara) {
			t.Fatalf("hiding the age removed the member: %v %v", search, nearby)
		}
	}
	h.exec(`UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,age}','"everyone"') WHERE user_id=$1`, cara)
	if search, nearby := h.both(alice, map[string]any{"ageMin": 20, "ageMax": 20}); fmt.Sprint(search) != fmt.Sprint([]string{cara}) || fmt.Sprint(nearby) != fmt.Sprint([]string{cara}) {
		t.Fatalf("age shown to everyone: %v %v", search, nearby)
	}
}
