> **DRAFT for legal review. Not legal advice. Placeholders in [BRACKETS] must be filled by the operator.**

# Data Retention

Version: 2026-10-01

Effective date: [EFFECTIVE DATE]

This document says how long Hiyall keeps each kind of information. A cleanup routine runs every hour on our servers and removes what has expired, in small batches. Items marked [CONFIRM] are targets that the operator must confirm before this is published, because the routine for them is not yet built or fixed.

## Your account

- **Download my data:** Settings > Account > Download my data.
- **Delete my account:** Settings > Account > Delete account. [CONFIRM] Your account is hidden and signed out straight away. If you change your mind, you have 30 days to cancel. After that your data is erased on a schedule, apart from the exceptions below.

## What we keep and for how long

| What | How long we keep it | Notes |
|---|---|---|
| Account and profile (name, username, bio, details, settings) | Until you delete your account | After deletion: 30-day grace period, then erased [CONFIRM] |
| Date of birth | Until you delete your account | Private. Kept so your age group stays correct. Cannot be changed. |
| Sign-in details (email, password, Google or Apple link) | Until your account is deleted | Held by Google's Firebase Authentication, not on our servers. |
| Chat messages on our servers | Removed once your phone confirms it received them. Anything delivered but not yet cleared goes after 7 days. Anything never delivered goes after 30 days. | The server only holds scrambled, unreadable text. Cleanup runs hourly. |
| Chat messages on your phone | Until you delete them, uninstall the app or delete your account | The app keeps the most recent 500 messages per chat. The other person keeps their own copy. |
| Chat photos (encrypted) | 30 days after the message is sent. 1 hour if never sent in a message. If you delete the photo it is removed at once. If a chat is blocked, its photos are removed within the hour. | Kept longer only if held as report evidence (see below). |
| Photos for profiles, posts and stories | Until you delete the post, story or photo, or replace your profile photo | Removed by the hourly cleanup. Uploads that are never finished are removed after 1 hour, and photos never attached to anything after 1 day. |
| Posts, comments and reactions | Until you delete them or your account | |
| Stories | Visible for the time you chose (6, 12 or 24 hours, 24 by default). The story and its viewer list are deleted 1 day after it expires. | |
| Shared location (for Nearby) | Counts as shared for 24 hours after the last update. Deleted after 7 days if not refreshed. Deleted straight away when you sign out. | Stored rounded (about 1 km, about 11 km for under-18s), never exact. |
| Online and last seen | Worked out from your sign-in activity, not stored separately | Last seen is rounded down to 5 minutes. |
| Sign-in sessions | A session record is removed once it is more than 30 days past its expiry and has not been used for 400 days. | A record that a session was signed out is kept so that it cannot be revived. It holds no profile content. |
| Chat device keys | Until you remove the device or delete your account | Public keys only. |
| Push token | Until it is replaced, the device is removed, or you delete your account | |
| One-time key claim records | 1 day | Used to stop abuse of chat setup. |
| Profile visits (who viewed whose profile) | While both accounts exist | The visitor list shows the most recent 200 visitors on the free plan. The total count is not reduced when a visitor deletes their account. |
| Follows, friends, blocks, mutes and restrictions | Until you remove them or delete your account | |
| Notifications inside the app | [CONFIRM] No automatic expiry yet. Target: 90 days. | |
| Reports and the actions taken | [CONFIRM] While a case is open, then up to 180 days after it closes, longer where a legal hold applies | Records of what staff decided are kept so that appeals can be handled. |
| Chat photos held as report evidence | Until the case is closed and the hold released | Released by staff. Not removed by the normal 30-day cleanup, by deleting the photo, or by blocking. |
| Technical logs on our servers | [CONFIRM: operator to set a period] | Request numbers, results and timings. No message contents or dates of birth. |
| Backups of our database | [CONFIRM] A rolling period of about 35 days | Backups cannot be edited, so data deleted from the live service may remain in a backup until it expires. If a backup is restored, deletions are applied again. |
| Data export files | [CONFIRM] Available to download for a limited time, then deleted | |

## After you delete your account

- **Content** such as posts, comments, stories and photos is removed. Copies others saved are theirs.
- **Messages** you sent and received remain on the other person's phone.
- **Reports** about you, or made by you, and any evidence held for them, may be kept for the periods above.
- **Third parties:** your sign-in record is removed from Firebase Authentication. If you signed in with Apple, [OPERATOR: describe Apple token revocation once built].
- **Anything we must keep by law**, or need to keep to protect someone from serious harm, is kept only for as long as that reason applies, with limited access.

## Legal holds

If a lawful request or an open safety case requires it, we keep the specific information concerned for longer. We do not use holds to keep everything.

## Questions

[PRIVACY EMAIL]
