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
| `AGE_BAND_ISOLATION` | no | no | leave `true` |
| `MEDIA_ENDPOINT`, `MEDIA_BUCKET`, `MEDIA_REGION`, `MEDIA_SECURE` | for photos | no | `<account>.r2.cloudflarestorage.com`, `hiyall`, `auto`, `true` |
| `MEDIA_ACCESS_KEY`, `MEDIA_SECRET_KEY` | with `MEDIA_ENDPOINT` | **yes** | bucket-scoped R2 token |
| `CHAT_MEDIA_ENDPOINT`, `CHAT_MEDIA_BUCKET`, `CHAT_MEDIA_REGION`, `CHAT_MEDIA_SECURE` | for chat photos | no | same shape, bucket `hiyall-chat` |
| `CHAT_MEDIA_ACCESS_KEY`, `CHAT_MEDIA_SECRET_KEY` | with `CHAT_MEDIA_ENDPOINT` | **yes** | a different token, scoped to the chat bucket only |
| `RATE_LIMIT_BACKEND` | no | no | `postgres` once you run more than one API machine (default `memory`) |
| `METRICS_ADDR` | no | no | default is loopback `127.0.0.1:9090`, unreachable from outside the machine; leave it, or set `0.0.0.0:9090` **and** `METRICS_TOKEN` and keep the port private |
| `METRICS_TOKEN` | if `METRICS_ADDR` is not loopback | **yes** | `openssl rand -hex 24` |
| `FCM_SERVICE_ACCOUNT_FILE`, `FCM_PROJECT_ID` | when push ships | file is **secret** | the config reads a file path, so the key must be mounted as a file (Fly: a `[[files]]` entry from a secret; check current docs). Gap: there is no env-var form of this key yet. |
| `FIREBASE_SERVICE_ACCOUNT_FILE` | when account deletion ships | file is **secret** | same mounting |
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
fly deploy --config fly.toml --dockerfile services/api/Dockerfile --app hiyall-api
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

Then point the mobile build at the API (`--dart-define=API_BASE_URL=https://api.<your-domain>`) and run real sign-up and a two-device chat before inviting anyone: neither has been done yet.

Metrics scraping: the first launch needs no scraper. Fly's own dashboards show machine CPU/memory and HTTP status; add an external uptime check on `/readyz` (free tiers of UptimeRobot, Better Stack and similar are enough) and alert on it. When you add Prometheus or Grafana Cloud later, scrape the private `:9090/metrics` with the bearer token. The metrics that matter are in section 7.

## 5. Migrations are a release step

- Migrations ship in the image (`/migrations`) and run with `/migrate` **before** any new API machine starts: Fly's `release_command`, `docker run --entrypoint /migrate ...` on a VPS, or a one-shot `migrate` service in compose. The API never migrates itself.
- `/migrate` takes a database advisory lock, applies unapplied files in order inside one transaction, records a SHA-256 checksum, and refuses a file that changed after it was applied. Two overlapping releases cannot interleave.
- `/readyz` returns 503 while the database lacks any migration that the running binary ships. If a binary is ever started against an unmigrated database (the release step skipped), it reports not ready and the platform keeps traffic away from it. If the release step fails, the deploy stops and the old machines keep serving.
- **Rule for every migration:** it must work with the release before it (expand, then contract). Add columns and tables in release N; stop using something in N+1; drop it in N+2. There are no down migrations. Rolling back code is safe because `/readyz` accepts a database that is *ahead* of the binary.
- Long locks: avoid `ALTER TABLE` forms that rewrite or lock big tables in a migration that runs on every deploy; create indexes `CONCURRENTLY` in a separate release if a table grows large (the runner uses one transaction, so `CREATE INDEX CONCURRENTLY` cannot run in it today: plan an out-of-band step for that case).

## 6. Backups, PITR and a restore drill

- Enable the provider's automated backups **and** point-in-time recovery, retention at least 7 days. A database that cannot be restored is not a backup; the drill below is what proves it.
- Independent copy: a nightly logical dump to a bucket in a different account or provider (for example a separate R2 bucket with its own token). Run it from a scheduled job you control: `pg_dump --format=custom --no-owner "$DATABASE_URL" | <upload>`; keep 14 days and encrypt it. It protects against a mistake or an account lockout that PITR cannot.
- Chat content on the server is ciphertext; the media buckets hold only photos and ciphertext. R2 has no cross-bucket backup by itself: enable bucket versioning/lifecycle rules per the Cloudflare docs if you need undelete, and know that deleting an account intentionally removes objects.

