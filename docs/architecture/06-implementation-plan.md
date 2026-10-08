# Kairova implementation plan and approval gate

**Status:** Architecture draft complete; first local foundation implemented after user authorization

**Goal:** build a checked, incremental MVP without a giant code dump or premature microservices

## 1. What will be built first

The first implementation slice is an end-to-end **safe conversation loop**:

```text
sign up -> complete minimum profile -> choose interests/privacy
  -> view Home/Pulse shell -> discover a person
  -> follow/message request/accept -> send one real-time message
  -> see durable delivery state -> block/report/privacy controls
```

This slice proves the highest-risk contracts early: authentication, authorization, profiles, privacy, media boundaries, cursor pagination, idempotent messaging, WebSocket resume, local offline state, and observability.

## 2. Dependencies and when they are required

### Product and policy — before public release

- Final product name/brand clearance; Kairova is provisional.
- MVP age policy and youth-safety boundary.
- Launch countries/regions, supported locales, data-residency obligations, and retention schedule.
- Mandatory direct-chat/attachment E2EE, reviewed protocol/library integration, device identity verification and recovery policy.
- Moderation policy, appeals policy, operator access policy, and high-severity response target.
- User-facing limits for group/community size, media size, message edit/delete windows, and story expiry.

### Accounts and vendors — before each connected integration

- AWS account topology, launch region, budget, and billing owners.
- OIDC/identity provider and email/SMS verification provider.
- Apple/Google OAuth/Sign in with Apple configuration.
- APNs/FCM credentials and notification policy.
- S3/CloudFront/WAF/KMS/Secrets Manager ownership.
- WebRTC/TURN deployment or approved managed provider.
- Malware/media moderation provider and AI provider policy.

### Engineering — during foundation setup

- Flutter/Dart version and package approval.
- Backend language/framework selection; default recommendation is Go for API/realtime/workers with generated OpenAPI types and SQL query generation, plus TypeScript/React for the admin console.
- PostgreSQL migration tooling and dedicated OpenSearch local container; DynamoDB tooling only when its storage cutover is scheduled.
- CI runner and container registry.
- Error tracking, metrics, logs, trace backend, and on-call ownership.

## 3. Contracts to freeze before implementation

1. Domain IDs, timestamps, cursor format, versioning, and standard response/error envelope.
2. Typed MVP OpenAPI contract in `docs/api/openapi-mvp.json`; advanced endpoint inventory and shared rules in `docs/api/04-api-specification.md`.
3. Event envelope, event names, schema versions, and outbox semantics.
4. Auth/session lifecycle, device model, token rotation, and step-up requirements.
5. Privacy/visibility matrix for profiles, stories, posts, comments, search, recommendations, and chat.
6. Message lifecycle, per-conversation sequence, offline retry, and WebSocket resume protocol.
7. Media upload/scan/transform/deletion state machine.
8. Deletion/export saga states and retention/legal-hold rules.
9. Moderation reason/action taxonomy and admin audit boundary.
10. Mobile local schema, mutation outbox, conflict policies, and supported offline actions.

## 4. Repository target structure

```text
/
  apps/
    mobile/                 # Flutter Android/iOS app
    admin/                  # secure web admin console
  services/
    api/                    # public HTTP API process
    realtime/               # WebSocket gateway process
    worker/                 # outbox, queues, media, notifications, projections
    scheduler/              # expiry, cleanup, digests, maintenance
    admin-api/              # separate admin audience/security boundary
  packages/
    domain/                 # shared contracts only; no database shortcuts
    api-contracts/          # generated OpenAPI and event schemas
    ui/                     # Flutter design system if shared across apps
    config/                 # safe defaults and schema validation
    observability/          # tracing/logging/metrics conventions
  infrastructure/
    terraform/
    docker/
    environments/
  database/
    migrations/
    seeds/
    fixtures/
  docs/
    architecture/
    database/
    api/
    mobile/
    runbooks/
  .github/workflows/
```

The current workspace contains the architecture docs only. This structure is a target, not an assertion that these directories or services already exist.

## 5. Delivery phases

### Phase 0 — repository and development foundation

Acceptance criteria:

- Repository is initialized with pinned runtime/tool versions and instructions.
- Flutter app, backend service, worker, and admin shell build locally with no secrets.
- Lint, format, unit-test, integration-test, migration-check, and container-scan commands are real and fail meaningfully.
- CI runs checks on pull requests and produces a traceable build artifact.
- Structured logs, request IDs, OpenTelemetry wiring, error handling, and feature flags exist before feature volume grows.

### Phase 1 — identity, profile, privacy, and design system

- Signup/login/verification/recovery and session rotation.
- Profile edit, language/time-zone/interest selection, privacy defaults, device/session list.
- Block/mute/restrict/report contracts and server-side negative authorization tests.
- Flutter design tokens/components, navigation shell, localization/RTL/accessibility baseline.

