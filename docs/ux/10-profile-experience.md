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
  website, Current Vibe, and social counts use field audiences. Since the open-access
  decision (owner, October 2026) optional fields and the counts default to everyone and the
  followers and following lists to followers for adults and friends for minors (migration `0026`;
  before it, friends for everyone), for new accounts and, through migrations `0016`, `0019` and `0026`, for
  every existing account; the earlier conservative defaults and backfill are superseded. A field with no
  value is simply not shown.
  Friends/follower audiences continue to fail closed until relationship
  authorization workflows are implemented.
- Country visibility reveals only country, never stored city or region.
- Age, birth details, email, phone, provider IDs, coins, login timestamps,
  visitor analytics, and sessions are not part of the visitor profile projection.
  The birth date is stored privately and never returned. Age in whole years is
  projected on another member's profile when it is known, its own `age` audience
  (default everyone) allows the viewer and the profile is not the locked card; the
  owner's own profile has none. Gender is an optional
  profile field with its own audience and is in the projection only when that
  audience allows it.
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

Owners receive counts; visitors receive them when whole-profile access and the
`fieldAudiences.counts` audience allow them (default everyone, set for existing accounts by
migration `0019`). The connection lists keep `fieldAudiences.connections` (`followers` for adults, `friends` for minors). Clients cannot patch socialStats. Counts are rendered
only if the response includes them; omission is not replaced with zero. Screen
readers receive the full count even when the visible number is abbreviated.
A successful block/unblock invalidates the owner profile cache
so its counts refresh alongside the affected visitor profile. This does not enable Connect or broaden friend/follower access.

## Tappable stats

Each of Following, Followers, Visitors and Stories is a whole-cell button (`ProfileStatsRow`,
`lib/shared/profile_stats.dart`): at least 48 dp tall, with a ripple, focusable with the keyboard on the web,
and a small chevron as the affordance. Screen readers hear for example "7 followers, opens the list" (a stat that
does not open is just "7 followers"). Where a stat leads is one map, `ProfileStatActions`: a stat without an entry is
a plain number, so a new destination is one more entry (`ownStatActions` and `otherStatActions` in
`lib/features/people_lists.dart`). Every list is read through the API, which decides who may see what; the app
never relies on hiding a button. After any action the profile refreshes, so the counts follow.

| Stat | Your own profile | Another member's profile |
|---|---|---|
| Following | `/profile/following`: people you follow, newest first, paged. Tap a row to open the profile; **Message**; **Unfollow** after a confirmation (the row leaves and the stat updates). Pull to refresh, empty and error states with retry. | `/person/{id}/following`, read-only, only when the server says `canSeeConnections` on their profile. For an adult member that is true once **you follow them** (an active follow; a pending request does not count) or are their friend, and for a member under 18 only for friends; otherwise a plain number with the note "Their followers and following lists are private." A direct visit to a private list shows "Not shared". Following or unfollowing from their profile reloads it, so the cells and the note update at once. The note appears only when `canSeeConnections` is false. |
| Followers | `/profile/followers`: a **Follow requests** section on top when someone waits for approval (**Approve** or **Decline**), then your followers with **Follow back** (only for people you do not follow), **Message** and **Remove** after a confirmation. | `/person/{id}/followers`, read-only as above. |
| Visitors | `/profile/visitors`: who opened your profile, newest first visit first, as "visited 3 h ago", with a row menu (**Message**, **Follow**, **Block** after a confirmation). Pull to refresh, "No visitors yet", error with retry. The screen opens with the line "People can see that you visited their profile." | A plain number, never tappable, even for a follower (visitors are for the profile owner alone). |
| Stories | `/profile/stories` (My stories): your active stories newest first, each with a preview (photo, or words on its colour), time left, audience and "Seen by N". Tap one to see who watched it; delete with a confirmation; **Add story** opens the story composer. | Opens the story viewer for the stories you may watch (`GET /v1/users/{id}/stories`: `public` for anyone, `followers` stories once you follow them, `friends` stories for friends); a plain number when there are none. |

### Visitors: privacy and safety

