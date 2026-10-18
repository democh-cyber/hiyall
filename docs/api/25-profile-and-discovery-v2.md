# Profile and discovery v2

Wave 7. Language levels, personality tags, about me and hometown, a photo gallery, the member's local time, a show-distance switch, new Discover filters, possible matches, and three opt-in visibility features (recent visitors, birthday, the member's own visit history). Migration `0048_profile_discovery.sql`. Code: `internal/domain/{profilev2,possible,localtime,languages}.go`, `internal/store/{profilev2,possible}.go`, `internal/httpapi/profilev2.go`. Everything is enforced by the server; the app only mirrors it. Free now, Pro later: every limit below is an `Entitlements` field, nothing is paywalled and nothing is a coin or an ad.

Age bands still apply everywhere: members under 18 and adults never see each other, and a member under 18 gets the stricter defaults listed under [Members under 18](#members-under-18).

## Language proficiency

A language on a profile is `{ "code": "en", "level": 4 }`. The level is a number from 1 to 6 (`domain.LanguageLevelMin`..`Max`):

| Level | Name in the app |
|---|---|
| 1 | Just starting |
| 2 | Beginner |
| 3 | Conversational |
| 4 | Fluent |
| 5 | Advanced |
| 6 | Native |

At most `Entitlements.LanguagesMax` (5) languages. A write may still send a bare tag, no level (stored as 3) or the older words `basic` (2), `conversational` (3), `fluent` (4), `native` (6); the API always answers with the number. More than the limit, a level outside 1 to 6 or a duplicate code is `422 VALIDATION` on `languages`.

The profile JSON stays the source for display. `profile_languages(user_id, code, level)` is derived from it for filtering and ranking (index `(code, level, user_id)`), together with `profile_interests` and `profile_personality_tags`. A trigger (`profiles_derive`, function `derive_profile_rows`) rewrites them in the same transaction as any write of `profiles.data` that changes `languages`, `interests` or `personalityTags`, so no write path (API, fixture, SQL fix) can leave them behind; deleting the profile deletes them (`ON DELETE CASCADE`). The migration turned every stored language into the numeric form and filled the tables.

The audience of languages is the existing field audience `languages`: Discover rows, search matching and ranking read languages only for members whose audience is `everyone`.

## Personality tags and interests

`personalityTags` is a list of ids from the fixed set (`domain.PersonalityTags`): `curious`, `night_owl`, `early_bird`, `homebody`, `explorer`, `bookish`, `foodie`, `maker`, `playful`, `sporty`, `music_lover`, `film_fan`, `jokester`, `deep_thinker`, `planner`, `spontaneous`, `empathetic`, `chatty`, `low_key` (19). A profile holds none, or `3` to `Entitlements.PersonalityTagsMax` (5), distinct; anything else is `422 VALIDATION` on `personalityTags`. The words and icons belong to the app. Own field audience `personality` (default everyone).

Interests are unchanged except that the limit is `Entitlements.InterestsMax` (10).

## About me, hometown, birthday

| Field | Rule | Audience field, adult default | Member under 18 |
|---|---|---|---|
| `aboutMe` | one line, up to 160 characters | `aboutMe`, followers | hidden by default; may choose friends, never wider |
| `hometown` | coarse free text, up to 80 characters, **never an address** | `hometown`, followers | up to 40 characters; **only confirmed friends in the same age band**; may choose hidden or friends |
| birthday | month and day, never the year; shown only when `showBirthday` is on | `birthday`, friends | can never be shown |

A hometown is refused with `422 VALIDATION` on `hometown` when it has more than two digits, contains `#`, `@`, `/` or `:`, or has street, apartment, plot, sector, floor or box words; the message never repeats the text. A member under 18 gets the same rule with the shorter limit.

A minor's hometown is read as friends-only whatever audience is stored: it is returned only to the member and to an accepted friend who may open the profile (so never across the age band), and it is never in search, Discover or Nearby rows (those never carry a hometown for anyone). `PATCH /v1/me/privacy` from a minor refuses `fieldAudiences.hometown` or `.aboutMe` wider than friends and `.birthday` other than `nobody` with `422 MINOR_SETTING_LOCKED`.

Date of birth is never returned. Age stays whole years only, as before (`fieldAudiences.age`). Note that a member who shows both their age and their birthday lets a viewer work out the birth year; the Settings screen says so next to the switch.

## Profile responses

`GET /v1/me/profile` and `GET /v1/users/{id}/profile` gain:

| Field | Meaning |
|---|---|
| `languages[].level` | the number above |
| `personalityTags`, `aboutMe`, `hometown` | as above, for the viewers their audiences admit; the owner always sees their own |
| `photos` | the gallery, `[{mediaId, url, thumbUrl, width, height}]`, signed URLs; absent on a locked card |
| `localTime` | `{utcOffsetMinutes, label}`, only when the member's `showLocalTime` is on (and for the member themself) |
| `birthday` | `{month, day}`, adults who turned `showBirthday` on, to the `birthday` audience; never on your own profile |
| `visitorsVisible` | `true` when this adult shares who visited (see below); never for a member under 18 |

`PATCH /v1/me/profile` accepts `languages`, `personalityTags`, `aboutMe` and `hometown`. The limits come from the member's `Entitlements` (`ValidateProfilePatchFor`).

## Local time

`localTime` is computed on the server from the stored IANA time zone (`time.LoadLocation`; the zone data is embedded with `time/tzdata`, so a minimal container has it) at the moment of the request: `{ "utcOffsetMinutes": 330, "label": "UTC+5:30" }`. Daylight saving is therefore right today; it is wrong only for a zone that changes while the app stays open, until the next refresh. An empty, `Local` or unknown zone gives no `localTime`, never a wrong one. The zone name is never sent. The app adds the offset to its own clock and redraws once a minute, only while the label is on screen and the app is in the foreground. Discover rows carry `localTime` for members who show it.

Setting `showLocalTime` (privacy, boolean): adults default on, members under 18 default off (their own choice to turn it on).

## Show distance

Setting `showDistance` (privacy, boolean): adults default on, members under 18 default off. In Nearby results a member who turned it off has no `distanceKm` at all. The page is still ordered, and its cursor still made, by distance bucket (an ordering is not a distance, but it does reveal a relative order; this is documented, not hidden). The bucket is removed after the cursor is made (`hideDistances`).

## Discover filters

`POST /v1/discovery/search` and `POST /v1/discover/nearby` accept, besides the existing filters:

| Key | Meaning |
|---|---|
| `languages` | unchanged; any one of the codes matches (now read from `profile_languages`) |
| `languageMinLevel` | `0` to `6`; at this level or above in at least one of the selected languages; needs `languages` (`422 VALIDATION` otherwise) |
| `personalityTags` | any one of these tags matches |
| `sameCountry` | the shortcut: the server uses the country on your own profile; `422 COUNTRY_NOT_SET` when you have none; not combinable with `country` |

A member matches a dimension only when their audience for that field is `everyone`, exactly as for interests: a hidden field can never be found by filtering. Cursors are signed, short-lived and bound to the account and to the whole filter set (the new keys included), so changing any filter, or using another member's cursor, is `422 INVALID_CURSOR`. Every page counts against `Entitlements.SearchPagesPerDay` as before. Age and gender filters stay refused for a viewer under 18 (`422 FILTER_NOT_AVAILABLE`).

## Possible matches

`POST /v1/discovery/possible-matches` with `{ "limit": 1..20, "excludeFollowing": false, "cursor": "" }` (every key optional) answers `{ "items": [...], "nextCursor": ... }`. Items are the usual Discover items plus `reasons`: a subset of `interests`, `personality`, `languages`, `country` (never the score).

Ranking (`domain.Score`, mirrored in SQL; a test holds them equal): 3 per shared interest (counted up to 5), 2 per shared personality tag (up to 5), 4 for each direction of complementary languages (they are level 4 or above in a language you are at level 3 or below in, and the other way round, so 0, 4 or 8), 1 for the same country; maximum 34. Only fields the other member shows to everyone count, and a member with a score of 0 is not listed. Order: score descending, user id ascending, paged by that pair with a signed cursor (`possible\x00` key prefix) bound to the account and the options, 15 minutes, at most 10 pages. Eligibility is the same as search: active, onboarded, discoverable, public, not you, not blocked, same age band (`notBarred`). `excludeFollowing` also leaves out people you follow or asked to follow. Every page counts against the day's search pages (`429 DAILY_LIMIT`).

Candidates come from the indexes of the three normalised tables and from `profiles_country` (the same-country signal is capped at `store.PossibleCountryCap`, 3000, by user id; a member who shares anything else is found through the other indexes whatever the cap). `TestPossibleMatchesUsesTheNormalisedIndexes` runs EXPLAIN on 30,000 members and fails on a sequential scan of the normalised tables.

## Photo gallery

Up to `Entitlements.ProfilePhotosMax` (8) photos, in order; the first is the profile photo (`avatarMediaId` and `avatarUrl` follow it). A gallery photo is an ordinary upload with purpose `avatar`: `POST /v1/media/uploads`, PUT the bytes, `POST /v1/media/{id}/complete` (re-encode, metadata dropped, the upload scanner runs and a flagged or matched photo is quarantined and never becomes ready; no scanner is bypassed). It counts towards the usual upload slots and storage like any photo.

| Route | |
|---|---|
| `GET /v1/me/photos` | `{photos, max}` in order |
| `POST /v1/me/photos` `{mediaId}` | add at the end; `409 PHOTOS_FULL` at the limit; `422 VALIDATION` on `mediaId` for a photo that is not yours, not ready (pending, quarantined, deleted), already used or not an `avatar` upload |
| `PUT /v1/me/photos/order` `{mediaIds}` | every photo once, in the new order |
| `PUT /v1/me/photos/{mediaId}` `{mediaId}` | replace, keeping the position; the old photo is released for deletion |
| `DELETE /v1/me/photos/{mediaId}` | remove and release; the next photo becomes the profile photo; `404` when it is not in your gallery |

These take the profile-edit limiter. The old `PATCH /v1/me/profile {avatarMediaId}` still works and goes through the gallery: a new id replaces the first photo, `null` removes it and promotes the next. A photo an operator removes afterwards (or that is quarantined later) drops out of every response and out of the gallery at the next write.

Audience: the profile's. Anyone who may open the profile (not blocked, same age band, the profile audience admits them) gets `photos`; a locked card gets none. A minor's gallery is therefore visible to their own band under the same profile audience rules. Account deletion releases every photo (the existing media sweep) and the gallery rows go with the profile.

## Recent visitors, birthday, visit history

Three opt-in social visibility features. All default off and adults only where stated.

**Recent visitors.** Setting `visitorsVisibleToOthers` (adults, default false). When on, `GET /v1/users/{userId}/visitors` (paged, `limit` and `cursor` as other lists) returns who opened that member's profile in the last 30 days (`VisitWindow`), at most 200 (`VisitListMax`), most recent visit first: `{user, visitedAt, following}`. Allowed only when the member is an adult with the setting on and the caller may open the profile; otherwise `403 VISITORS_PRIVATE` (also for the member's own id: the owner has `GET /v1/me/visitors`, unchanged), or `404` when the pair is barred. Left out: inactive accounts, **every member under 18**, and anyone barred from the viewer or from the member (blocks either way, other age band). A minor can never turn the setting on (`422 MINOR_SETTING_LOCKED`) and a minor's list is never available. Opening a profile adds the visitor to that list for 30 days, so a profile that shares says so (`visitorsVisible`) and the app tells the visitor before they open the list. `profile_visits.last_visited_at` is refreshed at most once an hour by `RecordProfileVisit`.

