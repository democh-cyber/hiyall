# Encrypted chat attachments (server)

The server side of [encrypted chat attachments](../security/14-encrypted-chat-attachments.md) (phase 1: images). A member's device compresses and encrypts the image, uploads the ciphertext straight to a separate storage bucket, and sends the key, hash and descriptor inside the end-to-end encrypted message. The server authorizes, size-checks, rate-limits and expires opaque blobs. It never sees a key or a plaintext byte, and cannot scan, transcode or moderate them. Implemented in migration `0023_chat_blobs.sql`, `services/api/internal/store/chatmedia.go`, `internal/httpapi/chatmedia.go`, `internal/domain/chatmedia.go` and `internal/media/media.go`. Tests are in `internal/httpapi/chatmedia_test.go`; `scripts/chat-blob-e2e.py` checks a running API against the real bucket.

The flow, as the app uses it:

1. `POST /v1/conversations/{id}/blobs` for each blob (`full`, then `thumb`): get a signed PUT URL.
2. `PUT` the ciphertext to that URL with exactly the returned headers. The signature pins the content type, the SHA-256 and the exact body size (`sizeBytes`): storage refuses another content type, another checksum (`400`), another length (`403`, a larger or a smaller body) and a request without the signed headers. `Content-Length` is signed but is not in the returned headers: the HTTP client sets it from the body, as browsers do not allow setting it.
3. `POST /v1/blobs/{blobId}/complete`.
4. `POST /v1/conversations/{id}/messages` with `blobIds` and the usual envelopes (the descriptor naming the blobs is inside the ciphertext).
5. The peer reads the descriptor, asks `GET /v1/conversations/{id}/blobs/{blobId}/url`, downloads the ciphertext, checks its SHA-256 against the descriptor and decrypts.

All routes need a finished onboarding like the rest of the chat routes. Ids are canonical lowercase UUIDs only (anything else is 404 on a path and 422 in a body). Responses use the usual envelope and carry `Cache-Control: no-store`.

## Routes

### `POST /v1/conversations/{conversationId}/blobs`

Reserves one upload slot.

```json
{"role": "full", "sizeBytes": 412345, "ctSha256": "<standard padded base64 of the 32-byte SHA-256 of the whole ciphertext>"}
```

`201`:

```json
{"blobId": "5b6c…", "uploadUrl": "https://…r2.cloudflarestorage.com/hiyall-chat/chat/5b6c…?X-Amz-…", "method": "PUT",
 "headers": {"Content-Type": "application/octet-stream", "x-amz-checksum-sha256": "<the same ctSha256>"},
 "expiresAt": "2026-10-12T10:15:00Z"}
```

The URL is valid for 15 minutes and signs both headers. The object store refuses a body whose SHA-256 is not `ctSha256` (400 `BadDigest`), a request without the checksum header or with another content type (403 `SignatureDoesNotMatch`). The client must send the headers exactly as returned. The object key is `chat/<blobId>`: a random id, no user or conversation names.

Rules, in order:

