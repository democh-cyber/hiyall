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

// IsID reports whether value is an id in canonical form: lowercase, hyphenated, 36
// characters, exactly as the API returns ids. Other spellings uuid.Parse accepts
// (urn:uuid:, braces, 32 hex digits, upper case) are refused, so an id taken from a
// path or body can be compared as a string and cast to uuid without surprises.
func IsID(value string) bool { return uuidPattern.MatchString(value) }

var (
	ErrMessagesNotAllowed = &PolicyError{403, "MESSAGES_NOT_ALLOWED", "This account isn't accepting messages from you"}
	ErrDevicesChanged     = &PolicyError{409, "DEVICES_CHANGED", "Devices changed. Refresh them and encrypt again."}
	// ErrPeerNoDevices answers a send to a person with no active chat device (each was removed as idle or signed
	// out, or they never opened chat): nothing can be encrypted for them yet, and it can be tried again once they
	// open Hiyall (CHAT-N1). Distinct from ErrDevicesChanged, which says "encrypt again for the current devices".
	ErrPeerNoDevices  = &PolicyError{409, "PEER_NO_DEVICES", "They haven't opened Hiyall in a while. Your message can't be delivered yet."}
	ErrTooManyDevices = &PolicyError{409, "TOO_MANY_DEVICES", "Remove a device before adding another"}
	ErrDeviceConflict = &PolicyError{409, "DEVICE_CONFLICT", "This device id is already registered with different keys"}
	// ErrAwaitingReply is the first-contact cap: until the other person has sent a message of their
	// own, a sender may send FirstContactMessages messages in a conversation.
	ErrAwaitingReply      = &PolicyError{403, "AWAITING_REPLY", "You can send more once they reply. Give them a little time."}
	ErrConversationClosed = &PolicyError{403, "CONVERSATION_CLOSED", "This conversation is closed"}
	// ErrRecipientBacklog answers a send when a device that must receive it already holds the most
	// undelivered envelopes a device may (Entitlements.ChatBacklogPerDevice). The caller adds Retry-After.
	// The same code answers a sender who alone already has Entitlements.ChatBacklogPerSenderPerDevice envelopes
	// waiting on a recipient device: nobody else is held back by it.
	// ErrOwnBacklog is its own code (OWN_BACKLOG) when the full device is one of the sender's own other
	// devices, because the person who can fix it is the sender, in Chat devices.
	// Since round 4 (CHAT-N2) it is only answered for a device that is in use: one idle for more than 48 hours
	// that is full for this sender alone is revoked in the send instead, and a peer with no active device gets
	// ErrPeerNoDevices.
	ErrRecipientBacklog = &PolicyError{429, "RECIPIENT_BACKLOG", "They haven't caught up on earlier messages yet. Try again later."}
	ErrOwnBacklog       = &PolicyError{429, "OWN_BACKLOG", "One of your other devices has too many unread messages. Open Hiyall on it, or remove it in Chat devices."}
	// ErrChatDailyLimit is the per-conversation daily message quota (Entitlements.ChatMessagesPerConversationPerDay).
	ErrChatDailyLimit = &PolicyError{429, "CHAT_DAILY_LIMIT", "You've sent a lot of messages in this chat today. Try again later."}
	// ErrNewChatsQuota is the daily cap on starting conversations (Entitlements.NewConversationsPerDay);
	// the caller adds a Retry-After.
	ErrNewChatsQuota = &PolicyError{429, "QUOTA", "You’ve reached today’s limit for starting new chats. Try again later."}
)

// Signed statements bind each public key to its owner and device, so the server
// cannot attach a key to another account without the clients noticing.
func DeviceStatement(userID, deviceID, identityKey, signingKey string) string {
	return strings.Join([]string{"hiyall-device-v1", userID, deviceID, identityKey, signingKey}, "\n")
}

func OneTimeKeyStatement(userID, deviceID, keyID, publicKey string) string {
	return strings.Join([]string{"hiyall-otk-v1", userID, deviceID, keyID, publicKey}, "\n")
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
	// LastSeenAt is shown only to the device's owner, never to peers.
	LastSeenAt *time.Time `json:"lastSeenAt,omitempty"`
	// SessionID is the auth session that registered the device (never serialised). Revoking that
	// session revokes the device (migration 0035).
	SessionID string `json:"-"`
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
	// BlobIDs are the encrypted attachments this message claims: uploaded, unclaimed blobs of the
	// sender in this conversation. The ids are not secret; the descriptor naming them is in the ciphertext.
	BlobIDs []string `json:"blobIds,omitempty"`
	// Aux is an optional hint the relay can read: "reaction" marks a message that is a small
	// auxiliary event (today only an emoji reaction) rather than a conversation turn. The relay cannot
	// see message kinds, so the sender says so. An auxiliary message is delivered like any other but
	// never counts as unread, never pushes and never reorders the chat list (see Store.SendMessage). A
	// sender who lies can only make their own message quieter for the peer. Empty means a normal message.
	Aux string `json:"aux,omitempty"`
}

// AuxReaction is the only Aux value; MaxAuxCiphertext caps each envelope of an auxiliary message
// (decoded bytes), far below the 16 KiB of a normal one: a reaction payload is a few hundred bytes.
const (
	AuxReaction      = "reaction"
	MaxAuxCiphertext = 2048
)

func ParseSendMessage(body map[string]json.RawMessage) (SendMessage, error) {
	return parseSend(body, 20, true)
}

