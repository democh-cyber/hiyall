# Phase 6: communities, Moments and events

Communities, timed Moments and events use `/v1/spaces`. Direct chat remains on
its separate encrypted relay. Space discussion entries are server-readable
shared content: the composer and discussion screen explain this distinction.
There is no unencrypted private or event chat endpoint.

## Using the app

Discover → Communities · Moments · Events opens the space browser. Filter by
kind or Joined, pull to refresh and load subsequent pages. Create a space with
its description, rules, capacity and audience. A community host can create
Moments and events under that community. The global creation sheet also links
here. Invitations and approvals appear in Activity and open the space.

Public spaces accept eligible adults immediately. Private spaces show preview
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

All routes require authentication and current trusted adult eligibility.

| Method | Route | Purpose |
|---|---|---|
| GET / POST | `/v1/spaces` | Browse / create |
| GET / PUT | `/v1/spaces/{id}` | Metadata / host edits |
| PUT / DELETE | `/v1/spaces/{id}/membership` | Join or RSVP / leave |
| PUT | `/v1/spaces/{id}/status` | Open, close or archive |
| POST | `/v1/spaces/{id}/invitations` | Invite by username |
| GET | `/v1/spaces/{id}/members` | Active, pending, invited or banned members |
| PUT | `/v1/spaces/{id}/members/{userId}` | Approve, invite, remove, ban, unban or set role |
| GET / POST | `/v1/spaces/{id}/entries` | Read / publish discussion |
| DELETE | `/v1/spaces/{id}/entries/{entryId}` | Author/moderator removal |

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

Eligibility, host account status, two-way blocks and bans are rechecked on every
request. Parent community membership gates child spaces. Losing parent access
immediately hides children; existing child membership records are retained so
rejoining the parent restores them. Entries and participant lists omit blocked
or no-longer-eligible adults. Space and entry reporting uses `/v1/reports` with
`targetType=space|space_entry`; entry reports require current membership.

## Verification and limits

Integration tests cover admission, invitation-only previews, parent gates,
role hierarchy, moderation, reporting, current age eligibility, block filtering,
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
