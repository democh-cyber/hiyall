# Group chat (Wave 8)

Server contract for end-to-end encrypted group chats of 3 to 10 people, and the payload rules the apps apply. The relay still stores only ciphertext: every message is sealed once per recipient device with the existing one-to-one Olm sessions (the sender's phone does the fan-out), so the server never sees text, photos, voice, video, reactions or the name of a quoted message. It does see, as it already does for one-to-one chats, who sent something, when, how large it was and to which devices. For groups it also sees **membership and roles** and the **group name**, because it has to enforce limits, age bands and blocks. The design, the user experience and the security review items are in [the mobile group chat note](../mobile/19-group-chat.md). Read [encrypted chat implementation](../security/13-encrypted-chat-implementation.md) first.

Code: migration `0052_group_chat.sql`, `services/api/internal/store/groups.go`, `internal/httpapi/groups.go`, `internal/domain/groups.go`, `internal/domain/entitlements.go` (the group limits). Also `internal/store/chatmedia.go` (blobs in groups), `internal/push/push.go` (the invite push), `cmd/api/main.go` (the two hourly jobs), `apps/admin` (the roster on a report). Tests: `internal/httpapi/groups_test.go` (the whole feature over HTTP against PostgreSQL), the group rows of `internal/httpapi/account_purge_test.go`, and `apps/admin/src/test/console.test.tsx`.

## Model

- A **group** is a row of `conversations` with `kind = 'group'` (and no `user_low_id`/`user_high_id`), plus `chat_groups` (name, owner), `chat_group_members` (membership and invites) and `chat_group_events` (server-recorded membership events). Its `conversationId` is its `groupId`: the existing conversation routes for messages, blobs, read pointers, mute, pin, hide and restore work on it unchanged, and group messages are ordinary `messages` with one `message_envelopes` row per recipient device.
- **Roles.** `owner` (the creator, until they leave or delete their account) and `member`. The owner renames the group, invites and removes people. Anyone can leave. The owner leaves by naming the member who takes over.
- **Size.** 3 to 10 people. A group is created with at least 2 invitees and at most 9. Pending invites count towards the 10.
- **Invites.** Every invited person sees the invite in their chat list and must accept or decline. An invite carries no message content: nothing is sent to an invited person until they accept, and they never receive anything from before they joined. An unanswered invite expires after 7 days. A group with fewer than 2 active members closes.
- **Who can be invited.** Only people the inviter already has a chat with (an active one-to-one conversation) or follows. Everyone in a group must be allowed to interact with everyone else: no block in either direction between any two of them, and, while age-band isolation is on, one age band (all under 18 or all adults). With `AGE_BAND_ISOLATION=off` the band rule is off with it, exactly as for every other feature. The invitee must also pass their own `messagesFrom` setting (the same check as starting a chat). A refusal on any of these is the same answer, `409 CANNOT_ADD_MEMBER`, naming the person but never the reason.
- **Blocks after the fact.** A block between two members does not remove either from the group. Each stops seeing the other inside it: the blocked pair's messages are not delivered to each other (the existing inbox rule), neither appears in the other's member list, and senders no longer encrypt for the barred pair's devices. Everyone else carries on.
- **No history for new members.** Messages exist on the relay only as per-device ciphertext sealed at send time for the devices that were members then, so a person who joins later cannot receive earlier messages from the server, and the apps do not copy history to them.

## Limits (all enforced here, never by the app)

| Limit | Free value | Source | Refusal |
|---|---|---|---|
| People in a group, counting pending invites | 10 | `Entitlements.GroupMembersMax` | `409 GROUP_FULL` |
| Groups one person is in or invited to | 30 | `Entitlements.GroupsPerMemberMax` | `409 GROUP_LIMIT` (when it is the invitee's limit: `409 CANNOT_ADD_MEMBER`, no reason given) |
| Groups created per UTC day | 5 | `Entitlements.GroupsCreatedPerDay` | `429 DAILY_LIMIT` |
| People invited per UTC day (create and add together) | 30 | `Entitlements.GroupInvitesPerDay` | `429 DAILY_LIMIT` |
| Invite lifetime | 7 days | constant `domain.GroupInviteTTL` | the invite disappears |
| Group name | 0 to 40 characters | constant | `422 VALIDATION` |
| Messages per sender per group per rolling 24 h | 2000 | `Entitlements.ChatMessagesPerConversationPerDay` | `429 CHAT_DAILY_LIMIT` |
| Envelopes in one group message | 100 | constant `domain.MaxGroupEnvelopes` | `422 VALIDATION` |
| Pinned chats (groups count with one-to-one chats) | 5 | `Entitlements.ChatPinsMax` | `409 PIN_LIMIT` |

Plans are not enforced, so every member has the Free numbers; the limits are read from the member's `Entitlements`, so a later tier is a new case in `EntitlementsFor`. The daily message quota counts every message a person sends in the group, membership messages and reactions included. The group routes take the per-account limiters (`graph` for changes, `lists` for lists), group messages take the ordinary send limiter, and group reactions take the reaction limiter per group, as in one-to-one chats. A group does not use the one-to-one "new chat" quota or its first-contact message cap.

## Routes

All routes need a signed-in member who has finished onboarding.

### `POST /v1/groups`

```json
{"name": "weekend crew", "memberIds": ["<user id>", "<user id>"]}
```

`name` is optional (0 to 40 characters, normalised and checked like other names; empty means "no name", apps show the member names). `memberIds`: 2 to 9 distinct ids, never the caller. `201` with the [Group](#group). The caller is the owner and the only active member; each invitee is `invited` until they accept.

Checks, in one transaction behind the caller's quota lock: the caller's group count, `GroupsCreatedPerDay`, `GroupInvitesPerDay`, then for every invitee the chat-or-follow rule, `messagesFrom`, the barred check (blocks, age band) against the caller **and against every other invitee**, and the invitee's own group count. Any person who fails is `409 CANNOT_ADD_MEMBER` with `error.details.userId` naming one of them; nothing is created. Invitees get an `inbox` realtime signal (no content) and the apps refresh their invites.

### `GET /v1/groups`

```json
{"items": [ <Group> ]}
```

The caller's groups that are not deleted from their list (active and closed ones), pinned first, then most recent activity first. At most 30 plus closed groups, so there is no paging. Members the caller is barred from are left out of `members`.

### `GET /v1/groups/hidden`

`{"items": [<Group with hiddenAt and restoreUntil>], "retentionDays": 30}`: the caller's deleted groups, hidden under 30 days ago. Restore with `POST /v1/conversations/{id}/restore`. Groups closed for the caller after 30 days are listed in `closedIds` of `GET /v1/conversations/hidden` (the same list as one-to-one chats), and the app wipes their local history.

### `GET /v1/groups/invites`

```json
{"items": [{"groupId": "…", "name": "…", "invitedBy": <UserSummary>, "invitedAt": "…", "expiresAt": "…",
            "memberCount": 3, "members": [<UserSummary>]}]}
```

The caller's pending, unexpired invites, newest first. `members` are the people who have already joined; no content. An invite the caller could not accept any more (the inviter was blocked since, the group closed) is left out.

### `GET /v1/groups/{groupId}`

The [Group](#group) with `events`. For an active member: everything. For an invited person: the name, the active members and `myState: "invited"`, no events. Anyone else: `404 NOT_FOUND`.

### `POST /v1/groups/{groupId}/members`

Owner only. `{"userIds": ["<user id>"]}`: invite 1 to 9 more people, with the same checks as creation, and the size limit (`409 GROUP_FULL`). `200` with the Group. Inviting someone already active or invited is skipped without error. Not the owner: `403 GROUP_NOT_OWNER`. Closed group: `403 CONVERSATION_CLOSED`.

### `POST /v1/groups/{groupId}/accept`

An invited person joins. Body: `{"control": <Control>}`, the encrypted `join` message for everyone already in the group ([Control messages](#control-messages)). `200` with the Group. In one transaction the server checks that the invite exists and has not expired, the group is open, the person is not barred from any active member and has room for another group, checks the control message's device set, stores it, and makes the person active. The person is then in every later send's device set. `404 NOT_FOUND` for no invite, an expired one or a group that closed; `409 DEVICES_CHANGED` when the device set does not match (fetch the group again and re-encrypt); `409 GROUP_LIMIT` when the person is in too many groups; `409 GROUP_FULL`.

### `POST /v1/groups/{groupId}/decline`

No body. `200 {"declined": true}`. Deletes the invite. If the group then has fewer than 2 active members and no pending invite, it closes. Nobody is told who declined or that anyone did.

### `PATCH /v1/groups/{groupId}`

Owner only. `{"name": "new name", "control": <Control>}` renames the group (`name` may be empty). `200` with the Group. The `rename` control message is part of the same request, so every member's app shows the notice and the server's name changes together.

### `POST /v1/groups/{groupId}/members/{userId}/remove`

Owner only. Body `{"control": <Control>}` for an active member (the `remove` message goes to everyone in the group **including the removed person**, so their app learns it and stops); no body for a pending invite, which is simply cancelled. Removing yourself is `422 VALIDATION` (use leave). `200` with the Group. The removed person's unread ciphertext for this group is deleted, except the removal notice. If fewer than 2 active members remain the group closes.

### `POST /v1/groups/{groupId}/leave`

`{"control": <Control>, "newOwnerId": "<user id>"}`. Anyone active can leave. The owner must name `newOwnerId` (an active member) when two or more other active members remain, otherwise ownership is not needed because the group closes. Without other active members, `control` is omitted. `200 {"left": true}`. The leaver's unread ciphertext for the group is deleted. If fewer than 2 active members remain, the group closes (pending invites are cancelled).

### Existing routes that now serve groups

| Route | For a group |
|---|---|
| `POST /v1/conversations/{groupId}/messages` | Stores one envelope per recipient device. The device set must be exactly the devices of every active member the sender is not barred from, except the sending device, plus the sender's other devices (`409 DEVICES_CHANGED` otherwise; `409 GROUP_WAITING` while the group has no other active member with a device). Up to 100 envelopes; the request body may be up to 3 MiB. `aux: "reaction"` works as in one-to-one chats. `aux: "group"` is refused here: control messages travel only with the routes above. Blobs are claimed in the same transaction. Backlog caps are those of one-to-one chats, per recipient device and per sender. The response and the `inbox` signal and push go to every active member. A message is not an event for a person who is barred from the sender. |
| `POST /v1/conversations/{groupId}/blobs`, `GET …/blobs/{blobId}/url`, `POST /v1/blobs/{blobId}/complete`, `DELETE /v1/blobs/{blobId}` | Same quotas, caps and 30 day retention as one-to-one chats. Any active member may upload and download; there is no "peer replied" gate, because everyone in a group agreed to be there. A member barred from the uploader cannot download that blob. |
| `POST /v1/conversations/{groupId}/read` | Moves the caller's own read pointer. No read receipts and no typing signals exist in groups. |
| `POST`/`DELETE /v1/conversations/{groupId}/mute` | Per member, as in one-to-one chats. |
| `PUT …/pin`, `POST …/hide`, `POST …/restore` | Per member, with the same 5-pin cap (groups and one-to-one chats together), the 30-day restore window and the close job. |
| `GET /v1/conversations/unread` | Counts groups too (not muted, not deleted from the list). |
| `GET /v1/users/{userId}/devices`, `POST …/devices/{deviceId}/claim` | Allowed, in addition to the `messagesFrom` rules, between people who share an active group (and for an invited person towards the active members), so that two members who are not otherwise connected can start the Olm sessions their group messages need. Blocks, age bands and the key-claim caps are unchanged. |
| `GET /v1/conversations/{groupId}` | `404 NOT_FOUND`: use `GET /v1/groups/{groupId}`. |
| `POST /v1/reports` | `targetType: "message"` with a group message: the subject is the sender. `targetType: "conversation"` with a group: the subject is the owner (refused for the owner). Evidence is the reporter's own decrypted copy, volunteered as in one-to-one chats. |

## Group

```json
{
  "groupId": "…", "conversationId": "…", "kind": "group",
  "name": "weekend crew", "ownerId": "…", "status": "active",
  "createdAt": "…", "lastMessageAt": null,
  "memberCount": 3,
  "members": [{"userId": "…", "username": "…", "displayName": "…", "avatarUrl": null, "role": "owner", "joinedAt": "…"}],
  "pending": [{"userId": "…", "username": "…", "displayName": "…", "avatarUrl": null, "invitedAt": "…", "expiresAt": "…"}],
  "myState": "active",
  "unreadCount": 0, "readAt": null, "mutedUntil": null, "pinnedAt": null, "hiddenAt": null, "restoreUntil": null,
  "limits": {"maxMembers": 10, "inviteExpiryDays": 7, "nameMax": 40, "maxGroups": 30},
  "events": [{"eventId": "…", "kind": "joined", "actorId": "…", "subjectId": "…", "messageId": "…", "name": null, "at": "…"}]
}
```

`status` is `active` or `closed`. `memberCount` is the number of active members the caller can see, the caller included. `pending` is listed to active members. `events` appears only on the single GET: the newest 50 server-recorded membership events, oldest first. `kind` is `created`, `joined`, `left`, `removed`, `renamed` (with `name`), `owner_changed`, `member_deleted` (an account was deleted: the only way members learn of it, since the person can no longer send anything) or `closed`. `messageId` links an event to the control message that carried it, so an app that already showed the notice from the message does not show it twice. Events are kept 90 days.

## Control messages

A membership change that has other members to tell is one request that carries both the change and the encrypted message announcing it, so the server's roster and every member's device set change together and nobody is ever addressed with a stale set.

```json
{"messageId": "<uuid>", "senderDeviceId": "<uuid>",
 "envelopes": [{"deviceId": "…", "type": 0, "ciphertext": "…"}]}
```

Same shape and size rules as a message body (envelope up to 4 KiB decoded for control messages, up to 100 envelopes). The server stores it as an auxiliary message (never unread, never pushed), validates the device set exactly as for a message, and for these operations the set is:

| Operation | Recipients |
|---|---|
| `accept` (join) | every device of every active member the person is not barred from, and the person's other devices |
| `leave` | every device of every other active member (not barred from the leaver), and the leaver's other devices |
| `remove` | as `leave`, plus every device of the removed person |
| `rename` | every device of every active member (not barred from the owner), and the owner's other devices |

The plaintext payloads are in [the mobile note](../mobile/19-group-chat.md#payloads). A control message is auxiliary at the relay (`messages.aux`), so it is never counted unread and never pushed; the app checks that the decrypted kind is `group` and drops any message whose relay flag and kind disagree.

## Push and realtime

- **Realtime.** Every roster change and every group message signals the affected accounts with the existing `inbox` event (`{conversationId}`), content-free; the apps refresh the group list, the invites and the inbox. There is no `typing` or `read` event for a group.
- **Push.** A group message pushes `New message` with `{kind: "chat", conversationId}` to every active member except the sender, after the dispatcher's usual checks (live socket, a muted group, a muted or restricted sender, blocks and age band, the member's own switch and the 30 second coalescing window per group). It never names the group, the sender or any text. Reactions and membership messages are quiet. An invite pushes `You have a new group invite` with `{kind: "group_invite"}` to the invited person (the chat category; the same checks; never the group name or the inviter).

## Errors

| Status | Code | Meaning |
|---|---|---|
| 409 | `CANNOT_ADD_MEMBER` | That person cannot be added. `details.userId` names them. No reason is ever given: a block, an age band, their privacy choice, their group limit and "you do not know them" look the same. |
| 409 | `GROUP_FULL` | The group has 10 people (pending invites count). |
| 409 | `GROUP_LIMIT` | The caller is in or invited to the most groups they may be. |
| 409 | `GROUP_WAITING` | A send found no other active member with a device. |
| 409 | `DEVICES_CHANGED` | The envelope set does not match. Fetch `GET /v1/groups/{id}`, fetch devices, encrypt again. |
| 403 | `GROUP_NOT_OWNER` | The route is for the owner. |
| 403 | `CONVERSATION_CLOSED` | The group is closed. |
| 404 | `NOT_FOUND` | Not a member, no such invite, an invite that expired. |
| 422 | `VALIDATION` | A bad name, id list, a missing `newOwnerId` or `control`, more than 100 envelopes. |
| 429 | `DAILY_LIMIT`, `RATE_LIMITED`, `CHAT_DAILY_LIMIT`, `RECIPIENT_BACKLOG` | The limits above. |

## Account deletion, export, retention

- **Deletion.** When a member's account is purged, their membership rows are deleted and a `member_deleted` event is recorded in each group they were in, so the others see "A member deleted their account" and stop encrypting for their devices (the apps drop an id that an event says is gone). If they owned a group, it passes to its longest-standing active member; if fewer than 2 active members remain, the group closes. Their invites to others are cancelled, and the metadata of messages they sent in groups and their blobs are purged under the existing rules (a message named in a report keeps its metadata row).
- **Export** (`GET /v1/me/export`, section `chat`): a `groups` list with the person's own groups: `groupId`, `name`, `role`, `status`, `joinedAt`, `memberCount`, and the counts of messages they sent and received, plus their pending invites. No content: there is none on the server.
- **Retention.** Message envelopes, blobs and message metadata follow the existing one-to-one rules. Pending invites are deleted by an hourly job after 7 days. Membership events are deleted after 90 days. A closed group's rows stay until every member has deleted the chat and its 30 days have passed, as for a closed one-to-one chat.
- **Staff.** A report on a group message or group (`reports.conversation_id`, set when the report is made) shows moderators the group's name, owner and member list (username, role, active or invited), read from `chat_groups` and `chat_group_members` alone: the console has no access to message rows. Never content.

## What the server does not know

The server cannot see message text or kind, reactions, who replied to whom, attachment keys or descriptors, or read state of anyone but the caller (it has none to share: there are no receipts in groups). It does know the group name, membership, roles, invite times, the sender, time and size of every message and which devices it was sealed for.
