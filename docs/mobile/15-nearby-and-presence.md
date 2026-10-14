# Nearby and online status (app)

Discover is one simple people list. **Nearby** ("My surroundings") is a tab and a filter on that list, not a separate screen, and the member never turns location on or off inside the app. Settings has one visibility control, **Show when I'm online and last seen** (under it: "Everyone can see when you’re active. Turn off to hide both."). It is the existing `online-toggle`: on sets `onlineAudience` to `everyone`, off to `nobody`, and last seen follows it. Members under 18 start with it off. The API side, including the full contract and the safety note, is in [open access and nearby](../api/19-nearby-and-open-access.md).

## Discover

The screen is described in full in [people discovery](../ux/12-people-discovery.md#premium-discover-layout-find-your-people); in short:

- **Category chips:** Everyone, Online, Same vibe, Interests, Languages and **Nearby** (always last), the three in the middle only when the member's own profile has that field. Nearby is the existing Nearby route ("My surroundings") and the app still reads the location automatically, see below. Nothing on Discover asks for location itself.
- **Online** is a real server-side filter (`online: true`, also accepted by Nearby), switchable from the chip or from **Online now** in the filter sheet. The server matches members whose `onlineAudience` admits the viewer and who had session activity in the last 2 minutes; live socket connections (per API node) are not part of the filter, so it can show fewer people than the per-row dot, never more (see the [API note](../api/19-nearby-and-open-access.md#the-online-filter-and-interest-context-on-rows)).
- **Filters:** the Filters button opens the sheet: Online now, country, language, **age** (13 to 60+; the top stop means no upper limit), location, **gender**, interests and vibe. Its badge counts the filters that are on (a filter a chip stands for is not counted again) and **Reset** clears them.
- **Rows:** avatar with country badge and, only when the server says the person is online and lets this viewer see it, the shared `PresenceDot`; name; one line of what you have in common (or their top interests); a line about them; the languages they speak; and a **Say hi** pill. In Nearby the languages line starts with "Within 5 km", and results are nearest first within 50 km.
- Age and gender are filters only; they are never shown on a row or a profile card. The server also keeps minors (13 to 17) and adults (18+) apart; see [open access and nearby](../api/19-nearby-and-open-access.md).
- Circles and Moments are reachable from the compass beside the heading and from the Home create sheet.

## Another member's profile

Tapping someone in Discover opens `VisitorProfile` (`lib/features/visitor_profile.dart`):

- **Top:** back arrow and the options menu (mute, restrict, report, block).
- **Header:** avatar with country badge (and the online dot when they chose to show it), name with a gender mark, `@username`, language levels and where they are.
- **Stats:** Following, Followers, Visitors and Stories. Following and Followers open read-only lists when the server says you may see them (otherwise they are plain numbers with a note); Visitors is how many different members have opened the profile (a plain number here, never who; only the owner has a list); Stories is how many of their stories you can watch right now and opens the story viewer. See [profile experience](../ux/10-profile-experience.md#tappable-stats).
- **Actions:** **Message** is the main wide button and **Follow** sits beside it. Anyone can message anyone, so there is no friend step and following never limits messaging. A private-profile card, which an earlier privacy setting can still produce, keeps its friend request control.
- **Tabs:** an icon tab for the **Detailed profile** (age, current location, interests with the ones you share first and counted as "N in common", current vibe, languages with levels, profession, education, website) and one for **Posts**.
- Messaging uses the end-to-end encrypted chat, which runs in the Android and iOS apps. On the web, Message explains that chats are available in the mobile apps.

## Location is opt-in

Nearby is off for every member until they turn it on, and the app reads the device position only then. `LocationSync` (`lib/core/location_sync.dart`) is now a plain wrapper: it reads and uploads nothing on launch, resume, sign-in or onboarding.

- Opening **Nearby** in Discover while "Show me in Nearby" is off shows a card (`NearbyOptInCard`). **Show me in Nearby** opens an explainer sheet (`nearby_optin.dart`) that says what is shared (a rough area, about 1 km for adults and 10 km for members under 18, moved a little each day, never the exact spot), who can see it (only other people who turned Nearby on; under 18s only see other under 18s; distances like "within 5 km", never a map), how long (24 hours, read only when Nearby is opened and the person asks) and how to stop. Members under 18 get a stronger paragraph, and the app shows it whenever it cannot tell. Only **Show me in Nearby** in the sheet calls `PUT /v1/me/nearby` and then reads one low-accuracy position for `PUT /v1/me/location`. **Not now** reads nothing.
- Settings has a **Show me in Nearby** switch (`features/nearby_setting.dart`, `NearbySettingsGroup`). Switching on shows the same explainer first; switching off calls `DELETE /v1/me/nearby`, which deletes the stored area on the server at once. The switch is read from `GET /v1/me/nearby` and is off by default.
- When the member is already visible but the stored area has expired (`LOCATION_NOT_SHARED`), opening Nearby reads the position once more without asking again, because they already agreed; if that fails the list is replaced by the explanation with **Try again** and **Open settings** (permission blocked or services off).
- Members under 18 do not get the age and gender filters in the filter sheet (the server refuses them with `FILTER_NOT_AVAILABLE`).
- Signing out still calls `DELETE /v1/me/location`.

## Online dot and last seen

Everything about presence is decided by the server, by the person's own `onlineAudience` and their relationship to the viewer (see [Presence](../api/19-nearby-and-open-access.md#presence)); the app only reflects what it is sent. A person is online with a live connection or session activity in the last 2 minutes, and `lastSeenAt` is their latest activity rounded down to 5 minutes. When the server does not send either, the app draws nothing and cannot tell "offline" from "hidden", and does not try.

One widget, `PresenceDot` (`lib/shared/presence_dot.dart`), draws the green dot everywhere so it looks identical: Discover and Nearby rows (top left of the avatar, where the country badge sits at the bottom right; key `online-dot-<userId>`), a visitor's profile (bottom right, 18 px; same key), the chats list (bottom right, key `chat-row-online-<userId>`) and the conversation header (bottom right, key `chat-online-dot`). The ring is cut out in the colour of the surface behind the avatar, the semantic label is "online", and the word "online" in the header uses a deeper green on light surfaces so it stays readable. Chats and the header also show last seen text; see the [chat experience](../ux/14-chat-experience.md).

Freshness: Discover updates on its normal reload; the chats list and an open conversation re-read their conversation payload on the existing chat signals, on pull to refresh, and on a slow 60 s refresh while the realtime socket is live (without a socket the existing 30 s sync already signals them). There is no new tight polling loop.

The web build opens no realtime socket, so a web member is online through their ordinary authenticated requests (the session's `last_seen_at`, refreshed at most once a minute), for as long as the page keeps making requests, and then shows "last seen" a few minutes later. Nothing in the app assumes a socket.

## What the app no longer has

The Privacy screen, the Discover visibility banner, the privacy step in onboarding and the earlier Nearby screen with its Share/Stop controls are gone. Profiles are visible to everyone in Discover and the other privacy settings keep the server's defaults. Blocking, muting, restricting and reporting remain in Settings → Safety.

## Tests

`test/discover_redesign_test.dart` covers the redesigned screen (chips, Online filter, Surprise me, Say hi, states, accessibility, contrast); `test/nearby_test.dart` covers the Nearby chip, the filter, distance and presence display, the permission-needed state, that nothing is read or shared on start or resume, and sign-out stopping the sharing; `test/nearby_optin_test.dart` covers the opt-in card, the explainer (including the under 18 wording and Not now reading nothing) and the Settings switch. The online toggle is covered in `test/widget_test.dart`.
