# Topics, voice notes, search, notices and support: experience notes (Wave 7)

The server contract is [docs/api/27](../api/27-stories-notices-support.md). These are the choices the app makes. Everything follows the visual language of [07](07-ux-and-design-system.md): `ChatTokens`, `PressScale`, 48 dp targets, reduced motion, light and dark contrast, and a layout that holds at text scale 2.0 on a 320 px screen and right to left.

## Home: Following and Everyone, with topics

- The segmented control keeps its two words ("Your people", "Everyone"). It now drives the stories above it too: **Your people** shows the tray of your circle, **Everyone** shows the public stories (`StoryExploreStrip`) in the same bubbles. A tap opens the story viewer, which carries on through the list.
- Under the control: a row of **topic chips** (All, then the eight topics, each with its own icon). The chosen topic narrows the stories and the posts of that tab and is remembered only in memory for that tab. A magnifier button opens **search**.
- A topic is optional on every post and story: a one-line "Topic (optional)" picker in the post composer and a `#` tab in the story composer. Cards and the story viewer show a small topic label.

## Voice notes

- A post and a story may carry one voice note of up to 60 seconds (record button in the composers). Recording shows the time left (red in the last ten seconds), a live level strip, Cancel and Stop; then the recording can be **listened to, re-recorded, thrown away or used**. A denied microphone is explained with an "Open settings" action. A note over a minute, a refused file and a busy server are worded for a recording, and Try again keeps the recording.
- Playback: one clip at a time in the whole app, nothing starts by itself, tapping the playing clip pauses it, a card scrolled away or a closed screen stops its clip, a call or another app pauses it. The bars are a drawing seeded by the clip's id (the server sends no loudness). A story with a voice note stays up for as long as the note plays. Screen readers get "Voice note from NAME" and the play button's state.

## Comments in threads

- The comments sheet lists top-level comments with **Reply** and **View N replies**; replies are indented one level and load on demand. A reply to a reply is sent with that reply's id and joins the thread of its top-level comment. A banner says who you are replying to. Deleting a comment takes its replies with it.
- **Translate** on a post, a comment and a story: on-device only (`TranslationService`). The button appears only when the phone can translate and the text is in another language; it asks before downloading a language pack; the translation replaces the text in place with "Show original". On stories the translation shows in a small caption over the story.

## Search and My activity

- Search (posts or stories, optional topic) waits for a pause in typing, needs two letters, loads a page at a time ("Show more": the server caps the pages and counts each against the day) and says plainly when a daily limit is reached. A result opens the post (`/post/:id`) or the story viewer.
- **My activity** (Settings > Account) has Comments and Likes tabs. A row opens its post; "This post was removed" rows do not open.

## Notifications settings

Master switch, Messages, then Social (New followers, Friend requests and invites, Comments, Replies, Reactions, **Profile visits** (opt-in, off by default, with an explanation that you will only be told about people who could see you anyway) and **Hide names in notifications** (on by default for members under 18). Each switch sends only its own field, moves at once and goes back with the server's words when it is refused. With the master switch off the others are disabled and the screen says security alerts still arrive.

## Notices and support

- **Notices** (Settings > Help & Safety) lists staff posts by category (Safety, News, Update), pinned first, with an unread dot; the body is paragraphs, bold and https links only (a small own renderer: no HTML, only https links open). A **pinned safety banner** on Home can be dismissed for the session; dismissal is not saved or sent. Opening the board marks everything seen (one pointer; nothing is tracked per notice).
- **Message support** (Settings > Help & Safety): conversations with the Hiyall team, one open per topic (Account, Safety, Bug, Other). Above the box, in plain words: messages to support are **not end-to-end encrypted** and the team can read them; do not send passwords or ID numbers (the safety topic also points to emergency services for immediate danger). A reply arrives as the push "Support replied" and an unread dot; a closed conversation offers "Start a new message". Members under 18 can use it; staff are told the member's age band and never ask for off-platform contact.