### Phase 2 — Pulse, stories, media, and notifications

- Direct-to-object-storage media upload with scan/transform states.
- Cursor feed, posts, comments, reactions, saves, stories, views, and expiry.
- Basic notification aggregation, push deep links, and offline cache.
- Feed projection rebuild command and deletion propagation tests.

### Phase 3 — Bridge and consent requests

- Find Friends filters, Interest Passport, explainable overlap, search, follow/friend requests.
- Consent request lifecycle, recipient-only acceptance, DM pair uniqueness, and per-recipient abuse budgets.
- Recommendation baseline using explicit interests and social graph only.

### Phase 4 — real-time chat

- Reviewed E2EE library/native adapter, device key lifecycle/verification, encrypted local ratchet/outbox transactions, conversations/membership, ciphertext relay, gateway, receipts, typing, encrypted media, reconnect/resume.
- Offline mutation outbox and duplicate/out-of-order tests.
- Spam/rate limiting using metadata, report/block and explicitly selected evidence; no automatic server reading/scanning of E2EE chat content.

### Phase 5 — communities, events, calls, and advanced safety

- Moments, communities, roles, community posts, events, RSVP, event chat.
- WebRTC voice/video pilot with TURN, network switching, and call history.
- Moderation operations, appeals, human review, and admin access controls.
- Translation/AI assistance behind explicit user action and policy gateway.

### Phase 6 — measured scale work

- Load/soak tests based on real traffic shapes and hot-key distributions.
- Move messages/feed projections/search to scale-out stores when thresholds are exceeded.
- Multi-AZ failure drills, restore tests, queue replay, regional backup/failover.
- Cell boundaries and independent service extraction only when a measured trigger is met.

## 6. Minimum checks for each phase

| Area | Check |
|---|---|
| Code | format, lint, static analysis, dependency/license scan |
| Unit | domain policy, validation, idempotency, cursor and time-zone tests |
| API | generated contract tests, auth negatives, pagination, rate limits |
| Data | migration up/down or forward compatibility, indexes/query plans, backup restore |
| Mobile | widget/accessibility, offline/reconnect, dark/RTL/dynamic text |
| Real-time | duplicate/out-of-order events, resume cursor, backpressure |
| Media | signed upload, checksum/MIME, quarantine, scan rejection, deletion |
| Security | OWASP baseline, BOLA/IDOR, injection, session/OTP, abuse/rate-limit tests |
| Operations | logs/metrics/traces, SLO alerts, DLQ replay, rollback/kill switch |
| Scale | load tests with recorded assumptions; no extrapolated claim without evidence |

Only checks actually run may be reported as passed. Application checks now exist for the foundation slice. See `docs/development.md` for behavior, checks and remaining limitations. Architecture/roadmap contract checks remain recorded separately in `docs/architecture/10-review-and-traceability.md`.

## 7. Definition of done for MVP

- Every MVP user journey in the PRD has an implemented happy path, empty state, error state, and safety path.
- Public API and event contracts are versioned and generated into client/server types.
- Authorization tests cover direct object access, privacy, blocks, membership, moderation, and admin separation.
- Offline message retry is duplicate-safe and WebSocket reconnect is cursor-safe.
- Media never passes large bytes through the application API.
- Feed, search, notifications, and recommendations degrade safely and are rebuildable.
- Export/deletion workflows report status and cover source data, caches, search, feeds, media, notifications, analytics, and retention exceptions.
- CI runs required tests/scans; staging smoke tests run before release; rollback is documented.
- Baseline load tests record requests/sec, concurrent sockets, messages/sec, media GB/day, latency, error rate, and cost signals.
- No document, UI, or response claims production readiness without evidence from these checks.

## 8. Architecture approval boundary

The requested brief explicitly puts implementation after architecture approval. Review the defaults in `docs/architecture/10-review-and-traceability.md`: Flutter/Riverpod, Go modular monolith, separate search, adult-only safety assumptions, consent-based E2EE MVP chat, and one-region AWS example. Approval of this architecture authorizes the local foundation slice below.

Market/region/vendor credentials and operational policies are selected before their connected integrations or public release. Brand clearance, complete future call infrastructure, and production cloud accounts do not block local repository setup. Direct-chat/attachment E2EE is now required. Complete suite-specific key/device/recovery/reporting integration review before implementing chat; the updated ciphertext transport contract is a draft, not cryptographic proof.

## 9. First implementation task after approval

Create the repository foundation and one vertical slice only:

```text
Flutter shell + API health/auth contract + PostgreSQL migration runner
  + profile read/update + privacy read/update
  + structured request logging/tracing
  + unit/API/widget tests for the above
```

Do not implement all feature modules, video calls, recommendation models, or 100M-user infrastructure in the first code change.
