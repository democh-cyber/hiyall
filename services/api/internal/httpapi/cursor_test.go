package httpapi

import (
	"strings"
	"testing"
)

type testCursor struct {
	User string `json:"u"`
	Page int    `json:"p"`
}

func TestSealAndOpenCursor(t *testing.T) {
	a, b := New(nil, nil, false, ""), New(nil, nil, false, "")
	key := make([]byte, 32)
	key[0] = 1
	a.SetCursorKeys(key)
	b.SetCursorKeys(make([]byte, 32), key) // b signs with another key and still accepts a's cursors

	raw := sealCursor(a, "", testCursor{"u1", 3})
	var got testCursor
	if !openCursor(a, "", raw, &got) || got != (testCursor{"u1", 3}) {
		t.Fatalf("round trip: %v", got)
	}
	if !openCursor(b, "", raw, &got) {
		t.Fatal("a previous key must still verify")
	}
	// The format is the one clients already hold: base64url(JSON) + "." + base64url(HMAC).
	if body, sig, ok := strings.Cut(raw, "."); !ok || strings.ContainsAny(body+sig, "+/=") {
		t.Fatalf("format %q", raw)
	}
	for name, bad := range map[string]string{
		"other use of the key": sealCursor(a, "nearby\x00", testCursor{"u1", 3}),
		"no signature":         strings.Split(raw, ".")[0],
		"extra part":           raw + ".AAAA",
		"empty":                "",
		"tampered body":        "e30" + raw[3:],
		"tampered signature":   raw[:len(raw)-2] + "AA",
		"too long":             strings.Repeat("A", cursorMaxLen+1),
		"not base64":           "!!.!!",
	} {
		var c testCursor
		if openCursor(a, "", bad, &c) {
			t.Errorf("%s: opened", name)
		}
	}
	// A cursor of another key never opens, and a prefixed cursor only under its own prefix.
	other := New(nil, nil, false, "")
	var c testCursor
	if openCursor(other, "", raw, &c) {
		t.Error("a cursor signed by a different key opened")
	}
	nearby := sealCursor(a, nearbyCursorPrefix, testCursor{"u1", 1})
	if !openCursor(a, nearbyCursorPrefix, nearby, &c) || openCursor(a, "", nearby, &c) {
		t.Error("prefix separation")
	}
}
