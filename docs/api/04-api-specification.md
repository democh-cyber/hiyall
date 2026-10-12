# Hiyall API specification

**Status:** Architecture draft; typed MVP contract in `openapi-mvp.json`, advanced routes below are design inventory

**Style:** REST/JSON for commands/queries, WebSocket for real-time events, WebRTC for call media

**Base path:** `/v1`

**Time:** ISO-8601 UTC in transport; IANA time-zone IDs where a user/event local zone matters

`openapi-mvp.json` defines bounded MVP schemas, exact status codes, preconditions, and authentication. Tables here describe the broader roadmap. Deferred routes must not be treated as implemented or fully frozen contracts.

## 1. API principles

- Public API contracts do not mirror internal deployment boundaries.
- Every protected resource is authorized in the domain layer, not only by route middleware.
- Use opaque server IDs and cursor pagination; never expose sequential database IDs.
- Retryable creates/actions require `Idempotency-Key`; naturally idempotent PUT/DELETE and version-conditional edits specify their own safe retry rules. A client does not infer retry safety from HTTP method alone.
- Request and event IDs are returned for support and tracing; secrets and private content are not logged.
- All request bodies and query parameters are validated against bounded schemas.
- Privacy, block, membership, moderation, residency, and account status are checked at read and write time.
- The API returns a safe fallback when optional ranking, translation, search, or notification dependencies fail.

## 2. Authentication and headers

### Required headers

```http
Authorization: Bearer <short-lived-access-token>
Accept: application/json
Accept-Language: en-GB
X-Client-Version: ios/1.0.0
X-Request-Id: req_01J...
Idempotency-Key: idem_01J...   # required for retryable creates/commands
If-Match: "profile-version-7"   # required for conflict-sensitive edits
```

`X-Request-Id` is generated if absent. `Idempotency-Key` identifies a record by principal + HTTP method + normalized resource path + key. A canonical request body hash is stored in that record, not included in the uniqueness key; otherwise different bodies would escape conflict detection. Records for ordinary creates retain results for 7 days. Durable message deduplication survives that cache window. Reusing a key with a different body returns `409 IDEMPOTENCY_KEY_REUSED`.

### Auth model

- OIDC-compatible access tokens are short-lived and audience-scoped.
- Refresh tokens rotate and are bound to a session/device record.
- OIDC/Apple/Google/passkey provider subject resolution occurs only in the Identity module.
- Administrative APIs use a separate audience, host, role policy, and stronger MFA requirements.

## 3. Response envelopes

### Success

```json
{
  "success": true,
  "data": {},
  "meta": {
    "requestId": "req_01J...",
    "serverTime": "2026-10-06T12:00:00Z",
    "nextCursor": "cursor_opaque"
  }
}
```

`nextCursor` is omitted or `null` when there is no next page. Cursors are opaque, signed or integrity-protected, expire, and encode the relevant sort/ranking version. Clients must not parse them.

### Error

```json
{
  "success": false,
  "error": {
    "code": "INVALID_REQUEST",
    "message": "The request could not be processed.",
    "fields": {
      "username": "must be 3-30 characters"
    }
  },
  "meta": {
    "requestId": "req_01J..."
  }
}
```

Messages are safe for end users. Stack traces, SQL, provider payloads, tokens, and internal topology are never returned.

### HTTP status policy

| Status | Use |
|---:|---|
| 200 | successful read/update/action |
| 201 | resource created |
| 202 | accepted async workflow, such as export or deletion |
| 204 | successful empty delete/ack where body is not useful |
| 400 | malformed request or invalid field |
| 401 | missing/invalid/expired authentication |
| 403 | authenticated but not permitted; avoid leaking resource existence |
| 404 | not found or intentionally indistinguishable due to privacy |
| 409 | state conflict, duplicate, idempotency reuse |
| 412 | failed `If-Match` version precondition |
| 428 | required version precondition missing |
| 413 | body/media too large |
| 415 | unsupported media type |
| 422 | semantically invalid but well-formed input |
| 429 | rate limit; include `Retry-After` |
| 500/503 | safe server/dependency failure; return request ID |

Implemented conventions (foundation API):

