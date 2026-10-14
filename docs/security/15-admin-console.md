# Admin console (staff moderation access)

**Status:** implemented 13 October 2026 in `services/api/cmd/admin`, `services/api/internal/admin`, `services/api/internal/store/moderation.go`, migration `0031_admin_operators.sql` and `apps/admin`. Extended 14 October 2026 with the content preview, quarantine cases and least-privilege database roles (`internal/admin/content.go`, `internal/store/admincontent.go`, migration `0036_moderation.sql`, `database/roles/roles.sql`; runbook: [16](16-csam-and-illegal-content.md)). Not independently reviewed or penetration tested. This is the day-to-day tool for trust and safety; `cmd/moderate` remains as the break-glass command line and runs the same store methods.

Hiyall has members from age 13 and open Discover, so staff access to reports is treated as a high-risk surface: it is a separate process with its own authentication, sees as little as the job needs, and records everything it shows or changes.

## Threat model for staff access

| Threat | Control |
|---|---|
| Member or attacker reaches an admin route | Separate binary, loopback listener by default, separate auth. A member token means nothing here and a console session means nothing on the public API. Admin routes are not in the public OpenAPI. |
| Stolen or guessed staff password | argon2id hashes, mandatory TOTP with no bypass, 5 failures per 15 minutes per account and per address (in the database), generic errors. |
| Phished password plus code | Codes are single use (replay protected); sessions are short and tied to a cookie scripts cannot read; every action is audited with a reason; roles limit what one account can do. |
| Browser based attack on a signed-in operator (CSRF, XSS, clickjacking, DNS rebinding) | `SameSite=Strict` HttpOnly cookie, CSRF header on every mutating request, same-origin check, no CORS, CSP `default-src 'self'` with no inline script or style, `frame-ancestors 'none'`, Host allow-list. All case text is rendered as text by React. |
| Insider browsing member data | Staff see reports, not accounts: no message content beyond what a reporter chose to share, no location, no visitors, no birth dates, no email. The **text and photos of a reported public item** are shown only to moderators and up, after typing a reason; quarantined uploads only to administrators, blurred until an explicit reveal. Every case, user, content and photo view is audited before data is returned. |
| Insider tampering with the trail | The console's database role (`hiyall_admin`, see Database roles) holds **INSERT and SELECT only** on `operator_audit`: no UPDATE, DELETE or TRUNCATE, and it does not own the table, so it cannot drop or disable the trigger either. The trigger from migration 0031 is the second line: it refuses UPDATE, DELETE and TRUNCATE for any role that has the privilege, including a superuser, **but the table owner (`hiyall_migrate`) or a superuser can still disable or drop it**. So the owner credential is used only by the release step, never by a running service, and the public API role has no access to the operator tables at all (a test proves both). |
| Hasty or wrongful sanction | Mandatory written reason (10 to 1000 characters) on every action, a confirmation step for suspend, restore for any suspension, an administrator cannot disable themselves, and the last active administrator cannot be disabled or demoted. |
| Database copy | Password hashes are argon2id; TOTP secrets are AES-256-GCM sealed under `ADMIN_DATA_KEY`, which is not in the database; login-attempt keys are HMACs, not addresses. |
| Console exposed to the internet | Refuses to start on a non-loopback address unless `ADMIN_ALLOW_REMOTE=true` and TLS is in front; see deployment. |

Out of scope today: SSO, hardware security keys (WebAuthn), per-case access scopes and expiry, dual control for sanctions. See the end of this page.

## Authentication

