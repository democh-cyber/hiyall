# Release builds, error reporting, versions and links (app)

How a Hiyall release is built and what protects it once it is out. API-side counterparts are in
[the deploy guide](../deployment/10-deploy-guide.md) and [environments](../deployment/11-environments.md).

## Building a release

`scripts/build-release.sh android|ios|web` is the only supported way to build a release. It refuses to
build (exit 1, every problem listed) unless it has:

| Needed | Variable | Notes |
| --- | --- | --- |
| API address | `API_BASE_URL` | must be `https://`, not localhost |
| Firebase | `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_API_KEY`, `FIREBASE_ANDROID_APP_ID` or `FIREBASE_IOS_APP_ID` or `FIREBASE_WEB_APP_ID` (+ `FIREBASE_AUTH_DOMAIN` for web) | per-platform keys `FIREBASE_API_KEY_ANDROID/_IOS/_WEB` win over `FIREBASE_API_KEY` |
| Contacts | `SUPPORT_EMAIL`, `SAFETY_EMAIL`, `PRIVACY_EMAIL` | shown in Help & Safety; `ALLOW_PLACEHOLDER_CONTACTS=1` overrides for a test build |
| Version | `APP_VERSION` (`1.2.3`), `APP_BUILD_NUMBER` | version defaults to the `vX.Y.Z` tag, then `pubspec.yaml`; the build number to `GITHUB_RUN_NUMBER`. Stores reject a repeated build number |

It only warns about `SENTRY_DSN` (no crash reporting without it), `APP_STORE_URL` and `PLAY_STORE_URL`.
Inputs can come from the environment or from `config/mobile-release.<env>.local.env` (git-ignored; copy
`config/mobile-release.example.env`; `HIYALL_RELEASE_ENV=<env>`, default `production`). The script turns them
into a temporary `--dart-define-from-file` under `apps/mobile/build/` (git-ignored, deleted on exit) and runs
`flutter build appbundle | ipa | web --release --build-name --build-number`. Android and iOS add
`--obfuscate --split-debug-info=build/symbols`; **keep `build/symbols` for every release** (the workflow
uploads it) and upload it to Sentry, or crash reports cannot be read. Flutter web has no Dart obfuscation.
On iOS the script writes `ios/Flutter/Firebase.xcconfig` (the Firebase sign-in URL scheme, derived from the
iOS app id) when it is missing. `scripts/build-release.sh <platform> --check` validates and prints the
plan without building; `scripts/test-build-release.sh` exercises the refusals.

Compile-time switches, all `--dart-define`s: `ENABLE_EVENTS` (Events and Moments; default off),
`ENABLE_FACEBOOK_LOGIN`, `APPLE_SIGN_IN_WEB` and `APP_ENV`. There is no development-login switch: the app has no such code.

## Startup that cannot blank the screen

`FirebaseConfig.initialize()` never throws: a malformed key or a failed start marks Firebase as
unavailable, reports the error, and the app opens on Welcome with "sign-in isn't set up" like any build
without keys. Error reporting starts first so such a failure is seen.

## Error reporting (Sentry)

Phone: `sentry_flutter` 9.30.1 (pinned; 10.0.0 was five days old when this was written), initialised only when
`SENTRY_DSN` is defined. `environment` is `APP_ENV`, `release` is `hiyall@<version>+<build>`.
`FlutterError.onError` and `PlatformDispatcher.onError` both go through `ErrorReporting.capture`.
Nothing personal leaves the phone (`lib/core/error_reporting.dart`, tested in `test/error_reporting_test.dart`):
`sendDefaultPii` is false; no screenshots; request bodies and headers are dropped (only content type and the
client platform and version survive); URL query strings and fragments are cut and ids in paths become `:id`;
bearer tokens, JWTs, emails and ids are masked in every message, and so are quoted payloads (a JSON object or
array is cut from its opening `{"` to the end of the line, as a `FormatException` quotes it) and long base64-looking
runs; console/print breadcrumbs and anything that mentions a chat or conversation are dropped. Only an error that
nothing caught (`PlatformDispatcher.onError`) is reported as fatal and unhandled; errors the framework caught
(`FlutterError.onError`) are non-fatal, so crash-free statistics are not skewed.

