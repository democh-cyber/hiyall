package admin

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// TOTP per RFC 6238 with the parameters every authenticator app supports: HMAC-SHA1, 30 second steps,
// 6 digits. A code is accepted one step either side of now to allow for clock drift; the step that
// matched is returned so the caller can refuse to accept it twice.
const (
	totpPeriod = 30
	totpDigits = 6
	totpSkew   = 1
)

// NewTOTPSecret returns 160 random bits, the size RFC 4226 recommends.
func NewTOTPSecret() []byte {
	b := make([]byte, 20)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

// TOTPStep is the 30 second counter for t.
func TOTPStep(t time.Time) int64 { return t.Unix() / totpPeriod }

// TOTPCode is the code for a step (RFC 4226 dynamic truncation).
func TOTPCode(secret []byte, step int64) string {
	var counter [8]byte
	binary.BigEndian.PutUint64(counter[:], uint64(step))
	m := hmac.New(sha1.New, secret)
	m.Write(counter[:])
	sum := m.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	return fmt.Sprintf("%0*d", totpDigits, value%1_000_000)
}

// VerifyTOTP checks code against the steps around now. Every candidate step is always compared, in
// constant time, whatever matched, so timing says nothing about which window a near miss fell in.
// It returns the matching step (the latest, if the secret collides across two) and whether any matched.
func VerifyTOTP(secret []byte, code string, now time.Time) (int64, bool) {
	code = strings.ReplaceAll(code, " ", "")
	valid := len(code) == totpDigits
	for _, c := range code {
		valid = valid && c >= '0' && c <= '9'
	}
	if !valid {
		code = strings.Repeat("x", totpDigits) // still do the comparisons below
	}
	var matched int64
	found := 0
	current := TOTPStep(now)
	for step := current - totpSkew; step <= current+totpSkew; step++ {
		eq := subtle.ConstantTimeCompare([]byte(TOTPCode(secret, step)), []byte(code))
		if eq == 1 {
			matched = step
		}
		found |= eq
	}
	return matched, found == 1 && valid
}

// OTPAuthURI is the enrolment URI an authenticator app scans or imports.
func OTPAuthURI(issuer, account string, secret []byte) string {
	b32 := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(secret)
	label := url.PathEscape(issuer) + ":" + url.PathEscape(account)
	q := url.Values{"secret": {b32}, "issuer": {issuer}, "algorithm": {"SHA1"}, "digits": {"6"}, "period": {"30"}}
	return "otpauth://totp/" + label + "?" + q.Encode()
}

// TOTPSecretText is the secret in the base32 form apps accept for manual entry.
func TOTPSecretText(secret []byte) string {
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(secret)
}
