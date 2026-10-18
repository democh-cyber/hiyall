package domain

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestParseTopic(t *testing.T) {
	for _, name := range Topics {
		got, err := ParseTopic(&name)
		if err != nil || got == nil || *got != name {
			t.Fatalf("%s: %v %v", name, got, err)
		}
	}
	empty, blank := "", "  "
	for _, in := range []*string{nil, &empty, &blank} {
		if got, err := ParseTopic(in); got != nil || err != nil {
			t.Fatalf("no topic: %v %v", got, err)
		}
	}
	bad := "politics"
	if _, err := ParseTopic(&bad); err == nil {
		t.Fatal("unknown topic accepted")
	}
}

func TestNoticeBodyAcceptsOnlyParagraphsBoldAndHTTPSLinks(t *testing.T) {
	good := []string{"Hello.\n\nSecond **bold** paragraph.", "See [our tips](https://hiyall.app/safety?a=1#x).", "plain"}
	for _, b := range good {
		if err := ValidateNoticeBody(b); err != nil {
			t.Errorf("%q: %v", b, err)
		}
	}
	bad := map[string]string{
		"html":        "<b>x</b>",
		"http":        "[x](http://example.com)",
		"javascript":  "[x](javascript:alert(1))",
		"data":        "[x](data:text/html;base64,AAAA)",
		"credentials": "[x](https://user:pw@example.com)",
		"no host":     "[x](https:///path)",
		"image":       "![x](https://example.com/a.png)",
		"open bold":   "a **b",
		"broken link": "[x] (https://example.com) and ](https://example.com)",
		"empty":       "",
		"long":        strings.Repeat("a", MaxNoticeBody+1),
	}
	for name, b := range bad {
		if ValidateNoticeBody(b) == nil {
			t.Errorf("%s accepted: %q", name, b)
		}
	}
}

func TestNewNoticeValidate(t *testing.T) {
	now := time.Now()
	ok := NewNotice{Category: "safety", Title: "Hi", Body: "body", Locale: "pt-BR"}
	if err := ok.Validate(now); err != nil || ok.Audience != "all" {
		t.Fatalf("%v %q", err, ok.Audience)
	}
	past := now.Add(-time.Hour)
	for name, n := range map[string]NewNotice{
		"category":  {Category: "ads", Title: "t", Body: "b"},
		"audience":  {Category: "news", Title: "t", Body: "b", Audience: "kids"},
		"locale":    {Category: "news", Title: "t", Body: "b", Locale: "EN us"},
		"title":     {Category: "news", Title: "two\nlines", Body: "b"},
		"expired":   {Category: "news", Title: "t", Body: "b", ExpiresAt: &past},
		"inversion": {Category: "news", Title: "t", Body: "b", PublishedAt: &now, ExpiresAt: &now},
	} {
		if n.Validate(now) == nil {
			t.Errorf("%s accepted", name)
		}
	}
	if !NoticeVisibleTo("minors", true) || NoticeVisibleTo("minors", false) || NoticeVisibleTo("adults", true) || !NoticeVisibleTo("all", true) {
		t.Fatal("audience rule")
	}
}

func TestParseNotificationPrefs(t *testing.T) {
	parse := func(js string) (NotificationPatch, error) {
		var raw map[string]json.RawMessage
		_ = json.Unmarshal([]byte(js), &raw)
		return ParseNotificationPrefs(raw)
	}
	p, err := parse(`{"visits":true,"hideNames":false,"enabled":true}`)
	if err != nil || p.Visits == nil || !*p.Visits || p.HideNames == nil || *p.HideNames || p.Chat != nil {
		t.Fatalf("%+v %v", p, err)
	}
	for _, js := range []string{`{}`, `{"loud":true}`, `{"chat":null}`, `{"chat":"yes"}`} {
		if _, err := parse(js); err == nil {
			t.Errorf("%s accepted", js)
		}
	}
	if d := DefaultNotificationPrefs(true); !d.HideNames || d.Visits || !d.Enabled {
		t.Fatalf("minor default %+v", d)
	}
	if d := DefaultNotificationPrefs(false); d.HideNames || d.Visits {
		t.Fatalf("adult default %+v", d)
	}
}

func TestSupportAndSearchInput(t *testing.T) {
	if _, err := ParseSupportBody("  "); err == nil {
		t.Fatal("blank body")
	}
	if _, err := ParseSupportBody(strings.Repeat("x", MaxSupportBody+1)); err == nil {
		t.Fatal("long body")
	}
	if b, err := ParseSupportBody("  hi there \n"); err != nil || b != "hi there" {
		t.Fatalf("%q %v", b, err)
	}
	if _, err := ParseSupportCategory("billing"); err == nil {
		t.Fatal("category")
	}
	if _, err := ParseSearchQuery("a"); err == nil {
		t.Fatal("short query")
	}
	if _, err := ParseSearchQuery(strings.Repeat("x", MaxSearchQuery+1)); err == nil {
		t.Fatal("long query")
	}
	if q, err := ParseSearchQuery("  guitar  "); err != nil || q != "guitar" {
		t.Fatalf("%q %v", q, err)
	}
}

func TestPostAndStoryNeedTextPhotoOrVoice(t *testing.T) {
	id := "019a4000-0000-7000-8000-000000000001"
	if _, err := ParsePost([]byte(`{"body":"","audience":"public","voiceMediaId":"` + id + `"}`)); err != nil {
		t.Fatalf("voice-only post: %v", err)
	}
	if _, err := ParsePost([]byte(`{"body":"","audience":"public"}`)); err == nil {
		t.Fatal("empty post")
	}
	if _, err := ParseStory([]byte(`{"audience":"public","voiceMediaId":"` + id + `","topic":"music"}`)); err != nil {
		t.Fatalf("voice-only story: %v", err)
	}
	if _, err := ParseStory([]byte(`{"body":"x","audience":"public","topic":"nope"}`)); err == nil {
		t.Fatal("unknown topic")
	}
	if _, err := ParsePost([]byte(`{"body":"x","audience":"public","voiceMediaId":"nope"}`)); err == nil {
		t.Fatal("bad voice id")
	}
}
