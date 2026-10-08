package domain

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

var (
	ErrMessagesNotAllowed = &PolicyError{403, "MESSAGES_NOT_ALLOWED", "This account isn't accepting messages from you"}
	ErrDevicesChanged     = &PolicyError{409, "DEVICES_CHANGED", "Devices changed. Refresh them and encrypt again."}
	ErrTooManyDevices     = &PolicyError{409, "TOO_MANY_DEVICES", "Remove a device before adding another"}
	ErrDeviceConflict     = &PolicyError{409, "DEVICE_CONFLICT", "This device id is already registered with different keys"}
	ErrConversationClosed = &PolicyError{403, "CONVERSATION_CLOSED", "This conversation is closed"}
)

// Signed statements bind each public key to its owner and device, so the server
// cannot attach a key to another account without the clients noticing.
func DeviceStatement(userID, deviceID, identityKey, signingKey string) string {
	return strings.Join([]string{"kairova-device-v1", userID, deviceID, identityKey, signingKey}, "\n")
}

func OneTimeKeyStatement(userID, deviceID, keyID, publicKey string) string {
	return strings.Join([]string{"kairova-otk-v1", userID, deviceID, keyID, publicKey}, "\n")
}

// Keys and signatures use vodozemac's unpadded standard base64.
func decodeKey(field, value string, size int) ([]byte, error) {
	raw, err := base64.RawStdEncoding.Strict().DecodeString(value)
	if err != nil || len(raw) != size {
		return nil, invalid(field, "must be an unpadded base64 key")
	}
	return raw, nil
}

func VerifySigned(signingKey, statement, signature string) error {
	key, err := decodeKey("signingKey", signingKey, ed25519.PublicKeySize)
	if err != nil {
		return err
	}
	sig, err := decodeKey("signature", signature, ed25519.SignatureSize)
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(key), []byte(statement), sig) {
		return invalid("signature", "does not verify")
	}
	return nil
}

type Device struct {
	DeviceID    string    `json:"deviceId"`
	UserID      string    `json:"userId"`
	IdentityKey string    `json:"identityKey"`
	SigningKey  string    `json:"signingKey"`
	Signature   string    `json:"signature"`
	Platform    string    `json:"platform"`
	DisplayName string    `json:"displayName"`
	CreatedAt   time.Time `json:"createdAt"`
}

func ParseDevice(userID string, body map[string]json.RawMessage) (Device, error) {
	d := Device{UserID: userID, Platform: "unknown"}
	fields := map[string]*string{"deviceId": &d.DeviceID, "identityKey": &d.IdentityKey, "signingKey": &d.SigningKey, "signature": &d.Signature, "platform": &d.Platform, "displayName": &d.DisplayName}
	for key, raw := range body {
		target, ok := fields[key]
		if !ok {
			return d, invalid(key, "field is not accepted")
		}
		value, err := validateString(key, raw, 0, 200)
		if err != nil {
			return d, err
		}
		*target = value
	}
	if !uuidPattern.MatchString(d.DeviceID) {
		return d, invalid("deviceId", "must be a lowercase UUID")
	}
	if !member(d.Platform, "android", "ios", "web", "linux", "unknown") {
		return d, invalid("platform", "unsupported platform")
	}
	if len([]rune(d.DisplayName)) > 60 {
		return d, invalid("displayName", "must be at most 60 characters")
	}
	if _, err := decodeKey("identityKey", d.IdentityKey, 32); err != nil {
		return d, err
	}
	return d, VerifySigned(d.SigningKey, DeviceStatement(userID, d.DeviceID, d.IdentityKey, d.SigningKey), d.Signature)
}

type OneTimeKey struct {
	KeyID     string `json:"keyId"`
	PublicKey string `json:"publicKey"`
	Signature string `json:"signature"`
}

func (k OneTimeKey) Validate(userID, deviceID, signingKey string) error {
	if k.KeyID == "" || len(k.KeyID) > 64 {
		return invalid("keyId", "must be 1–64 characters")
	}
	if _, err := decodeKey("publicKey", k.PublicKey, 32); err != nil {
		return err
	}
	return VerifySigned(signingKey, OneTimeKeyStatement(userID, deviceID, k.KeyID, k.PublicKey), k.Signature)
}

type KeyUpload struct {
	OneTimeKeys []OneTimeKey `json:"oneTimeKeys"`
	FallbackKey *OneTimeKey  `json:"fallbackKey"`
}

type ClaimedKey struct {
	DeviceID string `json:"deviceId"`
	OneTimeKey
	Fallback bool `json:"fallback"`
}

type Envelope struct {
	DeviceID   string `json:"deviceId"`
	Type       int    `json:"type"`
	Ciphertext string `json:"ciphertext"`
}

type SendMessage struct {
	MessageID      string     `json:"messageId"`
	SenderDeviceID string     `json:"senderDeviceId"`
	Envelopes      []Envelope `json:"envelopes"`
}

func ParseSendMessage(body map[string]json.RawMessage) (SendMessage, error) {
	var m SendMessage
	for key := range body {
		if !member(key, "messageId", "senderDeviceId", "envelopes") {
			return m, invalid(key, "field is not accepted")
		}
	}
	raw, _ := json.Marshal(body)
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&m) != nil {
		return m, invalid("message", "invalid message")
	}
	if !uuidPattern.MatchString(m.MessageID) || !uuidPattern.MatchString(m.SenderDeviceID) {
		return m, invalid("messageId", "messageId and senderDeviceId must be lowercase UUIDs")
	}
	if len(m.Envelopes) == 0 || len(m.Envelopes) > 20 {
		return m, invalid("envelopes", "send 1–20 device envelopes")
	}
	seen := map[string]bool{}
	for _, e := range m.Envelopes {
		if !uuidPattern.MatchString(e.DeviceID) || seen[e.DeviceID] {
			return m, invalid("envelopes", "each envelope needs a distinct device")
		}
		seen[e.DeviceID] = true
		if e.Type != 0 && e.Type != 1 {
			return m, invalid("envelopes", "type must be 0 (pre-key) or 1 (message)")
		}
		decoded, err := base64.RawStdEncoding.Strict().DecodeString(e.Ciphertext)
		if err != nil || len(decoded) < 4 || len(decoded) > 16384 {
			return m, invalid("envelopes", "ciphertext must be unpadded base64 of at most 16 KiB")
		}
	}
	return m, nil
}

type Conversation struct {
	ConversationID string      `json:"conversationId"`
	Peer           UserSummary `json:"peer"`
	Status         string      `json:"status"`
	CreatedAt      time.Time   `json:"createdAt"`
	LastMessageAt  *time.Time  `json:"lastMessageAt"`
}

type InboxItem struct {
	MessageID      string    `json:"messageId"`
	ConversationID string    `json:"conversationId"`
	SenderID       string    `json:"senderId"`
	SenderDeviceID string    `json:"senderDeviceId"`
	SenderIdentity string    `json:"senderIdentityKey"`
	Type           int       `json:"type"`
	Ciphertext     string    `json:"ciphertext"`
	CreatedAt      time.Time `json:"createdAt"`
}
