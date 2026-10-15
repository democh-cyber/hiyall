# V1 release runbook

**Status, 15 October 2026.** Written, not rehearsed: the workflow, the stores and the production environment have
never been used. Rehearse the builds first with **Actions > Release dry run** (no secrets; see step 4). Every step marked **owner** needs an account, credential or decision only the owner has; the
repository cannot do it. The order matters: later steps assume earlier ones passed. Companion pages: the
[deploy guide](10-deploy-guide.md) (how the API runs, incidents, rollback of the API), [environments](11-environments.md)
(what to create), [release and reliability (app)](../mobile/16-release-and-reliability.md) (build, signing, versions) and
[store listings](../mobile/store-listing.md) (privacy label, Data safety, listing fields).

## 0. What the owner must have supplied before step 1

The preflight fails loudly on each of these; nothing in the repository fakes them.

| Item | Where it goes | Preflight gate |
| --- | --- | --- |
| Final legal text (Terms, Privacy, Children and Teens, Community Guidelines, Data Retention) with company name, address, dates, contacts, retention periods; a new terms version | `docs/legal/*` copied to `apps/mobile/assets/legal/`; version in the documents, `legal_documents.dart`, `domain.TermsVersion` | b |
| Mobile release inputs: API URL, Firebase ids and key, Sentry DSN, store URLs, three real mailboxes | `config/mobile-release.production.local.env` (git-ignored) or GitHub variables and secrets | c |
| Production API environment and key files (cursor key, Firebase admin and FCM service accounts, Apple key, upload scanner list or provider) | platform secret store; for the local check `config/api.production.env` and `config/secrets/` (both git-ignored) | d |
| Android upload keystore and `key.properties` (CI: four secrets) | `apps/mobile/android/key.properties` | e |
| Apple Developer account, App ID with Push and Sign in with Apple, APNs key, distribution certificate and profile (CI: three secrets) | Xcode, App Store Connect, GitHub secrets | r (CI) |
| Which mobile platforms ship: the repository variable `RELEASE_PLATFORMS` (default `android,ios`). A listed platform must have its signing secrets; an unlisted one is skipped on purpose | GitHub variables | e, r |
| The GitHub `production` environment with required reviewers (and optionally the `RELEASE_GATE_TOKEN` secret so the check can read it) | GitHub Settings > Environments | o |
| Real GitHub owner and security contact | `.github/CODEOWNERS`, `SECURITY.md` | h |
| Foundation checks green on the commit that is tagged | GitHub Actions | n |
| Photo scanning: a hash list or provider, **or** the written acknowledgement below | API environment | q, d |
| A production Firebase project and buckets that are not the development ones | `config/environments.json` lists the development values | c, d |
| Store listing fields, privacy answers, reviewer accounts | `docs/mobile/store-listing.md` | i |
| Production Firebase project, buckets, database, DNS and TLS, separate from development | [environments](11-environments.md) | d |
| Moderator on call, CSAM runbook owner, hash-list or scanning provider | `docs/security/16-csam-and-illegal-content.md` | d (scanner), q |
| Database roles and grants (`database/roles/roles.sql` once, then `grants.sql` after every migration; the release step does the second) | production database | see steps 2 and 6 |
| Independent review of the end-to-end encryption | external | none (a go/no-go decision) |

**Photo scanning, the written acknowledgement.** Production refuses to start without an upload scanner unless
`SCAN_ALLOW_NONE=true`. A release with that switch on passes the preflight only when you also set
`RELEASE_ACK_UNSCANNED=I_ACCEPT_UNSCANNED_PHOTOS` (gate q; in GitHub as repository variables `SCAN_ALLOW_NONE` and
`RELEASE_ACK_UNSCANNED`, mirrors of the production setting). It is a deliberate decision of yours: the draft release
notes print "UNSCANNED PHOTOS ACKNOWLEDGED", and gate q fails while any line of the store listing or of the review notes below that
carries the hidden scanned-claim comment still says photos are scanned. The legal texts carry a `[COUNSEL: scanning status
at launch ...]` placeholder that gate b refuses until counsel has chosen the true wording.

