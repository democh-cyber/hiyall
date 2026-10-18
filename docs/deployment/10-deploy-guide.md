# Deploy guide: the first production path for a small team

**Status, 13 October 2026.** Written, not rehearsed. Nothing has been deployed. The container image has not been built with Docker on any machine that wrote this (Docker was not installed); the static Linux binaries (`CGO_ENABLED=0`, same flags as the Dockerfile) were built and the Go tests, the health, metrics, leader-election and shared-limiter code were run against a local PostgreSQL. Every command below is for the **owner** to run; it creates accounts and spends money, so none of it was run for you. Prices are orders of magnitude from memory, not quotes: check each pricing page before you commit.

This guide covers the API (`services/api`). Media lives in Cloudflare R2 and sign-in in Firebase. Today those are **development** resources (the development buckets and the development Firebase project, listed in `config/environments.json`); production needs its own (`hiyall-prod`, `hiyall-chat-prod`, `hiyall-evidence-prod` and a new Firebase project; see [11-environments.md](11-environments.md)), and the release preflight refuses a production configuration that reuses the development ones. For capacity maths and the later multi-region picture see [09-capacity-and-operations.md](09-capacity-and-operations.md); this page is the small, boring start.

## 1. The recommendation

**Run the API on Fly.io (two always-on machines in one region near your users) with a managed PostgreSQL 16 that has point-in-time recovery, and keep R2 for media.** Reasons, specific to this codebase:

- The API is one static Go binary with a WebSocket endpoint. It needs machines that stay up (the hourly cleanup loop and the realtime sockets die with scale-to-zero) and a platform that lets sockets live for hours. Fly runs ordinary always-on containers with TLS in front.
- Releases need a "run `/migrate` first, then start the new version" step, and `/migrate` needs the **owner** role (`hiyall_migrate`), which the API must never hold. So the migration runs outside the app: from the release workflow's `migrate-production` job, or from your laptop or a one-off machine, with `MIGRATE_DATABASE_URL`. It is **not** a Fly `release_command` and the migration URL is **not** an app secret (section 5). The image already contains `/migrate`.
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
| Managed PostgreSQL 16 with PITR | provider of your choice | Same region as the API. Create database `hiyall`; the three roles come from `database/roles/roles.sql` (section 11): `hiyall_migrate` (owner, release step only), `hiyall_api` (the API) and `hiyall_admin` (the console), each with its own long random password. TLS on; download the CA if the provider uses a private one. |
| Domain and DNS | your registrar | `api.<your-domain>` for the API. |
| A production Firebase project | create it (not `hiyall-prod-1`, which is the development project) | Add your web origin to Authorized domains if you serve the web app. Real sign-up has not been tested yet. |
| FCM service-account key | Firebase console | Only when push ships. Not needed for first deploy; pushes are logged without it. |
| R2 buckets and tokens | already created | The production tokens should be new ones limited to their bucket; do not reuse the development tokens. |
| Terms of Service and Privacy Policy | `docs/legal` (drafts) | Needs legal review before real users. |

## 3. Environment and secrets checklist

Authoritative list with every variable, default and rule: [`infrastructure/docker/api.example.env`](../../infrastructure/docker/api.example.env). For production:

