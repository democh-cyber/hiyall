# Mute, restrict, chat mute and reports

Implemented in migration `0009_safety_controls.sql`, `services/api/internal/store/safety.go`, `services/api/internal/httpapi/safety.go` and the app's `features/safety.dart`. None of these controls is ever visible to the person it is about.

## Controls on a person

| Action | Endpoint | Effect |
|---|---|---|
| Mute | `POST /v1/users/{id}/mute` with optional `{"until": RFC3339}` | Their posts and stories leave the caller's Pulse. Their new activity still lists but arrives already read, so it never raises the badge, and nothing about them is pushed (activity or messages). Their messages still count as unread. Without `until` the mute lasts until removed; an `until` in the past is 422. |
| Unmute | `DELETE /v1/users/{id}/mute` | Idempotent. |
| Restrict | `POST /v1/users/{id}/restrict` | Their activity and pushes are silenced as with mute, their chats leave the caller's unread badge (the chat row still counts), read receipts and typing are off in both directions, and their comments on the caller's posts are visible only to them. Their posts still show. No expiry. |
| Unrestrict | `DELETE /v1/users/{id}/restrict` | Idempotent. |

Self-targets are 422, and unknown or inactive accounts are 404, and so is muting or restricting a member whose profile the caller could not open: one in the other age band or one who has not finished onboarding (exactly as their profile answers). Removing a control always works. Writes share the per-account graph rate limit. `relationship` on `GET /v1/users/{id}/profile` gains `muted` and `restricted`, which describe only the viewer's own controls. The target's controls on the viewer are never returned.

## Chat mute

`POST /v1/conversations/{id}/mute` with optional `{"until"}`, and `DELETE` to unmute. This applies to the caller's side only. A muted chat sends no push and leaves `GET /v1/conversations/unread`, but its own `unreadCount` keeps counting. Conversations return `mutedUntil` while muted (`9999-12-31` means until unmuted). The peer never sees it.

## Lists

`GET /v1/me/blocked`, `/v1/me/muted` and `/v1/me/restricted` page `{user, since, until?}`, newest first. They omit expired mutes and inactive accounts. The muted and restricted lists also omit members the caller may not know: in the other age band (for instance after a birthday moved one of them) or not onboarded; the control stays stored. The blocked list shows every block, so each can be undone. The app shows these under Privacy → Blocked, muted and restricted, with undo in place.

## Reports

`POST /v1/reports`:

```json
{"targetType": "user|conversation|message", "targetId": "…", "reasonCode": "harassment",
 "description": "optional, ≤1000 chars", "evidence": [{"messageId": "…", "text": "…", "sentAt": "…"}],
 "disclosureConsent": true, "block": false}
```

- Reasons: `spam`, `harassment`, `scam`, `hate`, `threats`, `sexual_content`, `violence`, `self_harm`, `underage`, `impersonation`, `copyright`, `other`. `hate`, `threats`, `sexual_content`, `violence`, `self_harm` and `underage` are queued as high severity.
- Conversation and message reports are only accepted from members. Anyone else gets 404.
- **Messaging is open**, so blocking and reporting are the controls a member has against unwanted contact: anyone who is not blocked and is in the same age band can start a conversation, with no friendship or follow, and a block or a report works exactly as before. Opening conversations with people you have never exchanged a message with has its own limiter (burst 10, then one a minute, `429 RATE_LIMITED`, `Retry-After: 60`), and each member may start at most 40 conversations per rolling 24 hours (`429 QUOTA`, `Retry-After` set; see [Nearby and open access](19-nearby-and-open-access.md)). See the safety note in [Nearby and open access](19-nearby-and-open-access.md#safety-note-for-the-owner).
- **Evidence is opt-in and end-to-end safe.** The server cannot decrypt chats. The only text it receives is what the reporter selected on their device, at most 10 messages. Sending any evidence requires `disclosureConsent: true`, and the database also enforces this. Each `messageId` must belong to the reported chat. The sender and time are taken from the relay's records, not from the client. User reports cannot carry evidence.
- **Shared images.** An evidence entry may carry `attachments: [{blobIds, descriptor}]`, the encrypted images of that message the reporter chose to share (at most 4 per message; the decrypted descriptor, key included, is shared under the same `disclosureConsent`). In the report transaction every blob must belong to that evidence message in the reported chat (otherwise 422 and nothing is stored) and is held against retention, uploader delete, block and account deletion. See [encrypted chat attachments](21-chat-attachments.md#reporting-evidence). Text-only evidence is unchanged. Reactions are not messages the reporter can choose: an evidence entry for a reaction message is dropped by the server (not an error), and the app never lists one ([reactions](24-chat-reactions-and-replies.md)).
- A repeat report of the same target while the first is open returns that report with `200` and `duplicate: true`. A new report returns `201`.
- `block: true` also blocks the subject in the same request.
- A report against a member in the other age band or one who has not finished onboarding is accepted (and queued for operators with full details), but the answer and `GET /v1/me/reports` name nobody: `subject.userId` is there, `subject.username` and `subject.displayName` are empty strings. A block does not hide the name.
- Rate limit: a burst of 10, then 1 per minute per account (429).

`GET /v1/me/reports` lists the caller's own reports with `status` (`open`, `actioned`, `dismissed`). The reported person cannot see that a report exists.

## Operator tools

Moderation is done in the **admin console** (`services/api/cmd/admin`, UI in `apps/admin`): a separate process and audience with its own staff accounts (password plus mandatory authenticator code), roles (`viewer`, `moderator`, `admin`), a mandatory written reason on every action and an append-only audit log of every case read and action. Reports involving a member under 18 are flagged and sorted first. It is not part of the public API or OpenAPI. Design, threat model, endpoints, what staff can and cannot see, deployment and incident steps: [Admin console](../security/15-admin-console.md). Start it for development with `scripts/dev-admin.sh`.

The command line `go run ./cmd/moderate` (with `DATABASE_URL`) stays as the break-glass path with direct database access. It calls the same store methods as the console (`ResolveReport`, `RestoreUser`), so a report resolves identically from either:

```
moderate queue [-limit 20]
moderate resolve -report ID -action dismiss|warn|suspend -operator NAME [-note TEXT]
moderate restore -user ID -operator NAME [-note TEXT]
```

- The queue lists high severity first, then oldest, with the subject's earlier report count and any shared evidence. Held encrypted images are listed as blob id, role, size and SHA-256 only: the tool never fetches or decrypts them.
- `suspend` sets the account to `suspended` and revokes every session in one transaction. Authentication already requires `active`, so the account is cut off immediately. The same transaction notifies the realtime channel, so every API node closes the account's live sockets (see [sessions](15-sessions-and-settings.md#realtime-connections-end-with-their-session)).
- Every resolution and restore is written to `moderation_actions` (actor, report, action, note). The console additionally writes `operator_audit`; the command line does not require a reason, the console always does. A report that is already resolved answers `REPORT_CLOSED` (409).