- **Retry-After** is the real time until the refusal lifts, in whole seconds: the limiter's refill for rate limits, the seconds left of a 7-day friend-request cooldown, until the oldest pending upload expires, until the oldest key claim of the hour ages out. A refusal that lifts only when the caller acts (for example `Close an existing space before creating another`) has no `Retry-After`. Every 429, spaces included, follows this.
- **Timestamps** are always UTC with a `Z` suffix, whatever the server's own time zone: the database pool scans `timestamptz` in UTC and runs its sessions in UTC, and times taken from a request (a mute's `until`) are echoed in UTC.
- **Text** fields refuse NUL and other control characters (only tab, line feed and carriage return are allowed, and not in one-line values such as interests and filters) with `422 VALIDATION`; text the database still cannot store (SQLSTATE 22021/22P05) is also a 422, never a 500. A profile `timezone` must be a real IANA zone (`Local` is refused).
- **Every response carries `X-Request-Id`** and the standard headers (`Cache-Control: no-store`, `nosniff`, `no-referrer`, CSP), including refusals of `/v1/realtime` before the upgrade. A 500 is logged with the request id, method, path and the underlying error (never a body, credential, birth date or position).

## 4. Resource summaries

Responses expose only fields allowed by the viewer and current policy. The examples below are abbreviated.

```json
{
  "userId": "usr_01J...",
  "username": "naya",
  "displayName": "Naya",
  "avatar": { "mediaId": "med_01J...", "url": "signed-url" },
  "relationship": { "following": false, "friendship": "none", "blocked": false },
  "privacy": { "profile": "public", "location": "hidden" }
}
```

```json
{
  "messageId": "msg_01J...",
  "conversationId": "conv_01J...",
  "sequence": "1842",
  "senderId": "usr_01J...",
  "type": "encrypted",
  "protocolVersion": "reviewed-suite-version",
  "ciphertext": "base64-encoded-reviewed-protocol-envelope",
  "state": "delivered",
  "createdAt": "2026-10-06T12:00:00Z"
}
```

## 5. Authentication endpoints

| Method and path | Auth | Request | Response/notes |
|---|---|---|---|
| `POST /auth/signup/start` | none | `{method,emailOrPhone,locale,consentVersion}` | `202`; sends a bounded verification challenge |
| `POST /auth/signup/verify` | none | `{challengeId,code}` | `200`; consumes verification and returns session/onboarding state |
| `POST /auth/login/start` | none | `{identifier,clientContext}` | `202`; may require risk challenge |
| `POST /auth/login/verify` | none | `{challengeId,code}` | `200`; access + refresh rotation metadata |
| `POST /auth/oidc/exchange` | none | `{provider,authorizationCode,redirectUri,pkceVerifier}` | `200`; validates provider server-side |
| `POST /auth/passkeys/challenge` | none | `{purpose}` | `200`; WebAuthn challenge |
| `POST /auth/passkeys/verify` | none | `{challengeId,credential}` | `200`; session or signup continuation |
| `POST /auth/token/refresh` | refresh token | `{refreshToken}` | `200`; rotates refresh token, revokes reuse chain |
| `POST /auth/logout` | user | `{sessionId}` | `204`; revokes current/specified session |
| `POST /auth/logout-all` | user + step-up | no body | `204`; revokes all active sessions |
| `POST /auth/recovery/start` | none | `{identifier}` | `202`; response must not reveal account existence |
| `POST /auth/recovery/verify` | none | `{challengeId,code}` | `200`; invalidates prior sessions after provider/risk checks |

Rate limits apply by account, device, IP/ASN, provider, endpoint, and risk tier. OTPs are short-lived, single-use, and never stored in plaintext.