// ParseGroupSendMessage is ParseSendMessage for a group: the same fields and rules, with up to MaxGroupEnvelopes
// envelopes (every device of every member).
func ParseGroupSendMessage(body map[string]json.RawMessage) (SendMessage, error) {
	return parseSend(body, MaxGroupEnvelopes, true)
}

// parseSend reads a message body. allowAux says whether the optional aux and blobIds members are accepted (a group
// control message takes neither).
func parseSend(body map[string]json.RawMessage, maxEnvelopes int, allowAux bool) (SendMessage, error) {
	var m SendMessage
	for key := range body {
		if !member(key, "messageId", "senderDeviceId", "envelopes", "blobIds", "aux") || (!allowAux && (key == "blobIds" || key == "aux")) {
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
	if m.Aux != "" && m.Aux != AuxReaction {
		return m, invalid("aux", "aux must be \"reaction\" when present")
	}
	if m.Aux != "" && len(m.BlobIDs) > 0 {
		return m, invalid("blobIds", "a reaction cannot carry attachments")
	}
	if len(m.BlobIDs) > 0 && !ValidBlobIDs(m.BlobIDs, MaxBlobsPerMessage) {
		return m, invalid("blobIds", "send at most 4 distinct blob ids")
	}
	if len(m.Envelopes) == 0 || len(m.Envelopes) > maxEnvelopes {
		return m, invalid("envelopes", "send 1–"+itoa(maxEnvelopes)+" device envelopes")
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
		if m.Aux != "" && len(decoded) > MaxAuxCiphertext {
			return m, &PolicyError{Status: 413, Code: "TOO_LARGE", Message: "A reaction envelope is at most 2 KiB"}
		}
	}
	return m, nil
}

// ConversationPeer is the other member of a conversation: the usual summary plus presence. Online is
// present (as true) only while the peer is online, and LastSeenAt (RFC 3339, UTC, in PresenceLastSeenBucket
// steps) only when they are not and have been active; both are left out when the peer's onlineAudience does
// not admit the caller, which is exactly how an offline peer with no activity looks. They are never false or null.
type ConversationPeer struct {
	UserSummary
	Online     bool       `json:"online,omitempty"`
	LastSeenAt *time.Time `json:"lastSeenAt,omitempty"`
}

type Conversation struct {
	ConversationID string           `json:"conversationId"`
	Peer           ConversationPeer `json:"peer"`
	Status         string           `json:"status"`
	CreatedAt      time.Time        `json:"createdAt"`
	LastMessageAt  *time.Time       `json:"lastMessageAt"`
	// UnreadCount counts the peer's messages after ReadAt, the caller's pointer.
	UnreadCount int        `json:"unreadCount"`
	ReadAt      *time.Time `json:"readAt"`
	// PeerReadAt is set only when both people have read receipts on.
	PeerReadAt *time.Time `json:"peerReadAt"`
	// MutedUntil is set while the caller has this chat muted; 9999-12-31
	// means until unmuted.
	MutedUntil *time.Time `json:"mutedUntil"`
	// PinnedAt is when the caller pinned this chat (null: not pinned). Pinned chats lead the first page of the list.
	PinnedAt *time.Time `json:"pinnedAt"`
	// HiddenAt is set while the caller has deleted this chat from their list (it shows in the Deleted-chats list
	// and the single GET only); RestoreUntil is then the end of the restore window, HiddenAt plus
	// HiddenChatRetention. The peer never learns of either.
	HiddenAt     *time.Time `json:"hiddenAt"`
	RestoreUntil *time.Time `json:"restoreUntil,omitempty"`
	// SharedInterests lists up to MaxSharedInterests interests both members have on their profiles, matched
	// case-insensitively and spelled and ordered as the caller wrote them. It is empty (never null) when
	// nothing is shared or the peer's interests are not visible to the caller (see Store.fillSharedInterests).
	SharedInterests []string  `json:"sharedInterests"`
	SortAt          time.Time `json:"-"`
	// PeerOnlineAudience is the peer's onlineAudience, read with the row so presence needs no extra query
	// for it (see Store.fillPresence). It is never serialised.
	PeerOnlineAudience string `json:"-"`
}

// HiddenChatRetention is how long a member can restore a chat they deleted from their list. After it the hourly
// job closes the chat for that member: it leaves the Deleted-chats list for good and the app wipes its local history.
const HiddenChatRetention = 30 * 24 * time.Hour

// MaxSharedInterests caps Conversation.SharedInterests.
const MaxSharedInterests = 3

// SharedInterests is the case-insensitive intersection of two interest lists in the order and spelling of
// mine, without duplicates and at most MaxSharedInterests long. The result is never nil.
func SharedInterests(mine, theirs []string) []string {
	result := []string{}
	if len(mine) == 0 || len(theirs) == 0 {
		return result
	}
	other := make(map[string]bool, len(theirs))
	for _, v := range theirs {
		other[strings.ToLower(strings.TrimSpace(v))] = true
	}
	seen := map[string]bool{}
	for _, v := range mine {
		key := strings.ToLower(strings.TrimSpace(v))
		if key == "" || !other[key] || seen[key] {
			continue
		}
		seen[key] = true
		result = append(result, v)
		if len(result) == MaxSharedInterests {
			break
		}
	}
	return result
}

// UnreadSummary feeds the Chats badge.
type UnreadSummary struct {
	Messages      int `json:"messages"`
	Conversations int `json:"conversations"`
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
	// Aux is true for a message the sender marked auxiliary (a reaction or the quiet noop). The app checks that
	// the decrypted kind agrees and drops the message when it does not (re-audit CHAT-3).
	Aux bool `json:"aux,omitempty"`
}