**Debug symbols.** Release builds are obfuscated (`--obfuscate --split-debug-info=build/symbols`), so Dart stack
traces in Sentry are unreadable without the symbols. The Android and iOS jobs of `.github/workflows/release.yml`
upload `apps/mobile/build/symbols` with `sentry-cli debug-files upload` (`@sentry/cli` pinned) when the
repository secrets `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` and `SENTRY_PROJECT` are all set; with any of them missing
the step prints a notice and is skipped, and the symbols are still kept in the build artifact. Create the token
in Sentry with the `project:releases` and `org:read` scopes (a Custom Integration or an organisation token), and
upload the Android R8 `mapping.txt` the same way if native frames matter.

Server: `SENTRY_DSN` (plus `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`) enables `internal/errreport`, which
implements `httpapi.ErrorReporter` for panics and unexpected 500s. It is a small envelope client rather than
the sentry-go SDK on purpose: the SDK attaches the request, environment variables and host name by default and
each has to be audited on every upgrade, while this client can only send a route pattern, request id,
scrubbed message and a stack without argument values, and adds no dependency. Unset DSN: nothing is sent
(production logs a warning). Tests: `internal/errreport/errreport_test.go`.

## Version gate (426)

Every API call carries `X-Client-Version: <APP_VERSION>`. When the server refuses it with HTTP 426 and code
`UPGRADE_REQUIRED`, the app routes to a full-screen "Update Hiyall" page and nothing else works until it is
updated (store links from `APP_STORE_URL` / `PLAY_STORE_URL`; on web it asks for a reload).

## Messages people see

`friendlyError()` (`lib/core/user_error.dart`) is the only place an error becomes words. API failures are
worded by `ApiClient.failureMessage` from the status, the server's error code and the endpoint: offline,
timeout and 5xx are different messages, 404 names what was missing, 409 only says "username taken" for
`USERNAME_TAKEN`. Anything unexpected shows "Something went wrong. Try again." and goes to error reporting;
`toString()` is never shown. (The chat screens, owned separately, still have their own wording.)

## Signing out offline

Sign-out always finishes on the device. If the server cannot be told, the short-lived access token is kept in
the platform keystore for up to an hour and the revoke is sent on the next launch (`RevokeQueue`); the
identity-provider session ends on the device regardless.

`SessionController.signOutHooks` runs whenever a session ends: sign-out, session expiry, account deletion and an
end the identity provider reports by itself (`_onUser(null)` while a session is live and the app is not signing
out: a revoked refresh token, a disabled account) (`lib/core/state.dart`). Each hook gets 5 seconds
(`signOutHookTimeout`); one that throws or hangs is logged (error type only) and skipped, so it can never keep the
person signed in. The controller registers three hooks of its own, independent of any screen or provider
listener:

1. `chatWipeHook` (`lib/core/chat_wipe_hook.dart`): erases the departing account's chat keys, history and cached
   photos through `ChatLocalData.wipeAccount` and removes the chat device on the server, best effort with a 3 s
   limit; a failed revoke is remembered and retried next launch. The files go first and every keystore step is
   tried on its own: when the keystore errors, the account is written to a small "wipe pending" file
   (`chat_wipe_pending` in the app's private folder, no secrets) that `SessionController` retries at every launch
   (before the chat engine opens, see `chatWipeSettled`) and at the next sign-out. The chat keystore is bound in
   `lib/bindings.dart` (`chatWipeStoreProvider`).
2. The export-file wipe (`exportWipeProvider`): the data export in the temporary folder and the copy
   `share_plus` keeps in `<cacheDir>/share_plus` on Android (see "Data export on the phone").
3. `accountResidueHook` (`lib/core/signout_residue.dart`): the account's unsent story draft and its Home, Say hi
   and notification choices, image_picker's plaintext copies of picked photos (`sweepPickerTemp`,
   `lib/core/picked_file.dart`) and every cached picture (the network image cache is shared, so it goes whole).
   Whose it is comes from the departing session, else the last signed-in account, which is also kept in a small
   non-secret file (`last_user.json`, `lib/core/last_user.dart`) so that a cold start the server refuses with a
   dead credential still names it. Each step is best effort.

Push (`PushController.beforeSignOut`, each step limited to 2 s) and the chat engine add theirs. On expiry the
credential is already dead, so server calls in hooks fail quietly and the local clean-up is what runs.
A departure that finishes after somebody signed in again leaves what that sign-in remembered alone.
Tests: `test/session_hooks_test.dart`, `test/signout_paths_test.dart`, `test/session_round4_test.dart` (real
`SessionController`, fake keystore and revoker), `test/chat_wipe_pending_test.dart` (a keystore that errors).

