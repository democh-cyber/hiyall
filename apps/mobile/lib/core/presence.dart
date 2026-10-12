/// A last-seen time from the server: an RFC 3339 string in five-minute steps,
/// or null for anything else (missing, null, not a string, not a date), which
/// the screens treat as "nothing to show".
DateTime? parseLastSeen(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

/// The presence the server put on a person object: [online] only when it is
/// exactly `true`, and [lastSeenAt] only when they are not online. Both are
/// left out by the server when this viewer may not see them, so "hidden" and
/// "offline" are the same here, and anything malformed means nothing is shown.
({bool online, DateTime? lastSeenAt}) parsePresence(Object? person) {
  if (person is! Map) return (online: false, lastSeenAt: null);
  final online = person['online'] == true;
  return (
    online: online,
    lastSeenAt: online ? null : parseLastSeen(person['lastSeenAt']),
  );
}