- A visit is recorded once per pair, the first time a member opens a profile. Visitors are not notified and cannot opt out.
- The list is the owner's alone, and the server never names a visitor anywhere else.
- Minors and adults never see each other (age-band isolation), so neither appears in the other's list; blocked members (either direction) and inactive accounts are left out too. The number can therefore be larger than the list, which also stops at the owner's `VisitorListLimit` most recent visitors (200 on Free).
- The honest line "People can see that you visited their profile." sits at the top of the Visitors screen so nobody is listed by surprise. It also belongs in the docs that describe profile views: **profile views are visible to the profile owner.**
- **Open launch item for the owner:** add a line about profile views being visible to the profile owner to the Terms and Privacy copy before launch. No legal text is written in the repository.

## Capabilities waiting for their services

Voice introductions, stories/highlights, verification,
subscriptions, post/media feeds and notification settings are not implemented
services in this foundation.
Do not simulate them with random images, badges, counters, playback, or successful
social actions. Without a photo, the avatar uses an original static orbital
composition with the real account's initial. It is an identity decoration, not a
story/verification badge. Follow, friend requests and Message are live (see
`docs/api/13-social-and-activity.md`). Posts/Media have honest empty states; Vibes
displays the saved current vibe, with no fabricated history. The profile options
button offers mute, restrict, report and block (see `docs/api/14-safety-controls.md`).

Keep future private account, wallet, analytics, and identity operations separate
from the profile APIs. Media must use ownership checks and privacy-aware delivery;
do not import third-party public storage URLs as a substitute. Private age data
is kept in its own table (`member_ages`) and is used for age bands and the age filter
only; the only projection is whole years of age on another member's profile, governed by the `age` audience. Optional self-described gender must not be inferred
from the sample Boolean; the gender filter matches only members whose audience is everyone.

## Profile photos (avatars)

Every place a member appears (feed and story authors, comments, Discover and
Nearby rows, activity, chats, safety lists, space members, the header and
dock, Settings) goes through one widget, `PersonAvatar`
(`lib/shared/person_avatar.dart`). It shows the member's photo when the API sent
`avatarUrl` and otherwise keeps the existing look: the initial on a tint, or the
orbital monogram in the profile header. The photo replaces only the fill, so
accent frames, country badges and online dots are unchanged.

- **Quiet loading, safe failure.** While the photo loads, the fallback is what
  shows; a photo that fails to load simply leaves the fallback. Nothing shows an
  error or a spinner for an avatar.
- **Cache by path, not URL.** Photo URLs are signed and expire after about an
  hour. Images are cached under `avatar:<userId>:<object path>` (the query string
  is dropped), so a refreshed URL for the same photo is not downloaded again.
  Signed URLs are never logged or put in error messages.
- **Sizes.** Rows use the thumbnail (`avatarUrl`); the big circles on an own,
  visitor or locked profile use `avatarFullUrl` when the server sent it.
- **Choosing a photo.** Onboarding has an optional step (see
  [sign-in and onboarding](../mobile/14-sign-in-and-onboarding.md)); Edit profile
  has a tappable avatar with a camera badge opening a sheet: Choose from gallery,
  Take a photo (phones only) and Remove photo. A picked photo previews at once
  from local bytes, uploads with progress (Cancel drops it, a failure can be
  retried without picking again), is attached with `avatarMediaId` through the
  profile update (null removes it), and the profile is re-read so every screen
  updates. JPEG, PNG and WebP up to 15 MB are accepted; the picker resizes to
  2048 px at about 85% quality. Typed-in edits in the form survive a photo change.
  Code: `lib/core/avatar_upload.dart`, `lib/shared/avatar_sheet.dart`.

## Scope and verification

The navbar and other primary screen designs are preserved. Changes to privacy and
the editor support the profile's new fields. Existing global header actions remain.
Motion is finite, respects reduced motion, and does not loop while scrolling.

Verification covers persisted drafts and version conflict recovery, structured
languages, owner/visitor separation, blocks, restricted field audiences, private
account canaries, responsive scrolling, large text, light/dark appearance, and
regression screens. Render captures use local fixture accounts for visual review;
they are not seeded into a signed-in account.
