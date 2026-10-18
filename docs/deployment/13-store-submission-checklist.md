# Store submission checklist (Google Play and Apple App Store)

**Status, 19 October 2026.** Refreshed for Wave 7 (profile v2, voice and video in chat, on-device translation, topics and voice notes,
notices and support, coins, Premium and rewarded ads). Written from the code, not from a store review: nothing here has been submitted.
**None of this is legal advice.** Items marked **OWNER** need an account, a credential, a page or a decision that only the owner has; the
repository cannot do them. Items marked **DECIDE** need the owner or counsel to choose. Everything else is a fact the repository already
holds, with where to look.

Companion pages: [release runbook](12-release-runbook.md) (the order of steps; step 7 is store submission),
[store listings](../mobile/store-listing.md) (listing fields, what the app sends, the full Apple and Play tables, review notes),
[shop and ads](../mobile/18-shop-and-ads.md), [billing API](../api/28-billing.md), [legal drafts](../legal/privacy-policy.md),
[deploy guide section 12](10-deploy-guide.md) (billing, AdMob), [environments](11-environments.md).

## 0. Decide first: are paid features on at launch?

`PLANS_ENFORCED` (API) is **off by default**: nothing is charged, no shop, no coins and no ads appear for anyone. Every answer below
that says "when paid features are on" is the state after the owner flips it.

- [ ] **DECIDE** Launch with paid features off (recommended for the first review: fewer forms, no AdMob, no In-App Purchase review) or on.
- [ ] If off: the legal drafts keep their present-tense wording ("free to use today, no ads"); delete the `[COUNSEL: paid features at launch ...]`
  brackets in `docs/legal` (both folders). The Android release build still needs an AdMob **app** id (Gradle refuses a release build
  without `ADMOB_APP_ID_ANDROID`, because the ads SDK reads it at start), so an AdMob account is needed even with ads off, **or** the build
  must be changed to leave the SDK out. **DECIDE** which.
- [ ] If on: do sections 5 and 6, keep the bracketed paid wording in `docs/legal` (counsel confirms it, then remove the brackets), answer the
  Play and Apple forms with the "when paid features are on" rows, and mirror `PLANS_ENFORCED` and `ADMOB_SSV_AD_UNIT_IDS` as repository
  variables so release gate s checks the AdMob ids strictly.

## 1. Release gates that enforce this page

| Gate | What it checks |
| --- | --- |
| b | legal drafts final (no DRAFT banner, no `[BRACKET]`), both folders identical, one terms version |
| f | Info.plist purpose strings present (location, photo library, camera, microphone), `aps-environment`, bundle ids |
| i | `docs/mobile/store-listing.md` has no `TODO` / owner marker left |
| q | unscanned-photo acknowledgement; legal text may not describe a scanner while unscanned |
| s | AdMob release ids: real (not Google's test ids), well-formed, unit listed in `ADMOB_SSV_AD_UNIT_IDS`. **Hard failure** when `PLANS_ENFORCED=true` or `ADMOB_SSV_AD_UNIT_IDS` is set; a warning otherwise |

## 2. Google Play Console (all **OWNER**)

Answers come from `docs/mobile/store-listing.md` ("What the app sends", "Google Play: Data safety"); the rows added for Wave 7 are below.

### Data safety form

Data is **encrypted in transit** (HTTPS only). Users can request deletion in the app (Settings > Account > Delete account) and on a web page
(**OWNER**: the page does not exist yet, see store-listing.md "Web account-deletion URL"). Data is **not sold**. Service providers acting
for us (Firebase, Cloudflare R2, Sentry) are not "sharing".

| Play data type | Collected | Shared | Required or optional | Purpose | New in Wave 7 |
| --- | --- | --- | --- | --- | --- |
| Personal info: name, email, user IDs | yes | no | required | App functionality, account management | |
| Personal info: other (birth date, gender, language levels, personality tags, hometown, optional birthday) | yes | no | birth date required, the rest optional | App functionality | profile v2 fields |
| Photos and videos | yes | no | optional | App functionality | gallery of 8; chat videos (ciphertext) |
| Audio: voice or sound recordings | yes | no | optional | App functionality | voice notes on posts and stories; chat voice messages (ciphertext) |
| Messages: other in-app messages | yes | no | optional | App functionality, customer support | support messages (plaintext, staff can read) |
| Other user-generated content | yes | no | optional | App functionality | topics; text is searchable by members who may see it |
| Location: approximate | yes | no | optional (opt-in) | App functionality | unchanged: Nearby off until turned on |
| App activity: other actions | yes | no | optional | App functionality | profile visits, visit notices |
| App info and performance: crash logs | yes (when a Sentry DSN is set) | no | optional | Analytics | |
| Device or other IDs: push token, chat device key | yes | no | required for notifications | App functionality | |
| Financial info: purchase history | **when paid features are on** | no (the store keeps its own) | optional | App functionality | coins, Premium |
| Device or other IDs: advertising ID | **when rewarded ads are on** | **yes, with Google AdMob** | optional | Advertising | AdMob; adults only, after consent |

Not collected: contacts, precise location, health, payment details. Local-only, not collected: saved Discover filters, translations.
**DECIDE / uncertain:** whether ML Kit's language-pack download or its own usage metrics must be declared (message text never leaves the
phone). Check Google's ML Kit data disclosure before answering "no" for the diagnostics type.

