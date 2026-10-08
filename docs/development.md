# Running the Kairova foundation

Implementation was authorized on 7 October 2026. This is the first local vertical slice, not the full MVP or a production deployment.

## Installed toolchains

Tools are installed for this user under `~/.local/share/kairova-tools`; `scripts/env.sh` adds them to the current shell. No administrator password or system package replacement was needed. Versions and downloaded artifact hashes are recorded in `toolchains.lock.json`.

| Tool | Installed version | Use |
|---|---|---|
| Flutter / Dart | 3.47.6 / 3.13.5 | Android/iOS source, web preview, widget tests |
| Go | 1.27.1 | API, migrations, tests |
| Node.js | 24.21.0 | OpenAPI validation and generated TypeScript contracts |
| Temurin Java | 21.0.12.1+1 | Android Gradle builds |
| Android SDK | platforms 36 and 35, build tools 36.0.0, platform-tools | Android build and ADB |
| Android NDK / CMake | 28.2.13676358 / 3.22.1 | Native plugin builds |
| PostgreSQL | 16.15 | Local persistent data and integration tests |
| Redis | 7.0.15 Ubuntu package | Installed for later cache/limits work; not used by this slice |
| GCC / binutils | Ubuntu GCC 13.3, binutils 2.42 | Go race detector with an isolated compiler sysroot |

Flutter is pinned to its official release Git tag, so `flutter doctor` may describe the detached checkout as an unknown channel. The Android toolchain passes its checks. Linux desktop compilers/GTK development packages and a full Android emulator are outside this Android/iOS slice. iOS compiling/signing requires macOS and Xcode and has not been tested here.

## Start locally

From the repository root, start the API in one terminal:

```bash
./scripts/dev-api.sh
```

This initializes and starts PostgreSQL if needed, applies checksum-tracked migrations, creates two local fixture profiles, and binds the API to `127.0.0.1:8080`. The local PostgreSQL socket directory has mode 0700 and is restricted to this OS account. TCP is loopback only and requires SCRAM credentials; no database password is embedded in the repository. The development socket uses local trust for the owning OS account only. This configuration is for local development.

Start the Flutter browser preview in another terminal:

```bash
./scripts/dev-mobile.sh
```

Open `http://127.0.0.1:49321` yourself. Choose Anjali or Niko. Local tokens expire in 30 minutes, are kept in app memory, and are stored as SHA-256 hashes on the server. Refreshing the browser requires signing in again. Signing out revokes the session on the server. Development login requires an explicit flag, a loopback API listener, and a loopback request address; it is disabled in release-mode Flutter builds.

For an Android phone connected through ADB:

```bash
source scripts/env.sh
adb reverse tcp:8080 tcp:8080
cd apps/mobile
flutter run --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

An emulator can use `API_BASE_URL=http://10.0.2.2:8080`. No device/emulator run has been verified. Debug cleartext exceptions are limited to these local addresses. Standard release builds reject cleartext traffic, trust only system CAs, disable Android backup, and require a private release signing configuration. No debug signing fallback is permitted for release.

## Full UI design studio

The [Gen Z experience specification](ux/08-gen-z-experience.md) establishes the brand, tokens, flows, screen inventory and high-fidelity concepts. Open `/#/design` or select **Explore the full design** from Welcome/Profile/Home to browse all 58 screen designs across every requested screen family. The `tool/export_brand_assets_test.dart` utility regenerates Android/iOS icon rasters from the Flutter vector mark. The Home creation star opens Post/Story/Vibe/Poll/Question/Event/Community layouts. These are labeled design previews with sample content, session-only selections and temporary forms; they do not invoke unimplemented APIs. Chat sending, recording, camera access, publication, provider login and calls are disabled. The existing main app profile/privacy/session features remain connected to the API.

## Working behavior

- Five redesigned destinations, floating bottom navigation on phones, a desktop sidebar, locally bundled Space Grotesk/Manrope fonts, original vector artwork, and light/dark themes. Responsive tests traverse all eight implemented routes at 320, 390 and 1440 pixels wide with normal and 200% text scaling.
- Own profile read/update with validated, bounded fields, unique usernames, and optimistic version checks. The Flutter form edits display name, username, bio and profession; the API supports the other non-media profile fields.
- Privacy read/update, private defaults, explicit Save, nested field-audience merging, and profile/privacy audience synchronization. Offline/failed saves never show success; stale edits require reload.
- Viewer-specific profile projections with the viewer's relationship, hidden-field omission and bidirectional blocks. `public`, `friends` and `followers` audiences are enforced for profiles and each field (friends count as followers). When the audience excludes the viewer, the profile is a locked card with only identity, style and relationship, so the viewer can still follow or send a request.
- [Follows, friend requests, connection lists and activity](api/13-social-and-activity.md): follow policies (everyone, approval, nobody), follow requests, removing followers, friend requests under `requestsFrom` with crossing-request acceptance and a 7-day cooldown after a decline, unfriending, privacy-gated friends/followers/following lists, and a recipient-only activity feed with read state. Blocking ends follows, friendships, pending requests and the activity between the pair; unblocking restores nothing.
- Owned session pagination with signed, expiring cursors; current-session logout and revocation of another owned session. Last-seen timestamps are recorded; platform remains `unknown` until trusted device registration exists.
- API authentication boundary: signature/issuer/audience/expiry verification for configured OIDC access JWTs, explicit access-token semantics and a required `sid`. ID tokens are rejected. Revoked provider session IDs cannot be recreated with still-valid tokens.
- Temporary discovery filters, live public-field search, signed principal/query-bound pagination, bidirectional block exclusion, and a server-enforced trusted adult-eligibility gate. No result totals or saved search defaults are fabricated.
- Transactional outbox records profile/privacy/block/follow/friendship changes with a per-user ordering clock. No worker/queue consumer is implemented yet.
- Rate limits are per client address before authentication, per account for search and relationship writes, and an instance-wide backstop. Each table is bounded and evicts the least recently used key, so a flood of new keys cannot lock out existing clients. Behind a proxy, limit per real client there; forwarded headers are not trusted.

