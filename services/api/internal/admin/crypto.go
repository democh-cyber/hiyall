package admin

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

// PasswordParams are the argon2id cost parameters. They are stored in every hash, so raising them
// later does not invalidate existing passwords. 64 MiB, 3 passes and 2 lanes is above the OWASP
// minimum (19 MiB, 2 passes); tests lower it to keep the suite quick.
type PasswordParams struct {
	Time, Memory uint32 // memory in KiB
	Threads      uint8
}

// DefaultPasswordParams is what new password hashes use.
var DefaultPasswordParams = PasswordParams{Time: 3, Memory: 64 * 1024, Threads: 2}

const (
	argonKeyLen  = 32
	argonSaltLen = 16
	// MinPasswordLength and MaxPasswordLength bound what the CLI accepts and what login will hash.
	MinPasswordLength = 12
	MaxPasswordLength = 256
)

// HashPassword returns the PHC string of an argon2id hash of password.
func HashPassword(password string, p PasswordParams) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	sum := argon2.IDKey([]byte(password), salt, p.Time, p.Memory, p.Threads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, p.Memory, p.Time, p.Threads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(sum)), nil
}

// VerifyPassword reports whether password matches the PHC string. A malformed or out-of-range hash is
// an error, never a match. The comparison is constant time.
func VerifyPassword(password, encoded string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != "v=19" {
		return false, errors.New("unsupported password hash")
	}
	var p PasswordParams
	for _, kv := range strings.Split(parts[3], ",") {
		k, v, ok := strings.Cut(kv, "=")
		n, err := strconv.ParseUint(v, 10, 32)
		if !ok || err != nil {
			return false, errors.New("malformed password hash")
		}
		switch k {
		case "m":
			p.Memory = uint32(n)
		case "t":
			p.Time = uint32(n)
		case "p":
			p.Threads = uint8(n)
		}
	}
	// Bounds protect the process from a hash row someone tampered with.
	if p.Time < 1 || p.Time > 10 || p.Memory < 8 || p.Memory > 1<<20 || p.Threads < 1 || p.Threads > 16 {
		return false, errors.New("password hash parameters out of range")
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(salt) < 8 {
		return false, errors.New("malformed password hash")
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(want) < 16 {
		return false, errors.New("malformed password hash")
	}
	got := argon2.IDKey([]byte(password), salt, p.Time, p.Memory, p.Threads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// keys derives every secret the console needs from the one ADMIN_DATA_KEY, each under its own label,
// so a value from one use (a cursor signature, say) is worthless in another.
type keys struct{ root []byte }

func newKeys(root []byte) (keys, error) {
	if len(root) != 32 {
		return keys{}, errors.New("ADMIN_DATA_KEY must be 32 random bytes, base64 encoded")
	}
	return keys{root: append([]byte(nil), root...)}, nil
}

func (k keys) derive(label string) []byte {
	m := hmac.New(sha256.New, k.root)
	m.Write([]byte("hiyall-admin/" + label))
	return m.Sum(nil)
}

// mac is HMAC-SHA256 of data under the key for label.
func (k keys) mac(label string, data ...string) []byte {
	m := hmac.New(sha256.New, k.derive(label))
	for _, d := range data {
		m.Write([]byte(strconv.Itoa(len(d)) + ":"))
		m.Write([]byte(d))
	}
	return m.Sum(nil)
}

func (k keys) aead() cipher.AEAD {
	block, err := aes.NewCipher(k.derive("seal"))
	if err != nil {
		panic(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}
	return gcm
}

// seal encrypts plain, binding it to aad (the operator id), as nonce||ciphertext.
func (k keys) seal(plain []byte, aad string) []byte {
	g := k.aead()
	nonce := make([]byte, g.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return g.Seal(nonce, nonce, plain, []byte(aad))
}

func (k keys) open(sealed []byte, aad string) ([]byte, error) {
	g := k.aead()
	if len(sealed) < g.NonceSize()+g.Overhead() {
		return nil, errors.New("sealed value too short")
	}
	return g.Open(nil, sealed[:g.NonceSize()], sealed[g.NonceSize():], []byte(aad))
}

// randomToken is 256 bits from the system CSPRNG, URL-safe base64.
func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func tokenHash(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}