* Operators live in the `operators` table, separate from members, created **only** by `admin operator-add` on the server. No HTTP route creates an account.
* Sign-in is one request carrying email, password and code (the UI shows two screens). A wrong password, a wrong code, an unknown account, a disabled account and a replayed code are indistinguishable: `401 SIGN_IN_FAILED`, with the same work done in each case (an argon2 verification against a throwaway hash for unknown accounts).
* **Password:** argon2id, 64 MiB, 3 passes, 2 lanes, 16 byte salt; parameters are stored in each hash, so they can be raised later. Minimum 12 characters. At most 4 hashes run at once, to bound memory.
* **TOTP (mandatory):** RFC 6238, SHA-1, 30 s, 6 digits, one step either side of now, constant time comparison. The step that matched is stored (`totp_last_step`) and must be newer next time, so a code cannot be reused, even by two simultaneous requests. A password alone never opens a session in any mode.
* **Lockout:** every attempt is written to `operator_login_attempts` under a lock before it is checked. 5 failures in 15 minutes for the same email (typed, whether or not the account exists) or from the same client address, and further attempts get `429 TOO_MANY_ATTEMPTS` with `Retry-After`, even with correct credentials. The state is in PostgreSQL, so it survives restarts and applies to every node. A lockout lifts by itself; an attacker can lock a named account out for up to 15 minutes, which is the accepted cost.
* **Sessions:** 256 random bits; only the SHA-256 is stored. Cookie `__Host-hiyall_admin` (`hiyall_admin` over plain loopback HTTP), `HttpOnly`, `SameSite=Strict`, `Secure` whenever TLS is in front. Expires 8 hours after sign-in or after 30 minutes without a request, and when the account is disabled. Role and disabled state are read from the database on every request, so a role change or disable applies to open sessions at once.
* **CSRF:** the server derives a token from the session secret (HMAC) and returns it from `login` and `me`; every POST must send it in `X-CSRF-Token`. An `Origin` that is not this host, or `Sec-Fetch-Site: cross-site`, is refused. Bodies must be `application/json`, at most 16 KiB, with no unknown fields.
* **Headers on every response:** `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; ... frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, COOP/CORP same-origin, restrictive `Permissions-Policy`, HSTS when secure. No CORS header is ever sent. API responses are `Cache-Control: no-store`.
* **Rate limit:** 20 requests per second (burst 60) per operator on every authenticated route.

## Roles

| Role | Can |
|---|---|
| `viewer` | read the queue, cases, and a member's moderation view |
| `moderator` | everything a viewer can, plus resolve reports (dismiss, warn, suspend), restore suspended members, read the **text and photos of a reported public item** (with a reason) and list and read quarantine cases (evidence record only, no image) |
| `admin` | everything a moderator can, plus manage operators (list, disable, enable, change role), read the audit log, look up a member's sign-in identity, and **load, reveal and decide quarantined uploads** |

Every route checks its role on the server before running (`Server.handle`); the test suite walks all registered routes against all roles. The last active administrator cannot be disabled or demoted, and nobody can disable their own account over HTTP. `admin operator-disable` on the server can disable any operator, including the last administrator, because a stolen administrator device must be closable.

## Endpoints

JSON under `/admin/v1`, same envelope as the public API: `{"success":true,"data":...,"meta":{"requestId","serverTime"}}` or `{"success":false,"error":{"code","message"},...}`. Not in `docs/api/openapi-*.json`: this is a different audience.

| Method and path | Role | Notes |
|---|---|---|
| `POST /login` | none | `{email,password,code}` sets the cookie, returns `{operator,csrfToken,expiresAt}` |
| `POST /logout` | any | ends the session |
| `GET /me` | any | `{operator,csrfToken,expiresAt}` |
| `POST /me/password` | any | `{current,new}`; ends your other sessions |
| `GET /reports?status=&severity=&minor=&subject=&limit=&cursor=` | viewer | `status` open (default), actioned, dismissed, all. Open is the work queue: reports involving a member under 18 first, then high severity, then oldest. Other statuses list newest first. Signed 15 minute cursors bound to operator and filters; `422 INVALID_CURSOR` otherwise. Returns `{items,nextCursor,hasMore}` |
| `GET /reports/{id}` | viewer | the case (below). Audited as `case_view` |
| `POST /reports/{id}/resolve` | moderator | `{action: dismiss\|warn\|suspend, reason, confirm}`; suspend needs `confirm: true`. `409 REPORT_CLOSED` if already resolved |
| `GET /users/{id}` | viewer | moderation view (below). Audited as `user_view` |
| `GET /users/{id}?identity=true` | admin | adds the sign-in identity (provider and opaque subject). Audited as `user_identity_view` |
| `POST /users/{id}/restore` | moderator | `{reason}`; `409 NOT_SUSPENDED` if the account is not suspended |
| `POST /reports/{id}/content` | moderator | `{reason}` (10 to 1000 characters). Returns the reported post, comment, story, space, space entry or member avatar: `{content:{text,authorUsername,deleted,...},media:[{mediaId,width,height,url}],mediaAvailable}`. `url` is a console path (`/admin/v1/media/{mediaId}?t=...`) valid two minutes, bound to the operator and photo. `422 NO_PREVIEW` for chats. Audited as `report_content_view` with the reason, before the read |
| `GET /media/{mediaId}?t=` | moderator (administrator for a quarantine link) | streams the photo (`image/jpeg`, `no-store`) from storage with the console's read-only token. `422` for a missing, expired, tampered or foreign token, `503 MEDIA_UNAVAILABLE` without `ADMIN_MEDIA_*`. Audited as `content_media_fetch` / `quarantine_media_fetch` before a byte is fetched |
| `GET /content-cases?status=&limit=&cursor=` | moderator | quarantine cases newest first, status `open`, `confirmed`, `reported`, `cleared`; no imagery |
| `GET /content-cases/{id}` | moderator | the evidence record (uploader, age band, scanner signals, SHA-256, size, hold dates, status); never an object key. Audited as `content_case_view` |
| `POST /content-cases/{id}/view` | admin | `{reason}`; returns a link to the **blurred** image. Audited as `quarantine_media_view` |
| `POST /content-cases/{id}/reveal` | admin | `{reason}`; records the explicit unblur (the page then removes the blur). Audited as `quarantine_media_reveal` |
| `POST /content-cases/{id}/resolve` | admin | `{action: confirm\|clear\|reported, reason, reportReference?, legalHold?}`; `reported` needs the reference of the report made outside the console; `409 CASE_STATE` for a step the case does not allow. Confirm and reported set the legal hold. Audited in the same transaction
| `POST /holds/{caseId}/release` | admin | `{reason}`: releases the evidence hold of a quarantine case. `409` `HOLD_CASE_OPEN`, `HOLD_LEGAL_HOLD`, `HOLD_REPORT_OPEN`, `HOLD_OTHER_CASE_OPEN` or `HOLD_ALREADY_RELEASED`. Deletes nothing at once: the maintenance job removes the files after `holdUntil` ([16](16-csam-and-illegal-content.md)). Audited as `hold_release` |
| `GET /audit?operator=&action=&target=&limit=&cursor=` | admin | newest first; the first page of a visit is itself audited (`audit_view`) |
| `POST /audit/prune` | admin | `{reason, olderThanDays?}` (default and minimum 365): prunes audit entries older than that through the database function; see Audit log. Audited as `audit_prune` |
| `GET /operators` | admin | never includes credentials |
| `POST /operators/{id}/disable`, `/enable`, `/role` | admin | `{reason}` (and `{role}`); `409 LAST_ADMIN`, `SELF_DISABLE`, `NO_CHANGE` |

Resolve and restore call the same store methods as `cmd/moderate` (`ResolveReportWith`, `RestoreUserWith`). Suspend sets the account to `suspended`, revokes every member session and sends the realtime disconnect notice, in one transaction with the audit entry.

## What staff can and cannot see

**A case shows:** the report (reason, severity, status, description, target type and id); the reported member and the reporter in summary (display name, username, **age band** `minor` or `adult`, account status, how often they were reported and how often they reported); whether a minor is involved; the messages the reporter chose to share with the sender side and time taken from the relay's records; the held encrypted images as **blob id, role, size and SHA-256 only**; the subject's other reports and earlier moderation actions.

**Never shown, by construction:** message content or ciphertext the reporter did not share (the console never reads `messages` or `message_envelopes`); the decryption descriptor or key of a shared image (dropped before the case is built); object keys (images are not fetched, decrypted or viewable); birth dates or exact ages; location; profile visitors; member email addresses (the platform does not store them; the identity provider holds them); the content of reported posts, comments, stories, spaces and entries **unless a moderator asks for it with a reason** (see Content preview below), and anything from a private chat.

**The user view** adds only account status, age band, live session count, reports against and by the member, and moderation actions.

## Content preview and quarantine cases

A report about a public item (`post`, `comment`, `story`, `space`, `space_entry`) or a member (`user`, which shows the avatar) has a **View reported content** button for moderators and administrators. It asks for a reason, then `POST /reports/{id}/content` writes the audit entry and returns the text and the photos. Chats (`conversation`, `message`) have no preview, ever: the case still shows only what the reporter shared.

Photos are **proxied, not linked**. The console fetches the object from storage with its own read-only token (`ADMIN_MEDIA_ENDPOINT`, `ADMIN_MEDIA_ACCESS_KEY`, `ADMIN_MEDIA_SECRET_KEY`, bucket `ADMIN_MEDIA_BUCKET`; never the API's write token) and streams it from `/admin/v1/media/{id}` behind a token that is an HMAC of the operator, the photo, the report or case, and a two minute expiry (key derived from `ADMIN_DATA_KEY`). The browser never receives a storage URL or object key, the page's CSP (`img-src 'self'`) would block one anyway, and each photo fetch is its own audit row. Without `ADMIN_MEDIA_*` the console shows text only and says so.

**Quarantined uploads** (the upload scanner's flags and matches, [16](16-csam-and-illegal-content.md)) are listed under *Quarantine* for moderators and up, as an evidence record. Only administrators can load the image: a reason first (`quarantine_media_view`), shown **blurred by default**, and an explicit **Reveal image** click (`quarantine_media_reveal`, an audit row of its own). The console never deletes a held object and never sends anything to an authority; an administrator records the reference of a report made elsewhere.

## Audit log

`operator_audit` records, for every read of a case or user view and every action: operator id and email, action, target, reason, truncated client address, time, and a small detail object (for example the subject id or a role change from and to). Content actions are recorded as `report_content_view`, `content_media_fetch`, `content_case_view`, `quarantine_media_view`, `quarantine_media_fetch`, `quarantine_media_reveal` and `content_case_confirm` / `_clear` / `_reported`. Sign-in, sign-out, password changes and operator management are recorded too; command line changes are recorded with `cli:<os user>` as the actor. Actions write their audit entry in the same transaction as the change; reads write it before returning any data and fail if it cannot be written.

Privacy stance: client addresses are stored **truncated** in the audit log and sessions (IPv4 /24, IPv6 /48), enough to tell the VPN from somewhere else and not to identify a household. Login attempt records hold only keyed hashes of the email and address and are deleted after 2 days. The log holds no message text. Retention follows the "Security/admin audit" row of [08](08-security-and-privacy.md): 180 days online, then archive; the append-only trigger means pruning needs a reviewed migration, not an ad hoc DELETE.

**Retention.** Audit entries older than a year may be pruned by an administrator: `POST /admin/v1/audit/prune` `{reason, olderThanDays?}` (default and minimum 365; the console role has no DELETE on the table). The append-only trigger stays on for every role: the database function `prune_operator_audit` (migration 0038, `SECURITY DEFINER`, executable only by `hiyall_admin`) is the only way an entry is removed. It runs as the table's owner, switches the trigger off for its single `DELETE` and on again in the same transaction (a failure leaves it on), refuses anything younger than 365 days whatever it is asked, needs a reason, and writes its own `audit_prune` entry (rows deleted, cut-off, reason). Review the log as the runbook says before pruning anything. Tests: `TestAuditPruneKeepsTheLogAppendOnly`, `TestHoldAndAuditFunctionsAreGrantedToOneRoleEach`.

Not audited per row: the queue listing and the operator list (they show summaries, not cases).

## Deployment

1. **Never expose the console to the internet.** Run it where only staff can reach it: a VPN or SSO-aware reverse proxy (identity-aware proxy, mTLS or equivalent) in front, TLS terminated there.
2. Default is `ADMIN_ADDR=127.0.0.1:8081`. A non-loopback address (including `:8081`) is refused at startup unless `ADMIN_ALLOW_REMOTE=true` **and** TLS is in front: native (`ADMIN_TLS_CERT` and `ADMIN_TLS_KEY`) or `ADMIN_TRUST_PROXY=true`. Behind a proxy, set `ADMIN_ALLOWED_HOSTS=admin.example.internal` (required for non-loopback listeners, recommended always) and have the proxy pass `Host`, set `X-Forwarded-Proto: https` and append the real client address to `X-Forwarded-For`. With `ADMIN_TRUST_PROXY=true` the console rejects any request without `X-Forwarded-Proto: https`, takes the client address from the last `X-Forwarded-For` entry, and marks cookies `Secure`. Do not set it unless a proxy you control is the only way in.
3. Environment: `APP_ENV`, `ADMIN_DATABASE_URL` (the `hiyall_admin` role, production requires `sslmode=verify-full`; it falls back to `DATABASE_URL` in development), `ADMIN_DATA_KEY` or `ADMIN_DATA_KEY_FILE` (32 random bytes, base64: `openssl rand -base64 32`, held in a secret store, never in the database or repository), `ADMIN_STATIC_DIR` (built console, default `apps/admin/dist` relative to the working directory; `/console` in the image), and optionally `ADMIN_MEDIA_*` (a read-only token for the media bucket, for the content preview).
4. Use a **separate database role** for the console (see Database roles). Production **refuses to start on the API's `DATABASE_URL`** unless `ADMIN_ALLOW_SHARED_DB=true`. Run migrations with a third role.
5. Build the console: `npm run admin:install && npm run admin:build` (or `scripts/dev-admin.sh` in development), or build the image: `docker build -f services/api/Dockerfile.admin -t hiyall-admin .` (CI does this on every change). Deploy steps: [deploy guide, section 11](../deployment/10-deploy-guide.md#11-admin-console-database-roles-and-upload-scanning).

## Database roles

`database/roles/roles.sql` defines three roles, least privilege, re-runnable (run it after every `migrate`):

| Role | Used by | Can | Cannot |
|---|---|---|---|
| `hiyall_migrate` | the release step (`/migrate`) only | owns the schema; creates and alters tables, triggers and grants | nothing is run with it besides migrations |
| `hiyall_api` | the public API (`DATABASE_URL`) | read and write member data; `INSERT` into `content_cases` (the scanner opens a case); read `schema_migrations`; `EXECUTE` `held_objects_due` and `mark_hold_purged` (the maintenance job that removes the files of released evidence holds) | any access to `operators`, `operator_sessions`, `operator_login_attempts`, `operator_audit` or their sequence; read or change a case; DDL; TRUNCATE |
| `hiyall_admin` | the console (`ADMIN_DATABASE_URL`) | read what cases and member views show; update `users`, `reports`, `sessions`, `content_cases` for moderation; insert `moderation_actions`; run the operator tables; **INSERT and SELECT on `operator_audit`**; `EXECUTE` `prune_operator_audit` | UPDATE, DELETE, TRUNCATE or DDL on `operator_audit`; any access to messages, envelopes, locations, visitors, devices or keys; write to the media bucket |

Two trigger functions that moderation writes fire (`users_status_counters`, `revoke_session_devices`) are `SECURITY DEFINER` since migration 0036 so the console role needs no grant on the tables they touch. `TestDatabaseRolesHaveLeastPrivilege` and `TestConsoleWorksEndToEndOnTheRestrictedAdminRole` check the grants and run the whole console on the restricted role; CI fails if they skip. Roles are created `NOLOGIN` (many managed databases do not let the migration role create roles, so this is a script, not a migration): give each a password or certificate once with `ALTER ROLE ... LOGIN PASSWORD`, outside the repository.

Losing `ADMIN_DATA_KEY` means no operator can sign in; re-enrol each with `admin operator-reset`. Rotating it is the same procedure.

## Operator onboarding

1. On the server, as someone allowed to run it: `admin operator-add -email name@example.org -role moderator`. The password is read from a terminal prompt (twice, no echo) or from the first line of stdin; it is never a flag, never printed and never logged.
2. The command prints an `otpauth://` URI and a base32 secret **once**. Hand them to the new operator over a channel you trust; they add it to an authenticator app. The secret is stored sealed and cannot be shown again.
3. The operator signs in, then changes the password under Account (the person who ran the command knew the first one).
4. Role changes and disabling are done by an admin in the console, with a reason.