## 6. Users, profiles, sessions, and media

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /users/{userId}` | optional | `fields` bounded allow-list | Public-safe user summary; privacy may yield `404` |
| `GET /users/by-username/{username}` | optional | none | Same privacy-filtered summary |
| `GET /me/profile` | user | none | Full self-view, including editable/private fields |
| `PATCH /me/profile` | user | profile fields + `If-Match` | `200`; optimistic conflict returns `412` |
| `GET /users/{userId}/profile` | optional | none | Viewer-specific profile projection |
| `GET /users/{userId}/posts` | optional | `limit,cursor` | Visibility-filtered post page |
| `GET /users/{userId}/media` | optional | `limit,cursor` | Visibility-filtered media page |
| `GET /me/sessions` | user | `limit,cursor` | Current session/device list, no raw tokens |
| `DELETE /me/sessions/{sessionId}` | user | none | `204`; revoke one session |
| `POST /media/uploads` | user | `{purpose,contentType,sizeBytes,checksum}` | `201`; short-lived multipart upload session |
| `POST /media/uploads/{uploadId}/complete` | user | `{parts,checksum}` | `202`; returns processing state |
| `GET /media/{mediaId}` | authorized | none | Signed URL only after policy/scan state check |

Media upload completion is asynchronous. A client must render `processing`, `ready`, `rejected`, and `expired` states rather than assuming publish success.

## 7. Social graph and privacy actions

### Friends and follows

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `POST /users/{userId}/friend-requests` | user | `{message?}` | `201`; idempotent active request or privacy-safe conflict |
| `GET /me/friend-requests` | user | `direction,status,limit,cursor` | Cursor page |
| `POST /friend-requests/{requestId}/accept` | user | none | `200`; friendship projection |
| `POST /friend-requests/{requestId}/decline` | user | none | `204` |
| `DELETE /friend-requests/{requestId}` | user | none | `204`; cancel own request |
| `GET /me/friends` | user | `limit,cursor` | Accepted friends, privacy-filtered |
| `POST /users/{userId}/follow` | user | none | `201` or idempotent `200` |
| `DELETE /users/{userId}/follow` | user | none | `204` |
| `GET /users/{userId}/followers` | authorized | `limit,cursor` | Bounded public/follower projection |
| `GET /users/{userId}/following` | authorized | `limit,cursor` | Bounded following projection |
| `POST /users/{userId}/block` | user | `{reason?}` | `204`; takes effect synchronously for new access decisions |
| `DELETE /users/{userId}/block` | user | none | `204` |
| `POST /users/{userId}/mute` | user | `{surface,until?}` | `204` |
| `DELETE /users/{userId}/mute` | user | `{surface}` | `204` |
| `POST /users/{userId}/restrict` | user | none | `204` |

Server authorization checks block/restrict/privacy state for every endpoint, including search, media grant issuance, feed, notifications, and deep links. Already issued CDN grants have bounded residual access; see `docs/security/08-security-and-privacy.md`.

### Privacy Center

| Method and path | Auth | Request/response |
|---|---|---|
| `GET /me/privacy` | user | Current versioned privacy settings |
| `PATCH /me/privacy` | user | Field-level settings with `If-Match`; returns effective settings |
| `GET /me/discoverability` | user | Explains active discovery surfaces and visibility |
| `POST /me/privacy/preview` | user | `{viewerType,userId?}`; shows what a viewer would see without exposing private data |
| `GET /me/blocks` | user | Cursor-paginated blocked-account list |
| `GET /me/mutes` | user | Cursor-paginated muted-account/surface list |

## 8. Home, posts, comments, and stories

### Pulse/feed

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /feed` | user | `mode=personalized\|friends\|following\|communities\|global\|trending`, `limit,cursor` | Ranked post/story/Moment cards; includes reason/fallback metadata |
| `POST /feed/feedback` | user | `{objectType,objectId,action}` | `204`; hide/not-interested/report signal |
| `POST /feed/refresh` | user | none | `202`; optional rebuild request, not a synchronous fanout |

MVP feed responses default to 20 items and have a hard maximum of 50. The cursor includes ranking version and boundary; clients do not construct it.

### Posts

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `POST /posts` | user | `{type,body,mediaIds,audience,location?,poll?,link?}` | `201`; post may be `processing` until media/moderation completes |
| `GET /posts/{postId}` | optional | none | Viewer-authorized post detail |
| `PATCH /posts/{postId}` | owner/moderator | editable fields + `If-Match` | `200`; conflict-safe |
| `DELETE /posts/{postId}` | owner/moderator | none | `202`; tombstone/deletion propagation |
| `POST /posts/{postId}/reactions` | user | `{reactionType}` | `201`/`204`; idempotent per user/type |
| `DELETE /posts/{postId}/reactions/{reactionType}` | user | none | `204` |
| `POST /posts/{postId}/save` | user | none | `204` |
| `DELETE /posts/{postId}/save` | user | none | `204` |
| `POST /posts/{postId}/share` | user | `{destination,conversationId?,quote?}` | `201`; privacy checked for source and destination |
| `POST /posts/{postId}/repost` | user | `{audience,comment?}` | `201` |

