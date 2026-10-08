# Follows, friends and activity

Implemented in migration `0006_social_graph_activity.sql`, `services/api/internal/store/social.go` and `services/api/internal/httpapi/social.go`. The contract is in [openapi-foundation.json](openapi-foundation.json) under the Graph and Activity tags.

## Relationships

| Action | Endpoint | Rules |
|---|---|---|
| Follow | `POST /v1/users/{id}/follow` | Target `followPolicy`: `everyone` → active, `approval` → pending (accepted friends skip approval), `nobody` → 403 `FOLLOW_NOT_ALLOWED`. Repeating returns the current state. |
| Unfollow / withdraw | `DELETE /v1/users/{id}/follow` | Idempotent. Withdrawing removes the owner's pending-request activity row. |
| Approve follower | `POST /v1/users/{id}/follow-requests/accept` | Owner only; `{id}` is the follower. |
| Decline follower | `DELETE /v1/me/follow-requests/{id}` | Owner only. |
| Remove follower | `DELETE /v1/me/followers/{id}` | Drops an active follower without blocking. |
| Friend request | `POST /v1/users/{id}/friend-requests` | Target `requestsFrom`: `everyone`, `followers` (sender actively follows the target), `friends` (friends of friends), `nobody`. Refused → 403 `REQUEST_NOT_ALLOWED`. If the target already asked, this accepts. Resending a pending request returns it. A sender whose request was declined waits 7 days (429 `REQUEST_COOLDOWN`). |
| Accept / decline | `POST /v1/friend-requests/{rid}/accept\|decline` | Recipient only; anyone else gets 404. |
| Cancel | `DELETE /v1/friend-requests/{rid}` | Sender only. Removes the recipient's activity row. |
| Unfriend | `DELETE /v1/users/{id}/friendship` | Idempotent. |

Every write locks both accounts in id order, so crossing or repeated actions cannot deadlock or duplicate rows. Inactive accounts and blocked pairs look identical to missing ones (404). Relationship writes are limited per account.

`GET /v1/users/{id}/profile` includes `relationship` (`following`, `followedBy`, `friendship`, `friendRequestId`, `canFollow`, `canFriendRequest`) and `locked`. Profile and field audiences admit `everyone`, `friends`, or `followers` (friends included).

## Lists

`GET /v1/me/{friends|followers|following|follow-requests}`, `GET /v1/me/friend-requests?direction=incoming|outgoing`, and `GET /v1/users/{id}/{friends|followers|following}`. Another person's lists need access to both their profile audience and their `connections` field audience; otherwise 403 `CONNECTIONS_PRIVATE`. Lists omit inactive accounts and anyone blocked with the owner or the viewer.

## Activity

`GET /v1/notifications` returns the caller's own rows, newest first, with `unreadCount`; `unreadOnly=true` filters. Events: `follow.started`, `follow.requested`, `follow.accepted`, `friend.requested`, `friend.accepted`, mapped to the contract types `follow` and `friend_request`. Text is rendered by the API, not stored, as a full sentence naming the first actor ("Niko sent you a friend request"); clients show it as-is. Repeating an action refreshes one row as unread instead of adding another. Rows from actors who are inactive or blocked with the recipient are hidden. `POST /v1/notifications/{id}/read`, `POST /v1/notifications/read-all` and `GET /v1/notifications/unread-count` complete it. Likes, comments and messages will add events when those modules exist.

## Pagination

All lists take `limit` (1–50, default 20) and an opaque `cursor`. Cursors are HMAC-signed, bound to the account and the specific list, and expire after 15 minutes.

## Blocking

Blocking ends follows in both directions, friendships, pending requests and the activity between the pair, in the same transaction as the block. Unblocking restores visibility but not relationships. An account can unblock someone who has since been deactivated.

## Verification

PostgreSQL integration tests (`social_test.go`) cover every policy value, owner-only approvals, sender/recipient-only request actions, cooldown, crossing requests, friends-of-friends, locked cards for each audience, list privacy and block/inactive filtering, block severing and non-restoration, notification paging with cursor binding, read ownership, read-all, refresh-instead-of-duplicate, hidden actors, concurrent crossing requests and parallel follows, and per-account write limits. They run with the race detector.

## App wiring

The Activity tab (`lib/core/activity_state.dart`, `NotificationsScreen`) loads pages through `GET /v1/notifications`, marks rows read on open or via "Mark all as read", and answers open requests inline with Accept/Decline. Updates are optimistic and roll back if the server refuses. The bell and dock show the unread count, refreshed every 30 seconds and on return to the foreground until server push replaces polling. The person screen (`RelationshipBar`, `LockedProfile`) shows Follow / Follow back / Follow requested / Following and Add friend / Requested / Accept·Decline / Friends from the server's `relationship`, and shows only identity plus those controls when `locked` is true.
