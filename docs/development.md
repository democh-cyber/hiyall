# Running the Hiyall foundation

Implementation was authorized on 7 October 2026. This is the first local vertical slice, not the full MVP or a production deployment.

## Installed toolchains

Tools are installed for this user under `~/.local/share/hiyall-tools`; `scripts/env.sh` adds them to the current shell. No administrator password or system package replacement was needed. Versions and downloaded artifact hashes are recorded in `toolchains.lock.json`.

| Tool | Installed version | Use |
|---|---|---|
| Flutter / Dart | 3.47.6 / 3.13.5 | Android/iOS source, web preview, widget tests |
| Go | 1.27.2 | API, migrations, tests |
| Node.js | 24.21.0 | OpenAPI validation and generated TypeScript contracts |
| Temurin Java | 21.0.12.1+1 | Android Gradle builds |
| Android SDK | platforms 36 and 35, build tools 36.0.0, platform-tools | Android build and ADB |
| Android NDK / CMake | 28.2.13676358 / 3.22.1 | Native plugin builds |
| PostgreSQL | 16.15 | Local persistent data and integration tests |
| Redis | 7.0.15 Ubuntu package | Installed on the Linux toolchain only; the API does not use Redis (limits and the realtime bus use PostgreSQL) |
| GCC / binutils | Ubuntu GCC 13.3, binutils 2.42 | Go race detector with an isolated compiler sysroot |

Flutter is pinned to its official release Git tag, so `flutter doctor` may describe the detached checkout as an unknown channel. The Android toolchain passes its checks. Linux desktop compilers/GTK development packages and a full Android emulator are outside this Android/iOS slice. iOS compiling/signing requires macOS and Xcode and has not been tested here.

## Start locally

From the repository root, start the API in one terminal:

```bash
./scripts/dev-api.sh
```

This initializes and starts PostgreSQL if needed, applies checksum-tracked migrations, creates three local fixture profiles (Anjali, Niko and Sam), and binds the API to `127.0.0.1:8080`. The local PostgreSQL socket directory has mode 0700 and is restricted to this OS account. TCP is loopback only and requires SCRAM credentials; no database password is embedded in the repository. The development socket uses local trust for the owning OS account only. This configuration is for local development.

Start the Flutter browser preview in another terminal:

```bash
./scripts/dev-mobile.sh
```

