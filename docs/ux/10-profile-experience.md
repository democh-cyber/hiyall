# Profile experience and data boundaries

The profile now has a compact personal identity hero and an original generated
orbital monogram,
headline/bio and separately editable quote, real social counts, integrated Current
Vibe, compact About rows and interest/language sections, a sticky avatar/name
header while scrolling, and Posts/Media/Vibes navigation with a tiny active marker.
Owner settings are accessed only through the settings sheet. The shared visitor
view has
no editor, owner settings, sessions, or account details.

## Implemented data contract

- Existing profile endpoints are retained: `/v1/me/profile` and
  `/v1/users/{userId}/profile`. The latter is a server allowlist after whole-profile
  audience and bidirectional block checks. Its ID is our profile routing ID, never
  an identity-provider subject.
- Headline, optional quote (up to 160 characters), interests (up to ten), Current
  Vibe, accent (`lime`, `violet`, `cyan`),
  background (`glow`, `orbit`, `plain`), and frame (`minimal`, `orbit`) are validated
  and saved with the existing optimistic version check and transactional outbox.
- Languages use `{code, level?}` entries. Levels are explicitly selected from
  basic/conversational/fluent/native. Legacy tag-only arrays remain readable and
  accepted without guessing proficiency; subsequent serialization is structured.
  Localized display labels are derived from codes, not supplied by the user.
- Optional country, profession, pronouns, education, languages, interests,
  website, Current Vibe, and social counts use field audiences. Optional fields
  default to only me. New field privacy is backfilled conservatively for older accounts.
  Friends/follower audiences continue to fail closed until relationship
  authorization workflows are implemented.
- Country visibility reveals only country, never stored city or region.
- Age, birth details, gender, email, phone, provider IDs, coins, login timestamps,
  visitor analytics, and sessions are not part of the visitor profile projection.
  This release does not import the supplied sample people or introduce private
  account/billing fields into the profile table.
- The form saves only on an explicit Save, preserves failed drafts, and offers
  reload after a version conflict. Country and language selectors are searchable;
  proficiency, interests, vibe, and signature can be changed or removed.
- Share opens a sheet for copying the username, plus an authorized-view profile
  URL in the web preview. A copied link never changes the profile audience. Native
  universal links and a native share sheet need configured production link routing.

## Social count read foundation

Migration `0004_profile_social_counts.sql` adds the planned canonical friendship
pairs and directed follows with states and indexed active adjacency. The read-only
view derives Friends from accepted pairs and Following/Followers from active
follows, excludes inactive accounts and either-direction blocks, and returns real
zeroes for empty graphs. No production or development relationships are seeded.
The API overrides any stale JSON count payload with these derived values.

Owners receive counts; visitors receive them only when whole-profile access and
`fieldAudiences.connections=everyone` allow them. The field defaults to only me
for old and new accounts. Clients cannot patch socialStats. Counts are rendered
only if the response includes them; omission is not replaced with zero. Screen
readers receive the full count even when the visible number is abbreviated.
The displayed counts are read-only until member lists and connection workflows
are implemented. A successful block/unblock invalidates the owner profile cache
so its counts refresh alongside the affected visitor profile. This does not enable Connect or broaden friend/follower access.

## Capabilities waiting for their services

Media upload/delivery, voice introductions, stories/highlights, verification,
subscriptions, connection creation/approval and member lists, post/media feeds,
notification settings,
and mute/restrict/report workflows are not implemented services in this foundation.
Do not simulate them with random images, badges, counters, playback, or successful
social actions. The avatar uses an original static orbital composition with the
real account's initial. It is an identity decoration, not a story/verification
badge. Connect and Message
remain unavailable. Posts/Media have honest empty states; Vibes displays the saved
current vibe, with no fabricated history. Existing block/unblock still works.

Keep future private account, wallet, analytics, and identity operations separate
from the profile APIs. Media must use ownership checks and privacy-aware delivery;
do not import third-party public storage URLs as a substitute. Private age data,
if collected for eligibility, needs its own owner-only flow and server-calculated
optional age/range projection. Optional self-described gender must not be inferred
from the sample Boolean or used as an unrestricted discovery filter.

## Scope and verification

The navbar and other primary screen designs are preserved. Changes to privacy and
the editor support the profile's new fields. Existing global header actions remain.
Motion is finite, respects reduced motion, and does not loop while scrolling.

Verification covers persisted drafts and version conflict recovery, structured
languages, owner/visitor separation, blocks, restricted field audiences, private
account canaries, responsive scrolling, large text, light/dark appearance, and
regression screens. Render captures use local fixture accounts for visual review;
they are not seeded into a signed-in account.
