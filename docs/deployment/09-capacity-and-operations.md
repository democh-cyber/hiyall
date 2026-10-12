# Hiyall capacity, deployment, and recovery plan

**Status:** quantitative planning model and proposed runbooks, 7 October 2026. No infrastructure is deployed, no capacity benchmark has run, and no costs below are vendor quotes.

## Capacity inputs and calculations

Use these deliberately explicit assumptions to size experiments, then replace them with measured product behavior:

- DAU = 10% of registered users. Model also includes a future 20M DAU scenario; a 100M registration count alone says little about concurrency.
- HTTP operations = 120/DAU/day, excluding CDN bytes and WebSocket events. Peak factor = 5 × average.
- Chat sends = 40/DAU/day, stored message footprint = 1 KiB excluding media/indexes/replicas; direct chats initially. Each send may produce multiple delivery/receipt operations, so message rate is not database write rate.
- Peak concurrently connected users = 10% DAU; devices/user = 1.3. Socket heartbeats every 30 seconds.
- Media uploads = 0.2/DAU/day × 5 MB after compression, plus 1.5× derivative multiplier. Media delivery = 50 MB/DAU/day. Decimal GB/TB for media; KiB for message footprint.
- Feed requests = 20/DAU/day × 20 cards/page. Posts = 0.5/DAU/day; stories = 0.3/DAU/day. A feed request is included in HTTP operations, not added again.

| Registered | DAU | Peak HTTP RPS | Messages/day | Peak sends/sec | Peak sockets incl. devices | Derived media stored/day | CDN delivered/day |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 100 | 0.7 | 4,000 | 0.2 | 13 | 0.15 GB | 5 GB |
| 100,000 | 10,000 | 69 | 400,000 | 23 | 1,300 | 15 GB | 500 GB |
| 1M | 100,000 | 694 | 4M | 231 | 13,000 | 150 GB | 5 TB |
| 10M | 1M | 6,944 | 40M | 2,315 | 130,000 | 1.5 TB | 50 TB |
| 100M | 10M | 69,444 | 400M | 23,148 | 1.3M | 15 TB | 500 TB |
| 100M, higher activity | 20M | 138,889 | 800M | 46,296 | 2.6M | 30 TB | 1 PB |

Formula: peak HTTP RPS = DAU × 120 / 86,400 × 5. At 10M DAU, 400M messages/day occupy approximately 410 GB/day or 150 TB/year of raw 1 KiB records before retention, indexes, replication, receipts, and backups. Media grows ~5.5 PB/year at the assumed derivative rate without lifecycle deletion. Heartbeats at 1.3M sockets imply ~43,333 client heartbeats/sec plus responses; measure that cost independently.

At 100M users and 150 average directed follows, the graph contains 15B edges. 5M posts/day × 150 eligible recipients could create 750M candidate insertions/day; a highly followed account can dominate a spike. Do not extrapolate evenly distributed tests to this skew. Feed pages at 10M DAU produce 4B card hydrations/day without cache/batch gains; bound hydration to one batched candidate request and version-aware policy fetch, not 20 independent queries.

These values are hypotheses, not a statement that a proposed instance fleet supports them. Retention, read/write amplification, retry storms, policy checks, message requests, and media distributions are separate workload dimensions.

## Scaling stages and extraction triggers

| Stage | Concrete operating model | Evidence needed to advance |
|---|---|---|
| 1K →100K | One regional cell; API/socket/worker ECS tasks; Postgres Multi-AZ; private S3/CDN; Redis; dedicated small OpenSearch; SQS/outbox | Baseline latency, user flow correctness, restore/deletion drills, two-user authorization tests |
| 100K →1M | More stateless tasks/workers; query/connection tuning; read replicas only for nonauthoritative reads; bounded feed projections | Record CPU/pool/lock saturation, cache hit rate, index size, queue age, largest authors/chats |
| 1M →10M | Extract chat/feed when contention persists after tuning; bucket ordered storage; isolated media capacity; search shards and ingestion budgets | Shadow/cutover validation, hot-key benchmarks, per-owner throughput, delivery lag and reconciliation |
| 10M →100M+ | Multiple regional cells, resource home-region directory, regional stores and streams, independent deployments and quotas | Owner fencing, privacy-residency routing, reconnect storm/region failure evidence, operational staffing |

