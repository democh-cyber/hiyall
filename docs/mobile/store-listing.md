# Store listings: privacy label, Data safety and review inputs

Inputs for App Store Connect (App Privacy), the Play Console (Data safety) and review notes, derived from
what the code sends. Re-derive them whenever a feature adds or changes data; the code references are the
source of truth. **Everything marked "decide" or "uncertain" needs the owner or counsel; none of this is
legal advice.** The same facts are declared in `ios/Runner/PrivacyInfo.xcprivacy`.

## Listing fields (owner completes; preflight gate i fails while a field is unfinished)

Draft copy is offered where the code makes it checkable; the owner approves or rewrites it. Store limits: Apple name 30
characters, subtitle 30, keywords 100, promotional text 170; Play title 30, short description 80, full description 4000.

Unfinished fields are marked with the word in capitals that gate i searches for; replace each with the value.

| Field | Value |
| --- | --- |
| App name (both stores) | Hiyall |
| Apple subtitle (30) | Say hi to y'all |
| Play short description (80) | Meet people near you and everywhere. Private chats. Ages 13+. |
| Full description (draft; no claim that is not built) | Hiyall is a social app for meeting people. Find people in Discover, follow friends, share photos and stories, join spaces, and chat one to one with end-to-end encrypted messages and photos. Nearby is opt-in and only ever shows a rounded distance. Block and report on every profile and chat. For ages 13 and up. |
| Apple keywords (100) | TODO: owner |
| Primary category | Social Networking (Apple) / Social (Play) |
| Support URL | TODO: https page with a working contact (Apple tests it) |
| Marketing URL (optional) | TODO: URL or write "none" |
| Privacy policy URL | TODO: hosted copy of `assets/legal/privacy-policy.md` |
| Terms URL | TODO: hosted copy of `assets/legal/terms-of-service.md` |
| Account deletion URL (Play) | TODO: see "Web account-deletion URL" below |
| Contact email for the stores | TODO: monitored mailbox (same as `SUPPORT_EMAIL`) |
| Age rating answers | TODO: record the answers given (UGC yes, unrestricted web access no, location yes, no gambling) and the resulting ratings |
| Reviewer account (both stores) | TODO: record where the credentials are kept; see the runbook, "Reviewer account" |
| Export compliance answers | TODO: record the App Store Connect encryption answers and the classification used |
| Privacy label and Data safety reviewed against an Xcode privacy report and the real build | TODO: date and reviewer |
| Screenshots (phone; iPhone 6.9 in and 6.5 in; iPad only if iPad is supported) | TODO: captured from the release build on real devices |
| Feature graphic 1024x500 and 512x512 icon (Play) | TODO: owner-supplied artwork |
| Crisis resources verified for every launch country | TODO: date and reviewer |

## What the app sends, by feature