### Comments and replies

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /posts/{postId}/comments` | authorized | `sort,cursor,limit` | Bounded threaded comment page |
| `POST /posts/{postId}/comments` | user | `{body,parentCommentId?}` | `201`; comment policy and moderation apply |
| `PATCH /comments/{commentId}` | owner/moderator | `{body}` + `If-Match` | `200` |
| `DELETE /comments/{commentId}` | owner/moderator | none | `202`; tombstone |
| `POST /comments/{commentId}/reactions` | user | `{reactionType}` | `204` |
| `DELETE /comments/{commentId}/reactions/{reactionType}` | user | none | `204` |

### Stories

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /stories/tray` | user | `limit,cursor` | Authorized story page; client groups by author; expiry/audience checked |
| `POST /stories` | user | `{type,body?,mediaId?,audience,expiresAt?,stickers?}` | `201` or `202` if media/moderation pending |
| `GET /stories/{storyId}` | authorized | none | Story detail; access is rechecked at read |
| `POST /stories/{storyId}/view` | user | `{completionRatio?}` | `204`; idempotent current view state |
| `POST /stories/{storyId}/replies` | user | `{body,mediaId?}` | `201`; creates authorized message/reply |
| `POST /stories/{storyId}/reactions` | user | `{reactionType}` | `204` |
| `DELETE /stories/{storyId}` | owner/moderator | none | `202`; expiry/deletion propagation |
| `GET /me/story-highlights` | user | `limit,cursor` | Highlight groups |
| `POST /me/story-highlights` | user | `{title,storyIds}` | `201` |
| `PATCH /story-highlights/{highlightId}` | owner | `{title,storyIds}` | `200` |

### Moments

Moments are the original bounded conversation primitive. They use the same post/media/chat contracts where possible but keep a separate lifecycle.

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /moments` | user | `topic,language,communityId,status,limit,cursor` | Discovery-safe Moment cards |
| `POST /moments` | user | `{title,prompt,audience,languages,capacity,startsAt,endsAt,moderationMode}` | `201` |
| `GET /moments/{momentId}` | authorized | none | Detail, rules, participants summary, current state |
| `POST /moments/{momentId}/join` | user | `{mode}` | `201`; may create approval request |
| `DELETE /moments/{momentId}/join` | participant | none | `204`; leave without social explanation |
| `POST /moments/{momentId}/close` | host/moderator | `{archive:boolean}` | `202` |
| `POST /moments/{momentId}/continue-privately` | participant | `{targetUserId}` | `201`; consent request, never unsolicited chat |
| `GET /moments/{momentId}/participants` | authorized | `limit,cursor` | Role/visibility-filtered summaries |

## 9. Search, Find Friends, interests, and recommendations

### Global search

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /search` | optional/user | `q,type,language,communityId,limit,cursor` | People, posts, communities, hashtags, topics, events |
| `GET /search/suggestions` | optional/user | `q,type,limit` | Prefix/typo-tolerant bounded suggestions |
| `GET /search/trending` | optional | `region,language,limit,cursor` | Safety-filtered trends; not private message content |
| `DELETE /me/search-history` | user | none | `202`; deletes retained history according to policy |

`type` is an allow-list. Search results always apply visibility, blocks, takedowns, and residency rules. Private message bodies are not included by default.

### Find Friends / Bridge

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /discover/people` | user | filters + `limit,cursor` | Filtered/re-ranked user cards with reason codes |
| `GET /discover/people/{userId}/overlap` | user | none | Shared-interest/community/language overlap only |
| `GET /discover/categories` | user | `category,limit,cursor` | Mutuals, similar interests, new users, global, etc. |
| `POST /discover/feedback` | user | `{candidateId,action}` | `204`; dismiss/hide/not-interested |
| `GET /me/interests` | user | none | Interest Passport with source/visibility |
| `PUT /me/interests` | user | `{interests:[{interestId,visibility}]}` | `200`; explicit user selections replace current set |
| `GET /interests/catalog` | optional | `q,language,limit,cursor` | Versioned taxonomy |
| `POST /recommendations/refresh` | user | `{surface}` | `202`; bounded refresh, not unlimited regeneration |

Discovery filters may include declared interests, language, coarse location, profession/education where voluntarily disclosed, community, activity, verification, and account type. Sensitive/discriminatory attributes are not accepted by the schema.

## 10. Chat, messages, and calls

### Conversations

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /conversations` | user | `type,limit,cursor` | User inbox projection, not a full member scan |
| `POST /conversations` | user | MVP `{otherUserId}`; advanced group contract later | `201`; membership/privacy checks; idempotency required |
| `GET /conversations/{conversationId}` | member | none | Membership-filtered metadata |
| `PATCH /conversations/{conversationId}` | owner/admin | `{title?,avatarMediaId?,permissions?}` + `If-Match` | `200` |
| `POST /conversations/{conversationId}/members` | admin | `{userIds}` | `202`; bounded batch, idempotent |
| `DELETE /conversations/{conversationId}/members/{userId}` | admin/self | none | `202` |
| `POST /conversations/{conversationId}/join-requests` | user | none | `201` |
| `POST /conversations/{conversationId}/read` | member | `{sequence}` | `204`; advances watermark monotonically |
| `POST /conversations/{conversationId}/typing` | member | WebSocket preferred | ephemeral; never persisted as content |
| `POST /conversations/{conversationId}/mute` | member | `{until?}` | `204` |

