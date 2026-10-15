# Environments: development, staging, production

**Status, 15 October 2026.** Today development uses one Firebase project (`hiyall-prod-1`, which despite its name is the **development** project) and the development R2 buckets (`hiyall`, `hiyall-chat`). Production must have its own Firebase project and buckets before real users: a test account, a leaked dev token or a bucket CORS change in development would otherwise touch production. The release preflight enforces it (section "Development identifiers"). This page lists exactly what the owner creates; nothing here has been created.

| | development (your Mac) | staging | production |
|---|---|---|---|
| Purpose | daily work, fixtures, dev login | release rehearsal, store beta builds, restore drills | real users |
| Firebase project | `hiyall-prod-1` (the dev project; listed in `config/environments.json`) | `hiyall-staging` | a NEW production project (not `hiyall-prod-1`) |
| Database | local Postgres (`.runtime`) | its own managed Postgres, database `hiyall_staging` | its own managed Postgres, database `hiyall` |
| R2 social bucket | `hiyall` (dev; rename or recreate as `hiyall-dev` when convenient) | `hiyall-staging` | a new production bucket (`hiyall-prod`), not the dev one |
| R2 chat bucket | `hiyall-chat` | `hiyall-chat-staging` | `hiyall-chat-prod` |
| R2 tokens | dev tokens in `config/*.local.env` | tokens limited to the two staging buckets | new tokens limited to the two production buckets |
| API | `scripts/dev-api.sh`, `APP_ENV=development`, `ENABLE_DEV_AUTH` allowed | `APP_ENV=production` (same start checks as production) at `api.staging.<domain>` | `APP_ENV=production` at `api.<domain>` |
| FCM / APNs | none | staging project's FCM key and APNs key | production project's keys |
| Sentry | none | its own project/DSN | its own project/DSN |
| Mobile bundle id | as is | same id, build points at staging | same id, build points at production |

Rules: no credential is valid in more than one column; a staging build can never reach production data because its Firebase project and API URL differ; `ENABLE_DEV_AUTH` and `/dev/session` exist only in development (the API refuses them otherwise). Staging runs `APP_ENV=production` on purpose so the TLS, https and secure-media start checks are rehearsed there.

## Development identifiers (the preflight refuses to reuse them)

`config/environments.json` is committed, holds no secret, and lists what development uses: `DEV_FIREBASE_PROJECT_ID` (today `hiyall-prod-1`) and `DEV_MEDIA_BUCKETS` (`hiyall`, `hiyall-chat`, `hiyall-media`). `scripts/release-preflight.sh` fails when a production value equals any of them:

- gate c: `FIREBASE_PROJECT_ID` in the mobile release inputs;
- gate d: `FIREBASE_PROJECT_ID`, `MEDIA_BUCKET`, `CHAT_MEDIA_BUCKET` (and the admin and evidence buckets) of the production API environment.

When development moves to its own project or buckets, add the new names to the file (the old ones stay listed until nothing uses them). Extra names can be added for one run through the environment variables `DEV_FIREBASE_PROJECT_ID` and `DEV_MEDIA_BUCKETS` (comma separated). The production templates (`config/api.production.example.env`) already use placeholders and `hiyall-prod` and `hiyall-chat-prod`.

## Files in the repository

| File | What it is |
|---|---|
| `infrastructure/docker/api.example.env` | every API variable, with rules |
| `config/api.staging.example.env`, `config/api.production.example.env` | only the per-environment values (project id, buckets, origins), placeholders |
| `infrastructure/docker/admin.example.env`, `config/admin.production.example.env` | every variable of the admin console, and its production overlay |
| `config/environments.json` | the development identifiers the preflight refuses to see in production |
| `infrastructure/alerts/hiyall.rules.yml` | Prometheus alert rules; validate with `scripts/validate-alerts.sh` ([deploy guide](10-deploy-guide.md) section 7) |
| `config/r2-cors.development.json`, `.staging.json`, `.production.json` | CORS for each environment's buckets. Replace `<your-domain>`; apply with the Cloudflare dashboard (R2 > bucket > Settings > CORS policy; paste the JSON) or wrangler (check its current `r2 bucket cors` syntax) to **both** buckets of that environment. Native apps need no CORS; it is for the web build only. |
| `config/mobile-release.example.env` | the inputs of `scripts/build-release.sh` per environment |
| `config/media.example.env`, `config/chat-media.example.env` | local development bucket credentials |

## What the owner must create (checklist)

**Firebase / Google**
1. Project `hiyall-staging` (Blaze plan not required for Auth). Enable the same sign-in providers as production (email link, Apple, whichever you ship). Add the staging web origin to Authorized domains.
2. Register the Android and iOS apps in each project; download nothing into the repo (`config/firebase.local.json` is ignored). Note each project's app ids, sender id and web API key for the release variables below.
3. For each project: a service-account key for FCM sending and one with the Firebase Authentication Admin role for account deletion, stored as secrets and mounted as files (`FCM_SERVICE_ACCOUNT_FILE`, `FIREBASE_SERVICE_ACCOUNT_FILE`). Upload the APNs auth key to each project's Cloud Messaging settings.

