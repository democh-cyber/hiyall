# Architecture review and requirement coverage

**Review date:** 7 October 2026

**Status:** A–E architecture deliverables and UX specification drafted; F foundation implementation authorized and started on 7 October 2026. See [the development record](../development.md) for the implemented slice and actual checks.

## Decisions proposed for approval

| Decision | Default / reason | Consequence |
|---|---|---|
| Product | Provisional Hiyall; five familiar tabs; stories on Home; Interest Passport and consent requests | Original product direction, brand clearance before public launch |
| Client | Flutter/Riverpod/go_router/Drift + secure storage | Native Android/iOS integration and real-device testing; future web shares contracts |
| Backend | Go modular monolith with isolated runtime processes; React admin | Small initial operational footprint; extract only with measured scaling/ownership needs |
| Sources | PostgreSQL source transactions; Redis ephemeral; private S3/CDN; OpenSearch separate from source DB | No giant single store; search and feed candidates never authorize access |
| Messaging | User now requires E2EE direct chat/attachments, encrypted device envelopes and durable retry mapping | Reviewed suite/device/recovery integration before chat code; no server plaintext chat processing |
| Safety | Not adult-only (owner decision, minimum age 13 self-declared); open, discoverable profiles by default; coarse, expiring Nearby with no in-app opt-out; strangers use bounded requests | Minors and adults are kept apart (`AGE_BAND_ISOLATION`) and minors get stricter defaults, but on a self-declared, falsifiable birth date; age assurance, moderation staffing, COPPA/GDPR-K and EU parental-consent review and content restrictions for minors are recommended and not done (`docs/api/19-nearby-and-open-access.md`); no age filters; precise location is never stored |
| Scope | Profiles, posts/stories, friends/follows, discovery, 1:1 chat, notifications, safety/privacy | Moments/groups/communities/events/calls/AI deferred; no extra bottom tabs |
| Deployment | AWS example; one region Multi-AZ first, regional ownership later | Actual market/region/provider configuration precedes connected deployment, not architecture review |

The brief states: **“After architecture approval, start implementation.”** Approval of these defaults authorizes the first local foundation slice. It does not assert production readiness or require buying/configuring every vendor before repository setup. No additional product-name/provider questionnaire is required to review the architecture itself.

## Additional encryption requirement

The user now requires stronger encryption and interception resistance. [Encryption and interception design](../security/11-encryption-and-interception.md) replaces the old server-visible-chat assumption with mandatory E2EE direct chats/attachments. The API no longer accepts plaintext message bodies or pre-acceptance private introductions. Group/call E2EE and suite-specific key-directory APIs still need separate design. Release verification must test ordinary proxy rejection, ciphertext transport, pin rotation, device/key changes, backup/log leakage and endpoint-compromise limitations. The app remains unimplemented.

## What changed in this review

The workspace already contained six architecture documents. This pass reviewed and extended those documents without replacing the working brand or starting an unapproved app implementation.

- Removed incompatible partition/unique-key suggestions; separated global username reservation, rotated refresh history, DM pair uniqueness and durable message retry mappings from caches.
- Clarified command/outbox atomicity, storage cutover fencing, message/create/version/sync cursors, receipt meaning, source authorization and stale-index filtering.
- Selected dedicated OpenSearch to follow the brief's separate-search requirement; kept transaction/analytics work separate.
- Added the machine-readable MVP OpenAPI contract with explicit schemas, limits, authentication, ownership, preconditions and safe errors; advanced API inventory remains labeled as design.
- Moved the new Moments concept to the advanced phase to keep the MVP bounded; retained Interest Passport, transparent overlap and Quiet Controls as differentiators.
- Added screen inventory, flow/navigation diagrams, wireframes, component contracts and design tokens.
- Added threat risk/mitigation/detection/response, retention/deletion/export mechanics, admin evidence boundaries, numeric capacity calculations, SLOs, recovery objectives and staging/release gates.
- Defined residual media access honestly: a committed block denies new server operations/grants; existing signed grants and downloaded bytes have different limits.

## Requirement map