Only the server's explicit `401 UNAUTHENTICATED` ends a session (`ApiClient`, the cold-start check in
`SessionController._establish`, and the realtime socket, which reads the reason with one plain request after a
refused handshake). `401 APP_CHECK_REQUIRED` means the app, not the session, is refused: nothing is signed out or
wiped, `appCheckRequiredProvider` is set and the router shows "Update or verify this app" (`/verify-app`, with
"Update now" and "Try again"). A 401 whose reason cannot be read proves nothing and is retried. The app does not
send an App Check token yet (see the deploy guide, App Check); this is only the error handling.

## Photos picked from the gallery or camera

`image_picker` copies every pick in plaintext into a temporary folder and never removes it (Android
`<cacheDir>/<uuid>/<name>`, the resized `<cacheDir>/scaled_<name>` and camera captures `<cacheDir>/<uuid><digits>.jpg`;
iOS `<tmp>/image_picker_<id>.<ext>`). Every pick site reads the photo with `readAndDeletePick` (story composer,
post composer, profile photo; the chat photo picker adopts the same helper), and `sweepPickerTemp` removes what is
left (the original of a resized pick, a pick never read) at every launch and in the residue hook at sign-out.
It looks only at the first level of the two temporary folders and only at those shapes. Tests:
`test/picked_file_test.dart` (temporary folders laid out like both platforms), `test/pick_sites_delete_test.dart`.

## Deep links

A location the person was sent away from (a notification, a shared link, a web URL) is remembered through
splash, welcome, log in, verify-email and onboarding and opened afterwards instead of Home
(`lib/core/deep_link.dart`). It is only remembered while no session has been active in this launch, so the
page someone signed out of is never offered to the next sign-in; it is bound to the account that was active and
dropped if another one signs in, and it is cleared on sign-out, session expiry and account deletion.
Unknown links show a branded "This page wandered off" page. Back from Sign up and
Log in returns to Welcome (they are pushed, and the links between the two replace each other).

**Owner steps for real Universal Links / App Links** (the app handles the routes; the platforms need proof
of domain ownership, which needs the final domain):

- Android: add intent filters with `android:autoVerify="true"` for `https://<domain>` in
  `android/app/src/main/AndroidManifest.xml`, and host `https://<domain>/.well-known/assetlinks.json`
  listing package `app.hiyall.hiyall` and the release signing key's SHA-256.
- iOS: add the Associated Domains capability (`applinks:<domain>`) to `Runner.entitlements`, and host
  `https://<domain>/.well-known/apple-app-site-association` with the team id + bundle id and the paths to open.
- Web: serve the Flutter build with SPA fallback (every path returns `index.html`) so a deep link reloads.

## Data export on the phone

"Download my data" goes through `ApiClient._request` like every other call (`X-Client-Version`, the https rule,
401 refresh-and-retry, 426 handling), as a raw byte download. On a phone the file is written to the temporary
folder only (never Documents, which iOS backs up), offered to the share sheet, and deleted when the sheet closes
(shared, cancelled or failed). Leftovers (an interrupted share, a crash, a file an older build put in Documents)
are removed at launch, when Settings resumes, and at sign-out when this run wrote one
(`lib/core/data_delivery.dart`, `data_delivery_io.dart`; the web download is unchanged). Tests:
`test/data_delivery_test.dart` (fake file system), `test/account_api_test.dart`.

One transport rule (`lib/core/api_config.dart`, `isSecureTransport`): https, or plain http to localhost,
127.0.0.1 or 10.0.2.2 in a debug build only. `ApiClient`, the realtime socket and `ChatApi` (its own requests and the
upload-slot check) all use that one helper.

## Deleting an Apple account

Any account that lists Apple as a provider (also next to Google, Facebook or a password) signs in with Apple again
and sends the one-time authorization code. If the server answers `422 APPLE_CODE_REQUIRED` for an account the app
did not know had an Apple identity (nothing was sent), the delete screen goes to the Apple sign-in step with no miss
counted. If Apple returns no code (web never does; iOS is unverified on a device), or a code was sent and the server
still refuses it, the screen shows a plain explanation with "Try Apple again" and "Contact support" (the Help &
Safety support address), logs it to error reporting without personal data, and stops asking after two misses.

