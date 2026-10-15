# Accounts and onboarding

Production sign-in uses Firebase Authentication, and a new account must finish a short server-enforced onboarding before the rest of the API opens. Implemented in `services/api/internal/identity/firebase.go`, `internal/config/config.go`, `internal/store/onboarding.go`, `internal/httpapi/onboarding.go` and migrations `0015_onboarding.sql` and `0016_open_profiles_nearby.sql` (which renames the age column). Hiyall is for Gen Z and is not adult-only: the age gate is a minimum age of 13, see [Nearby and open access](19-nearby-and-open-access.md). The app side is described in [sign-in and onboarding (app)](../mobile/14-sign-in-and-onboarding.md).

**Status.** Firebase sign-in is implemented on the server and covered by unit and integration tests that use locally signed tokens. It has not been run against a real Firebase project or the real signing-key host, and the app side is being connected. Treat provider sign-in as unverified until that run has happened.

## Firebase mode

Set `FIREBASE_PROJECT_ID` to the Firebase project id.

| Setting | Value |
|---|---|
| Issuer | `https://securetoken.google.com/<project id>` |
| Audience | `<project id>` |
| Signing keys | `https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`, fetched on first use and cached, RS256 only |

The project id must be 4-64 lowercase letters, digits or hyphens. `OIDC_ISSUER` and `OIDC_AUDIENCE` are not required in this mode and stay available for generic OIDC. If they are also set they must equal the derived values; anything else is a startup error, so a half-changed configuration cannot silently verify tokens for the wrong provider. Production still requires an HTTPS issuer (always true here), `sslmode=verify-full` and no development authentication. Startup needs no network: a key-host outage surfaces as `503 AUTH_UNAVAILABLE`, never as a sign-out.

Clients send the Firebase ID token as `Authorization: Bearer <idToken>` on every request, including the realtime socket. Firebase ID tokens last an hour; the SDK refreshes them and the API accepts every refreshed token.

### What is verified

Signature, issuer, audience and expiry as for any OIDC token, then Firebase's own claims:

| Rule | Failure |
|---|---|
| `sub` is non-empty and at most 128 characters | 401 |
| `auth_time` is a JSON number, a whole positive count of seconds, and not more than 5 minutes in the future | 401 |
| `iat`, when present, is not more than 5 minutes in the future | 401 |
| `firebase.sign_in_provider` is present | 401 |
| the provider is not `anonymous` or `custom` | 401 |
| for provider `password`, `email_verified` is `true` | 403 `EMAIL_NOT_VERIFIED` |

Firebase ID tokens have neither `typ: at+jwt`, `token_use` nor a `sid`, so none of those are required in this mode. Social providers (`google.com`, `facebook.com`, `apple.com` and so on) and `phone` are accepted whatever `email_verified` says, because the provider vouches for the identity.

The email rule runs before an account is looked up or created. An unverified password sign-up therefore gets `403 EMAIL_NOT_VERIFIED` ("Verify your email to continue.") with no user, identity or session row written. After the person verifies and the app gets a fresh token, the next request provisions the account.

### Session id

