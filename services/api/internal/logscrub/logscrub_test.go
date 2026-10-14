package logscrub

import (
	"errors"
	"strings"
	"testing"
)

func TestURLsAreHidden(t *testing.T) {
	in := `Get "https://bucket.r2.example/media/x/full.jpg?X-Amz-Signature=abc123": dial tcp: lookup failed; also postgres://u:p@h/db`
	got := URLs(in)
	if strings.Contains(got, "abc123") || strings.Contains(got, "u:p") || !strings.Contains(got, "[url]") {
		t.Fatalf("%q", got)
	}
	if Err(nil) != "" || Err(errors.New("see http://x/y?token=1")) != "see [url]" {
		t.Fatal("Err")
	}
	if URLs("no url here: 10:30") != "no url here: 10:30" {
		t.Fatal("changed plain text")
	}
}
