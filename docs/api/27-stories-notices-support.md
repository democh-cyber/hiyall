# Stories, comments, notifications, notices and support (Wave 7)

Implemented in migration `0050_social_features.sql`, plus:

- server: `domain/topics.go`, `domain/social7.go`, `domain/notices.go`, `domain/support.go`, `domain/notifications.go`, `media/audio.go`, `store/pulse.go`, `store/pulse7.go`, `store/voice.go`, `store/notices.go`, `store/visits.go`, `store/push.go`, `httpapi/social7.go`, `admin/social.go`
- admin console: `apps/admin/src/pages/Notices.tsx`, `Support.tsx`, `SupportThread.tsx`
- app: `lib/core/social7.dart` (client), `lib/features/` (topics, voice, thread view, search, My activity, notification settings, Notices, Support)

Every limit below is enforced by the server and is a `domain.Entitlements` value (free now, a Pro tier later: [plans and entitlements](../architecture/11-plans-and-entitlements.md)). Nothing here costs coins, shows ads or tracks reading.

## 1. Topics

Eight topics, original to Hiyall, listed by `GET /v1/topics` → `{items:["language","music","food","travel","games","art","sport","study"]}` (`domain.Topics`). The names are stored and sent; each client draws its own label and icon, and shows a name it does not know (a newer server) as plain text. The database only checks the shape (`^[a-z]{1,24}$`), so a new topic is a code change, not a migration.

- `POST /v1/posts` and `POST /v1/stories` take an optional `topic` (a name above, or null / empty for none; anything else is `422 VALIDATION` on `topic`). Posts and stories carry `topic` (string or null).
- `GET /v1/feed?mode=following|everyone&topic=music`: the feed narrowed to one topic. The cursor is bound to the mode and the topic.
- `GET /v1/stories/tray?topic=music`: the tray narrowed to one topic.

### Tabs