### Messages

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `GET /conversations/{conversationId}/messages` | member | `limit,cursor,before,after` | Ordered message page; server cursor preferred |
| `POST /conversations/{conversationId}/messages` | member | MVP `{clientMessageId,protocolVersion,deviceEnvelopes}`; private content fields are inside authenticated ciphertext | `201`; durable `sequence` and state |
| `GET /conversations/{conversationId}/messages/{messageId}` | member | none | Authorized message detail |
| `PATCH /conversations/{conversationId}/messages/{messageId}` | sender/admin | `{body}` + `If-Match` | `200`; edit window/policy enforced |
| `DELETE /conversations/{conversationId}/messages/{messageId}` | sender/admin | MVP `{scope:self|everyone}` | `202`; tombstone and notification policy |
| `POST /conversations/{conversationId}/messages/{messageId}/reactions` | member | `{reactionType}` | `204` |
| `DELETE /conversations/{conversationId}/messages/{messageId}/reactions/{reactionType}` | member | none | `204` |
| `POST /conversations/{conversationId}/messages/{messageId}/forward` | member | `{destinationConversationIds}` | `202`; source/destination visibility checked |
| `POST /conversations/{conversationId}/messages/{messageId}/translate` | member | `{targetLanguage}` | `200` or `202`; original is never changed |
| `POST /conversations/{conversationId}/messages/{messageId}/summarize` | member | `{language?}` | `200`/`202`; explicit user action and policy gate |
| `POST /conversations/{conversationId}/drafts` | member | `{clientDraftId,body,attachments?}` | `200`; drafts are private to author/device policy |
| `GET /conversations/{conversationId}/search` | member | `q,limit,cursor` | Only if message-search policy allows; otherwise client-local search |

`POST /conversations/{conversationId}/messages` uses the client `clientMessageId` plus `Idempotency-Key`. A retry returns the original durable result, not a second message. Read/delivery state is represented by conversation/member watermarks rather than a row for every recipient/message whenever possible.

### WebSocket contract

Connect at `wss://api.example/v1/realtime` with the access token via the approved handshake mechanism. Do not put long-lived tokens in URLs.

Client envelope:

```json
{
  "type": "message.send",
  "version": 1,
  "eventId": "client_evt_01J...",
  "conversationId": "conv_01J...",
  "data": {
    "clientMessageId": "cm_01J...",
    "protocolVersion": "reviewed-suite-version",
    "deviceEnvelopes": [
      { "recipientDeviceId": "device_uuid", "envelopeType": "session", "ciphertext": "base64-envelope" }
    ]
  }
}
```

Server envelope:

```json
{
  "type": "message.created",
  "version": 1,
  "eventId": "evt_01J...",
  "conversationId": "conv_01J...",
  "sequence": "1842",
  "occurredAt": "2026-10-06T12:00:00Z",
  "data": {}
}
```

Required event types: `connection.ready`, `message.accepted`, `message.created`, `message.updated`, `message.deleted`, `receipt.updated`, `typing.started`, `typing.stopped`, `presence.changed`, `conversation.updated`, `notification.created`, `error`, and `sync.required`.

The client sends `resume` with the last acknowledged event cursor. The server may respond `sync.required`, in which case the client uses REST cursors before resuming live events.

### Calls

| Method and path | Auth | Request/response |
|---|---|---|
| `POST /conversations/{conversationId}/calls` | member | Creates call session metadata and signaling token |
| `POST /calls/{callId}/join` | authorized participant | Returns short-lived WebRTC signaling/TURN configuration |
| `POST /calls/{callId}/leave` | participant | Records call history state |
| `POST /calls/{callId}/end` | host/participant policy | Ends signaling session |
| `GET /me/calls` | user | Cursor-paginated call metadata; no recording implied |

Signaling is API/WebSocket traffic. Audio/video flows peer-to-peer or through a WebRTC media service/TURN, never through the application API or database.

## 11. Notifications

| Method and path | Auth | Request/query |
|---|---|---|
| `GET /notifications` | user | `unreadOnly,type,limit,cursor` |
| `POST /notifications/{notificationId}/read` | user | none |
| `POST /notifications/read-all` | user | `{throughCreatedAt}` |
| `GET /me/notification-preferences` | user | none |
| `PATCH /me/notification-preferences` | user | per-type/device/quiet/digest settings + `If-Match` |
| `POST /me/push-tokens` | user | `{deviceId,provider,token}`; token encrypted at rest |
| `DELETE /me/push-tokens/{deviceId}` | user | none |

