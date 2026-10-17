> **DRAFT for legal review. Not legal advice. Placeholders in [BRACKETS] must be filled by the operator.**

# Privacy Policy

Version: 2026-10-01

Effective date: [EFFECTIVE DATE]

This policy explains what information Hiyall collects, why, who can see it, who we share it with, how long we keep it, and what choices you have. It is written to be read. If something here is unclear, write to [PRIVACY EMAIL].

## The short version

- Hiyall is open. Your profile is visible to other members in your age group, and other members can see when you visited their profile.
- We keep your date of birth private. We store it, privately, to place you in an age group and to work out your age in years. Your age in years is visible on your profile to members in your age group. Your date of birth is never shown.
- Your one-to-one chats are end-to-end encrypted. We cannot read them. We can still see some information about them, such as who you chat with and when.
- Nearby is off until you turn it on. Hiyall does not read your location unless you have turned Nearby on. When it is on, others see only a rounded distance. Turning it off deletes the location we saved.
- [COUNSEL: scanning status at launch. Keep this item only if a hash list or scanning provider is live at launch; otherwise delete it. Wording if live: Photos you upload for your profile, posts and stories are checked for known illegal images. A photo that is flagged is not shown and is kept as evidence, even if you delete your account (section 6).]
- If the app crashes, it can send a scrubbed crash report to our error-reporting provider (section 8).
- There are no ads. We do not sell your information.
- You can download your data and delete your account from the app.

## 1. Who is responsible

[COMPANY LEGAL NAME], [COMPANY ADDRESS], is responsible for your information ("Hiyall", "we", "us"). Contact: [PRIVACY EMAIL].

[DATA PROTECTION CONTACT / REPRESENTATIVE: add a data protection officer or representative for the EU or UK if one is required.]

## 2. What we collect

### Information you give us

- **Sign-in details.** An email address and password, or your Google or Apple account. These are held by Firebase Authentication (see section 8). Hiyall's own servers keep an identifier that Firebase gives your account, and do not keep your email address or password. If you choose Apple's "Hide My Email", the address held by Firebase is Apple's relay address, not your real one.
- **Date of birth.** Asked once when you sign up. We store it, privately, on our servers. It is used to place you in an age group and to work out your age in years. It cannot be changed, and it is deleted when your account is erased. If you enter a date that makes you younger than 13, see "Age check refusals" below.
- **Profile.** Display name, username, profile photo, headline, bio, and optional details such as gender, country, languages, interests, current vibe, and similar fields. Some of this may be filled in for you from your sign-in account, and you can change it.
- **Content.** Posts, comments, reactions, stories, photos, and discussions in spaces. Photos have their location and other hidden data stripped when they are processed.
- **Your connections and choices.** Who you follow, friend requests, who follows you, blocks, mutes, restrictions and your settings.
- **Reports.** What you tell us when you report something, including any messages or photos you choose to include.

### Information from your device and your use of the app

- **Location.** Only if you turn Nearby on. Nearby is off by default for everyone. The app reads your approximate position when you turn Nearby on (after you have read the explanation) and when you ask it to refresh. It does not refresh on its own, and it reads your location only while the app is open, never in the background. If you turn Nearby off, the location we saved is deleted. See section 5.
- **Sessions and devices.** For each sign-in we keep the platform (Android, iOS or web), when it started, and when it was last active. For chat we keep public encryption keys for each of your devices. If push notifications are switched on, we keep a push token for your device.
- **Online activity.** The time you were last active, used for the online dot and last seen (section 5).
- **Profile views.** Which member opened which member's profile, and when it first happened.
- **Crash reports.** If the app crashes or hits an unexpected error and the build includes error reporting, it sends a report to our error-reporting provider (section 8). The report is scrubbed on your phone before it leaves: no screenshots, no request contents or headers, no sign-in tokens, no email addresses, no ids, no chat text and nothing from your chats at all. It carries the app version, the phone's platform and operating system, and the technical details of the error. Our servers send the same kind of scrubbed report for server errors.
- **Technical logs.** Our servers log a request number, the result and how long a request took, for security and to fix problems. Logs do not include message contents or dates of birth. [OPERATOR: confirm what your hosting provider or network edge logs, such as IP addresses, and for how long.] Our servers use your network address to limit abuse; we do not store it with your account.
- **Abuse-prevention records.** To limit spam, scraping and unwanted contact we keep small counters: how many times your account (or your network address) did something in the last minutes or on the current day, such as following people, sending friend requests, searching or opening profiles. They hold a number and a time, not content. Rate-limit counters are removed shortly after they reset; daily counters are kept for a few days. To limit scraping of Nearby we also keep, for 3 days, which search centres an account (and a network address) used each day: the account and the address are each stored only as a keyed hash that we cannot turn back into the account or the address, together with a keyed hash of the stored point used as the centre. These records hold no readable location, no name and no content. We also keep a random key that your app attaches to creating a post, story or space message, for 24 hours, so a retry after a poor connection does not post twice.
- **Age check refusals.** If you enter a birth date that makes you younger than 13, we do not create your account and we remember that your sign-in (the identifier Firebase gives it, never the date you entered) was refused, how many times, and when. For 7 days after the last refusal that sign-in cannot try again. We remove the record after 30 days. Deleting an account does not clear it.