| Variable | Required | Secret | Value |
|---|---|---|---|
| `APP_ENV` | yes | no | `production` |
| `DATABASE_URL` | yes | **yes** | the **`hiyall_api`** role (never the owner or a superuser), direct connection, `sslmode=verify-full` (the API refuses to start otherwise). `MIGRATE_DATABASE_URL` (`hiyall_migrate`) is **not** an API variable: it belongs only to the migration step |
| `LISTEN_ADDR` | no | no | image default `0.0.0.0:8080` |
| `FIREBASE_PROJECT_ID` | yes | no | the production Firebase project id (never the development one; preflight gate d) |
| `WEB_ORIGIN` | if you serve the web app | no | `https://app.<your-domain>` (https origin only) |
| `AGE_BAND_ISOLATION` | no | no | leave `true`; `false` is refused in production |
| `MEDIA_ENDPOINT`, `MEDIA_BUCKET`, `MEDIA_REGION`, `MEDIA_SECURE` | for photos | no | `<account>.r2.cloudflarestorage.com`, `hiyall-prod`, `auto`, `true` |
| `MEDIA_ACCESS_KEY`, `MEDIA_SECRET_KEY` | with `MEDIA_ENDPOINT` | **yes** | bucket-scoped R2 token |
| `CHAT_MEDIA_ENDPOINT`, `CHAT_MEDIA_BUCKET`, `CHAT_MEDIA_REGION`, `CHAT_MEDIA_SECURE` | for chat photos | no | same shape, bucket `hiyall-chat-prod` |
| `CHAT_MEDIA_ACCESS_KEY`, `CHAT_MEDIA_SECRET_KEY` | with `CHAT_MEDIA_ENDPOINT` | **yes** | a different token, scoped to the chat bucket only |
| `RATE_LIMIT_BACKEND` | **yes** | no | `postgres`; production refuses to start with `memory` (the per-node limiters evict keys and multiply with machines) |
| `TRUSTED_PROXY_CIDRS`, `BEHIND_PROXY`, `CLIENT_IP_HEADER`, `DIRECT_LISTENER` | **yes** (one of the two modes) | no | `BEHIND_PROXY=true`, the proxy's CIDR blocks, `CLIENT_IP_HEADER=Fly-Client-IP` on Fly; **or** `DIRECT_LISTENER=true` when nothing is in front. Production refuses to start with neither, and with `BEHIND_PROXY=true` and no CIDRs (every client would share the proxy's bucket). `DEBUG_LOG_PEER` is a temporary aid (section 4a). The chosen mode is logged at startup |
| `CURSOR_KEY` | **yes** | **yes** | `openssl rand -base64 32`, the same on every machine. Rotate with `CURSOR_KEY_PREVIOUS` (keep the old key for 15 minutes) |
| `NEARBY_OFFSET_KEY` | **yes** | **yes** | `openssl rand -base64 32`. Keys the stable per-member offset applied to a shared Nearby point (up to 2 km, 5 km for minors; docs/api/19). Do not rotate casually: a new key moves every member's stored point once, at their next update. `NEARBY_OFFSET_KEY_PREVIOUS` may be written down during a rotation and is ignored |
| `MEDIA_PROCESS_SLOTS` | no | no | default `2`: photo uploads decoded at once per machine (the rest wait 4 s, then get 503 `MEDIA_BUSY` with Retry-After). Memory table in section 7, item 6 |
| `EXPORT_CONCURRENCY` | no | no | default `3`: data exports built at once per machine (a fourth gets 503 `EXPORT_BUSY`, and keeps its daily export) |
| `EVIDENCE_BUCKET`, `EVIDENCE_ENDPOINT`, `EVIDENCE_REGION`, `EVIDENCE_SECURE` | **yes** with `MEDIA_ENDPOINT` | no | a bucket of its own for quarantined originals (`hiyall-evidence-prod`); endpoint, region and TLS default to the media bucket's |
| `EVIDENCE_ACCESS_KEY`, `EVIDENCE_SECRET_KEY` | with `EVIDENCE_BUCKET` | **yes** | the API's token for that bucket. It is **meant** to be write-only (no read, no delete), but **Cloudflare R2 cannot scope a token that way** (object read-and-write includes delete), so do not assume it: put an **R2 bucket-lock retention rule** on the evidence bucket and prove what the token can do with `api check-config -release -net` (the canary below) |
| `EVIDENCE_CANARY`, `EVIDENCE_ALLOW_API_DELETE`, `EVIDENCE_CANARY_ACCEPT_UNLOCKED` | no | no | `EVIDENCE_CANARY=true` runs the canary at every start; `api check-config -release -net` runs it once (writes a probe object, `canary/<UTC date>`, then tries to read and delete it with the API's credential). `EVIDENCE_ALLOW_API_DELETE=true` **declares** that the evidence bucket has a bucket-lock rule, and the canary **verifies it**: the probe must survive a delete by the API's credential. A probe that CAN be deleted fails the check and refuses a production start, whatever `EVIDENCE_ALLOW_API_DELETE` says, unless `EVIDENCE_CANARY_ACCEPT_UNLOCKED=true` (an explicit, knowing acceptance of the risk; a warning). A token that can read but not delete needs `EVIDENCE_ALLOW_API_DELETE=true`. A probe that cannot be written (an R2 outage) never stops a start: it is retried in the background; only `check-config -release -net` fails on it. The lock rule must cover `canary/` too. At most one tiny object per day stays (a lock keeps it). The API also writes `evidence-bucket-id` (its bucket name) into the bucket at start, which the console's sweep and purge compare with `ADMIN_EVIDENCE_BUCKET` before they do anything |
| `EVIDENCE_ALLOW_SHARED_BUCKET` | no | no | `true` keeps quarantined originals in the media bucket under `hold/`, where the API's own token could delete them. Production refuses to start without `EVIDENCE_BUCKET` unless this is set |
| `EVIDENCE_RETENTION_DAYS` | no | no | default `365` (one year, pending counsel; LEGAL-2); **production refuses less than 365**. Applies to NEW quarantine cases only; existing cases keep their `hold_until`. A case marked `reported` is held until at least a year after the report |
| `NEARBY_ACCOUNTS_PER_ADDRESS` | no | no | default `500`: how many different accounts one source address (an IPv6 /64, an IPv4 address) may use Nearby from per UTC day. **Behind carrier-grade NAT (CGNAT), a campus or a school thousands of people share one address**; it is a ceiling against account farms, not a quota. Request limits do not have this problem: the strict 50 requests a second per address applies to requests without a token and to tokens that fail verification, while signed-in traffic is held only to a 500 a second flood backstop per address (and 8000 a second per machine) and is otherwise limited per account. Many `429 DAILY_LIMIT` for Nearby from different members means the ceiling is too low, or `TRUSTED_PROXY_CIDRS` is wrong and every client looks like the proxy (section on client addresses) |
| `DB_MAX_CONNS`, `DB_STATEMENT_TIMEOUT`, `DB_LOCK_TIMEOUT`, `DB_IDLE_IN_TRANSACTION_TIMEOUT` | no | no | default pool 20 per machine; per-connection limits 5s, 3s, 15s (a `pool_max_conns` in `DATABASE_URL` wins over `DB_MAX_CONNS`) |
| `MIN_CLIENT_VERSION_ANDROID`, `_IOS`, `_WEB` | **yes for a release** (`check-config -release`) | no | the oldest app version still allowed; older clients get 426 `UPGRADE_REQUIRED`. Set it **before** running `check-config -release`. For the first release use `1.0.0`, the version being shipped: no installed app is older, so nobody is locked out (runbook step 5.1) |
| `APP_CHECK_ENFORCE`, `FIREBASE_PROJECT_NUMBER` | no (recommended for launch) | no | `false` (default), `log`, then `true` once App Check is set up (see "App Check" below). `FIREBASE_PROJECT_NUMBER` is the numeric project number, required for `log` and `true` |
| `LOG_FORMAT` | no | no | default `json` in production |
| `GOMEMLIMIT` | recommended | no | about 80% of the machine's memory, `400MiB` on a 512 MB machine (see section 7, item 6) |
| `METRICS_ADDR` | no | no | default is loopback `127.0.0.1:9090`, unreachable from outside the machine; leave it, or set `0.0.0.0:9090` **and** `METRICS_TOKEN` and keep the port private |
| `METRICS_TOKEN` | if `METRICS_ADDR` is not loopback | **yes** | `openssl rand -hex 24` |
| `FCM_SERVICE_ACCOUNT_FILE`, `FCM_PROJECT_ID` | when push ships (a set but invalid file stops a production start) | file is **secret** | the config reads a file path, so the key must be mounted as a file (Fly: a `[[files]]` entry from a secret; check current docs). Gap: there is no env-var form of this key yet. |
| `FIREBASE_SERVICE_ACCOUNT_FILE` | **yes** (production start check) | file is **secret** | same mounting. Without it an account purge would leave the person's Firebase record (their email) behind, which the privacy policy says does not happen, so production refuses to start without a readable file |
| `SCAN_HASHLIST_FILE` or `SCAN_PROVIDER_URL` + `SCAN_PROVIDER_KEY_FILE` | **yes** with `MEDIA_ENDPOINT` (production start check) | file is **secret** | the upload scanner (section 11). `SCAN_ALLOW_NONE=true` is the loud opt-out for running unscanned |
| `APPLE_SIGN_IN_ENABLED`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `APPLE_PRIVATE_KEY_FILE` | **yes** when the app offers Sign in with Apple | the `.p8` file is **secret** | account deletion revokes Apple's token (App Store guideline 5.1.1(v)) when the app sends the authorization code; **without one nobody at Hiyall can revoke it for the member** (the revoke call needs their token, the developer portal has no per-user revoke), so the app tells them to remove the app's access in Apple ID settings; production refuses `APPLE_SIGN_IN_ENABLED=true` without all four. `api check-config -release` (also `-db`, `-net`) **probes Apple**: it asks `/auth/token` to exchange a deliberately invalid code; `invalid_grant` means the credentials work, `invalid_client` fails the check (wrong team, key or client id), and no network is a warning only |
| `MIGRATIONS_DIR` | no | no | image sets `/migrations` |
| `ENABLE_DEV_AUTH` | **never** | | production refuses it |

**Owner and migration credentials stay out of the API's environment.** A production API **refuses to start** while any of an **explicit list of console and migrate variable names** is set in its process (`config.OwnerVariableNames`, kept complete by a test; not a prefix match, so platform variables such as Kubernetes service links, `ADMIN_SERVICE_HOST`, never trip it; `MIGRATE_DATABASE_URL` is the table owner, `ADMIN_DATABASE_URL` and `ADMIN_EVIDENCE_*` are the console's): whoever got code execution in the API would read them and defeat the least-privilege roles. They belong to the `admin` and `/migrate` processes only (`config/migrate.production.example.env`, `config/admin.production.example.env`); `api check-config` applies the same rule, so run it with the API's own environment. **Check an environment before deploying it:** `/api check-config` (the image's entrypoint; `fly ssh console -C "/api check-config -release"`, or `go run ./cmd/api check-config -release` with the variables exported) loads the environment exactly as a start does, parses the key files, and prints every problem by variable name without printing any value; `-release` adds the V1 requirements (FCM, Sentry, Apple revocation, minimum client versions, real buckets). Exit 1 on any problem. `config.Load` reports its first refusal only, so rerun until it passes. The ordered release procedure is [the release runbook](12-release-runbook.md).