## 1. Preflight

On the commit to be released, on `main`, pushed:

```bash
scripts/check.sh               # the heavy suites: Go with the race detector, Rust, Flutter analyse and tests, contracts
scripts/release-preflight.sh   # every release gate, each with its one-line fix; exits non-zero until all pass
```

`release-preflight.sh` only gates. Fix every `[FAIL]` and run it again; do not tag while it fails. Its own tests run with
`python3 scripts/test-release-preflight.py` (placeholder patterns, dev-identifier reuse, check-run and environment checks,
the scanning acknowledgement, env-docs drift). Gates n (Foundation checks green on the tagged commit) and o (the `production`
environment has reviewers) call `gh api`: in CI they use the workflow token and fail or report `NOT VERIFIED` as the
environment page describes; locally they print `NOT VERIFIED` without a logged-in `gh`, and then you confirm both by hand.
Gate p fails when an environment variable the Go code reads is not in an example env file (`python3 scripts/check_env_docs.py`).
Gate l fails in CI when `govulncheck` is missing (the workflow installs it) unless `PREFLIGHT_SKIP_GOVULNCHECK=1`. Gate d needs the
production environment as a file on your machine; if you would rather not keep one, skip it (`PREFLIGHT_SKIP=d`,
printed as SKIPPED) and run the same server check on the deployed machine in step 2 and again in step 6. The release
workflow runs this script as its first job (`release-preflight`) with gate d skipped for that reason.

## 2. Staging deploy

1. Build or take the image of this commit and deploy it to staging as the production recipe does
   ([deploy guide](10-deploy-guide.md) section 4; staging runs `APP_ENV=production`). `/migrate` runs first as the release step.
   **Roles and grants:** on a new database create the roles once (`psql "$SUPERUSER_URL" -f database/roles/roles.sql`, then give each a
   password; deploy guide section 11). After that every release must refresh the grants; the release step does it when
   `MIGRATE_RUN_GRANTS=true` is set (the workflow's `migrate-production` job sets it; set it on staging's release command too), and
   running `database/roles/grants.sql` by hand as the migration role does the same. Skipping it leaves the API role unable to read a
   new table or view. The API and the jobs must run as `hiyall_api` on staging, so a missing grant shows up there and not in production.
2. On the machine: `fly ssh console -a <staging-app> -C "/api check-config -release"` (any platform: run the image's
   `/api check-config -release` with the same environment). It loads the environment exactly as a start does, parses the
   key files, applies the release requirements, prints `problem:` lines and warnings, never a value, and exits 1 on any
   problem. It does not touch the database or the network. Where the binary has it, `/api check-config -db` also checks the
   role grants against the real database.
3. `curl https://api.staging.<domain>/readyz`, and check `hiyall_build_info{commit,version}` shows this commit (the first 12
   characters of the sha) and, for a tag build, the tag as the version (for example `v1.0.0`). A build without the stamp says
   `commit="unknown"` and `version="dev"`: the image was built without the build arguments. Sentry's release defaults to that version.
4. Build the apps against staging (`HIYALL_RELEASE_ENV=staging scripts/build-release.sh android`) and install them on real devices.

## 3. Smoke test list (staging, real devices: one Android and one iPhone, two accounts)

Tick every line; each has failed in some app before it shipped. Record date, build number, device and tester.

1. Sign up with a new email, receive and follow the verification email, finish onboarding (birth date, terms); sign in
   again after a force-quit; sign out and in; Sign in with Apple on the iPhone and Google if enabled.
2. Profile: edit, add a photo from the gallery and from the camera; another account sees it.
3. Discover and search; follow and friend request both ways; block and unblock; report a profile and a post.
4. Chat between the two devices: first message from both at the same moment, text, a photo, a reaction, a reply, and
   reading it after a force-quit; after a reinstall check the behaviour described in
   `docs/security/13-encrypted-chat-implementation.md`.
