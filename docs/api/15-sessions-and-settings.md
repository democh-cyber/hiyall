# Sessions and settings

Implemented in `services/api/internal/store/store.go` and `httpapi/server.go`; the app side is `apps/mobile/lib/features/settings.dart` and `privacy.dart`.

## Sessions

| Endpoint | Behaviour |
|---|---|
| `GET /v1/auth/sessions` | Sessions that are still signed in, newest first (by `createdAt`), signed cursor: not revoked, and either unexpired or, for a sign-in from the identity provider, used (`lastSeenAt`) within the last 30 days. Each item: `sessionId`, `platform` (`android`, `ios`, `web`, `unknown`), `createdAt`, `lastSeenAt`, `expiresAt`, `current`. |
| `DELETE /v1/auth/sessions/{id}` | Signs out one of the caller's sessions, expired or not, and ends its realtime connections. |
| `POST /v1/auth/sessions/revoke-others` | Signs out every other session, including idle ones whose last token has expired, ends their realtime connections and sets the sign-out watermark (below); returns `{revoked}`. |
| `POST /v1/auth/logout` | Ends this session and its realtime connections. |

Clients send `X-Client-Platform` on every request. It is recorded when a session is created; anything other than the three known platforms is stored as `unknown`.

Authentication reads the session row on every request but writes `last_seen_at` at most once a minute, so steady traffic does not turn every API call into a database write.

### Identity-provider sessions stay revoked

A Firebase session is the interactive sign-in, `fb:<sub>:<auth_time>`, and `expiresAt` is only the expiry of the last ID token the API saw (an hour). The refresh token keeps minting ID tokens with the same `auth_time` for as long as the person stays signed in on that device, so a session whose `expiresAt` has passed is idle, not over. Therefore:

- **Revoking** marks the row whatever its expiry, and the row is a **tombstone**: the next refreshed token for that sid is refused (401) instead of recreating the session.
- **Sign out everywhere else** also sets `auth_identities.sessions_revoked_before` (migration `0020`). A Firebase sign-in whose `auth_time` is at or before that watermark and that has no session row yet is refused, so it also covers a device that signed in earlier but had not called the API. The device that pressed the button keeps its row and stays signed in; a new sign-in afterwards works.
- **Purging** (hourly, 5000 rows at a time, `store.PurgeSessions`): development sessions 30 days after they expired; identity-provider sessions that were never revoked once they are 30 days past expiry and unused for 400 days (a refreshed token recreates such a row, except for a sign-in from before a watermark: so the device that signed the others out has to sign in again only after 400 days without using the app). **Revoked identity-provider sessions are never purged**; they are one small row per sign-out.

### Realtime connections end with their session

Each socket remembers the session it authenticated with. Logout, revoking a session, sign out everywhere else and a suspension (from `cmd/moderate`, which notifies through PostgreSQL in its transaction) end the matching sockets at once on every API node, through the realtime bus; the local node closes its own even if the bus is down. The socket is closed with **1008** ("session ended"), unlike the 1013 resync close, so the client must authenticate again rather than just reconnect. Every heartbeat (25 seconds) also checks the session again and closes the socket when it is revoked, expired or the account is no longer active, which covers a node that missed the notice and an ID token that expired without the app making a request. A database error at that check keeps the socket. A client that stays connected longer than its ID token lives should make a request with a fresh token (which extends the session) or expect to reconnect.

When a signed-in request gets 401, the app drops the local session and returns to the welcome screen with "Your session ended", instead of showing errors on every screen.

## Privacy screen

Sections match what the server enforces today:

- **Your profile:** who can view the profile, and per-field visibility (including `age`, whole years, and `counts`, the friends, following, followers, visitors and stories counts; both default to everyone).
- **Connections:** `followPolicy`, `requestsFrom`, `messagesFrom`. New accounts start with `followPolicy` and `messagesFrom` both `everyone` (instant follows; anyone not blocked and in the same age band may message, with no friendship or follow needed), and `requestsFrom` `everyone`. `approval`, `friends`, `followers` and `nobody` stay available through the API for members who choose them; the app offers no screen for any of it for now.
- **Discover:** `discoverable`, `showInterestOverlap`. Discover lists only public profiles, so the screen says so when `discoverable` is on and the profile isn't public.
- **Chats:** `readReceipts`, which is reciprocal and also covers typing.
- **For features on the way:** stories, comments, mentions, activity and location. (Online and last seen are live: one control, `onlineAudience`; `lastSeenAudience` is stored but not used. See [Presence](19-nearby-and-open-access.md#presence).) These are saved now and applied when those features launch. The screen labels them that way rather than implying they already work.

Changes save together with optimistic concurrency (`If-Match`). A sticky bar offers Save or Discard while there are unsaved edits.

## Not yet built

Account deactivation, deletion and data export need step-up authentication, which depends on the identity provider that replaces development sign-in. They are specified in `docs/api/04-api-specification.md` §14.
