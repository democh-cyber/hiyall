# Profile photos

A member can have one profile photo (an avatar). It reuses the photo pipeline described in [Pulse, stories and photos](16-pulse-and-media.md#photos): the same upload, re-encode (2048 px full and 640 px thumb JPEGs, metadata and GPS dropped), signed URLs and clean-up. Implemented in migration `0022_avatar_media.sql`, `services/api/internal/store/{avatar,store}.go`, `internal/httpapi/{pulse,server}.go` and `internal/domain/models.go`.

## Setting a photo

The media routes need a finished onboarding, so the app uploads the photo after onboarding completes. Nothing about the onboarding gate changed.

1. `POST /v1/media/uploads` `{purpose: "avatar", contentType, sizeBytes}`. The limits, the per-account upload limiter and the 50-pending cap are the same as for post and story photos. Avatar uploads count towards the member's daily upload slots and bytes and towards their live photo storage like any other photo (`429 QUOTA`, see [Limits and quotas](16-pulse-and-media.md#limits-and-quotas)); a replaced or cleared avatar frees its storage. The app shows the server's message inline, offers no retry for a limit, and during onboarding a photo that fails never blocks entering the app. `503 MEDIA_UNAVAILABLE` when storage is not configured.
2. PUT the bytes to the returned URL, then `POST /v1/media/{mediaId}/complete`.
3. `PATCH /v1/me/profile` with `If-Match` and `{"avatarMediaId": "<mediaId>"}`. The answer is the updated profile, including the new URLs.

`avatarMediaId` is a canonical lowercase UUID or `null`:

| Value | Result |
|---|---|
| The caller's own `avatar` photo that is `ready` and not attached | Attached to the profile. The previous avatar, if any, is marked deleted in the same transaction, and the hourly media clean-up removes its objects. |
| The id the profile already has | No change to the photos. Other fields in the request still apply. |
| `null` | Clears the avatar and releases the previous photo the same way. Needs no storage. |
| Anything else: someone else's photo, a post or story photo, a pending upload, a photo that is attached or deleted, an unknown id, a malformed id | `422 VALIDATION` on `avatarMediaId`. The whole request is rolled back: no other field changes and no photo is attached. |

`coverMediaId` stays "not enabled yet": only `null` is accepted.

A photo that is uploaded but never claimed expires after a day like any unattached photo, so abandoned uploads are cleaned up.

## Where the URLs appear

`avatarUrl` is a signed URL of the 640 px thumbnail, or `null` when the person has no photo, the photo is not ready or was deleted, or storage is not configured (nothing errors in that case). URLs last one hour and are minted for each response; they are never stored. Cache image bytes by `avatarMediaId` or by the URL path, not by the whole URL.

Own profile (`GET`/`PATCH /v1/me/profile`) and another member's profile (`GET /v1/users/{id}/profile`, including your own through that route) also carry `avatarFullUrl`, the signed full-size photo or `null`. The locked card (the profile's audience excludes you) shows the thumbnail only: `avatarFullUrl` is `null` there.

```json
// GET /v1/me/profile
{ "userId": "...", "username": "anjali", "avatarMediaId": "01a1...", "avatarUrl": "https://.../media/01a1.../thumb.jpg?X-Amz-...", "avatarFullUrl": "https://.../media/01a1.../full.jpg?X-Amz-...", "...": "..." }
// GET /v1/users/{id}/profile
{ "userId": "...", "username": "niko", "displayName": "Niko", "avatarUrl": "https://...", "avatarFullUrl": "https://...", "locked": false, "...": "..." }
```

Every other place a person is shown gains `avatarUrl` on the person object (the thumbnail only):

| Response | Where |
|---|---|
| People search `POST /v1/discovery/search`, Nearby `POST /v1/discover/nearby` | on each item |
| `GET /v1/users/{id}/followers`, `following`, `friends`, `GET /v1/me/follow-requests`, `GET /v1/stories/{id}/viewers` | `items[].user.avatarUrl` |
| Friend requests (`GET /v1/me/friend-requests`, send, accept, decline) | `sender.avatarUrl` and `recipient.avatarUrl` |
| `GET /v1/notifications` | `items[].actors[].avatarUrl` |
| Feed, saved, `GET /v1/posts/{id}`, `GET /v1/users/{id}/posts` | `author.avatarUrl` |
| Comments, including the one just created | `author.avatarUrl` |
| `GET /v1/stories/tray` | `items[].author.avatarUrl` |
| Spaces: cards (`owner.avatarUrl`), `GET /v1/spaces/{id}/members` (`items[].user.avatarUrl`), `GET /v1/spaces/{id}/entries` (`items[].author.avatarUrl`) | |
| Conversations (`POST`/`GET /v1/conversations`, `GET /v1/conversations/{id}`) | `peer.avatarUrl` |
| `GET /v1/me/blocked`, `muted`, `restricted` | `items[].user.avatarUrl` |

Report subjects (`/v1/reports`, `/v1/me/reports`) carry no photo, like the name they hide from a reporter who may not know the person.

## Who can see a photo

A photo is shown wherever, and to whomever, the person is shown. Every query that returns people still applies its existing rules first (blocks in either direction, the other age band, inactive or not-yet-onboarded accounts, audiences, mutes), and the photo comes from the same row, so a blocked or age-band-barred member never gets another's photo. Profiles are public by default, so in Discover anyone onboarded can see an avatar. A signed URL is a bearer link for an hour, like the post photo URLs.

## How it is stored and read

- `media_assets.purpose` allows `avatar` (migration `0022`, which only widens the `media_assets_purpose_check` constraint).
- The profile keeps the id in its stored JSON as `avatarMediaId` (already part of the profile; `null` until set). No profile column or index was added: rendering joins `media_assets` by primary key once per person row (`LEFT JOIN`, so a page of people costs no extra queries). The join requires the media to be the person's own, purpose `avatar` and `ready`, so a deleted, pending or foreign id simply renders as no photo.
- Attaching, releasing and the profile write are one transaction, serialised by the profile row lock and the `If-Match` version check.
- Signed URLs and object keys are never logged.
