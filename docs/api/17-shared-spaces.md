# Phase 6: communities, Moments and events

Communities, timed Moments and events use `/v1/spaces`. Direct chat remains on
its separate encrypted relay. Space discussion entries are server-readable
shared content: the composer and discussion screen explain this distinction.
There is no unencrypted private or event chat endpoint.

## Using the app

Discover → Circles or Moments, then Find your circle, opens the space browser. Filter by
kind or Joined, pull to refresh and load subsequent pages. Create a space with
its description, rules, capacity and audience. A community host can create
Moments and events under that community. The global creation sheet also links
here. Invitations and approvals appear in Activity and open the space.

Public spaces accept any active, onboarded member immediately. Private spaces show preview
metadata and require host approval; discussion, participants and private event
locations require active membership. Invite-only spaces are invisible to
uninvited people; hosts invite by exact username. Invited people accept before
participating. Join requests and invitations are bounded to 1000 outstanding
memberships per space. Hosts can maintain 50 open, unexpired spaces.

Owners can promote admins. Owners/admins can appoint moderators and manage
invitations; moderators can approve requests, remove/ban ordinary members and
remove entries. Moderators cannot modify admins or owners; admins cannot modify
other admins. The owner retains membership. A ban hides the space and prevents
rejoining until a host unbans the person.

## API

All routes require authentication and a completed onboarding. There is no age or eligibility check beyond that: the old `403 ADULT_SPACE_REQUIRED` and the `discovery_eligibility` gate are gone (see [Nearby and open access](19-nearby-and-open-access.md)), and spaces are open to every member who declared the minimum age of 13, within their own age band: a space hosted by a member of the other band (minors and adults are kept apart, `AGE_BAND_ISOLATION`) is invisible and cannot be joined, read or written, exactly as if its host had blocked you.

| Method | Route | Purpose |
|---|---|---|
| GET / POST | `/v1/spaces` | Browse / create |
| GET / PUT | `/v1/spaces/{id}` | Metadata / host edits |
| PUT / DELETE | `/v1/spaces/{id}/membership` | Join or RSVP / leave |
| PUT | `/v1/spaces/{id}/status` | Open, close or archive |
| POST | `/v1/spaces/{id}/invitations` | Invite by username |
| GET | `/v1/spaces/{id}/members` | Active, pending, invited or banned members |
| PUT | `/v1/spaces/{id}/members/{userId}` | Approve, invite, remove, ban, unban or set role |
| GET / POST | `/v1/spaces/{id}/entries` | Read / publish discussion; the POST takes an optional `Idempotency-Key` header (see [Pulse: idempotency](16-pulse-and-media.md#idempotency-creating-posts-stories-and-space-entries)) and answers 201 |
| DELETE | `/v1/spaces/{id}/entries/{entryId}` | Author/moderator removal |

**Invitations by username reveal nothing.** Anyone can check whether a username is taken (`GET /v1/usernames/{name}/availability`), so `POST /v1/spaces/{id}/invitations` answers exactly the same, status and body, whether the name belongs to a member the host may invite, to someone in the other age band, blocked from (or blocking) the owner or the inviting host, not onboarded, or to nobody: the space as a successful invitation returns it, or the same refusal a real invitation would meet first (`403 SPACE_ROLE_REQUIRED`, `403 SPACE_MEMBER_REQUIRED` for a child space when the person is not in the parent community, `409 SPACE_CLOSED`, `409 SPACE_FULL` at 1000 outstanding). Only a member the host may reach is invited, notified, signalled and pushed. The invited-members list (`?state=invited`) still shows only real invitations, to moderators. `PUT /v1/spaces/{id}/members/{userId}` with `invite` takes an id, which the profile endpoint already answers 404 for, and keeps answering 404 for someone who cannot be invited.

**Moderation needs someone in the space.** `remove` needs an existing membership row and `ban` needs a row or a member the actor may reach (active, onboarded, not barred, by block or age band, from the owner or from the acting moderator); `approve`, `unban` and role changes need the matching state. Anything else, including an id that names no account, is `404 NOT_FOUND`, never a 500 (a foreign-key violation on a caller-supplied id is mapped to 404 everywhere). The barrier is checked against the acting moderator as well as the owner for invitations and approvals too. Only a change to the membership row (state, role or RSVP) signals and pushes the target, and the push respects the target's mute or restrict of the actor.

Browse accepts `kind=community|moment|event`, optional `parentId` and `mine=true`.
Every list supports `limit=1..50` and opaque cursors bound to user, space, kind
and membership-state filters; cursors expire after 15 minutes. Responses use the
standard envelope; POST creation returns 201. See the generated foundation
OpenAPI contract for request and response fields.

Capacity is 2–10000 including the owner; going and interested RSVPs both occupy
membership slots. Membership changes lock one space row before updating its
count, preventing over-capacity concurrent joins. Moment duration is at most
24 hours; event duration at most 30 days. The app picks dates in device-local
time, submits UTC and retains the declared IANA host zone. A Moment accepts
entries only between start and end. Expired/closed/archived discussions remain
readable to members. A host can edit/extend the schedule and reopen the space;
changing its audience or parent is prohibited to protect existing discussions.

Member status (active and onboarded), host account status, two-way blocks and bans are
rechecked on every request. Parent community membership gates child spaces. Losing parent access
immediately hides children; existing child membership records are retained so
rejoining the parent restores them. Entries and participant lists omit blocked
or deactivated members. Space and entry reporting uses `/v1/reports` with
`targetType=space|space_entry`; entry reports require current membership.

## Verification and limits

Integration tests cover admission, invitation-only previews, parent gates,
role hierarchy, moderation, reporting, members with no eligibility row, members who are not onboarded or active, block filtering,
cursor isolation, schedule expiry, simultaneous joins at capacity and role
revocation while a moderator is waiting on a row lock. Widget
tests cover browse filters, joining, discussion posting, revoked-access clearing,
composer validation and absence of moderator/child-creation controls for
ordinary members.

This is a local functional release, not a 100M-user capacity claim. Keyset
pagination and per-space locks bound work, but hot spaces still serialize writes;
load testing, read projections, partitioning and cell routing remain future
scale work. Spaces are capped at 10000 participants. Discussion refresh uses a
30-second foreground timer and manual refresh, rather than per-entry socket
fanout. Polls, threaded replies, reactions, scheduled reminder delivery, external
calendar integration, encrypted group/event chat and ownership transfer are not
implemented by this slice. Existing private E2EE chat is accessible through each
participant's profile and its established messaging policy.

**Events and Moments are off for V1.** Unless the server sets `SPACES_EVENTS_ENABLED=true`, `POST /v1/spaces` with `kind` `event` or `moment` answers `403 FEATURE_DISABLED` ("Events and Moments aren’t available yet."); communities are unaffected, and existing events and moments can still be read, edited and left. The app hides creation, the Moments tab and the Events tab of a community unless built with `--dart-define=ENABLE_EVENTS=true`; a linked event or Moment still opens, without a Join button.
