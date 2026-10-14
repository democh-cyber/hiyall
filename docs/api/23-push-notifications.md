# Push notifications

Push wakes a phone that is not connected. It never carries what someone said:
chats are end-to-end encrypted, so the server cannot read them and a payload
could not contain them anyway. The app opens, fetches and decrypts as usual.

FCM (Firebase Cloud Messaging) delivers to Android and, through the APNs key
uploaded in the Firebase console, to iOS. Provider `fcm` therefore covers both.
`apns` is still accepted by `PUT /v1/devices/{id}/push` (so the contract does
not change if a raw APNs sender is ever added) but nothing is delivered through
it today.

## Owner setup

Nothing here is needed for development: without a service account the server
only logs what it would have pushed.

1. **Service account.** Firebase console, project settings, Service accounts,
   "Generate new private key". Save the JSON as
   `config/fcm-service-account.local.json` (git-ignored; see
   `config/fcm-service-account.example.json` for the shape). The account needs
   the "Firebase Cloud Messaging API Admin" role; the default Firebase Admin SDK
   account has it. Also make sure the "Firebase Cloud Messaging API (V1)" API is
   enabled for the project.
2. **APNs key (iOS).** Apple Developer account, Keys, create a key with Apple
   Push Notifications service enabled, download the `.p8`. Firebase console,
   project settings, Cloud Messaging, "APNs authentication key", upload it with
   the key id and team id.
3. **Server configuration.** Set `FCM_SERVICE_ACCOUNT_FILE` to the file's path
   (`scripts/dev-api.sh` does this by itself when
   `config/fcm-service-account.local.json` exists). `FCM_PROJECT_ID` defaults to
   `FIREBASE_PROJECT_ID`, then to the `project_id` in the file; set it only if
   they differ. At start the log says either `push notifications: FCM` or why
   pushes are only logged. The key is never printed or logged.
4. **Xcode (iOS), once.** There is no Xcode on the development Mac, so this was
   not built or verified. `Runner/Runner.entitlements` carries `aps-environment`
   and `Info.plist` has `UIBackgroundModes: remote-notification`. Open
   `ios/Runner.xcworkspace`, select the Runner target, Signing & Capabilities,
   and check that **Push Notifications** and **Background Modes** (Remote
   notifications) are listed and that the entitlements file is
   `Runner/Runner.entitlements`; if Xcode shows them missing, add the two
   capabilities (it edits the same files). `aps-environment` is `development`
   in the file; archive and App Store builds are re-signed with `production` by
   the distribution profile. The App ID needs the Push Notifications capability in
   the Apple Developer portal too.
5. **Android.** Nothing to do. The manifest asks for `POST_NOTIFICATIONS`
   (Android 13+) and names the default channel `hiyall_default`, which
   `MainActivity` creates. The notification uses the launcher icon; a dedicated
   monochrome small icon can be added later.
6. **Test on a real device.** Build with the Firebase keys
   (`--dart-define-from-file=../../config/firebase.local.json`), sign in, send a
   message from another account while this one is in the background.

## What is pushed

A small allowlist in `internal/push/push.go`; every other event is dropped before
it is queued. Title is always `Hiyall`.

| kind | when | body | data |
| --- | --- | --- | --- |
| `chat` | a message arrived | `New message` (never named) | `{kind: "chat", conversationId}` |
| `device` | a chat device was added to your account for the first time | `New device added to your account` (never named) | `{kind: "device"}` |
| `friend_request` | someone sent a friend request | `<name> sent you a friend request` | `{kind: "social", event}` |
| `friend_accepted` | your request was accepted (also a crossing request) | `<name> accepted your friend request` | same |
| `follow` | someone followed you | `<name> started following you` | same |
| `follow_request` | someone asked to follow you (approval accounts) | `<name> asked to follow you` | same |
| `follow_accepted` | your follow request was approved | `<name> accepted your follow request` | same |
| `space_invite` | you were invited to a space by username | `<name> invited you to a space` | same |

Not pushed: reactions, comments, story activity, space moderation. They still
appear in Activity and reach open apps over the socket.

The app opens the conversation for `kind: chat`, Activity for `kind: social` and the Chat devices screen (`/profile/devices`) for `kind: device`.

`device` is a **security notice**: it has its own category, `security`, which the `chat` and `social` switches do not cover, so it cannot be turned off. It goes only to the account's other devices (the one that was just added is excluded by device id, and the actor is the recipient themselves), at most one a minute; it carries no device name. The other rules below (account state, a live socket on this node, daily cap) still apply. The realtime `device` event and the in-app banner cover devices that are connected.