**Birthday.** Setting `showBirthday` (adults, default false) and the field audience `birthday` (default friends): month and day appear on the profile for that audience, never the year.

**Places I've visited.** `GET /v1/me/visited` lists the caller's own history (profiles they opened in the last 30 days, at most 200, newest first, barred or inactive people left out); `DELETE /v1/me/visited` clears it (the all-time visitor counts of the profiles are not lowered). Nobody else can read it. A minor has it too, for their own account.

## Members under 18

- `showLocalTime` and `showDistance` default off (they may turn them on).
- `visitorsVisibleToOthers` and `showBirthday` can never be on; `birthday` is locked to hidden.
- `aboutMe` starts hidden and can be friends at most; `hometown` starts hidden, is at most 40 characters and is for confirmed friends only; neither is ever in Discover, search or Nearby rows.
- They never appear in anyone's recent-visitor list and never have one.
- Possible matches, filters, the gallery and everything else stay inside their age band.

## Entitlements and errors

New `Entitlements` fields: `LanguagesMax` 5, `InterestsMax` 10, `PersonalityTagsMax` 5, `ProfilePhotosMax` 8. Domain constants (not plan data): `PersonalityTagsMin` 3, `AboutMeMax` 160, `HometownMax` 80, `MinorHometownMax` 40, `VisitWindow` 30 days, `VisitListMax` 200, the ranking weights.

New error codes: `PHOTOS_FULL` (409), `VISITORS_PRIVATE` (403), `COUNTRY_NOT_SET` (422). Reused: `MINOR_SETTING_LOCKED`, `INVALID_CURSOR`, `DAILY_LIMIT`, `VALIDATION`.

## Privacy settings added

`showLocalTime`, `showDistance`, `visitorsVisibleToOthers`, `showBirthday` (booleans in `GET`/`PATCH /v1/me/privacy`) and the field audiences `aboutMe`, `hometown`, `personality`, `birthday`. The migration filled all of them for every existing member by age band.
