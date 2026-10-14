# Store listings: privacy label, Data safety and review inputs

Inputs for App Store Connect (App Privacy), the Play Console (Data safety) and review notes, derived from
what the code sends. Re-derive them whenever a feature adds or changes data; the code references are the
source of truth. **Everything marked "decide" or "uncertain" needs the owner or counsel; none of this is
legal advice.** The same facts are declared in `ios/Runner/PrivacyInfo.xcprivacy`.

## What the app sends, by feature

| Data | Sent when | Server keeps it | Code |
| --- | --- | --- | --- |
| Email address, sign-in provider id | Sign-up and sign-in (Firebase Auth) | In Firebase and as the account's identity | `core/auth/*`, `identity/` |
| Birth date | Onboarding age step | Checked, then not stored (only the age band) | `completeOnboarding` |
| Display name, username, bio, headline, profession, education, pronouns, gender, country, region, city, languages, interests, links | Profile editor | Yes, shown per the member's audience settings | `core/api.dart` `updateProfile` |
| Profile, post, story photos | Upload | Yes (R2), metadata stripped | `avatar_upload.dart`, `pulse.dart` |
| Posts, comments, story text, space discussions and members | Posting | Yes | `core/pulse.dart`, `core/spaces.dart` |
| Chat messages and chat photos | Sending a chat | Ciphertext only (end-to-end encrypted); the server also sees who talks to whom and when | `core/chat/*` |
| Approximate location | Only after the person opens Nearby, reads the explainer and chooses to share, or turns it on in Settings | Rounded server-side (about 1 km; about 11 km under 18), shared for 24 h, deleted on sign-out | `core/nearby.dart`, `features/nearby_optin.dart` |
| Push token, chat device key, platform | Notifications consent, first chat | Yes, until signed out or the token is rejected | `core/push/*` |
| Follows, friend requests, blocks, mutes, reports, notification settings, online-visibility choice | Using the app | Yes | `core/api.dart` |
| Crash and error reports | Only in builds with a Sentry DSN | Scrubbed: no URLs, bodies, chat text, emails or ids; no user | `core/error_reporting.dart` |
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
| Other Data Types | Yes | Birth date (not stored), gender, interests, languages |
| Diagnostics: Crash Data | Yes | Only with Sentry; not linked |
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

## Web account-deletion URL (needed: not built yet)

Play requires a public web page where a person can request deletion without installing the app, linked in the
Data safety form. None exists. Minimum: a page at `https://<domain>/delete-account` that explains the
in-app route, and a way to request deletion for someone who has lost the app (a form that emails
`PRIVACY_EMAIL`, answered within a stated time, after verifying ownership of the email). Apple also requires
in-app deletion (done) and, for Sign in with Apple accounts, token revocation (`identity/apple_revoke.go`,
needs the owner's Apple key).

## Review notes to include

- Test accounts for reviewers (email + password) with a note that email verification is pre-completed.
- UGC safeguards (Apple 1.2): report and block in every profile and chat (Settings > Help & Safety explains
  them), published contact details (Help & Safety), a moderation team and a 24-hour response target
  (`docs/security/`), filtering for sexual content in photos (scanning provider is an owner setup).
- Location is opt-in, only while Nearby is open, rounded; age and gender filters are off when either side is a
  minor; members under 18 are not discoverable by adults.
- Encryption: see "Export compliance" in `16-release-and-reliability.md`.

## Crisis resources list (Help & Safety)

`lib/features/help_safety.dart` ships a short starting list (US 988, UK Samaritans and Childline, Canada,
Australia, India Tele-MANAS, findahelpline.com). **Verify every number and add the countries you launch in
before release**: numbers change and a wrong one in a safety screen is worse than none.

## Contact addresses

`SUPPORT_EMAIL`, `SAFETY_EMAIL`, `PRIVACY_EMAIL` are build-time. The release script refuses placeholders.
The mailboxes must exist and be monitored before review: Apple tests them.
