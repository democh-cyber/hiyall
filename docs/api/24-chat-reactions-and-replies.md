# Chat reactions and replies (API)

Reactions and replies are end-to-end encrypted payloads; the full protocol, validation and ordering rules are in [the security record](../security/13-encrypted-chat-implementation.md#reactions-and-replies). The server's part is one optional field on the existing send request and the rules that follow from it. There are no new routes.

## Send request

`POST /v1/conversations/{conversationId}/messages` (as before: `messageId`, `senderDeviceId`, `envelopes`, optional `blobIds`) gains an optional `aux`:

```json
{"messageId":"…","senderDeviceId":"…","aux":"reaction",
 "envelopes":[{"deviceId":"…","type":1,"ciphertext":"<unpadded base64>"}]}
```

| Field | Rules |
|---|---|
| `aux` | Optional string. The only value is `"reaction"`. `""` and `null` mean an ordinary message; anything else (`true`, `"typing"`, `"Reaction"`, a number) is `422 VALIDATION`. A reaction cannot carry `blobIds` (`422 VALIDATION`). Older apps never send it and are unchanged. |

The relay cannot read message kinds, so this is a hint set by the sender. It is a deliberate metadata leak (the relay can see which messages are reactions, not what they refer to or say) and a lying sender can only make their own message quieter for the peer; see the security record.

## What a message with `aux` does and does not do

| | Ordinary message | `aux: "reaction"` |
|---|---|---|
| Block, age band, `messagesFrom`, exact device set (`DEVICES_CHANGED`), idempotency by `messageId` | yes | yes, unchanged |
| Per-account send limiter (`messages`: 5 a second, burst 40, `429 RATE_LIMITED`) | yes | **yes, the same bucket** |
| Per-conversation reaction limiter (`aux_messages`) | no | burst 60, one token back every 10 seconds, so 60 per 10 minutes sustained, per sender per conversation. `429 RATE_LIMITED` with `Retry-After` (seconds, 1 to 10) |
| Envelope size | at most 16 KiB decoded | **at most 2048 bytes decoded each**, else `413 TOO_LARGE` |
| Peer's unread counter and `GET /v1/conversations/unread` | +1 | unchanged |
| Conversation order (`last_message_at`, the member sort key) | moves to the top | unchanged |
| Sender's read pointer | advances to the message | unchanged |
| Push notification | yes, if the peer's rules allow | **never** |
| Realtime `inbox` signal to both people's devices | yes | yes |
| Counts as "the peer has replied" (unlocks photos, `messagesFrom` reply-after-contact) | yes | **no** |
| Counts as a message for "has this pair exchanged messages" (new-chat limiter) | yes | no |
| Report evidence | selectable | not selectable; if sent in `evidence` it is dropped, not an error |
| Retention, ack, expiry of envelopes | 7 days delivered, 30 undelivered | same |

An idempotent replay of a stored reaction is answered from the stored row and stays quiet whatever the replay's own `aux` says.

The limiter is the shared `ratelimit` package: in memory per node by default, one bucket per key through the database with `RATE_LIMIT_BACKEND=postgres`. The key is `<userId>:<conversationId>`. Counting is by token bucket: from a full bucket a sender can send 60 at once and then one every ten seconds. There is no per-day message quota in the API today (only new conversations per day), so there is nothing else for a reaction to count against beyond the send limiter above.

## Storage

Migration `0032_message_aux.sql`: `ALTER TABLE messages ADD COLUMN aux boolean NOT NULL DEFAULT false`. Existing rows are ordinary messages. The flag is read by the unread recount (`POST /read`), the reply gates and report evidence.

## Errors

`422 VALIDATION` (bad `aux`, `aux` with `blobIds`), `413 TOO_LARGE` (a reaction envelope over 2048 bytes), `429 RATE_LIMITED` (either limiter; the reaction limiter's message is "You're reacting a lot. Try again in a moment."), and everything a message send can already return (`404`, `403 MESSAGES_NOT_ALLOWED`, `403 CONVERSATION_CLOSED`, `409 DEVICES_CHANGED`).
