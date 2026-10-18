package domain

import (
	"encoding/base64"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

func body(t *testing.T, value string) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(value), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestParseNewBlob(t *testing.T) {
	sum := base64.StdEncoding.EncodeToString(make([]byte, 32))
	ok, err := ParseNewBlob(body(t, `{"role":"thumb","sizeBytes":262144,"ctSha256":"`+sum+`"}`), Free())
	if err != nil || ok.Role != "thumb" || ok.SizeBytes != 262144 || ok.CtSha256Base64() != sum {
		t.Fatalf("%+v %v", ok, err)
	}
	if _, err = ParseNewBlob(body(t, `{"role":"full","sizeBytes":4194304,"ctSha256":"`+sum+`"}`), Free()); err != nil {
		t.Fatal(err)
	}
	if _, err = ParseNewBlob(body(t, `{"role":"thumb","sizeBytes":262145,"ctSha256":"`+sum+`"}`), Free()); err != ErrBlobTooLarge {
		t.Fatalf("thumb over its cap: %v", err)
	}
	if _, err = ParseNewBlob(body(t, `{"role":"full","sizeBytes":99999999999999999999,"ctSha256":"`+sum+`"}`), Free()); err == nil {
		t.Fatal("huge size accepted")
	}
	for role, cap := range map[string]int64{"voice": 8 << 20, "video": 40 << 20} {
		fits := `{"role":"` + role + `","sizeBytes":` + strconv.FormatInt(cap, 10) + `,"ctSha256":"` + sum + `"}`
		over := `{"role":"` + role + `","sizeBytes":` + strconv.FormatInt(cap+1, 10) + `,"ctSha256":"` + sum + `"}`
		if b, err := ParseNewBlob(body(t, fits), Free()); err != nil || b.Role != role {
			t.Fatalf("%s at its cap: %v", role, err)
		}
		if _, err := ParseNewBlob(body(t, over), Free()); err != ErrBlobTooLarge {
			t.Fatalf("%s over its cap: %v", role, err)
		}
	}
	// The voice and video caps are entitlements: a smaller one is what applies.
	small := Free()
	small.VideoMaxBlobBytes = 1 << 20
	if _, err := ParseNewBlob(body(t, `{"role":"video","sizeBytes":1048577,"ctSha256":"`+sum+`"}`), small); err != ErrBlobTooLarge {
		t.Fatalf("video over a smaller entitlement: %v", err)
	}
	for _, bad := range []string{
		`{"role":"full","sizeBytes":31,"ctSha256":"` + sum + `"}`,
		`{"role":"full","sizeBytes":"100","ctSha256":"` + sum + `"}`,
		`{"role":"full","sizeBytes":100.5,"ctSha256":"` + sum + `"}`,
		`{"role":"full","sizeBytes":100,"ctSha256":"` + strings.TrimRight(sum, "=") + `"}`,
		`{"role":"audio","sizeBytes":100,"ctSha256":"` + sum + `"}`,
		`{"role":"full","sizeBytes":100,"ctSha256":"` + sum + `","extra":1}`,
		`{"sizeBytes":100,"ctSha256":"` + sum + `"}`,
		`{"role":"full","ctSha256":"` + sum + `"}`,
		`{"role":"full","sizeBytes":100}`,
	} {
		if _, err := ParseNewBlob(body(t, bad), Free()); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}

func TestSendMessageBlobIDs(t *testing.T) {
	id := "019a4000-0000-7000-8000-0000000000a1"
	base := `{"messageId":"` + id + `","senderDeviceId":"` + id + `","envelopes":[{"deviceId":"019a4000-0000-7000-8000-0000000000a2","type":0,"ciphertext":"AAAAAA"}]`
	for body, ok := range map[string]bool{
		base + `}`:                                           true,
		base + `,"blobIds":[]}`:                              true,
		base + `,"blobIds":null}`:                            true,
		base + `,"blobIds":["` + id + `"]}`:                  true,
		base + `,"blobIds":["` + id + `","` + id + `"]}`:     false,
		base + `,"blobIds":["` + strings.ToUpper(id) + `"]}`: false,
		base + `,"blobIds":"` + id + `"}`:                    false,
		base + `,"blobIds":[1]}`:                             false,
	} {
		var raw map[string]json.RawMessage
		if err := json.Unmarshal([]byte(body), &raw); err != nil {
			t.Fatal(err)
		}
		if _, err := ParseSendMessage(raw); (err == nil) != ok {
			t.Fatalf("%s: %v", body, err)
		}
	}
	five := `"` + strings.Join([]string{"019a4000-0000-7000-8000-0000000000b1", "019a4000-0000-7000-8000-0000000000b2", "019a4000-0000-7000-8000-0000000000b3", "019a4000-0000-7000-8000-0000000000b4", "019a4000-0000-7000-8000-0000000000b5"}, `","`) + `"`
	var raw map[string]json.RawMessage
	_ = json.Unmarshal([]byte(base+`,"blobIds":[`+five+`]}`), &raw)
	if _, err := ParseSendMessage(raw); err == nil {
		t.Fatal("five blobs accepted")
	}
}

func TestEvidenceAttachmentsAreValidated(t *testing.T) {
	id := "019a4000-0000-7000-8000-0000000000a1"
	report := func(evidence string) error {
		_, err := ParseReport([]byte(`{"targetType":"conversation","targetId":"` + id + `","reasonCode":"spam","disclosureConsent":true,"evidence":[` + evidence + `]}`))
		return err
	}
	msg := func(attachments string) string {
		return `{"messageId":"` + id + `","text":"photo","sentAt":"2026-10-12T10:00:00Z"` + attachments + `}`
	}
	if err := report(msg(``)); err != nil {
		t.Fatal(err)
	}
	if err := report(msg(`,"attachments":[{"blobIds":["` + id + `"],"descriptor":{"key":"k"}}]`)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		`,"attachments":[{"blobIds":[],"descriptor":{}}]`,
		`,"attachments":[{"blobIds":["` + id + `"]}]`,
		`,"attachments":[{"blobIds":["` + id + `"],"descriptor":"k"}]`,
		`,"attachments":[{"blobIds":["` + id + `"],"descriptor":null}]`,
		`,"attachments":[{"blobIds":["` + id + `"],"descriptor":{"pad":"` + strings.Repeat("x", 4100) + `"}}]`,
		`,"attachments":[{"blobIds":["nope"],"descriptor":{}}]`,
		`,"attachments":[{"blobIds":["` + id + `"],"descriptor":{},"x":1}]`,
	} {
		if err := report(msg(bad)); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}
