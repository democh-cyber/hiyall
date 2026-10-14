# Nearby and open access

Hiyall is for Gen Z and is **not adult-only**. Anyone old enough can join, every onboarded member is visible to everyone in Discover, and the app has no privacy options for now: the one control a member has is whether others can see them online. A new Discover section, **Nearby**, lists people close to the member's own location. Since the second owner decision (see [age bands](#age-bands)) it also keeps minors and adults apart, stores the birth date privately and adds age and gender filters. Implemented in migrations `0016_open_profiles_nearby.sql` and `0017_member_ages_and_gender.sql`, `services/api/internal/domain/{models,nearby,onboarding,discovery,agebands}.go`, `internal/store/{discovery,nearby,spaces,store,onboarding,social,chat,pulse,safety}.go` and `internal/httpapi/{nearby,discovery,spaces,onboarding}.go`.

**Status.** Covered by unit tests and by PostgreSQL integration tests against the dedicated `hiyall_test` database. Nothing here has been exercised from the Flutter app, on a second API node, with real users or under load beyond the single synthetic query measurement described below. Treat the safety assumptions as unreviewed; see the [safety note](#safety-note-for-the-owner).

## What changed

| Area | Before | Now |
|---|---|---|
| Who can join | 18 and over (declared) | 13 and over (declared), `domain.MinimumAge` |
| Who can use people search and spaces | Only accounts with a trusted `discovery_eligibility` record (never provisioned for real users) | Every active member who finished onboarding |
| Default profile | Friends-only, not discoverable, every field hidden, presence hidden | Public, discoverable, every field visible; the followers and following lists open to followers (friends only for minors), presence shown |
| Messaging | Friends only by default | Anyone not blocked and in the same age band, no friendship or follow needed (`messagesFrom` "everyone"), minors included within their band |
| Following | Needed approval by default | Instant by default (`followPolicy` "everyone") |
| Profile counts | Friends, following, followers, shown to friends | Plus visitors and stories; shown to everyone by default (new `counts` audience) |
| Presence | Not exposed | `online` / `lastSeenAt` when the member's `onlineAudience` admits the viewer (below) |
| Location | Never | Coarse, expiring, listed as distance buckets (Nearby); stored only when the client sends it |
| Birth date | Read, checked and dropped | Stored privately once (`member_ages`), never returned; places the member in the minor or adult age band. Whole years of age are shown on the profile (below) |
| Minors and adults | Not told apart | Kept apart everywhere a block applies (`AGE_BAND_ISOLATION`, default on) |
| Discover filters | Interests, languages, country, vibe | Plus `ageMin`, `ageMax` and `gender`, in people search and Nearby |

## Minimum age

`POST /v1/me/onboarding/complete` refuses a declared age under 13 with `403 AGE_REQUIREMENT_NOT_MET` and the message "Hiyall is for people 13 and over." The validation is as strict as before (real calendar day, from 1900, not in the future, current terms version). The birth date is no longer dropped: it is stored privately, once (see [age bands](#age-bands)); it is still never logged, echoed or returned. Someone who turns 13 today is accepted. 13 is the floor the identity providers set (the owner's stated rationale; not independently checked here); the owner can change the `MinimumAge` constant and the message follows it. The column that records the declaration is renamed `age_declared_at`.

What the check does **not** do: it is a self-declaration, so it is not age assurance and anyone can type a different date. It does not verify identity or collect parental consent. What it does do is decide a member's age band and so which protections apply, which is exactly why a falsified date defeats them; see the [safety note](#safety-note-for-the-owner).

## Eligibility is retired

People search and shared spaces no longer join or check `discovery_eligibility`. Removed: `store.EligibleAdult`, the `403 DISCOVERY_ELIGIBILITY` response ("Adult eligibility must be confirmed before discovery is available") and the `403 ADULT_SPACE_REQUIRED` response ("Shared spaces are available to verified adults"). The table stays in the schema for migration history, is marked retired with a table comment and has no readers or writers; `0005_discovery_eligibility.sql` still describes it. Every other check is unchanged: the target must be active and have completed onboarding, discoverable and public (people search, Nearby), and not blocked in either direction; spaces still enforce bans, roles, capacity, parent-community membership and host status on every read and write.

A member who has not finished onboarding is not listed anywhere, and `GET /v1/users/{id}/profile` answers `404` for them to everybody else. This matters because new accounts are public and discoverable from the moment they are created: without it, a half-set-up placeholder profile would be findable.

## Open defaults

`domain.DefaultPrivacy()` is what provisioning (`ResolveOIDC`, so Firebase sign-in) and `Seed` write, and it is what migration `0016` rewrites every existing row to.

| Setting | Value |
|---|---|
| `profileAudience`, `discoverable`, `showInterestOverlap` | `public`, `true`, `true` |
| `onlineAudience` | `everyone` |
| `fieldAudiences` | `everyone` for `pronouns`, `gender`, `age`, `counts`, `location`, `profession`, `education`, `website`, `timezone`, `languages`, `interests`, `vibe`; `followers` for `connections` (adults; `friends` for minors, set at onboarding) |
| `messagesFrom`, `followPolicy`, `requestsFrom` | `everyone` (anyone not blocked and in the same age band may message; a follow is instant) |
| `storyAudience`, `commentsFrom`, `mentionsFrom` | `friends` |
| `activityAudience`, `lastSeenAudience` (unused: last seen follows `onlineAudience`), `locationAudience` | `nobody` |
| `readReceipts` | `false` (unchanged) |

The three `nobody` audiences have no screen. The endpoints and their validation are untouched, so `PATCH /v1/me/privacy` still accepts every field and search and profile views still honour whatever is stored; only the defaults and the removed eligibility gate changed. A new account's profile data also mirrors `profileAudience: "public"`.

### Migration `0016_open_profiles_nearby.sql`

1. Renames `onboarding.adult_declared_at` to `age_declared_at`. `0015` is already applied in development and test databases and is not edited.
2. Comments `discovery_eligibility` as retired.
3. Rewrites **every existing** `privacy_settings` row: the keys in the table above are overwritten with the new defaults, `version` is incremented and `updated_at` set. Keys not in the table (for example `readReceipts`, or any other stored key) keep their value. Existing members' own earlier choices for the listed keys are replaced, including anyone who had chosen a private profile; that is the intended effect of the product decision and cannot be undone by the migration.
4. Sets `profiles.data->>'profileAudience'` to `public` for every profile and increments `profiles.version`, so a client holding an old `If-Match` version gets `412 VERSION_CONFLICT` once and reloads.
5. Creates `user_locations` with its indexes (below).

The migration was run against the dedicated test database and its rewrite is covered by a test that applies the file to a scratch schema and compares the result with `DefaultPrivacy()`. It has not been applied to the shared development database by this change; `./scripts/dev-api.sh` applies it on the next start.

## Open messaging, instant follows and profile counts

Owner decision (2026-10-10): anyone can message anyone, so there is no need to add a friend; members may follow each other, but following must not restrict messaging; and the profile page shows Following, Followers, Visitors and Stories counts. Implemented in migration `0019_open_messaging_visitors.sql`.

### Messaging

`messagesFrom` and `followPolicy` default to `everyone`, and migration `0019` rewrites every existing privacy row to them (the version is bumped only where something changed). **Anyone who is not blocked and, with `AGE_BAND_ISOLATION` on, is in the same age band may open a conversation with anyone, with no friendship and whatever the follow state** (none, pending, active, either direction). The barrier still behaves like a block (404). That includes minors, who keep their other stricter defaults but whose `messagesFrom` is also `everyone`, within their band; there is no minor-specific messaging rule.

The code path is one function, `canMessage`: it checks that both accounts are active and onboarded (an unfinished account is missing, 404, for following, friend requests and messaging too, like its profile), the pair is not barred, and then the target's `messagesFrom`; `everyone` returns at once. It is called when a conversation is opened, when a message is relayed, when a peer's devices are listed and when a one-time key is claimed, and nothing else in chat checks friendship or follows (the inbox, acknowledgements and read state never did). `friends`, `followers` and `nobody` are still honoured for members who set them through the API (`403 MESSAGES_NOT_ALLOWED`; once the target has written, the other side may always reply); nothing in the app sets them. Blocking and reporting work as before.

**Shared interests on conversations.** Every conversation payload (`POST /v1/conversations`, `GET /v1/conversations`, `GET /v1/conversations/{id}`) carries `sharedInterests`: an array of at most 3 strings, always present, `[]` when there is nothing to show. It is the case-insensitive intersection of both members' profile `interests`, spelled and ordered as the caller wrote them (so a peer's own spelling is never shown), computed on the server so the app only reflects it. The peer's interests are compared only when the peer's `profileAudience` and `fieldAudiences.interests` both admit the caller, using the same `privacyOf`, `relationship` and `Relationship.Allows` helpers as the profile view (`everyone` always; `followers` for an active follower or a friend; `friends` for friends; `nobody` never; a locked profile shows nothing). Blocked and age-barred pairs never get this far because the conversation itself is 404 or left out. It is a read of two profile rows plus, only when something is shared, the peer's privacy row and relationship; it goes nowhere near the profile view, so it records no visit and touches no visitor counter. No migration. Example: `"sharedInterests": ["Music", "Gaming"]`.

**Presence on conversations.** The same payloads carry the peer's presence on `peer`, under the rule in [Presence](#presence): `"peer": {"userId":"…","username":"niko","displayName":"Niko","avatarUrl":null,"online":true}` while the peer is online, `"peer": {…, "lastSeenAt":"2026-10-13T14:20:00Z"}` when they are away and visible to you, and neither key otherwise. It is computed for the whole page in one batch (the peer's audience is read with the conversation row), records no visit and does not touch typing or any other realtime behaviour.

Abuse protection stays. The existing limits still apply to strangers: a general per-account limit on opening conversations and claiming keys (burst 20, one more every 2 seconds) and the per-account message-send limit. New: **opening a conversation with someone you have never exchanged a message with** (no message in either direction) has its own budget, a burst of 10 and then one a minute per account, `429 RATE_LIMITED` with `Retry-After: 60`. Reopening a conversation that has held messages is not limited. Attempts that are refused (a block, the other band) use the budget like any other. One-time key claims are capped in the database across nodes (`key_claims`, migration `0020`): one claimer may take at most 10 keys of one device per rolling hour (`429 KEY_CLAIMS_LIMITED`, `Retry-After` the seconds until the oldest of those claims is an hour old), and a device hands out at most 100 one-time keys an hour to everyone together, after which claimers get its fallback key, so nobody can drain a member's one-time keys and nobody can stop others from starting a chat with a popular member. Claim records are purged after a day.

**Daily limit on starting conversations.** A one-tap greeting makes mass greeting easy, so each member may also **start** only so many conversations per rolling 24 hours: `Entitlements.NewConversationsPerDay`, 40 on Free (see [plans and entitlements](../architecture/11-plans-and-entitlements.md)). It is enforced in `Store.OpenConversation`, in the transaction that creates the row, so no request path can skip it. A conversation counts for the member who created it (`conversations.created_by`, the first opener) by `created_at`, over `now() - 24 hours`; closing one (a block does) never refunds, and a conversation row is not deleted by any request. Only a pair with **no row yet** is a start: reopening an active conversation, reactivating a closed one (it keeps its creator and date) and opening one the other person started never count, and the same pair opened in parallel is one start. The checks run in this order, so a refusal never reveals or spends the quota: a blocked, other-band or unavailable target (404, as before), the target's `messagesFrom` (403 `MESSAGES_NOT_ALLOWED`), then the limit. The count and the insert share one transaction behind the member's advisory lock (`lockQuota("chat", member)`, the same pattern as posts and stories) and the pair lock, so parallel opens cannot pass it. The count reads only the member's own conversations through the `user_low_id` and `user_high_id` indexes; no migration. Past the limit the answer is `429` with code `QUOTA` and a `Retry-After` of the seconds until enough of the member's oldest starts leave the window (the same computation as the post and blob quotas):

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 3412

{"success":false,"error":{"code":"QUOTA","message":"You’ve reached today’s limit for starting new chats. Try again later."},"meta":{"requestId":"…","serverTime":"…"}}
```

This sits behind the per-account `RATE_LIMITED` budgets above, which still apply first. Sending a message into an existing conversation is not limited by it.

### Follows

A follow takes effect at once (`active`, activity `follow.started`). A member whose `followPolicy` is `approval` still gets requests to approve (`pending`, `follow.requested`), and `nobody` still refuses with `403 FOLLOW_NOT_ALLOWED`; nothing in the app sets those. Following has no effect on messaging.

### Counts

`socialStats` on `GET /v1/me/profile` and `GET /v1/users/{id}/profile` is now `{friends, following, followers, visitors, stories}`, all integers:

```json
"socialStats": {"friends":3,"following":12,"followers":40,"visitors":128,"stories":2}
```

- **`visitors`** is the number of different members who have opened the profile, all time, once each however often they return, and **never who**: no endpoint or field lists them, and the table (`profile_visits(profile_id, visitor_id, first_visited_at)`) is read by nothing but the writer. A visit is recorded when another member successfully opens `GET /v1/users/{id}/profile`, a locked card included. It is not recorded for one's own profile or when the request is refused (blocked, the other age band, inactive, not onboarded, unknown id). The count includes the visit that produced the response. The counter (`profile_visit_counts`, 8 slots like post counters) is incremented only when a new pair is inserted, in the same statement, so it never exceeds the number of rows even under concurrent views; a repeat visit only reads (no row is written and no counter touched), so a hot profile's repeat views never queue behind each other. Deleting a member removes their visit rows but not the all-time count.
- **`stories`** is how many unexpired stories the viewer may see on that profile (the same audience, expiry, block and age-band rules as opening a story); on your own profile, all your active stories. 0 when none.
- **Who sees them.** The counts have their own audience, `fieldAudiences.counts` (default `everyone`, added to every existing privacy row by `0019`), so any member who can open the profile sees them, and the owner always does. The connection *lists* keep `fieldAudiences.connections` (`followers` for adults, `friends` for minors; the friends list stays friends-only, see [social and activity](13-social-and-activity.md)). The locked card shows no counts. Members cannot change this in the app.

Stored visits are personal data about who looked at whom, kept indefinitely and never shown; a retention rule has not been decided.

## Age bands

Hiyall is for everyone from 13 up and minors and adults share the platform, so (owner decision, 2026-10-10) they are kept apart and minors get stricter protections. This reverses the earlier rule that the birth date is never stored. **The age is self-declared and can be falsified; nothing here is age assurance.**

### The data

`member_ages(user_id, birth_date, created_at)` (migration `0017`) holds the birth date declared at onboarding. It is private: no endpoint returns the birth date or a band, and it appears in no profile JSON, search or Nearby item, outbox payload or log line. The only derived value that is shown is the age in whole years on another member's profile (see [age on the profile](#age-on-the-profile)). The first stored value is final (`INSERT ... ON CONFLICT DO NOTHING`), so a second date cannot move a member between bands; a repeat completion with another valid date is accepted and ignored, and an under-13 date is still refused and stores nothing. A member with no row, which includes every account from before `0017`, has an unknown age and counts as an adult. SQL functions give the single definition: `member_age(uuid)` is whole years today in UTC (NULL when unknown), `age_band(uuid)` is `'minor'` below `domain.AdultAge` (18) and otherwise `'adult'`, and `interaction_barred(a, b)` is below. A test compares the SQL with the Go calculation across every day of 100 years including leap days.

### The barrier

`interaction_barred(a, b)` is true for a block in either direction **or**, while isolation is on, when `age_band(a) <> age_band(b)`. Every place that checked blocks between two members now calls it, so a cross-band attempt behaves exactly like a block: the same 404 or "unavailable" answers, no new error code, nothing that reveals age. Existing cross-band relationships (friends, follows, conversations, memberships, notifications) become unreachable the same way; **nothing is deleted** and they come back when both members are in the same band again, for instance when a minor turns 18 and the other already is. List queries (people search, Nearby, feeds, comments, story viewers, visitors, connections, friend requests, notifications, spaces) use `notBarred(viewer, other)` in `store/barred.go` instead of calling the function per row (audit D9): the blocks are one hashed `NOT IN` subplan built once, the viewer's band and the isolation switch are evaluated once, and only the other member's band is looked up per row. `TestNotBarredMatchesInteractionBarred` checks every pair of bands and blocks, isolation on and off, against `interaction_barred`, which stays for single-row checks and for chat.

Configuration: `AGE_BAND_ISOLATION` (default `true`; only `true` or `false` are accepted, anything else is a startup error). `false` restores block-only behaviour and the API logs a warning at startup; the minor defaults, the coarser minor location and the minor distance buckets still apply, because they protect the member's own data. The API sets `hiyall.age_band_isolation` on every connection of its pool (`store.WithAgeBandIsolation`, `Store.AgeBandIsolation`) and the SQL function reads it; a connection that never set it treats isolation as on.

Paths that use the barrier:

- **Discovery:** people search, Nearby, and the age and gender filters in both.
- **Profiles and people:** `GET /v1/users/{id}/profile`, another member's followers, following and friends lists, and your own connection lists (a barred member is left out).
- **Graph:** follow and approving a follow request, sending and accepting a friend request, the friend-request lists and responding to or cancelling a request, and notifications and the unread count.
- **Chat:** opening a conversation, listing a peer's devices and claiming keys, reading and listing conversations, relaying a message, the inbox (ciphertext from a barred sender is not delivered), the unread totals, and read-receipt and typing signals.
- **Content:** the everyone feed and the following feed (the circle), a member's posts, a single post, reactions, comments (reading and writing, and comments by barred authors are hidden), saving and the saved list, stories (the tray, viewing and an author's list of viewers), and reports of posts, comments and stories.
- **Spaces:** which spaces are visible (host and parent community), joining and membership changes, approvals and invitations, entries, participant lists, and reports of space entries.

Safety controls and reports follow the barrier without revealing anyone: muting or restricting a member in the other band (or not onboarded) is 404 like their profile, the muted and restricted lists leave such members out, and a report against them is accepted but names nobody (see [safety controls](14-safety-controls.md)). Not changed on purpose: the blocked list (it shows every real block, so each can be undone), and the friend and follower counts on a profile, which are per profile and not per viewer, so they still count relationships that are now unreachable. Presence and the realtime socket carry only events for conversations that pass the checks above.

Cost: the barrier is evaluated once per candidate (two lookups of birth dates and one of blocks). In a scratch measurement on the test database with 100,000 synthetic accounts, a Nearby page took about 15 ms at radius 25 and about 230 ms at radius 100 when 16,000 members were inside the box; people search took a few milliseconds. People search scans in id order and stops after 21 matches, so a viewer whose band is very rare in a large population does more work per page, and a filter nobody can match scans the whole table (an age filter that the viewer's band makes impossible is answered without a query). If either matters, denormalize the band into an indexed column. This is one synthetic run, not a benchmark.

### Stricter defaults for minors

Applied once, in the transaction that completes onboarding, when the stored date makes the member under 18. Messaging is open for minors too (`messagesFrom` "everyone", within their band only): there is no minor-specific messaging default. All of these are named constants in `domain/agebands.go`:

| What | Minor | Adult |
|---|---|---|
| `onlineAudience` | `nobody` | `everyone` |
| Country (`fieldAudiences.location`) | `friends` | `everyone` |
| Stored location precision | 1 decimal (about 11 km), chosen by the band at write time | 2 decimals (about 1.1 km) |
| Nearby distance buckets (viewer is a minor, so everyone listed is a minor) | 10, 25, 50, 100 | 5, 10, 15, 25, 50, 100 |

A member keeps the right to change their own settings afterwards, and a repeated completion does not reapply the defaults. The band is read when a location is written: a member who turns 18 stores finer points from their next write, and nothing already stored is rewritten.

### Gender and the age and gender filters

`gender` is a new optional profile field: `woman`, `man`, `nonbinary` or empty (unset or prefer not to say); anything else is `422 VALIDATION`. It has its own field audience (`fieldAudiences.gender`, default `everyone`, added to every existing privacy row by `0017`), and `GET /v1/users/{id}/profile` includes it when that audience allows it. It is never part of a search or Nearby item, and neither is age.

`POST /v1/discovery/search` and `POST /v1/discover/nearby` accept three more filters, parsed by the same code and applied by the same SQL:

- `ageMin`, `ageMax`: plain JSON integers from 13 to 99, either may be omitted, `ageMin` not above `ageMax`; `null`, strings, fractions and exponents are `422 VALIDATION`. A member matches when their stored age is in the inclusive range **and their `fieldAudiences.age` is `everyone`**, like every other filter and its field audience, so an age the member hid cannot be read off by narrowing the range; **a member with an unknown age never matches an age filter**. Hiding the age does not hide the member, who is still listed without an age filter.
- `gender`: `man`, `woman`, `nonbinary`, or empty for any. A member matches only when their gender audience is `everyone` and the value equals; a hidden gender never matches, and an unset one never matches a gender filter.

They combine with the other filters (AND across dimensions) and are part of the cursor hash, so changing one invalidates the cursor (`422 INVALID_CURSOR`). The barrier still applies: a minor filtering for 25 to 34 finds nobody.

### Age on the profile

`GET /v1/users/{id}/profile` includes an integer `age` (whole years, from `member_age`, the same calculation the age filter uses) **when all of these hold**: the member's age is known; the member's `fieldAudiences.age` allows the viewer (same audience logic as every other field; default `everyone`, added to existing privacy rows by migration `0018` and to new accounts by `DefaultPrivacy`); the profile is not the locked card; and the viewer is not the member themself. Otherwise the key is omitted, never `null` or `0`. The birth date and the band are never returned, `GET /v1/me/profile` has no age, and search and Nearby items have none. The barrier still applies first: a member in the other age band is a 404, so only members of the same band, who are allowed to open the profile, see the age.

**Plain consequence:** with the default audience and no privacy screens in the app, **every member's age in whole years is visible to every same-band member who can open their profile, and members cannot hide it in the app.** For a minor that includes other minors, in their own band only. The audience can be changed through `PATCH /v1/me/privacy` (`fieldAudiences.age`), but no app screen offers it; for now the only protections are the barrier and the profile audience itself. Members who joined before birth dates were kept have no age and show none.

### Residual risks

- **The date is typed by the member.** Anyone can declare 17 to be seen by minors, or 18 to be seen by adults, and a minor who does so gets adult defaults and adult visibility. The barrier is only as strong as the declaration.
- **Ages are readable to the year.** Search and Nearby results carry no age, but the profile now shows it to the year by default (see above), and anyone can also narrow the age filter (for example `ageMin` = `ageMax` = 15) and learn the age of a member inside their own band who shows it to everyone (the default); a member whose `fieldAudiences.age` is anything else is never matched by an age filter. A client that wants coarser filtering has to enforce it; the API accepts any integers.
- **With isolation off nothing separates the bands** (the minor defaults and coarse location remain).
- **Existing relationships and counts.** Cross-band relationships stay in the database and still count in friend and follower totals.
- **Minors are still locatable** to about 11 km by other minors who share a location, and a spoofing minor can still trilaterate to that grid (see the Nearby risks).
- **Per-row cost.** See above.

## Presence

The member's only control is the existing `onlineAudience` field: the app sends `PATCH /v1/me/privacy {"onlineAudience":"everyone"}` or `"nobody"` (one switch, "Show when I'm online and last seen"). Last seen has no control of its own: `lastSeenAudience` is stored but not used, and the last-seen time follows `onlineAudience`. Minors start at `nobody`.

**Definition** (`domain.ResolvePresence`, one helper for every payload). A member is *online* when they hold a live realtime connection on this node, or their latest session activity is within `domain.PresenceOnlineWindow` = **2 minutes**. Session activity is `max(sessions.last_seen_at)` over their sessions that are not revoked and not expired. A live connection makes the member online whatever their sessions say. Otherwise, if they have any usable session, they were *last seen* at that activity **rounded down to `domain.PresenceLastSeenBucket` = 5 minutes** (UTC, aligned to the hour), so no exact moment of activity ever leaves the server. A member with no usable session and no connection has no presence data. The two numbers are presence semantics, not plan limits, and are the same for everyone.

`sessions.last_seen_at` is refreshed on authenticated requests at most once a minute for development sessions (`VerifyDevSession`) and on every verified token for identity-provider sessions (`ResolveOIDC`), which is why the window is 2 minutes. Any authenticated request therefore keeps a member online, including from the web app, which has no realtime socket.

**Where it appears.** People-search items, Nearby items, the visible `GET /v1/users/{id}/profile` projection, and the `peer` object of every conversation payload (`POST /v1/conversations`, `GET /v1/conversations`, `GET /v1/conversations/{id}`). Two optional keys, never `false` or `null`:

- `online: true`, only while the member is online;
- `lastSeenAt`, an RFC 3339 UTC string in 5-minute steps, only when the member is *not* online and has been active.

**Who can see it** is decided on the server by the member's `onlineAudience`, with the same `Relationship.Allows` rule as every other audience:

| `onlineAudience` | stranger | active follower | friend | the member |
|---|---|---|---|---|
| `everyone` (default for adults) | yes | yes | yes | yes |
| `followers` | no | yes | yes | yes |
| `friends` | no | no | yes | yes |
| `nobody` (default for minors) | no | no | no | yes |

When the audience does not admit the viewer both keys are simply omitted, so hidden is indistinguishable from offline (and from never seen); status codes and response shapes do not differ. A locked profile card never carries presence. Presence is never shown across a block or an age band: such a member is missing (404 or left out of the list) before presence is considered, and the conversation payloads only ever contain peers of conversations the caller can open. Reading presence records no profile visit.

**Cost.** One page of people or conversations is resolved with at most two statements however long the page is: one for the relationships of members whose audience is `friends` or `followers` (skipped when all are `everyone`), and one `GROUP BY` over `sessions` for the admitted members who are not connected right now (skipped when all are). The in-process hub is asked once per admitted member and never for hidden ones. No migration: `sessions(user_id, ...)` is already indexed.

**Multiple nodes.** The hub half (`Hub.Connected`) is per API node. A member connected to another node still shows as online while their requests keep their session active (within 2 minutes of the last one); an idle socket on another node can lag by up to the window. A shared presence bus is still the way to make that exact.

### The Online filter and interest context on rows

Added for the Discover redesign (no migration). Both people search (`POST /v1/discovery/search`) and Nearby (`POST /v1/discover/nearby`) take and return the same new things, because they share `peopleFilterSQL` and `discoveryItem`.

**`online: true` filter.** `{"online":true}` keeps only members who (1) have an `onlineAudience` that admits the viewer, with exactly the rule of the per-row flag (`everyone`; `friends` an accepted friend; `followers` an accepted friend or an active follower; `nobody` and anything unknown never) and (2) have a usable session (not revoked, not expired) with `last_seen_at` within `domain.PresenceOnlineWindow` (2 minutes). It is a real server-side filter (`onlineFilterSQL` in `store/discovery.go`): the audience is checked with two correlated `EXISTS` over `friendships` and `follows`, activity with one `EXISTS` over `sessions`, per candidate, and cursor pagination, ordering and the `search` limiter are unchanged. `online:false` is the same as omitting it; anything that is not a JSON boolean is `422 VALIDATION`. The flag is part of the filter hash the cursor is bound to, so adding, dropping or flipping it invalidates a cursor (`422 INVALID_CURSOR`). It combines with every other filter by AND.

Difference from the per-row flag: the row flag also counts a live realtime connection (the hub is per node, in memory, and cannot be asked in SQL), the filter does not. A member who is connected but has had no session activity for more than 2 minutes is therefore not matched by the filter although their row would say `online: true` elsewhere. The filter is a precise subset of "online now", never a superset: every row it returns carries `online: true`. Blocked, age-barred (minors never see adults and vice versa), undiscoverable, non-public and suspended members are excluded exactly as without the filter, minors default to `onlineAudience: nobody` and so are not matched until they choose to show presence, and a hidden audience simply never matches, like an offline member, so the filter reveals nothing the flag would not.

**`interests` and `sharedInterests` on rows.** `interests` was already returned (the member's own list, in their own spelling) when their `fieldAudiences.interests` is `everyone`; it is unchanged and clients take the first three to show. New: `sharedInterests`, an array of at most 3 strings, the case-insensitive intersection of the member's interests and the viewer's own, **spelled and ordered as the viewer typed them** (`domain.SharedInterests`, the helper conversations use). It is present (possibly `[]`) exactly when `interests` is present, so it follows the same audience check and nothing can be inferred about a hidden list. The viewer's own interests are read once per page (one single-row query), and the candidates' interests are already on the rows, so there is no per-person query. Example row: `{"userId":"…","displayName":"Mira","interests":["music","Photography","Art","Hiking"],"sharedInterests":["Music","Art"],"online":true}`.

Tests: `internal/httpapi/online_filter_test.go` (audience matrix across stranger, follower and friend viewers in search and Nearby, 2 minute window edges, revoked and expired sessions, hub-only limitation, blocks, discoverability, suspension, minor defaults and age bands, 27-member pagination and cursor binding, combinations with other filters, interest context and its audiences) and `internal/domain/discovery_online_test.go`.

## Nearby

A member is listed only while **Show me in Nearby** is on (`nearby_prefs.visible`, `PUT`/`DELETE /v1/me/nearby`, off by default for everyone, migration `0034_teen_safety.sql`), and only visible members can search (`409 NEARBY_OFF` otherwise), so nobody can watch without being watched. `PUT /v1/me/location` is refused with `409 NEARBY_OFF` while it is off, and `DELETE /v1/me/nearby` deletes the stored point in the same transaction. See [teen safety and abuse limits](../architecture/18-teen-safety.md) for the hardening that follows (radius buckets, daily offset, change and query caps, speed check).

### Endpoints

All require a completed onboarding (`403 ONBOARDING_REQUIRED` before it; they are not in the allow-list).

`PUT /v1/me/location`

```json
{"latitude":12.971634,"longitude":77.594566}
```

The body is exactly those two keys, finite JSON numbers in range (latitude -90 to 90, longitude -180 to 180) with `Content-Type: application/json`. Anything else, including extra or missing keys, strings, `null`, out-of-range values and duplicate keys, is `422 VALIDATION`; the message never repeats the input. Success is `200`:

```json
{"success":true,"data":{"sharing":true,"updatedAt":"2026-10-10T08:30:00.123456Z"},"meta":{...}}
```

The server **rounds both coordinates to 2 decimal places (about 1.1 km) before it stores anything**; the precise values are not written to the database, the outbox, logs or any response. Each account may change its point in a burst of 3, then once every 2 minutes: `429 RATE_LIMITED` with `Retry-After: 120`. Only requests that pass validation use a token.

`GET /v1/me/location` -> `200 {"sharing":true|false,"updatedAt":"<RFC 3339>"|null}`. `sharing` is false when no point is stored or the stored point is older than 24 hours; `updatedAt` is null unless sharing. Coordinates are never returned.

`DELETE /v1/me/location` -> `200 {"sharing":false}`. Idempotent. The member disappears from everyone's Nearby results immediately.

`POST /v1/discover/nearby`

The body is a JSON object with `Content-Type: application/json`; **every key is optional**. `GET /v1/discover/nearby` is no longer served (it answers 404).

```json
{"radiusKm":25,"country":"IN","interests":["music","art"],"languages":["en"],"vibe":"chill","cursor":"<opaque>"}
```

```json
{"success":true,"data":{"items":[
  {"userId":"…","username":"niko","displayName":"Niko","headline":"…","bio":"…","distanceKm":5,
   "interests":["Music"],"sharedInterests":["Music"],"languages":[{"code":"en"}],"currentVibe":"Chill","country":"IN","online":true}
 ],"nextCursor":null},"meta":{...}}
```

- `radiusKm`: a plain JSON integer that is one of the buckets 5, 10, 15, 25, 50, 100, default 25. Any other number, a string, a fraction (`5.5`, `5.0`), an exponent or `null` is `422 VALIDATION`. A viewer who is a minor is searched at the smallest of 10, 25, 50, 100 that covers the radius.
- `interests`, `languages`, `country`, `vibe`, `ageMin`, `ageMax`, `gender`, `online` and `cursor` are parsed and validated by the same code as `POST /v1/discovery/search` (`domain.ParsePeopleFilters`): at most 10 distinct interests and 10 distinct language tags, an uppercase two-letter country, a vibe of at most 80 characters, `ageMin`/`ageMax` plain JSON integers from 13 to 99 with `ageMin` not above `ageMax`, `gender` one of `woman`, `man`, `nonbinary` or empty (any), a cursor of at most 2048 characters, `null` and the wrong type refused. **Unknown keys are `422 VALIDATION`**, which includes any position: the server only ever uses the caller's stored point.
- Filter semantics are identical to people search, and the SQL predicates are shared: any value within `interests` or `languages` may match (OR), different dimensions combine (AND), comparisons ignore case, and a filter matches a member **only when that member's field audience for it is `everyone`** (`location` for country, `vibe`, `interests`, `languages`, `gender`, and `age` for `ageMin`/`ageMax`). A hidden field can therefore not be inferred by filtering, and a member who hides their languages is simply not matched by a language filter (they are still listed without it).
- Reads share the per-account `search` limiter (burst 10, one more every 2 seconds): `429 RATE_LIMITED` with `Retry-After: 2`. A caller with no stored point, or one older than 24 hours, gets `409 LOCATION_NOT_SHARED` ("Share your location to see people nearby.").
- Errors in one place: `403 ONBOARDING_REQUIRED`, `409 LOCATION_NOT_SHARED`, `422 VALIDATION` (radius, filters, unknown key, body not a JSON object), `422 INVALID_CURSOR`, `429 RATE_LIMITED`. The checks run in that order of cost: limiter, body, caller's location, cursor.

### Who is listed

People whose stored point is fresh (updated within 24 hours) and lies within `radiusKm` of the **caller's** fresh stored point (great-circle, spherical Earth of radius 6371 km, between the two rounded points), who are active, have completed onboarding, are `discoverable` and `public` (the same rules as people search), are not the caller, are not blocked in either direction, are in the caller's age band (while isolation is on) and match the filters, if any were sent.

`interests`, `languages`, `currentVibe` and `country` appear only when that member's field audience (`interests`, `languages`, `vibe`, `location`) is `everyone`, exactly as in people search; `online` and `lastSeenAt` follow the presence rule. Nothing else is returned: no coordinates, grid cells or exact distances.

`distanceKm` is a **bucket**: the smallest value in `[5, 10, 15, 25, 50, 100]` that is at least the distance between the two stored points. A viewer who is a minor sees the coarser set `[10, 25, 50, 100]`. Because the radii are the buckets, a person is inside a radius exactly when their bucket is at most the radius, so a search never reveals anything finer than a bucket.

### Order and paging

Items are ordered by `distanceKm` ascending and then by `userId` ascending, 20 per page, at most 10 pages (200 people). **Deviation from the brief:** ties inside a bucket are broken by user id, not by the exact distance. Ordering by exact distance would let a client read the relative order of people inside one bucket, and the keyset cursor would have to carry an exact distance, which is finer than anything the API is meant to reveal. The order a client sees is therefore always consistent with the `distanceKm` it is shown.

`nextCursor` is signed (HMAC with the API's cursor key), opaque, expires after 15 minutes and is bound to the principal, the radius, a hash of the filters and a keyed hash of the caller's stored point. It carries the last bucket and user id and nothing positional. Send it back in the body with the same `radiusKm` and the same filters (key order and an explicit default such as `"vibe":""` do not matter; the hash is taken from the parsed filters, as in people search). Changing the radius or any filter, a bad, truncated, tampered, foreign, expired or mismatched cursor, one from before the caller moved, or one beyond page 10 is `422 INVALID_CURSOR` ("Reload people nearby"). A cursor over 2048 characters is refused as `422 VALIDATION` before it is read, as in people search. Sharing the same point again keeps cursors valid; sharing a different one invalidates them.

### Query shape

The query first finds the rows inside a latitude/longitude bounding box through a GiST index on `point(longitude, latitude)` (`user_locations_point_gist`, migration `0038`; built-in geometric types, no extension; the condition is `point <@ box(...)`, and a box across the antimeridian is two boxes). The index hands the candidates out nearest first (`point <-> centre`, planar degrees) and the query keeps at most `NearbyCandidateCap` (5000) of them, so in a very dense area the farthest points are dropped, never the nearest. It then computes the haversine distance and bucket for those rows only (a materialized step so PostgreSQL cannot reorder it), then joins the account, onboarding, profile and privacy rows by key, applies the eligibility, block, keyset and filter predicates and returns 21 rows. The box handles the antimeridian (two longitude ranges) and falls back to a latitude-only filter when the circle reaches a pole; it is only a prefilter and a test checks it never drops a point the exact distance would keep. Tests compare the API with a brute-force reference on 300 members around the antimeridian and both poles, unfiltered and with three filter sets (including members who hide fields), and check that Nearby and people search return the same people for the same filters. The filtered query was not timed separately from the unfiltered one below.

Measured once on a scratch copy of the test database before the age barrier existed (a rolled-back transaction, 100,000 synthetic accounts with either all or a fifth of them sharing, no concurrent load): 1 to 130 ms per page depending on how many members fall inside the radius, with the box scan on the old `(latitude, longitude)` B-tree (replaced by the GiST index in `0038`; `TestNearbyUsesGistIndexAndHashedBlocks` shows the plan: a bitmap scan of `user_locations_point_gist`, no sequential scan). The barrier (blocks and age bands) is now evaluated inside the same materialized step, once per member inside the radius, and the settings are read through a fenced lateral lookup by key; current numbers are in the cost paragraph under [age bands](#age-bands). This is a sanity check, not a benchmark. The cost grows with the number of members inside the radius, because every page re-evaluates them; a dense city at radius 100 is the worst case. If that matters, move to a cell-based or GiST/PostGIS index before the member count grows.

## Privacy by design

- **No point until the client sends one.** Nothing is stored until a location arrives, and a caller who is not sharing cannot see Nearby (409). With the current app that is the OS permission, not an in-app choice: see [client behaviour](#client-behaviour).
- **Coarse.** Coordinates are rounded to a ~1.1 km grid on the server before storage (~11 km for minors). A test scans every table and the captured log output for the precise values.
- **Buckets only.** Others see a distance bucket. Order and cursors contain nothing finer.
- **Expiring.** A point counts as shared for 24 hours; the hourly maintenance job in `cmd/api` deletes points not refreshed for 7 days (`PurgeLocations`, batches of 5000, with a test for the store method). If the job is not running the API still ignores points older than 24 hours.
- **Stoppable.** `DELETE /v1/me/location` removes it at once and is idempotent.
- **No events.** Location changes write no outbox event and appear in no response other than the member's own `sharing` and `updatedAt`.
- **Same visibility rules as search.** Members who are not discoverable or not public, blocked pairs in either direction, suspended accounts and members who have not finished onboarding are never listed.
- **Throttled.** Moving the shared point is limited per account, and reads share the search limit.

### Residual risks

- **Trilateration by a member who spoofs locations.** `PUT /v1/me/location` takes the client's word. A member can place their own point and read Nearby from each, but the radius is only the bucket list (nothing under 5 km), each member's stored point carries a secret daily offset, a member can change cell at most 5 times a day and not faster than 1000 km/h, and Nearby is capped at 200 queries a day, so the sweep that located a target to about 1 km no longer resolves below the 5 km bucket (see [18 teen safety](../architecture/18-teen-safety.md)). The mitigations above (rounding, buckets, one move per 2 minutes after a burst of 3, one search per 2 seconds, 24 hour expiry, opt-in, blocks, discoverable and public only) slow this down; they do not prevent it. Many accounts multiply the budget because per-account limits do not stop an attacker who creates accounts; the per-client-address request limit is the only guard that spans accounts.
- **Filters make singling out easier.** Combined with spoofed positions, country, interest, language and vibe filters let a member narrow a small area to people with a rare combination, so a profile that is public and discoverable can be found by where it is and what it shows. Filters only match fields a member already shows to everyone, so they reveal no hidden attribute, but they raise the precision of a search.
- **Stored points are personal data.** They are coarse but still say roughly where someone was, they sit in the database and its backups for up to 7 days, and they are visible to anyone with database access.
- **A shared point goes stale silently.** For up to 24 hours after the member moves away the previous point is still used until they stop sharing or re-share.
- **Deactivated members** drop out of results at once (the account must be active) but their row lasts until the 7 day purge.
- **The realtime half of presence is per node**; session activity covers the rest within two minutes (see Presence).

## Client behaviour

As reported by the app team (the app code was not read or tested as part of this change): the app reads the device position automatically when it opens or returns to the foreground, at most about once every 5 minutes, and sends it with `PUT /v1/me/location`. It shows no on/off control for sharing and calls `DELETE /v1/me/location` on sign-out. Members choose only whether to grant the operating system's location permission; if they refuse it, nothing is sent and Nearby answers 409. [Nearby and online status (app)](../mobile/15-nearby-and-presence.md) describes an earlier explicit "Share my location" flow and has not been updated for this.

The server is unchanged by that: it rounds (to the member's band precision), expires (24 hours), rate-limits (burst 3, then one change per 2 minutes) and purges (7 days) exactly as before. A throttle of one write per 5 minutes sits well inside the limit.

## Operations

- Migrations `0016` to `0019` must be applied before the new API version starts; `scripts/dev-api.sh` runs migrations first. `AGE_BAND_ISOLATION=false` turns the age barrier off and is refused when `APP_ENV=production`; it exists for development only.
- `maintain` in `cmd/api/main.go` runs the location purge with the other hourly jobs.
- Tests run against `hiyall_test`: `go test -race ./...` from `services/api` with `TEST_DATABASE_URL` set. The Nearby and location tests are in `internal/httpapi/nearby_test.go` and `nearby_filters_test.go`; the defaults, eligibility and migration tests are in `open_access_test.go`; the age band tests are `age_bands_test.go` (barrier, SQL functions, existing relationships), `age_onboarding_test.go` (stored once, minor defaults, nothing leaks, fixtures), `minor_nearby_test.go` (location precision and buckets) and `age_gender_filters_test.go` (gender and the age and gender filters).
- Local data: `./scripts/seed-demo-people.sh` then `./scripts/seed-demo-nearby.sh [LAT LON]` (default 12.9716 77.5946) place Anjali, Niko, Kai and the `demo_` people between about 0.5 and 40 km from the centre (minors on the 1-decimal grid). `demo-people.sql` gives the demo people a gender and an adult age (18 to 40) and adds two demo minors, `demo_minor_mika` (15) and `demo_minor_noor` (16); Kai is the minor development account (`/dev/session`, id `019a4000-0000-7000-8000-0000000000a2`). Both scripts refuse any database other than the local `hiyall`.

## Safety note for the owner

Minors (13 to 17) and adults share the platform. With `AGE_BAND_ISOLATION` on, they cannot see or reach each other, which is the main protection, and minors also get stricter defaults. What it rests on, and what is still not done, in plain terms:

- **Everything depends on a typed date.** There is no age assurance. A minor can declare 18 and be treated as an adult, and an adult can declare 14 and be seen by minors. Nothing detects either.
- **No in-app opt-out for location.** The app sends the position automatically and offers no on/off control, so every member who grants the operating system permission becomes locatable by anyone nearby in their own band who is also sharing, for as long as the app keeps refreshing it and 24 hours after the last update, to about 1.1 km for adults and about 11 km for minors; the only ways to stop are revoking the OS permission or signing out.
- **Open messaging raises contact risk, minors included.** Anyone in a member's age band who is not blocked can start a conversation with them, with no friendship, no request and no consent step, and follows are instant. For minors that means any other minor, including one they have never met who found them in Discover or Nearby, can message them directly; the only controls are blocking, reporting and a new-conversation limiter (burst 10, then one a minute). Minors' `bio`, `headline`, interests and languages are shown in Discover and Nearby to their own band, and their age to the year on their profile.
- **Age is visible.** Every member's age in whole years is shown on their profile to same-band members who can open it, by default and with no way to hide it in the app (see [age on the profile](#age-on-the-profile)). For minors that means other minors, with a falsifiable declared age.
- **With isolation turned off** none of the separation exists.

Status of the recommendations from the first version of this note:

1. **Age-banded discovery and Nearby.** Implemented (the barrier), on every path listed above, subject to the declaration caveat.
2. **Stricter defaults for under-18s.** Implemented in part: presence hidden, country and the followers/following lists friends-only, location rounded to about 11 km and coarser Nearby buckets. Not implemented: not discoverable by default, hiding `bio` and `headline` in Nearby, Nearby off by default. Since the open-messaging decision, `messagesFrom` and `requestsFrom` are `everyone` for minors too, so that earlier recommendation (`messagesFrom` narrower for under-18s) is deliberately not followed.

Still **not done**, and recommended:

3. **Report and moderation staffing and response times.** A queue is not a service: someone has to read reports (including the `underage` reason, which nothing acts on automatically), act and escalate, with response-time targets, and a way to handle a member found to be under 13.
4. **COPPA and GDPR-K legal review.** How a self-declared 13 floor interacts with COPPA, the GDPR's rules for children and the age of digital consent, and now with storing the birth date of minors.
5. **Parental consent for under-16s in the EU.** The age at which a child can consent varies by member state (13 to 16); some will need verifiable parental consent, including for location.
6. **Age assurance beyond self-declaration** where the markets or the law require it, and server-side detection of spoofed locations before Nearby is offered to minors.
7. **Content-level restrictions for minors**, for example what may be shared in posts, stories, spaces and messages and what links or media a minor can receive; nothing here restricts content by age.
8. **Narrower contact defaults for minors** and a decision on whether minors should be discoverable at all by default.
9. **Message requests and inbox filtering for under-18s**, so a first message from someone they have not exchanged messages with lands in a requests folder they accept or ignore instead of straight into their chats.
10. **Stranger-message limits** beyond the new-conversation limiter (per recipient, per day, and tighter for minors), and detection of one account contacting many strangers.
11. **Link and media restrictions** in first messages and from strangers, and **safety nudges** (a prompt on the first message from a stranger, reminders about blocking and reporting) in the app.
12. **Moderation staffing** is listed above as item 3 and matters more now that contact is open.

## Not verified

- No run from the Flutter app, a real device or the real identity provider (the client behaviour above is as reported); no multi-node presence; no real-user load. The query timing above is one synthetic measurement.
- Migrations `0016`, `0017`, `0018` and `0019` were applied to `hiyall_test`; none was applied to the development database `hiyall` by these changes (the owner applies them by starting the API).
- The age-band barrier is covered by one test that exercises about 30 paths for each pair of members in the same and different bands, and by tests for the existing-relationship case, a reference comparison for Nearby and specific tests for each remaining path; a path that is added later without `interaction_barred` is not caught automatically.
- Query cost was measured once on synthetic data (see above); no load test.
- The seed scripts were run against copies pointed at `hiyall_test` (the real scripts refuse any other database); `scripts/seed-demo-nearby.sh` was not run end to end against `hiyall`.
- Open messaging, the new-conversation limiter and the visit counter are covered by API tests only (including concurrent first visits); no load test, nothing from the app, and no review of how much unwanted contact open messaging produces.
- No legal, child-safety or privacy review has been done.