Open `http://localhost:49321` yourself. (This applies to the fixture-account mode. If `config/firebase.local.json` exists, the scripts use real Firebase sign-in instead and the fixture accounts are hidden; run both scripts with `HIYALL_DEV_LOGIN=1` to get them back.) Choose Anjali or Niko, who are already onboarded, or Sam, whose onboarding is not finished (see [Sign-in and onboarding](#sign-in-and-onboarding)). Local tokens expire in 30 minutes, are kept in app memory, and are stored as SHA-256 hashes on the server. Refreshing the browser requires signing in again. Signing out revokes the session on the server. Development login requires an explicit flag, a loopback API listener, and a loopback request address; it is disabled in release-mode Flutter builds.

For an Android phone connected through ADB:

```bash
source scripts/env.sh
adb reverse tcp:8080 tcp:8080
cd apps/mobile
flutter run --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

An emulator can use `API_BASE_URL=http://10.0.2.2:8080`. No device/emulator run has been verified. Debug cleartext exceptions are limited to these local addresses. Standard release builds reject cleartext traffic, trust only system CAs, disable Android backup, and require a private release signing configuration. No debug signing fallback is permitted for release.

## Design reference

The [Gen Z experience specification](ux/08-gen-z-experience.md) establishes the brand, tokens, flows, screen inventory and high-fidelity concepts. The in-app design gallery that previewed unbuilt screens with sample content has been removed; every screen in the app is now connected to the API. The `tool/export_brand_assets_test.dart` utility regenerates Android/iOS icon rasters from the Flutter vector mark.

## Working behavior

- Five redesigned destinations, floating bottom navigation on phones, a desktop sidebar, locally bundled Space Grotesk/Manrope fonts, original vector artwork, and light/dark themes. Responsive tests traverse all eight implemented routes at 320, 390 and 1440 pixels wide with normal and 200% text scaling.
- Own profile read/update with validated, bounded fields, unique usernames, and optimistic version checks. The Flutter form edits display name, username, bio and profession; the API supports the other non-media profile fields.
- Privacy read/update, open defaults (public and discoverable, anyone may message and follow, followers and following lists open to followers (friends only for minors), the friends list friends-only), explicit Save, nested field-audience merging, and profile/privacy audience synchronization. Offline/failed saves never show success; stale edits require reload.
- Viewer-specific profile projections with the viewer's relationship, hidden-field omission and bidirectional blocks. `public`, `friends` and `followers` audiences are enforced for profiles and each field (friends count as followers). When the audience excludes the viewer, the profile is a locked card with only identity, style and relationship, so the viewer can still follow or send a request.
- [Encrypted chat attachments](api/21-chat-attachments.md) (server side, migration `0023`): end-to-end encrypted image blobs in a separate bucket with quotas, 30-day retention and evidence hold; the app and the Rust crypto are separate steps.
- [Profile photos](api/20-profile-photos.md): one avatar per member through the photo pipeline (`purpose: avatar`, then `avatarMediaId` on `PATCH /v1/me/profile`), shown as a signed `avatarUrl` thumbnail wherever a person appears and `avatarFullUrl` on profiles. Migration `0022` only widens the media purpose constraint.
- [Follows, friend requests, connection lists and activity](api/13-social-and-activity.md): follow policies (everyone, the default and instant; approval and nobody for members who set them), follow requests, removing followers, friend requests under `requestsFrom` with crossing-request acceptance and a 7-day cooldown after a decline, unfriending, privacy-gated friends/followers/following lists, and a recipient-only activity feed with read state. Blocking ends follows, friendships, pending requests and the activity between the pair; unblocking restores nothing.
- Owned session pagination with signed, expiring cursors; current-session logout and revocation of another owned session. Last-seen timestamps are recorded; platform remains `unknown` until trusted device registration exists.
- API authentication boundary: signature/issuer/audience/expiry verification for configured OIDC access JWTs, explicit access-token semantics and a required `sid`. ID tokens are rejected in generic OIDC mode. With `FIREBASE_PROJECT_ID` the API instead verifies Firebase ID tokens and derives the session id from `sub` and `auth_time`. Revoked provider session IDs cannot be recreated with still-valid tokens.
- [Server-enforced onboarding](api/18-accounts-and-onboarding.md): a new account can only edit its profile and privacy, check usernames and manage sessions until it declares a birth date making it 13 or over (`domain.MinimumAge`) and accepts the terms; every other route, including realtime, answers `403 ONBOARDING_REQUIRED`. The declaration is not age assurance; the birth date is stored privately once (`member_ages`) and puts the member in the minor or adult age band, and is never returned, logged or put in an event; only the age in whole years is shown, on another member's profile (default audience everyone).
- Temporary discovery filters, live public-field search, signed principal/query-bound pagination and bidirectional block exclusion over every onboarded, discoverable, public member; the old adult-eligibility gate is retired. No result totals or saved search defaults are fabricated.
- [Age bands](api/19-nearby-and-open-access.md#age-bands): minors (under 18) and adults are kept apart on every path that checks blocks (`AGE_BAND_ISOLATION`, default `true`; `false` is block-only), minors get stricter defaults and a coarser location, and people search and Nearby take `ageMin`, `ageMax` and `gender` filters. `gender` is an optional profile field with its own audience. The dev account `Kai` (`/dev/session`) is a 15-year-old minor; the barrier is why Anjali and Kai cannot see each other.
- [Open profiles, presence and Nearby](api/19-nearby-and-open-access.md): new accounts are public and discoverable (privacy defaults changed and migration `0016` rewrote existing rows), `online` shows only for members who allow it and are connected, and `PUT/GET/DELETE /v1/me/location` plus `POST /v1/discover/nearby` (people-search filters and a radius in the body) give a grid-rounded, 24-hour, bucketed Nearby list; the app sends the position automatically, so in practice the OS permission is the only opt-in. Read its safety note before enabling Nearby for real users.
- No outbox: the API used to write an `outbox_events` row (and bump `users.aggregate_version`) on every profile, privacy, block, follow and friendship change, but nothing ever consumed them, so since migration 0037 nothing writes them. The table and the column stay for one more release (expand, then contract); an hourly "outbox purge" job deletes rows older than 7 days; a later migration drops both. When a consumer (search indexing, webhooks) is needed, add the outbox back together with that consumer.
- Rate limits are per client address before authentication, per account for search and relationship writes, and an instance-wide backstop. Each table is bounded and evicts the least recently used key, so a flood of new keys cannot lock out existing clients. Behind a proxy, limit per real client there; forwarded headers are not trusted.

Profiles are public by default. To exercise a restricted profile, sign in as Niko, make the profile Friends only or hide fields, and save. Sign out, sign in as Anjali, then view Niko from Discover. Blocking makes the profile unavailable; the same screen offers removal of your block. The separate Find people flow now invokes real privacy-aware search with interests, vibe, languages, and country filters. Search needs only an onboarded member and finds public, discoverable profiles by their field audiences; there is no eligibility step. To try Discover locally, run `./scripts/seed-demo-people.sh` after the API has started once: it adds 16 public, opted-in, onboarded demo adults (aged 18 to 40, mixed genders) and two demo minors (`demo_minor_mika`, `demo_minor_noor`) in the local `hiyall` database only. The script refuses any other database and is safe to re-run. To try Nearby, run `./scripts/seed-demo-nearby.sh [LAT LON]` (default 12.9716 77.5946) after that: it places Anjali, Niko, Kai and the demo people between about 0.5 and 40 km from the centre with already-rounded coordinates and a fresh timestamp (a shared point counts for 24 hours, so run it again when Nearby goes quiet); it also refuses any other database. Share your own location from the app with the same point. Age assurance is not implemented; see [people discovery](ux/12-people-discovery.md) and the [safety note](api/19-nearby-and-open-access.md#safety-note-for-the-owner). To see online dots and "last seen", run `./scripts/seed-demo-presence.sh` (after the demo people exist): it gives each adult demo person a session with a spread of last activity (several under two minutes, so they show as online, the rest minutes to days ago, two never seen) and sets their `onlineAudience` to `everyone`; minors are never touched. Presence is real server data, so "online" only lasts about two minutes after the run: run it again, or `./scripts/seed-demo-presence.sh --keep`, which refreshes every 45 seconds until Ctrl-C. `--also anjali,niko` includes those accounts too (they get a tagged `demo-presence` session row, which also appears in that account's session list). It refuses any database other than `hiyall`; `DEMO_DB=hiyall_test` dry-runs it against the test database. To fill a member's Activity tab, Followers, Friends, Visitors and Pulse with realistic activity from the demo people, run `./scripts/seed-demo-activity.sh [USERNAME]` (default `demochannelsh_868`; the member must be an adult). It adds followers, friend requests waiting for an answer, one accepted friendship, profile visitors and two starter posts from the member with reactions and comments, writing the rows, counters and notifications the way the API does. It is safe to re-run (it refreshes the notifications as unread) and refuses any database other than the local `hiyall`.

Optional fields are currently stored in validated JSONB, with usernames, resource versions, identity, session and block keys in typed/indexed columns. The broader normalized/partitioned schema in the database design is a roadmap. This foundation schema has not been load-tested.

## Encrypted chat

Chat runs in the Android and iOS apps (web shows a notice). See [the encrypted chat implementation record](security/13-encrypted-chat-implementation.md). To try it on the emulator with Niko as a second device on this machine:

```bash
./scripts/dev-api.sh                      # terminal 1
emulator -avd hiyall                     # terminal 2 (after: source scripts/env.sh)
cd apps/mobile && adb reverse tcp:8080 tcp:8080 && flutter run -d emulator-5554 --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
cd apps/mobile && dart run tool/chat_peer.dart --as niko --listen 300   # Niko's device; --to anjali --send "hi" to reply
```

Anjali and Niko can message each other without being friends (messaging is open by default). Sending photos needs a second Cloudflare R2 bucket, `hiyall-chat`, with its own bucket-scoped token: copy `config/chat-media.example.env` to `config/chat-media.local.env` (git-ignored) and fill in the two keys; `scripts/dev-api.sh` loads it like `media.local.env` and prints `Chat photos: …` without showing a secret. Without it the attachment routes answer `503 CHAT_MEDIA_UNAVAILABLE`. With it, `python3 scripts/chat-blob-e2e.py --yes` checks the whole server side against the real bucket (it adds a few junk messages for Anjali and Niko and two throw-away devices; see the script's header). `python3 scripts/media-e2e.py --yes` does the same for public photo slots (post and avatar; it proves the signed URL pins the exact size and content type). See [encrypted chat attachments (API)](api/21-chat-attachments.md). The Rust core needs `cargo build --release` in `apps/mobile/rust` for the command-line peer and live test.

### Rust core and bridge regeneration

Rust checks, from `apps/mobile/rust` after `source scripts/env.sh`: `cargo fmt && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked`. `rustfmt.toml` there matches the existing layout. `rustfmt`, `clippy` and `cargo-expand` are installed into the toolchain (`rustup component add rustfmt clippy`; the code generator installs `cargo-expand` itself on first use).

After changing a `pub` function or type under `apps/mobile/rust/src/api`, regenerate the Dart and Rust glue and commit the result: `cd apps/mobile && flutter_rust_bridge_codegen generate` (configuration in `flutter_rust_bridge.yaml`; output in `lib/src/rust` and `rust/src/frb_generated.rs`). The code generator must be exactly the version of `flutter_rust_bridge` in `rust/Cargo.toml` and `pubspec.yaml` (2.13.0); it is installed with `cargo install flutter_rust_bridge_codegen --version '=2.13.0' --locked` into `~/.local/share/hiyall-tools/cargo/bin` and recorded in `toolchains.lock.json`. Dependency licences are listed in [the E2EE library evaluation](security/12-e2ee-library-evaluation.md).

## Checks

Create the dedicated test database once after starting PostgreSQL:

```bash
source scripts/env.sh
createdb -h "$PWD/.runtime/pgsocket" -p 55432 -U hiyall hiyall_test
./scripts/check.sh
```

Skip `createdb` if that database already exists. Tests require the database name `hiyall_test` and truncate only that dedicated database. `TEST_DATABASE_URL` can point to an equivalent disposable PostgreSQL instance with that name. Running bare `go test` without it skips API integration tests; the check script requires the database.

Checks cover input/identity rejection, production configuration guards, verified JWT boundaries, stale/racing edits, racing profile edits committing once, field visibility, blocks, owned revocation, revoked provider sessions and principal-bound cursors. Flutter tests cover navigation, disabled chat, explicit/failed privacy saves, unblock behavior, expired-session recovery, failed logout, small/desktop screens, both appearances and large text. Optional `--dart-define=CAPTURE_DESIGN=true` on `test/design_preview_test.dart` saves local fixture renders under `.runtime/design-previews`; selected renders were inspected during the redesign. A separate live-client test passed against the running API, including logout and token rejection. OpenAPI CLI validation and generated TypeScript contracts cover the implemented API subset. `govulncheck` found a transitive `golang.org/x/text` issue; the dependency was upgraded to v0.39.0 and the repeated scan reported no known vulnerabilities. See [the Go advisory](https://pkg.go.dev/vuln/GO-2026-5970). Node tooling audit reported no known vulnerabilities. These scans are limited to their covered dependencies. GitHub Actions workflow is supplied but has not run remotely.

The [foundation OpenAPI contract](api/openapi-foundation.json) describes implemented routes. [The MVP contract](api/openapi-mvp.json) remains a draft roadmap; it does not imply all 116 operations exist. `npm run contracts:build` regenerates the foundation contract and TypeScript declarations; `npm ci` restores pinned tooling.

To repeat the live Flutter client check while the local API is running:

```bash
source scripts/env.sh
cd apps/mobile
flutter test test/api_live_test.dart --dart-define=RUN_LIVE_API_TEST=true --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

## Remaining work and release boundary

**What exists.** Sign-in (Firebase) and onboarding, profiles and privacy, blocks and reports, Discover, Nearby, follows and connections, Pulse, Spaces, presence, and one-to-one chat: end-to-end encrypted text (Olm through the Rust core `apps/mobile/rust`) and end-to-end encrypted photos stored as ciphertext in a separate bucket, with a realtime WebSocket and an HTTP fallback. The server never sees chat plaintext or keys. Every limit (messages, first chats, uploads, reports, locations, and so on) is enforced by the API, not the client. Operations basics exist: `/healthz` and `/readyz`, Prometheus metrics on a separate listener, panic recovery with request ids, one-instance-at-a-time hourly cleanup, optional database-shared rate limits, a container image and CI that builds it ([deploy guide](deployment/10-deploy-guide.md)).

**What is verified.** The Go API (unit and PostgreSQL integration tests under the race detector), the Rust crypto core (unit tests and published vectors), Flutter analysis and widget tests, and the contract checks. The chat photo path ran end to end against a real Cloudflare R2 bucket. An Android debug APK and a release web bundle build. This is automated verification on one developer machine, not production evidence.

**What is not verified or not built.** No real Firebase sign-up, and no chat session between two real devices, has been run end to end yet. The E2EE design and code have had no independent review; treat the privacy claims as unaudited until one is done. Certificate pinning is not implemented, and how chat keys are held on the device has had no review beyond use of the platform secure store. There has been no load or capacity test, and nothing is deployed. Push delivery (the FCM sender and app registration are built) and account deletion and export have not run on a real device or against real Firebase; the admin and moderation console is built (`docs/security/15-admin-console.md`) but the people to staff it do not exist yet. All must be exercised and reviewed before launch. The Terms of Service and Privacy Policy under `docs/legal` are drafts without legal review. Feed, search infrastructure (OpenSearch), Redis, separate workers and multi-region are not built and are not needed at the current scale.

**Production start-up rules.** The API rejects dev authentication, a non-HTTPS OIDC issuer (Firebase mode is HTTPS by construction), a database URL without `sslmode=verify-full`, and a metrics listener that is reachable from outside without a token. It still depends on a correctly configured HTTPS ingress, managed secrets, encrypted disks and backups with a tested restore, monitoring and alerting, and a deployment you have rehearsed. Profile data and routing metadata are server-visible; only chat content is end-to-end encrypted, and traffic cannot be made invisible on a compromised device.

Android debug APK and browser debug/release builds passed. A release web bundle built with `ENABLE_DEV_LOGIN=true` contained none of the development login labels; the compile-time debug guard removes those controls. The browser preview builds successfully. Automated browser access was declined by browser security policy; no browser visual/interactivity review was completed. Native iOS builds, Android device runs, proxy/pin bypass tests, independent security review and capacity tests remain unverified.

## Sign-in and onboarding

Production sign-in uses Firebase Authentication. Set `FIREBASE_PROJECT_ID` (4-64 lowercase letters, digits or hyphens) instead of `OIDC_ISSUER`/`OIDC_AUDIENCE`; the issuer becomes `https://securetoken.google.com/<id>` and the audience `<id>`. Clients send the Firebase ID token as `Authorization: Bearer <idToken>` on every request. Anonymous and custom-token sign-ins are rejected, and a password sign-in needs a verified email (`403 EMAIL_NOT_VERIFIED`, nothing provisioned). The first valid token creates the account with a generated `member_...` username and an incomplete onboarding row. The full contract, session-id derivation, gating table and error codes are in [accounts and onboarding](api/18-accounts-and-onboarding.md). This path is covered by tests that sign tokens locally; it has not been run against a real Firebase project. To connect a project, run `firebase login` and then `./scripts/firebase-setup.sh <project-id>`. The script registers the apps, turns on Email/Password and Google sign-in, and writes the git-ignored `config/firebase.local.json` that `dev-api.sh` and `dev-mobile.sh` read; see [sign-in and onboarding](mobile/14-sign-in-and-onboarding.md#supplying-the-firebase-project).

`./scripts/dev-api.sh` seeds **Sam** (`019a4000-0000-7000-8000-0000000000a1`) next to Anjali and Niko. Sam has the default placeholders (username `member_0000000000a1`, name "Hiyall member") and an incomplete onboarding row, so `POST /dev/session` with Sam's id exercises the first-run flow: everything except profile, privacy, username checks, onboarding and sessions answers `403 ONBOARDING_REQUIRED` until a real username and name are saved and `POST /v1/me/onboarding/complete` succeeds. Seeding never completes Sam; the reset statements are in the accounts document. Accounts that existed before migration `0015_onboarding.sql` were backfilled as complete, and `scripts/demo-people.sql` creates complete rows for its demo people. To repeat the first-run flow after finishing it, run `./scripts/reset-sam.sh`, which turns Sam back into a new member in the local `hiyall` database.

## Shared spaces (Phase 6)

Discover → Circles or Moments (or Find your circle at `/#/spaces`) opens shared spaces, open to every onboarded member.
Use `./scripts/seed-demo-spaces.sh` after starting `./scripts/dev-api.sh` to add
local Anjali/Niko communities, a one-hour Moment and an upcoming event. Fixtures
are idempotent and require the local `hiyall` database and the existing Anjali and Niko
development accounts. Expired demo Moments stay read-only; the host can extend their schedule.

Run `./scripts/check.sh` for the whole repository, including shared-space
admission, role hierarchy, reporting and concurrent-capacity integration tests.
Details and current feature limits are in `docs/api/17-shared-spaces.md`.
Shared discussions are readable by members and the service; private
conversation continues through the existing E2EE chat.

## Moderation console

`./scripts/dev-admin.sh` migrates the dev database, builds `apps/admin` and serves the staff console on `http://127.0.0.1:8081` (loopback only). Create the first operator once with `./scripts/dev-admin.sh operator-add -email you@example.com -role admin` (password prompt; it prints an authenticator secret once). Root shortcuts: `npm run admin:install`, `npm run admin:build`, `npm run admin:test`. Design and deployment: [Admin console](security/15-admin-console.md). Its Go integration tests use a second database: `createdb hiyall_test_admin`, run `go run ./cmd/migrate` against it, and set `ADMIN_TEST_DATABASE_URL` (or keep `TEST_DATABASE_URL` pointing at `hiyall_test`, from which the name is derived); without it they skip locally, in CI they must run. The illegal-content procedure is [16](security/16-csam-and-illegal-content.md).

Release builds (`scripts/build-release.sh android|ios|web`, which refuses missing configuration; `scripts/test-build-release.sh` checks that), error reporting, the 426 version gate, deep links, export compliance and licences are described in [release builds and reliability (app)](mobile/16-release-and-reliability.md); store privacy answers are in [store listings](mobile/store-listing.md). Events and Moments are off in V1: `--dart-define=ENABLE_EVENTS=true` on the app and `SPACES_EVENTS_ENABLED=true` on the API turn them back on.
