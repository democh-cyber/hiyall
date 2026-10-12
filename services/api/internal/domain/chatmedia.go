package domain

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"time"
)

// Encrypted chat attachments (docs/security/14-encrypted-chat-attachments.md). The server stores
// opaque ciphertext objects and never learns what is inside them.
const (
	// MaxBlobsPerMessage is how many blobs one message may claim: full and thumb now, more with video.
	MaxBlobsPerMessage = 4
	// MinBlobBytes is the smallest ciphertext accepted: an AEAD tag alone is 16 bytes and no image is that small.
	MinBlobBytes = 32
	// Per-role ciphertext caps.
	MaxFullBlobBytes  = 4 << 20
	MaxThumbBlobBytes = 256 << 10
	// Unattached blobs (pending or uploaded) expire after an hour. The per-member quotas and how long a
	// linked blob is kept (30 days on Free) are Entitlements, not constants.
	UnattachedBlobTTL = time.Hour
	// MaxAttachmentDescriptor bounds the descriptor a reporter shares as evidence.
	MaxAttachmentDescriptor = 4096
)

// BlobRoles maps each role to its ciphertext size cap.
var BlobRoles = map[string]int64{"full": MaxFullBlobBytes, "thumb": MaxThumbBlobBytes}

var (
	ErrBlobNotReady          = &PolicyError{409, "BLOB_NOT_READY", "Finish uploading the photo first"}
	ErrBlobSizeMismatch      = &PolicyError{409, "BLOB_SIZE_MISMATCH", "The uploaded file isn't the size you declared. Start the upload again."}
	ErrBlobExpired           = &PolicyError{410, "BLOB_EXPIRED", "This photo is no longer available"}
	ErrAttachmentsNotAllowed = &PolicyError{403, "ATTACHMENTS_NOT_ALLOWED", "You can send photos once they have replied or you are friends"}
	ErrBlobTooLarge          = &PolicyError{413, "TOO_LARGE", "That file is too large"}
	ErrChatMediaUnavailable  = &PolicyError{503, "CHAT_MEDIA_UNAVAILABLE", "Photo sending isn't available right now"}
)

// NewBlob is a request for an upload slot.
type NewBlob struct {
	Role      string
	SizeBytes int64
	// CtSha256 is the 32-byte SHA-256 of the whole ciphertext; the request carries it as standard padded base64.
	CtSha256 []byte
}

// CtSha256Base64 is the hash in the form of the x-amz-checksum-sha256 header.
func (b NewBlob) CtSha256Base64() string { return base64.StdEncoding.EncodeToString(b.CtSha256) }

// ParseNewBlob validates {role, sizeBytes, ctSha256}. A size over the role's cap is the 413 TOO_LARGE
// refusal, anything else malformed is a 422.
func ParseNewBlob(body map[string]json.RawMessage) (NewBlob, error) {
	var b NewBlob
	for key := range body {
		if !member(key, "role", "sizeBytes", "ctSha256") {
			return b, invalid(key, "field is not accepted")
		}
	}
	var role, hash string
	if json.Unmarshal(body["role"], &role) != nil {
		return b, invalid("role", "must be full or thumb")
	}
	limit, ok := BlobRoles[role]
	if !ok {
		return b, invalid("role", "must be full or thumb")
	}
	b.Role = role
	// An integer only: 1e3 or 12.0 are not sizes.
	d := json.NewDecoder(bytes.NewReader(body["sizeBytes"]))
	d.UseNumber()
	var number json.Number
	if len(body["sizeBytes"]) == 0 || body["sizeBytes"][0] == '"' || d.Decode(&number) != nil {
		return b, invalid("sizeBytes", "must be an integer")
	}
	size, err := number.Int64()
	if err != nil || size < MinBlobBytes {
		return b, invalid("sizeBytes", "must be an integer of at least 32 bytes")
	}
	if size > limit {
		return b, ErrBlobTooLarge
	}
	b.SizeBytes = size
	if json.Unmarshal(body["ctSha256"], &hash) != nil {
		return b, invalid("ctSha256", "must be the base64 SHA-256 of the ciphertext")
	}
	raw, err := base64.StdEncoding.Strict().DecodeString(hash)
	if err != nil || len(raw) != 32 || base64.StdEncoding.EncodeToString(raw) != hash {
		return b, invalid("ctSha256", "must be the base64 SHA-256 of the ciphertext")
	}
	b.CtSha256 = raw
	return b, nil
}

// ValidBlobIDs checks the ids a message or an evidence attachment lists: canonical, distinct and at most max.
func ValidBlobIDs(ids []string, max int) bool {
	if len(ids) == 0 || len(ids) > max {
		return false
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if !uuidPattern.MatchString(id) || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}

// EvidenceAttachment is an image the reporter chose to share with a reported message. Descriptor is the
// decrypted attachment descriptor (including the key); it is shared only with the reporter's consent and
// the server keeps it as an opaque object. Blob ids must belong to the evidence message.
type EvidenceAttachment struct {
	BlobIDs    []string        `json:"blobIds"`
	Descriptor json.RawMessage `json:"descriptor"`
}

// BlobInfo is what the moderation tool may show about a held blob: never a key or a descriptor.
type BlobInfo struct {
	BlobID    string
	Role      string
	SizeBytes int64
	CtSha256  string
	State     string
}
