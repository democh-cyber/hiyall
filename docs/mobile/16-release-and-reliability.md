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
`ENABLE_FACEBOOK_LOGIN`, `APPLE_SIGN_IN_WEB`, `APP_ENV`, and in development only `ENABLE_DEV_LOGIN`
(the release script refuses it).

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
