# Deploy guide: the first production path for a small team

**Status, 13 October 2026.** Written, not rehearsed. Nothing has been deployed. The container image has not been built with Docker on any machine that wrote this (Docker was not installed); the static Linux binaries (`CGO_ENABLED=0`, same flags as the Dockerfile) were built and the Go tests, the health, metrics, leader-election and shared-limiter code were run against a local PostgreSQL. Every command below is for the **owner** to run; it creates accounts and spends money, so none of it was run for you. Prices are orders of magnitude from memory, not quotes: check each pricing page before you commit.

This guide covers the API (`services/api`). Media already lives in Cloudflare R2 (buckets `hiyall` and `hiyall-chat`) and sign-in in Firebase (`hiyall-prod-1`); both stay as they are. For capacity maths and the later multi-region picture see [09-capacity-and-operations.md](09-capacity-and-operations.md); this page is the small, boring start.

## 1. The recommendation

**Run the API on Fly.io (two always-on machines in one region near your users) with a managed PostgreSQL 16 that has point-in-time recovery, and keep R2 for media.** Reasons, specific to this codebase:

- The API is one static Go binary with a WebSocket endpoint. It needs machines that stay up (the hourly cleanup loop and the realtime sockets die with scale-to-zero) and a platform that lets sockets live for hours. Fly runs ordinary always-on containers with TLS in front.
- Releases need a "run `/migrate` first, then start the new version" step. Fly has this as `release_command`; the image already contains `/migrate`.
- The realtime bus uses PostgreSQL `LISTEN/NOTIFY` and the cleanup leader uses a session-level advisory lock. Both need a **direct** database connection, not a transaction-mode pooler. Pick a Postgres offering that gives you one.

