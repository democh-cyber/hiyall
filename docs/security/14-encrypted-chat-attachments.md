# Encrypted chat attachments (phase 1: images)

Status: approved design, 12 October 2026. Step 3 (the Go server) is built, see [Implementation (server)](#implementation-server); the rest is tracked in the steps below. This extends [encrypted chat implementation](13-encrypted-chat-implementation.md) and follows the attachment rules in [encryption and interception](11-encryption-and-interception.md): the sender's device compresses and then encrypts; ciphertext goes straight to storage; the key, hash and descriptor travel inside the E2EE message; the server can authorize, size-check and expire blobs but cannot read, scan or transcode them.

## Decisions (owner-approved defaults)

| Topic | Decision |
|---|---|
| Retention | 30 days after the message is sent; unattached or abandoned uploads expire after 1 hour; R2 lifecycle rule at 45 days as a safety net |
| Size caps | full image blob at most 4 MiB, thumbnail blob at most 256 KiB; per member per rolling 24 hours at most 100 blobs and 300 MiB (counted by creation time regardless of later deletion); at most 10 pending blobs |
| Who can send | only after the peer has replied in that conversation, or when the two are friends (stops unsolicited images from strangers) |
| Web | no attachments (chat E2EE runs only in the Android and iOS apps) |
| Older apps | see the payload's `text`: "Sent a photo. Update Hiyall to view it." |
| Format | JPEG only in phase 1 |
| Storage | separate R2 bucket `hiyall-chat` with its own token, never shared with the social bucket `hiyall`; object key `chat/<blobId>` (random id, no user or conversation names) |

## Spike results (all verified 12 October 2026)

1. **STREAM encryption works with the locked versions.** In `aead 0.6.x` the STREAM module moved to the separate crate `aead-stream` (0.6.0, MIT or Apache-2.0), which is a new direct dependency. With `chacha20poly1305 =0.11.0` (XChaCha20-Poly1305), `hkdf =0.13.0` and `sha2 =0.11.0` (already in `Cargo.lock` through vodozemac) a chunked `EncryptorBE32` and `DecryptorBE32` round-trips 0, 1, 64 KiB minus 1, 64 KiB, 64 KiB plus 1 and multi-chunk inputs. Ciphertext length is `len + ceil(len / chunk) * 16` (an empty file is one 16-byte tag), so chunk `i` starts at `i * (chunk + 16)`, which allows byte-range reads for video later. A flipped bit, a flipped last tag, a truncated final chunk, appended bytes, reordered chunks, a wrong key, blob id or context all fail. `encrypt_last` and `decrypt_last` consume the stream object. `Key::from_slice` is deprecated in the generic-array migration; prefer the `Array` conversions.
2. **R2 enforces the signed upload checksum.** `minio-go` `PresignHeader` with headers `Content-Type: application/octet-stream` and `x-amz-checksum-sha256: <base64>` signs both (`SignedHeaders=content-type;host;x-amz-checksum-sha256`). A body that does not match the signed checksum returns 400 `BadDigest`; omitting the checksum header or changing the content type returns 403 `SignatureDoesNotMatch`. `StatObject` returns the stored size, so `complete` can verify it.
3. **Image preparation is done in the Rust core, not a Flutter plugin.** Decoding with limits, applying EXIF orientation, downscaling and re-encoding from pixels with the `image` crate (0.25, features `jpeg`, `png`, `webp`, no defaults) drops all EXIF and GPS, applies rotation (a 300x200 file tagged orientation 6 came out 200x300), refuses a declared oversized canvas and fails cleanly on junk. This is deterministic, unit-testable without a device and gives one decoder policy. iOS HEIC photos arrive as JPEG because `image_picker` re-encodes them.

## Crypto design (Rust, `apps/mobile/rust/src/api/blob.rs`)

- Each attachment has one random 256-bit master key `k` from the OS CSPRNG. Per blob, derive with `HKDF-SHA256(ikm = k, salt = blobId, info = "hiyall-chat-blob/v1" | role | mime | chunkSize | plainLen | conversationId)` into a 32-byte key and a 19-byte stream nonce prefix. `role` is `full`, `thumb`, later `video` or `poster`. One `k` covers every blob of a message; the descriptor carries no nonce.
- Chunk size 64 KiB by default; the descriptor carries `chunk`, so phase 2 can use 1 MiB without a format change. Each chunk has a 16-byte tag and the final chunk uses the last-block flag, so truncation and reordering fail. The AAD of every chunk is the HKDF info string.
- The plaintext is padded to a Padme length; the true length is `plainLen`, bound through the HKDF info. This reduces but does not remove size leakage; document the residual leak.
- `ctSha256` is SHA-256 over the whole ciphertext object, in the descriptor, checked by the receiver before decrypting and enforced by R2 at upload.
- The thumbnail (about 320 px JPEG, around 20 KB) is a separate blob derived with `role = thumb`. A tiny `preview` (a ThumbHash of about 25 bytes) is inlined for instant layout and a blurred placeholder; keep it tiny because history is stored as JSON in secure storage.
- Never return partial plaintext on failure; keys use `Zeroizing`.

Rust surface exposed through flutter_rust_bridge (names are the contract):

- `generate_blob_key() -> Vec<u8>` (sync, 32 bytes)
- `prepare_chat_image(input: Vec<u8>) -> Result<PreparedImage, String>` where `PreparedImage { full: Vec<u8>, full_w, full_h, thumb: Vec<u8>, thumb_w, thumb_h, preview: Vec<u8> }`: decode with limits, orient, full at most 2048 px on the long edge (JPEG quality about 82), thumbnail at most 320 px, preview from the thumbnail.
- `encrypt_blob(key, role, blob_id, conversation_id, mime, chunk_size, plaintext) -> Result<SealedBlob { ciphertext, ct_sha256, plain_len, chunks }, String>`
- `decrypt_blob(key, role, blob_id, conversation_id, mime, chunk_size, plain_len, ct_sha256, ciphertext) -> Result<Vec<u8>, String>`
- `preview_to_rgba(preview: Vec<u8>) -> Result<RgbaPreview { w, h, rgba }, String>`
- Phase 2 adds file-based and range variants with the same format.

## Message payload

Keep `v: 1`, keep a string `text`, set `kind: "image"` and add `att` (the receiver's existing check that binds `messageId`, `conversationId` and `senderId` already stops the server swapping an attachment into another conversation or sender). The receiver validates `att` strictly: sizes, dimensions, mime allow-list and blob ids.

```json
{"v":1,"kind":"image","text":"Sent a photo. Update Hiyall to view it.",
 "messageId":"…","conversationId":"…","senderId":"…","sentAt":"…",
 "att":{"v":1,"key":"<b64 32B>","mime":"image/jpeg","w":1536,"h":2048,
  "chunk":65536,"plainLen":412000,"ctSize":412345,"ctSha256":"<b64>",
  "blobs":{"full":"<uuid>"},
  "thumb":{"blob":"<uuid>","w":240,"h":320,"plainLen":18000,"ctSize":18300,"ctSha256":"<b64>"},
  "preview":{"t":"thumbhash","d":"<b64 ~25B>"},"caption":""}}
```

An image payload may also carry a quote, `re`, exactly as a text payload does (the snippet is the caption or empty and `k` is `image`); see [reactions and replies](13-encrypted-chat-implementation.md#reactions-and-replies). A reaction to a photo is a separate `reaction` message and touches no blob.

## Server contract (Go API)

Migration `0023_chat_blobs.sql`: table `chat_blobs(blob_id uuid pk, uploader_id, conversation_id, message_id null, role, size_bytes, ct_sha256 bytea(32), state pending|uploaded|deleted, object_key, held_report_id null, created_at, uploaded_at, expires_at, deleted_at)` with indexes on `(uploader_id, created_at)`, `(expires_at) WHERE state <> 'deleted'` and `(message_id)`.

| Route | Rules |
|---|---|
| `POST /v1/conversations/{id}/blobs` | caller is a member of an active conversation, not `interaction_barred`, `canMessage` passes, and the peer has replied or they are friends; validates `role`, `sizeBytes`, `ctSha256`; enforces quotas; returns a presigned PUT signing `Content-Type: application/octet-stream` and `x-amz-checksum-sha256` |
| `POST /v1/blobs/{id}/complete` | uploader only; `Stat` must equal the declared size, otherwise delete the object and return 409; state becomes `uploaded` |
| `GET /v1/conversations/{id}/blobs/{blobId}/url` | member of an active conversation, not barred; blob `uploaded`, linked to a message and unexpired; presigned GET, 5 minute TTL; a muted or restricted sender does not block download |
| `DELETE /v1/blobs/{id}` | uploader only; held blobs are exempt |

Send path: `POST /v1/conversations/{cid}/messages` gains `blobIds` (at most 4). Inside the existing transaction after `lockPair`, one `UPDATE chat_blobs SET message_id = … WHERE blob_id = ANY(…) AND uploader_id = … AND conversation_id = … AND state = 'uploaded' AND message_id IS NULL`; a row-count mismatch returns 409 `BLOB_NOT_READY`. Unknown or foreign blobs are rejected and the idempotent early return keeps retries safe.

Contract JSON:

```json
POST /v1/conversations/{cid}/blobs   {"role":"full","sizeBytes":412345,"ctSha256":"<b64>"}
201 {"blobId":"<uuid>","uploadUrl":"https://…","method":"PUT",
     "headers":{"Content-Type":"application/octet-stream","x-amz-checksum-sha256":"<b64>"},
     "expiresAt":"…"}
POST /v1/blobs/{id}/complete          -> {"blobId":"<uuid>","state":"uploaded"}
GET  /v1/conversations/{cid}/blobs/{blobId}/url -> {"url":"https://…","expiresAt":"…","sizeBytes":412345}
```

Errors: 404 (not a member, barred or closed), 409 `BLOB_NOT_READY`, 410 `BLOB_EXPIRED`, 413 `TOO_LARGE`, 429 `RATE_LIMITED` or `QUOTA`, 503 `CHAT_MEDIA_UNAVAILABLE`.

Storage wiring: add `Stat` and a `NoCreate` option to `media.Store` and `S3Config` (a token scoped to one bucket cannot create buckets); a second store `api.ChatMedia` configured by `CHAT_MEDIA_ENDPOINT`, `_BUCKET` (default `hiyall-chat`), `_ACCESS_KEY`, `_SECRET_KEY`, `_REGION`, `_SECURE`; when unset, log a warning and answer 503 `CHAT_MEDIA_UNAVAILABLE`; production requires `_SECURE=true`. Never log signed URLs, keys or descriptors; responses are `no-store`.

Retention and cleanup: `expires_at` is 30 days after the message is linked and 1 hour for unattached blobs; a cleanup job in `maintain()` mirrors `MediaGarbage` and skips held blobs; blocking marks the pair's unheld blobs deleted; account deletion marks the user's unheld blobs, and the other member's in their shared conversations, deleted (see [account deletion](../api/22-account-deletion-and-export.md)).

## Reporting evidence

Extend `domain.Evidence` with `attachments: [{blobIds, descriptor}]`, where the descriptor (including the key) is shared only by the reporter's explicit consent. In the report transaction check that the blobs belong to the evidence messages in the reported conversation and set `held_report_id` so cleanup, block and delete skip them. The moderation tool verifies `ct_sha256` against the descriptor before decrypting. Staff must never auto-decrypt anything. Before launch the owner needs a written process for handling suspected child sexual abuse material, including legal reporting duties.

## What cannot be done and what compensates

The server cannot scan, transcode or moderate encrypted images. Compensating controls: quotas, the reply-or-friend gate, reporting with consented evidence, blocking, size and hash checks, client-side decode checks and bounded retention. Still pending: moderation of non-E2EE media (posts, stories, avatars), a hash-matching and legal-reporting process, video, optional on-device nudity warnings and an independent review of this construction.

## Implementation: Rust core (step 2, done 12 October 2026)

Shipped in `apps/mobile/rust/src/api/blob.rs`, exposed through flutter_rust_bridge (generated Dart in `apps/mobile/lib/src/rust/api/blob.dart`). Server and app are not built against it yet.

Surface (Dart names as generated; integers are `u32` on the Rust side and `int` in Dart, hashes are raw 32-byte arrays, not base64):

```
Uint8List generateBlobKey()                                    // sync, 32 bytes
Future<PreparedImage> prepareChatImage({required List<int> input})
Future<SealedBlob> encryptBlob({key, role, blobId, conversationId, mime, chunkSize, plaintext})
Future<Uint8List> decryptBlob({key, role, blobId, conversationId, mime, chunkSize, plainLen, ctSha256, ciphertext})
Future<RgbaPreview> previewToRgba({required List<int> preview})
PreparedImage { full, fullW, fullH, thumb, thumbW, thumbH, preview }
SealedBlob    { ciphertext, ctSha256, plainLen, chunks }
RgbaPreview   { w, h, rgba }
```

Format, exactly as implemented:

- HKDF-SHA256, `ikm` = the 32-byte master key, `salt` = the blob id (UTF-8), `info` = `hiyall-chat-blob/v1|<role>|<mime>|<chunkSize>|<plainLen>|<conversationId>` (decimal numbers), 51 bytes of output: the first 32 are the XChaCha20-Poly1305 key, the last 19 the STREAM-BE32 nonce prefix. The info string is also the AAD of every chunk. The descriptor carries no nonce.
- Plaintext is padded with zeros to `padme(plainLen)` inside the encryption, then split into `chunkSize` pieces; the last piece (possibly short, or empty for an empty blob) uses the STREAM last-block flag. Ciphertext length is exactly `padme(plainLen) + max(1, ceil(padme(plainLen) / chunkSize)) * 16`; chunk `i` starts at `i * (chunkSize + 16)`. Padme leaves lengths 0 and 1 unchanged and adds at most about 12%. The descriptor's `ctSize` is `ciphertext.length`; the server size caps apply to that length, so the app should check it, since the padded length can exceed the plain JPEG size by that margin.
- `decryptBlob` checks, in this order: parameters, exact ciphertext length, SHA-256 of the whole ciphertext, then every chunk, then that the padding is all zeros. Any failure returns an error string without secrets and no plaintext.
- Ids (blob and conversation) must be 1 to 128 printable ASCII bytes (UUIDs fit).

Limits enforced:

| Item | Limit |
|---|---|
| Roles | `full`, `thumb` (anything else, including `video` and `poster`, is refused until phase 2) |
| Mime | `image/jpeg` only |
| Chunk size | power of two from 4 KiB to 1 MiB; 64 KiB is the default the app should send |
| Plaintext | at most 16 MiB (the server's 4 MiB and 256 KiB caps are stricter) |
| Key | exactly 32 bytes; hash exactly 32 bytes |
| Image input | at most 64 MiB, JPEG, PNG or WebP only (others, including GIF, BMP and HEIC, are refused); at most 12,000 px per side, 40 megapixels and 200 MiB of decoder allocation |
| Image output | full: long edge at most 2048 px, JPEG quality 82; thumbnail: at most 320 px, quality 80; never upscaled; preview: ThumbHash (about 21 to 25 bytes) of a 100 px version of the thumbnail; decoded to at most 32x32 RGBA, input 5 to 64 bytes |

Image behaviour: the decoder reads the EXIF orientation, the image is flattened onto white if it has alpha, shrunk, then rotated (so the big buffer is dropped early), and both JPEGs are re-encoded from pixels, so no EXIF, GPS, ICC or comment segment reaches the output. Colour is not managed: a Display P3 photo is treated as sRGB, which looks slightly less saturated. A 12 MP photo takes about 0.2 s in a release build on an Apple-silicon Mac (`cargo test --release -- --ignored twelve`). A JPEG from a 48 MP camera exceeds the 40 MP cap and is refused; the picker should request a downscaled image (for example `maxWidth` of 4096) instead of the original.

Residual leaks: Padme hides the exact size but not the size class; the server sees the ciphertext length, the number of blobs per message, upload times and the conversation. The same applies to the thumbnail blob.

Fixed test vectors (key bytes `00 01 ... 1f`, blob id `00000000-0000-4000-8000-000000000001`, conversation id `00000000-0000-4000-8000-0000000000c1`, mime `image/jpeg`, plaintext byte `i` = `(i * 7 + 3) mod 256`). These were also reproduced with an independent pure-Python implementation of HKDF, XChaCha20-Poly1305 and the STREAM-BE32 nonce layout, so they check the construction, not only the crates:

| Case | Expected |
|---|---|
| HKDF output, role `full`, chunk 4096, plainLen 0, key | `b199e0e38c75daba8c7a9bc2483fddba7e601090a7d0bc5521c52876a505f11c` |
| same, nonce prefix | `d1741428c27a82d06d17f228e87b4cf245356f` |
| ciphertext, empty plaintext, chunk 4096 | `2e2915987e1e2955aced165a79c95ab6` |
| ciphertext, single byte `42`, chunk 4096 | `99da1c20105adcb1d79ba9ce90805d7160` |
| SHA-256 of ciphertext, `full`, chunk 4096, 1000 bytes | `3652e70353c758290c13a8b3766619de4376b515a5829126e296aaf71cfb7934` |
| SHA-256 of ciphertext, `thumb`, chunk 4096, 10000 bytes | `571d9764b5a54a56912e8f582466250ae27cde3181157aea8bda3d5fb147415b` |
| SHA-256 of ciphertext, `full`, chunk 65536, 70000 bytes | `60e73830e91635f50815dda7e1f7760a8f06373567a8183dcbe52c895e992a5a` |

Tests (24 in `blob.rs`, run by `cargo test`): round trips for 0, 1, chunk minus 1, chunk, chunk plus 1, several chunks; the exact size formula and Padme values; the vectors; a flipped bit in every chunk and in the last tag; truncated, appended, duplicated, inserted, reordered and rotated chunks, including a truncation that also adjusts `plainLen` and the hash; wrong key, role, blob id, conversation id, mime, chunk size and `plainLen` (also one that pads to the same length); hash mismatch and wrong hash length; non-zero padding; key derivation independence per role and per field; parameter validation; random-garbage fuzz for decryption, previews and images; EXIF and GPS stripping with a real APP1 segment, orientations 1, 3, 6 and 8 applied by pixel colour, downscale and no upscale, PNG and WebP input with transparency flattened, junk, unsupported and oversized-canvas refusal, and the preview round trip to RGBA.

## Implementation: app (steps 4 to 6, done 12 October 2026, not run on a device)

Code: `apps/mobile/lib/core/chat/` (`chat_attachment.dart`, `chat_history.dart`, `chat_blob_codec.dart`, `chat_blob_transport.dart`, `chat_blob_cache.dart`, `chat_media.dart`, `chat_outbox.dart`, `chat_jpeg.dart`, plus the blob calls in `chat_api.dart` and the glue in `chat_engine.dart`) and `lib/features/{chat,chat_photo,safety}.dart`. Tests: `test/chat_{attachment,outbox,media,blob_transport,photo_widget}_test.dart` with fakes in `test/chat_photo_helpers.dart`. Nothing has been run against real storage, the Rust library or a phone.

**One deliberate change to the descriptor: `salt`.** The Rust core binds the blob id into the key derivation, but the server creates the blob id only in answer to a slot request that already carries the ciphertext's size and SHA-256, so the id cannot be an input to that ciphertext. The app therefore passes the core a random per-attachment UUID, the `salt` in `att`, where the core takes `blobId`; the server's blob ids are only locators. The security property is unchanged (the master key is random per message, and the role, mime, chunk size, length and conversation id are still bound), and the descriptor stays far below the 4 KiB evidence limit. The moderation tool must use `att.salt`, not a blob id, as the salt when it decrypts evidence. Alternative if this is not wanted: let the slot request carry a client-chosen blob id (a server change).

**Sending** (`PhotoOutbox`, started by `ChatEngine.sendPhoto`):

1. The picker returns a JPEG, PNG or WebP of at most 4096 px (`maxWidth` and `maxHeight`), at most 64 MiB. `prepareChatImage` makes the full image and the thumbnail.
2. A random master key and salt are generated; the thumbnail and the full image are encrypted with the conversation id. The ciphertext lengths are checked against 4 MiB and 256 KiB before any slot is requested; over the cap gives a "too large" message and nothing is stored.
3. The ciphertext goes to `chat_outbox/<messageId>/{thumb,full}.bin` in the app-support folder, an outbox entry (key, salt, ids, each blob's stage, file names relative to the outbox folder, caption, time) is saved in the sealed chat snapshot ([atomic storage](13-encrypted-chat-implementation.md#atomic-encrypted-storage-and-the-receive-path-c8)), and the message appears at once in the history as `sending` with a progress ring.
4. For each blob (thumbnail first): `POST …/blobs`, `PUT` of the ciphertext straight to the returned URL with exactly the returned headers (Dio, progress callback, `CancelToken`, up to four attempts with 1, 2, 4 and 8 second pauses on network errors and 5xx; a refusal such as 403 is not retried; URLs are never logged, stored or put in an error), then `POST /v1/blobs/{id}/complete`. A failed upload deletes its slot at once so it does not count against the 10 pending slots.
5. The message goes through the normal Olm envelope path (`kind: "image"`, `text` is the caption or "Sent a photo. Update Hiyall to view it.", `att` as above) with `blobIds` of full then thumb. The uploads run outside the engine's Olm lock; only this last step takes it.
6. On success the message is replaced by the sent one, the verified ciphertext files are moved into the cache under their blob ids (so the sender's own photo needs no download), and the outbox entry and folder are deleted.

Retrying is idempotent: each stage is saved before the next, so Retry resumes at the first unfinished blob with the same message id, key and ciphertext. A retry never creates a second message because the relay answers a repeated `messageId` with the first result. If the relay no longer has the blobs (an unclaimed upload expires one hour after completion, or complete answers `BLOB_SIZE_MISMATCH`, or the send answers `BLOB_NOT_READY`), the blobs are uploaded once more from the saved ciphertext with new slots. After a restart a photo that was mid-upload shows as failed ("Sending was interrupted") until the person taps Retry; nothing uploads in the background without the app. A failed photo keeps its bubble with the reason, Retry and Delete; Delete removes the message, the files and any uploaded blob. Sign-out (or another account signing in) deletes the outbox, its files, the whole photo cache and the stored outbox entry.

**Receiving:** `messageFromBody` keeps the existing `v`, conversation, sender, message id and string `text` checks and parses `att` strictly (`ChatAttachment.parse`): mime allow-list (`image/jpeg`), sizes and dimensions (each side at most 12,000 px, at most 40 MP), full ciphertext at most 4 MiB and thumbnail at most 256 KiB, canonical lowercase UUIDs for blob ids and salt, a 32-byte key, chunk sizes that are powers of two from 4 KiB to 1 MiB, an exact match between `plainLen` and `ctSize` (the Padme formula), canonical standard base64, and a descriptor of at most 4 KiB. A bad descriptor is not an error: the message shows as "Unsupported photo". A bubble shows the ThumbHash preview (`previewToRgba`, upscaled and blurred) at the right aspect ratio, then the thumbnail. The thumbnail is fetched when its bubble is built; the full image only when the viewer opens (it can be 4 MiB). `ChatMedia` asks for a short-lived download URL, downloads (at most three at once, one transfer per blob however many widgets ask), checks the length and SHA-256 against the descriptor before anything else, decrypts in memory, and only then writes the verified ciphertext to the cache. Before a JPEG is decoded, its magic bytes and the frame size in its header must equal the descriptor's size; decoding uses a target width. Decoded images live in a small in-memory LRU (48 MB) that hands out clones; Flutter's image cache, `cached_network_image` and the OS cache are not used for chat photos. 404, 410 and `BLOB_EXPIRED` show "Photo unavailable" (no retry); network errors show Retry; a failed hash or decryption shows "Can't open this photo".

**Cache:** `<application support>/chat_blobs/<blobId>`, ciphertext only (a file is useless without the key that only the message holds), least recently used files evicted past 200 MB, files deleted when their message falls out of the 500-message history, whole folder deleted on sign-out. A damaged cache file is dropped and fetched again. `android:allowBackup` is already false. **Gap:** on iOS the folder is not yet excluded from iCloud and device backups (that needs `NSURLIsExcludedFromBackupKey` and a stronger file protection class, which no plugin in the app sets; a small `AppDelegate.swift` method channel would do it). The cache holds only ciphertext and the keys are in the Keychain, so a backup of the cache alone reveals nothing, but a restore onto another device would carry ciphertext without keys.

**UI:** a photo button in the composer (hidden on web, where `chatSupported` is false) opens "Choose photo" and, on phones, "Take photo"; a preview sheet with an optional caption (500 characters) comes before anything is sent; the bubble has a progress ring with a cancel button while uploading, a failed state with the reason, Retry and Delete, and a download-failed state with Retry; tapping opens a full-screen viewer (pinch to zoom, dark background, caption, progress while the full image loads). There is no save or share. The conversation list shows "Photo" or the caption. Semantics labels describe each state. The calm explanation for the images gate (403 `ATTACHMENTS_NOT_ALLOWED`) is "You can send photos once they reply."

**Reporting:** photo messages can be picked as evidence. The text consent is unchanged; a second, separate checkbox ("Also share the photo itself … gives Hiyall's safety team the key to open the photo") controls whether `attachments: [{blobIds: [full, thumb], descriptor}]` (the descriptor includes the key) is sent. Without it only the text goes. Photos that never went out and photos with an invalid descriptor can only be reported as text. Text-only reports are byte for byte unchanged.

**Not covered:** no device testing of any of this (picker, camera, permissions, the native library, real storage, backgrounding mid-upload); no web (no attachments); no video or other formats; no save or share; no automatic retry of a failed photo; the iOS backup exclusion above; no push notification text for photos; a very large history of photos stores about 0.8 KB of descriptor per message in the secure store.

## Steps

1. Spike (done, above).
2. Rust `blob.rs` with tests (done, see Implementation above).
3. Go: migration, store, endpoints, send linking, quotas, cleanup, evidence hold, tests, end-to-end script (done, 12 October 2026; see below).
4. Flutter engine: payload, `ChatMessage.attachment` and status, outbox, transport and cache (done, see Implementation: app).
5. Flutter UI: picker, bubble, full-screen viewer, states (done).
6. Reporting evidence in the app (done).
7. Integration and a two-device manual pass.

Phase 2 (video): resumable multipart upload through R2's S3 multipart API, 1 MiB chunks through file-based encrypt and decrypt, range GET, a `poster` blob, client-side transcode and larger quotas; the descriptor needs no format break.

## Implementation (server)

Written up for clients in [API: encrypted chat attachments](../api/21-chat-attachments.md); this section records what was decided while building it and where it differs from the contract above.

- **Where.** Migration `0023_chat_blobs.sql`; `internal/store/chatmedia.go`, `internal/httpapi/chatmedia.go`, `internal/domain/chatmedia.go`; `media.Store` gained `PresignPutChecksum` (signs `Content-Type` and `x-amz-checksum-sha256`, the existing `PresignPut` is unchanged for the social store), `Stat` and `media.ErrNotFound`; `S3Config.NoCreate` skips every bucket call at startup. Wiring is `api.ChatMedia`, configured by `CHAT_MEDIA_*` (production needs `CHAT_MEDIA_SECURE=true`; the chat bucket must differ from the social one). Without it the four routes answer `503 CHAT_MEDIA_UNAVAILABLE`.
- **Gate.** "The peer has replied" is `EXISTS` a message whose `sender_id` is the peer in this conversation; "friends" is an accepted `friendships` row. Checked at slot creation and again when the message is sent. Failing it is `403 ATTACHMENTS_NOT_ALLOWED` (a code the contract did not list). `canMessage` still applies (`403 MESSAGES_NOT_ALLOWED`). Membership, active conversation and `interaction_barred` (blocks and age bands) are `404` for every route.
- **Quotas.** Slot creation locks both accounts in id order (`lockPair`, as the send path does), so one member's slots are serialized and the counts cannot be raced past: 100 blobs and 300 MiB per rolling 24 hours counted by `created_at` regardless of state (deleting never refunds), 10 pending. Size caps: `full` 4 MiB, `thumb` 256 KiB, minimum 32 bytes. Limiters: slots, completes and deletes share a burst of 60 refilling one per 500 ms; download URLs burst 60 at 10 per second.
- **Lifecycle.** Slots live an hour; `complete` (stat equals the declared size, else the object is deleted and the slot dead) restarts that hour; linking sets `expires_at = now() + 30 days`. Download is `404` for the peer until the message is sent, `410 BLOB_EXPIRED` once expired or deleted.
- **Send path.** `blobIds` is linked with one guarded `UPDATE` after the message row is inserted, still inside the transaction after `lockPair` (the foreign key needs the row; a mismatch rolls the message back with `409 BLOB_NOT_READY`). The idempotent early return for a known `messageId` comes first, so retries neither fail nor relink.
- **Clean-up.** `maintain()` runs `PurgeChatBlobs` (expired and deleted blobs; removes objects one by one, then clears `object_key`; skips held blobs; a failed removal is retried next hour) and `PurgeChatBlobTombstones`. Blocking marks the pair's unheld blobs `deleted` in the block transaction. The account purge calls `store.DeleteUserChatBlobs` in its content transaction, keeps blobs held as report evidence (with their message and conversation rows) and deletes the other rows once their objects are gone.
- **Evidence.** `domain.Evidence.attachments`; the report transaction locks the blobs, checks they belong to the evidence message in the reported chat and sets `held_report_id`. `moderate queue` prints held blob ids, sizes and SHA-256 only. Releasing a hold when a report is resolved is not built.
- **Logging.** A storage failure answers 503 and logs only the service's error code; URLs, keys, hashes and descriptors are never logged (covered by a test with leaky error text).
- **Verified against the real bucket (12 October 2026).** Besides the `media.Memory` tests, `scripts/chat-blob-e2e.py` ran 41 of 41 checks against the real Cloudflare R2 bucket `hiyall-chat` through a token scoped to that bucket only: the signed upload is refused when the body does not match the signed SHA-256 (400) or when the checksum header or content type is missing or changed (403); `StatObject` returns the stored size on a bucket-scoped token; the peer downloads, hash-checks and decrypts; an outsider gets 404; the pending cap and delete behave; and no key or plaintext appears in any response. The same token is refused (403) on the social bucket `hiyall`. The bucket has a 45-day lifecycle rule as a backstop. Still untested: real devices, the camera and picker, and the native Rust library inside the app.

## Receive caps and cache keys (13 October 2026 hardening)

- **Descriptor caps on receive.** The full image is at most 2048 px on either side and 4 Mi pixels (`maxFullSide`, `maxPixels`; the sender produces at most 2048 px on the long edge, so a 2048 x 2048 square is the largest), the thumbnail at most 320 px (`maxThumbSide`), the caption at most 500 code points (`maxCaption`; the caption is cleaned with the chat text rules, see [text rules](13-encrypted-chat-implementation.md#text-rules-in-the-app-s9), on the way out and on receipt). Anything over is an unsupported photo ("Can't open this photo"), never a decode. The previous limits (12,000 px, 40 MP, caption 1000) are gone; the Rust core's own input limits for the sender are unchanged.
- **Cache keys.** The ciphertext cache file name is `sha256("hiyall-blob-cache-v1\n" + conversationId + "\n" + blobId + "\n" + base64(ctSha256))` (`blobCacheKey`), not the blob id. A descriptor in another conversation, or with another hash, can neither read nor evict another photo's entry.
- **Never delete what verifies.** A cached file whose hash and size match its own descriptor is kept even if the descriptor's key will not decrypt it (that is reported as a damaged photo). A file that does not match is deleted and fetched again. When a message leaves the 500-message history, its cache entries are deleted only if no remaining message names the same entry. History eviction is by the relay's time (see [chat implementation](13-encrypted-chat-implementation.md#hardening-after-the-13-october-audit)).
- Sign-out and account deletion remove `chat_blobs`, `chat_outbox` and `chat_state` (the sealed snapshot that holds the outbox index) with the rest of the chat data.

Not done: excluding these folders from iOS backups (the keys are this-device-only, so a restored copy is unreadable but present). Photo payloads are not padded to size buckets (their blob ids and sizes are visible to the relay anyway); only text payloads are.
