# Chat voice messages, videos and the chat list (Wave 7)

Server contract for three chat features, and the app's payload rules for the two new message kinds. The chat stays end-to-end encrypted: the server relays ciphertext, stores opaque blobs and keeps a few per-member flags on the chat list. It never learns what a message is, how long it is or what language it is in. Design and crypto: [encrypted chat attachments](../security/14-encrypted-chat-attachments.md), [encrypted chat implementation](../security/13-encrypted-chat-implementation.md). The blob routes themselves are in [chat attachments](21-chat-attachments.md).

Code: migration `0049_chat_features.sql`, `services/api/internal/store/chatlist.go`, `internal/httpapi/chatlist.go`, `internal/domain/chatmedia.go` (`BlobRoleCap`), `internal/domain/entitlements.go`, the `hidden chat close` job in `cmd/api/main.go`. Tests: `internal/httpapi/chat_features_test.go`.

## Voice and video blobs

A voice message is one blob with role `voice`, a video is two: `thumb` (a JPEG poster, the same thumbnail as a photo) and `video`. They use the existing slot, upload, complete, link and download routes and the existing quotas (`BlobsPerDay`, `BlobBytesPerDay`, `PendingBlobs`), the same "peer replied or friends" gate and the same 30 day retention after the message is sent.

| Role | Ciphertext cap (Free) | Source |
|---|---|---|
| `full` | 4 MiB | constant |
| `thumb` | 256 KiB | constant |
| `voice` | 8 MiB | `Entitlements.VoiceMaxBlobBytes` |
| `video` | 40 MiB | `Entitlements.VideoMaxBlobBytes` |

Over the cap is `413 TOO_LARGE`; an unknown role is `422 VALIDATION`. The server enforces **bytes only**. The length of a voice message (at most 300 s, `Entitlements.VoiceMaxSeconds`) and of a video (at most 60 s, `VideoMaxSeconds`), the mime type (`audio/mp4`, `video/mp4`), the waveform and the picture size are inside the encrypted descriptor, so the server cannot see or check them: they are rules of the sending and the receiving app, and a modified app can exceed them as far as the byte cap allows. The receiving app treats every descriptor as untrusted input.

Single `PUT` of up to 40 MiB: the upload goes straight to the object store, never through the API, so the API's 15 second server timeouts do not apply; the signed URL lives 15 minutes (`uploadURLLifetime`) and pins `Content-Type`, `x-amz-checksum-sha256` and the exact size, as for photos. S3 and R2 accept a single `PUT` of up to 5 GiB, so no multipart upload is needed. The app's HTTP client must allow a slow uplink to finish inside those 15 minutes.

**Reporting.** A voice or video blob is shared as report evidence exactly like a photo: `attachments: [{blobIds, descriptor}]` on the evidence message (at most four blob ids), the blobs are held against deletion, and staff see ids, roles, sizes and hashes only. Covered by `TestVoiceAndVideoBlobsAreShareableAsReportEvidence`.

## Pinned chats, deleted chats, the list order

Group chats ([group chat](29-group-chat.md)) use these same routes by their id and share the pin cap with one-to-one chats; their list is `GET /v1/groups`.

All state is on the caller's own `conversation_members` row (`pinned_at`, `hidden_at`, `closed_at`); the peer is never told and sees nothing. Every write signals the caller's other devices (`inbox`).

### `PUT /v1/conversations/{conversationId}/pin`

Body exactly `{"pinned": true|false}`. `200 {"pinned": true, "pinnedAt": "…"}` (`pinnedAt` null when unpinned). Pinning needs a chat in the caller's visible list (not deleted, not barred, conversation active, peer active), otherwise `404 NOT_FOUND`. At most `Entitlements.ChatPinsMax` (5 on Free) chats are pinned: counting and updating run in one transaction under the member's own lock, so two pins at the same time cannot both pass at four; the sixth is `409 PIN_LIMIT` ("You can pin up to 5 chats"). Pinning a pinned chat succeeds and keeps its `pinnedAt`. A pinned chat that becomes unreachable (a block) frees its slot. Unpinning is allowed on any chat of the caller.

### `POST /v1/conversations/{conversationId}/hide`

No body. Deletes the chat from the caller's list: `hidden_at` is set (the earlier time is kept if it was hidden already), the pin is cleared, the unread count stays. Nothing else is touched: no message, no blob, not the peer's row. `200 {"hidden": true, "hiddenAt": "…", "restoreUntil": "<hiddenAt + 30 days>"}`. Not a member, or a chat already closed: `404`.

### `POST /v1/conversations/{conversationId}/restore`

No body. `200 {"hidden": false}`. Only a chat that is hidden, not closed and hidden less than 30 days ago can be restored; anything else is `404 NOT_FOUND`.

### `GET /v1/conversations/hidden`

```json
{"items": [ <Conversation with hiddenAt and restoreUntil> ], "closedIds": ["<conversation id>"], "retentionDays": 30}
```

`items`: the caller's Deleted chats (hidden, not closed, hidden under 30 days ago, peer reachable: no block, same age band), most recently hidden first, at most 100, no paging. `closedIds`: the conversations closed for the caller within the last 90 days (at most 200, newest first); the app wipes its local history of those, which also covers a phone that was offline when the job ran.

### `Conversation` additions

`pinnedAt` (time or null) and `hiddenAt` (time or null; `restoreUntil` beside it when set). Everything else is unchanged.

### `GET /v1/conversations`

Returns chats that are not deleted. Pinned chats (at most `ChatPinsMax`, most recent activity first) lead the **first page** (no cursor); the cursor runs over the unpinned chats only (`sort_at` then id, as before), so a pinned chat never appears again on a later page and the first page may hold up to `limit` plus the pinned ones.

### Coming back, and the 30 day close

- A message that is a conversation turn (not a reaction, not the quiet `noop`) sets `hidden_at` and `closed_at` to null on **both** rows in the same update that bumps `sort_at`. So a new message from the peer brings the chat back with its history (the app kept it), and so does the member sending one. Reactions never bring a chat back.
- `OpenConversation` (opening a chat on purpose, from a profile or the list) clears the caller's own `hidden_at`/`closed_at`.
- The hourly job `hidden chat close` (`Store.CloseExpiredHiddenChats`) sets `closed_at = now()` and `unread_count = 0` for rows hidden more than 30 days ago. Closed means: out of the Deleted-chats list for good, not restorable, listed in `closedIds` for 90 days. The server keeps no messages for a member (undelivered ciphertext expires by itself after 30 days and delivered after 7), so the job deletes no message; the app wipes its **local** history. A later message from the peer reopens the chat as a fresh, visible one.
- The badge (`GET /v1/conversations/unread`) leaves out deleted chats.

### Errors

`409 PIN_LIMIT`; `404 NOT_FOUND` (not a member, barred, not pinnable, nothing to restore); `422 VALIDATION` (pin body); `429 RATE_LIMITED` (the graph limiter).

## Payload kinds (app)

The two new message kinds are described, with the decoder limits, in [encrypted chat attachments, "Voice and video"](../security/14-encrypted-chat-attachments.md#voice-messages-and-videos-wave-7). The text fallback for older apps is "Sent a voice message. Update Hiyall to play it." and "Sent a video. Update Hiyall to watch it."

## What the server cannot do (on purpose)

Translation, text-to-speech, language detection and search of message text run on the phone, over the decrypted local history only. The server has no endpoint for any of them, and nothing about them is sent to it. See [encrypted chat implementation](../security/13-encrypted-chat-implementation.md#on-device-translation-and-reading-aloud-wave-7). A "sentence correction" feature that needs an online model is not built for the same reason.
