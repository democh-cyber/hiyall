/// A count that the server stops at 99, with the flag that says it stopped.
/// The app shows [badgeLabel] and never a number above 99.
class UnreadBadge {
  final int count;

  /// More than 99 were unread: show "99+". Absent from older servers.
  final bool more;
  const UnreadBadge(this.count, {this.more = false});

  /// Reads `<countKey>` and `<moreKey>` from an API answer.
  factory UnreadBadge.fromJson(
    Map<String, dynamic> json, {
    String countKey = 'unreadCount',
    String moreKey = 'unreadMore',
  }) => UnreadBadge(
    (json[countKey] as num?)?.toInt() ?? 0,
    more: json[moreKey] as bool? ?? false,
  );

  String get label => badgeLabel(count, more: more);

  @override
  bool operator ==(Object other) =>
      other is UnreadBadge && other.count == count && other.more == more;
  @override
  int get hashCode => Object.hash(count, more);
}

/// A count as it appears in a badge or caption: exact up to 99, then "99+".
String badgeLabel(int count, {bool more = false}) =>
    more || count > 99 ? '99+' : '$count';
