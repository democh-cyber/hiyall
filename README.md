# Kairova — global social + chat platform

Kairova is a provisional brand for an original, privacy-conscious social network and chat application for Flutter Android/iOS, with future web support. Brand/domain clearance is still needed before public launch.

**Current status: the first runnable foundation is implemented, 7 October 2026.** Flutter navigation, live profile/privacy editing, Go API, PostgreSQL migrations, session revocation, blocks, and privacy-aware people search are implemented. Discovery requires trusted adult eligibility; its age-assurance integration remains pending. The Gen Z visual redesign and a complete interactive screen design studio are supplied; chat, feed and production release backend work remain pending.

Run `./scripts/dev-api.sh` and `./scripts/dev-mobile.sh` in separate terminals. Open `http://127.0.0.1:49321`. See [development setup, implemented behavior and release boundaries](docs/development.md). Toolchains were installed per-user and are recorded in [toolchains.lock.json](toolchains.lock.json).

Open [the screen design studio](http://127.0.0.1:49321/#/design) to explore the full UI brief. Sample screens are explicitly marked and do not send messages, publish content, create accounts or place calls. Read [the brand, full screen inventory, flows, concepts and interaction specification](docs/ux/08-gen-z-experience.md).

## Review the architecture

Start with the [decision summary and requirement coverage](docs/architecture/10-review-and-traceability.md). Then review the requested starting deliverables:

| Deliverable | Document |
|---|---|
| A. Product requirements | [Vision, personas, journeys, MVP and future scope](docs/architecture/01-product-requirements.md) |
| B. Technical architecture | [Modules, diagrams, feed/chat/media/search/recommendations](docs/architecture/02-technical-architecture.md) |
| C. Database design | [All 25 requested entities, ER diagram, keys/indexes/partitioning/growth, supporting schemas](docs/database/03-database-design.md) |
| D. API design | [API rules and full roadmap inventory](docs/api/04-api-specification.md), [typed MVP OpenAPI contract](docs/api/openapi-mvp.json) |
| E. Flutter mobile architecture | [State, routing, networking, storage, offline sync, push, i18n and accessibility](docs/mobile/05-mobile-architecture.md) |
| UX/UI | [Screen inventory, navigation, flows, wireframes, tokens and components](docs/ux/07-ux-and-design-system.md) |
| Security/privacy | [Threat model and privacy](docs/security/08-security-and-privacy.md), [mandatory E2EE and interception protections](docs/security/11-encryption-and-interception.md) |
| Capacity/deployment | [1K→100M model, AWS/equivalent boundaries, SLOs, RPO/RTO, CI/CD and runbooks](docs/deployment/09-capacity-and-operations.md) |
| Implementation plan | [Incremental slices, acceptance criteria and approval boundary](docs/architecture/06-implementation-plan.md) |

## Proposed foundation

- Flutter + Riverpod + go_router + Drift/SQLite, encrypted local data and platform secure token storage.
- Go modular monolith with separate HTTP, WebSocket, worker/scheduler and admin processes; React/TypeScript admin.
- PostgreSQL for source transactions, dedicated OpenSearch for search, Redis for ephemeral/cache state, S3-compatible object storage/CDN, durable outbox and queues.
- One home region with Multi-AZ production deployment; extract services, ordered storage and regional cells from measured load and residency requirements.
- Five tabs: Home, Chats, Discover, Notifications, Profile; stories on Home; opt-in Interest Passport and consent-based messaging.
- Mandatory E2EE for direct chats/private chat media; reviewed network trust/pinning and secure local keys. No claim that a compromised endpoint or every request is impossible to inspect.

## Verification status

Run `./scripts/check.sh` for API unit/integration tests with the race detector, Flutter analysis/widget tests and contract checks. The implemented API is described in [openapi-foundation.json](docs/api/openapi-foundation.json); the larger MVP contract is a roadmap. See the development runbook for database setup and actual verification limitations.


Run `python3 scripts/validate_architecture.py` for document links, required entity coverage and OpenAPI structural checks. These checks do **not** validate application behavior, full OpenAPI tooling compatibility, database migrations, security controls, device performance or 100M-user capacity. The [review record](docs/architecture/10-review-and-traceability.md) distinguishes checks run from required future tests.

## Next slices

Configure production sign-in and account/device lifecycle, then integrate and review the required E2EE protocol and network pinning before chat opens. Feed/media/social modules follow incrementally. Provider accounts, launch markets and production infrastructure are configured as their integrations are reached. No backend secrets are included here.