**Cloudflare R2**
4. Buckets `hiyall-staging`, `hiyall-chat-staging`, `hiyall-prod`, `hiyall-chat-prod`, and an evidence bucket per environment (for example `hiyall-evidence-prod`; quarantined photos; the API's token there is write-only; see `EVIDENCE_*` in `infrastructure/docker/api.example.env`) (the API never creates them). Apply the matching `config/r2-cors.<env>.json`. Add the lifecycle rule from `config/chat-media.example.env` to both chat buckets.
5. One token per bucket, "Object Read & Write", limited to that single bucket. R2 has **no object versioning**; see the replication advice in [10-deploy-guide.md](10-deploy-guide.md) section 6.
6. A separate account or provider bucket for database backups (`BACKUP_S3_BUCKET`), with a write and list only token, and a lifecycle rule keeping 14 days or more.

**Database**
7. A managed PostgreSQL 16 for staging and one for production, each with TLS and a direct connection; PITR on production. A read-only role for the backup job.

**GitHub** (repository settings, needed by `.github/workflows/release.yml`)
8. Environments: create `production` and add **required reviewers** (yourself and one other person if there is one; enable "prevent self-review" when you have a second reviewer) and restrict it to tags `v*`. **Without the environment, GitHub creates `production` on first use with no reviewers and the migration job runs unattended.** Preflight gate o checks it (`gh api repos/<owner>/<repo>/environments/production` must show a required-reviewers rule): it runs in the release workflow with the workflow token (`actions: read`), and locally when `gh` is logged in as someone who can read the repository settings; with neither it prints `NOT VERIFIED` and you must look in Settings > Environments yourself. If the workflow token cannot see the rules, add a fine-grained token with Administration: read as the secret `RELEASE_GATE_TOKEN`. Add the secret `PRODUCTION_DATABASE_URL` (direct URL, `sslmode=verify-full`, the **hiyall_migrate** role) to that environment only; the job runs `/migrate` with `MIGRATE_RUN_GRANTS=true`, which also refreshes the grants of the API and admin roles. Optionally create `staging` the same way for a staging migration job.
9. Repository variables: `API_BASE_URL`, `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_ANDROID_APP_ID`, `FIREBASE_IOS_APP_ID`, `SUPPORT_EMAIL`, `SAFETY_EMAIL`, `PRIVACY_EMAIL` (the Help & Safety contacts; `scripts/build-release.sh` fails on a missing or placeholder address), `APP_STORE_URL`, `PLAY_STORE_URL` (the Update screen; `scripts/release-preflight.sh` rejects missing or placeholder values). Secrets: `FIREBASE_API_KEY`, `SENTRY_DSN`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`, `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`. Optional variables: `RELEASE_PLATFORMS` (default `android,ios`; a listed platform **requires** its signing secrets, an unlisted one is skipped on purpose), `IOS_TEAM_ID` and `IOS_PROFILE_NAME` (the iOS job reads both from the installed provisioning profile; set them only to override), `SCAN_ALLOW_NONE` and `RELEASE_ACK_UNSCANNED` (see the runbook, item "Photo scanning"). The preflight (gates e and r) fails when a listed platform lacks its secrets, and the mobile jobs fail rather than skip. Rehearse the whole pipeline without any secret with **Actions > Release dry run** (`release-dryrun.yml`). The workflow currently reads one set of release variables, so a staging build is made locally with `scripts/build-release.sh` and the staging file; add environment-scoped variables if you want staging builds from CI.
10. Settings > Actions: restrict allowed actions to those pinned in the workflows, set the default workflow token to read-only, and turn on branch protection for `main` requiring the "Foundation checks" jobs and one review (`CODEOWNERS` is in `.github/`).
11. Replace the owner placeholder in `SECURITY.md` and `.github/CODEOWNERS`.
12. Backups: to run `scripts/backup-db.sh` from GitHub Actions, copy `.github/workflows/backup-example.yml.disabled` to `backup.yml`, create the `production-backup` environment with the secrets named in the file, and read the comments there first. A cron job on a machine you control works as well; either way alert on a missing backup.

**Stores** (not environment-specific, listed so they are not forgotten): an Apple Developer account and App Store Connect app, a Google Play Console app and upload key, the privacy label / Data safety form, and a web page for account deletion.

## Local files for the release preflight (git-ignored)

`scripts/release-preflight.sh` reads `config/mobile-release.production.local.env` (from `config/mobile-release.example.env`;
`HIYALL_RELEASE_ENV=<env>` picks another) and, for gate d, `config/api.production.env` (from
`config/api.production.example.env` plus the secret values) with the key files it names under `/secrets/` placed in
`config/secrets/` (`PREFLIGHT_SECRETS_DIR` changes the directory). `HIYALL_API_ENV_FILE` points at another file. None of
these are committed; delete them from your machine when done if it is shared. The same check runs against the real
environment with `api check-config -release` on the deployed machine ([release runbook](12-release-runbook.md)).

## Smoke order for a new environment

Create the database and run `/migrate`; start the API; `curl /readyz`; sign in from a build that points at it; send a photo (checks both buckets); a two-device chat; a deletion request and the purge; then `scripts/restore-drill.sh` against a backup of it.