After two misses the screen says what is true: Hiyall cannot remove its own access to the member's Apple ID without
Apple's confirmation, so the member does it afterwards in Settings > Apple ID > Sign in with Apple > Hiyall > Stop
using Apple ID (button to Apple's help page, `appleStopUsingUrl` in `lib/features/account_data.dart`; the owner
verifies that page before release). "Delete my account anyway" then sends `appleCodeUnavailable: true`; the response
field `appleAction: remove_in_apple_settings` makes the confirmation screen repeat the instruction. Nothing in the app
says staff will revoke the access.

## Help & Safety contacts

The three addresses come from `SUPPORT_EMAIL`, `SAFETY_EMAIL` and `PRIVACY_EMAIL`. A placeholder (`*.example`,
what a build made without the release script has) is never listed: its row is hidden, and the section says
"Contact details are being set up" and points at Block and Report in the app.

## Export compliance (owner action)

`Info.plist` sets `ITSAppUsesNonExemptEncryption` to `true`: the app ships its own end-to-end encryption
(Olm/Double Ratchet through vodozemac, ChaCha20-Poly1305 attachments) beyond what the operating system
provides, so Apple treats it as non-exempt. Before the first TestFlight upload to external testers:

1. In App Store Connect → App Information → App Encryption Documentation, answer the questionnaire:
   uses encryption, and it is not limited to the OS/HTTPS; the algorithms are standard (not proprietary).
2. Upload the self-classification report. Mass-market software with standard encryption normally qualifies
   under ECCN 5D992.c (the "mass market" note); confirm with counsel.
3. File the annual self-classification report with the US BIS (email to the addresses on bis.gov) by
   1 February of the following year, listing the product; Apple's page "Complying with Encryption Export
   Regulations" has the current steps.
4. France and a few other countries need a declaration or approval before distribution; if you list in
   France, Apple will ask for the French documentation. Keep the answers with the release records.

This is not legal advice; the classification is the owner's to confirm.

## Open-source licences

Settings → Help → Open-source licences opens Flutter's licence page. `registerAppLicenses` adds the two fonts
and the Rust crates (vodozemac Apache-2.0, flutter_rust_bridge MIT, x25519-dalek BSD-3-Clause, and the
RustCrypto, rand, zeroize, image and thumbhash crates) with their licence texts from `assets/licenses/`.
`test/licenses_test.dart` fails if a dependency in `rust/Cargo.toml` has no entry; update `lib/core/licenses.dart`
when you add a crate. Transitive Rust crates are covered by their parents' licences listed in
`rust/Cargo.lock`; generate a complete list with `cargo about` or `cargo license` before a public launch.

## Performance

Post photos decode at layout width times device pixel ratio (`photoDecodeWidth`, 64 px steps, 2048 cap)
instead of full size; people lists and the Spaces list build rows lazily (`SliverList.builder`). The
live-sync fallback poll and presence timers stop when the app is paused and restart on resume; the
verify-email page re-checks after 5, 15, then every 30 seconds and not at all in the background. The chat
list and the chat engine's own inbox timer belong to the chat code and were not changed here.

## Release preflight

`scripts/release-preflight.sh` is the single command that says whether the repository is fit to tag. It lists every
unmet gate with a one-line fix and exits non-zero; it does not build or run tests (`scripts/check.sh` does). Gates:
(a) git tree clean and tag-able, (b) legal text final, copies equal, one terms version, (c) mobile release inputs,
(d) production API environment, validated by the server itself (`api check-config -release`), (e) Android signing,
(f) versions and bundle ids, (g) icons and launch assets, (h) owner placeholders, (i) store-listing fields, (j)
migrations, (k) OpenAPI contract, (l) `go vet` and `govulncheck`, (m) the release workflow touches no dev script, (s) the AdMob release ids are real when ads or `PLANS_ENFORCED` are on (a warning otherwise; docs/mobile/18-shop-and-ads.md).
The store forms and owner accounts are in [the store submission checklist](../deployment/13-store-submission-checklist.md).
The ordered release procedure is [the release runbook](../deployment/12-release-runbook.md).

## Versions and bumping

The only place a version is written is `version:` in `apps/mobile/pubspec.yaml` (`1.0.0+1`: name `1.0.0`, build
number `1`). Flutter feeds it to Android (`versionName`, `versionCode` through `flutter.versionName` and
`flutter.versionCode` in `build.gradle.kts`) and to iOS (`CFBundleShortVersionString` is `$(FLUTTER_BUILD_NAME)`,
`CFBundleVersion` is `$(FLUTTER_BUILD_NUMBER)`). `scripts/build-release.sh` passes `--build-name` and
`--build-number` explicitly, so CI overrides the file: name from the `vX.Y.Z` tag, number from the workflow run
number. To release:

1. Edit `version:` (patch for fixes, minor for features; the build number only ever grows: both stores reject a
   build number they have seen, Play also rejects a lower `versionCode` than any previous upload).
2. Commit, then `git tag vX.Y.Z` (it must equal the name in `pubspec.yaml`; preflight gate a checks) and push the tag.
3. Raise `MIN_CLIENT_VERSION_ANDROID`/`_IOS` on the API only to retire an old version on purpose (426 screen).

The API's own version is `buildinfo.Version`, set at image build from the tag; `info.version` in the OpenAPI file is
the contract revision and is unrelated to the app version.

## Android release readiness

- **Identity.** `applicationId` and `namespace` are `app.hiyall.hiyall`, equal to the `MainActivity` package, the
  iOS bundle id and the Android app registered in Firebase (`FIREBASE_ANDROID_APP_ID`). It cannot change after the
  first Play upload; gate f checks all of them agree.
- **Signing.** Release tasks fail at configuration time unless `android/key.properties` (git-ignored) exists with
  `storeFile`, `storePassword`, `keyAlias`, `keyPassword` and the keystore file is present; there is no debug-key
  fallback. Create the upload key once and keep it, and its passwords, in a password manager and a second safe place:
  `keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`.
  Enrol in Play App Signing when creating the app, so Google holds the app signing key and you hold a resettable
  upload key. CI writes `key.properties` from the `ANDROID_*` secrets (see the workflow).
- **Shrinking.** R8 minification and resource shrinking are on for release; `app/proguard-rules.pro` explains every
  keep rule. Upload `build/app/outputs/mapping/release/mapping.txt` and `build/symbols` to Sentry with each release,
  and test the minified bundle on a device (R8 mistakes appear at run time). Native debug symbols for the Rust library
  ship in the bundle (`debugSymbolLevel = SYMBOL_TABLE`).
- **Icons and splash.** Adaptive launcher icon (`mipmap-anydpi-v26/ic_launcher.xml`: lime background colour, star
  foreground inside the safe zone, monochrome layer for themed icons), legacy PNGs for API 24 and 25, a monochrome
  notification icon (`drawable/ic_stat_hiyall.xml`, named by the FCM `default_notification_icon` meta-data with the
  `notification_accent` tint) and the Android 12 splash (`values-v31/styles.xml`: brand background, star on a lime
  disc; older versions use `drawable/launch_background.xml`). The star path is the one in `web/hiyall.svg`; the PNGs
  come from `flutter test tool/export_brand_assets_test.dart`. Not verified: no Gradle build or device run was
  possible where this was written (no Android SDK), so install a release build and look at the icon, splash and a
  push on a real Android 12+ phone.
- **Permissions.** Declared by the app: `INTERNET`, `ACCESS_COARSE_LOCATION` (Nearby asks for
  `LocationAccuracy.low`), `POST_NOTIFICATIONS`. Added by `firebase_messaging`: `WAKE_LOCK`, `ACCESS_NETWORK_STATE`.
  Removed from the merged manifest on purpose: `ACCESS_FINE_LOCATION`, `CAMERA` (image_picker uses the system camera
  app, and a declared `CAMERA` permission would make that intent crash without a runtime grant) and geolocator's
  location foreground service (no Play foreground-service declaration needed). After the first release build run
  `aapt2 dump permissions app-release.aab` (or inspect the merged manifest under `build/app/intermediates`) and
  compare with this list.
- **Network and backup.** Cleartext is off in release (`network_security_config.xml`, system CAs only); the debug
  build alone allows loopback and `10.0.2.2`. `allowBackup=false` plus `fullBackupContent` and `dataExtractionRules`
  exclude everything, because chat keys must not leave the phone.
