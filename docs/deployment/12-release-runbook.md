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
| Android upload keystore and `key.properties` (CI: four secrets, in the `release` environment) | `apps/mobile/android/key.properties` | e |
| Apple Developer account, App ID with Push and Sign in with Apple, APNs key, distribution certificate and profile (CI: three secrets, in the `release` environment) | Xcode, App Store Connect, GitHub secrets | r (CI) |
| Which mobile platforms ship: the repository variable `RELEASE_PLATFORMS` (default `android,ios`). A listed platform must have its signing secrets; an unlisted one is skipped on purpose | GitHub variables | e, r |
| The GitHub `production` AND `release` environments, both with required reviewers (`release` holds the store signing secrets), the `v*` tag protection, and the `RELEASE_GATE_TOKEN` secret (fine-grained, Administration: read) so gate o can read them | GitHub Settings > Environments, Rules | o |
| Real GitHub owner and security contact | `.github/CODEOWNERS`, `SECURITY.md` | h |
| Foundation checks green on the commit that is tagged | GitHub Actions | n |
| Photo scanning: a hash list or provider, **or** the written acknowledgement below | API environment | q, d |
| Evidence bucket (owner action before launch): a bucket of its own with three separate credentials (the API's, meant to be write-only; the console's read-only one; the console purge job's delete one), and an **R2 bucket-lock retention rule of at least `EVIDENCE_RETENTION_DAYS` (365)** because R2 cannot make the API's token write-only. `EVIDENCE_ALLOW_API_DELETE=true` is your statement that the lock is in place, and the canary verifies it (the probe must survive a delete by the API's credential; the rule must cover `canary/` too) | Cloudflare R2, production API and console environments | d (`check-config -release -net` runs the canary) |
| A production Firebase project and buckets that are not the development ones | `config/environments.json` lists the development values | c, d |
| Store listing fields, privacy answers, reviewer accounts | `docs/mobile/store-listing.md` | i |
| Production Firebase project, buckets, database, DNS and TLS, separate from development | [environments](11-environments.md) | d |
| Moderator on call, CSAM runbook owner, hash-list or scanning provider | `docs/security/16-csam-and-illegal-content.md` | d (scanner), q |
| Database roles and grants (`database/roles/roles.sql` once, then `grants.sql` after every migration; the release step does the second, as `hiyall_migrate`; the API itself runs as `hiyall_api`) | production database | see steps 2 and 5 |
| Independent review of the end-to-end encryption | external | none (a go/no-go decision) |

**Photo scanning, the written acknowledgement.** Production refuses to start without an upload scanner unless
`SCAN_ALLOW_NONE=true`. A release with that switch on passes the preflight only when you also set
`RELEASE_ACK_UNSCANNED=I_ACCEPT_UNSCANNED_PHOTOS` (gate q; in GitHub as repository variables `SCAN_ALLOW_NONE` and
`RELEASE_ACK_UNSCANNED`, mirrors of the production setting). It is a deliberate decision of yours: the draft release
notes print "UNSCANNED PHOTOS ACKNOWLEDGED", and gate q fails while any line of the store listing or of the review notes below that
carries the hidden scanned-claim comment still says photos are scanned. The legal texts carry `[COUNSEL: scanning status
at launch ...]` placeholders around every sentence that describes the scanner (case records, fingerprints, restricted storage, two-person approvals); gate b
refuses them until counsel has chosen the true wording, and gate q also fails an unscanned release while any legal text outside those brackets
still speaks of hash lists, flagged photos, safety cases or restricted evidence storage.

## 1. Preflight

On the commit to be released, on `main`, pushed:

```bash
scripts/check.sh               # the heavy suites: Go with the race detector, Rust, Flutter analyse and tests, contracts
scripts/release-preflight.sh   # every release gate, each with its one-line fix; exits non-zero until all pass
```

`release-preflight.sh` only gates. Fix every `[FAIL]` and run it again; do not tag while it fails. Its own tests run with
`python3 scripts/test-release-preflight.py` (the legal-placeholder allowlist, dev-identifier reuse, check-run and environment checks,
the scanning acknowledgement, platform parsing, skip rules, env-docs drift). Gate b is an allowlist: every square-bracket span left in a
legal document, in any case and over any number of lines, blocks the release unless it is a Markdown link with a real address or a
checkbox. Gates n (Foundation checks green on the tagged commit) and o (the `production` and `release` environments have reviewers) call
`gh api`: in CI they **fail** when they cannot look (a gate that cannot verify must not pass); locally they print `NOT VERIFIED` without a
logged-in `gh`, and then you confirm both by hand.
Gate p fails when an environment variable the Go code reads is not in an example env file (`python3 scripts/check_env_docs.py`).
Gate l fails in CI when `govulncheck` is missing (the workflow installs it) unless `PREFLIGHT_SKIP_GOVULNCHECK=1`. Gate d needs the
production environment as a file on your machine; if you would rather not keep one, skip it locally (`PREFLIGHT_SKIP=d`,
printed as SKIPPED) and run the same server check in step 5. In CI gate d cannot run, so the workflow skips it **only** while the repository
variable `PREFLIGHT_HOST_CHECK` equals the tag being released, which you set after the host check of step 5.2 passed; any other CI
skip needs `PREFLIGHT_SKIP_REASON`, and gate o can be skipped only while no `RELEASE_GATE_TOKEN` exists. `RELEASE_PLATFORMS` may be written
`android, ios`: a `platforms` job normalises spaces and case and rejects an unknown name.

## 2. Staging deploy

1. Build or take the image of this commit and deploy it to staging as the production recipe does
   ([deploy guide](10-deploy-guide.md) section 4; staging runs `APP_ENV=production`). `/migrate` runs first, as `hiyall_migrate`, from your laptop or a one-off machine (not as an app release command).
   **Roles and grants:** on a new database create the roles once (`psql "$SUPERUSER_URL" -f database/roles/roles.sql`, then give each a
   password; deploy guide section 11). After that every release must refresh the grants; `/migrate` does it when
   `MIGRATE_RUN_GRANTS=true` and `MIGRATE_DATABASE_URL` are set (the workflow's `migrate-production` job does), and
   running `database/roles/grants.sql` by hand as the migration role does the same. Skipping it leaves the API role unable to read a
   new table or view. The API and the jobs must run as `hiyall_api` on staging, so a missing grant shows up there and not in production.
2. On the machine: `fly ssh console -a <staging-app> -C "/api check-config -release"` (any platform: run the image's
   `/api check-config -release` with the same environment). It loads the environment exactly as a start does, parses the
   key files, applies the release requirements, prints `problem:` lines and warnings, never a value, and exits 1 on any
   problem. Without a flag it touches neither the database nor the network; **`-release`, `-db` and `-net` do call out**: they
   probe Apple's `/auth/token` with a deliberately invalid code (when `APPLE_*` is configured), `-net` also writes a probe object to
   the evidence bucket (a write error there is a problem with `-release -net`), and `-db` connects to the database. Where the binary has it, `/api check-config -db` also checks the
   role grants against the real database.
3. `curl https://api.staging.<domain>/readyz`, and check `hiyall_build_info{commit,version}` shows this commit (the first 12
   characters of the sha) and, for a tag build, the tag as the version (for example `v1.0.0`). A build without the stamp says
   `commit="unknown"` and `version="dev"`: the image was built without the build arguments. Sentry's release defaults to that version.
4. Build the apps against staging (`HIYALL_RELEASE_ENV=staging scripts/build-release.sh android`) and install them on real devices.

## 3. Smoke test list (staging, real devices: one Android and one iPhone, two accounts). Done before the tag; the production checks are step 6

Tick every line; each has failed in some app before it shipped. Record date, build number, device and tester.

1. Sign up with a new email, receive and follow the verification email, finish onboarding (birth date, terms); sign in
   again after a force-quit; sign out and in; Sign in with Apple on the iPhone and Google if enabled.
2. Profile: edit, add a photo from the gallery and from the camera; another account sees it.
3. Discover and search; follow and friend request both ways; block and unblock; report a profile and a post.
4. Chat between the two devices: first message from both at the same moment, text, a photo, a reaction, a reply, and
   reading it after a force-quit; after a reinstall check the behaviour described in
   `docs/security/13-encrypted-chat-implementation.md`.
5. Push: a message while the app is closed, on both platforms; the notification shows the Hiyall icon, the title "Hiyall" and the line "New message" (no text, no name) and opens the chat; a friend request or follow may show the other member's display name, and that is expected.
6. Nearby: off by default; the explainer; opt in; permission prompt asks for approximate location only; another
   account sees only a rounded distance; sign out asks the server to remove the location (best effort: otherwise it stops showing within 24 hours and is deleted within 7 days); the app reads the location only when Nearby is turned on or refreshed by hand. A 13 to 17 account has the teen filters off.
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
   (`scripts/build-release.sh ios` without `IOS_TEAM_ID`/`IOS_PROFILE_NAME`; the CI path signs manually: it writes the git-ignored
   `ios/Flutter/Signing.xcconfig`, which only the Runner target includes, proves it with `xcodebuild -showBuildSettings`, archives, and
   exports with `apps/mobile/ios/ExportOptions.plist`. It has never run and is the most likely step to need a fix: rehearse it
   on a Mac with a manual-signing profile first).
3. The workflow runs: preflight (with the Foundation checks required green), Go checks, the API **and admin console** images
   built with the commit and tag stamped in, scanned with trivy and pushed by digest, SBOMs, Android bundle, iOS IPA, a **draft**
   release. A platform missing from `RELEASE_PLATFORMS` is skipped; a listed one without signing secrets fails. Download
   `android-aab`, `android-r8-mapping` and `ios-ipa`; the bundles include `build/symbols`. Upload the symbols, and the Android
   `mapping.txt`, to Sentry for that release name (`hiyall@<version>+<build>`).
4. The run now waits: the `android` and `ios` jobs wait for a reviewer on the `release` environment (they hold the store signing keys),
   and `migrate-production` waits for one on `production`. Approve `release` when the preflight and checks are green; do **not**
   approve `migrate-production` until step 5 says so. Nothing in this step touches production: production smoke tests and the
   reviewer accounts come after the production deploy (steps 5 and 6), never before.

## 5. Production deploy

Order matters. The production environment is made complete first, then the new image is checked against it, then the schema is
migrated, then the API is rolled out.

1. **Set the production environment, `MIN_CLIENT_VERSION_*` included, before any check.** `api check-config -release` refuses a
   production environment without a minimum client version, so set it first, not after. For the **first** release set
   `MIN_CLIENT_VERSION_ANDROID`, `MIN_CLIENT_VERSION_IOS` (and `_WEB` if the web app ships) to `1.0.0`, the version being released:
   no installed app is older, so nobody is locked out, and the setting exists for the day you need to retire a version. Later releases
   raise it only after the fixed version is live in the stores (step 9). `APP_CHECK_ENFORCE=false` (the app does not send App Check
   tokens yet; plan `log` then `true`, deploy guide 4b).
2. **Check the new image with that environment, before approving anything.** Run the image's `/api check-config -release` with the
   production environment and the key files mounted at `/secrets/` (a one-off container on your laptop:
   `docker run --rm --env-file <production env file> -v <secrets dir>:/secrets:ro --entrypoint /api <image>@<digest> check-config -release`,
   or a one-off machine on your platform). It must exit 0. This is also what lets you set the repository variable `PREFLIGHT_HOST_CHECK`
   to the tag, which the next release's preflight needs to skip gate d.
3. **Migrate.** The run waits at `migrate-production` for a required reviewer on the `production` environment. Before approving: back up and
   confirm PITR, then approve; the job runs the image's own `/migrate` as `hiyall_migrate` (secret `PRODUCTION_MIGRATE_DATABASE_URL`, never an
   application secret; idempotent, locked, each file in a transaction) with `MIGRATE_RUN_GRANTS=true`, which then applies `grants.sql`, the
   privilege refresh for new tables and views (deploy guide section 11). The job needs network reach to the production database; a GitHub-hosted
   runner has no fixed address. If it cannot connect, run the same command from your laptop or a one-off machine that can
   (deploy guide section 5) and let the job fail. `api check-config -db` confirms the grants afterwards.
4. **Deploy the image by digest** from the draft release ([deploy guide](10-deploy-guide.md) section 8b):
   `fly deploy --image ghcr.io/<owner>/<repo>/api@sha256:... --app hiyall-api`. The API runs as `hiyall_api`; there is no `release_command`.
5. On the machine: `/api check-config -release` and `-db` against the live production environment. The startup log names the client-address
   mode; check `hiyall_build_info{commit}` equals the tagged commit; `/readyz` 200. Set the repository variable `PREFLIGHT_HOST_CHECK` to the tag.
6. Go on to step 6 (reviewer accounts and the production smoke test), then step 7 (stores). Publish the GitHub draft release last.

## 6. Reviewer accounts and the production smoke test

Only now, after step 5: the reviewer accounts live in the production database and the production app talks to the production API.

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
5. Production smoke test, one real phone, a throwaway account: sign up, finish onboarding, send one chat photo (it proves both
   buckets), post one photo (the social bucket), request deletion and cancel it, then delete the account for good. Check `/readyz`,
   the logs for `ERROR`, Sentry (a deliberate test error from the API and from a production build), and that a test alert fires.

## 7. Store submission

Submit only after step 6: the review notes and the store forms name reviewer accounts that exist in production.

### Google Play (owner)

1. Play Console, create the app (Hiyall, default language, App, Free). Enrol in Play App Signing. Upload the AAB to
   **Internal testing** first and install from the test link on real devices (smoke list again, release build).
   Accounts created as a personal developer account recently may need a closed test with a minimum number of testers
   for a minimum number of days before production access; the Console says so on the Dashboard. Check it early.
2. App content declarations (Policy and programs > App content): privacy policy URL; **App access**: restricted, give the
   reviewer instructions (see step 6 (Reviewer accounts)); ads: none; **Content rating** questionnaire (user generated
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
   > or ban the account; [COUNSEL/OPERATOR: response target, only once someone is on call to meet it]; contact details are in Settings > Help & Safety
   > (`SAFETY_EMAIL`). Photos are scanned on upload against known-illegal-image hash lists before they are shown. <!-- claim:scanned -->
   > (Unscanned release: delete the line above and write instead: "Uploaded photos are not scanned; moderation relies on reports and staff review.")
   > Members under 18 and adults are kept apart (no discovery or messaging between them); Nearby is off until a member turns it
   > on, shows only a rounded distance, and the age and gender filters are not available to teens. Account deletion is in Settings > Account (30-day grace, then
   > erased); Sign in with Apple is revoked on deletion when the app can obtain Apple's code; otherwise the app tells the member to remove Hiyall in Settings > Apple ID > Sign in with Apple, because nobody at Hiyall can revoke it for them. Notifications ask permission after a first message
   > or follow, never at launch.

5. Submit for review with manual release. After approval, release on the chosen day.

## 8. Post-release monitoring checklist

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

## 9. Rollback

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