Firebase tokens carry no session id, so the API derives one: `fb:<sub>:<auth_time>`. `auth_time` is fixed for one interactive sign-in and does not change when the SDK refreshes the token, so refreshes reuse one session. Signing in again (or re-authenticating) changes it and starts a new session. The session is tracked as `(issuer, external_sid)` like every OIDC session: it appears in `GET /v1/auth/sessions`, `POST /v1/auth/logout` or a revoke ends it, and a revoked session cannot be recreated by a still-valid token for the same sign-in: revoked rows are kept as tombstones, a revoke reaches idle sessions whose last token expired, and "sign out everywhere else" also refuses any earlier sign-in the server has not seen yet (see [sessions](15-sessions-and-settings.md#identity-provider-sessions-stay-revoked)).

The first valid token for an unknown `(issuer, sub)` creates the account in one transaction: user, profile with a generated `member_<12 hex>` username and the display name "Hiyall member", the open default privacy (public and discoverable once onboarded, see [open defaults](19-nearby-and-open-access.md#open-defaults)), and an **incomplete** onboarding row. A member who has not finished onboarding is never listed in people search or Nearby and their profile answers 404 to everyone else, whatever their settings say.

## Onboarding

An account is *onboarded* once it has declared a birth date that makes it at least the minimum age and accepted the current terms version. The minimum age is `domain.MinimumAge`, currently **13**; the owner can change that one constant and the refusal message follows it. The principal's `onboarded` state is read in the same query that resolves the session, so it adds no round trip.

### Endpoints

`GET /v1/me/onboarding`

```json
{"success":true,"data":{"completed":false,"completedAt":null,"termsVersion":"2026-10-01"},"meta":{...}}
```

`completedAt` is an RFC 3339 UTC time once completed. `termsVersion` is always the *current* terms version, the one the client must send back.

`POST /v1/me/onboarding/complete`

```json
{"birthDate":"1990-04-12","termsVersion":"2026-10-01"}
```

Success is 200 with the same body shape as the GET (`completed: true`, `completedAt`, `termsVersion`). Completing is idempotent: repeating it after success returns the original `completedAt` and writes nothing, including a different valid birth date, which is ignored (the request must still be well formed, and an under-13 date is still refused).

Checks run in this order:

1. The body is a JSON object with exactly `birthDate` and `termsVersion`. `birthDate` is a strict `YYYY-MM-DD` date, a real calendar day, from 1900 on and not in the future. `termsVersion` equals the current version. Otherwise 422 `VALIDATION`.
2. Age is computed on the server in UTC, by calendar date. Under 13 returns 403 `AGE_REQUIREMENT_NOT_MET` ("Hiyall is for people 13 and over.") and stores nothing. Someone who turns 13 today is accepted; someone who turns 13 tomorrow is not.
3. The profile must not still hold its provisioning defaults: the username must not match the generated `member_<12 hex>` shape and the display name must be non-empty and not "Hiyall member" (compared case-insensitively). Otherwise 422 `PROFILE_INCOMPLETE` ("Choose a name and username first.").
4. One transaction records `age_declared_at`, `terms_version`, `terms_accepted_at` and `completed_at`, stores the birth date privately in `member_ages` (`INSERT ... ON CONFLICT DO NOTHING`: the first stored value is final), applies the minor defaults once when the stored date makes the member under 18 (presence `onlineAudience` "nobody" and country audience "friends", privacy version bumped; `messagesFrom` stays "everyone", as for everyone), and appends an `onboarding.completed` outbox event. The response is unchanged and says nothing about age.

`GET /v1/usernames/{username}/availability`

```json
{"success":true,"data":{"available":true},"meta":{...}}
```

The username must match the profile grammar (3-30 lowercase letters, digits or underscores), otherwise 422 `VALIDATION`. It is available when no other account holds it; the caller's own current name is available. Generated `member_<12 hex>` names are never available, and `PATCH /v1/me/profile` refuses to change a username to one (422 `VALIDATION`, "this username is reserved"). The check shares the per-account `search` rate limit (burst 10, one more every 2 seconds): 429 `RATE_LIMITED` with `Retry-After`. It is advisory; the profile `PATCH` is still the authority and can answer 409 `USERNAME_TAKEN` (only when the unique constraint on `profiles.username` is what failed; any other duplicate is a 412 conflict).

**Renaming.** Changing the username starts a **30 day cooldown**: a second change before it ends is 429 `USERNAME_COOLDOWN` with `Retry-After` (`profiles.username_changed_at`, migration 0037). Choosing the first real name over the generated `member_…` one does not start it, a refused rename (taken, reserved) does not either, and the cooldown never blocks other profile edits. `PATCH /v1/me/profile` and `/v1/me/privacy` are also limited per account (burst 30, then one every 3 seconds; 429 `RATE_LIMITED`).

`POST /v1/me/onboarding/age` `{birthDate}` (allowed before onboarding) checks a declared date as soon as it is chosen and stores nothing: `200 {allowed:true}`, `403 AGE_REQUIREMENT_NOT_MET` for a date under 13 (recorded against the sign-in identity, no date kept), and `403 AGE_GATE_COOLDOWN` for 7 days after a refusal, whatever date follows; `complete` refuses the same way. See [18 teen safety](../architecture/18-teen-safety.md#age-gate-t5).

### Gating

Enforced in one place, the authenticated dispatcher, plus the realtime gateway. Until onboarding is complete only these requests pass; everything else, including unknown paths and `/v1/realtime`, returns 403 `ONBOARDING_REQUIRED` ("Finish setting up your profile to continue.").

| Allowed before onboarding | Methods |
|---|---|
| `/v1/me/profile` | GET, PATCH |
| `/v1/me/privacy` | GET, PATCH |
| `/v1/me/onboarding` | GET |
| `/v1/me/onboarding/complete` | POST |
| `/v1/usernames/{username}/availability` | GET |
| `/v1/auth/*` (logout, sessions, revoke) | all |

The location and Nearby routes (`/v1/me/location`, `/v1/discover/nearby`) are deliberately not on this list. Completion takes effect on the next request with the same token; no new sign-in is needed. Health probes and `/dev/session` sit outside the gate.

### Error codes

| Status | Code | When |
|---|---|---|
| 401 | `UNAUTHENTICATED` | Missing, invalid, expired or revoked token; anonymous or custom Firebase sign-in |
| 403 | `EMAIL_NOT_VERIFIED` | Password sign-in whose email is not verified (any route, including the socket) |
| 403 | `ONBOARDING_REQUIRED` | Route outside the allow-list before onboarding |
| 403 | `AGE_REQUIREMENT_NOT_MET` | Declared age under 13 (`domain.MinimumAge`) |
| 422 | `VALIDATION` | Malformed completion body or username |
| 422 | `PROFILE_INCOMPLETE` | Name or username still generated |
| 429 | `RATE_LIMITED` | Username checks or profile edits too frequent |
| 429 | `USERNAME_COOLDOWN` | The username was changed in the last 30 days (`Retry-After`) |
| 503 | `AUTH_UNAVAILABLE` | Signing keys or database unreachable; do not sign the person out |

CORS is unchanged: the same allowed headers and methods, and the same exposed headers (`ETag`, `X-Request-Id`). The refusals above carry the usual CORS headers, so the web client can read them.

## What the minimum-age check is, and is not

The self-declared minimum-age check is **not** trusted age assurance. Anyone can type a date, and a falsified date puts the member in whichever age band it implies. It is a policy gate that keeps an obviously underage declaration out of the app, records that the person accepted the terms, and (since migration `0017`) places the member in an **age band**: a member who declares under 18 is a *minor* and gets stricter protections, and is kept apart from adults, who are everyone else. `discovery_eligibility` is retired: no code reads or writes it. The age bands, what separates them and the protections minors get are in [Nearby and open access](19-nearby-and-open-access.md#age-bands), together with the recommendations that are still not done.

## The birth date is kept privately

This reverses the earlier rule that the birth date was never stored. It is now written once to `member_ages(user_id, birth_date, created_at)`, which is private: no endpoint returns the birth date or a band, no profile or privacy JSON contains one, no outbox payload mentions one and no log line carries one. The one thing derived from it that is shown is the member's **age in whole years on their profile when another member opens it** (`GET /v1/users/{id}/profile`), see below. The member's own profile (`GET /v1/me/profile`) has no age. Error messages do not repeat it and the response does not echo it. A refused under-13 declaration writes nothing. The first stored value is final, so a later request cannot move the member to another band; a member with no stored date (every account from before `0017`) is treated as an adult. Tests scan every table, the outbox and the captured logs for the submitted dates and assert that only `member_ages` holds them, and that no response contains a birth date, a band or an `age` that is null or zero, and that a numeric `age` appears on no route except another member's profile. It is still not a barrier, since the person can submit another date before the first completion, which is why this is a policy gate and not assurance.

## Data and migration

`0015_onboarding.sql` creates `onboarding(user_id PK → users, adult_declared_at, terms_version, terms_accepted_at, completed_at, created_at)` and backfills a completed row with `terms_version = 'legacy'` for every account that exists when it runs, so existing development and fixture accounts keep working. An account with no row is treated as not onboarded, so any code path that creates users directly must create the row too. The demo seed script does. `0016_open_profiles_nearby.sql` renames `adult_declared_at` to `age_declared_at` (0015 is already applied everywhere and is not edited), so every later reference uses the new name. `0017_member_ages_and_gender.sql` creates `member_ages`, the SQL functions `member_age`, `age_band` and `interaction_barred`, and adds the gender audience to existing privacy rows.

## Development fixtures

`/dev/session` accepts four accounts: Anjali and Niko (completed, `terms_version = 'fixture'`, adults), **Kai**, `019a4000-0000-7000-8000-0000000000a2` (completed, a minor aged 15 when first created, gender unset, with the minor defaults applied, so the minor experience can be tried: Kai and the adults cannot see each other) and **Sam**, `019a4000-0000-7000-8000-0000000000a1`. `Seed` stores adult birth dates for Anjali and Niko (adding them to an existing database the first time the API starts after `0017`) and Kai's when it creates Kai. Sam is created with the default placeholders (username `member_0000000000a1`, display name "Hiyall member") and an incomplete onboarding row so the first-run flow can be tried locally. `Seed` is idempotent: it never resets an existing fixture, never completes Sam, and restores a missing row as incomplete. To repeat the flow, reset it in the local database (the statements below; they also clear Sam's birth date and location. The `reset-sam.sh` helper was removed with the fixture sign-in buttons):

```sql
UPDATE onboarding SET completed_at=NULL, age_declared_at=NULL, terms_version=NULL, terms_accepted_at=NULL
 WHERE user_id='019a4000-0000-7000-8000-0000000000a1';
DELETE FROM member_ages WHERE user_id='019a4000-0000-7000-8000-0000000000a1';
UPDATE profiles SET username='member_0000000000a1', data=data||'{"displayName":"Hiyall member"}'::jsonb, version=version+1
 WHERE user_id='019a4000-0000-7000-8000-0000000000a1';
```
