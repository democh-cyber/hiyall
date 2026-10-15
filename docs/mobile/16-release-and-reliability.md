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
bearer tokens, JWTs, emails and ids are masked in every message; console/print breadcrumbs and anything that
mentions a chat or conversation are dropped.

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
identity-provider session ends on the device regardless. The `signOutHooks` list (push token removal, chat
wipe) runs first and a failing hook no longer blocks sign-out.

## Deep links

A location the person was sent away from (a notification, a shared link, a web URL) is remembered through
splash, welcome, log in, verify-email and onboarding and opened afterwards instead of Home
(`lib/core/deep_link.dart`). Unknown links show a branded "This page wandered off" page. Back from Sign up and
Log in returns to Welcome (they are pushed).

**Owner steps for real Universal Links / App Links** (the app handles the routes; the platforms need proof
of domain ownership, which needs the final domain):

- Android: add intent filters with `android:autoVerify="true"` for `https://<domain>` in
  `android/app/src/main/AndroidManifest.xml`, and host `https://<domain>/.well-known/assetlinks.json`
  listing package `app.hiyall.hiyall` and the release signing key's SHA-256.
- iOS: add the Associated Domains capability (`applinks:<domain>`) to `Runner.entitlements`, and host
  `https://<domain>/.well-known/apple-app-site-association` with the team id + bundle id and the paths to open.
- Web: serve the Flutter build with SPA fallback (every path returns `index.html`) so a deep link reloads.

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
migrations, (k) OpenAPI contract, (l) `go vet` and `govulncheck`, (m) the release workflow touches no dev script.
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
  audience (13+ with teens: complete the teen and families questions), ads declaration (none), content rating
  questionnaire, news app (no), government app (no), financial features (none), health (none).

## iOS release readiness (file level; no Xcode was available where this was written)

Already in the repo: `CFBundleDisplayName` `Hiyall`; version keys from Flutter; usage strings for location (when in
use; approximate), photo library and camera, each stating the real purpose, and none for things the app does not do
(no microphone, contacts, Bluetooth, tracking, or saving to the library, so no `NSPhotoLibraryAddUsageDescription`);
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
4. Build the archive with `scripts/build-release.sh ios` (the CI job does, after importing the certificate and
   profile), or Product > Archive in Xcode. Run Product > Archive > Generate Privacy Report and compare it with
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