| Brief area | Design coverage | Implementation / proof status |
|---|---|---|
| Product vision, personas, journeys, MVP/future | 01 PRD; 07 UX | Documented; user research not conducted |
| Mobile/UX/navigation/accessibility | 05 mobile; 07 UX | Routes/tokens/wireframes; no Flutter build or device tests |
| Identity, sessions, MFA, OAuth, recovery | 02 architecture; 03 database; 04 API/OpenAPI; 08 security | Provider adapter designed; provider-specific passkey/MFA enrollment and conformance deferred to foundation |
| Profiles, privacy, friends, follows, block/restrict/mute | 03 source/support entities; 04 API; 08 matrix | Authorization rules specified; no runtime enforcement yet |
| Home/feed/posts/comments/stories | 02 hybrid fanout; 03 entities; 04 API; 07 screens | Cursor/expiry/processing contract defined; no feed service |
| Discovery, advanced filters, transparent recommendations | 01 PRD; 02 §19; 04 API | Baseline scoring/opt-in schema; advanced community/skill/hobby-specific discovery later |
| Chat, offline retry, receipts, real-time | 02 chat; 03 §15; 04 §17; 05 mobile | Atomicity/dedupe/replay designed; no actual message transmission |
| Group messaging, large communities, events, calls | 01 future; 02 media/RTC; 03 entities/support; 04 advanced routes | Deferred architecture inventory; no full advanced machine contract or load evidence |
| Media/CDN/storage/compression | 02 media; 03 assets; 04 upload; 08 access; 09 cost | Direct upload/quarantine/scan/transform specified; no scans/transcodes run |
| Search/indexing | 02 search; 04 typed routes; 08 authorization | Separate index with current-policy hydration; no index deployed |
| Notifications/push/quiet controls | 02 notifications; 03 preferences; 04 API; 05 zones | Batching/device ownership designed; no APNs/FCM integration |
| AI translation/writing/moderation | 01 AI; 02 gateway; 08 case controls | Optional/advanced; originals preserved; no external processing enabled |
| Moderation/admin/appeals/audit | 03 reports/actions/appeals; 04 §18; 08 threat model | Separate consumer/staff boundaries specified; no admin app |
| Source tables/indexes/partitioning/growth | 03 all 25 entities + supporting schemas/ER | Logical design only; no SQL migration/query-plan validation |
| Scaling 1K→100K→1M→10M→100M | 02 stages; 09 quantitative workload/extraction | Assumptions/formulas; no achieved capacity claim |
| Global/time zones/i18n/residency | 01 principles; 05 §19; 08 data matrix; 09 regional cells | Nine-language architecture; no reviewed shipping translations/global legal finding |
| Caching/queue/events/idempotency | 02 contracts; 03 outbox/dedupe; 04 transport | Rebuildable projections and atomic effects designed; no worker runtime |
| CI/CD/IaC/security/environment config | 06 plan; 08 controls; 09 sequence/config | Planned pipelines/secret references only; no runnable deploy instructions yet |
| Observability/analytics/cost | 01 metrics; 02 telemetry; 08 retention; 09 costs/SLOs | Event/log policy and measurement plan; no dashboards/bills |
| RPO/RTO/backup/failover/disaster recovery | 09 objectives/runbook; 08 deletion ledger | Proposed targets; no backup/restore/region drill |
| Unit/integration/API/UI/load/stress/security tests | 04 tests; 05 tests; 06 acceptance; 08 negatives; 09 load | Test plans only; static artifact checks below are separate |

## Verification completed in the architecture phase

`python3 scripts/validate_architecture.py` uses only the Python standard library. It checks:

1. Every relative Markdown document link resolves to an existing local artifact.
2. All 25 requested core entities have documented sections with purpose, columns, primary/foreign keys, indexes, partition strategy and growth context; support schemas are present.
3. The OpenAPI JSON parses, all local references resolve, operation IDs are unique, declared path parameters match paths, known security schemes are used, private ownership policies are present, error/rate-limit responses exist, 204 responses have no body, and idempotent creates require a header.
4. Arrays/text/numeric input schemas have finite bounds, object request schemas reject unknown fields, conditional-version operations declare 412/428, and mutable source response types carry resource versions where required.
5. Typed body request/response schemas and pagination envelopes are connected to every declared operation; placeholders remain clearly marked.
6. Direct-chat request/response/edit/reaction schemas contain ciphertext envelopes and no plaintext content fields; pre-acceptance requests contain no private introduction; upload encryption mode is explicit.

Latest run passed: **12 Markdown documents, 18 resolved local links, 25 core entities, 98 API paths, 116 unique operations, 153 schemas, and 1,521 resolved local references**. Command: `python3 scripts/validate_architecture.py` (exit 0).

These are structural checks, **not** a full OpenAPI meta-schema validator, generated-client compilation, SQL execution, unit/integration/security tests, a legal review, or a scalability benchmark. A standard OpenAPI linter/generator, source DB tests, physical device tests and staging provider tests are required in the foundation phase. No external cloud state was changed.

## Remaining work and first approved slice

After architecture approval, create toolchain/monorepo setup, the Flutter shell/design components, versioned migrations and API foundation, then identity/profile/privacy behavior with tests. The minimal vertical slice validates login/session handling, profile read/update, privacy read/update, block authorization and structured telemetry before feed/chat volume is added.

Before any real production release, choose launch markets/regions, age-assurance and retention policy, identity/verification/push vendors, moderation staffing and incident ownership, cloud budget, and signing/account configuration. Run required tests and recovery drills. The updated E2EE requirement is mandatory. Complete protocol/library/device-key integration and the interception test plan before chat implementation; no uninspectable-device guarantee is possible.