Proposed trigger: when a module repeatedly consumes >30% of source DB CPU/writes or exceeds its latency budget at 2× forecast peak despite bounded-query tuning, benchmark extraction. The thresholds are decision aids, not automatic service counts. Feed fanout threshold starts as a configurable 10K followers/author hypothesis, adjusted by posting frequency, eligible recipients, and queue budget; crossing it selects pull/merge candidates. Never synchronously fan out millions of writes. An API worker fleet must not overwhelm the database merely because autoscaling finds more HTTP traffic.

Socket task formula: max(ceil(peak_connections / measured_safe_connections_per_task), ceil(peak_event_rate / measured_safe_events_per_task)); add 30% headroom and tolerate loss of one AZ. Safe task capacity must include heartbeat, TLS memory, subscription count, queue size, file descriptors, slow readers, and reconnects. The same principle applies to media workers and sequencers; there is no invented fixed sockets-per-server guarantee.

## Performance and availability targets

| Indicator | Proposed initial target | Boundary / fallback |
|---|---|---|
| Public API availability | 99.9% monthly | Eligible requests; 5xx/timeouts count, deliberate 4xx do not |
| Durable core writes | 99.95% monthly | Valid authorized writes acknowledged only after commit |
| Feed p95/p99 | <300ms / <1s server | 20-item page; optional ranker may use chronological fallback |
| Message durable ack p95/p99 | <250ms / <750ms in home region | Persistence, separate from recipient offline delivery |
| Online recipient delivery p95 | <1s backend; <2s device target in launch network tests | Exclude disconnected recipients from online metric; report offline metrics separately |
| Search p95 | <500ms | Typed bounds; no stale-private data fallback |
| Projection delay p95 | <10s | Source authorization overrides stale search/feed immediately |
| Foreground cold start p95 | <2s on chosen mid-range reference device | Cached shell; token restore/network measured separately |
| Scrolling | 60fps baseline, 120 where available | 16.7ms/8.3ms frame budgets measured on supported devices |
| Media processing | Photos p95 <10s; bounded short videos p95 <2min | Queue limits, clear processing status |

A 30-day month gives 43.2 minutes at 99.9% and 21.6 minutes at 99.95% error budgets. Use fast/slow burn alerts; pause risky deployments if exhausted. These are proposed targets, not passed tests or contractual SLAs. Include platform and vendor failures in availability reporting; don't hide maintenance through vague exclusions.

## Regional deployment and environment configuration

Proposed local development: Docker Compose with Postgres, Redis, OpenSearch, S3-compatible storage, a queue adapter, local identity-provider configuration, API, gateway, worker. Emulators are for development, not evidence of AWS parity. Run contract tests against real staging providers before launch.

Production: ECS Fargate containers across at least two AZs (prefer three where available), ALB/WAF ingress, private subnets, regional Postgres writer, replicas for eligible reads, Redis, dedicated OpenSearch, S3 private quarantine/published buckets, CDN origin access control, SQS/DLQs, Secrets Manager/KMS. Admin is a separate hostname, audience, ECS task role, and access policy. Scheduled cleanup runs from one leased job owner; worker concurrency caps expensive jobs.

| Configuration key | Purpose | Secret? |
|---|---|---|
| `APP_ENV`, `REGION`, `HOME_CELL_ID` | Environment/routing identity | No |
| `PUBLIC_API_BASE_URL`, `REALTIME_URL` | Mobile build-safe endpoints | No |
| `OIDC_ISSUER`, `OIDC_CONSUMER_AUDIENCE`, `OIDC_ADMIN_AUDIENCE`, `OIDC_MOBILE_CLIENT_ID` | Verified issuer/client boundaries | No; allow-listed |
| `DATABASE_URL_SECRET_ARN` | Secret reference, not a raw connection string in docs/images | Reference only |
| `REDIS_ENDPOINT`, `SEARCH_ENDPOINT`, `SEARCH_INDEX_ALIAS` | Private services | No public mobile exposure |
| `MEDIA_QUARANTINE_BUCKET`, `MEDIA_PUBLISHED_BUCKET`, `CDN_HOST` | Media boundaries | No |
| `OUTBOX_QUEUE_URL`, `NOTIFICATION_QUEUE_URL`, `DLQ_URL` | Async routes | No |
| `KMS_KEY_ARN`, `PUSH_CREDENTIAL_SECRET_ARN`, `CDN_SIGNING_KEY_SECRET_ARN` | Encryption/provider grants | References only; values fetched under task role |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `LOG_LEVEL`, `TRACE_SAMPLE_RATE` | Telemetry routing/budget | No; no raw payload logging |
| `MAX_BODY_BYTES`, `MEDIA_QUOTA_BYTES`, `FEED_PAGE_MAX`, `PRIVATE_MEDIA_GRANT_SECONDS` | Bounded runtime budgets | No |
| `ENABLE_TRANSLATION`, `ENABLE_CALLS`, `ENABLE_MOMENTS` | Advanced features/kill switches | No; off by default |