Notification creation is internal/event-driven. Clients never call a public “send push to user” endpoint.

## 12. Communities and events

| Method and path | Auth | Request/query | Response/notes |
|---|---|---|---|
| `POST /communities` | user | `{name,description,privacy,rules,avatarMediaId?}` | `201` |
| `GET /communities` | optional/user | `q,privacy,topic,limit,cursor` | Search/discovery projection |
| `GET /communities/{communityId}` | optional | none | Privacy-filtered detail |
| `PATCH /communities/{communityId}` | owner/admin | editable fields + `If-Match` | `200` |
| `POST /communities/{communityId}/join` | user | none | `201` or `202` pending |
| `DELETE /communities/{communityId}/join` | member | none | `204` |
| `GET /communities/{communityId}/members` | admin/allowed | `role,status,limit,cursor` | Bounded member list |
| `PATCH /communities/{communityId}/members/{userId}` | admin | `{role,state}` | `202`; audit action |
| `POST /communities/{communityId}/posts` | member | post payload | `201` |
| `GET /communities/{communityId}/posts` | member/optional | `limit,cursor` | Visibility/moderation-filtered |
| `POST /communities/{communityId}/events` | owner/admin/member policy | event payload | `201` |
| `GET /events` | optional/user | filters + `limit,cursor` | Time-zone-aware event page |
| `GET /events/{eventId}` | authorized | none | Detail and RSVP state |
| `POST /events/{eventId}/rsvp` | user | `{state}` | `204`; idempotent |
| `GET /events/{eventId}/attendees` | authorized | `limit,cursor` | Privacy-filtered attendee list |

## 13. Reports, moderation, and account lifecycle

### User-facing safety endpoints

| Method and path | Auth | Request/response |
|---|---|---|
| `POST /reports` | user | `{targetType,targetId,reasonCode,description?,evidenceRefs?,disclosureConsent?}` → `201` |
| `GET /me/reports` | user | `status,limit,cursor` → own report status where policy allows |
| `POST /reports/{reportId}/additional-context` | reporter | `{text,evidenceRefs?}` → `202` |
| `POST /appeals` | user | `{actionId,reason}` → `201` |
| `GET /me/appeals` | user | `status,limit,cursor` |

Admin moderation routes are under a separate host/audience, for example `/admin/v1/reports`, and are not available to consumer tokens. They support queue filters, case detail with minimised evidence, suspend/ban/restore, content action, appeal review, moderator notes, and immutable audit events.

## 14. Export, deletion, and account management

| Method and path | Auth | Request/response |
|---|---|---|
| `POST /me/export-requests` | user + step-up | `202` with export job ID and status URL |
| `GET /me/export-requests/{jobId}` | user | progress, expiry, download availability |
| `POST /me/deactivation` | user + step-up | `202`; reversible state policy |
| `POST /me/deletion-requests` | user + step-up | `202`; deletion saga ID/status |
| `GET /me/deletion-requests/{jobId}` | user | store/phase status and policy exceptions |
| `POST /me/deletion-requests/{jobId}/cancel` | user | allowed only during grace period |
| `POST /me/password/change` | user + step-up | credential update; rotates sessions per policy |
| `GET /me/security-events` | user | cursor page of login/session/security events |

Exports and deletions are asynchronous. The API exposes policy-safe progress, not internal queue or database details.

## 15. Rate limits and idempotency classes

Limits are distributed and evaluated by multiple dimensions: principal, device, IP/ASN, route, target object, region, and risk score.

| Class | Examples | Response |
|---|---|---|
| Authentication | signup, login, OTP, recovery | strict adaptive limit; `429` + challenge |
| Social graph | follows, friend requests, invites | account reputation + target limits |
| Content | posts, comments, reactions, reports | per-user/device and burst budget |
| Chat | messages, media, forwards, group adds | conversation/account/device limit |
| Search/discovery | search, suggestions, recommendations | query budget and result cap |
| Media | upload sessions, completion | quota, size, type, bandwidth limits |
| Admin | reports/actions/export | role-specific, audited, often lower concurrency |

Retryable `POST`, `PATCH`, and action endpoints define idempotency semantics in their OpenAPI descriptions. `GET` is safe to retry but still bounded and rate-limited.

## 16. Contract testing requirements

Before implementation is called complete:

- generate server/client types from the OpenAPI document;
- contract-test success/error envelopes, pagination, authorization negatives, and idempotency;
- fuzz validation for user text, media metadata, cursors, and nested JSON;
- test privacy/block state across every resource path and deep link;
- test duplicate/out-of-order WebSocket events and reconnect/resume;
- test backwards-compatible schema/event evolution;
- verify no sensitive fields appear in logs, push payloads, or error messages.

