# Profile data and visibility review

Status: profile field review based on the supplied sample structures. The implemented subset is tracked below. No sample person, external photo, contact detail, or provider UID has been imported into the app.

## Boundaries

Separate the visitor profile, the owner's editable profile, private account settings, private wallet, and owner analytics. Do not return an account document directly as a visitor profile. Visitors receive an explicit server allowlist after account status, whole-profile audience, individual field audience, and bidirectional block checks.

The two supplied objects have different identities and must remain separate records. Neither object is a source of truth for our signed-in account.

## Field decisions

“Visible” below means eligible for an authorized viewer of the profile, not automatically available to everyone on the internet. Optional fields stay private until the owner chooses an audience. Empty, null, unsupported, or undisclosed values do not create empty rows, fake statistics, or inferred values.

| Sample field | Proposed use | Visitor visibility |
|---|---|---|
| `nickName`, `name` | Normalize to `displayName`; add a separate unique `username` | Display identity when profile access is allowed |
| `pics` | Owner-selected avatar and optional photo gallery; retain media ownership and order | Only media authorized for this viewer; supply through our media service rather than copying third-party URLs |
| `oneLineIntro` | Short headline | Optional; follows profile audience |
| `introduce` | Longer bio/about text | Optional; follows profile audience |
| `country` | Voluntarily chosen country; normalize uppercase country code | Optional location audience; no inferred GPS/IP location |
| `language` | Normalize to tagged language entries | Optional languages audience; do not label proficiency until numeric values are defined |
| `transLanguage` | Preferred translation language | Private language settings |
| `job` | Normalize to `profession` | Optional profession audience; hide null values |
| `gender`, `man` | Optional self-described gender field if the product needs it; pronouns remain distinct | Optional explicit audience; do not infer gender from a Boolean or photo |
| `birthYear`, `age` | Private age/eligibility source where needed; optional audience-filtered age or age range | Do not show birth year/date by default. Birth year alone cannot establish exact current age |
| `audioUrl` | Optional voice introduction with user-initiated playback | Same profile/media audience checks; hide absent audio |
| `socialCount.following`, `socialCount.follower` | Server-derived social counts; count visibility setting | Only if counts are enabled and supported; never reveal inaccessible member lists through aggregates |
| `socialCount.story` | Separate authorized active story availability from total/archive counts | Ring/highlights only for accessible, unexpired or explicitly highlighted content; zero does not create a story ring |
| `socialCount.visitor` | Aggregate profile-view analytics, only if the product defines and implements them | Owner analytics only; no public visitor counter or visitor identities by default |
| `online` | Presence managed by a dedicated presence feature | Owner's online audience; missing/hidden must not be presented as offline |
| `lastLoginTime` | Private authentication activity | Never a visitor field; do not reuse as last seen. Visible last seen needs its own source and audience |
| `premium` | Subscription state; optional owner-enabled subscriber badge | Only an optional badge, never billing details; premium does not mean verified |
| `coin` | Server-controlled wallet balance | Owner wallet only |
| `roomCount` | Meaning unresolved: may be private conversations or public rooms | Keep private until defined; private conversation count must not appear on visitor profiles |
| `signUpTime` | Account creation metadata; optional “Member since” month/year | Hide precise timestamp; optional coarse date only if owner enables it |
| `email`, `phone` | Recovery/contact information | Private account settings; omit entirely from visitor responses |
| `provider` | Sign-in method / connected identity settings | Private account/security settings |
| `_id`, `id`, `uid` | Internal records or identity-provider mapping | Do not render; expose only our necessary opaque profile identifier for routing. An identifier is never authorization |

## Recommended first profile experience

Own profile:

1. Avatar, display name, username, optional headline and bio.
2. Optional country, languages, interests, profession, pronouns, and website with field audiences.
3. Server-backed following/follower counts and content tabs only when their features exist.
4. Edit profile, privacy settings, and a preview of the profile as another authorized viewer.
5. Account/security, subscription, wallet, and analytics reached through separate owner-only settings, as those features become available.

Visitor profile:

1. The audience-filtered identity and optional details above.
2. Only authorized photos, posts, active stories, and highlights.
3. Follow/message actions when the underlying feature and recipient policy allow them.
4. Block and report actions as supported. A blocked or unauthorized account gets the same unavailable state without leaking profile details.

Nulls and hidden fields are omitted from the rendered profile. Do not explain a hidden field with sensitive placeholder text such as “gender hidden” or “last seen hidden.” Keep unsupported counts and content sections absent until there is real data.

## Current implementation and gaps

- The redesigned profile and editor now consume display name, username, headline, bio, optional separate quote, real derived social counts, profession, pronouns, country, structured languages/proficiency, interests, Current Vibe, and bounded profile signature choices. They use the existing versioned profile API.
- Visitor responses apply a server allowlist, profile access, blocks, and field audiences. Optional country, languages, profession, interests, and Current Vibe remain private by default. Country disclosure does not include city or region. Friends/followers access fails closed while relationship modules are unavailable.
- Friends, Following and Followers now derive from accepted/active persisted relationships. Inactive or blocked peers are excluded; new accounts have zero counts. Count visibility defaults to only me and is enforced server-side. No sample relationships are imported; creation/approval APIs remain pending.
- Avatar/cover uploads remain rejected until ownership and media delivery exist. The profile uses an original generated orbital monogram; the navbar keeps its existing initial avatar.
- Gallery, voice introduction, age/gender flows, live presence, connection workflows/member lists, profile-view analytics, wallet, subscriptions, stories and content feeds require their own services. They are not simulated by the profile redesign.
- See [the implemented profile experience](10-profile-experience.md) for the current scope, response contract, and deferred service boundaries.

## Response design

Keep these response purposes separate:

- `GET /v1/me/profile`: owner's editable profile fields and version, without identity-provider subjects or wallet secrets.
- `GET /v1/users/{id}/profile`: viewer-filtered profile fields only. This is the source for other people's profile screens.
- Private account/security endpoints: sign-in methods, recovery details, and session activity.
- Private wallet and analytics endpoints: balance and aggregate visits, once implemented.
- A privacy-aware media service: authorized avatar/gallery/audio delivery. A long-lived public media URL cannot preserve later audience changes.

Encrypting transport does not determine who may see a profile field. Sensitive fields must be excluded by the server before the visitor response is created; client-side hiding is insufficient.
