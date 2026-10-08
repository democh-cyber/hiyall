# Activity UI refinement

This change affects only the `/notifications` page presentation. The existing
global header, navigation dock, routes, API contracts, data models, providers and
backend are unchanged. No notification records are seeded or synthesized.

## Current page

The foundation has no notification endpoint/provider. Its existing empty state
is retained, now inside an Activity header with a selected All view, compact
offline orbital illustration, and restrained copy. The promotional cards and
coming-soon labels are removed. Find your people opens the existing `/discover`
route. Activity visibility opens the existing `/profile/privacy` controls; it
does not introduce push preferences or notification delivery settings.

The page does not simulate fetching, unread counts, pull refresh, mark-as-read,
dismissal, notification settings saves, or content navigation. No placeholder
requests are made to a nonexistent endpoint.

## Reusable presentation

`ActivityView` consumes existing Notification JSON without replacing its model.
The `AsyncValue` describes presentation state only. A future existing-data caller
can supply loading/data/error states and real action handlers.

- Lazy timeline rows retain supplied order, text, actors, count and readAt.
  Date headings and relative timestamps are display formatting. No events are
  merged into new records. Existing aggregate count/actor information appears
  as stacked avatars and an update count.
- Filters derive from supplied existing notification types: like/comment,
  follow/friend_request, message/message_request and security/moderation.
  Unsupported or absent types do not create additional filters. In particular,
  no Mention type, record, endpoint or filter is invented.
- Unread rows use a small lime dot, a visible New label and an accessible unread
  description. Read state is not changed optimistically in the view.
- Taps and accessible read/dismiss menus are available only with supplied real
  callbacks. Targets without an existing navigation handler are not fabricated.
- Avatar initials come from supplied actor display names. Image providers may
  be supplied by an authorized media resolver; the view does not fabricate a
  URL from avatarMediaId or use sample photographs.
- Loading uses static row skeletons rather than the empty illustration. Errors
  show friendly copy, omit raw diagnostics and offer retry only with a handler.
- Pull refresh exists only with a real callback. Its orbit rotates only while
  that callback is running, stops afterward and remains static in reduced-motion
  mode. The current foundation page does not attach a fake refresh callback.

## Verification

Widget checks cover the actual empty route and existing navigation, 0/1/10/125
items, lazy rendering, filtering, date groups, supplied aggregate counts, read
state, delegated actions, loading/error separation, reduced-motion refresh,
small phones, the 679×1314 viewport, desktop, both themes and double text size.
Contract-shaped notification fixtures exist only in tests. Local render captures
are visual QA artifacts, not live user notifications.