### App content declarations

- [ ] **Ads:** "Contains ads" is **no** while rewarded ads are off and **yes** once on. The Android build merges the advertising-ID permission
  (`com.google.android.gms.permission.AD_ID`) through the ads plugin even when ads are off: complete the **Advertising ID** declaration
  (purpose: advertising once ads are on; if ads stay off, check whether Play still wants the answer for a build that carries the SDK).
- [ ] **Target audience:** 13 and over (13 to 15, 16 to 17, 18+). Minors and adults are kept apart; ads and purchases are adults only and
  enforced by the server (`docs/api/28-billing.md`). Complete the teen questions.
- [ ] **Content rating (IARC):** user-generated content yes, users interact yes, shares location yes (approximate), digital purchases yes
  (when on), no gambling, no violence by the app.
- [ ] **App access:** restricted; give the reviewer accounts (runbook step 6).
- [ ] **Account deletion** URL and in-app path; **Financial features:** none; **Health, news, government:** none.
- [ ] **Permissions:** `RECORD_AUDIO` (voice messages, videos and voice notes: only while recording) and `ACCESS_COARSE_LOCATION` are shown on
  the listing. Neither is a restricted permission that needs a declaration form (verify in the Console: the policy changes).
- [ ] **In-app products** (when on): see section 5.

## 3. Apple App Store Connect (all **OWNER**)

### App Privacy ("nutrition label")

Declare from `docs/mobile/store-listing.md` ("Apple: App Privacy"). Additions for Wave 7: **User Content: Audio Data** (voice notes and chat
voice messages; already in `PrivacyInfo.xcprivacy`), **User Content: Customer Support** (plaintext support messages), and for the profile v2
fields **Other Data Types**. When paid features are on: **Purchases: Purchase History** (linked, App Functionality) and, for AdMob, the
Identifiers, Usage Data and Diagnostics types Google lists for rewarded ads (**DECIDE**: follow Google's "Apple App Privacy details" page; the
app never asks for App Tracking Transparency, ads are not personalised without consent, and `NSPrivacyTracking` is `false` today).

- [ ] Archive, Product > Archive > **Generate Privacy Report**, compare with `ios/Runner/PrivacyInfo.xcprivacy` (the AdMob and ML Kit pods ship
  their own manifests; add any category the report shows, runbook and store-listing.md describe the usual `E174.1` surprise).