We do not use advertising or analytics software in the app. Error reporting is for fixing crashes, not for tracking you. [OPERATOR: confirm before release.]

### Information we do not collect

We do not collect your exact location, contacts, microphone or camera data (the camera is only used when you choose to take a photo), or health data.

## 3. How we use your information

- To run Hiyall: sign you in, show your profile, let people find, follow and message each other, and show posts and stories.
- To keep people safe: apply age groups, enforce limits and the Community Guidelines, deal with reports, [COUNSEL: scanning status at launch. keep "check uploaded photos for known illegal images," only if photos are scanned at launch] and spot abuse and fake accounts.
- To keep the service working and secure: fix bugs, find crashes and defend against attacks.
- To follow the law.
- To contact you about your account or about changes to our terms.

We do not use your chats to train anything or to decide what to show you, because we cannot read them. We do not show ads and we do not build advertising profiles.

[LEGAL REVIEW: for the EU and UK, list the legal basis for each use above.]

## 4. Who can see what

| What | Who can see it |
|---|---|
| Display name, username, photo, bio and profile details | Members in your age group, who are not blocked by you or blocking you. Each detail can be hidden by its own setting, but the app does not offer those settings yet, so today they are visible. |
| Your age in years | Members in your age group who open your profile. Never your date of birth. |
| Profile views | You see the list of members who visited your profile (up to the most recent 200 on the free plan). The visit count is also shown on your profile. Visitors are not notified and cannot opt out. |
| Followers and following lists | Adults: anyone who follows you. Under 18: only your friends. Your friends list is visible only to you and your friends. |
| Online and last seen | Everyone in your age group by default for adults, no one by default if you are under 18 (and under 18s cannot open it up). You can change it in Settings if you are an adult. |
| Nearby | Only if you turned Nearby on: a rough distance bucket, never coordinates. See section 5. |
| Posts, comments, stories | The audience you chose, and Hiyall staff when needed for safety. |
| Spaces | Members of the space, and Hiyall staff when needed for safety. Spaces are not end-to-end encrypted. |
| Chats | You and the person you chat with. See section 7. |
| Reports | The people reviewing them. The person you report is not told that you reported them. |
| [COUNSEL: scanning status at launch. Keep this row only if photos are scanned at launch, otherwise delete it. Wording if live: Flagged photos and safety cases] | [COUNSEL: scanning status at launch. Wording if live: A small number of authorised staff, with every view logged. See section 6.] |

Age groups are explained in the Children and Teens document. In short, members under 18 and members 18 and over cannot see or contact each other.

## 5. Online status, last seen and Nearby

**Online and last seen.** You appear as online while the app is open or you were active in the last two minutes. When you are not online, others may see a "last seen" time that is rounded down to the nearest five minutes. One switch controls both: **Settings > Show when I'm online and last seen**. If you switch it off, others see neither. For under-18s it starts off and stays off. When it is hidden, it looks the same to other people as being offline.

**Nearby.**