| Data | Sent when | Server keeps it | Code |
| --- | --- | --- | --- |
| Email address, sign-in provider id | Sign-up and sign-in (Firebase Auth) | In Firebase and as the account's identity | `core/auth/*`, `identity/` |
| Birth date | Onboarding age step | **Yes, stored privately** on the server (never shown to other members; it sets the age band and the age shown in years) and deleted with the account. A date under 13 is refused and only the sign-in identifier, a count and a time are kept (7 days of cooldown, deleted after 30 days; no date) | `completeOnboarding`, `age_gate_refusals` |
| Display name, username, bio, headline, profession, education, pronouns, gender, country, region, city, languages, interests, links | Profile editor | Yes, shown per the member's audience settings | `core/api.dart` `updateProfile` |
| Profile, post, story photos | Upload | Yes (R2), metadata stripped | `avatar_upload.dart`, `pulse.dart` |
| Posts, comments, story text, space discussions and members | Posting | Yes | `core/pulse.dart`, `core/spaces.dart` |
| Chat messages and chat photos | Sending a chat | Ciphertext only (end-to-end encrypted); the server also sees who talks to whom and when | `core/chat/*` |
| Approximate location | Only when the person turns Nearby on (after the explainer; off by default for everyone, also from Settings) and when they ask to refresh; there is no automatic refresh and no background reading | Offset and rounded server-side (about 1 km; about 11 km under 18), shared for 24 h, deleted after 7 days if not refreshed, deleted at once when Nearby is turned off. Sign-out asks the server to delete it (best effort); if that fails, or the session is ended elsewhere, the position stops being shown within 24 h and is deleted within 7 days | `core/nearby.dart`, `features/nearby_optin.dart` |
| Push token, chat device key, platform | Notifications consent, first chat | Yes, until signed out or the token is rejected; chat devices unused for 35 days are removed (a removed device registers again when the app returns) | `core/push/*` |
| Notification content sent through Google (FCM) and, on iPhones, Apple (APNs) | Each push | Not stored by us beyond delivery. A visible notification: title "Hiyall"; a chat shows "New message" and carries the conversation id, never message text; friend request, follow and space invitation notices can include another member's display name; device notices and "Account deletion scheduled" say so; Google and Apple see that a notification was sent, when, and what it shows | `internal/push/push.go` |
| Follows, friend requests, blocks, mutes, reports, notification settings, online-visibility choice | Using the app | Yes | `core/api.dart` |
| Crash and error reports | Only in builds with a Sentry DSN (Sentry, a service provider; the API sends scrubbed server errors to the same provider) | Scrubbed: no URLs, bodies, chat text, emails or ids; no user | `core/error_reporting.dart`, `internal/errreport` |
| Photos checked for known illegal images | Server side, when a profile, post or story photo is uploaded | A flagged photo and a case record (account id, fingerprint, size, times, decision) are kept as evidence for the period the legal text states, even after account deletion. Chat photos are end-to-end encrypted and are not checked | `internal/media/scan.go`, `internal/store/mediascan.go` <!-- claim:scanned --> |
| Abuse-prevention records | Using the app | Counters (rate limits, daily limits), a 24 hour idempotency key on posting, keyed hashes of the account, the network address and the Nearby search centre for 3 days (also used to cap how many accounts search Nearby from one address), a short-lived queue of account ids for recounting follower numbers (normally cleared within an hour) | `internal/ratelimit`, `internal/store/idempotency.go` |
| IP address, user agent | Every request | In server logs only (retention is the host's) | uncertain: confirm host log retention |

Not collected: contacts, calendar, microphone, advertising id, browsing history, precise GPS history,
financial data, health data. No third-party analytics or advertising SDKs. **Tracking: none.**

## Apple: App Privacy ("nutrition label")

All entries are "linked to the user", **not used for tracking**, purpose **App Functionality** (crash data:
not linked).

| Apple category | Declare | Note |
| --- | --- | --- |
| Contact Info: Email Address | Yes | |
| Contact Info: Name | Yes | Display name |
| Identifiers: User ID | Yes | |
| Identifiers: Device ID | Yes | Push token and chat device key. Uncertain whether Apple wants a push token here; declared to be safe |
| User Content: Photos or Videos | Yes | |
| User Content: Other User Content | Yes | Posts, comments, stories, bio |
| User Content: Emails or Text Messages | Yes (decide) | Chat is end-to-end encrypted and unreadable to us, but the server stores the ciphertext and delivery metadata. Apple's guidance on "collected" and E2EE is not explicit; declaring is the conservative reading |
| Location: Coarse Location | Yes | Opt-in. The phone asks the OS for an approximate fix, but sends the coordinates it gets and the server rounds them; if you would rather declare Precise Location, change both this and the manifest |
| Other Data Types | Yes | Birth date (stored privately for the age band), gender, interests, languages |
| Diagnostics: Crash Data | Yes | Only with Sentry; not linked. Sentry is a service provider, not "sharing" |
| Health, Financial, Sensitive Info, Contacts, Browsing/Search History, Purchases, Usage Data, Advertising | No | |

Privacy policy URL: the hosted copy of `assets/legal/privacy-policy.md`. Required fields in the listing: age
rating 12+/13+ (the app is open to 13+ with user-generated content: answer "yes" to UGC and unrestricted web
access = no), a working support URL, and a privacy-policy URL.

### Privacy manifest (`PrivacyInfo.xcprivacy`)

Declared required-reason APIs, as far as can be determined from our code and plugins:

| Category | Reason | Why |
| --- | --- | --- |
| File timestamp | C617.1 | files inside the app container: image cache, encrypted chat photo cache and outbox |
| User defaults | CA92.1 | Firebase and Flutter plugins keep settings there |
| System boot time | 35F9.1 | the Rust library times image preparation with `std::time::Instant` (reads the uptime clock on iOS) |

**Uncertainty.** The manifest was written by reading our code and plugin names, not by an Xcode privacy
report. Firebase, Sentry-Cocoa and the Flutter engine ship their own manifests; some third-party plugins
(`flutter_secure_storage`, `share_plus`, `geolocator`, `image_picker`) may or may not. Before the first
submission: archive in Xcode, choose Product > Archive > Generate Privacy Report, compare the aggregated report
with this file, and add any category it shows (disk space `E174.1`/`85F4.1` is the usual surprise). Apple emails
"ITMS-91053" for any missing declaration.

## Google Play: Data safety

Data is **encrypted in transit** (HTTPS only). Users can **request deletion**: in the app (Settings > Account
> Delete account) **and via a web page**, which Play requires (see below). Data **not shared** with third
parties except service providers acting for us (Firebase for sign-in and push, Cloudflare R2 for photos,
Sentry for crash reports; declare these as service providers, not "sharing").

| Play data type | Collected | Shared | Optional | Purpose |
| --- | --- | --- | --- | --- |
| Personal info: Name, Email address, User IDs | Yes | No | Required | App functionality, Account management |
| Personal info: Other (birth date, gender) | Yes | No | Required (birth date) / optional (gender) | App functionality |
| Photos and videos | Yes | No | Optional | App functionality |
| Messages: Other in-app messages | Yes (ciphertext) | No | Optional | App functionality |
| Other user-generated content (posts, comments, bio) | Yes | No | Optional | App functionality |
| Location: Approximate location | Yes | No | Optional (opt-in) | App functionality |
| App activity: Other actions (follows, reports) | Yes | No | Optional | App functionality |
| App info and performance: Crash logs | Yes (with Sentry) | No | Optional | Analytics |
| Device or other IDs | Yes | No | Required for notifications | App functionality |

Also answer: "Does your app let people create accounts?" Yes. "Account deletion URL": see below.
Content rating questionnaire: UGC, user interaction, shares location (approximate), no gambling, no
violence by the app itself. Target audience includes 13 to 17: complete the Families/teen policy questions and
note that adult and minor interaction limits exist (see `docs/legal/children-and-teens.md`).

## Web account-deletion URL (needed: not built yet; OWNER ACTION)

**Owner: the account-deletion URL field in the Listing fields table is yours to fill. Nothing in the repository can create the page.**

Play requires a public web page where a person can request deletion without installing the app, linked in the
Data safety form. None exists. Minimum: a page at `https://<domain>/delete-account` that explains the
in-app route, and a way to request deletion for someone who has lost the app (a form that emails
`PRIVACY_EMAIL`, answered within a stated time, after verifying ownership of the email). Apple also requires
in-app deletion (done) and, for Sign in with Apple accounts, that the link to the member's Apple account can be ended. The server revokes the token at deletion when the app supplies Apple's authorization code; when it cannot, the app tells the member to remove Hiyall under Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID, there is no operator revocation, and the legal texts say so
([COUNSEL/OPERATOR: confirm this satisfies Apple's account-deletion rule, when reviewing the build]). Support can delete an account on request
with the operator tool `admin schedule-deletion`, which is audited.

## Review notes to include

- Test accounts for reviewers (email + password) with a note that email verification is pre-completed.
- UGC safeguards (Apple 1.2): report and block in every profile and chat (Settings > Help & Safety explains
  them), published contact details (Help & Safety), a moderation team and a stated response target
  [COUNSEL/OPERATOR: response target]. No document in `docs/security/` states a number of hours, so none is claimed until the operator sets one and a person is on call to meet it (the marker keeps gate i red until then). Photo scanning, choose exactly ONE of the next two lines and delete the other (preflight gate q fails an unscanned release while the line that carries the hidden scanned-claim comment is still here):
  - Scanner configured: profile, post and story photos are compared, on upload, against a list of known illegal images (a hash list or provider); there is no filtering for nudity or any other content, and chat photos are end-to-end encrypted and are not checked. <!-- claim:scanned -->
  - Unscanned at launch (`SCAN_ALLOW_NONE=true` with `RELEASE_ACK_UNSCANNED=I_ACCEPT_UNSCANNED_PHOTOS`): uploaded photos are NOT scanned; moderation relies on member reports and staff review.
- Location is opt-in (off by default for everyone, read only after the in-app explainer and only while Nearby is open),
  rounded; age and gender filters are off when either side is a minor; members under 18 are not discoverable by adults.
- Encryption: see "Export compliance" in `16-release-and-reliability.md`.

## Crisis resources list (Help & Safety)

`lib/features/help_safety.dart` ships a short starting list (US 988, UK Samaritans and Childline, Canada,
Australia, India Tele-MANAS, findahelpline.com). **Verify every number and add the countries you launch in
before release**: numbers change and a wrong one in a safety screen is worse than none.

## Contact addresses

`SUPPORT_EMAIL`, `SAFETY_EMAIL`, `PRIVACY_EMAIL` are build-time. The release script refuses placeholders.
The mailboxes must exist and be monitored before review: Apple tests them.