Rules: secrets live only in the platform's secret store (`fly secrets set`), never in the repository, the image, `fly.toml` or CI logs. The image contains no secrets. Rotate R2 tokens and `DATABASE_URL` by setting the new value and redeploying.

## 4. First deployment on Fly.io (owner runs these)

Replace `<...>`. Run from the repository root. Check flags against `fly help` (versions move).

```bash
# 1. Account and app
fly auth signup            # or: fly auth login   (interactive, you enter credentials)
fly apps create hiyall-api

# 2. Database: create the managed Postgres you chose (section 2) and note its DIRECT connection string.
#    Create database "hiyall", then the three roles (section 11: roles.sql once, then a password for each). Require TLS.

# 3. Secrets (values are typed by you; nothing here is stored in the repo). The app's DATABASE_URL is the RESTRICTED role
#    hiyall_api. The owner role's URL (hiyall_migrate) is NOT set here: it would sit in the running API's environment, and a
#    compromise of the process would then hold the owner of every table (the API refuses to start in production with it).
fly secrets set --app hiyall-api \
  DATABASE_URL='postgresql://hiyall_api:<password>@<db-host>:5432/hiyall?sslmode=verify-full' \
  MEDIA_ACCESS_KEY=<r2-key> MEDIA_SECRET_KEY=<r2-secret> \
  CHAT_MEDIA_ACCESS_KEY=<r2-chat-key> CHAT_MEDIA_SECRET_KEY=<r2-chat-secret> \
  EVIDENCE_ACCESS_KEY=<r2-evidence-write-only-key> EVIDENCE_SECRET_KEY=<r2-evidence-write-only-secret> \
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
  # No release_command: /migrate needs the owner role, which the app must not hold. Migrate first, outside the app (step 4 below).
  strategy = "rolling"

[env]
  APP_ENV = "production"
  FIREBASE_PROJECT_ID = "<production-firebase-project-id>"
  WEB_ORIGIN = "https://app.<your-domain>"
  MEDIA_ENDPOINT = "<account>.r2.cloudflarestorage.com"
  MEDIA_BUCKET = "hiyall-prod"
  MEDIA_REGION = "auto"
  MEDIA_SECURE = "true"
  CHAT_MEDIA_ENDPOINT = "<account>.r2.cloudflarestorage.com"
  CHAT_MEDIA_BUCKET = "hiyall-chat-prod"
  EVIDENCE_BUCKET = "hiyall-evidence-prod"   # write-only token; section 3
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
# 4. Migrate FIRST, as the owner role, from outside the app (the image is the one you are about to deploy; for a first deploy
#    build it locally: docker build -f services/api/Dockerfile -t hiyall-api .). MIGRATE_RUN_GRANTS=true then refreshes the grants
#    of hiyall_api and hiyall_admin in the same step. Nothing here is a Fly secret.
docker run --rm -e MIGRATE_DATABASE_URL='postgresql://hiyall_migrate:<password>@<db-host>:5432/hiyall?sslmode=verify-full' \
  -e MIGRATE_RUN_GRANTS=true --entrypoint /migrate hiyall-api
#    (the release workflow's migrate-production job runs exactly this after a reviewer approves it)

# 5. Deploy: builds the image remotely and starts two machines. The migration above has already run, so /readyz is green at once.
fly deploy --config fly.toml --dockerfile services/api/Dockerfile --app hiyall-api \
  --build-arg COMMIT="$(git rev-parse --short=12 HEAD)" --build-arg VERSION="$(git describe --tags --always)"
fly scale count 2 --app hiyall-api   # if not already two

# 6. TLS and DNS
fly certs add api.<your-domain> --app hiyall-api
#    create the DNS records fly prints, wait for: fly certs show api.<your-domain>

# 7. Smoke test the real thing
curl -s https://api.<your-domain>/healthz
curl -s https://api.<your-domain>/readyz
fly logs --app hiyall-api            # expect "API listening", no "failed" warnings
fly proxy 9090:9090 --app hiyall-api &   # then, with the token you generated:
curl -s -H "Authorization: Bearer <METRICS_TOKEN>" localhost:9090/metrics | head
```

### 4a. Tell the API which proxy it is behind

The API limits requests per client address. Behind Fly's proxy the TCP peer is always the proxy, so unless the API is told which peers are proxies, every user shares one bucket (50 requests a second) and normal load, or one abuser, makes everyone get 429. Two settings fix that:

- `TRUSTED_PROXY_CIDRS`: the proxy's source addresses, comma separated. Forwarded headers are believed **only** from a peer inside them; a client that reaches the machine another way and sends `Fly-Client-IP` or `X-Forwarded-For` is keyed by its own address, so it cannot pick its bucket.
- `CLIENT_IP_HEADER=Fly-Client-IP` (Cloudflare: `CF-Connecting-IP`): the header the proxy sets and overwrites. Without it the API uses the rightmost `X-Forwarded-For` hop that is not one of your proxies; `api check-config -release` says so as a warning.

Production now needs exactly one of two statements (the start refuses otherwise, and so does `api check-config`): **`BEHIND_PROXY=true`** with `TRUSTED_PROXY_CIDRS` (and `CLIENT_IP_HEADER`), or **`DIRECT_LISTENER=true`** (clients reach the process with no proxy in front; forwarded headers are ignored). Leaving both unset is no longer a quiet default.

**Finding the proxy's address, truthfully.** The API cannot know its proxy at start: the peer address exists only when a request arrives, so a start log can only say that. Do this on the first deploy:

1. Set `DIRECT_LISTENER=true` and `DEBUG_LOG_PEER=true` (a temporary aid), deploy.
2. Call `/healthz` once, then `fly logs`. The API logs `client address: first request` with the `peer`, and, with `DEBUG_LOG_PEER`, the peer and the forwarding header *names and values* of the first 20 requests (`DEBUG_LOG_PEER`). The peer is the proxy's address (on Fly the machine's private IPv6 network, `fdaa::/16`, is the usual value; on a VPS with Caddy on the same host it is the Docker bridge `172.16.0.0/12` or `127.0.0.1/32`). If `peerTrusted=false` and `forwardingHeaders` is not empty, that peer is your proxy.
3. Set `TRUSTED_PROXY_CIDRS` to it, `CLIENT_IP_HEADER`, `BEHIND_PROXY=true`, **remove `DIRECT_LISTENER` and `DEBUG_LOG_PEER`**, deploy.

`api check-config -release` refuses `DEBUG_LOG_PEER` (it logs request headers, which is why it stops after 20 requests and prints forwarding headers only, never `Authorization`).

**A wrong value is no longer silent.** A forwarding header (`X-Forwarded-For`, `Forwarded`, the configured header, `Fly-Client-IP`, `CF-Connecting-IP`...) arriving from a peer that is **not** trusted logs a warning at most once a minute naming the peer, and counts in `hiyall_untrusted_forwarding_total` (an alert rule is committed: a sustained rate means `TRUSTED_PROXY_CIDRS` is wrong and every user shares one bucket). The startup log says `client address self-test: the observed peer is unknown until the first request`; the first request then logs the peer. After a deploy, check the log, then open the app from two networks and confirm no 429s.

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

- Migrations ship in the image (`/migrations`) and run with `/migrate` **before** any new API machine starts, **as `hiyall_migrate`** through `MIGRATE_DATABASE_URL` (with `MIGRATE_RUN_GRANTS=true`, which then applies `grants.sql`). Run it from the release workflow's `migrate-production` job (a required reviewer approves it), or by hand: `docker run --rm -e MIGRATE_DATABASE_URL=... -e MIGRATE_RUN_GRANTS=true --entrypoint /migrate <image>@<digest>` from your laptop or a one-off machine. It is **never** a Fly `release_command` or any app-level secret: a release command runs with the app's secrets, which hold `hiyall_api`, the restricted role, and that role cannot create tables. The API never migrates itself.
- **Reaching the database from the workflow.** A GitHub-hosted runner has no fixed address, so `migrate-production` works only if the production database accepts connections from it: an allowlist that includes GitHub's published runner ranges, a self-hosted runner inside your network, or a tunnel. Do not open the database to the world for it. If the job cannot connect, run the command above from a machine that can and let the job fail; the draft release and the images are unaffected.
- `/migrate` takes a database advisory lock for the whole run and applies unapplied files in order, **each in its own transaction** (with its `schema_migrations` row, which stores a SHA-256 checksum; a file that changed after it was applied is refused). A failing file rolls back alone and earlier files stay applied. Every file runs with `lock_timeout` (`MIGRATE_LOCK_TIMEOUT`, 5 s): when it cannot get a table lock it rolls back and retries (up to 8 times, with growing pauses) instead of queueing behind a long query and blocking every request on that table. The whole run has a deadline (`MIGRATE_DEADLINE`, default 10 minutes). Two overlapping releases cannot interleave.
- `/readyz` returns 503 while the database lacks any migration that the running binary ships, and while `hiyall_api` lacks a grant the release needs, a table, a column or an EXECUTE on any definer function (checked every 60 s; red once the gap has lasted a full interval, because a release runs `grants.sql` moments after the migrations). A new production machine, and a new console (`admin serve` as `hiyall_admin`), that finds its grants incomplete **refuses to start** and logs what is missing: run `grants.sql` as `hiyall_migrate` or set `MIGRATE_RUN_GRANTS=true` on the migrate step. If a binary is ever started against an unmigrated database (the release step skipped), it reports not ready and the platform keeps traffic away from it. If the release step fails, the deploy stops and the old machines keep serving.
- **Rule for every migration:** it must work with the release before it (expand, then contract). Add columns and tables in release N; stop using something in N+1; drop it in N+2. There are no down migrations. Rolling back code is safe because `/readyz` accepts a database that is *ahead* of the binary.
- Long locks: avoid `ALTER TABLE` forms that rewrite or lock big tables in a migration that runs on every deploy. A test (`cmd/migrate/lint_test.go`) fails a migration from 0045 on that creates or drops an index on `messages`, `message_envelopes`, `media_assets`, `follows`, `notifications`, `chat_blobs`, `posts` or `comments` without `CONCURRENTLY` in a `-- hiyall:no-transaction` file; `-- hiyall:allow-locking-index` (with the reason) overrides it for a table that is still empty. A file whose **first line** is `-- hiyall:no-transaction` runs its statements one at a time outside any transaction, which `CREATE INDEX CONCURRENTLY` needs; write such a file so that it can run twice (`IF NOT EXISTS`; drop a half-built invalid index first), because a failure part way leaves what ran in place and the file is attempted again by the next release.

## 6. Backups, PITR and a restore drill