5. Push: a message while the app is closed, on both platforms; the notification shows the Hiyall icon, opens the chat.
6. Nearby: off by default; the explainer; opt in; permission prompt asks for approximate location only; another
   account sees only a rounded distance; sign out removes the location. A 13 to 17 account has the teen filters off.
7. Pulse: post with a photo, comment, react, story; delete the post.
8. Account export and deletion: request both; confirm the 30-day grace period and cancel; for a throwaway account let
   the purge run and confirm the Firebase user is gone.
9. Update gate: set `MIN_CLIENT_VERSION_ANDROID` above the build, confirm the "Update Hiyall" screen, set it back.
10. Offline and airplane mode behaviour, rotation and large text, dark mode, a low-end Android device.
11. Server: `/readyz` 200; logs show no `ERROR`; Sentry receives a deliberate test error from both the API and an app
    build (then resolve it); metrics reachable; the alerts of the deploy guide section 7 exist and a test alert fires.
12. Backup and restore drill done within the last 30 days (`scripts/restore-drill.sh`, which also re-applies the roles and grants and
    verifies them), PITR on, and the nightly backup is scheduled (cron, or `.github/workflows/backup-example.yml.disabled` renamed) with an alert on a missing backup.
13. Load test on staging at twice expected peak (not scripted in the repository; the audit asks for it).

## 4. Tag and build

1. Edit `version:` in `apps/mobile/pubspec.yaml` if this is not the first release (see "Versions and bumping" in the
   app release page); commit; `scripts/release-preflight.sh` again on that commit.
2. `git tag vX.Y.Z && git push origin vX.Y.Z` (X.Y.Z equals the pubspec name; gate a checks).
   Before the first real tag, run **Actions > Release dry run** (`release-dryrun.yml`): it builds a release-mode Android App
   Bundle with a throwaway keystore generated inside the job (R8 shrinking, obfuscation, the Rust library for every ABI) and the
   web build, with made-up configuration and no secrets, and uploads nothing. Tick its `ios` input for an unsigned iOS build.
   **The first signed iOS archive cannot be rehearsed in CI. Do it once on a Mac** with your Apple account
   (`scripts/build-release.sh ios`; the CI path signs manually through `apps/mobile/ios/ExportOptions.plist`, has never run, and is
   the most likely step to need a fix).
3. The workflow runs: preflight (with the Foundation checks required green), Go checks, the API **and admin console** images
   built with the commit and tag stamped in, scanned with trivy and pushed by digest, SBOMs, Android bundle, iOS IPA, a **draft**
   release. A platform missing from `RELEASE_PLATFORMS` is skipped; a listed one without signing secrets fails. Download
   `android-aab` and `ios-ipa`; they include `build/symbols`. Upload the symbols, and the Android
   `mapping.txt`, to Sentry for that release name (`hiyall@<version>+<build>`).
4. Do **not** approve `migrate-production` yet if you want to test the new image against production first; see step 6.

## 5. Store submission

### Google Play (owner)

1. Play Console, create the app (Hiyall, default language, App, Free). Enrol in Play App Signing. Upload the AAB to
   **Internal testing** first and install from the test link on real devices (smoke list again, release build).
   Accounts created as a personal developer account recently may need a closed test with a minimum number of testers
   for a minimum number of days before production access; the Console says so on the Dashboard. Check it early.
2. App content declarations (Policy and programs > App content): privacy policy URL; **App access**: restricted, give the
   reviewer instructions (see "Reviewer account" below); ads: none; **Content rating** questionnaire (user generated
   content and user interaction yes; shares location yes, approximate; no gambling, no violence by the app); **Target
   audience**: 13 and up, so complete the teen questions and state that minors and adults are kept apart and that
   location is off by default for teens (`docs/legal/children-and-teens.md`); news, government, health, financial
   features: no; **Data safety** from `store-listing.md` (encrypted in transit; deletion in the app and at the web URL;
   service providers are not "sharing"); **Account deletion** URL (not built: gate i stays red until there is a page).
