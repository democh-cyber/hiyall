# Mute, restrict, chat mute and reports

Implemented in migration `0009_safety_controls.sql`, `services/api/internal/store/safety.go`, `services/api/internal/httpapi/safety.go` and the app's `features/safety.dart`. None of these controls is ever visible to the person it is about.

## Controls on a person

| Action | Endpoint | Effect |
|---|---|---|
| Mute | `POST /v1/users/{id}/mute` with optional `{"until": RFC3339}` | Their posts and stories leave the caller's Pulse. Their new activity still lists but arrives already read, so it never raises the badge, and nothing about them is pushed (activity or messages). Their messages still count as unread. Without `until` the mute lasts until removed; an `until` in the past is 422. |
| Unmute | `DELETE /v1/users/{id}/mute` | Idempotent. |
| Restrict | `POST /v1/users/{id}/restrict` | Their activity and pushes are silenced as with mute, their chats leave the caller's unread badge (the chat row still counts), read receipts and typing are off in both directions, and their comments on the caller's posts are visible only to them. Their posts still show. No expiry. |
| Unrestrict | `DELETE /v1/users/{id}/restrict` | Idempotent. |

Self-targets are 422, and unknown or inactive accounts are 404. Writes share the per-account graph rate limit. `relationship` on `GET /v1/users/{id}/profile` gains `muted` and `restricted`, which describe only the viewer's own controls. The target's controls on the viewer are never returned.

## Chat mute

`POST /v1/conversations/{id}/mute` with optional `{"until"}`, and `DELETE` to unmute. This applies to the caller's side only. A muted chat sends no push and leaves `GET /v1/conversations/unread`, but its own `unreadCount` keeps counting. Conversations return `mutedUntil` while muted (`9999-12-31` means until unmuted). The peer never sees it.

## Lists

`GET /v1/me/blocked`, `/v1/me/muted` and `/v1/me/restricted` page `{user, since, until?}`, newest first. They omit expired mutes and inactive accounts. The app shows these under Privacy → Blocked, muted and restricted, with undo in place.

## Reports

`POST /v1/reports`:

```json
{"targetType": "user|conversation|message", "targetId": "…", "reasonCode": "harassment",
 "description": "optional, ≤1000 chars", "evidence": [{"messageId": "…", "text": "…", "sentAt": "…"}],
 "disclosureConsent": true, "block": false}
```

- Reasons: `spam`, `harassment`, `scam`, `hate`, `threats`, `sexual_content`, `violence`, `self_harm`, `underage`, `impersonation`, `copyright`, `other`. `hate`, `threats`, `sexual_content`, `violence`, `self_harm` and `underage` are queued as high severity.
- Conversation and message reports are only accepted from members. Anyone else gets 404.
- **Evidence is opt-in and end-to-end safe.** The server cannot decrypt chats. The only text it receives is what the reporter selected on their device, at most 10 messages. Sending any evidence requires `disclosureConsent: true`, and the database also enforces this. Each `messageId` must belong to the reported chat. The sender and time are taken from the relay's records, not from the client. User reports cannot carry evidence.
- A repeat report of the same target while the first is open returns that report with `200` and `duplicate: true`. A new report returns `201`.
- `block: true` also blocks the subject in the same request.
- Rate limit: a burst of 10, then 1 per minute per account (429).

`GET /v1/me/reports` lists the caller's own reports with `status` (`open`, `actioned`, `dismissed`). The reported person cannot see that a report exists.

## Operator tool

Until the separate admin console exists, trust and safety use `go run ./cmd/moderate` with `DATABASE_URL`:

```
moderate queue [-limit 20]
moderate resolve -report ID -action dismiss|warn|suspend -operator NAME [-note TEXT]
moderate restore -user ID -operator NAME [-note TEXT]
```

- The queue lists high severity first, then oldest, with the subject's earlier report count and any shared evidence.
- `suspend` sets the account to `suspended` and revokes every session in one transaction. Authentication already requires `active`, so the account is cut off immediately.
- Every resolution and restore is written to `moderation_actions` as the audit trail.