## 17. Frozen MVP transport rules

The machine-readable [MVP contract](openapi-mvp.json) is the authoritative route/schema subset for implementation planning. The preceding tables include advanced inventory and abbreviated examples; they do not override the typed contract. IDs serialize as canonical UUID strings (lowercase, hyphenated) and are accepted only in that form: `urn:uuid:`, braced, bare-hex and upper-case spellings are 404 in a path and 422 in a body (`domain.IsID`), sequence/version counters as decimal strings (checked against signed bigint bounds), and dates as UTC ISO-8601. OpenAPI 3.1 permits JSON Schema constructs for conditional body validation. Generator compatibility must be checked at repository setup, not assumed from parsing this document. [OpenAPI 3.1.1 specification](https://spec.openapis.org/oas/v3.1.1.html).

- Default page 20, hard cap 50; request body 64 KiB, upload-completion metadata at most 1 MiB. Reject unknown properties and unsupported query keys. No mobile binary media bytes on these endpoints.
- Cursor contains principal/surface, normalized filter hash, sort tuple or rank epoch/position, authorization-relevant scope, expiry, and signature version. Invalid, altered, cross-user or wrong-filter cursor returns `400 CURSOR_INVALID`; expired rank snapshot returns `400 CURSOR_EXPIRED`. Do not carry credentials or private content in a cursor.
- Feed snapshots freeze ordering, not permission. Hydrate each page under current block/visibility/expiry/moderation policy; overscan a bounded candidate window and permit sparse pages. Return the next scan boundary, not the number of visible cards. A refresh creates a new epoch; clients dedupe by resource ID and retain the most recent resource version.
- Private profile/chat/job/settings responses use `Cache-Control: private, no-store` at shared caches. Client encrypted cache policy is separate. Public immutable media may be cached only with an appropriate audience grant. `204` has no JSON body; all JSON success/error responses include request ID/server time.
- Strong quoted version ETag (`"7"`) returned by conditional resources. Missing `If-Match` gives `428 PRECONDITION_REQUIRED`; mismatch gives `412 VERSION_CONFLICT`. Create/accept/send actions with a required idempotency header have a principal/method/path/key uniqueness record and a stored canonical request hash. An in-flight conflicting request gets `409 IDEMPOTENCY_IN_PROGRESS`, then a safe retry; different body gets `409 IDEMPOTENCY_KEY_REUSED`.
- An idempotent replay returns the original committed outcome or a policy-safe tombstone; it still rechecks live principal and object authorization. Never replay a cached private payload to someone who has since lost access. A retry-cache expiry does not erase durable message sender/client-ID mappings.
- Edits: owner only; post/comment version-conditional; chat text sender-only within 15 minutes. Delete-for-everyone: sender within 24 hours; case-scoped safety removal is a separate admin operation. User or moderator removal produces a tombstone, never an impersonated edited message.
- The MVP has no cross-user group-creation shortcut. A direct conversation requires eligible accepted contacts or accepted recipient consent; pair uniqueness and block checks are transactional. Requests contain only connection metadata until acceptance; no plaintext private introduction, attachment/preview or read/online disclosure.
- The MVP uses E2EE private text/attachments/control payloads; reactions/replies/edits are encrypted. Receipts/delivery metadata remain minimized server-visible state. Drafts and search remain encrypted/local. It defers forwarding/scheduling/disappearing rules, GIF/sticker catalogs, contact/location sharing, and server message search until their privacy/moderation contracts are designed. Story stickers/music/polls and events/groups/AI likewise remain advanced inventory.

### Real-time session and resumption

Native Flutter uses a bearer header during TLS WebSocket upgrade; future web clients obtain a 30-second one-use session-bound ticket and authenticate in the first frame within 5 seconds. No bearer/refresh token in query strings. Until authenticated, the gateway permits no subscriptions/content. Proposed maximum authenticated frame: 64 KiB, heartbeat: 30 seconds, connection idle deadline: 90 seconds, bounded queued bytes per connection: 1 MiB. A slow reader receives a safe reconnect/sync instruction and disconnect rather than consuming unbounded memory.

1. `connection.ready` includes server time, session ID, supported event version and a principal-scoped resume cursor.
2. Client `resume` sends that opaque cursor. Seven-day durable `sync_events` retain resource pointers/versions, not copies of private message text. Replay hydrates only currently authorized sources; removed content yields permitted tombstones.
3. `message.send` uses the same command validation/authorization/idempotency as HTTP, mapping clientMessageId plus sender and conversation to one durable result. `message.accepted` means committed, not delivered. HTTP and socket retries dedupe against the same mapping.
4. Conversation `sequence` orders message creates; message `version` handles edits/deletes; principal `syncSequence` orders replay events. None substitutes for another. Do not advance a resume watermark through an unprocessed gap. Processing an event and persisting its cursor happen in one local transaction.
5. `receipt.updated` carries monotonic eligible member watermarks. Delivered means recipient app accepted/persisted, not that the push provider accepted a notification. Read is voluntary and follows privacy controls. Sender's local `sending/failed` states are not durable server receipt states.
6. `typing/presence` expire via TTL, are lossy, rate-limited, and absent from durable replay. Revalidate session/member/pair policy at send, subscribe and replay; revocation closes affected subscriptions.
7. If replay retention or cursor scope is invalid, emit `sync.required` with a safe reason and REST resource scopes. Sync metadata/history via bounded cursors, then subscribe from a fresh watermark. Edits/deletes must be recovered through sync revisions, not merely a `sequence > last_message` query.

Every real-time frame uses `type`, `version`, `eventId`, `occurredAt`, optional conversation/message sequence, resource version and typed payload. Unknown major versions fail with a safe protocol error. Heartbeats and ephemeral event IDs need not be persisted; durable effects always are. A separate versioned event schema artifact is a foundation-phase deliverable before gateway implementation.

## 18. Separate admin contract boundary

The admin web dashboard and API are an isolated application host/audience. These routes are architecture inventory pending their own machine-readable contract; none accepts a consumer token.

| Route / capability | Role | Required authorization / audit |
|---|---|---|
| `GET /admin/v1/metrics` | analyst | Aggregated DAU/MAU, growth, retention, reports, server health; no raw private content |
| `GET /admin/v1/users` | support | Bounded account lookup and lifecycle state; no arbitrary message access |
| `GET /admin/v1/reports` | reviewer | Region/severity/status queue and assigned case scope |
| `GET /admin/v1/reports/{reportId}/evidence` | assigned reviewer | Time-bound purpose grant; only reported evidence; log every read |
| `POST /admin/v1/actions` | reviewer/senior reviewer | Typed target, policy reason, case scope, expiry; critical ban requires human escalation |
| `POST /admin/v1/actions/{actionId}/restore` | senior reviewer | Compensating action, never overwrite audit record |
| `GET /admin/v1/appeals` | appeals reviewer | Independent review workflow and action context |
| `POST /admin/v1/appeals/{appealId}/resolve` | appeals reviewer | Decision, explanation, policy version and immutable audit |
| `GET /admin/v1/audit` | auditor | Redacted purpose/actor/action/time; no broad content replay |

Admin UI: health/engagement dashboard; user search/account status; reports queue; case detail/evidence grant; action confirmation/reason; appeals; audit. RBAC is supplemented by case assignment, region, scope and purpose. No dashboard should imply that an empty queue or green server graph proves content safety.


## 19. E2EE transport update — mandatory user requirement

[Encrypted-chat design](../security/11-encryption-and-interception.md) supersedes all legacy plaintext chat examples/advanced inventory above. `MessageCreate` and encrypted edit/reaction commands use protocol-generated device envelopes, not body/reaction/language/attachment-key fields. A server response to send is a relay acknowledgment; history/detail returns only the authenticated current device's ciphertext, never another device's envelope. Body-level semantics and reply/control targets are verified after client decryption. No silent plaintext fallback. Exact protocol suite, serialized headers/prekey bundles and directory APIs must be reviewed before these routes are frozen for chat implementation.

The server keeps authorized relay metadata, versions, device eligibility, envelope-size/quota controls, receipts and durable deduplication. Ratchet/outbox state is persisted atomically on clients; retries reuse identical ciphertext. Encrypted edits/reactions append immutable encrypted revisions/control deliveries so offline devices can recover every required protocol envelope. Do not overwrite the only copy of an undecrypted ratchet message. User deletion produces allowed transport tombstones; it cannot recall recipient plaintext or erase history already copied.

Encrypted uploads set `encryptionMode=e2ee` for message purpose, use ciphertext MIME/checksum/size and `encrypted_uploaded` state, and place keys/descriptors inside E2EE envelopes. Server social-media scanning/transcoding does not run on chat ciphertext. Push carries generic wake-up metadata only. Server chat translation/search/moderation and plaintext exports are unavailable; local processing or explicit evidence/AI disclosure applies. See the mandatory proxy/release/device-key tests in the encryption document.