The app shows **Everyone** and **Following** tabs on the Pulse feed (`mode=everyone` and `mode=following`; Following is the viewer's circle: self, follows, friends) and on stories:

- Stories **Following**: `GET /v1/stories/tray` (grouped by author, as before).
- Stories **Everyone**: `GET /v1/stories/explore?topic=&cursor=&limit=` pages the **public** stories that are up now from people outside the tray's rules: newest first, muted, blocked, other-age-band and inactive authors never appear, the viewer's own are left out (the tray has them). Items are flat: `{author:{userId,username,displayName,avatarUrl}, storyId, body, background, textStyle, media, topic, voice, audience, createdAt, expiresAt, seen}`. Signed cursor, 15 minutes, `INVALID_CURSOR` otherwise. Read limiter: burst 30, then two a second.

## 2. Search

`GET /v1/search/pulse?q=&scope=posts|stories&topic=&cursor=`

- `q` is 2 to 80 characters (`422 VALIDATION` on `q` otherwise). The match is Postgres full text with the `simple` configuration (`to_tsvector('simple', body) @@ plainto_tsquery('simple', q)`: every word must appear, no stemming, so it works for any language) over **post text** (the last 180 days) or the **text of active stories**. GIN indexes `posts_search` and `stories_search`.
- What a member finds is what they could open: the audience rules of a single read (public, followers, friends), blocks, the age band, muted and inactive authors. Voice-only posts have no text and are not found.
- **Caps** like the people search's: each page counts against `PulseSearchPagesPerDay` (300 per UTC day, `429 DAILY_LIMIT`, `Retry-After` to the next UTC midnight), a page examines at most 100 matching candidates before the audience rules (when fewer than 20 are visible among them the response still carries a cursor to carry on after the last candidate examined), and a search reads at most **10 pages** (the 10th has no cursor). The cursor is signed, bound to the member, the text, the scope and the topic, and lasts 15 minutes (`422 INVALID_CURSOR`: "Start a new search").
- Response `{items, nextCursor, hasMore, scope}`: posts as in the feed, stories as in the Everyone list. Limiter: the search limiter (`429 RATE_LIMITED`).

## 3. Voice notes

A post or a story may carry one voice clip of at most **60 seconds** (`Entitlements.PulseVoiceSeconds`; `postId.voice` / `story.voice` = `{mediaId, url, durationMs}` or null; `url` is a signed read URL valid one hour, like photos).

1. `POST /v1/media/uploads` `{purpose:"voice", contentType:"audio/mp4", sizeBytes}` (up to 4 MiB: `413 TOO_LARGE`; any other type `415 UNSUPPORTED_MEDIA`). The same slot, daily upload count, declared bytes and storage quotas as photos apply (`429 QUOTA`). The presigned PUT pins the type and exact size.
2. The app PUTs the bytes.
3. `POST /v1/media/{id}/complete` **validates, and does not transcode**: it reads the MP4 boxes (`ftyp` brand M4A/mp42/isom, `moov/mvhd` duration, one audio track and no video track) and refuses anything else with `415 UNSUPPORTED_MEDIA` (the upload is deleted). A clip longer than 60 seconds (one second of encoder slack) is `422 VOICE_TOO_LONG`. The stored object is `media/{id}/voice.m4a`; the original upload is deleted. The reply is `{mediaId, status:"ready", durationMs, url}`.
4. `POST /v1/posts` / `POST /v1/stories` with `voiceMediaId`. The clip must be the member's own, ready, uploaded for voice and unused (`409 MEDIA_NOT_READY`). A post or story may be only a voice note; a story may have a photo and a voice note.

**Scanning does not apply to audio.** The upload scanner (`SCAN_HASHLIST_FILE`, `SCAN_PROVIDER_URL`) is image based: hash lists of known images and an image classifier. A clip is never rendered as pixels, only played, and the server does not decode it. Its `media_assets.scan_result` stays NULL. Voice notes are reachable by reports like any post or story (`POST /v1/reports`); a moderator hears nothing in the console today (the content preview shows text and photos only): this is a documented gap (see the release notes of the legal pass). Clean-up is the photos' (abandoned upload after an hour, unattached after a day, a deleted post's or story's clip with it).

The app records with the `record` package (AAC in an `.m4a`, mono, 64 kbit/s, stops at 60 s) and plays with `just_audio`; microphone permission strings are the chat voice messages' (`NSMicrophoneUsageDescription`, `RECORD_AUDIO`).

## 4. Threaded comments

Replies are **one level deep**. `POST /v1/posts/{id}/comments` `{body, parentId?}`: a reply to a reply is stored under the top-level comment of that thread (and notifies the member who wrote the reply it answers). `parentId` must be a visible comment on this post (`422 VALIDATION` on `parentId`).

- `GET /v1/posts/{id}/comments` without `parent` is unchanged: every comment, flat, oldest first (the first apps read this).
- `?parent=none`: only the top-level comments, each with **`replyCount`** (the replies the viewer can see; 0 on a reply).
- `?parent={commentId}`: the replies to that comment, oldest first.
- Deleting a top-level comment deletes its replies with it and leaves the post's count for all of them. The writer or the post's author can delete any comment.

Notifications: a reply creates the Activity item **`comment.replied`** ("replied to your comment", `type` comment, `targetType` post, `targetId` the post) for the author of the comment that was answered; the post's author hears about a comment once (a reply to their own comment is the reply item only). A comment from someone the author restricted is stored hidden and notifies nobody.

The translate button on posts, comments and stories uses `TranslationService` (`lib/core/translate/translation_service.dart`, on-device) when that file is part of the build; the button is hidden otherwise. The server never sees the translation.

## 5. Notification choices

`GET /v1/me/notifications` and `PATCH /v1/me/notifications` (a partial body of any of these booleans; unknown fields are `422`):

| Field | Meaning | Default |
|---|---|---|
| `enabled` | master switch: off silences everything but security pushes (a new device, an account deletion) | on |
| `chat` | new chat messages | on |
| `follows` | new followers, follow requests, accepted follow requests | on |
| `friendRequests` | friend requests, accepted requests, space invitations | on |
| `comments` | comments on your posts | on |
| `replies` | replies to your comments | on |
| `reactions` | reactions to your posts | on |
| `visits` | **profile visit notices: an owner opt-in** | **off** |
| `hideNames` | social pushes never name the person ("You have a new follower") | **on for a member under 18, off for an adult** until they choose |
| `social` | legacy umbrella (an older app): true while any social category is on; setting it sets follows, friendRequests, comments, replies and reactions (not `visits`) | derived |

The response has every field. The choices are **enforced by the server** when it decides to push (`store.PushAudienceFor`, called by the push dispatcher): the app only shows the switches. Muting a chat or a person, blocks, restrictions and the age band apply on top. `hideNames` is applied there too: with it on the dispatcher gets no name and sends the generic line, so a stranger's display name never travels through FCM or APNs to a lock screen. A member without a row has the defaults above.

Pushes now exist for `reaction`, `comment`, `reply`, `visit` and `support` besides the earlier kinds; they are content-free apart from the actor's display name when `hideNames` is off, coalesce per actor (reaction 30 minutes, comment and reply 10, visit a day) and count in the daily cap. See [push notifications](23-push-notifications.md).

### Profile visit notices (opt-in, default off)

When `visits` is on and someone opens the member's profile **for the first time** (a visit is recorded once per pair, so this is at most one notice per visitor and owner, and it is also kept to one per day), the owner gets the Activity item `profile.visited` ("visited your profile", `type` visit, `targetType` profile, `targetId` the visitor) and a push. Rules: never across the age band or a block (the visit is refused before this runs); the Activity item names the visitor under the same rules as the owner-only visitors list (active, not barred); the push says "Someone visited your profile" unless `hideNames` is off **and** the visitor's own profile audience lets the owner open their profile, when it names them (`visit` versus `visit_anon`). Visits themselves, the visitors list and `visitorsVisibleToOthers` belong to the profile ([profile](25-profile-and-discovery-v2.md)); this only adds the notification.

## 6. Notice board

Short posts from the Hiyall team: `safety`, `news` or `update`. Table `notices` (`noticeId`, `category`, `title` ≤ 120, `body` ≤ 4000, `audience` all|minors|adults, `locale` ('' for every language, else a code such as `en`, matched on its first subtag), `pinned`, `publishedAt` (may be in the future), `expiresAt`, `unpublishedAt`, `created_by`).

**Body markup** is exactly three things: paragraphs (a blank line), `**bold**` and `[label](https://address)` links. HTML (`<`, `>`), images, a link that is not `https` or has credentials, and unbalanced bold are refused by the console (`422`). Apps draw the markup themselves; no HTML reaches a screen, and a link opens only if it is https.

Member endpoints (age band decides the audience; a notice for minors reaches members under 18 only, one for adults the rest):

| Endpoint | Notes |
|---|---|
| `GET /v1/notices?locale=&cursor=&limit=` | Live notices (published, not unpublished, not expired), newest first, signed cursor. The response adds `unreadCount` (up to 99, `unreadMore`) and `pinned` (up to 3 live pinned notices, safety first). Each item has `unread`. |
| `GET /v1/notices/summary?locale=` | `{unreadCount, unreadMore, pinned}`: what Home needs for the pinned **safety banner** and what Settings needs for the unread dot. |
| `POST /v1/notices/seen` | Moves the member's pointer (`notice_seen`) to now: everything published so far is read. |

**No tracking.** Unread is a single pointer per member (`notice_seen.seen_at`, or the account's creation time before the first call): no per-notice reads, opens or timestamps are kept, and nothing is sent to anyone. The pointer is deleted with the account.

Console (admin role to publish, edit and unpublish; viewers and moderators read): see [admin console](../security/15-admin-console.md#notices-and-support).

## 7. In-app support

A member writes to Hiyall staff from Settings > Help & Safety > **Message support**. **Support messages are plaintext stored on the server and read by staff. They are NOT end-to-end encrypted** (the app says so above the box). Minors can use it. Reports about a chat or a member stay the existing flow (`POST /v1/reports`).

Tables `support_threads` (`category` account|safety|bug|other, `status` open|closed, `assigned_to`, `last_author`, the member's own `member_read_at`) and `support_messages` (`author` member|staff, `body` ≤ 2000). **A staff member is never named to the member**: only "Hiyall team".

| Endpoint | Notes |
|---|---|
| `GET /v1/support/threads` | The member's threads, most recent activity first, signed cursor; adds `unreadCount`. Each: `{threadId, category, status, createdAt, lastMessageAt, unread, lastAuthor, preview}`. |
| `POST /v1/support/threads` `{category, body}` | Opens a thread with its first message (201 with the thread). `409 SUPPORT_THREAD_OPEN` when the member already has an open thread in that category (reply there). |
| `GET /v1/support/threads/{id}` | One thread. |
| `GET /v1/support/threads/{id}/messages` | Oldest first, signed cursor; opening the first page marks the thread read. Each `{messageId, author, body, createdAt}`. |
| `POST /v1/support/threads/{id}/messages` `{body}` | 201 with the message. `409 SUPPORT_THREAD_CLOSED` when closed. |
| `POST /v1/support/threads/{id}/close` | The member closes their own thread (staff can reopen it). |
| `GET /v1/support/unread` | `{unreadCount}`: threads where staff wrote last and the member has not opened since. |

**Limits** (`Entitlements.SupportMessagesPerDay` = 20 per UTC day, counted when a thread is opened and when a message is sent, `429 DAILY_LIMIT`; 2000 characters, `422 VALIDATION`; one open thread per category, `409 SUPPORT_THREAD_OPEN`) plus the content limiter on writes.

**Push.** A reply written in the console (which has no push sender) waits as a row in `support_messages` with `pushed_at IS NULL`; every API node polls every 20 seconds and **claims** such rows with `FOR UPDATE SKIP LOCKED`, so exactly one node sends the content-free push **"Support replied"** (kind `support`, data `kind=support`) and a `support` realtime wake-up to the member. It obeys the master switch only. `store.ClaimSupportPushes`, `httpapi.RunSupportPush`.

**Retention and deletion.** A thread is kept **365 days after it closes**, then deleted with its messages (maintenance job "support thread purge", hourly). An open thread is kept while it is open. Deleting an account deletes its threads at once (`purgeContent`), and the data export lists them (`support`).

## 8. My activity

`GET /v1/me/activity/comments` and `GET /v1/me/activity/reactions` (signed cursors, 20 per page, up to 50, read limiter): what the member wrote and reacted to, newest first.

```json
{"commentId":"…","postId":"…","parentId":null,"body":"…","createdAt":"…",
 "post":{"postId":"…","state":"available","author":{…},"excerpt":"first 140 characters","topic":null,"hasMedia":false,"hasVoice":false}}
{"postId":"…","reaction":"heart","createdAt":"…","post":{…}}
```

`post.state` is `removed` (and the card carries only `postId`) when the post is deleted or no longer visible to the member (blocked, other age band, inactive author, audience changed). The app opens `GET /v1/posts/{id}` to jump to a post and shows "removed" for the rest. Deleted comments are not listed.

## Errors and limits added

| Code | Status | When |
|---|---|---|
| `VOICE_TOO_LONG` | 422 | a voice clip over 60 s (complete, or when attaching) |
| `SUPPORT_THREAD_OPEN` | 409 | a second open support thread in a category |
| `SUPPORT_THREAD_CLOSED` | 409 | a message to a closed thread |
| `DAILY_LIMIT` | 429 | post/story search pages (300 a day), support messages (20 a day) |
| `INVALID_CURSOR` | 422 | a search cursor that is not the member's or this search's, expired or past page 10 |

## Admin console endpoints

JSON under `/admin/v1`, the same envelope as [the console](../security/15-admin-console.md#notices-and-support):

| Method and path | Role | Notes |
|---|---|---|
| `GET /notices?status=all\|live\|scheduled\|ended\|unpublished&cursor=&limit=` | viewer | notices with their status |
| `POST /notices` | admin | `{category,title,body,audience,locale,pinned,publishedAt?,expiresAt?,reason}`; 201; audited `notice_publish` in the same transaction |
| `PUT /notices/{id}` | admin | the same fields; `404` for an unpublished notice; audited `notice_edit` |
| `POST /notices/{id}/unpublish` | admin | `{reason}`; audited `notice_unpublish` |
| `GET /support/threads?status=open\|closed\|all&category=&waiting=true&assigned=me\|none&sort=oldest\|newest&cursor=` | viewer | the inbox: no message text, the member's username, display name, age band and status |
| `GET /support/threads/{id}` | viewer | the thread and its messages; **audited before it is read** (`support_thread_view`) |
| `POST /support/threads/{id}/reply` | moderator | `{body}`; 201; `409 SUPPORT_THREAD_CLOSED`; audited `support_reply` (message id and length, never the text) |
| `POST /support/threads/{id}/close` and `/reopen` | moderator | `409 SUPPORT_THREAD_OPEN` when reopening beside another open thread of the category; audited |
| `POST /support/threads/{id}/assign` | moderator | `{assignTo:"me"\|null}`; audited `support_assign` |

## Legal items for the release agent (not edited here)

- Support threads are **plaintext** and readable by staff; kept **365 days after they close**, deleted with the account; included in the export.
- The notice board: staff-written, no reading is tracked; one "last seen" pointer per member, deleted with the account.
- Voice notes on posts and stories: audio up to 60 seconds, stored on the media bucket, not scanned, played to whoever may see the post or story, deleted with it.
- Post and story search: text of posts and stories a member may see is searchable by other members within those audiences.
- Notification choices and `hideNames`: social pushes can carry a display name through FCM and APNs unless names are hidden (the default for members under 18); profile visit notices are opt-in.