Pin Flutter/Dart, Go, Terraform, database, and library versions at repository setup after checking support/security constraints. The design does not invent package compatibility before builds. No cloud keys or backend provider secrets in mobile build configuration. Startup rejects missing or invalid critical configuration; never silently connect to production from development.

### Deployment sequence after architecture approval

1. Initialize runnable repository/toolchains and local services; generate server/Dart types from the contract, create forward-compatible source migrations, and seed synthetic data.
2. Implement the first profile/privacy/auth slice and meaningful unit, integration, mobile tests. Local commands become executable README instructions only after they exist.
3. Create isolated staging account resources with Terraform remote state/lock, OIDC CI deployment role, encrypted secrets, budget tags, and least-privilege network access.
4. Run migration rehearsal, authorization tests, provider integration, load baseline, rollback and restore drills in staging. Deploy immutable image digests, migration version, schema compatibility manifest, and SBOM.
5. Release to limited production audience with progressive routing/feature flags; monitor error budget, queue age, and auth/delivery errors. Roll back application readers only while data schema stays compatible.

CI: format/lint → domain unit/property tests → source integration/migration checks → API/security negatives → mobile widget/device flows → dependency/image/IaC scans → signed builds → staging deploy → smoke/load budget checks → controlled production release. Android release needs signing ownership; iOS build/release requires macOS and Apple developer configuration. Docker cannot substitute for iOS build tools.

## Recovery objectives and runbooks

| Data / incident | Proposed RPO | Proposed RTO | Recovery |
|---|---|---|---|
| Source accounts/messages, AZ failure | 0 acknowledged writes target | 15 minutes | Managed regional failover + application reconnect/fence verification |
| Source accounts/messages, region failure, MVP backup stage | ≤24 hours | ≤24 hours | Authorized cross-region daily backups or permitted alternate region; restore and erasure ledger replay |
| Source, regional replica stage | ≤60 seconds target | ≤60 minutes | Fence old writer, check replication lag, promote one owner, update directory and verify |
| Media, same-region failure | 0 committed objects target | ≤4 hours | Versioned storage, reconcile metadata, recover derivatives |
| Media, permitted cross-region replica | ≤24 hours target | ≤8 hours | Verify replication inventory and residency policy; deny missing private objects |
| Feed/search/recommendations | Rebuildable; no new canonical loss | ≤24 hours full rebuild | Chronological bounded source fallback; private search unavailable until authorized index ready |
| Redis/presence | Ephemeral state loss acceptable | ≤15 minutes | Recreate; invalidate auth-sensitive caches; enforce degradation limits |
| Queue/outbox | 0 source-committed events target | ≤4 hours | Republish uncheckpointed outbox, replay idempotently, quarantine poison messages |
| Audit/deletion ledger | 0 acknowledged records regional target | ≤4 hours | Restricted replica/archive and reconciled checkpoints before serving restored data |

Backup-stage RPO is weaker than the later replica target and must be disclosed. Cross-region objectives apply only where replication is legally/policy permitted and configured. AWS documents possible data loss during unplanned Aurora Global Database failover due to asynchronous lag; planned synchronized switchovers differ. Do not advertise regional RPO zero from Multi-AZ storage. [Aurora global recovery documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database-disaster-recovery.html).

Runbook: detect → declare incident/owner → stop or fence old writers using durable ownership generation and routing controls → select allowed recovery region/snapshot → restore keys/config/data → replay deletion ledger and unfinished source outbox → reconcile source counts/committed sequences/media inventory → canary traffic → reopen → post-incident review. If writer fencing cannot be proved, keep writes unavailable; avoid split brain. Idempotency mappings/tombstones recover with messages, not in an independent stale cache snapshot.

