package domain

import (
	"encoding/json"
	"testing"
)

func TestProfileRejectsIdentityAndUnsafeURL(t *testing.T) {
	for _, input := range []string{`{"userId":"other"}`, `{"version":"2"}`, `{"websiteUrl":"http://unsafe.example"}`, `{"websiteUrl":"https://name:secret@example.com"}`, `{"username":"UPPER"}`, `{"displayName":null}`, `{"timezone":"not/a/zone"}`, `{"avatarMediaId":"unowned"}`, `{}`} {
		var patch map[string]json.RawMessage
		_ = json.Unmarshal([]byte(input), &patch)
		if ValidateProfilePatch(patch) == nil {
			t.Errorf("accepted %s", input)
		}
	}
	var valid map[string]json.RawMessage
	_ = json.Unmarshal([]byte(`{"displayName":"अंजलि","bio":"Hello 🌿","websiteUrl":"https://example.com","timezone":"Asia/Kolkata"}`), &valid)
	if err := ValidateProfilePatch(valid); err != nil {
		t.Fatal(err)
	}
}
func TestPrivacyDefaultsAndUnknownFields(t *testing.T) {
	// Hiyall is open by default: public, discoverable, shows presence, anyone may message and follow,
	// and only the connection lists, stories, comments and mentions stay friends-only.
	p := DefaultPrivacy()
	if p.ProfileAudience != "public" || !p.Discoverable || !p.ShowInterestOverlap || p.OnlineAudience != "everyone" || p.ReadReceipts {
		t.Fatalf("defaults %+v", p)
	}
	for name, want := range map[string]string{
		"storyAudience": p.StoryAudience, "commentsFrom": p.CommentsFrom, "mentionsFrom": p.MentionsFrom,
	} {
		if want != "friends" {
			t.Fatalf("%s default %q, want friends", name, want)
		}
	}
	if p.MessagesFrom != "everyone" || p.FollowPolicy != "everyone" {
		t.Fatalf("messagesFrom %q followPolicy %q, want everyone for both", p.MessagesFrom, p.FollowPolicy)
	}
	if p.FieldAudiences["counts"] != "everyone" {
		t.Fatalf("counts audience %q", p.FieldAudiences["counts"])
	}
	if p.RequestsFrom != "everyone" || p.ActivityAudience != "nobody" || p.LastSeenAudience != "nobody" || p.LocationAudience != "nobody" {
		t.Fatalf("defaults %+v", p)
	}
	if len(p.FieldAudiences) != len(Fields) {
		t.Fatalf("field audiences %v", p.FieldAudiences)
	}
	for field, audience := range p.FieldAudiences {
		want := "everyone"
		switch field {
		case "connections", "aboutMe", "hometown":
			want = "followers"
		case "birthday":
			want = "friends"
		}
		if audience != want {
			t.Fatalf("field %s audience %q, want %q", field, audience, want)
		}
	}
	for _, input := range []string{`{"readReceipts":null}`, `{"fieldAudiences":{"secret":"everyone"}}`, `{"fieldAudiences":{"profession":"public"}}`, `{"messagesFrom":"all"}`, `{"userId":"other"}`} {
		var patch map[string]json.RawMessage
		_ = json.Unmarshal([]byte(input), &patch)
		if ValidatePrivacyPatch(patch) == nil {
			t.Errorf("accepted %s", input)
		}
	}
}

func TestExpressiveProfileValidation(t *testing.T) {
	for _, input := range []string{`{"interests":["Music","music"]}`, `{"interests":[""]}`, `{"interests":null}`, `{"languages":[{"code":"en","level":"expert"}]}`, `{"languages":[{"code":"ko","level":"native","email":"secret"}]}`, `{"languages":["en","EN"]}`, `{"languages":[{"ko":0}]}`, `{"languages":[{"code":"en","level":null}]}`, `{"profileAccent":"red"}`, `{"avatarFrame":"verified"}`, `{"profilePattern":"custom-html"}`, `{"premium":true}`, `{"birthYear":2004}`, `{"email":"private@example.test"}`, `{"coin":99}`, `{"quote":null}`, `{"socialStats":{"friends":85,"following":542,"followers":1200}}`} {
		var patch map[string]json.RawMessage
		_ = json.Unmarshal([]byte(input), &patch)
		if ValidateProfilePatch(patch) == nil {
			t.Errorf("accepted %s", input)
		}
	}
	var patch map[string]json.RawMessage
	_ = json.Unmarshal([]byte(`{"quote":"A little curiosity goes a long way.","headline":"Coffee > meetings ☕","interests":["Music","Finance"],"currentVibe":"📚 Reading","profileAccent":"violet","profilePattern":"orbit","avatarFrame":"orbit","languages":[{"code":"en","level":"fluent"},{"code":"ko"}]}`), &patch)
	if err := ValidateProfilePatch(patch); err != nil {
		t.Fatal(err)
	}
	var languages Languages
	if err := json.Unmarshal([]byte(`["en","ko"]`), &languages); err != nil {
		t.Fatal(err)
	}
	// A language written without a level reads as the default level, and writes back as a structured entry.
	if len(languages) != 2 || languages[1].Code != "ko" || languages[1].Level != LanguageLevelDefault {
		t.Fatal("a bare tag did not read as the default level")
	}
	data, _ := json.Marshal(languages)
	if string(data) != `[{"code":"en","level":3},{"code":"ko","level":3}]` {
		t.Fatal(string(data))
	}
}

// Only bio and quote may contain line breaks; one-line fields refuse them.
func TestOneLineProfileFieldsRefuseLineBreaks(t *testing.T) {
	for _, field := range []string{"displayName", "headline", "currentVibe", "pronouns", "profession", "education", "city", "region"} {
		patch := map[string]json.RawMessage{field: json.RawMessage(`"line one\nline two"`)}
		if ValidateProfilePatch(patch) == nil {
			t.Fatalf("%s accepted a line break", field)
		}
	}
	for _, field := range []string{"bio", "quote"} {
		patch := map[string]json.RawMessage{field: json.RawMessage(`"line one\nline two"`)}
		if err := ValidateProfilePatch(patch); err != nil {
			t.Fatalf("%s refused a line break: %v", field, err)
		}
	}
}

func TestProfileAvatarPatchShapes(t *testing.T) {
	cases := map[string]bool{
		`{"avatarMediaId":null}`:                                            true,
		`{"avatarMediaId":"019a4000-0000-7000-8000-000000000001"}`:          true,
		`{"avatarMediaId":"019A4000-0000-7000-8000-000000000001"}`:          false,
		`{"avatarMediaId":"urn:uuid:019a4000-0000-7000-8000-000000000001"}`: false,
		`{"avatarMediaId":"0190a40000007000800000000000000000"}`:            false,
		`{"avatarMediaId":""}`:                                              false,
		`{"avatarMediaId":5}`:                                               false,
		`{"avatarMediaId":["x"]}`:                                           false,
		`{"coverMediaId":null}`:                                             true,
		`{"coverMediaId":"019a4000-0000-7000-8000-000000000001"}`:           false,
	}
	for input, ok := range cases {
		var patch map[string]json.RawMessage
		_ = json.Unmarshal([]byte(input), &patch)
		if err := ValidateProfilePatch(patch); (err == nil) != ok {
			t.Errorf("%s: accepted=%v err=%v", input, err == nil, err)
		}
	}
}