## Incident: stolen or lost operator device

1. An administrator disables the operator in the console (Operators, Disable, with a reason). Their sessions end immediately and sign-in is refused. If the device belonged to the only administrator, run `admin operator-disable -email ... -reason ...` on the server, which has no last-administrator guard.
2. Review `operator_audit` for that operator and address since the last known good time: which cases and members were viewed, which actions taken. Reverse mistaken or malicious actions with restore, and note why.
3. Before re-enabling or re-issuing access: `admin operator-reset -email ...` gives a new password and a new authenticator secret and ends all sessions. The old authenticator on the lost device is then useless.
4. If a password was reused elsewhere or the device was unlocked, treat the data seen as exposed and follow the data incident process in [08](08-security-and-privacy.md). If `ADMIN_DATA_KEY` or a database dump may have leaked, rotate the key and reset every operator.

## Not done

* Single sign-on and WebAuthn security keys (today: password and TOTP).
* Case-scoped access with purpose and expiry; a second approver for sanctions; appeals tooling.
* Held **encrypted chat** images are listed but not viewable (the console has no key, by design). Public items and quarantined uploads are viewable as described above.
* Releasing an evidence hold from the console, case assignment, and a second approver for quarantine decisions ([16](16-csam-and-illegal-content.md#9-not-built-yet)).
* Alerts on unusual operator access volume; the audit log is read by an admin, not monitored.
* The console's integration tests use their own database, `hiyall_test_admin` (`ADMIN_TEST_DATABASE_URL`, or `TEST_DATABASE_URL` with the name swapped), so they never share one with the API tests that truncate tables. CI creates it and fails the job if any of them skips. Locally they skip when that database does not exist: `createdb hiyall_test_admin` and run `go run ./cmd/migrate` against it (`scripts/check.sh` does not create it).
