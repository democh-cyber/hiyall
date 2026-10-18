package billing

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
)

func bytesReader(b []byte) io.Reader { return bytes.NewReader(b) }

// Hash is the stored form of a store identifier (a transaction id, a purchase token, an original transaction id): hex SHA-256 of
// "<store>:<value>". The identifier itself is never stored or logged.
func Hash(store, value string) string {
	sum := sha256.Sum256([]byte(store + ":" + value))
	return hex.EncodeToString(sum[:])
}