- Nearby lists members close to you. It is **off by default for everyone**. You turn it on from Discover, where the app first explains what is shared and who can see it, or in Settings. Until you do, the app does not read your location and we hold none for you.
- When Nearby is on, the app reads an approximate position when you turn Nearby on and each time you ask it to refresh, and sends it to our server. There is no automatic refresh: if you do not refresh, your saved position gets older and stops being shown after 24 hours. Our server adds a small secret offset and rounds it before saving it, to about 1 kilometre for adults and about 11 kilometres for under-18s. We do not save your exact coordinates.
- Other members never see coordinates. They see a distance in steps (for example "within 5 km"). For under-18s, the steps are wider (10, 25, 50 or 100 km).
- Your saved position counts as shared for 24 hours after the last update. It is deleted after 7 days if it is not refreshed. Turning Nearby off deletes it straight away. When you sign out in the app, the app asks our server to delete it. That is best effort: if the request does not get through, for example because you have no connection, the next point applies.
- If the app could not ask our server to delete your position when you signed out, or your sign-in ends without you signing out in the app (for example because you signed that device out from another device or we suspended the account), your position is not deleted at that moment. It stops being shown to others within 24 hours and is deleted within 7 days. [OPERATOR: update this paragraph when the server deletes it at once.]
- Only members in your age group who also turned Nearby on can see you in Nearby, and you can only see them. Members under 18 are never shown in adults' Nearby lists, and the other way round. Age and gender filters are not available to under-18s and are never applied to them.
- Rounding and distance steps reduce risk, but they are not perfect. A determined person who fakes locations from many places could narrow down where someone is to within a few kilometres. The server also limits how many accounts can search Nearby from one network address a day, using keyed hashes only. If this concerns you, leave Nearby off or turn off location for Hiyall in your phone's settings.

## 6. Photo checks, reports and safety records

**Photo checks.** [COUNSEL: scanning status at launch. Keep this paragraph only if a hash list or scanning provider is live; if photos are not scanned at launch, replace it with: "We do not currently check uploaded photos against lists of known illegal images. We rely on reports." Wording if live: Profile, post and story photos are checked when you upload them against a list of known illegal images, using a digital fingerprint (a hash) of the photo. The check finds known images only. It does not recognise people or look at what a photo shows, and no person looks at your photo because of it unless it matches, is flagged, or someone reports it. Photos in end-to-end encrypted chats cannot be checked, because we cannot read them.]

[COUNSEL: scanning status at launch. Keep this paragraph, with its heading, only if photos are scanned at launch; if they are not, a photo can still reach a case through a report, so rewrite it for reports. Wording if live: If a photo is flagged or matches. The photo is not shown to anyone and the upload is refused with a general message. We open a case and keep the photo as evidence in a separate restricted storage area, even if you later delete the post or your account. If the check found a match, we may suspend the account and sign it out of every device. We do not tell the person why, because an authority may ask us not to, and telling could put a child at risk. Staff review the case, and we may report it to the authorities where the law requires.]

