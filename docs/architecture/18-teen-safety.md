# Teen safety and abuse limits

What the API enforces for members under 18 and against scraping. Everything here is server-side: the app only mirrors it. The unit of "minor" is the age band in [18 accounts and onboarding](../api/18-accounts-and-onboarding.md) and [19 Nearby and open access](../api/19-nearby-and-open-access.md): a member whose declared birth date makes them under 18 (`age_band()`), and an unknown date counts as an adult. Migration `0034_teen_safety.sql` adds `nearby_prefs`, `member_daily_counts` and `age_gate_refusals`.

## Nearby is opt-in (T2)

- `nearby_prefs.visible` is false for every new member and for every minor. `PUT /v1/me/nearby` turns it on (and stores no location); `DELETE /v1/me/nearby` turns it off and deletes the stored point in the same transaction; `GET /v1/me/nearby` returns `{visible, sharing, minor, updatedAt}`.
- Migration backfill: an adult who had shared a location in the last 24 hours stays visible (the app keeps working for them); everyone else starts off, and every minor's stored point is deleted.
- **Reciprocity.** You must be visible to search Nearby (`409 NEARBY_OFF`), and a member who is not visible is never listed: the query joins `nearby_prefs.visible`, so even a stray point row cannot list them. `PUT /v1/me/location` is `409 NEARBY_OFF` while it is off.
- The app reads the device position only after the explainer, from Discover's Nearby or from Settings (see [mobile 15](../mobile/15-nearby-and-presence.md)). Nothing is read on launch or resume. The explainer states what is shared, who can see it, 24 hours, and how to stop; members under 18 get a stronger paragraph.

## Nearby hardening (S2)

- `radiusKm` is accepted only from the bucket list 5, 10, 15, 25, 50, 100 (`422 VALIDATION` otherwise). The distance buckets are the same list (minors: 10, 25, 50, 100, and a minor's radius is widened to their next bucket), so a member being inside a radius is exactly "their bucket is at most the radius": a search reveals nothing finer than 5 km. A binary search over the radius is therefore impossible, and a search over spoofed centres is limited by the next two rules.
- **Daily offset.** Each member has a secret offset (up to 2 km, 5 km for minors) stored in `nearby_prefs` with its UTC day and rotated when the day changes. It is added to the submitted point before the point is rounded to the grid (about 1.1 km, about 11 km for minors), so the stored cell is not the member's true cell and moves from day to day.
- **Change cap.** At most `Entitlements.LocationChangesPerDay` (5) writes per UTC day that land in a different cell than the stored fresh point (`429 DAILY_LIMIT`). A write to the same cell only refreshes the time. The existing limiter (burst 3, then one every 2 minutes) stays.
- **Speed check.** A point more than 1000 km/h, after 30 km of tolerance for the grid and the offset, from the last stored point is `422 LOCATION_IMPLAUSIBLE` and does not count as a change.
- **Query cap.** `Entitlements.NearbyQueriesPerDay` (200) Nearby requests per UTC day, pages included (`429 DAILY_LIMIT`).
- Tests (`httpapi/teen_test.go`): no radius under 5 km; a member 0.4, 1.9 and 4.8 km away all show as "5"; the sixth cell change in a day is refused; implausible jumps; the offset is stored, kept within a day and rotated across days.

## Minor protections (S3)

- **Filters.** Age and gender filters are refused with `422 FILTER_NOT_AVAILABLE` (people search and Nearby) when the viewer is a minor. They are never applied to a candidate who is a minor (those two predicates pass for minors), which only matters when `AGE_BAND_ISOLATION` is off in development, since with isolation on an adult never sees a minor. The app hides both filters for minors.
- **Locked defaults.** `PATCH /v1/me/privacy` from a minor refuses `onlineAudience` other than `nobody`, `locationAudience` other than `nobody`, and `fieldAudiences.location` or `.connections` more open than `friends`, with `422 MINOR_SETTING_LOCKED` ("This setting stays more private for members under 18."). Tightening is always allowed; adults are unaffected; turning 18 unlocks them. The check uses the age band at the time of the request.
- First messages from strangers to minors are capped by the chat work, not here.

## Age gate (T5)

- The date picker opens on today in the year list, with no suggested age, and the date is sent when Continue is tapped: `POST /v1/me/onboarding/age {birthDate}` (allowed before onboarding, stores nothing). A date under 13 is `403 AGE_REQUIREMENT_NOT_MET` and the refusal is recorded in `age_gate_refusals` against the sign-in identity (issuer and subject, a count and a time, **no date**). From then on, the identity's age checks and completions are `403 AGE_GATE_COOLDOWN` for 7 days from the last refusal, whatever date is sent. `POST /v1/me/onboarding/complete` records a refusal the same way. The row has no foreign key, so deleting the account does not clear it; maintenance deletes refusals older than 30 days.
- The app shows a calm message for both codes. Development fixtures with no identity row record nothing. A self-declaration is still not age assurance.

## Text rules (S9)

`domain/text.go` rejects, for every free-text field that goes through `CleanText` or `CleanLine` (display name, bio and the other profile text, interests, posts, comments, stories, spaces and space entries, reports): C0 and C1 controls and DEL (tab, line feed and carriage return only where the field is multi-line), format characters (bidi overrides, embeddings and isolates, zero-width space, word joiner, BOM, soft hyphen, tag characters), private-use characters and U+2028 and U+2029. The zero width joiner (emoji sequences, Indic conjuncts) and zero width non-joiner (Persian and Indic spelling) are allowed only between two visible characters, never first, last, doubled or next to a space. Runs of more than 5 combining marks are refused. Accepted text is stored in NFC (`golang.org/x/text/unicode/norm`) and lengths are counted after normalisation. Chat bubbles are end-to-end encrypted, so the server cannot apply this to them: the chat client applies `domain.Normalize`-equivalent rules itself.

## Scraping caps (S10)

Per account and UTC day, server-side (`Entitlements`): 300 search pages, 500 profile views of other members (your own is free), 200 Nearby queries (`429 DAILY_LIMIT`). A visit row is written once per viewer and profile (the table's key) and the request that would check it is throttled to one per viewer and profile per hour per node (`visit_writes`, memory only). Follows (200), friend requests (50), comments (300), spaces (3) and space entries (100) have daily caps too; see [11 plans and entitlements](11-plans-and-entitlements.md#daily-caps).

**Firebase App Check is not enabled.** It needs console setup (registering the iOS and Android apps with App Attest, Play Integrity or a debug provider, and enforcing it for the API). Until then every sign-in provisions an account, which the caps above only slow down; App Check should be turned on before launch.