| Option | Good for | Watch out for | Rough monthly cost to start |
|---|---|---|---|
| **Fly.io + managed Postgres + R2 (recommended)** | Small team, one region, WebSockets, release command, quick rollback | Fly's managed Postgres tier and region list change: confirm one exists in your region with PITR before choosing it; otherwise use another provider with a direct connection (Neon direct endpoint, Supabase direct port 5432, RDS, Cloud SQL) | tens of dollars for two small machines, plus roughly tens to low hundreds for the database depending on size and HA |
| Google Cloud Run + Cloud SQL | You already live on Google Cloud and want IAM and Cloud Monitoring | Needs `min-instances=1` and "CPU always allocated" or cleanup and sockets starve; one exposed port only, so the metrics listener is unreachable (use Cloud Monitoring's built-in request metrics); WebSocket connections are capped at the request timeout (reconnects are normal, the app handles them) | same order as above, usually a bit higher because Cloud SQL has a floor |
| **Single VPS + docker compose** | Cheapest, simplest, fine for a closed beta | One machine is one outage; you own OS patches, backups and TLS; no rolling deploy (a few seconds of downtime per release) | roughly $5 to $40 |

Single VPS in eight lines (closed beta only; use a managed Postgres or enable `pgbackrest`/WAL archiving before real users, because a VPS disk is not a backup):

```bash
curl -fsSL https://get.docker.com | sh                      # 1. Docker on a fresh Ubuntu/Debian VPS
git clone <your repo> hiyall && cd hiyall                   # 2. the code
cp infrastructure/docker/api.example.env infrastructure/docker/api.env   # 3. fill in real values (section 3)
$EDITOR infrastructure/docker/api.env                       # 4. APP_ENV=production, DATABASE_URL (sslmode=verify-full), ...
docker build -f services/api/Dockerfile -t hiyall-api .     # 5. build the image
docker run --rm --env-file infrastructure/docker/api.env --entrypoint /migrate hiyall-api   # 6. migrations
docker run -d --name api --restart unless-stopped --env-file infrastructure/docker/api.env -p 127.0.0.1:8080:8080 hiyall-api   # 7. API
# 8. Put Caddy (or nginx) in front on 443 with a Let's Encrypt certificate, proxying to 127.0.0.1:8080, WebSocket upgrade on.
```

`compose.prod-like.yml` is for the smoke test on your laptop (section 9), not for production: its database has no TLS and no backups.

## 2. Before you start: what the owner has to decide or create

| Item | Where | Note |
|---|---|---|
| Fly.io account and `flyctl` | fly.io | Billing needed. Enable 2FA. |
| Managed PostgreSQL 16 with PITR | provider of your choice | Same region as the API. Create database `hiyall` and a role `hiyall` with a long random password. TLS on; download the CA if the provider uses a private one. |
| Domain and DNS | your registrar | `api.<your-domain>` for the API. |
| Firebase project `hiyall-prod-1` | already created | Add your web origin to Authorized domains if you serve the web app. Real sign-up has not been tested yet. |
| FCM service-account key | Firebase console | Only when push ships. Not needed for first deploy; pushes are logged without it. |
| R2 buckets and tokens | already created | The production tokens should be new ones limited to their bucket; do not reuse the development tokens. |
| Terms of Service and Privacy Policy | `docs/legal` (drafts) | Needs legal review before real users. |

## 3. Environment and secrets checklist

Authoritative list with every variable, default and rule: [`infrastructure/docker/api.example.env`](../../infrastructure/docker/api.example.env). For production:

| Variable | Required | Secret | Value |
|---|---|---|---|
| `APP_ENV` | yes | no | `production` |
| `DATABASE_URL` | yes | **yes** | direct connection, `sslmode=verify-full` (the API refuses to start otherwise) |
| `LISTEN_ADDR` | no | no | image default `0.0.0.0:8080` |
| `FIREBASE_PROJECT_ID` | yes | no | `hiyall-prod-1` |
| `WEB_ORIGIN` | if you serve the web app | no | `https://app.<your-domain>` (https origin only) |
| `AGE_BAND_ISOLATION` | no | no | leave `true`; `false` is refused in production |
| `MEDIA_ENDPOINT`, `MEDIA_BUCKET`, `MEDIA_REGION`, `MEDIA_SECURE` | for photos | no | `<account>.r2.cloudflarestorage.com`, `hiyall`, `auto`, `true` |
| `MEDIA_ACCESS_KEY`, `MEDIA_SECRET_KEY` | with `MEDIA_ENDPOINT` | **yes** | bucket-scoped R2 token |
| `CHAT_MEDIA_ENDPOINT`, `CHAT_MEDIA_BUCKET`, `CHAT_MEDIA_REGION`, `CHAT_MEDIA_SECURE` | for chat photos | no | same shape, bucket `hiyall-chat` |
| `CHAT_MEDIA_ACCESS_KEY`, `CHAT_MEDIA_SECRET_KEY` | with `CHAT_MEDIA_ENDPOINT` | **yes** | a different token, scoped to the chat bucket only |
| `RATE_LIMIT_BACKEND` | **yes** | no | `postgres`; production refuses to start with `memory` (the per-node limiters evict keys and multiply with machines) |
| `TRUSTED_PROXY_CIDRS`, `BEHIND_PROXY`, `CLIENT_IP_HEADER` | **yes** behind a proxy | no | `BEHIND_PROXY=true`, the proxy's CIDR blocks, `CLIENT_IP_HEADER=Fly-Client-IP` on Fly. Without the CIDRs every client shares the proxy's rate-limit bucket, so production refuses to start with `BEHIND_PROXY=true` and none. The chosen mode is logged at startup (see section 4a) |
| `CURSOR_KEY` | **yes** | **yes** | `openssl rand -base64 32`, the same on every machine. Rotate with `CURSOR_KEY_PREVIOUS` (keep the old key for 15 minutes) |
| `DB_MAX_CONNS`, `DB_STATEMENT_TIMEOUT`, `DB_LOCK_TIMEOUT`, `DB_IDLE_IN_TRANSACTION_TIMEOUT` | no | no | default pool 20 per machine; per-connection limits 5s, 3s, 15s (a `pool_max_conns` in `DATABASE_URL` wins over `DB_MAX_CONNS`) |
| `MIN_CLIENT_VERSION_ANDROID`, `_IOS`, `_WEB` | no | no | empty (off). Set to retire an app version: older clients get 426 `UPGRADE_REQUIRED` |
| `APP_CHECK_ENFORCE`, `FIREBASE_PROJECT_NUMBER` | no (recommended for launch) | no | `false` (default), `log`, then `true` once App Check is set up (see "App Check" below). `FIREBASE_PROJECT_NUMBER` is the numeric project number, required for `log` and `true` |
| `LOG_FORMAT` | no | no | default `json` in production |
| `GOMEMLIMIT` | recommended | no | about 80% of the machine's memory, `400MiB` on a 512 MB machine (see section 7, item 6) |
| `METRICS_ADDR` | no | no | default is loopback `127.0.0.1:9090`, unreachable from outside the machine; leave it, or set `0.0.0.0:9090` **and** `METRICS_TOKEN` and keep the port private |
| `METRICS_TOKEN` | if `METRICS_ADDR` is not loopback | **yes** | `openssl rand -hex 24` |
| `FCM_SERVICE_ACCOUNT_FILE`, `FCM_PROJECT_ID` | when push ships (a set but invalid file stops a production start) | file is **secret** | the config reads a file path, so the key must be mounted as a file (Fly: a `[[files]]` entry from a secret; check current docs). Gap: there is no env-var form of this key yet. |
| `FIREBASE_SERVICE_ACCOUNT_FILE` | **yes** (production start check) | file is **secret** | same mounting. Without it an account purge would leave the person's Firebase record (their email) behind, which the privacy policy says does not happen, so production refuses to start without a readable file |
| `SCAN_HASHLIST_FILE` or `SCAN_PROVIDER_URL` + `SCAN_PROVIDER_KEY_FILE` | **yes** with `MEDIA_ENDPOINT` (production start check) | file is **secret** | the upload scanner (section 11). `SCAN_ALLOW_NONE=true` is the loud opt-out for running unscanned |
| `APPLE_SIGN_IN_ENABLED`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `APPLE_PRIVATE_KEY_FILE` | **yes** when the app offers Sign in with Apple | the `.p8` file is **secret** | account deletion revokes Apple's token (App Store guideline 5.1.1(v)); production refuses `APPLE_SIGN_IN_ENABLED=true` without all four |
| `MIGRATIONS_DIR` | no | no | image sets `/migrations` |
| `ENABLE_DEV_AUTH` | **never** | | production refuses it |

Rules: secrets live only in the platform's secret store (`fly secrets set`), never in the repository, the image, `fly.toml` or CI logs. The image contains no secrets. Rotate R2 tokens and `DATABASE_URL` by setting the new value and redeploying.

## 4. First deployment on Fly.io (owner runs these)

Replace `<...>`. Run from the repository root. Check flags against `fly help` (versions move).

```bash
# 1. Account and app
fly auth signup            # or: fly auth login   (interactive, you enter credentials)
fly apps create hiyall-api

# 2. Database: create the managed Postgres you chose (section 2) and note its DIRECT connection string.
#    Create database "hiyall" and a role with a long random password. Require TLS.

# 3. Secrets (values are typed by you; nothing here is stored in the repo)
fly secrets set --app hiyall-api \
  DATABASE_URL='postgresql://hiyall:<password>@<db-host>:5432/hiyall?sslmode=verify-full' \
  MEDIA_ACCESS_KEY=<r2-key> MEDIA_SECRET_KEY=<r2-secret> \
  CHAT_MEDIA_ACCESS_KEY=<r2-chat-key> CHAT_MEDIA_SECRET_KEY=<r2-chat-secret> \
  CURSOR_KEY="$(openssl rand -base64 32)" \
  METRICS_TOKEN="$(openssl rand -hex 24)"
```

Create `fly.toml` (keep it out of the repo, or commit it: it contains no secrets):

```toml
app = "hiyall-api"
primary_region = "bom"          # the region nearest your users

[build]
  dockerfile = "services/api/Dockerfile"

[deploy]
  release_command = "/migrate"  # runs once per release, in a temporary machine, before new machines start
  strategy = "rolling"

[env]
  APP_ENV = "production"
  FIREBASE_PROJECT_ID = "hiyall-prod-1"
  WEB_ORIGIN = "https://app.<your-domain>"
  MEDIA_ENDPOINT = "<account>.r2.cloudflarestorage.com"
  MEDIA_BUCKET = "hiyall"
  MEDIA_REGION = "auto"
  MEDIA_SECURE = "true"
  CHAT_MEDIA_ENDPOINT = "<account>.r2.cloudflarestorage.com"
  CHAT_MEDIA_BUCKET = "hiyall-chat"
  CHAT_MEDIA_REGION = "auto"
  CHAT_MEDIA_SECURE = "true"
  RATE_LIMIT_BACKEND = "postgres"
  BEHIND_PROXY = "true"
  TRUSTED_PROXY_CIDRS = "<see section 4a>"
  CLIENT_IP_HEADER = "Fly-Client-IP"
  GOMEMLIMIT = "400MiB"            # about 80% of the 512 MB machine below
  FIREBASE_SERVICE_ACCOUNT_FILE = "/secrets/firebase-admin.json"   # mounted from a secret, see section 3

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "off"     # sockets and the hourly cleanup need a machine that stays up
  min_machines_running = 2

  [[http_service.checks]]
    method = "GET"
    path = "/readyz"             # database reachable and schema current; liveness is /healthz
    interval = "15s"
    timeout = "3s"
    grace_period = "20s"

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

```bash
# 4. Deploy: builds the image remotely, runs /migrate as the release command, then starts two machines
fly deploy --config fly.toml --dockerfile services/api/Dockerfile --app hiyall-api \
  --build-arg COMMIT="$(git rev-parse --short=12 HEAD)" --build-arg VERSION="$(git describe --tags --always)"
fly scale count 2 --app hiyall-api   # if not already two

# 5. TLS and DNS
fly certs add api.<your-domain> --app hiyall-api
#    create the DNS records fly prints, wait for: fly certs show api.<your-domain>

# 6. Smoke test the real thing
curl -s https://api.<your-domain>/healthz
curl -s https://api.<your-domain>/readyz
fly logs --app hiyall-api            # expect "API listening", no "failed" warnings
fly proxy 9090:9090 --app hiyall-api &   # then, with the token you generated:
curl -s -H "Authorization: Bearer <METRICS_TOKEN>" localhost:9090/metrics | head
```

### 4a. Tell the API which proxy it is behind

The API limits requests per client address. Behind Fly's proxy the TCP peer is always the proxy, so unless the API is told which peers are proxies, every user shares one bucket (50 requests a second) and normal load, or one abuser, makes everyone get 429. Two settings fix that:

- `TRUSTED_PROXY_CIDRS`: the proxy's source addresses, comma separated. Forwarded headers are believed **only** from a peer inside them; a client that reaches the machine another way and sends `Fly-Client-IP` or `X-Forwarded-For` is keyed by its own address, so it cannot pick its bucket. Find the CIDR on a first deploy: set `BEHIND_PROXY=false`, deploy, call `/healthz` once and read the peer address in `fly logs` (the machine's own network, `fdaa::/16` for Fly's private IPv6 network, is the usual value), then set it and `BEHIND_PROXY=true`. On a VPS with Caddy on the same host it is the Docker bridge (`172.16.0.0/12`) or `127.0.0.1/32`.
- `CLIENT_IP_HEADER=Fly-Client-IP` (Cloudflare: `CF-Connecting-IP`): the header the proxy sets and overwrites. Without it the API uses the rightmost `X-Forwarded-For` hop that is not one of your proxies.

At startup the log says which mode is active (`client address: trusted proxies, header ...`, or `direct peer` with a warning). After a deploy, check it, then open the app from two networks and confirm no 429s.

Then point the mobile build at the API (`--dart-define=API_BASE_URL=https://api.<your-domain>`) and run real sign-up and a two-device chat before inviting anyone: neither has been done yet.

Metrics scraping: the first launch needs no scraper. Fly's own dashboards show machine CPU/memory and HTTP status; add an external uptime check on `/readyz` (free tiers of UptimeRobot, Better Stack and similar are enough) and alert on it. When you add Prometheus or Grafana Cloud later, scrape the private `:9090/metrics` with the bearer token. The metrics that matter are in section 7.

### 4b. App Check (owner steps; the server side is built, the app side is not)

App Check ties requests to the real app: the app sends a short-lived Firebase token (`X-Firebase-AppCheck`) that Firebase issues only after Play Integrity (Android) or App Attest (iOS) vouches for the install. It does not replace sign-in, and it stops a script that holds a stolen ID token. The API side is `internal/appcheck` and `httpapi/appcheck.go`: the JWT is verified with RS256 against `https://firebaseappcheck.googleapis.com/v1/jwks`, issuer `https://firebaseappcheck.googleapis.com/<project number>`, audience `projects/<project number>`.

1. Firebase console, Project settings, General: copy the **project number** into `FIREBASE_PROJECT_NUMBER`.
2. Console, App Check: register the Android app with Play Integrity (the Play Console app and the signing certificate fingerprint must match) and the iOS app with App Attest (DeviceCheck as the fallback). Leave enforcement **off** in the console: the API enforces.
3. Add the Flutter plugin (`firebase_app_check`), activate it at start-up after `Firebase.initializeApp`, and send `await FirebaseAppCheck.instance.getToken()` as `X-Firebase-AppCheck` on every API request and on the realtime socket's upgrade request. (Not done: the app does not send the header yet.) Debug builds use the plugin's debug provider with a debug token registered in the console.
4. Ship the app, set `APP_CHECK_ENFORCE=log`, and watch `hiyall_app_check_total{mode="log",result=...}`: `valid` should be nearly everything; `missing` is old app versions; `invalid` is worth a look.
5. When `missing` and `invalid` are small, set `APP_CHECK_ENFORCE=true` (and raise `MIN_CLIENT_VERSION_*` past the versions that cannot send tokens). A request without a valid token then answers `401 APP_CHECK_REQUIRED`; if Firebase's keys cannot be fetched it is `503 APP_CHECK_UNAVAILABLE`, not a sign-out. Health probes, the legal documents and development login never need a token.

## 5. Migrations are a release step

- Migrations ship in the image (`/migrations`) and run with `/migrate` **before** any new API machine starts: Fly's `release_command`, `docker run --entrypoint /migrate ...` on a VPS, or a one-shot `migrate` service in compose. The API never migrates itself.
- `/migrate` takes a database advisory lock for the whole run and applies unapplied files in order, **each in its own transaction** (with its `schema_migrations` row, which stores a SHA-256 checksum; a file that changed after it was applied is refused). A failing file rolls back alone and earlier files stay applied. Every file runs with `lock_timeout` (`MIGRATE_LOCK_TIMEOUT`, 5 s): when it cannot get a table lock it rolls back and retries (up to 8 times, with growing pauses) instead of queueing behind a long query and blocking every request on that table. The whole run has a deadline (`MIGRATE_DEADLINE`, default 10 minutes). Two overlapping releases cannot interleave.
- `/readyz` returns 503 while the database lacks any migration that the running binary ships. If a binary is ever started against an unmigrated database (the release step skipped), it reports not ready and the platform keeps traffic away from it. If the release step fails, the deploy stops and the old machines keep serving.
- **Rule for every migration:** it must work with the release before it (expand, then contract). Add columns and tables in release N; stop using something in N+1; drop it in N+2. There are no down migrations. Rolling back code is safe because `/readyz` accepts a database that is *ahead* of the binary.
- Long locks: avoid `ALTER TABLE` forms that rewrite or lock big tables in a migration that runs on every deploy. A file whose **first line** is `-- hiyall:no-transaction` runs its statements one at a time outside any transaction, which `CREATE INDEX CONCURRENTLY` needs; write such a file so that it can run twice (`IF NOT EXISTS`; drop a half-built invalid index first), because a failure part way leaves what ran in place and the file is attempted again by the next release.

## 6. Backups, PITR and a restore drill

- Enable the provider's automated backups **and** point-in-time recovery, retention at least 7 days. A database that cannot be restored is not a backup; the drill below is what proves it.
- Independent copy: a nightly logical dump to a bucket in a different account or provider (for example a separate R2 bucket with its own token). `scripts/backup-db.sh` does it: `pg_dump --format=custom`, encrypted with `age` (or `gpg`) so nothing reaches the bucket in clear, uploaded with the AWS CLI to any S3-compatible endpoint, plus a small `deleted_users` CSV (the deletion ledger below). Run it from a scheduled job you control, with a read-only database role and a write-only bucket token; the decryption key must not live on that machine. Keep 14 days with a bucket lifecycle rule. It protects against a mistake or an account lockout that PITR cannot. **Not running yet:** nothing schedules it and it has not been run against a real database (`pg_dump` was not available where it was written; only the deletion-replay script was exercised, against throwaway local databases).
- Chat content on the server is ciphertext; the media buckets hold only photos and ciphertext. **R2 has no object versioning** (Cloudflare's S3 compatibility page lists `PutBucketVersioning` and `GetBucketVersioning` as unimplemented, checked 14 October 2026; re-check before relying on this), so a deleted or overwritten object cannot be undeleted from R2 itself. If you need protection against a bad bulk delete or a leaked write token, replicate the buckets periodically to a second bucket in another account (for example `rclone sync` on a schedule, with the destination token unable to delete) and accept that an account deletion intentionally removes objects, so the replica must not be used to resurrect a deleted account's photos (apply the deletion ledger to it too). Lifecycle rules (expire after N days) exist and are what `config/chat-media.example.env` recommends.

**Restoring without bringing deleted people back.** `docs/legal/data-retention.md` promises that deletions are applied again after a restore. The ledger is the `deleted_users` table (an id and a time, nothing else); it lives in the same database, so it is lost with it unless it is copied elsewhere. What exists, honestly:

1. `scripts/backup-db.sh` writes the ledger as a separate encrypted CSV next to every dump, so after a total loss the ledger is at most as old as the last backup. Purges that happened after it cannot be recovered from anything outside the database; that gap (up to one backup interval) is real. Shorten it by running the ledger export more often (the `\copy` line is cheap).
2. After a restore (PITR or dump), and **before the restored API takes traffic**: run `RESTORED_DATABASE_URL=... PROD_DATABASE_URL=... scripts/replay-deletions.sh` (or `--ledger-file <decrypted csv>` if production is gone). It marks every ledger account that the restored database still has as due for deletion. Start the API against the restored database with its normal media and Firebase configuration: its own purge job then performs the deletion exactly as it does in production (the object and Firebase deletions of an already-removed item are no-ops). Finally `scripts/replay-deletions.sh --verify` must print 0 and exit 0.
3. Gaps this does not close: other copies (the bucket replica, the provider's own backups) keep the data until their retention ends, which the privacy policy discloses; and an append-only ledger outside the primary database written at purge time (by the purge job itself) is still a code change in `internal/store/account.go`, not done.

**Restore drill, monthly, and once before launch** (30 to 60 minutes; `scripts/restore-drill.sh --latest` automates steps 2 and 3 against a scratch Postgres with `DRILL_ADMIN_URL`, then step 4's counts):

1. Create a new database instance from the latest backup or PITR to a time 10 minutes ago (the provider's restore action). Never restore over production.
2. Note the new instance's direct URL. From your laptop, run the API image against it with production-like config except a fresh `LISTEN_ADDR` and no media or push credentials: `docker run --rm -p 8081:8080 -e APP_ENV=development -e DATABASE_URL='<restored-url, sslmode as the provider requires>' -e FIREBASE_PROJECT_ID=hiyall-prod-1 hiyall-api` (development mode allows a non-verify-full URL).
3. `curl localhost:8081/readyz` must be 200 (schema current). Count rows in `users`, `messages` and `schema_migrations`; compare with production.
4. Record the elapsed time (this is your real recovery time), delete the restored instance, write the date and result in your ops log. If any step failed, fixing it is the next task, not a nice-to-have.

## 7. Scaling notes: what breaks first

Watch these, in this order. Metric names are on the `METRICS_ADDR` listener.

1. **Database connections and CPU.** Each API machine holds a pool of at most 20 connections (`DB_MAX_CONNS`, or `pool_max_conns` in the URL; `hiyall_db_pool_conns_max`), a separate pool of 4 for the background jobs and the leader lock, and one for the realtime LISTEN connection; add them up across machines against the database's `max_connections`. Every request connection carries a 5 s statement timeout, a 3 s lock timeout and a 15 s idle-in-transaction timeout, so a slow query or a stuck request is cut off instead of piling up; the jobs and the account export use longer limits of their own. A request that hits a limit answers 500 and the log says `canceling statement due to statement timeout` (SQLSTATE 57014) or `lock timeout` (55P03): that is the signal to look at the query. Rising `hiyall_db_pool_empty_acquires_total` and `hiyall_db_pool_acquire_wait_seconds_total` mean requests wait for a connection: first add database CPU/RAM, then read the slow queries; do not simply add machines (more machines means more connections). Authentication needs no write and no row lock for a session already known (one read, plus one update at most once a minute per session), so the busiest path no longer queues on the `users` row.
2. **Per-node presence.** "Online now" is answered from the sockets on the same machine. With more than one machine, a member connected to the other machine looks offline until their session's last activity says otherwise. This is acceptable for the beta (and `hiyall_realtime_connections` shows the split) but is the first user-visible oddity to fix; it needs the realtime bus to carry presence or a shared presence table.
3. **Realtime fan-out over `NOTIFY`.** Every event goes through one PostgreSQL channel to every machine. It suits one region and thousands of concurrent sockets; it is not the design for hundreds of thousands. Measure `hiyall_realtime_connections` and event rate before changing it.
4. **Rate limits multiplied by machine count.** Fixed: set `RATE_LIMIT_BACKEND=postgres` and the per-account limits (first chats, search, reports, uploads, message sends and the rest) are counted once for all machines, at the price of one small indexed write per limited request (`rate_limits`, unlogged, cleaned hourly). The per-address flood guard stays per machine on purpose; put a real per-address limit at the edge (Cloudflare in front of Fly, or Fly's own limits) before opening to the public. If the limiter's database call fails the request is let through and `hiyall_rate_limit_backend_errors_total` rises: alert on it.
5. **Push and cleanup.** Hourly cleanup runs on exactly one machine (advisory lock; `hiyall_maintenance_leader` is 1 on that machine, `hiyall_maintenance_job_runs_total{result="error"}` and `hiyall_maintenance_job_last_run_timestamp_seconds` show health). The push queue is per machine and bounded; dropped wake-ups only delay delivery.
   Retention jobs (migration `0033`, `cmd/api/retention.go`): notifications at 90 days, closed reports (with their actions) at 180 days unless they hold encrypted evidence, soft-deleted posts, comments and space entries blanked after 1 day and deleted after 30, message metadata at 180 days (never rows a report names, with an attachment or still undelivered), finished photo rows at 30 days. Counters kept at write time (`social_counters` by triggers, `post_counters`, `spaces.member_count`) are recomputed once a week by the `* reconcile` jobs, which remember their place in `reconcile_state`; `hiyall_maintenance_job_rows_total{job="social counter reconcile"}` above zero means a counter had drifted. Indexes added after launch must use `CREATE INDEX CONCURRENTLY`.
6. **Media.** Objects go to R2 and downloads use short-lived presigned URLs, so bandwidth does not touch the API; image processing is capped at 4 concurrent jobs per machine (CPU) and one photo may be at most 20 megapixels (a decoded 20 MP image is about 80 MB, four at once about 320 MB before the re-encoded copies). Finishing an upload may take up to 30 s (`POST /v1/media/{id}/complete` has its own deadline and a per-account limiter; every other request has 10 s). **Set `GOMEMLIMIT`** (about 80% of the machine's memory: `400MiB` on a 512 MB machine, in `fly.toml` `[env]`): it is a Go runtime variable, not read by the API, and it makes the garbage collector work harder before the machine runs out of memory and is killed. Watch `go_memstats_heap_inuse_bytes`, `go_memstats_sys_bytes`, `go_gc_pause_seconds_total` and machine CPU when photo uploads grow.

Baseline alerts to create on day one: `/readyz` failing for 2 minutes; `rate(hiyall_http_requests_total{status_class="5xx"}[5m])` above 1% of requests; `hiyall_http_request_duration_seconds` p95 above 1 s; `hiyall_db_pool_conns_acquired == hiyall_db_pool_conns_max` for 5 minutes; `time() - hiyall_maintenance_job_last_run_timestamp_seconds{job="session purge"} > 7200`; `hiyall_http_panics_total` increasing; `increase(hiyall_push_config_errors_total[15m]) > 0` (FCM refused the push because of our configuration, tokens are kept; check `FCM_SERVICE_ACCOUNT_FILE` against the app's Firebase project); `increase(hiyall_maintenance_job_runs_total{result=~"error|timeout"}[1h]) > 0` for `media cleanup` and `account purge` (objects not removed, retried every hour); a 426 rate (`status_class="4xx"` on every route) right after setting `MIN_CLIENT_VERSION_*` is expected, not an incident.

## 8. Rollback

- **Code:** redeploy the previous image. On Fly: `fly releases --image --app hiyall-api` to find it, then `fly deploy --image <previous image> --app hiyall-api` (note the release command runs again; it is a no-op when the schema is current). On a VPS: `docker run` the previous tag. Keep the last three image tags; tag images with the git commit. The running commit and version are in the startup log (`starting version=... commit=...`) and in the metric `hiyall_build_info{version,commit}`: after any deploy, check that the metric shows the commit you meant to ship.
- **Database:** there is no down migration. Because every migration is backward compatible with the release before it (section 5), the old code runs on the new schema, and `/readyz` allows it. If a migration itself damaged data, restore with PITR to a new instance (section 6), verify, then switch `DATABASE_URL`; that is an incident, not a rollback.
- **Configuration:** `fly secrets set` triggers a redeploy; to undo, set the old value again.

## 8b. Release pipeline (tags)

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`: the Go tests, then the API image is built and pushed to GHCR **by digest** (only that job has `packages: write`), an SBOM is generated, the Android bundle and the iOS IPA are built through `scripts/build-release.sh` when the signing secrets exist (otherwise those jobs say they were skipped), everything is attached to a **draft** GitHub release, and finally the migration job waits for a reviewer to approve the `production` environment before it runs `/migrate` from the image against the production database. Nothing deploys the API: after the migration you roll out the digest yourself (`fly deploy --image ghcr.io/<owner>/<repo>/api@sha256:...`). One-time owner setup is in [11-environments.md](11-environments.md). The workflow has never run.

## 9. Local smoke test of the deploy mechanics (no cloud, no real secrets)

Requires Docker. Builds the image, starts Postgres, runs `/migrate` as a one-shot release step, then the API, with metrics behind a token:

```bash
docker compose -f infrastructure/docker/compose.prod-like.yml up --build --abort-on-container-exit
# in another shell:
curl -s localhost:8080/healthz && curl -s localhost:8080/readyz
curl -s -H 'Authorization: Bearer smoke-test-metrics-token' localhost:9090/metrics | head -20
docker compose -f infrastructure/docker/compose.prod-like.yml ps      # api shows "healthy"
docker compose -f infrastructure/docker/compose.prod-like.yml down -v
```

The compose API runs with `APP_ENV=development` because its Postgres has no TLS (production demands `sslmode=verify-full`) and with a project id that does not exist, so real sign-in does not work there. CI runs the same sequence (build, `/migrate`, start, `/readyz`, metrics) in the `docker` job of `.github/workflows/foundation.yml`; that job and this compose file have not yet been run because Docker was unavailable when they were written.

## 10. Runbook: the five most likely incidents

For all of them: find the request id from the client or the logs (`X-Request-Id` is on every response and in every log line), check `/readyz`, then `fly logs` / `docker logs`. Logs never contain tokens, message bodies, presigned URLs or query strings; if one ever does, treat that as a bug and rotate the secret.

**1. A bad release (5xx up, panics, crash loop).**
Symptoms: alert on 5xx or `hiyall_http_panics_total`; machines restarting. Action: roll back the code (section 8) first, investigate second. The panic log line has the route pattern, the request id and the stack. Afterwards: add a test for the failing route, then redeploy.

**2. The database is down or saturated.**
Symptoms: `/readyz` 503 "Database unavailable", `NOT_READY` from the platform's checks, requests slow, `hiyall_db_pool_conns_acquired` at max, `hiyall_db_pool_empty_acquires_total` climbing. Liveness (`/healthz`) stays 200 on purpose so machines are not restarted in a loop. Action: check the provider status and the database's CPU/connection count; kill runaway queries (`SELECT * FROM pg_stat_activity ORDER BY query_start`); scale the database up. If it is gone, restore to a new instance (section 6) and switch `DATABASE_URL`. Sockets drop and the app reconnects; the server sends a resync signal and chat state is fetched over HTTP, so nothing is lost.

**3. A migration failed during a deploy.**
Symptoms: the release command fails; `fly deploy` stops; old machines keep serving (their `/readyz` is unaffected). Action: read the release logs for `migration <file>: ...`; do not edit an applied migration (checksum check will refuse it). Fix forward with a new migration file or fix the data, then deploy again. If `/readyz` says "schema is behind this release" on a running machine, someone deployed the binary without running `/migrate`: run it.

**4. Sign-in failing for everyone (401 or `AUTH_UNAVAILABLE` 503).**
Symptoms: all authenticated routes fail; `/healthz` fine. Causes in order of likelihood: the API cannot fetch Firebase's signing keys (network egress or Google outage: 503 `AUTH_UNAVAILABLE`); `FIREBASE_PROJECT_ID` is wrong after a config change (401 for every token); the clients are using another Firebase project. Action: check Google's status, check the effective `FIREBASE_PROJECT_ID`, read the verification error in `fly logs` (the image has no shell to exec into) and redeploy the previous config. Existing sessions do not need Google once keys are cached; new sign-ins do.

**5. Photos fail (503 `MEDIA_UNAVAILABLE` or `CHAT_MEDIA_UNAVAILABLE`, uploads rejected, images not loading).**
Symptoms: the app shows photo errors; the API log says "storage failed" with an error code (never a URL). Causes: the R2 token was revoked or scoped to the wrong bucket (403), the endpoint or bucket name is wrong after a config change, or R2 has an incident. Action: check Cloudflare status; confirm `MEDIA_*` / `CHAT_MEDIA_*` values; roll the token (create a new bucket-scoped token, `fly secrets set`, redeploy). Text chat and everything else keep working while media is down. The hourly cleanup retries object deletion, so a short R2 outage self-heals.

Not on the list but likely soon: an abuse spike (watch `hiyall_rate_limit_rejections_total{limiter=...}`; tighten at the edge first, then in code) and a reconnect storm after a deploy (watch `hiyall_realtime_connections` recover; the rolling strategy replaces one machine at a time, so only that machine's sockets reconnect).

## 11. Admin console, database roles and upload scanning

These are owner steps; none was run for you. Design: [admin console](../security/15-admin-console.md); the illegal-content procedure: [runbook 16](../security/16-csam-and-illegal-content.md).

**Database roles (once, then after every migration).** Production runs three roles instead of one: `hiyall_migrate` (owns the schema; only the release step uses it), `hiyall_api` (the API: no access to the operator tables) and `hiyall_admin` (the console: INSERT and SELECT only on the audit log). Create them with a superuser or `CREATEROLE` user, give each a password, and hand over an existing database:

```bash
psql "$SUPERUSER_URL" -v ON_ERROR_STOP=1 -f database/roles/roles.sql          # creates the NOLOGIN roles and the grants
psql "$SUPERUSER_URL" -c "ALTER ROLE hiyall_api LOGIN PASSWORD '<long random>'" # same for hiyall_admin, hiyall_migrate
psql "$SUPERUSER_URL" -c "REASSIGN OWNED BY <current owner> TO hiyall_migrate"  # only for a database that already exists
```

Then: the release step (`fly release_command = "/migrate"`) connects as `hiyall_migrate`; the API's `DATABASE_URL` is `hiyall_api`; and **re-run `roles.sql` after each release's migrations** (add it to the release step, or run it by hand; it is idempotent). A table the script does not know is unreachable by the API and the console, so forgetting it breaks loudly instead of leaving a new table open. `/readyz` is unaffected. Managed databases that forbid `CREATE ROLE` for the owner role: create the three roles in the provider's console and run the rest of the script as the owner.

**Admin console.** A second app, never on the public internet. Build: `docker build -f services/api/Dockerfile.admin -t hiyall-admin .` (the image holds `/admin` and the built UI in `/console`; CI builds it and fetches the UI on every change). Run it where only staff can reach it: a private Fly app reached through `fly proxy` or WireGuard, or a VPS behind an identity-aware proxy. Settings:

| Variable | Value |
|---|---|
| `APP_ENV` | `production` |
| `ADMIN_DATABASE_URL` | the `hiyall_admin` role, `sslmode=verify-full`. Production refuses to start on the API's `DATABASE_URL` unless `ADMIN_ALLOW_SHARED_DB=true` |
| `ADMIN_DATA_KEY` | `openssl rand -base64 32`, a secret; losing it means re-enrolling every operator |
| `ADMIN_ADDR`, `ADMIN_ALLOW_REMOTE`, `ADMIN_TRUST_PROXY`, `ADMIN_ALLOWED_HOSTS` | `0.0.0.0:8081`, `true`, `true` (only behind your TLS terminating proxy), `admin.<your-private-domain>`. Without them it listens on loopback only |
| `ADMIN_MEDIA_ENDPOINT`, `ADMIN_MEDIA_BUCKET`, `ADMIN_MEDIA_REGION`, `ADMIN_MEDIA_SECURE` | the same R2 bucket as the API, `true` for secure; optional (without them the console shows text only) |
| `ADMIN_MEDIA_ACCESS_KEY`, `ADMIN_MEDIA_SECRET_KEY` | a **read-only** R2 token scoped to the media bucket (object read), not the API's write token |

Create the first administrator on the machine (the password is read from the terminal, never a flag): `fly ssh console -a hiyall-admin -C "/admin operator-add -email you@example.org -role admin"`. The command prints the authenticator secret once.

**Upload scanner.** Obtain a hash list or provider ([runbook 16](../security/16-csam-and-illegal-content.md#2-the-upload-scanner)), mount the list as a secret file, set `SCAN_HASHLIST_FILE` (or the provider variables) on the **API**, and confirm the startup log line `upload scanner: hash list` (or `provider`). Production refuses to start with `MEDIA_ENDPOINT` set and no scanner. Also enable Cloudflare's **CSAM Scanning Tool** on the media zone (dashboard, owner action; runbook section 3), and fill in the contacts in runbook section 7.

**Sign in with Apple.** Create a Sign in with Apple key in the Apple developer account (Keys), note the Key ID and Team ID, set `APPLE_*` on the API and mount the `.p8` as a secret file. The app sends the Apple authorization code with the deletion request; unset, deletion works and logs a warning, and production with `APPLE_SIGN_IN_ENABLED=true` refuses to start without all four.
