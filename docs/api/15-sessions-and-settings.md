# Sessions and settings

Implemented in `services/api/internal/store/store.go` and `httpapi/server.go`; the app side is `apps/mobile/lib/features/settings.dart` and `privacy.dart`.

## Sessions

| Endpoint | Behaviour |
|---|---|
| `GET /v1/auth/sessions` | Live sessions only (not revoked, not expired), newest first, signed cursor. Each item: `sessionId`, `platform` (`android`, `ios`, `web`, `unknown`), `createdAt`, `lastSeenAt`, `expiresAt`, `current`. |
| `DELETE /v1/auth/sessions/{id}` | Signs out one of the caller's sessions. |
| `POST /v1/auth/sessions/revoke-others` | Signs out every other live session; returns `{revoked}`. |
| `POST /v1/auth/logout` | Ends this session. |

Clients send `X-Client-Platform` on every request. It is recorded when a session is created; anything other than the three known platforms is stored as `unknown`.

Authentication reads the session row on every request but writes `last_seen_at` at most once a minute, so steady traffic does not turn every API call into a database write. The API's hourly maintenance job deletes sessions 30 days after they expired, 5000 rows at a time.

When a signed-in request gets 401, the app drops the local session and returns to the welcome screen with "Your session ended", instead of showing errors on every screen.

## Privacy screen

Sections match what the server enforces today:

- **Your profile:** who can view the profile, and per-field visibility.
- **Connections:** `followPolicy`, `requestsFrom`, `messagesFrom`.
- **Discover:** `discoverable`, `showInterestOverlap`. Discover lists only public profiles, so the screen says so when `discoverable` is on and the profile isn't public.
- **Chats:** `readReceipts`, which is reciprocal and also covers typing.
- **For features on the way:** stories, comments, mentions, activity, online, last seen and location. These are saved now and applied when those features launch. The screen labels them that way rather than implying they already work.

Changes save together with optimistic concurrency (`If-Match`). A sticky bar offers Save or Discard while there are unsaved edits.

## Not yet built

Account deactivation, deletion and data export need step-up authentication, which depends on the identity provider that replaces development sign-in. They are specified in `docs/api/04-api-specification.md` §14.