- **SDK levels.** The Flutter 3.47.6 defaults are minSdk 24, compileSdk and targetSdk 36 (Android 16). Google Play
  requires new apps and updates to target API 36 from 31 August 2026 (Play Console help, "Target API level
  requirements"; re-check it before each release, it moves every August). Native libraries must also support 16 KB
  memory pages: the NDK in use (28.2) aligns them by default; verify with Google's `check_elf_alignment.sh` on the
  release APK, or Play Console warns.
- **Play Console.** App content: privacy policy URL, Data safety (`store-listing.md`), account-deletion URL, target
  audience (13+ with teens: complete the teen and families questions), ads declaration (none while rewarded ads are off, yes once on, plus the Advertising ID declaration), content rating
  questionnaire, news app (no), government app (no), financial features (none), health (none).

## iOS release readiness (file level; no Xcode was available where this was written)

Already in the repo: `CFBundleDisplayName` `Hiyall`; version keys from Flutter; usage strings for location (when in
use; approximate), photo library, camera and microphone (voice messages, voice notes and videos, only while recording), each stating the real purpose, and none for things the app does not do
(no contacts, Bluetooth, tracking, or saving to the library, so no `NSPhotoLibraryAddUsageDescription`);
no ATS exceptions (HTTPS only); `UIBackgroundModes` is only `remote-notification`;
`ITSAppUsesNonExemptEncryption` is `true` (see Export compliance); `PrivacyInfo.xcprivacy`; the full AppIcon set (opaque,
generated from the brand mark) and a launch storyboard with the brand background and mark; `aps-environment` in
`Runner.entitlements` is `development`, and Xcode writes `production` into the signed archive when it is exported
with an App Store distribution profile, so leave it. The things only Xcode and an Apple account can do, in order:

1. Apple Developer Program membership; create the App ID `app.hiyall.hiyall` with the capabilities **Push
   Notifications** and **Sign in with Apple** (the entitlements file already lists the latter). Create an APNs auth
   key (`.p8`) and upload it to Firebase, Cloud Messaging; create a Sign in with Apple key for the API's `APPLE_*`
   settings.
2. Open `ios/Runner.xcworkspace`, select Runner, Signing & Capabilities: choose the team, leave Automatic signing for
   local work, and confirm the two capabilities show without errors. The deployment target is iOS 15.
3. App Store Connect: create the app (bundle id above, SKU free text), fill the listing from `store-listing.md`,
   answer App Privacy and the encryption questions, set the age rating, add the reviewer notes and an account.
4. **Rehearse the first archive on a Mac before the first tag.** On a Mac, `scripts/build-release.sh ios` signs
   automatically with the Apple account signed in to Xcode. CI has no account, so with `IOS_TEAM_ID` and `IOS_PROFILE_NAME` set (the
   workflow reads both from the installed provisioning profile) the script signs **manually**, and only in CI: it runs
   `flutter build ios --config-only`, writes the git-ignored `ios/Flutter/Signing.xcconfig` (`CODE_SIGN_STYLE=Manual`, team, profile,
   Apple Distribution), which `ios/Flutter/Release.xcconfig` includes, so only the Runner target takes the settings (a command-line
   override would also hit the Swift package targets, which cannot take a profile); it then proves that with `xcodebuild
   -showBuildSettings` (`scripts/ios_signing_check.py`), runs `xcodebuild archive` and `xcodebuild -exportArchive` with
   `ios/ExportOptions.plist`. The Xcode project file is never edited. This path has never run: do it once by hand on a Mac with a
   manual App Store profile (`IOS_TEAM_ID=... IOS_PROFILE_NAME=... CI=true scripts/build-release.sh ios`, then delete
   `ios/Flutter/Signing.xcconfig` if the run was interrupted) and fix what it shows before relying on CI. Or archive with Product > Archive in Xcode. Run Product > Archive > Generate Privacy Report and compare it with
   `PrivacyInfo.xcprivacy` (store-listing.md explains why this matters). Upload through Xcode Organizer or Transporter.
5. TestFlight: install on a real iPhone, sign up with a real email, send a chat photo and receive a push before
   submitting for review.

## Web build

The web app is a companion to the phones. `web/index.html` carries the title, description, theme colour, Open Graph
and Twitter tags, a `noindex` robots tag and `robots.txt` (`Disallow: /`), because it is not a landing page; change both
when a public page is served from the same site. The canonical and Open Graph URLs are filled by
`scripts/build-release.sh web` from `WEB_CANONICAL_URL` (an https URL ending in `/`; the build refuses without it).
`manifest.json` has name, short name, theme and background colours, standard and maskable icons, and a start URL.
Release web builds show no debug banner (`debugShowCheckedModeBanner: false`). Serve with SPA fallback and HTTPS.