Daily backup monitoring; monthly source restore to isolated staging; quarterly AZ/queue/cache drills; semiannual allowed regional recovery rehearsal. Record actual RPO/RTO and gaps. Restore failures block a production readiness claim even when backup jobs are green.

## Load, stress, and security test plan

Test plans are not results. Progress from 10K to 100K to 1M to 10M simulated users only when traffic generators, staging data, quotas, budget, and owners can support that experiment. A million registered synthetic rows are not a million connected users.

Workload mix: auth bursts, 20-card feed, skewed follow graph, search with filters/typos, direct chat, reads/receipts, upload sessions plus direct object bytes, moderation queues, deletion, and 20% offline reconnect behavior. Record separate logical users, actual sockets, RPS, sends/sec, media bytes/sec, regions, CPU/memory, generator saturation, p95/p99, errors, cost, and duration.

- Baseline 30 minutes at expected peak, 60-minute steady soak, then 24-hour soak before expanding rollout.
- Spike 3× peak for five minutes; reopen 25% of sockets within 60 seconds to exercise reconnect/sync rather than fresh connections alone.
- Skew: one account with 10M followers, a hot community/member list, one busy conversation, fanout lag, slow recipients; advanced group scale only after its ordering contract exists.
- Chaos: stop Redis, delay DB/queue, exhaust pools, duplicate/reorder events, pause media/search, remove an AZ, expire credentials, and simulate network switching/process death.
- Pass: durable acknowledged writes survive, retries create no duplicates, unauthorized fields never leak, bounded queues do not grow indefinitely, clients reconcile, safe fallbacks meet stated budgets, and restoration finishes within recorded targets.

Capacity extrapolation reports confidence ranges and bottlenecks. Require distributed tests at the claimed concurrency/rate before claiming that capacity; a small test only validates its measured envelope.

## Cost model and cloud portability

No fixed monthly dollar estimate is asserted without region/provider/retention and observed traffic. Estimate separately: compute task-hours, relational vCPU/storage/I/O, Redis memory, search capacity/storage, queue/stream operations, object bytes/versions, scan/transcode minutes, CDN egress/requests, TURN/SFU minutes/egress, telemetry ingestion/retention, and staff operations. Normalize cost/DAU, delivered message, stored GB, delivered media GB, search, and successful call minute. Cache hit rate reduces origin work, not total user-delivered CDN bytes.

Use media lifecycle/derivative policies, bounded histories, intelligent compression, CDN thumbnail variants, quiet/digest notifications, adaptive telemetry sampling, log redaction, budgets/anomaly alerts, and feature-specific spend caps. Preserve security/audit coverage when sampling traces. Tiny OpenSearch clusters and Multi-AZ minimum capacity impose fixed baseline costs even at 1K users; include them explicitly in a quote.

| Boundary | AWS concrete | GCP equivalent candidate | Azure equivalent candidate |
|---|---|---|---|
| Containers | ECS Fargate | Cloud Run / GKE when socket limits demand | Container Apps / AKS when needed |
| Relational | Aurora PostgreSQL | Cloud SQL PostgreSQL / AlloyDB | Azure Database for PostgreSQL |
| Ephemeral cache | ElastiCache Redis | Memorystore | Azure Managed Redis |
| Object/CDN | S3 / CloudFront | Cloud Storage / Cloud CDN | Blob Storage / Front Door |
| Async | SQS/SNS/EventBridge; streams later | Pub/Sub; ordered keys where needed | Service Bus / Event Hubs |
| Search | Dedicated OpenSearch | OpenSearch-compatible managed/self-hosted service | OpenSearch-compatible managed/self-hosted service |
| Ordered message store | DynamoDB once measured | Bigtable evaluated by access pattern | Cosmos DB evaluated by partition/consistency |
| Keys/secrets | KMS / Secrets Manager | Cloud KMS / Secret Manager | Key Vault |
| Analytics | S3/Athena / warehouse | BigQuery | ADLS / analytical warehouse |

These are architectural mappings, not drop-in feature parity or validated regional availability. Adapter contracts cover object grants, queues, secret retrieval, identity, search, telemetry, and message stores; infrastructure remains provider-specific. Revalidate each substitute's ordering, transaction, consistency, quotas, retention, and cost before adoption.