To exercise profile visibility, sign in as Niko, make the profile Public, choose which fields are visible to Everyone, and save. Sign out, sign in as Anjali, then view Niko from Discover. Blocking makes the profile unavailable; the same screen offers removal of your block. The separate Find people flow now invokes real privacy-aware search with interests, vibe, languages, and country filters. Search requires trusted adult eligibility for the viewer and candidates, public profiles, discovery opt-in, and field audiences. Development accounts are not granted eligibility automatically. To try Discover locally, run `./scripts/seed-demo-people.sh` after the API has started once: it adds 16 public, opted-in demo people (usernames start with `demo_`) and marks them plus Anjali and Niko as adults in the local `kairova` database only. The script refuses any other database and is safe to re-run. Age-assurance provisioning and relationship/contact creation are still pending; see [people discovery and its eligibility boundary](ux/12-people-discovery.md).

Optional fields are currently stored in validated JSONB, with usernames, resource versions, identity, session and block keys in typed/indexed columns. The broader normalized/partitioned schema in the database design is a roadmap. This foundation schema has not been load-tested.

## Encrypted chat

Chat runs in the Android and iOS apps (web shows a notice). See [the encrypted chat implementation record](security/13-encrypted-chat-implementation.md). To try it on the emulator with Niko as a second device on this machine:

```bash
./scripts/dev-api.sh                      # terminal 1
emulator -avd kairova                     # terminal 2 (after: source scripts/env.sh)
cd apps/mobile && adb reverse tcp:8080 tcp:8080 && flutter run -d emulator-5554 --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
cd apps/mobile && dart run tool/chat_peer.dart --as niko --listen 300   # Niko's device; --to anjali --send "hi" to reply
```

Anjali and Niko must be allowed to message each other (friends by default). The Rust core needs `cargo build --release` in `apps/mobile/rust` for the command-line peer and live test.

## Checks

Create the dedicated test database once after starting PostgreSQL:

```bash
source scripts/env.sh
createdb -h "$PWD/.runtime/pgsocket" -p 55432 -U kairova kairova_test
./scripts/check.sh
```

Skip `createdb` if that database already exists. Tests require the database name `kairova_test` and truncate only that dedicated database. `TEST_DATABASE_URL` can point to an equivalent disposable PostgreSQL instance with that name. Running bare `go test` without it skips API integration tests; the check script requires the database.

Checks cover input/identity rejection, production configuration guards, verified JWT boundaries, stale/racing edits, atomic outbox writes, field visibility, blocks, owned revocation, revoked provider sessions and principal-bound cursors. Flutter tests cover navigation, disabled chat, explicit/failed privacy saves, unblock behavior, expired-session recovery, failed logout, small/desktop screens, both appearances and large text. Optional `--dart-define=CAPTURE_DESIGN=true` on `test/design_preview_test.dart` saves local fixture renders under `.runtime/design-previews`; selected renders were inspected during the redesign. A separate live-client test passed against the running API, including logout and token rejection. OpenAPI CLI validation and generated TypeScript contracts cover the implemented API subset. `govulncheck` found a transitive `golang.org/x/text` issue; the dependency was upgraded to v0.39.0 and the repeated scan reported no known vulnerabilities. See [the Go advisory](https://pkg.go.dev/vuln/GO-2026-5970). Node tooling audit reported no known vulnerabilities. These scans are limited to their covered dependencies. GitHub Actions workflow is supplied but has not run remotely.

The [foundation OpenAPI contract](api/openapi-foundation.json) describes implemented routes. [The MVP contract](api/openapi-mvp.json) remains a draft roadmap; it does not imply all 116 operations exist. `npm run contracts:build` regenerates the foundation contract and TypeScript declarations; `npm ci` restores pinned tooling.

To repeat the live Flutter client check while the local API is running:

```bash
source scripts/env.sh
cd apps/mobile
flutter test test/api_live_test.dart --dart-define=RUN_LIVE_API_TEST=true --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

## Remaining work and release boundary

The Flutter production sign-in flow, provider setup, recovery, account lifecycle, device registration, encrypted local cache, key storage/lifecycle, certificate pins and pin rotation, and reviewed E2EE protocol integration are pending. The secure-storage dependency is installed but is not used for local fixture tokens. No plaintext chat route or chat composer exists. Messaging stays disabled until the encryption integration and verification are complete.

Posts, stories, uploads, social graph, interest matching, notifications, admin tooling, workers, distributed rate limiting, production observability and cloud deployment are future slices. Saved preferences for those features are not claims of active feature enforcement. The API's global in-process request budget is a local guard, not a distributed abuse-control system.

Production API startup rejects dev authentication, non-HTTPS OIDC and database connections without `sslmode=verify-full`. It still requires a correctly configured HTTPS ingress, trusted provider access tokens, managed secrets, encrypted disks/backups, per-user/distributed limits, monitoring and deployment validation. Profile/public social data and routing metadata are server-visible; end-to-end encryption will protect private chat content. Traffic cannot be made invisible on a compromised endpoint.

Android debug APK and browser debug/release builds passed. A release web bundle built with `ENABLE_DEV_LOGIN=true` contained none of the development login labels; the compile-time debug guard removes those controls. The browser preview builds successfully. Automated browser access was declined by browser security policy; no browser visual/interactivity review was completed. Native iOS builds, Android device runs, proxy/pin bypass tests, independent security review and capacity tests remain unverified.