- [ ] **Age rating** (section 4), **privacy policy URL**, **support URL**, **terms URL** (the app links the same texts in Settings > Legal).
- [ ] **Export compliance:** `ITSAppUsesNonExemptEncryption` is `true` (own end-to-end encryption); answers in `docs/mobile/16-release-and-reliability.md`.
- [ ] **Sign in with Apple** is offered, so account deletion must also end the Apple link: see store-listing.md.
- [ ] **Subscriptions** (when on): subscription group, localized names, the privacy policy and terms links must be reachable in the app and in the
  metadata (Settings > Legal has them; the Shop shows the store's own price and length). **OWNER:** confirm Apple's subscription-information
  rules against the Shop screen on a real device.

## 4. Age rating notes (both stores)

- Minimum age **13**, self-declared date of birth (no age assurance). Members 13 to 17 and 18+ are kept apart in every list.
- **User-generated content: yes** (posts, stories, comments, spaces, voice notes, photos, chat). Safeguards for Apple 1.2: report and block on every
  profile, post and chat, a moderator console, published contact details (Settings > Help & Safety). Voice notes are not scanned and a moderator
  cannot yet play one in the console (`docs/api/27-stories-notices-support.md`, section 3): **DECIDE** whether to close that gap before launch.
- **Messaging and chat: yes** (end-to-end encrypted one-to-one chats; support messages are not encrypted).
- **Location:** approximate, opt-in, off by default; the age and gender filters do not exist for minors.
- **Unrestricted web access: no** (a notice opens only `https` links; confirm in the questionnaire how Apple counts links that leave the app).
- **In-app purchases and ads:** adults only; a member under 18 never sees a shop, is charged or has the ads SDK started. Answer the
  advertising question **no while ads are off, yes once on**. Apple's age-rating questionnaire changes: answer what is true, do not copy this page.
- **DECIDE / uncertain:** the rating the questionnaires produce. Expect 13+ or higher because of user-generated content and chat.

## 5. In-App Purchase capability and store products (only when paid features are on; all **OWNER**)

- [ ] **Apple:** enable the **In-App Purchase** capability on the app id (developer portal) **and** on the Runner target in Xcode (the repository
  does not enable it; `Runner.entitlements` carries only push and Sign in with Apple). Accept the Paid Applications agreement; set tax and banking.
- [ ] Create the products named in `config/billing-catalog.example.json`: consumables `coins_s`, `coins_m`, `coins_l`, `coins_xl`; a subscription
  group with `premium_1m`, `premium_3m`, `premium_12m`. **Prices are set in the stores**, never in the catalog. Add the review screenshots.
- [ ] Create the App Store Connect In-App Purchase key; set `APPLE_IAP_*` and the App Store Server Notifications V2 URL
  (`https://<api host>/v1/billing/apple/notifications`). See deploy guide section 12 step 3.
- [ ] **Google Play:** merchant account, in-app products and subscriptions with the same ids, a service account with the two Play permissions, the
  Pub/Sub topic and the **push** subscription to `/v1/billing/google/rtdn?token=...`, license testers. See deploy guide section 12 step 2.
- [ ] Rehearse with a license tester and an Apple sandbox account on a release-signed build before `PLANS_ENFORCED=true` (step 5 of section 12).
- [ ] Review notes: purchases are adults only; the reviewer account is an adult; spend always asks first; "Restore purchases" is in the Shop.

## 6. AdMob (only when rewarded ads are on; all **OWNER**)

- [ ] AdMob account with the payment profile and address verification done.
- [ ] Register the Android and iOS apps; note the two **app ids** (`ADMOB_APP_ID_ANDROID`, `ADMOB_APP_ID_IOS`, form `ca-app-pub-<publisher>~<app>`).
- [ ] Create one **rewarded** ad unit per platform; note the **unit ids** (`ADMOB_REWARDED_ANDROID`, `ADMOB_REWARDED_IOS`, form
  `ca-app-pub-<publisher>/<unit>`). Enable **server-side verification** on both with the callback `https://<api host>/v1/billing/admob/ssv` and set
  `ADMOB_SSV_AD_UNIT_IDS` on the API to the two unit ids.
- [ ] Put the four app and unit ids in `config/mobile-release.production.local.env` or as repository variables (they are not secrets), plus the
  `PLANS_ENFORCED` and `ADMOB_SSV_AD_UNIT_IDS` mirrors. **Never Google's published test ids**: gate s refuses them, `scripts/build-release.sh`
  warns, and Gradle refuses the Android test app id.
- [ ] **Privacy & messaging:** create the consent message (GDPR/UK and the US-states message) so the User Messaging Platform form the app calls
  has something to show, and the age-restricted-users setting. The app already marks every member who is not a confirmed adult as child-treated and
  caps ad content at PG.
- [ ] **app-ads.txt:** publish it on the developer website named in both store listings (AdMob verifies it). The repository has no website.
- [ ] iOS: add Google's `SKAdNetworkItems` list to `ios/Runner/Info.plist` (an owner step; the repository does not carry it).
- [ ] Test on a device with a registered test device before the first real impression; a test ad earns nothing.

## 7. Permission strings review

| Permission | Where | Text or reason | Status |
| --- | --- | --- | --- |
| Location (approximate) | iOS `NSLocationWhenInUseUsageDescription`, `NSLocationDefaultAccuracyReduced`; Android `ACCESS_COARSE_LOCATION` (fine location is removed) | Nearby only, rounded, opt-in, never in the background | ok |
| Photo library | iOS `NSPhotoLibraryUsageDescription` | "photo or video you choose ... Only what you pick is shared" (updated: covers gallery, story and chat) | ok, **OWNER** read it once on a device |
| Camera | iOS `NSCameraUsageDescription`; Android has no `CAMERA` permission (the system camera app is used) | photo for a profile, post, story or chat, or a short video in a chat (updated) | ok |
| Microphone | iOS `NSMicrophoneUsageDescription`; Android `RECORD_AUDIO` | only while recording a voice message, voice note or video; never in the background; chat recordings are encrypted on the phone | ok; gate f now requires the iOS string |
| Notifications | iOS runtime prompt, Android `POST_NOTIFICATIONS` | asked after a first message or follow, never at launch | ok |
| Tracking | no `NSUserTrackingUsageDescription` | the app never asks for App Tracking Transparency | ok; **DECIDE** again before AdMob goes on |
| Billing | Android `com.android.vending.BILLING`; iOS In-App Purchase capability | adults only | the capability is an **OWNER** step (section 5) |
| Advertising ID | Android `AD_ID` (merged from the ads plugin) | declared in Play Console | **OWNER** (section 2) |
| Merged from plugins | `ACCESS_NETWORK_STATE`, `WAKE_LOCK` | Firebase Messaging | ok |

## 8. Before pressing submit

- [ ] `scripts/check.sh` and `scripts/release-preflight.sh` pass on the tagged commit (the preflight output is the source of truth for open gates).
- [ ] Legal: DRAFT banners removed, brackets resolved, **terms version bumped in the three places** (`docs/legal/*`, `apps/mobile/lib/core/legal_documents.dart`,
  `services/api/internal/domain/onboarding.go`) so existing members accept the Wave 7 wording; hosted copies match `assets/legal`.
- [ ] Store-listing.md has no TODO left; reviewer accounts exist in production; support, safety and privacy mailboxes are monitored.
- [ ] Screenshots from the release build on real devices (the Shop and ads only if paid features are on).
