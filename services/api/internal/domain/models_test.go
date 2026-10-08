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
	p := DefaultPrivacy()
	if p.ProfileAudience != "friends" || p.Discoverable || p.ReadReceipts {
		t.Fatal("unsafe defaults")
	}
	for _, audience := range p.FieldAudiences {
		if audience != "nobody" {
			t.Fatal("field disclosure")
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
	if len(languages) != 2 || languages[1].Code != "ko" || languages[1].Level != "" {
		t.Fatal("legacy proficiency was invented")
	}
	data, _ := json.Marshal(languages)
	if string(data) != `[{"code":"en"},{"code":"ko"}]` {
		t.Fatal(string(data))
	}
}
