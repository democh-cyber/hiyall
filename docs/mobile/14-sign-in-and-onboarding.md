# Sign-in and onboarding (app)

The app signs people in with Firebase Authentication: email and password, Google and Apple. Facebook sign-in is built but switched off (see below). Sign in with Apple is described in its own section below. Every provider ends in a Firebase ID token, which the app sends as the bearer token on each API request. The API verifies it directly ([accounts and onboarding](../api/18-accounts-and-onboarding.md)) and creates the Hiyall account on first sight.

**Status:** the screens, state machine, token handling and tests are implemented and pass against a fake provider. The real Firebase project has not been connected, so no provider sign-in has been exercised end to end. Until keys are supplied the sign-in forms are visible but disabled, with a notice saying so.

## Supplying the Firebase project

`scripts/firebase-setup.sh` connects a Firebase project in one step. It uses the Firebase CLI, which is installed with the rest of the toolchain (see `toolchains.lock.json`).

```bash
firebase login                                       # once; opens a browser
./scripts/firebase-setup.sh hiyall-prod-1 --create   # or drop --create for an existing project
```

The script is safe to re-run. It:

1. registers the web app, the Android app (`app.hiyall.hiyall`) and the iOS app (`app.hiyall.hiyall`), reusing any that exist;
2. adds the Android debug keystore's SHA-1 and SHA-256 fingerprints, which Google sign-in needs. The keystore appears after the first Android build, so re-run then. Pass the release and Play app-signing fingerprints with `--sha <fingerprint>`;
3. turns on **Email/Password** and **Google** sign-in (`firebase deploy --only auth`). The consent screen's support email defaults to the CLI account; change it with `--support-email`;
4. writes two git-ignored files: `config/firebase.local.json` (every `FIREBASE_*` value, per platform) and `apps/mobile/ios/Flutter/Firebase.xcconfig` (the URL scheme below).

`scripts/dev-api.sh` reads `FIREBASE_PROJECT_ID` from that file and starts the API in Firebase mode, accepting browser requests from `http://localhost:49321` only. `scripts/dev-mobile.sh` passes the file with `--dart-define-from-file` and serves the web app on that address. The API verifies either Firebase tokens or the local fixture accounts, never both. The app can only sign in with Firebase, so local development needs the config file. `HIYALL_DEV_LOGIN=1` starts the API in fixture mode for the live tests and the chat peer tool only. For any other build, pass the same file:

```bash
flutter build apk --dart-define-from-file=../../config/firebase.local.json \
  --dart-define=API_BASE_URL=https://api.example.com
```

Plain `http://` to the API is accepted only by debug builds (`flutter run`) and only for `localhost`, `127.0.0.1` or `10.0.2.2`; every other build, including `--release` and `--profile`, requires `https://`. A release build pointed at `http://127.0.0.1:8080` therefore shows "The service is not configured yet." after a successful sign-in, so test against the local API with `scripts/dev-mobile.sh`.

You can also pass the values one by one: `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_AUTH_DOMAIN` (web), `FIREBASE_APP_ID_ANDROID|_IOS|_WEB` and `FIREBASE_API_KEY_ANDROID|_IOS|_WEB`. `FIREBASE_APP_ID` and `FIREBASE_API_KEY` apply to every platform. None of these is a secret. The API needs only `FIREBASE_PROJECT_ID`, because ID tokens are verified with Google's public keys.

Still done in the Firebase console:

- Authentication → Settings → Password policy: require at least 8 characters to match the app's own check.
- Authorized domains: add `localhost` if it isn't listed (Google sign-in in the browser needs it; Email/Password and the mobile apps don't), and the production web domain before launch.
- Facebook (optional, off by default): create a Meta app, paste its App ID and App Secret into the Facebook provider, add the OAuth redirect URI Firebase shows to the Meta app, then build with `--dart-define=ENABLE_FACEBOOK_LOGIN=true` to show the button.

Social sign-in uses Firebase's provider flow: `signInWithProvider` on Android and iOS, a popup on web. No extra native plugin is needed, but on iOS the browser hands the result back through a URL scheme made from the encoded iOS app ID. `Info.plist` reads it as `$(FIREBASE_IOS_URL_SCHEME)` from `Firebase.xcconfig`, which the setup script writes. If the native Google account chooser is preferred later, it can replace `signInWithGoogle` inside `FirebaseAuthGateway` without touching any screen.