## Privacy rules (server side)

* The payload holds only the strings above plus the conversation id. No message
  text, ciphertext, photo, username or user id.
* The actor's display name appears only in social pushes, only when the push is
  allowed at all, which requires that the recipient can already see the actor
  (neither blocked the other, same age band while isolation is on, both active
  and onboarded). Their profile card and Activity show the same name. A name is
  stripped of control characters and cut at 40 characters. Otherwise the body is
  the generic line.
* A push is skipped when: the recipient has a live socket on this node; the chat
  is muted; the recipient muted or restricted the sender, or the sender
  restricted the recipient; either blocked the other; the two are in different
  age bands (isolation on); the conversation is closed; either account is not
  `active` (suspended, banned, deactivated, pending deletion, deleting, deleted)
  or has not finished onboarding; the member switched the category off
  (`GET`/`PATCH /v1/me/notifications`: `chat`, `social`; the social switch
  covers every kind except `chat`).
* Pushes go to the recipient's active devices only, never to the sender's other
  devices, and never to a revoked device. (The `device` kind is the exception that
  proves the rule: its actor is the recipient, and the new device is skipped.)
* Coalescing: at most one `chat` push per (recipient, conversation) per 30
  seconds; social pushes at most one per (recipient, kind, actor) per 10
  minutes. The device also collapses them (`collapse_key`, `apns-collapse-id`:
  `chat-<conversationId>` and `social`). The app syncs on open, so a dropped
  push only delays nothing but the nudge.
* A daily cap of 200 pushes per recipient (rolling 24 hours).
* Quiet hours are not implemented.

The database rules run on a worker after the request has returned, so they never
slow a request. They fail closed: if the check errors, nothing is sent.

### Per-node limits

The "live socket" check, coalescing and the daily cap live in memory on each API
node. With several nodes a member connected to another node can still get one
redundant push, the cap is per node, and all counters reset on restart. The
worst case is a few extra nudges, never a lost message.

## Failure handling

* Pushes are queued (4096 entries) and sent by 4 workers. A full queue drops the
  push with a log line (`push queue full; push dropped`) and a counter
  (`Dispatcher.Stats`). Shutdown cancels the workers and any wait between retries.
* `UNREGISTERED` and `INVALID_ARGUMENT` naming the token
  clear that device's token (only if the device still holds that exact token, so
  a token the app has just refreshed is kept). A bare 404 is not treated as a
  dead token, because a wrong project id also answers 404.
* `SENDER_ID_MISMATCH` means the server's service account and the app belong to
  different Firebase projects: a **configuration error**, not a dead token. Every
  token would be refused the same way, so none is cleared; the failure is counted
  in `hiyall_push_config_errors_total` (alert on any) and logged as an error.
* In production a set but unreadable or invalid `FCM_SERVICE_ACCOUNT_FILE` stops
  the API from starting (in development it falls back to logging pushes).
* 429, 5xx, 401 (the cached access token is dropped) and network failures are
  retried up to 4 attempts with exponential backoff (0.5 s, 1 s, 2 s) plus jitter,
  honouring `Retry-After`. Requests time out after 10 seconds.
* Anything else (permission denied, invalid payload) is logged once without the
  token or the provider's message, and not retried.
* The OAuth access token is obtained with a signed service-account JWT
  (RS256) and cached until 5 minutes before it expires.

## Push tokens

`PUT /v1/devices/{id}/push {provider, token}` attaches a token to one of the
caller's devices. A token the same account holds on another of its devices (a
reinstall) is moved. A token held by **another account** is never taken over: the
answer is `409 PUSH_TOKEN_IN_USE` (the server logs the refusal without the token
or the other account; the body names nobody). `DELETE` clears it.

## Preferences API

`GET /v1/me/notifications` returns `{chat, social}` (both true until changed).
`PATCH /v1/me/notifications` takes one or both keys as booleans; a key left out
keeps its value. Stored in `notification_prefs` (migration 0029).

## App

`firebase_messaging` is used only on Android and iOS builds that carry Firebase
keys; web, desktop and tests use a no-op service. The permission dialog is
never shown at launch: the app shows a short explainer sheet after the member's
first sent message or first follow, or when they switch push on in Settings,
Notifications. "Not now" is remembered and the sheet does not return for 14
days; a system-level refusal ends the asking. The token is registered against
the chat engine's device id, re-registered whenever FCM refreshes it, and
removed on the server (and on the device) when the member switches push off or
signs out. A message that arrives while the app is open shows no banner; live
sync updates the screen. The background handler is a no-op top-level function
that never touches chat keys.
