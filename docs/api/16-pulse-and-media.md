# Pulse, stories and photos

Implemented in migrations `0010_pulse.sql`, `0011_report_content.sql` and `0024_pulse_quota_indexes.sql` (the quota indexes), plus:

- server: `services/api/internal/media`, `store/pulse.go`, `store/pulsequota.go`, `httpapi/pulse.go`, `domain/entitlements.go`
- app: `lib/core/pulse.dart`, `lib/core/feed_state.dart`, `lib/features/pulse.dart`

## Photos

Bytes never pass through the API or live in Postgres.

1. `POST /v1/media/uploads` `{purpose: post|story|avatar, contentType: image/jpeg|png|webp, sizeBytes ≤ 15 MB}` returns `{mediaId, uploadUrl, headers, expiresAt}`. The upload URL is a signed S3 PUT. It is valid for 15 minutes, and the signature pins the content type and the exact body size (`sizeBytes`): storage refuses a body larger or smaller than declared with 403, so the quotas below, which count the declared size, cannot be undercut by a modified client. The size is signed as `Content-Length` but is not in the returned `headers` (only `Content-Type` is): send the bytes as the raw body and let the HTTP client set the length, as browsers do not allow setting it. Uploads are limited per account: see [Limits and quotas](#limits-and-quotas).
2. The app PUTs the bytes straight to storage.
3. `POST /v1/media/{id}/complete` processes the photo:
   - The API reads at most the declared size.
   - It rejects anything that isn't a JPEG, PNG or WebP image (415), and any image over 40 megapixels, so a small file can't declare a huge canvas.
   - It applies EXIF orientation and re-encodes a 2048 px "full" and a 640 px "thumb" JPEG.
   - Re-encoding from pixels drops all metadata, including GPS. The original upload is deleted.
   - **Scanning.** Before the variants are stored, the upload scanner (`SCAN_HASHLIST_FILE` and/or `SCAN_PROVIDER_URL`) inspects the exact upload and the re-encoded copy. `clean` continues. A flag or a match quarantines the photo (kept under `hold/`, never served, never attachable), opens a case in the admin console, and a match suspends the uploader; the member gets `422 UPLOAD_REJECTED` and nothing about why. A scanner that cannot answer gives `503 SCAN_UNAVAILABLE` and the upload stays pending (retry). See [illegal content runbook](../security/16-csam-and-illegal-content.md). Chat photos are end-to-end encrypted and cannot be scanned.
   - Processing is CPU-bound, so each node runs at most 4 at once. At scale this moves to a media worker behind a queue.

Reads use signed GET URLs that last one hour. They are minted only after the viewer has been authorized for the post or story that uses the photo (profile photos follow the profile: see [Profile photos](20-profile-photos.md)). Unsigned reads are refused by storage. The app caches images by media id, so a refreshed URL doesn't refetch the bytes.

Clean-up runs hourly in the API's maintenance loop:
- abandoned uploads after 1 hour
- photos that were never attached after 1 day
- photos of deleted posts and stories
- profile photos that were replaced or cleared
- stories a day after they expire, along with their views (in batches of 5000; the loop repeats while a batch deletes 5000 stories, counted as stories, not photos)

**Objects first, then rows.** The "media cleanup" job (`store.PurgeMedia`) claims photo rows 50 at a time with `FOR UPDATE SKIP LOCKED` (two nodes never take the same ones), deletes each row's objects from storage, and only then marks the rows whose objects are all gone as finished (status `deleted`, keys cleared). A failed delete leaves its row untouched for the next run and does not hold back the others; the job reports an error so `hiyall_maintenance_job_runs_total{job="media cleanup",result="error"}` shows it. A row is therefore never finished while an object remains, which is what lets the account purge treat "no `media_assets` rows left" as "no photo objects left". Every job has its own timeout (10 minutes; 20 for the cleanups and the account purge) and runs on a separate small database pool with longer statement limits than a request. `outbox_events` older than 7 days are deleted by the "outbox purge" job (nothing writes the table any more).

**Finishing an upload** (`POST /v1/media/{id}/complete`) downloads, decodes and re-encodes the photo, so it has its own 30 second deadline (every other request: 10) and its own per-account limiter (burst 30, then one every 2 seconds, 429 `RATE_LIMITED`). At most 4 photos are processed at once per node, and a photo may be at most 20 megapixels (15 MB, checked before decoding). Set `GOMEMLIMIT` on the machine (deploy guide, section 7).

Encrypted chat photos do not use this pipeline or this bucket: see [encrypted chat attachments](21-chat-attachments.md). Development uses SeaweedFS (`scripts/dev-storage.sh`, S3 on `127.0.0.1:8333`, credentials generated into `.runtime/storage/`). Production sets `MEDIA_ENDPOINT`, `MEDIA_ACCESS_KEY`, `MEDIA_SECRET_KEY`, `MEDIA_BUCKET` and `MEDIA_SECURE=true` for S3, R2 or similar, behind a CDN. Video is not accepted yet: it needs a transcoding worker that also strips metadata.

## Limits and quotas

Every number below is enforced by the server. The per-member limits are `domain.Entitlements` values resolved per member (today everyone is on the Free plan, the same for adults and minors): see [plans and entitlements](../architecture/11-plans-and-entitlements.md). The rolling limits count by creation time over the last 24 hours, whatever became of the item afterwards: deleting a post, a story or a photo never refunds the day's count.

| Limit | Value | When it is hit |
|---|---|---|
| Upload slots, all purposes (post, story, avatar) | 50 per rolling 24 hours | `429 QUOTA`, `Retry-After` |
| Declared upload bytes, all purposes | 300 MiB per rolling 24 hours | `429 QUOTA`, `Retry-After` |
| Posts | 20 per rolling 24 hours, text-only ones too | `429 QUOTA`, `Retry-After` |
| Stories | 30 per rolling 24 hours, text-only ones too | `429 QUOTA`, `Retry-After` |
| Live photo storage | 2 GiB per member | `429 QUOTA`, no `Retry-After` |
| Pending (not completed, unexpired) uploads | 50 per member | `429 RATE_LIMITED`, `Retry-After` until the oldest expires |
| Size of one photo upload | 15 MB (15 MiB) | `413 TOO_LARGE` |
| Decoded image size | 40 megapixels | `415 UNSUPPORTED_MEDIA` at complete |
| Photo types | JPEG, PNG, WebP | `415 UNSUPPORTED_MEDIA` |
| Photos per post | 10 | `422 VALIDATION` |
| Post text | 2200 characters | `422 VALIDATION` |
| Comment text | 1000 characters | `422 VALIDATION` |
| Story text | 280 characters | `422 VALIDATION` |
| Story lifetime | 6, 12 or 24 hours as the member chooses (24 when not sent; the choices are `Entitlements.StoryLifetimes`); purged a day after it expires | `422 VALIDATION` for any other number |
| Upload URL lifetime / pending upload expiry / unattached photo expiry | 15 minutes / 1 hour / 1 day | |
| Per-account upload limiter | burst 30, then one every 2 seconds | `429 RATE_LIMITED`, `Retry-After: 5` |
| Per-account content limiter (posts, stories, comments, reactions) | burst 30, then one a second | `429 RATE_LIMITED`, `Retry-After: 5` |
| Photo processing | 4 at once per node | the request waits |

**What counts as "stored".** The storage cap is checked when an upload slot is created: the sum of `size_bytes` of the member's `media_assets` with status `ready` (attached to a post, story or profile, or not yet attached, never deleted ones), plus the declared size of the new upload, must be at most 2 GiB. A ready photo's `size_bytes` is the stored size of both re-encoded variants (full and thumb), not the size that was uploaded: the upload's declared size is kept separately (`declared_bytes`, migration 0024) for the daily bytes limit. Pending uploads are not stored yet, so they do not count: they are bounded by the pending cap instead (at most 50 uploads of up to 15 MiB can be in flight on top of a full storage). Deleting a post or a story marks its photos deleted, which frees their storage at once; replacing or clearing the profile photo does the same for the old one; story photos stay counted until the story is purged a day after it expires.

**The daily upload limits** count `media_assets` by `created_at` at slot creation, deleted and never-completed uploads included. The post and story limits count `posts.created_at` and `stories.created_at`, deleted rows included. The three counts are separate: hitting the story limit does not stop posts.

**The refusal** is the standard error envelope, the same as for the [chat attachment quotas](21-chat-attachments.md): `429`, code `QUOTA`, a message written to be shown as is, and nothing else about the account.

```
HTTP/1.1 429 Too Many Requests
Retry-After: 18342
Content-Type: application/json; charset=utf-8

{"success":false,"error":{"code":"QUOTA","message":"You’ve reached today’s limit of 20 posts. Try again later."},"meta":{"requestId":"...","serverTime":"..."}}
```

| Limit | Message |
|---|---|
| Posts | You’ve reached today’s limit of 20 posts. Try again later. |
| Stories | You’ve reached today’s limit of 30 stories. Try again later. |
| Upload slots or bytes | You’ve reached today’s photo upload limit. Try again later. |
| Storage | Your photo storage is full. Delete some posts or stories to free space. |

The daily limits send `Retry-After`: whole seconds until enough of the oldest counted items leave the 24 hour window for the request to fit (for bytes, until enough bytes have left). The storage cap has no automatic recovery, so it sends none; it lifts when the member deletes posts, stories or a profile photo. A client may show "try again in about N hours" from the header, and must not retry the storage refusal on its own.

**Checked in the inserting transaction.** `CreateUpload`, `CreatePost` and `CreateStory` take a transaction-scoped advisory lock per member and kind (`pg_advisory_xact_lock(hashtextextended('pulse-<kind>' || user))`), count the window, and insert in the same transaction, so two concurrent requests from one member cannot both pass at N-1. Members do not wait on each other. The counts are a range probe on `media_owner (owner_id, created_at DESC)` and the plain indexes `posts_author_created (author_id, created_at)` and `stories_author_created (author_id, created_at)` from migration 0024. A post or story that carries photos is validated as before (409 `MEDIA_NOT_READY`); a refused one leaves its photos unattached.

**Who enforces what.**

| Limit | Server-enforced? |
|---|---|
| Upload slots, declared bytes, storage, posts, stories, pending uploads, rates | Yes, per member, in the database transaction |
| Size of a photo | Yes: declared size checked at the slot (15 MB), stored size pinned by the signed URL (403 otherwise) |
| Content type and real image format | Yes: signed content type, then decoding and re-encoding at complete (415) |
| Decoded pixels | Yes: 20 MP checked before decoding (a decoded 20 MP image is about 80 MB; four are processed at a time per node) |
| Text lengths, photos per post | Yes |
| Retention, expiry, who may see what | Yes |
| Chat photos: byte sizes, counts, quotas, rates, retention, who may send | Yes, see [chat attachments](21-chat-attachments.md) |
| Chat photos: pixel dimensions, caption length, real image format | No. They are inside end-to-end encrypted ciphertext the server cannot read; only the sender's and the receiver's apps can check them |

## Posts

| Endpoint | Notes |
|---|---|
| `POST /v1/posts` `{body ≤ 2200, audience: public\|followers\|friends, mediaIds ≤ 10}` | Needs text or a photo. Photos must be the author's own, ready, unattached and uploaded for posts (409 `MEDIA_NOT_READY` otherwise). At most 20 a day (429 `QUOTA`). |
| `GET /v1/posts/{id}` / `DELETE` | 404 for missing, deleted and hidden posts alike. Deleting queues the post's photos for removal. |
| `GET /v1/feed?mode=following\|everyone` | 20 per page, at most 50, signed cursor. |
| `GET /v1/users/{id}/posts`, `GET /v1/me/saved` | Access is rechecked on every read; a saved post you lose access to drops out. |
| `PUT\|DELETE /v1/posts/{id}/reaction` `{reaction: heart\|fire\|laugh\|wow\|sad}` | One per person; changing it doesn't change the count. |
| `PUT\|DELETE /v1/posts/{id}/save` | |
| `GET\|POST /v1/posts/{id}/comments`, `DELETE /v1/comments/{id}` | Comments are oldest first, with one level of replies. The writer or the post's author can delete a comment. |

**Who sees a post:**
- `followers` includes friends.
- Blocked pairs, inactive authors and muted authors never appear.
- Each card carries counts, the viewer's reaction and saved state.

**Comments:**
- The post author's `commentsFrom` setting applies, with 403 `COMMENTS_NOT_ALLOWED`.
- A comment from someone the author restricted is stored hidden. Only its writer sees it, and it isn't counted. The writer is never told.

**Feed at scale:**
- "Following" reads the viewer's circle (self, follows and friends, minus muted and blocked accounts).
- It does one bounded index probe per author. Each author's audience is applied inside that probe, so posts hidden from the viewer can't crowd visible ones out of a page.
- "Everyone" walks a partial index of public posts.
- A page costs five batched queries, whatever its size.
- Counts live in 8 slots per post, so a viral post's reactions don't queue on one row. Reads sum the slots for the whole page.

**Next step for 100M users:** a materialized `feed_items` table with fan-out on write for most authors and merge on read for very large accounts, behind the same endpoint.

Reactions and comments notify the author as "X reacted to your post" or "X commented on your post". Repeats by the same person refresh one row, muted people's activity arrives already read, and nothing is pushed for them.

## Stories

| Endpoint | Notes |
|---|---|
| `POST /v1/stories` `{body ≤ 280, background?, textStyle?, lifetimeHours?, mediaId?, audience}` | A photo or words on a colour or gradient, drawn in a text style. Lives `lifetimeHours` (see below; 24 when left out). The app defaults the audience from `storyAudience`. At most 30 a day (429 `QUOTA`). |
| `GET /v1/stories/tray` | Active stories from the viewer's circle, grouped by author: own first, then unseen, newest first. Authors see `viewCount`. Bounded to each author's newest 100 stories and 1500 in all, the viewer's own first and then the newest, so when the bound bites the oldest are left out (stories within a group stay oldest first). |
| `GET /v1/me/stories` | The caller's own active stories (not deleted, not expired), newest first, paged with the signed cursor; each has `viewCount`, `expiresAt` (`lifetimeHours` after creation), `audience`, `body`, `background`, `textStyle` and `media`. Only ever the caller's own. Rate limit: a burst of 30 reads, then two a second (429). |
| `GET /v1/users/{id}/stories` | Another member's active stories the caller may watch (audience, blocks, age band, inactive accounts; the same rule as the Stories count on their profile), newest first, each with the caller's own `seen`. Empty when the caller cannot see the member. Same read rate limit. The app opens it in the story viewer from the Stories stat. |
| `POST /v1/stories/{id}/view` | Idempotent. Your own views aren't counted. |
| `GET /v1/stories/{id}/viewers` | Author only (anyone else, and a deleted story, gets 404). Most recent first as `{user, since}`. Inactive accounts and anyone blocked with the author or in the other age band are left out; `viewCount` (tray and `GET /v1/me/stories`) is counted the same way, so the number always equals the list. Same read rate limit. |
| `DELETE /v1/stories/{id}` | Author only; removes the story and queues its photo. Someone else's, unknown or already deleted is 404. Shares the content write limit. |

**Look and lifetime.** Every story JSON (tray, `GET /v1/me/stories`, `GET /v1/users/{id}/stories`) carries `background` and `textStyle`. Both are optional on create: an app from before text styles sends neither and gets `lime` and `clean`; stories stored before migration 0027 read as `clean`. Unknown values are `422 VALIDATION` naming the field, and nothing is stored or counted. The lists are enforced by the server (`domain.StoryBackgroundNames`, `domain.StoryTextStyleNames`); the database only checks the shape of a style name, so a new one never needs a migration. A client that meets a name it does not know (a newer server) draws `lime` or `clean`.

| `background` | |
|---|---|
| solid | `lime`, `lilac`, `pink`, `mint`, `peach`, `ink` |
| gradient | `sunset`, `bubblegum`, `aurora`, `ocean`, `grape`, `mango`, `midnight`, `freshmint` |

| `textStyle` | Look (all from the bundled Space Grotesk and Manrope) |
|---|---|
| `clean` | Space Grotesk bold: the default, and what every story from before text styles shows |
| `loud` | Manrope extra bold in capitals |
| `soft` | Manrope medium, airy |
| `glow` | Space Grotesk bold with a halo (lime on dark backgrounds, white on light ones) |
| `stamp` | capitals, wide spacing, on a solid label in the ink colour |
| `type` | Manrope semibold with tabular, letter-spaced characters |

Clients draw the words in the ink colour that contrasts best with the background (ink or cream, judged on the worst stop of a gradient), fit the size to the length, and white on a soft scrim over a photo. The app keeps text alignment (left, centre, right) to itself: it is not stored.

`lifetimeHours` is a whole number of hours, or null or absent for 24. Which numbers a member may use is `Entitlements.StoryLifetimes` (6, 12 and 24 on the Free plan, so 48 is `422 VALIDATION` with the message "choose 6, 12 or 24 hours"). The check comes before the daily limit and before any photo is claimed. The server sets `expires_at = now() + lifetimeHours`; clients show the time left from `expiresAt`. A story still counts towards the daily limit for 24 hours after it is created, however short it lives.

```json
POST /v1/stories
{"body":"gm","background":"sunset","textStyle":"glow","lifetimeHours":12,"audience":"friends"}
```

## Reports

`POST /v1/reports` also accepts `targetType` `post`, `comment` and `story`. The reporter must be able to see the content, the subject is its author, and you can't report your own.