3. Store listing from the listing fields table: title, short and full description, 512 px icon, feature graphic,
   phone screenshots, category Social, contact email, privacy policy URL.
4. Production: a **staged rollout** (start at 10 percent, watch step 8, then increase). Policy declarations can take
   days to review: submit to production at least a week before the date you need.

### Apple App Store (owner)

1. App Store Connect, create the app (bundle id `app.hiyall.hiyall`). Upload the IPA (Transporter or Xcode Organizer),
   wait for processing, answer the encryption questions (`ITSAppUsesNonExemptEncryption` is true; see Export
   compliance in the app release page), install through **TestFlight** on real iPhones and run the smoke list.
2. App Information: category Social Networking, age rating (the questionnaire decides: answer user generated content
   yes, unrestricted web access no, location yes; expect a rating that reflects user generated content, and set the
   minimum age to 13 in line with the terms), privacy policy URL. **App Privacy**: answer from the table in
   `store-listing.md`, then compare with Xcode's Privacy Report of the archive.
3. Version page: description, keywords, support URL, screenshots (iPhone 6.9 in and 6.5 in), promotional text, copyright,
   release option (manual, so you control the day) and **phased release** for automatic updates.
4. **Review notes** (App Review Information). Paste, with the real values:

   > Hiyall is a social app for people 13 and older. Sign-in is by email and password (a verified email is required)
   > or Sign in with Apple. Reviewer accounts are below; both are adults, already onboarded and friends with each
   > other so chat can be tried on one device by switching accounts. Chats are end-to-end encrypted, so we cannot
   > read them and no message text is stored on our servers.
   >
   > User-generated content safeguards (guideline 1.2): every profile, post, story, comment and chat has Report and
   > Block; reports reach a moderator console where a person reviews the reported content and can remove it, restrict
   > or ban the account; we aim to act on reports within 24 hours; contact details are in Settings > Help & Safety
   > (`SAFETY_EMAIL`). Photos are scanned on upload against known-illegal-image hash lists before they are shown. <!-- claim:scanned -->
   > (Unscanned release: delete the line above and write instead: "Uploaded photos are not scanned; moderation relies on reports and staff review.")
   > Members under 18 and adults are kept apart (no discovery or messaging between them); Nearby is off until a member turns it
   > on, shows only a rounded distance, and the age and gender filters are not available to teens. Account deletion is in Settings > Account (30-day grace, then
   > erased); Sign in with Apple tokens are revoked on deletion. Notifications ask permission after a first message
   > or follow, never at launch.

5. Submit for review with manual release. After approval, release on the chosen day.

### Reviewer account (both stores)

**There is no demo account built into the app.** The app signs in only through Firebase; the development login and the
fixture identities were removed, and the API refuses `ENABLE_DEV_AUTH` in production, so no special credential can be baked
into a build. A reviewer account must therefore be a real Firebase user:

1. In the production app on a real phone, sign up with a mailbox you control (for example `reviewer1@<your-domain>`),
   complete verification, choose a birth date that makes the account an adult, finish onboarding with a real-looking
   profile and photo. Repeat for `reviewer2@`. Make them friends, and post one photo each, so Discover, chat and Pulse
   are not empty. Leave Nearby off (the reviewer can opt in).
2. Put the email and password in the **App Review Information** sign-in fields (Apple) and **App access** instructions
   (Play), plus a phone number and email Apple can reach. The password has to work without a second factor.
3. Do not delete or suspend these accounts; check they still sign in before every submission. Use a long unique
   password and rotate it after review. Keep their credentials in the password manager with the keystore.
4. If a reviewer reports a verification email never arrived, check the Firebase Authentication templates and the
   sender domain, and the mailbox itself.

## 6. Production deploy