- Enable the provider's automated backups **and** point-in-time recovery, retention at least 7 days. A database that cannot be restored is not a backup; the drill below is what proves it.
- Independent copy: a nightly logical dump to a bucket in a different account or provider (for example a separate R2 bucket with its own token). `scripts/backup-db.sh` does it: `pg_dump --format=custom`, encrypted with `age` (or `gpg`) so nothing reaches the bucket in clear, uploaded with the AWS CLI to any S3-compatible endpoint, plus a small `deleted_users` CSV (the deletion ledger below). Run it from a scheduled job you control, with a read-only database role and a write-only bucket token; the decryption key must not live on that machine. Keep 14 days with a bucket lifecycle rule. It protects against a mistake or an account lockout that PITR cannot. The script refuses `BACKUP_ALLOW_UNENCRYPTED=1` unless both the database and the bucket endpoint are on the same machine and neither says production: anything else is treated as production and must name an age or gpg recipient. **Scheduling:** run it nightly from cron on a machine you control, or rename `.github/workflows/backup-example.yml.disabled` to `backup.yml` (a nightly backup job, plus a restore drill that runs only on demand with the age private key pasted into a dispatch input: GitHub never stores the private key, and a dispatch input is visible to anyone who can read the run, so prefer running `scripts/restore-drill.sh` on a machine of your own; read its header and create the `production-backup` environment first), and alert when the newest object in the bucket is older than 26 hours. **Not running yet:** nothing schedules it and it has not been run against a real database (`pg_dump` was not available where it was written; only the deletion-replay script was exercised, against throwaway local databases).
- Chat content on the server is ciphertext; the media buckets hold only photos and ciphertext. **R2 has no object versioning** (Cloudflare's S3 compatibility page lists `PutBucketVersioning` and `GetBucketVersioning` as unimplemented, checked 14 October 2026; re-check before relying on this), so a deleted or overwritten object cannot be undeleted from R2 itself. If you need protection against a bad bulk delete or a leaked write token, replicate the buckets periodically to a second bucket in another account (for example `rclone sync` on a schedule, with the destination token unable to delete) and accept that an account deletion intentionally removes objects, so the replica must not be used to resurrect a deleted account's photos (apply the deletion ledger to it too). Lifecycle rules (expire after N days) exist and are what `config/chat-media.example.env` recommends.

**Restoring without bringing deleted people back.** `docs/legal/data-retention.md` promises that deletions are applied again after a restore. The ledger is the `deleted_users` table (an id and a time, nothing else); it lives in the same database, so it is lost with it unless it is copied elsewhere. What exists, honestly:

1. `scripts/backup-db.sh` writes the ledger as a separate encrypted CSV next to every dump, so after a total loss the ledger is at most as old as the last backup. Purges that happened after it cannot be recovered from anything outside the database; that gap (up to one backup interval) is real. Shorten it by running the ledger export more often (the `\copy` line is cheap).
2. After a restore (PITR or dump), and **before the restored API takes traffic**: run `RESTORED_DATABASE_URL=... PROD_DATABASE_URL=... scripts/replay-deletions.sh` (or `--ledger-file <decrypted csv>` if production is gone). It marks every ledger account that the restored database still has as due for deletion. Start the API against the restored database with its normal media and Firebase configuration: its own purge job then performs the deletion exactly as it does in production (the object and Firebase deletions of an already-removed item are no-ops). Finally `scripts/replay-deletions.sh --verify` must print 0 and exit 0. The script fails loudly (non-zero, no swallowed `psql` errors) if the ledger cannot be read or any statement fails; never continue past a failure of it.
3. Gaps this does not close: other copies (the bucket replica, the provider's own backups) keep the data until their retention ends, which the privacy policy discloses; and an append-only ledger outside the primary database written at purge time (by the purge job itself) is still a code change in `internal/store/account.go`, not done.

**Restore drill, monthly, and once before launch** (30 to 60 minutes; `scripts/restore-drill.sh --latest` automates steps 2 and 3 against a scratch Postgres with `DRILL_ADMIN_URL`, then step 4's counts. It also creates the three roles on the scratch server if they are missing, applies `database/roles/grants.sql` (a dump holds no privileges, because `pg_dump --no-acl`), checks that the API role can read what it must and cannot read the operator tables, and runs `api check-config -db` when an `api` binary that has it is on `PATH` or in `API_BIN`; a restore that skips the grants comes up with an API that cannot read its own tables):

1. Create a new database instance from the latest backup or PITR to a time 10 minutes ago (the provider's restore action). Never restore over production.
2. Note the new instance's direct URL. From your laptop, run the API image against it with production-like config except a fresh `LISTEN_ADDR` and no media or push credentials: `docker run --rm -p 8081:8080 -e APP_ENV=development -e DATABASE_URL='<restored-url, sslmode as the provider requires>' -e FIREBASE_PROJECT_ID=<production-firebase-project-id> hiyall-api` (development mode allows a non-verify-full URL).
3. `curl localhost:8081/readyz` must be 200 (schema current). Count rows in `users`, `messages` and `schema_migrations`; compare with production.
4. Record the elapsed time (this is your real recovery time), delete the restored instance, write the date and result in your ops log. If any step failed, fixing it is the next task, not a nice-to-have.

## 7. Scaling notes: what breaks first

Watch these, in this order. Metric names are on the `METRICS_ADDR` listener.

1. **Database connections and CPU.** Each API machine holds a pool of at most 20 connections (`DB_MAX_CONNS`, or `pool_max_conns` in the URL; `hiyall_db_pool_conns_max`), a separate pool of 4 for the background jobs and the leader lock, and one for the realtime LISTEN connection; add them up across machines against the database's `max_connections`. Every request connection carries a 5 s statement timeout, a 3 s lock timeout and a 15 s idle-in-transaction timeout, so a slow query or a stuck request is cut off instead of piling up; the jobs and the account export use longer limits of their own. A request that hits a limit answers **503 `TEMPORARILY_UNAVAILABLE`** with `Retry-After` (not 500; the app retries) and the log says `canceling statement due to statement timeout` (SQLSTATE 57014) or `lock timeout` (55P03): that is the signal to look at the query. Rising `hiyall_db_pool_empty_acquires_total` and `hiyall_db_pool_acquire_wait_seconds_total` mean requests wait for a connection: first add database CPU/RAM, then read the slow queries; do not simply add machines (more machines means more connections). Authentication needs no write and no row lock for a session already known (one read, plus one update at most once a minute per session), so the busiest path no longer queues on the `users` row.
2. **Per-node presence.** "Online now" is answered from the sockets on the same machine. With more than one machine, a member connected to the other machine looks offline until their session's last activity says otherwise. This is acceptable for the beta (and `hiyall_realtime_connections` shows the split) but is the first user-visible oddity to fix; it needs the realtime bus to carry presence or a shared presence table.
3. **Realtime fan-out over `NOTIFY`.** Every event goes through one PostgreSQL channel to every machine. It suits one region and thousands of concurrent sockets; it is not the design for hundreds of thousands. Measure `hiyall_realtime_connections` and event rate before changing it.
4. **Rate limits multiplied by machine count.** Fixed: set `RATE_LIMIT_BACKEND=postgres` and the per-account limits (first chats, search, reports, uploads, message sends and the rest) are counted once for all machines, at the price of one small indexed write per limited request (`rate_limits`, unlogged, cleaned hourly). The per-address flood guard stays per machine on purpose; put a real per-address limit at the edge (Cloudflare in front of Fly, or Fly's own limits) before opening to the public. If the limiter's database call fails the request is let through and `hiyall_rate_limit_backend_errors_total` rises: alert on it.
5. **Push and cleanup.** Hourly cleanup runs on exactly one machine (advisory lock; `hiyall_maintenance_leader` is 1 on that machine, `hiyall_maintenance_job_runs_total{result="error"}` and `hiyall_maintenance_job_last_run_timestamp_seconds` show health). The push queue is per machine and bounded; dropped wake-ups only delay delivery.
   Retention jobs (migration `0033`, `cmd/api/retention.go`): notifications at 90 days, closed reports (with their actions) at 180 days unless they hold encrypted evidence, soft-deleted posts, comments and space entries blanked after 1 day and deleted after 30, message metadata at 180 days (never rows a report names, with an attachment or still undelivered), finished photo rows at 30 days. Counters kept at write time (`social_counters` by triggers, `post_counters`, `spaces.member_count`) are recomputed once a week by the `* reconcile` jobs, which remember their place in `reconcile_state`; `hiyall_maintenance_job_rows_total{job="social counter reconcile"}` above zero means a counter had drifted. Indexes added after launch must use `CREATE INDEX CONCURRENTLY`.
6. **Media.** Objects go to R2 and downloads use short-lived presigned URLs, so bandwidth does not touch the API. Image processing is bounded two ways (re-audit API-5): one photo may be at most **12 megapixels** (every phone camera's default; larger is refused as unsupported before any pixel is decoded), and a machine decodes at most **`MEDIA_PROCESS_SLOTS` (default 2)** photos at once; an upload that finds every slot busy for 4 s gets 503 `MEDIA_BUSY` with `Retry-After` and stays pending, and the app retries. **Measured** (`go test -v -run TestProcessPeakHeapStaysUnderBudget ./internal/media`, `runtime.MemStats` heap in use sampled every millisecond, a worst-case noise photo of exactly 12 MP): a PNG decodes to a peak of about **135 MB** and a JPEG to about **105 MB** above the baseline, plus the uploaded bytes (up to 15 MB) and the two re-encoded copies. The test asserts a budget of 160 MB (`media.ProcessHeapBudget`) per photo, so it fails if a change makes decoding hungrier. The first audit's figure of about 80 MB per 20 MP image was low by a factor of two (measured 178 MB for 20 MP), which is why the cap came down.

   | Machine memory | `MEDIA_PROCESS_SLOTS` | worst case for photos | `GOMEMLIMIT` |
   |---|---|---|---|
   | 512 MB | 1 | about 175 MB on top of about 60 MB baseline | `400MiB` |
   | 512 MB | 2 (default) | about 350 MB, **tight**: leaves little for requests and the database pool | `400MiB`; use 1 slot if the machine restarts for memory |
   | 1 GB | 2 | about 350 MB on a baseline of 100 MB | `800MiB` |
   | 2 GB | 4 | about 700 MB | `1600MiB` |

   Finishing an upload may take up to 30 s (`POST /v1/media/{id}/complete` has its own deadline and a per-account limiter; every other request has 10 s). **Set `GOMEMLIMIT`** (about 80% of the machine's memory: `400MiB` on a 512 MB machine, in `fly.toml` `[env]`): it is a Go runtime variable, not read by the API, and it makes the garbage collector work harder before the machine runs out of memory and is killed; it is the safety net under the slot count, not a substitute for it. Watch `go_memstats_heap_inuse_bytes`, `go_memstats_sys_bytes`, `go_gc_pause_seconds_total`, `hiyall_media_busy_total` and machine CPU when photo uploads grow. Data exports hold a pooled database connection while they stream (up to two minutes), so a machine builds at most `EXPORT_CONCURRENCY` (default 3) at once (`hiyall_export_busy_total`).

**Alert rules are committed:** `infrastructure/alerts/hiyall.rules.yml` (Prometheus rule format; Grafana Cloud, Mimir, vmalert and Alertmanager read it). It covers, each with a severity (`page` or `ticket`) and a pointer into this guide: the metrics endpoint down, `/readyz` failing (needs a blackbox or uptime probe named `hiyall-readyz`), 5xx above 1% of requests, handler panics, p95 latency above 1 s, a saturated database pool, database contention (`hiyall_db_contention_total` by SQLSTATE: lock timeout, statement timeout, deadlock, serialization), the shared rate limiter failing open (`hiyall_rate_limit_backend_errors_total`), forwarding headers from an untrusted peer, no maintenance leader, a failing maintenance job (any `error` or `timeout` run), a stale session purge, a **new quarantine case** (`hiyall_quarantine_cases_total`, the page that tells a person to open the console), upstream scan errors, push configuration errors (`hiyall_push_config_errors_total`) busy media slots, **the evidence canary failing** (`hiyall_evidence_canary_state == 2`: the API's own evidence token can delete evidence and no bucket lock stopped it), **a two-person approval waiting over 4 hours** (`hiyall_pending_approvals` with `hiyall_oldest_pending_approval_seconds`) and the queue gauges being unreadable (NaN). Load it into your metrics stack, scrape the API's `METRICS_ADDR` listener with `METRICS_TOKEN` as the bearer token under the job name `hiyall-api`, and run `scripts/validate-alerts.sh` after every edit (`promtool check rules` when installed; otherwise a structure check that does not parse PromQL, so install promtool before relying on it). Tune the thresholds after the first week of real traffic. The scan-upstream rule reads `hiyall_scan_upstream_errors_total`, which `internal/media` increments on every failed provider call. Counters are created at zero at startup and the rules use `increase(x[w]) > 0 or (x > 0 unless x offset w)`, so the **first** event after a restart is not missed; `scripts/validate-alerts.sh` fails when a rule names a metric the Go code does not define. A 426 rate (`status_class="4xx"` on every route) right after setting `MIN_CLIENT_VERSION_*` is expected, not an incident. The previous hand list is kept below for reference: `/readyz` failing for 2 minutes; `rate(hiyall_http_requests_total{status_class="5xx"}[5m])` above 1% of requests; `hiyall_http_request_duration_seconds` p95 above 1 s; `hiyall_db_pool_conns_acquired == hiyall_db_pool_conns_max` for 5 minutes; `time() - hiyall_maintenance_job_last_run_timestamp_seconds{job="session purge"} > 7200`; `hiyall_http_panics_total` increasing; `increase(hiyall_push_config_errors_total[15m]) > 0` (FCM refused the push because of our configuration, tokens are kept; check `FCM_SERVICE_ACCOUNT_FILE` against the app's Firebase project); `increase(hiyall_maintenance_job_runs_total{result=~"error|timeout"}[1h]) > 0` for `media cleanup` and `account purge` (objects not removed, retried every hour); a 426 rate (`status_class="4xx"` on every route) right after setting `MIN_CLIENT_VERSION_*` is expected, not an incident.

## 8. Rollback

- **Code:** redeploy the previous image. On Fly: `fly releases --image --app hiyall-api` to find it, then `fly deploy --image <previous image> --app hiyall-api` (the schema is migrated separately and is already current, so nothing else runs). On a VPS: `docker run` the previous tag. Keep the last three image tags; tag images with the git commit. The running commit and version are in the startup log (`starting version=... commit=...`) and in the metric `hiyall_build_info{version,commit}`: after any deploy, check that the metric shows the commit you meant to ship.
- **Database:** there is no down migration. Because every migration is backward compatible with the release before it (section 5), the old code runs on the new schema, and `/readyz` allows it. If a migration itself damaged data, restore with PITR to a new instance (section 6), verify, then switch `DATABASE_URL`; that is an incident, not a rollback.
- **Configuration:** `fly secrets set` triggers a redeploy; to undo, set the old value again.

## 8b. Release pipeline (tags)

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`: the preflight (which requires the Foundation checks green on that commit), the Go tests, then the API image **and the admin console image** are built with `COMMIT` (12 characters of the sha) and `VERSION` (the tag) stamped in, pushed to GHCR **by digest** (only those jobs have `packages: write`) and scanned with trivy by digest (a fixable HIGH or CRITICAL fails the release), SBOMs are generated, the Android bundle and the iOS IPA are built through `scripts/build-release.sh` for the platforms in the repository variable `RELEASE_PLATFORMS` (default both, spaces and case ignored, an unknown name fails; a listed platform needs its signing secrets, which live in the `release` environment, and fails without them; the draft release needs every listed platform to have succeeded). The Android job also uploads the R8 `mapping.txt`, everything is attached to a **draft** GitHub release, and finally the migration job waits for a reviewer to approve the `production` environment before it runs `/migrate` from the image against the production database as the migration role (secret `PRODUCTION_MIGRATE_DATABASE_URL`, passed as `MIGRATE_DATABASE_URL`), with `MIGRATE_RUN_GRANTS=true` so the grants of the API and admin roles are refreshed in the same step. `hiyall_build_info{commit,version}` and Sentry's release then name the tag. Nothing deploys the API: after the migration you roll out the digest yourself (`fly deploy --image ghcr.io/<owner>/<repo>/api@sha256:...`). One-time owner setup is in [11-environments.md](11-environments.md). The workflow has never run; `release-dryrun.yml` (Actions > Release dry run, no secrets, uploads nothing) rehearses the Android and web builds, and an unsigned iOS build on request. The first signed iOS archive must be rehearsed on a Mac. Its first job, `release-preflight`, runs `scripts/release-preflight.sh` (every release gate; the production-environment gate is run by hand, see [the release runbook](12-release-runbook.md)).

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
Symptoms: the migration step (the workflow's `migrate-production` job, or your own `/migrate` run) fails; you do not deploy; old machines keep serving (their `/readyz` is unaffected). Action: read the migration output for `migration <file>: ...`; do not edit an applied migration (checksum check will refuse it). Fix forward with a new migration file or fix the data, then deploy again. If `/readyz` says "schema is behind this release" on a running machine, someone deployed the binary without running `/migrate`: run it.

**4. Sign-in failing for everyone (401 or `AUTH_UNAVAILABLE` 503).**
Symptoms: all authenticated routes fail; `/healthz` fine. Causes in order of likelihood: the API cannot fetch Firebase's signing keys (network egress or Google outage: 503 `AUTH_UNAVAILABLE`); `FIREBASE_PROJECT_ID` is wrong after a config change (401 for every token); the clients are using another Firebase project. Action: check Google's status, check the effective `FIREBASE_PROJECT_ID`, read the verification error in `fly logs` (the image has no shell to exec into) and redeploy the previous config. Existing sessions do not need Google once keys are cached; new sign-ins do.

**5. Photos fail (503 `MEDIA_UNAVAILABLE` or `CHAT_MEDIA_UNAVAILABLE`, uploads rejected, images not loading).**
Symptoms: the app shows photo errors; the API log says "storage failed" with an error code (never a URL). Causes: the R2 token was revoked or scoped to the wrong bucket (403), the endpoint or bucket name is wrong after a config change, or R2 has an incident. Action: check Cloudflare status; confirm `MEDIA_*` / `CHAT_MEDIA_*` values; roll the token (create a new bucket-scoped token, `fly secrets set`, redeploy). Text chat and everything else keep working while media is down. The hourly cleanup retries object deletion, so a short R2 outage self-heals.

Not on the list but likely soon: an abuse spike (watch `hiyall_rate_limit_rejections_total{limiter=...}`; tighten at the edge first, then in code) and a reconnect storm after a deploy (watch `hiyall_realtime_connections` recover; the rolling strategy replaces one machine at a time, so only that machine's sockets reconnect).

## 11. Admin console, database roles and upload scanning

These are owner steps; none was run for you. Design: [admin console](../security/15-admin-console.md); the illegal-content procedure: [runbook 16](../security/16-csam-and-illegal-content.md).

**Database roles (roles once; grants after every migration).** Production runs three roles instead of one: `hiyall_migrate` (owns the schema; only the release step uses it), `hiyall_api` (the API: no access to the operator tables) and `hiyall_admin` (the console: INSERT and SELECT only on the audit log). Two scripts, in `database/roles/`:

- `roles.sql` is the **one-time** step, run by a superuser or `CREATEROLE` user: it creates the NOLOGIN roles and the schema-level rights (it is one transaction and idempotent).
- `grants.sql` is the **privilege refresh**, run by `hiyall_migrate` (the table owner) **after every migration**: tables and views for `hiyall_api` (SELECT on views, full DML on tables), the one `content_cases` column the media purge reads, the console's grants and the function grants. It is one transaction (the running API never sees a moment without rights), idempotent, and it asserts its own result, so a run by the wrong role fails instead of half-granting.

```bash
psql "$SUPERUSER_URL" -v ON_ERROR_STOP=1 -f database/roles/roles.sql          # once: creates the NOLOGIN roles
psql "$SUPERUSER_URL" -c "ALTER ROLE hiyall_api LOGIN PASSWORD '<long random>'" # same for hiyall_admin, hiyall_migrate
psql "$SUPERUSER_URL" -c "REASSIGN OWNED BY <current owner> TO hiyall_migrate"  # only for a database that already exists
```

Then the release step is one command: `/migrate` with `MIGRATE_DATABASE_URL` (`hiyall_migrate`) and `MIGRATE_RUN_GRANTS=true` applies the migrations and then `grants.sql` (the image has it at `/roles/grants.sql`; `MIGRATE_GRANTS_FILE` overrides the path). The API's `DATABASE_URL` is `hiyall_api`. A table that `grants.sql` has not been run for is unreachable by the API and the console, so forgetting it breaks loudly instead of leaving a new table open. Check a live database with `api check-config -db` (the role's shape and every grant `hiyall_api` and `hiyall_admin` should have, including EXECUTE on each function; the expected list is `store.ExpectedGrants`, which a test compares with `grants.sql`); a production start refuses to run as a superuser, as the owner of the tables, or as a role that can read `operators` or change `operator_audit`, unless `DB_ALLOW_OWNER_ROLE=true` (logged loudly at every start). the API checks the same grants itself at start (production refuses to start without them) and in `/readyz`. Test the whole path without a superuser with `TestOwnerPathWithoutSuperuser` (it builds a scratch database exactly like this and runs the migrations, `grants.sql` and every SECURITY DEFINER function as the non-superuser roles). Managed databases that forbid `CREATE ROLE` for the owner role: create the three roles in the provider's console and run the rest of `roles.sql` as the owner.

**Admin console.** A second app, never on the public internet. Build: `docker build -f services/api/Dockerfile.admin -t hiyall-admin .` (the image holds `/admin` and the built UI in `/console`; CI builds it and fetches the UI on every change). Run it where only staff can reach it: a private Fly app reached through `fly proxy` or WireGuard, or a VPS behind an identity-aware proxy. Every variable, with its rule, is in `infrastructure/docker/admin.example.env`, and the production overlay is `config/admin.production.example.env` (`scripts/check_env_docs.py` fails when they drift from the code). The image declares a `HEALTHCHECK` (`admin healthcheck`, a TCP connect to `ADMIN_ADDR`), is stamped with the commit and tag like the API image, and is built, scanned and pushed by digest by the release workflow. Settings:

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

**Sign in with Apple.** Create a Sign in with Apple key in the Apple developer account (Keys), note the Key ID and Team ID, set `APPLE_*` on the API and mount the `.p8` as a secret file. The app sends the Apple authorization code with the deletion request; if the app cannot get a code it sends `appleCodeUnavailable: true`: the deletion goes ahead, the response says `appleAction: "remove_in_apple_settings"` and the app tells the member to remove Hiyall under Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID; **there is no operator revocation** (Apple's revoke call needs the member's own token), and a record (`member_informed`, kept 90 days) is only visible in the console under *Apple deletions*. Every new deletion also sends one content-free push to the member's devices. Support deletes an account from a terminal with `admin schedule-deletion -user ID -reason TEXT -operator EMAIL` (`ADMIN_OPERATOR_EMAIL` instead of the flag; an active administrator; works for suspended members); such a record is `manual`, and an operator has to tell the member the same steps and then acknowledges it in the console (Hiyall holds no email address for a member, so how the member is reached is the operator's decision: [OPERATOR: how the member is told when support schedules a deletion]; a suspended or banned member cannot cancel a support-scheduled deletion; check weekly; `hiyall_apple_manual_revocations` counts the unacknowledged ones); unset, deletion works and logs a warning, and production with `APPLE_SIGN_IN_ENABLED=true` refuses to start without all four.


## 12. Billing: plans, coins and ads

Everything here is optional and a documented no-op while unset. Design: docs/architecture/11-plans-and-entitlements.md, API: docs/api/28-billing.md, app: docs/mobile/18-shop-and-ads.md.

**Env vars** (all in `infrastructure/docker/api.example.env`): `PLANS_ENFORCED` (default `false`; the launch switch; production refuses `true` without a store), `BILLING_CATALOG_FILE` (JSON, example `config/billing-catalog.example.json`: product grants, price tiers, Free/Premium policy, ad reward and cap, profile bonus; invalid files stop the start), `BILLING_ALLOW_TEST_PURCHASES` (default `true`: Google license testers and Apple Sandbox, which App Review uses), `GOOGLE_PLAY_PACKAGE_NAME`, `GOOGLE_PLAY_SERVICE_ACCOUNT_FILE`, `GOOGLE_PLAY_RTDN_TOKEN`, `APPLE_IAP_BUNDLE_ID`, `APPLE_IAP_ISSUER_ID`, `APPLE_IAP_KEY_ID`, `APPLE_IAP_PRIVATE_KEY_FILE`, `APPLE_IAP_ROOT_CERT_FILE`, `ADMOB_SSV_AD_UNIT_IDS`. Key files are mounted as secret files like `FCM_SERVICE_ACCOUNT_FILE`. A set but unusable store file stops a production start.

**Owner steps, in this order**

1. *Catalog.* Copy `config/billing-catalog.example.json`, adjust coins and tiers, mount it, set `BILLING_CATALOG_FILE`. Product ids are your own: `coins_s`, `coins_m`, `coins_l`, `coins_xl`, `premium_1m`, `premium_3m`, `premium_12m` (a store id that differs goes in `googleProductId` / `appleProductId`). **Prices are never in the catalog**: set them in the stores; the app shows the store's localized price.
2. *Google Play Console.* Create the in-app products (managed, consumable) `coins_*` and the subscriptions `premium_*` (a base plan each, auto-renewing, grace period on); create a service account in Google Cloud, invite it in Play Console > Users and permissions with *View financial data* and *Manage orders and subscriptions*; mount its JSON key and set `GOOGLE_PLAY_PACKAGE_NAME` and `GOOGLE_PLAY_SERVICE_ACCOUNT_FILE`. Real-time developer notifications: Play Console > Monetization setup > create a Pub/Sub topic, grant `google-play-developer-notifications@system.gserviceaccount.com` publish rights, create a **push** subscription to `https://<api host>/v1/billing/google/rtdn?token=<GOOGLE_PLAY_RTDN_TOKEN>` (a random 32+ character secret), send a test notification. Add license testers.
3. *App Store Connect.* Create the in-app purchases (consumables `coins_*`, a subscription group with `premium_*`), enable the In-App Purchase capability on the app id, create an In-App Purchase key (Users and Access > Integrations): note the issuer id and key id, mount the `.p8`; download Apple Root CA - G3 from https://www.apple.com/certificateauthority/ and mount it (`APPLE_IAP_ROOT_CERT_FILE`, the `.cer` or a PEM works); set `APPLE_IAP_*`. App Store Server Notifications V2: App information > set the production and sandbox URL to `https://<api host>/v1/billing/apple/notifications`.
4. *AdMob.* Create the app (Android and iOS) and one rewarded ad unit each; enable server-side verification on the ad units with the callback URL `https://<api host>/v1/billing/admob/ssv`; set `ADMOB_SSV_AD_UNIT_IDS` to the unit ids; in Privacy & messaging create the GDPR/UMP consent message and an age-restricted-users setting; build the apps with `ADMOB_APP_ID_ANDROID` / `ADMOB_APP_ID_IOS` and `--dart-define=ADMOB_REWARDED_ANDROID=... --dart-define=ADMOB_REWARDED_IOS=...` (docs/mobile/18-shop-and-ads.md). An app without the unit ids has no ads.
5. *Test.* With `PLANS_ENFORCED=false` buy a coin pack and a subscription as a license tester / sandbox account from an internal-testing build, read `hiyall_purchases_total{result}`, refund one in the store and watch the coins come back. Then set `PLANS_ENFORCED=true` (restart: it is read at start).

**Metrics.** `hiyall_purchases_total{result}` (`verified`, `pending`, `replay`, `invalid`, `claimed`, `refunded`, `revoked`, `store_error`), `hiyall_ad_rewards_total{result}`, `hiyall_coin_spend_total{reason}`, `hiyall_coin_grant_total{reason}`, `hiyall_coin_refund_shortfall_total`. A burst of `store_error` means a store credential or outage; check the logs for "refused our credentials".

**Support adjustments** (no admin UI): `SELECT coin_admin_adjust('<member>', 20, 'support:<you>', 'ticket 123');` as `hiyall_migrate` in `psql`; it writes the ledger and the operator audit.

**What is not verified until you do step 5**: the adapters were built from the stores' documentation and tested against fakes only.
