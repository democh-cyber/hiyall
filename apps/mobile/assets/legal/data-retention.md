> **DRAFT for legal review. Not legal advice. Placeholders in [BRACKETS] must be filled by the operator.**

# Data Retention

Version: 2026-10-01

Effective date: [EFFECTIVE DATE]

This document says how long Hiyall keeps each kind of information. A cleanup routine runs every hour on our servers and removes what has expired, in small batches. Items in square brackets are targets or decisions that the operator or counsel must confirm before this is published, because the period is not yet fixed.

## Your account

- **Download my data:** Settings > Account > Download my data.
- **Delete my account:** Settings > Account > Delete account. [CONFIRM: grace period] Your account is hidden and signed out straight away. If you change your mind, you have 30 days to cancel. After that your data is erased on a schedule, apart from the exceptions below.

## What we keep and for how long

| What | How long we keep it | Notes |
|---|---|---|
| Account and profile (name, username, bio, details, settings) | Until you delete your account | After deletion: 30-day grace period, then erased [CONFIRM: grace period] |
| Date of birth | Until your account is erased | Stored privately to set your age group. Never shown to others. Cannot be changed. |
| Age check refusal (a sign-in that entered a birth date under 13) | 7 days of cooldown from the last refusal, and the record is deleted after 30 days | Holds the sign-in identifier, a count and a time. No birth date. Deleting an account does not clear it, so the cooldown cannot be avoided. |
| Sign-in details (email, password, Google or Apple link) | Until your account is deleted | Held by Google's Firebase Authentication, not on our servers. The link between your account and the sign-in is kept for 1 day after erasure so an old sign-in token cannot create a new account. |
| Apple sign-in revocation token | Until Apple has revoked the link, normally never stored | Only kept, sealed (encrypted), if Apple could not be reached when you deleted your account. Retried until it works, then deleted. |
| Chat messages on our servers | Removed once your phone confirms it received them. Anything delivered but not yet cleared goes after 7 days. Anything never delivered goes after 30 days. | The server only holds scrambled, unreadable text. Cleanup runs hourly. |
| Chat message records (who sent a message and when, never what it said) | 180 days | Removed once the message has reached the other person's phone and nothing needs it, such as a report. The latest real message each person sent in a chat is kept so that chat rules keep working. |
| Chat messages on your phone | Until you delete them, sign out or delete your account. If you delete the app without signing out, Android removes them with the app; on iPhone they are erased the next time you open Hiyall after reinstalling | The app keeps the most recent 500 messages per chat. The other person keeps their own copy. |
| Chat photos (encrypted) | 30 days after the message is sent. 1 hour if never sent in a message. If you delete the photo it is removed at once. If a chat is blocked, its photos are removed within the hour. | Kept longer only if held as report evidence (see below). |
| Photos for profiles, posts and stories | Until you delete the post, story or photo, or replace your profile photo | Removed by the hourly cleanup. Uploads that are never finished are removed after 1 hour, and photos never attached to anything after 1 day. The small record that a photo existed (no image) is deleted 30 days after the photo is removed. |
| Photos flagged by the upload check, held as evidence | [COUNSEL: evidence retention period, default currently 365 days] from detection. Longer if the case is confirmed or reported, or under a legal hold | Kept in a separate restricted storage area. Not removed by deleting the photo, the post or your account. Released only by an administrator, and the files are removed after the period. |
| Safety case record for a flagged photo | [COUNSEL: how long the case record is kept after the files are removed] | Account id, what the photo was for, which check found it and what it found, the photo's fingerprint (SHA-256) and size, times, the staff decision, and any report reference. Never the photo itself. |
| Operator audit log (which staff member viewed what, when and why) | At least 1 year [COUNSEL: confirm the period] | Written before anything sensitive is shown. Removed only in batches by an administrator, and the removal is itself logged. |
| Posts, comments and reactions | Until you delete them or your account | When you delete a post, comment or space message, its text is blanked within a day and the record is deleted 30 days later, together with a post's comments, reactions and saves. Text under an open report is kept until the report is closed. |
| Stories | Visible for the time you chose (6, 12 or 24 hours, 24 by default). The story and its viewer list are deleted 1 day after it expires. | |
| Shared location (for Nearby) | Nothing is stored unless you turn Nearby on. Counts as shared for 24 hours after the last update. Deleted after 7 days if not refreshed. Deleted straight away when you turn Nearby off or sign out in the app. | Stored rounded (about 1 km, about 11 km for under-18s), never exact. If your sign-in ends without you signing out in the app, for example it is ended from another device or by us, the position stops being shown within 24 hours and is deleted within 7 days. [OPERATOR: update when it is deleted at once.] |
| Online and last seen | Worked out from your sign-in activity, not stored separately | Last seen is rounded down to 5 minutes. |
| Sign-in sessions | A session record is removed once it is more than 30 days past its expiry and has not been used for 400 days. | A record that a session was signed out is kept so that it cannot be revived. It holds no profile content. |
| Chat device keys | Until you remove the device, sign out, delete your account, or the device has not been used for 90 days | Public keys only. |
| Push token | Until it is replaced, the device is removed, or you delete your account | |
| One-time key claim records | 1 day | Used to stop abuse of chat setup. |
| Idempotency keys (a random key sent when you post, so a retry does not post twice) | 24 hours | Hold the key, what it was for and a fingerprint of the request, no content. |
| Daily action counters (follows, requests, searches, profile views and similar) | 3 days | A number per kind of action per day, used for daily limits. |
| Rate-limit counters | Removed within about an hour after the counter has reset | Keyed by your account or network address. Hold a count and times, no content. |
| Profile visits (who viewed whose profile) | While both accounts exist | The visitor list shows the most recent 200 visitors on the free plan. The total count is not reduced when a visitor deletes their account. |
| Follows, friends, blocks, mutes and restrictions | Until you remove them or delete your account | |
| Notifications inside the app | 90 days | |
| Reports and the actions taken | While a case is open, then 180 days after it closes. Longer where encrypted evidence is held or a legal hold applies | Records of what staff decided are kept so that appeals can be handled. |
| Chat photos held as report evidence | Until the case is closed and the hold released | Released by staff. Not removed by the normal 30-day cleanup, by deleting the photo, or by blocking. |
| Record that an account was erased (ledger) | Kept without an end date | The account id and the time it was erased, nothing else. Used so a restored backup does not bring a deleted account back, and so the id is never reused. |
| Account shell (the account record after erasure) | Kept without an end date | No personal data. Kept because retained reports and evidence point to it. |
| Crash and error reports (Sentry) | [OPERATOR: the retention set in the Sentry project, for example 90 days] | Scrubbed: no message text, tokens, emails or ids. |
| Technical logs on our servers | [CONFIRM: operator to set a period] | Request numbers, results and timings. No message contents or dates of birth. |
| Backups of our database | [CONFIRM: backup period] A rolling period of about 35 days | Backups cannot be edited, so data deleted from the live service may remain in a backup until it expires, including evidence that has since been removed. If a backup is restored, deletions are applied again using the ledger above before the service is used. |
| Data export files | [CONFIRM: how long an export stays available] Available to download for a limited time, then deleted | The copy the app saves on your phone is removed after you share it, and when you sign out. |

## After you delete your account

- **Content** such as posts, comments, stories and photos is removed. Copies others saved are theirs.
- **Messages** you sent and received remain on the other person's phone.
- **Reports** about you, or made by you, and any evidence held for them, may be kept for the periods above.
- **Flagged photos** held as evidence, and their case records, stay for the periods above even though your account is erased.
- **Third parties:** your sign-in record is removed from Firebase Authentication. If you signed in with Apple, we ask Apple to revoke the link between Hiyall and your Apple account as part of the deletion.
- **Backups** may still hold your data until they expire, as described in the table.
- **Anything we must keep by law**, or need to keep to protect someone from serious harm, is kept only for as long as that reason applies, with limited access.

## Legal holds

If a lawful request or an open safety case requires it, we keep the specific information concerned for longer. A case that is confirmed as illegal material, or reported to an authority, is kept under a hold until counsel or the authority says it can be released. We do not use holds to keep everything.

## Questions

[PRIVACY EMAIL]