## Pieces

| Piece | Where |
|---|---|
| Provider interface and a stand-in used until keys exist | `lib/core/auth/auth_gateway.dart` |
| Firebase implementation, error copy | `lib/core/auth/firebase_gateway.dart` |
| Build-time keys and legal links | `lib/core/auth/firebase_config.dart` |
| Session, verification hold, redirects | `lib/core/state.dart`, `lib/app.dart` (`authRedirect`) |
| Welcome, log in, sign up, reset, verify email, splash | `lib/features/auth/auth_screens.dart` |
| Five-step onboarding | `lib/features/auth/onboarding_screen.dart` |

## Flow

`authRedirect` is the single place that decides where a person belongs. It runs whenever the session or the verification hold changes.

| State | Destination |
|---|---|
| Restoring a sign-in at launch | `/splash` |
| Signed out | `/welcome`, `/login`, `/signup`, `/forgot-password` only; everything else goes to `/welcome` |
| Password account whose email is not verified | `/verify-email` |
| Signed in with the provider but the API could not be reached | `/splash` with Try again and Use a different account |
| Session established, onboarding not finished | `/onboarding` |
| Session established and onboarded | the app; the pages above redirect to `/home` |

Password accounts are held on the verify screen and never reach the API. It re-checks every five seconds and on demand, and limits resending to once per 45 seconds. Google, Facebook and Apple accounts skip it because the provider has already verified the address (see Apple's private relay addresses below).

After sign-in the app calls `GET /v1/me/profile` (which creates the account server side on first use) and `GET /v1/me/onboarding`, and builds the session from the result.

## Tokens

Firebase ID tokens last one hour. `Session.token` reads the newest token from the provider's cache, so the realtime socket and chat client pick up a rotated token on their next connect or request. The gateway also renews the token every 40 minutes while the app is open. A request that still receives a 401 asks the provider for a forced refresh and retries once; only if that gives the same token does the session end and the person return to Welcome with an explanation.

## Onboarding

Nothing is saved until the last step, so backing out loses nothing and leaves no half-made profile.

1. **Basics** — date of birth (must be 13 or older, the floor set by the identity providers' terms and children's-privacy law) and acceptance of the Terms and Privacy Policy. The date is sent once to `POST /v1/me/onboarding/complete`. The server stores it privately (it is never shown or returned) to apply the age-band protections and the age filter, and keeps the first value it receives.
2. **Name** — display name and username, prefilled from the provider where possible. Availability is checked before continuing and again by the server when saving.
3. **Add a photo** (optional) — a large circular placeholder with a camera icon, a **Choose a photo** button (gallery, plus the camera on phones), **Remove** once a photo is chosen, **Skip for now**, and a line saying the photo is public like the rest of the profile. The photo is only held on the device here: media routes answer `403 ONBOARDING_REQUIRED` until onboarding is complete, and nothing is saved before the last step anyway.
4. **A bit about you** (optional) — gender (woman, man or non-binary; leaving it blank sends nothing), country and languages.
5. **Interests** — at least three, up to ten, and an optional current vibe.

On finishing, the app saves the profile, then completes onboarding. Each call is safe to repeat, so a failure shows a message and the same Finish button retries. A username taken in the meantime returns the person to step 2.

**The photo goes last and can never block Finish.** Only after onboarding has completed does the app upload the chosen photo (`POST /v1/media/uploads`, the signed `PUT`, `POST /v1/media/{id}/complete`) and attach it with `PATCH /v1/me/profile` `{avatarMediaId}`. If the upload or the attach fails for any reason, onboarding still counts as finished: the person goes into the app and sees one snackbar, "We couldn’t upload your photo. You can add it from your profile." There is no retry loop; they add the photo from Edit profile. A server refusal on age shows a final page with Sign out. There are no privacy choices in onboarding: every profile is visible in Discover, and the only visibility control in the app is Settings → Show when I’m online.

## What this does not do

- The minimum-age confirmation is a self-declaration, not verified age assurance. Members of any age from 13 up can join, so Discover, Nearby and shared spaces are open to everyone; see the safety note in [open access and nearby](../api/19-nearby-and-open-access.md).
- The legal texts are drafts. They are bundled in the app (see [Legal documents](#legal-documents)) but still carry a banner saying they need legal review and placeholders for the operator's details.
- The Google "G" is drawn in code to approximate the official mark. Replace it with the official asset before store submission to meet Google's branding rules.
- Notification permission is not requested because push delivery is not implemented.
- Account deletion (another piece of work is building it; see the Apple note below), linking several providers to one account, and multi-factor sign-in are not implemented.

## Development

The app has no development or fixture login in any build, so there is nothing to strip from a release: local runs sign in through Firebase like users do (`config/firebase.local.json`, above). The server's `POST /dev/session` remains for Go tests and for the live tests, which sign in through `test/support/live_dev_session.dart`. Fixture identities used by widget tests (Anjali, Niko, Sam) are in `test/support/fixtures.dart`. `test/no_dev_code_test.dart` fails if `lib/` mentions the dev login, its flag or those identities.

Tests use a fake provider (`test/auth_test.dart`): sign-in states and redirects, form validation, verification, restoring a session, token refresh and retry, and every onboarding step including server refusals. Run `flutter test`; it needs no `--dart-define`.

## Legal documents

Plain-language drafts live in `docs/legal/` (`terms-of-service.md`, `privacy-policy.md`, `community-guidelines.md`, `children-and-teens.md`, `data-retention.md`). Each opens with a banner (DRAFT for legal review, not legal advice, placeholders in [BRACKETS] to be filled by the operator) and a `Version:` line. Identical copies are bundled in `apps/mobile/assets/legal/` (declared in `pubspec.yaml`) and rendered in the app by `lib/features/legal_screens.dart` with a small markdown subset parser in `lib/core/legal_documents.dart` (headings, paragraphs, bullets, bold, quotes and tables; no package).

| Where | What |
|---|---|
| Routes `/legal/terms`, `/legal/privacy`, `/legal/guidelines`, `/legal/teens`, `/legal/retention` | Outside the sign-in redirect, so they open signed out and in the middle of sign-up. They are pushed above the current page; Back returns to it. |
| Welcome, log in and sign up footers | Terms, Privacy Policy, Community Guidelines and Teens and safety links. |
| Onboarding step 1 | The consent line links Terms, Privacy Policy and Community Guidelines, a Children and Teens link sits below it, and "Terms version 2026-10-01" names what is accepted. |
| Settings, Legal group | One row per document. |

**One version, kept in step.** The server records the terms version a person accepts (`onboarding.terms_version`, constant `domain.TermsVersion` in `services/api/internal/domain/onboarding.go`). The app mirrors it as `kTermsVersion` (`lib/core/legal_documents.dart`) and every document carries the same `Version:` line. To publish a new revision, change all of them together and copy `docs/legal/*.md` over `apps/mobile/assets/legal/`. Tests fail when they diverge: `test/legal_test.dart` (bundled headers against `kTermsVersion`, against the Go constant, and the bundled files against `docs/legal`) and `TestLegalDocumentsCarryTheServersTermsVersion` in the API. At Finish, if the server asks for a revision other than `kTermsVersion` the app does not complete onboarding and tells the person to update, so nobody is recorded as accepting text they were not shown.

**Before launch:** fill every [PLACEHOLDER], have a lawyer review the drafts (the documents mark the parts that need it), then remove the draft banner from both copies. The Privacy Policy lists what could not be verified from the code (push delivery, logs kept by the hosting provider, account export and deletion, backups); confirm each. The earlier `TERMS_URL` and `PRIVACY_URL` build options no longer exist.

## Sign in with Apple

Apple requires an app that offers a third-party sign-in such as Google to offer Sign in with Apple too (App Store guideline 4.8), so the app has **Continue with Apple** next to Google on log in and sign up. It uses Firebase's `AppleAuthProvider` (`FirebaseAuthGateway.signInWithApple`): `signInWithProvider` on iOS and macOS, a popup on the web.

**Status:** implemented and tested with a fake provider and with locally signed tokens on the API side. It has **not** been run against Apple or Firebase, and nothing here shows it works end to end. The Xcode capability could not be checked on this machine (no Xcode).

| Platform | Button |
|---|---|
| iOS, macOS | Always shown. |
| Web | Only when the build sets `--dart-define=APPLE_SIGN_IN_WEB=true` (it needs a Services ID, below). |
| Android | Never shown. Firebase can run Apple sign-in there through a web flow, but it needs the same Services ID, and Apple does not require it. |
| Tests | Hidden unless a test injects the platform or `SocialSignIn.showApple`. |

Behaviour: closing the Apple sheet is not an error and shows nothing (`canceled`, `user-cancelled`, `web-context-canceled`, `web-context-cancelled`, `popup-closed-by-user`); other failures use the same friendly copy as the other providers. A first sign-in creates the account on the API like any other and goes through the same five onboarding steps. Apple only gives the name on the very first authorisation, so the display name may be blank and onboarding asks for it. Apple's **Hide My Email** addresses (`@privaterelay.appleid.com`) are accepted: the API does not hold `apple.com` tokens for email verification (`firebaseClaims` only requires it for the `password` provider, and the API never stores the address), and the app has no verification step for Apple accounts. `services/api/internal/identity/apple_test.go` covers relay, real, missing and unverified addresses.

### Owner setup

1. **Apple Developer, App ID.** Certificates, Identifiers and Profiles, Identifiers, open the App ID `app.hiyall.hiyall` (create it if missing), tick **Sign in with Apple**, Save. Regenerate and download the provisioning profile if you sign manually.
2. **Xcode.** Open `apps/mobile/ios/Runner.xcworkspace`, select the Runner target, Signing and Capabilities. **Sign in with Apple** should be listed. The repository already has `ios/Runner/Runner.entitlements` with `com.apple.developer.applesignin` and the project's `CODE_SIGN_ENTITLEMENTS` pointing at it (written by hand, not by Xcode); if the capability is missing, add it with the + button, and check that Xcode did not create a second entitlements file. If another feature has added keys such as `aps-environment` to the same file, keep them all. Build to a real device or simulator signed in to an Apple ID.
3. **Firebase console.** Authentication, Sign-in method, Add new provider, **Apple**, enable. For iOS and macOS only, nothing else is needed.
4. **Web (and Android, if ever wanted).** In Apple Developer create a **Services ID** (for example `app.hiyall.hiyall.web`), enable Sign in with Apple for it, and configure the domain `<project>.firebaseapp.com` and the return URL `https://<project>.firebaseapp.com/__/auth/handler` that the Firebase Apple provider panel shows. Create a **Key** with Sign in with Apple enabled, tied to the App ID, and download the `.p8` once. In the Firebase Apple provider enter the Services ID, your Apple Team ID, the Key ID and the contents of the private key. Never commit the key. Add the production web domain to Firebase authorized domains, then build the web app with `--dart-define=APPLE_SIGN_IN_WEB=true`.
5. **Private email relay.** If you will ever email members, register your sending domain and address in Apple Developer, Certificates, Identifiers and Profiles, More, Configure Sign in with Apple for Email Communication, or relayed addresses will bounce.
6. **App Store review.** Mention Sign in with Apple in the review notes and have an Apple sign-in test path ready.

### Account deletion and token revocation (owner note)

Apple requires an app that creates accounts to let people delete them inside the app, and for accounts made with Sign in with Apple the app must also **revoke the Apple tokens** when the account is deleted (App Store guideline 5.1.1(v)). Deleting the Firebase user does not do that. Revoking needs Apple's REST call `POST https://appleid.apple.com/auth/revoke` with the app's client ID (the bundle ID for native sign-ins, the Services ID for web), a client secret signed with the `.p8` key (a JWT with `iss` the Team ID, `sub` the client ID, `aud` `https://appleid.apple.com`), and the user's Apple refresh token (or access token). Either call it from your own server, or use the Firebase Authentication SDK's Apple token revocation (the Flutter `firebase_auth` package has a `revokeTokenWithAuthorizationCode` method for this; check the current documentation), which needs the Apple authorisation code from a fresh Apple sign-in and the key configured in the Firebase Apple provider. Either way the app must reauthenticate with Apple at deletion time to obtain the code, because the code is short-lived and is not kept. This has not been built: whoever implements account deletion must add the exchange at sign-in or reauthentication, store the refresh token privately, and call revoke during deletion, and until then Apple review may reject the app.
