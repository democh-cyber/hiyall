# Hiyall — global social + chat platform

Hiyall is a provisional brand for an original, privacy-conscious social network and chat application for Flutter Android/iOS, with future web support. Brand/domain clearance is still needed before public launch.

**Current status (13 October 2026): a working product slice, not yet a launched service.** Hiyall is for Gen Z and is not adult-only: anyone who declares they are 13 or over can join; every onboarded member is open and discoverable by default and the only member control is a "show when I'm online" setting. Minors (13 to 17) and adults are kept apart wherever blocks apply, based on a birth date members type and that can be falsified. Built and covered by automated tests: Firebase sign-in and server-enforced onboarding (tested with locally signed tokens); profiles and privacy; blocks, reports and safety controls; Discover and people search with age and gender filters; coarse, expiring Nearby; follows and connections; Pulse stories; Spaces (circles, moments, events); one-to-one chat with end-to-end encrypted text and photos (a Rust core on audited Olm for text, a separate attachment bucket for ciphertext) over HTTP plus a realtime WebSocket; presence; per-account limits enforced by the API; hourly cleanup jobs; health, metrics and container packaging ([deploy guide](docs/deployment/10-deploy-guide.md)). The photo path ran against a real Cloudflare R2 bucket in an end-to-end script. **Not verified:** a real Firebase sign-up and a real-device chat session have not been run end to end, nothing has been deployed, the E2EE design has had no independent review, and no load test has run. **Still pending before a public launch:** real-device testing, independent E2EE and security review, push notifications, account deletion and data export, an admin/moderation console and moderation staffing, reviewed Terms and Privacy Policy (drafts only under `docs/legal`), and the first production deployment. See [Remaining work and release boundary](docs/development.md#remaining-work-and-release-boundary).

Run `./scripts/dev-api.sh` and `./scripts/dev-mobile.sh` in separate terminals. Open `http://localhost:49321`. To use real sign-in, run `firebase login` and then `./scripts/firebase-setup.sh <project-id>` once; see [sign-in and onboarding](docs/mobile/14-sign-in-and-onboarding.md#supplying-the-firebase-project). See [development setup, implemented behavior and release boundaries](docs/development.md). Toolchains were installed per-user and are recorded in [toolchains.lock.json](toolchains.lock.json).

Sign-in and onboarding are described in [Sign-in and onboarding (app)](docs/mobile/14-sign-in-and-onboarding.md). Read [the brand, screen inventory, flows and interaction specification](docs/ux/08-gen-z-experience.md) for the design intent.

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
| Plans and entitlements | [Per-member limits as data resolved per member; no paid plans yet](docs/architecture/11-plans-and-entitlements.md) |

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

In order: run chat and photos on real devices and fix what that finds; deploy a staging environment from the container image ([deploy guide](docs/deployment/10-deploy-guide.md)); get an independent review of the E2EE implementation; finish push notifications, account deletion/export and the admin and moderation tooling; publish reviewed Terms and a Privacy Policy; then a closed beta. Larger-scale pieces (separate worker and realtime services, search, caches, multi-region) follow measured load, not guesses. No backend secrets are included here.
