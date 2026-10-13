# Follows, friends and activity

Implemented in migration `0006_social_graph_activity.sql`, `services/api/internal/store/social.go` and `services/api/internal/httpapi/social.go`. The contract is in [openapi-foundation.json](openapi-foundation.json) under the Graph and Activity tags.

## Relationships

| Action | Endpoint | Rules |
|---|---|---|
| Follow | `POST /v1/users/{id}/follow` | Target `followPolicy`: `everyone` (the default) → active at once, `approval` → pending (accepted friends skip approval; only for members who set it through the API, nothing in the app does), `nobody` → 403 `FOLLOW_NOT_ALLOWED`. Repeating returns the current state. |
| Unfollow / withdraw | `DELETE /v1/users/{id}/follow` | Idempotent. Withdrawing removes the owner's pending-request activity row. |
| Approve follower | `POST /v1/users/{id}/follow-requests/accept` | Owner only; `{id}` is the follower. |
| Decline follower | `DELETE /v1/me/follow-requests/{id}` | Owner only. |
| Remove follower | `DELETE /v1/me/followers/{id}` | Drops an active follower without blocking. |
| Friend request | `POST /v1/users/{id}/friend-requests` | Target `requestsFrom`: `everyone`, `followers` (sender actively follows the target), `friends` (friends of friends), `nobody`. Refused → 403 `REQUEST_NOT_ALLOWED`. If the target already asked, this accepts. Resending a pending request returns it. A sender whose request was declined waits 7 days (429 `REQUEST_COOLDOWN`, with `Retry-After` the seconds left). |
| Accept / decline | `POST /v1/friend-requests/{rid}/accept\|decline` | Recipient only; anyone else gets 404. |
| Cancel | `DELETE /v1/friend-requests/{rid}` | Sender only. Removes the recipient's activity row. |
| Unfriend | `DELETE /v1/users/{id}/friendship` | Idempotent. |

Follow, approve, friend-request and friendship actions share one per-account write limit (a burst of 20, then one every two seconds, 429 `RATE_LIMITED`). Unfollow, decline and remove follower are never limited: undoing a connection must always work.

Every write locks both accounts in id order, so crossing or repeated actions cannot deadlock or duplicate rows. Inactive accounts and blocked pairs look identical to missing ones (404). Relationship writes are limited per account.

`GET /v1/users/{id}/profile` includes `relationship` (`following`, `followedBy`, `friendship`, `friendRequestId`, `canFollow`, `canFriendRequest`) and `locked`, and on another member's unlocked profile `canSeeConnections`: whether the viewer may open that member's followers and following lists (the same test as the 403 `CONNECTIONS_PRIVATE` below; for an adult member it is true for someone who has an active follow on them, see below). The counts have their own audience, so a count can be visible while its list is private; the app then shows the number without opening it. Profile and field audiences admit `everyone`, `friends`, or `followers` (friends included).

## Lists

`GET /v1/me/{friends|followers|following|follow-requests}`, `GET /v1/me/friend-requests?direction=incoming|outgoing`, and `GET /v1/users/{id}/{friends|followers|following}`. Another person's lists need access to both their profile audience and their `connections` field audience; otherwise 403 `CONNECTIONS_PRIVATE`. The `connections` audience starts as `followers` for adults, so **anyone who actively follows an adult member (the viewer is the follower, `follows.state='active'`) and their friends may open that member's followers and following lists**, read-only; a pending follow request, an unfollow, or the member following the viewer does not count, and the access follows the follow at once. For members under 18 the audience starts as `friends`, so their followers do not get in. The **friends list** is the exception: it reads the same field with `followers` taken as `friends`, so it stays for the member and their friends (an owner who set `everyone` still opens it to everyone). The relationship's `followers` audience means "the viewer follows the owner, or is their friend" (`domain.Relationship.Allows`). Migration `0026` moved existing adult members from the old `friends` default to `followers`; the Privacy copy should say followers can see who a member follows and who follows them (a launch item, see [profile data visibility](../ux/09-profile-data-visibility.md#who-sees-the-connection-lists)). There is no route for another member's visitors. Lists omit inactive accounts and anyone blocked with the owner or the viewer, or in the other age band (`interaction_barred`), and are ordered newest connection first. Each row is `{user, since, following}` where `following` (`none`, `pending`, `active`) is the **caller's** own follow state on that person, so a followers list can offer Follow back without a second request. Pending follow requests are `GET /v1/me/follow-requests` (owner only); approving is `POST /v1/users/{id}/follow-requests/accept`, declining `DELETE /v1/me/follow-requests/{id}`.