[COUNSEL: scanning status at launch. Keep this paragraph only if photos are scanned at launch; otherwise delete it. Wording if live: The case record. A case holds: the account that uploaded the photo, what it was uploaded for (avatar, post or story), which check found it and what it found, the photo's fingerprint (SHA-256) and size, the times, the decision a staff member took and why, and, if we reported it, the report reference. It does not contain the photo itself; the photo is in the restricted storage area. Clearing a case, releasing the evidence hold and lifting a legal hold each need one administrator to propose it and a different administrator to approve it. Each proposal is kept with the case: the two staff ids, the reasons they wrote, the time, and, for lifting a legal hold, the reference counsel or the authority gave. We also keep the hold records of the case (that a hold was placed, until when, and when and why it was released).]

[COUNSEL: scanning status at launch. Keep this paragraph only if photos are scanned at launch; otherwise delete it. Wording if live: Who can see a case. Moderators can see the list of cases and each case record. Only administrators can load the held photo, and it opens blurred: showing it clearly is a second, separate step with a written reason.]

**Who can see reported content.** Staff can open the text and photos of reported public content after typing a reason. Every view of a case, a report or a member's account is written to an operator audit log before anything is shown: who, what, when and why. We keep the audit log for at least one year [COUNSEL: confirm the period]. Making someone an administrator needs one administrator to propose it and a different administrator to approve it. Staff cannot read private chats, other than what a reporter chooses to send.

**How long we keep it.** [COUNSEL: scanning status at launch. Keep this sentence group only if photos are scanned at launch; otherwise delete it. Wording if live: Held evidence is kept for the evidence retention period (default currently 365 days) from detection, and longer if the case is confirmed or reported, or if a legal hold or an authority requires it. Evidence is held at least 365 days, and at least a year after a report. The case record itself is kept after the files are removed (how long: counsel to confirm).] Encrypted chat photos that a reporter chose to include with a chat report are held as evidence until counsel sets a release rule [COUNSEL: chat evidence release rule]. See the Data Retention document.

**Reports.** If you report something, a person looks at it. For a chat report, you choose which messages (up to 10) and photos to include. The person you report is not told it was you.

**Other safety records.** We keep a record of moderation actions (such as a warning, content removal or suspension), and the records of your reports and of reports about you, for the periods in the Data Retention document.

## 7. Chats and end-to-end encryption

One-to-one chats, including photos, are end-to-end encrypted. Your phone encrypts a message before it leaves, and only the other person's phone can decrypt it. Our servers hold only scrambled data. We do not have the keys and cannot read your chats, so we cannot give them to anyone, including the authorities.

What this does not mean:

- **The server still sees information about chats.** For example: which accounts are chatting, when messages are sent, roughly how large they are, how many photos are sent and when, and which of your devices receive them. We also see the blocks and reports connected to a chat.
- **Limits on messages.** To reduce unwanted contact, a person can send up to 3 messages to someone who has not yet replied. After that they have to wait for a reply. Reactions and quiet messages count towards the three until the other person writes back. To keep one account from flooding another, at most 2,000 undelivered messages wait for one of your devices (and one sender can use only part of that room, currently 300), and one person can send at most 2,000 messages in one chat in a day. A sender who hits a limit is told to wait; the limits are counted by the server from the sender and the time, not from what a message says.
- **Your phone is the weak point.** Anyone who can unlock your phone, or the other person's phone, can read the chats stored there. Messages are kept on your device (the app keeps the most recent 500 per chat). Phone backups, if your phone's own backup feature includes them, are governed by Apple's or Google's terms, not ours.
- **The other person can share or screenshot it.** If someone reports a chat, they can choose to send us up to 10 messages and the photos in them. If you take part in a chat that is reported, those messages may be seen by our safety team. We only see what the reporter chooses to share.
- **Group chats and spaces are different.** Discussions in spaces are not end-to-end encrypted.
- **Safety numbers.** The app shows a safety number you can compare with the other person to check nobody has swapped keys. It does not do this for you automatically, and a mark that you verified it goes away if either of you adds or removes a device.
- **A new device on an account can read new messages.** Anyone who can sign in to an account, for example someone who learns its password, can add a device that reads the chats sent to that account from then on. It cannot read older messages, which stay on the phones that already had them. We do not yet check new devices cryptographically against the one you already trust. Instead the app tells you: your other devices show a banner, "A new device was added to your account", with a link to remove it, and they get a notification that contains no message text. The people you chat with see a notice in each conversation the next time they open it. If you see a device you do not recognise, remove it in Profile, Chat devices, and change your password.
- **Our server could add a device, and the app cannot yet tell.** Our server hands out each person's list of devices. If our server were tampered with, or misused by someone with access to it, it could add a device that you did not add, and the apps cannot yet prove that a device was really added by you. We treat every device added through the server the same way: your other devices and the people you chat with are told about it, and comparing safety numbers will show a change. This is a known limit of the design until devices must be approved by one you already trust.
- **Notifications show very little, but not nothing.** A chat notification shows only "Hiyall" and "New message". It carries no message text and no sender name, and it includes the id of the conversation so the app can open it. Notifications about friend requests, follows and space invitations can show another member's display name, for example "Sam sent you a friend request", and they say what kind of event it was. Notifications about devices say that a device was added to or removed from your account. When you schedule the deletion of your account, we send "Account deletion scheduled" to your devices before they are cleared. Every notification passes through Google (Firebase Cloud Messaging) and, on iPhones, through Apple, which deliver it, so Google and Apple learn that a notification was sent to your device, when, and what it says. Anyone looking at your lock screen can read it too: turn notifications off in your phone's settings if you do not want that. The app also does housekeeping for encryption, such as replacing a spare key about every 7 days, when it is open or has just been woken by a notification. A phone that is never opened keeps using its older keys for longer.
- **Leaving the app.** Signing out or deleting your account erases your chats, keys and cached photos from that phone. On an iPhone, if you delete the app without signing out, what the system keeps is erased the next time you open Hiyall after reinstalling. A chat device that has not been used for 35 days is removed from our servers. The messages waiting for it are kept until they expire (at most 30 days after they were sent), so a device that returns can still receive them. If you open the app on a device that was removed for being idle, it registers itself again with the same keys. The people you chat with are not alerted to a new device when that happens, and your other devices only get a calm note that a device you had not used for a while was signed out of chat. Someone who writes to a person whose devices were all removed this way is told that the person has not opened Hiyall in a while and the message cannot be delivered yet. A device that has been idle for more than 48 hours can also be removed while a message is being sent to it, if one sender has used up that sender's share of the room waiting for that device. Your other devices are told when a device is removed this way. If secure storage will not open, "Reset chat on this phone" clears this account's chat entries there (by name; not the app's other settings) and, the next time the app starts, also asks our server to remove that device from your account; it does not delete your account.
- Chats and chat photos can be used on the Android and iOS apps. They are not available in the web version.

## 8. Who we share information with

We do not sell your information. We do not share it for advertising. We use a small number of service providers to run Hiyall. They may only use your information to provide their service to us.

| Provider | What for | What they handle |
|---|---|---|
| Google (Firebase Authentication) | Sign-in, including Google sign-in | Your email, your password in protected form, your sign-in method, and sign-in details such as time and device information that Google collects as part of the service. Google's privacy policy applies to its own use. |
| Apple (Sign in with Apple, and Apple's notification service) | Apple sign-in; delivering notifications on iPhones | Your Apple account identifier and your relay or real email, if you use Apple sign-in. Push tokens, and the notifications Google passes to Apple for delivery on iPhones (section 7). When you delete your account we ask Apple to end the link between Hiyall and your Apple account if the app could get Apple's code; otherwise you remove it in your Apple ID settings (section 9). |
| Cloudflare (R2 storage) | Storing photos | Photos for profiles, posts and stories, kept in one storage area and shown to you only through short-lived links. Encrypted chat photos are kept in a separate storage area: Cloudflare only holds scrambled files it cannot open. Chat photos that a reporter included with a report are held in the encrypted-photo area. [COUNSEL: scanning status at launch. Keep only if photos are scanned at launch. Wording if live: Flagged photos held as evidence are kept in a further restricted area.] |
| Google (Firebase Cloud Messaging) | Push notifications | A push token for your device, and each notification we send you: the title "Hiyall", a short line and when it was sent. For a chat the line is "New message" and the notification carries the conversation id; it never contains message text. For friend requests, follows and space invitations the line can include another member's display name. On iPhones Google passes the notification on to Apple. [OPERATOR: confirm once push notifications are live.] |
| Sentry (Functional Software, Inc.) | Crash and error reports from the app and our servers | The scrubbed reports described in section 2: error details, app version and platform, never message text, tokens, emails or ids. [OPERATOR: confirm the Sentry region and how long reports are kept.] |
| [SCANNING PROVIDER] | [COUNSEL: scanning status at launch. Keep this row only if a hosted provider is used. Wording if live: Checking uploaded photos for known illegal images] | [COUNSEL: only if a hosted provider is used rather than our own hash list: say what is sent. A hash list kept by us shares nothing.] |
| [HOSTING PROVIDER] | Running our servers and database | Everything we store, except encrypted chat contents which are unreadable to them. [OPERATOR: fill in.] |

We may also share information:

- **With other members**, as described in section 4.
- **With the authorities or others** when the law requires, when we have a legal duty, or when it is needed to protect someone from serious harm. This includes reports about suspected child sexual abuse material. We can only provide what we have. We cannot decrypt your chats. [LEGAL REVIEW]
- **If our business changes** (for example, a merger), in which case this policy will continue to apply to your information unless we tell you otherwise.

[OPERATOR: add the countries where each provider processes data, and the legal mechanism for transfers outside the EU or UK.]

## 9. How long we keep information

We keep information only as long as we need it. The Data Retention document has a table with the details. Some examples: encrypted messages are removed from our servers after your phone has received them (or after 30 days if it never does), shared locations are deleted after 7 days, and stories are deleted a day after they expire. When you delete your account there is a grace period, then your data is erased, apart from the exceptions listed there.

What can remain after deletion, and why:

- **Evidence and safety records.** Reports, the encrypted chat photos held for a report, and the operator audit log are kept for the periods in the Data Retention document, because the law may require it and to protect people. [COUNSEL: scanning status at launch. Keep only if photos are scanned at launch. Wording if live: A flagged photo and its case record are kept too.]
- **A deletion record.** We keep the identifier of a deleted account and the time it was erased, and nothing else, so that a restored backup does not bring a deleted account back and the identifier is never reused. We also keep an empty shell of the account record (no personal data) because retained safety records point to it.
- **Backups.** Our database is backed up. Backups cannot be edited, so data you deleted may remain in a backup until it expires. [OPERATOR: state the backup retention.] If a backup is ever restored, we apply every deletion again before the service is used.
- **Apple sign-in.** When you delete your account and signed in with Apple, the app asks you to sign in with Apple again to get a one-time code from Apple, and our server uses it to ask Apple to end the link between Hiyall and your Apple account. If that last step fails, we keep a sealed (encrypted) copy of the token needed to do it, and retry until it works, then delete it. If the app cannot get Apple's code (for example you signed in again some other way), nobody at Hiyall can end the link for you, because Apple's request needs your own token. The app tells you so when your deletion is scheduled, and you remove it yourself: Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID. We keep a record, with no token, that you were told; it is removed when the deletion is cancelled and after 90 days. If our support schedules the deletion of your account, we hold no email address for you, so we cannot write to you: [OPERATOR: how the member is told when support schedules a deletion]. [COUNSEL: confirm this satisfies Apple's rules and any law on ending the link when an account is deleted.]

## 10. Your choices and rights

In the app:

- **Download my data:** Settings > Account > Download my data.
- **Delete my account:** Settings > Account > Delete account. Or ask us: staff can delete an account on request, and the action is logged. If support schedules the deletion of an account that is suspended or banned, the member cannot cancel it.
- **Edit your profile**, including removing your photo, bio or details.
- **Show when I'm online and last seen:** Settings.
- **Nearby:** turn it off in Settings, which deletes the location we saved.
- **Block, mute or restrict** anyone, and report content.
- **Sign out of other devices:** Settings > Where you're signed in.
- **Location:** turn off the location permission for Hiyall in your phone's settings.
- **Notifications:** turn them off in your phone's settings.

Depending on where you live, you may also have the right to access, correct, delete, restrict or object to the use of your information, to take it with you, and to complain to your data protection authority. To use a right the app does not cover, write to [PRIVACY EMAIL]. We may need to check it is really you. [LEGAL REVIEW: add region-specific sections, such as the EU and UK GDPR and US state laws, and a statement on rights for children.]

Things to know about deletion: other people may have copies of what you shared with them (for example a chat on their phone). Your date of birth is deleted with your account and we cannot change it before then. Evidence we must keep, such as a report and what was held for it (section 6), is not removed by deleting your account. [COUNSEL: scanning status at launch. Keep only if photos are scanned at launch. Wording if live: This includes a flagged photo and its case record.]

## 11. Security

We use encryption in transit, restrict who can reach our systems, log staff access to sensitive material, and design the chat so that we cannot read it. No service is perfectly secure. If we find out about a breach that affects you, we will tell you as the law requires. Security issues can be reported to [SECURITY EMAIL].

## 12. Children and teens

Hiyall is for people aged 13 and over. We do not knowingly collect information from anyone under 13. Teens get extra protection, described in the Children and Teens document. A parent or guardian can contact us at [PARENT/GUARDIAN CONTACT EMAIL].

## 13. Where your information is processed

[OPERATOR: state the countries where our servers and providers are located, and the legal basis for transfers.]

## 14. Changes to this policy

When we change this policy in a way that matters we will publish a new version number and ask you to accept it. The latest version is always in the app under **Settings > Legal**.

## 15. Contact

[COMPANY LEGAL NAME], [COMPANY ADDRESS]
Privacy questions: [PRIVACY EMAIL]
[DATA PROTECTION CONTACT / REPRESENTATIVE, if required]