| Check | Refusal |
|---|---|
| Caller belongs to the conversation, it is `active`, the pair is not barred (a block in either direction, or different age bands with `AGE_BAND_ISOLATION` on) and both accounts are active and onboarded | `404 NOT_FOUND` (existence is not leaked: non-member, barred and closed look the same) |
| `canMessage` passes (the peer's `messagesFrom`; a peer who has already written can always be answered) | `403 MESSAGES_NOT_ALLOWED` |
| **Images gate:** the peer has sent at least one message in this conversation, or the two are friends (an accepted friendship; a pending request does not count) | `403 ATTACHMENTS_NOT_ALLOWED` |
| `role` is `full` or `thumb`; `sizeBytes` is an integer of at least 32 and at most the role's cap; `ctSha256` is canonical padded base64 of 32 bytes; no other fields | `422 VALIDATION`; over the cap `413 TOO_LARGE` |
| At most 10 pending (not completed, unexpired) slots (`PendingBlobs` in the member's entitlements) | `429 RATE_LIMITED` with `Retry-After` until the oldest expires |
| Per member, rolling 24 hours, counted by `created_at` whatever became of the blob: at most 100 blobs and 300 MiB (`BlobsPerDay`, `BlobBytesPerDay`) | `429 QUOTA` with `Retry-After` until enough of the oldest blobs leave the window |
| Chat storage configured | `503 CHAT_MEDIA_UNAVAILABLE` |
| Per-account limiter (shared with complete and delete): burst 60, one every 500 ms | `429 RATE_LIMITED`, `Retry-After: 2` |

The "peer has replied or friends" gate uses `messages.sender_id` for the peer in this conversation (`EXISTS`, on the existing `messages_conversation` index) or an `accepted` row in `friendships`. It is checked again when the message is sent.

Limits: a `full` blob is at most 4 MiB (4194304 bytes) of ciphertext, a `thumb` at most 256 KiB (262144). Deleting a blob never refunds quota, so deleting and re-uploading cannot be used to exceed it. The per-member numbers (blobs and bytes a day, pending slots, and the 30 days a linked blob is kept) are `domain.Entitlements` values resolved per member, today the Free plan for everyone: see [plans and entitlements](../architecture/11-plans-and-entitlements.md). The caps on one blob (4 MiB, 256 KiB) and the four blobs per message are protocol limits, not entitlements.

**What only the apps can enforce.** The server sees ciphertext only: it enforces bytes, counts, quotas, rates, retention and who may send (and that the object is exactly the declared size and hash). It cannot check an image's pixel dimensions, a caption's length or the real image format inside the ciphertext. Only the sending and receiving apps can, and a modified client can ignore them: the receiving app must treat them as untrusted input (see [Limits and quotas](16-pulse-and-media.md#limits-and-quotas) for the table of who enforces what).

### `POST /v1/blobs/{blobId}/complete`

No body. Only the uploader. The API reads the stored size (`StatObject`) and compares it with the declared size:

- `200` `{"blobId": "…", "state": "uploaded"}`. Idempotent: completing again is `200`.
- `409 BLOB_NOT_READY`: nothing was PUT to the signed URL yet; try again after the upload.
- `409 BLOB_SIZE_MISMATCH`: the stored size is not the declared one. The object is deleted, the slot is dead and the client asks for a new one (it still counts towards quota).
- `410 BLOB_EXPIRED`: the slot expired or the blob was deleted.
- `404 NOT_FOUND`: not the caller's blob, unknown id, or the conversation is closed or barred.
- `503 CHAT_MEDIA_UNAVAILABLE`: storage not configured or failing (only the storage's error code is logged).

An uploaded blob that no message claims expires one hour after completion.

### `GET /v1/conversations/{conversationId}/blobs/{blobId}/url`

For either member of an active conversation who is not barred from the peer. Muting or restricting the sender does not matter.

`200` `{"url": "https://…", "expiresAt": "…", "sizeBytes": 412345}`: a signed GET valid for 5 minutes; `sizeBytes` is the ciphertext size. Ask again when needed; the app caches the decrypted image by blob id.

- `404 NOT_FOUND`: not a member, barred, closed, unknown, or somebody else's blob that is not sent yet.
- `409 BLOB_NOT_READY`: the caller's own blob is not sent yet (the uploader previewing before sending).
- `410 BLOB_EXPIRED`: past its 30 days, deleted by the uploader, or removed when the chat was blocked.
- `429 RATE_LIMITED`: a separate limiter, burst 60 then 10 per second.
- `503 CHAT_MEDIA_UNAVAILABLE`.

### `DELETE /v1/blobs/{blobId}`

Only the uploader; any state. `200` `{"deleted": true}`. The state becomes `deleted` and the object is removed at once (the hourly clean-up retries if storage failed). Idempotent. A blob held as report evidence is left alone and the answer is the same. Someone else's blob or an unknown id is `404`.

## Sending the message

`POST /v1/conversations/{id}/messages` gains an optional `blobIds` (at most 4, canonical UUIDs, no duplicates; otherwise `422 VALIDATION`). Inside the existing send transaction, after the message row is inserted (the foreign key needs it), one guarded statement claims them:

```sql
UPDATE chat_blobs SET message_id=…, expires_at=now()+interval '30 days'
WHERE blob_id=ANY(…) AND uploader_id=<sender> AND conversation_id=<this one>
  AND state='uploaded' AND message_id IS NULL AND expires_at>now()
```

If the row count differs from the number of ids, the whole send is rolled back with `409 BLOB_NOT_READY`; unknown, foreign, other-conversation, not completed, already claimed and expired blobs all look the same. The images gate is checked again (`403 ATTACHMENTS_NOT_ALLOWED`). A retry with a `messageId` that is already stored takes the existing idempotent early return before any of this: same answer, nothing relinked, whether or not the blobs are still around. Envelopes, the inbox and realtime signals are unchanged; the blob ids are not in them (the descriptor is inside the ciphertext).

## Retention and clean-up

| Blob | Expires |
|---|---|
| Slot never completed | 1 hour after creation |
| Uploaded, no message claimed it | 1 hour after completion |
| Claimed by a message | 30 days after the message |

The hourly `maintain()` job `chat blob cleanup` (`Store.PurgeChatBlobs`, batches of 5000) marks expired blobs `deleted`, deletes their objects from the chat bucket one by one and clears `object_key`. A failed removal leaves the key, so the next run retries. Blobs with `held_report_id` set are skipped. `chat blob tombstone purge` deletes rows whose object is gone two days after creation (after they stop counting towards any quota window). The bucket should also have a lifecycle rule deleting objects 45 days after upload as a safety net.

- **Blocking** (`SetBlock`) marks every unheld blob of the pair's conversation `deleted` in the same transaction; the job then removes the objects.
- **Uploader delete** marks and removes at once.
- **Account deletion** does not exist yet. The hook is `store.DeleteUserChatBlobs(ctx, tx, userID)`: it marks every unheld blob the user uploaded `deleted`. Account deletion must call it in its own transaction.

## Reporting evidence

`POST /v1/reports` evidence entries gain `attachments`:

```json
{"messageId": "…", "text": "Sent a photo. Update Hiyall to view it.", "sentAt": "…",
 "attachments": [{"blobIds": ["…", "…"], "descriptor": {"v": 1, "key": "…", "…": "…"}}]}
```

At most 4 attachments per message, each 1 to 4 distinct blob ids and a JSON object `descriptor` of at most 4 KiB (the decrypted descriptor, including the key, shared only under `disclosureConsent`). In the report transaction the blob rows are locked and every blob must belong to the evidence message it is listed under, in the reported conversation; otherwise `422 VALIDATION` and nothing is stored. The blobs get `held_report_id`, so retention, uploader delete, block and account deletion leave them alone. A repeat report while the first is open holds nothing new. Text-only reports are unchanged. The hold is not released automatically when a report is resolved: staff tooling for that does not exist yet. `moderate queue` lists the held blobs of each report with id, role, size and SHA-256 only; it never fetches or decrypts anything. Staff verify `ct_sha256` against the descriptor before decrypting, and never auto-decrypt.

## Configuration

| Variable | Meaning |
|---|---|
| `CHAT_MEDIA_ENDPOINT` | Storage endpoint; unset turns chat photos off (a startup warning; the routes answer `503 CHAT_MEDIA_UNAVAILABLE`) |
| `CHAT_MEDIA_BUCKET` | Default `hiyall-chat`; must not equal the social `MEDIA_BUCKET` on the same endpoint |
| `CHAT_MEDIA_ACCESS_KEY`, `CHAT_MEDIA_SECRET_KEY` | A token scoped to this one bucket; required with the endpoint |
| `CHAT_MEDIA_REGION` | Default `us-east-1`; R2 uses `auto` |
| `CHAT_MEDIA_SECURE` | `true` for https; required in production |

The API never creates or probes the chat bucket (the token cannot create buckets); create it first. See `config/chat-media.example.env`. Nothing logs signed URLs, keys, hashes or descriptors: a storage failure logs only the service's error code.

## Errors added

`ATTACHMENTS_NOT_ALLOWED` (403), `BLOB_NOT_READY` (409), `BLOB_SIZE_MISMATCH` (409), `BLOB_EXPIRED` (410), `TOO_LARGE` (413), `QUOTA` (429), `CHAT_MEDIA_UNAVAILABLE` (503). `RATE_LIMITED` (429) is used for the pending cap and the limiters.

## Device lifecycle and limits (13 October 2026)

Chat device routes (`POST /v1/devices`, `GET /v1/me/devices`, `DELETE /v1/devices/{id}`, keys, inbox and ack) have per-account limiters in addition to the per-address one (`chat_devices`, `chat_keys`, `chat_inbox`; see the implementation record). Migration `0035` links a device to the auth session that registered it: revoking the session revokes the device. A device unseen for 90 days is revoked by the hourly maintenance job. Photo descriptors are capped on receive and cached by conversation, blob id and hash: see [attachments](../security/14-encrypted-chat-attachments.md#receive-caps-and-cache-keys-13-october-2026-hardening). An unanswered sender gets `403 AWAITING_REPLY` after 3 messages, which also covers photo messages.