The app's tappable profile stats use these lists: Following and Followers (see [profile experience](../ux/10-profile-experience.md#tappable-stats)).

### Visitors

`GET /v1/me/visitors` is the owner's own visitor list; there is no route for anyone else's (`/v1/users/{id}/visitors` is 404). Each row is `{user: {userId, username, displayName, avatarUrl}, firstVisitedAt, following}`, newest first visit first, paged with the usual signed cursor (bound to the caller and this list). A visit is recorded once per pair, the first time a member opens a profile (a locked card counts; one's own profile does not); `firstVisitedAt` never moves afterwards.

- Left out: inactive accounts, anyone blocked with the owner in either direction, and anyone in the other age band (`interaction_barred`): minors and adults never see each other. Lifting a block brings the visit back, nothing is deleted.
- The list returns at most the owner's `VisitorListLimit` most recent visitors across all its pages (`domain.Entitlements`, 200 on Free; see [plans and entitlements](../architecture/11-plans-and-entitlements.md)). The cap is applied after the exclusions above.
- Rate limit: a burst of 30 reads, then two a second (429 `RATE_LIMITED`, `Retry-After` 1).
- The `visitors` count in `socialStats` keeps counting every member who ever opened the profile, including the excluded ones (blocked, in another age band, suspended) and members the limit cuts off, so the list can be shorter than the number. Deleting an account removes its visit rows but not the all-time count.
- Visitors are **not notified** and cannot opt out. No other response names a visitor.
- **Disclosure:** the draft Terms of Service and Privacy Policy (`docs/legal/`) say that profile views are visible to the profile owner and that followers of an adult member can open their followers and following lists. They are drafts awaiting legal review. The app also says "People can see that you visited their profile." on the Visitors screen.

## Activity

`GET /v1/notifications` returns the caller's own rows, newest first, with `unreadCount`; `unreadOnly=true` filters. Events: `follow.started`, `follow.requested`, `follow.accepted`, `friend.requested`, `friend.accepted`, mapped to the contract types `follow` and `friend_request`. Text is rendered by the API, not stored, as a full sentence naming the first actor ("Niko sent you a friend request"); clients show it as-is. Repeating an action refreshes one row as unread instead of adding another. Rows from actors who are inactive or blocked with the recipient are hidden. `POST /v1/notifications/{id}/read`, `POST /v1/notifications/read-all` and `GET /v1/notifications/unread-count` complete it. Likes, comments and messages will add events when those modules exist.

## Pagination

All lists take `limit` (1–50, default 20) and an opaque `cursor`. Cursors are HMAC-signed, bound to the account and the specific list, and expire after 15 minutes.

## Blocking

Blocking ends follows in both directions, friendships, pending requests and the activity between the pair, in the same transaction as the block. Unblocking restores visibility but not relationships. An account can unblock someone who has since been deactivated.

## Verification

`connections_followers_test.go` covers who may open the lists after 0026: the owner, an active follower, a stranger, a friend, a pending request (not enough), an unfollow, a follow the other way, a block either way, the other age band, a minor owner (followers refused, friends allowed), narrowing the field, a closed profile, the friends list staying friends-only, followers watching `followers` and `public` stories but not `friends` ones, and migration 0026 on a scratch schema (adults moved, minors and other choices untouched, idempotent). `profile_lists_test.go` covers the visitor list (owner only, newest first, blocked either way, age-barred, inactive, pagination and cursor binding, the entitlement cap from a test tier, rate limit), the follow state on connection rows and `canSeeConnections`. PostgreSQL integration tests (`social_test.go`) cover every policy value, owner-only approvals, sender/recipient-only request actions, cooldown, crossing requests, friends-of-friends, locked cards for each audience, list privacy and block/inactive filtering, block severing and non-restoration, notification paging with cursor binding, read ownership, read-all, refresh-instead-of-duplicate, hidden actors, concurrent crossing requests and parallel follows, and per-account write limits. They run with the race detector.

## App wiring

The Activity tab (`lib/core/activity_state.dart`, `NotificationsScreen`) loads pages through `GET /v1/notifications`, marks rows read on open or via "Mark all as read", and answers open requests inline with Accept/Decline. Updates are optimistic and roll back if the server refuses. The bell and dock show the unread count, refreshed every 30 seconds and on return to the foreground until server push replaces polling. The person screen (`RelationshipBar`, `LockedProfile`) shows Follow / Follow back / Follow requested / Following and Add friend / Requested / Accept·Decline / Friends from the server's `relationship`, and shows only identity plus those controls when `locked` is true.