**Restore drill, monthly, and once before launch** (30 to 60 minutes):

1. Create a new database instance from the latest backup or PITR to a time 10 minutes ago (the provider's restore action). Never restore over production.
2. Note the new instance's direct URL. From your laptop, run the API image against it with production-like config except a fresh `LISTEN_ADDR` and no media or push credentials: `docker run --rm -p 8081:8080 -e APP_ENV=development -e DATABASE_URL='<restored-url, sslmode as the provider requires>' -e FIREBASE_PROJECT_ID=hiyall-prod-1 hiyall-api` (development mode allows a non-verify-full URL).
3. `curl localhost:8081/readyz` must be 200 (schema current). Count rows in `users`, `messages` and `schema_migrations`; compare with production.
4. Record the elapsed time (this is your real recovery time), delete the restored instance, write the date and result in your ops log. If any step failed, fixing it is the next task, not a nice-to-have.

## 7. Scaling notes: what breaks first

Watch these, in this order. Metric names are on the `METRICS_ADDR` listener.

1. **Database connections and CPU.** Each API machine holds a pool of at most 10 connections (`hiyall_db_pool_conns_max`), plus one for the realtime LISTEN connection and one for the maintenance leader. Rising `hiyall_db_pool_empty_acquires_total` and `hiyall_db_pool_acquire_wait_seconds_total` mean requests wait for a connection: first add database CPU/RAM, then read the slow queries; do not simply add machines (more machines means more connections). The pool size is a code constant today.
2. **Per-node presence.** "Online now" is answered from the sockets on the same machine. With more than one machine, a member connected to the other machine looks offline until their session's last activity says otherwise. This is acceptable for the beta (and `hiyall_realtime_connections` shows the split) but is the first user-visible oddity to fix; it needs the realtime bus to carry presence or a shared presence table.
3. **Realtime fan-out over `NOTIFY`.** Every event goes through one PostgreSQL channel to every machine. It suits one region and thousands of concurrent sockets; it is not the design for hundreds of thousands. Measure `hiyall_realtime_connections` and event rate before changing it.
4. **Rate limits multiplied by machine count.** Fixed: set `RATE_LIMIT_BACKEND=postgres` and the per-account limits (first chats, search, reports, uploads, message sends and the rest) are counted once for all machines, at the price of one small indexed write per limited request (`rate_limits`, unlogged, cleaned hourly). The per-address flood guard stays per machine on purpose; put a real per-address limit at the edge (Cloudflare in front of Fly, or Fly's own limits) before opening to the public. If the limiter's database call fails the request is let through and `hiyall_rate_limit_backend_errors_total` rises: alert on it.
5. **Push and cleanup.** Hourly cleanup runs on exactly one machine (advisory lock; `hiyall_maintenance_leader` is 1 on that machine, `hiyall_maintenance_job_runs_total{result="error"}` and `hiyall_maintenance_job_last_run_timestamp_seconds` show health). The push queue is per machine and bounded; dropped wake-ups only delay delivery.
6. **Media.** Objects go to R2 and downloads use short-lived presigned URLs, so bandwidth does not touch the API; image processing is capped at 4 concurrent jobs per machine (CPU). Watch machine CPU when photo uploads grow.

Baseline alerts to create on day one: `/readyz` failing for 2 minutes; `rate(hiyall_http_requests_total{status_class="5xx"}[5m])` above 1% of requests; `hiyall_http_request_duration_seconds` p95 above 1 s; `hiyall_db_pool_conns_acquired == hiyall_db_pool_conns_max` for 5 minutes; `time() - hiyall_maintenance_job_last_run_timestamp_seconds{job="session purge"} > 7200`; `hiyall_http_panics_total` increasing.

## 8. Rollback

- **Code:** redeploy the previous image. On Fly: `fly releases --image --app hiyall-api` to find it, then `fly deploy --image <previous image> --app hiyall-api` (note the release command runs again; it is a no-op when the schema is current). On a VPS: `docker run` the previous tag. Keep the last three image tags; tag images with the git commit.
- **Database:** there is no down migration. Because every migration is backward compatible with the release before it (section 5), the old code runs on the new schema, and `/readyz` allows it. If a migration itself damaged data, restore with PITR to a new instance (section 6), verify, then switch `DATABASE_URL`; that is an incident, not a rollback.
- **Configuration:** `fly secrets set` triggers a redeploy; to undo, set the old value again.

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
