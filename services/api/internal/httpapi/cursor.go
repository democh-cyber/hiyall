package httpapi

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
)

// Signed cursors (audit G3). Every paged endpoint hands out a cursor that is the JSON of a small struct,
// base64url, a dot, and an HMAC-SHA256 of the same bytes under CURSOR_KEY. The signature proves the server
// made it; what the cursor is bound to (account, list, filters, an expiry) is a field of the struct that the
// caller checks after sealing and opening. This file is the one place that does the encoding, so the four
// kinds of cursor (sessions, lists, people search, Nearby) cannot drift apart.

// cursorMaxLen bounds what is parsed: no cursor the server makes comes near it.
const cursorMaxLen = 2048

// cursorMAC signs data with the current cursor key. prefix separates uses of the key (it may be empty).
func (a *API) cursorMAC(prefix string, data []byte) []byte {
	return macWith(a.cursorKey[:], prefix, data)
}

// cursorSigValid verifies a signature against the current key, then the previous ones.
func (a *API) cursorSigValid(sig []byte, prefix string, data []byte) bool {
	if hmac.Equal(sig, a.cursorMAC(prefix, data)) {
		return true
	}
	for i := range a.cursorKeyPrevious {
		if hmac.Equal(sig, macWith(a.cursorKeyPrevious[i][:], prefix, data)) {
			return true
		}
	}
	return false
}

func macWith(key []byte, prefix string, data []byte) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(prefix))
	mac.Write(data)
	return mac.Sum(nil)
}

// sealCursor encodes c and signs it. prefix names the use of the key ("" for the common lists, "nearby\x00" for
// Nearby), so a cursor of one kind never verifies as another.
func sealCursor[T any](a *API, prefix string, c T) string {
	data, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(a.cursorMAC(prefix, data))
}

// openCursor decodes raw into c and reports whether the signature is one of ours (the current key or a
// previous one). It checks nothing about the contents: the caller compares the fields that bind the cursor to
// this request (account, list, filters) and its expiry, and treats c as untrusted until then.
func openCursor[T any](a *API, prefix, raw string, c *T) bool {
	if len(raw) > cursorMaxLen {
		return false
	}
	body, sig, found := strings.Cut(raw, ".")
	if !found || strings.Contains(sig, ".") {
		return false
	}
	data, e1 := base64.RawURLEncoding.DecodeString(body)
	mac, e2 := base64.RawURLEncoding.DecodeString(sig)
	return e1 == nil && e2 == nil && a.cursorSigValid(mac, prefix, data) && json.Unmarshal(data, c) == nil
}