1. The release run waits at `migrate-production` for a required reviewer on the `production` environment. Before
   approving: back up and confirm PITR, then approve; the job runs the image's own `/migrate` (idempotent, locked,
   each file in a transaction). Database roles: `roles.sql` ran once; with `MIGRATE_RUN_GRANTS=true` and
   `MIGRATE_DATABASE_URL` (`hiyall_migrate`) the same step then applies `grants.sql`, the privilege refresh for new
   tables and views (deploy guide section 11). `api check-config -db` on the machine confirms the grants.
2. Deploy the image **by digest** from the draft release ([deploy guide](10-deploy-guide.md) section 8b):
   `fly deploy --image ghcr.io/<owner>/<repo>/api@sha256:... --app hiyall-api`.
3. On the machine: `/api check-config -release` (same as step 2) against the production environment. The startup log
   names the client-address mode; check `hiyall_build_info{commit}` equals the tagged commit; `/readyz` 200.
4. Set `MIN_CLIENT_VERSION_ANDROID` and `_IOS` to `1.0.0`, `APP_CHECK_ENFORCE=false` (App Check is not sent by the app
   yet; plan `log` then `true` after an app release that sends tokens, see deploy guide 4b).
5. Publish the stores: Play staged rollout; App Store manual release. Publish the GitHub draft release last.
6. Sign up on a real phone against production with a throwaway account and send one chat photo (it proves both
   buckets), then delete the account.

## 7. Post-release monitoring checklist

First hour (one person watching, no other changes):

- `/readyz` and the external uptime check green; 5xx rate under 1 percent; `hiyall_http_request_duration_seconds` p95 under 1 s.
- `hiyall_http_panics_total` flat; Sentry shows no new issue from the API or either app; crash-free sessions in Play
  Console vitals and App Store Connect, after the first sessions arrive.
- `hiyall_db_pool_conns_acquired` below max; no `rate_limit_rejections_total` spike for one limiter (a 429 storm means
  the proxy settings are wrong: the startup log says the client-address mode).
- `hiyall_realtime_connections` rises with users; a push reaches a real phone.
- Sign-ups complete (onboarding completions versus sign-ups), verification emails arrive, no `AUTH_UNAVAILABLE`.
- Reports reach the moderation console; the on-call moderator saw the first one.

First day: store reviews and support mailbox answered; Play pre-launch and vitals reports; photo scanning counters
(`quarantine` events, none unexplained); maintenance job last-run metrics fresh; the backup job ran; bucket sizes sane.

First week: staged rollout increased when crash-free sessions and 5xx stay healthy; retention of new accounts;
restore drill rehearsed; open an issue list from reviews; decide the `MIN_CLIENT_VERSION` plan for the first bug-fix.

## 8. Rollback

- **API:** redeploy the previous image digest ([deploy guide](10-deploy-guide.md) section 8). The schema is
  backward compatible by rule, so the old code runs on the new schema. Never edit an applied migration; fix forward.
- **Configuration:** `fly secrets set` the previous value (it redeploys).
- **Apps cannot be rolled back.** Halt the Play staged rollout (Release > Halt) or remove the build from the App Store
  release (do not release it, or pause phased release), then ship a **new** version with a higher build number. To
  protect people on a bad build meanwhile, raise `MIN_CLIENT_VERSION_*` above it (426 shows the Update screen) once the
  fixed version is live; raising it before then locks everyone out.
- **A feature that must go now:** `SPACES_EVENTS_ENABLED` is off already; photo uploads stop by unsetting
  `MEDIA_ENDPOINT` (503 `MEDIA_UNAVAILABLE`) and chat photos by unsetting `CHAT_MEDIA_ENDPOINT` (503
  `CHAT_MEDIA_UNAVAILABLE`); the app copes with those answers. Anything else needs a build.
- **Data damage:** PITR to a new instance, verify, switch `DATABASE_URL`, then `scripts/replay-deletions.sh` before the
  restored API takes traffic (deploy guide section 6). This is an incident, not a rollback.
- **Leaked secret:** rotate it in the provider first (R2 token, service-account key, Sentry DSN, signing key via Play's
  upload-key reset), then in the secret store; Firebase API keys are not secrets but restrict them in the Google Cloud console.
