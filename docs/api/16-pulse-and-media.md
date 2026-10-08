# Pulse, stories and photos

Implemented in migrations `0010_pulse.sql` and `0011_report_content.sql`, plus:

- server: `services/api/internal/media`, `store/pulse.go`, `httpapi/pulse.go`
- app: `lib/core/pulse.dart`, `lib/core/feed_state.dart`, `lib/features/pulse.dart`

## Photos

Bytes never pass through the API or live in Postgres.

1. `POST /v1/media/uploads` `{purpose: post|story, contentType: image/jpeg|png|webp, sizeBytes ≤ 15 MB}` returns `{mediaId, uploadUrl, headers, expiresAt}`. The upload URL is a signed S3 PUT. It is valid for 15 minutes, and its content type is fixed by the signature. Each account can have at most 50 pending uploads, and uploads are rate-limited.
2. The app PUTs the bytes straight to storage.
3. `POST /v1/media/{id}/complete` processes the photo:
   - The API reads at most the declared size.
   - It rejects anything that isn't a JPEG, PNG or WebP image (415), and any image over 40 megapixels, so a small file can't declare a huge canvas.
   - It applies EXIF orientation and re-encodes a 2048 px "full" and a 640 px "thumb" JPEG.
   - Re-encoding from pixels drops all metadata, including GPS. The original upload is deleted.
   - Processing is CPU-bound, so each node runs at most 4 at once. At scale this moves to a media worker behind a queue.

Reads use signed GET URLs that last one hour. They are minted only after the viewer has been authorized for the post or story that uses the photo. Unsigned reads are refused by storage. The app caches images by media id, so a refreshed URL doesn't refetch the bytes.

Clean-up runs hourly in the API's maintenance loop:
- abandoned uploads after 1 hour
- photos that were never attached after 1 day
- photos of deleted posts and stories
- stories a day after they expire, along with their views

Development uses SeaweedFS (`scripts/dev-storage.sh`, S3 on `127.0.0.1:8333`, credentials generated into `.runtime/storage/`). Production sets `MEDIA_ENDPOINT`, `MEDIA_ACCESS_KEY`, `MEDIA_SECRET_KEY`, `MEDIA_BUCKET` and `MEDIA_SECURE=true` for S3, R2 or similar, behind a CDN. Video is not accepted yet: it needs a transcoding worker that also strips metadata.

## Posts

| Endpoint | Notes |
|---|---|
| `POST /v1/posts` `{body ≤ 2200, audience: public\|followers\|friends, mediaIds ≤ 10}` | Needs text or a photo. Photos must be the author's own, ready, unattached and uploaded for posts (409 `MEDIA_NOT_READY` otherwise). |
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
| `POST /v1/stories` `{body ≤ 280, background, mediaId?, audience}` | A photo or words on a colour. Lives 24 hours. The app defaults the audience from `storyAudience`. |
| `GET /v1/stories/tray` | Active stories from the viewer's circle, grouped by author: own first, then unseen, newest first. Authors see `viewCount`. |
| `POST /v1/stories/{id}/view` | Idempotent. Your own views aren't counted. |
| `GET /v1/stories/{id}/viewers` | Author only. |
| `DELETE /v1/stories/{id}` | Removes the story and queues its photo. |

## Reports

`POST /v1/reports` also accepts `targetType` `post`, `comment` and `story`. The reporter must be able to see the content, the subject is its author, and you can't report your own.
