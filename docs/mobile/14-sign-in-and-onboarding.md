# Sign-in and onboarding (app)

The app signs people in with Firebase Authentication: email and password and Google. Facebook sign-in is built but switched off (see below). Every provider ends in a Firebase ID token, which the app sends as the bearer token on each API request. The API verifies it directly ([accounts and onboarding](../api/18-accounts-and-onboarding.md)) and creates the Hiyall account on first sight.

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

`scripts/dev-api.sh` reads `FIREBASE_PROJECT_ID` from that file and starts the API in Firebase mode, accepting browser requests from `http://localhost:49321` only. `scripts/dev-mobile.sh` passes the file with `--dart-define-from-file` and serves the web app on that address. The API verifies either Firebase tokens or the local fixture accounts, never both, so once the config file exists the fixture accounts are off; set `HIYALL_DEV_LOGIN=1` for both scripts to bring them back. For any other build, pass the same file:

```bash
flutter build apk --dart-define-from-file=../../config/firebase.local.json \
  --dart-define=API_BASE_URL=https://api.example.com \
  --dart-define=TERMS_URL=https://... --dart-define=PRIVACY_URL=https://...
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

Password accounts are held on the verify screen and never reach the API. It re-checks every five seconds and on demand, and limits resending to once per 45 seconds. Google and Facebook accounts skip it because the provider has already verified the address.

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
- Terms and Privacy Policy text is not in the app. The sign-up and onboarding screens link to `TERMS_URL` and `PRIVACY_URL` when supplied and otherwise name the documents without a link; supply both before release.
- The Google "G" is drawn in code to approximate the official mark. Replace it with the official asset before store submission to meet Google's branding rules.
- Notification permission is not requested because push delivery is not implemented.
- Account deletion, linking several providers to one account, and multi-factor sign-in are not implemented.

## Development

Debug builds started with `ENABLE_DEV_LOGIN=true` show three local accounts on Welcome: Anjali and Niko (already onboarded) and Sam, who has not finished onboarding, for trying that flow against the local API. They are removed from release builds at compile time.

Tests use a fake provider (`test/auth_test.dart`): sign-in states and redirects, form validation, verification, restoring a session, token refresh and retry, and every onboarding step including server refusals. Run `flutter test`.
