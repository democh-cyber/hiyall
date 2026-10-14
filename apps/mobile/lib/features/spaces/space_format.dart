import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_info.dart';
import '../../core/theme.dart';

const spaceKinds = {
  'community': 'Communities',
  'event': 'Events',
  'moment': 'Moments',
};

/// The kinds offered in browse lists: just communities unless Events are on.
Map<String, String> get visibleSpaceKinds =>
    FeatureFlags.events ? spaceKinds : {'community': spaceKinds['community']!};
const spaceKindNames = {
  'community': 'Community',
  'moment': 'Moment',
  'event': 'Event',
};
const spaceVisibility = {
  'public': 'Open to all',
  'private': 'Host approval',
  'invite': 'Invite only',
};
const spaceMemberStates = {
  'active': 'Active',
  'pending': 'Requests',
  'invited': 'Invited',
  'banned': 'Banned',
};

(IconData, Color) spaceKindStyle(String kind) => switch (kind) {
  'moment' => (Icons.bolt_rounded, VibeColors.lime),
  'event' => (Icons.event_rounded, VibeColors.peach),
  _ => (Icons.groups_rounded, VibeColors.lilac),
};

/// A stable accent per space so each circle keeps its own identity.
Color spaceTint(SocialSpace s) {
  if (s.kind == 'moment') return VibeColors.lime;
  if (s.kind == 'event') return VibeColors.peach;
  const tints = [VibeColors.lilac, VibeColors.mint, VibeColors.peach];
  return tints[s.spaceId.codeUnits.fold(0, (a, b) => a + b) % tints.length];
}

String spaceCapitalized(String v) =>
    v.isEmpty ? v : '${v[0].toUpperCase()}${v.substring(1)}';

String spaceClock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String spaceDay(DateTime t) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final year = t.year == DateTime.now().year ? '' : ' ${t.year}';
  return '${days[t.weekday - 1]} ${t.day} ${months[t.month - 1]}$year';
}

/// "Tonight · 20:00", "Tomorrow · 09:30" or "Sun 11 Oct · 14:00".
String whenLabel(DateTime at, [DateTime? now]) {
  final t = at.toLocal(), n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day).difference(today).inDays;
  final name = day == 0
      ? (t.hour >= 17 ? 'Tonight' : 'Today')
      : day == 1
      ? 'Tomorrow'
      : spaceDay(t);
  return '$name · ${spaceClock(t)}';
}

String _span(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min';
  if (d.inHours < 24) return '${d.inHours} h';
  final days = (d.inHours / 24).round();
  return days == 1 ? '1 day' : '$days days';
}

/// Short live state for timed spaces: "Live now · 30 min left", "Starts in 2 h".
String? spaceTiming(SocialSpace s, [DateTime? now]) {
  if (s.status == 'archived') return 'Archived';
  if (s.status == 'closed') return 'Closed';
  if (s.startsAt == null || s.endsAt == null) return null;
  final at = now ?? DateTime.now();
  if (at.isBefore(s.startsAt!)) {
    return 'Starts in ${_span(s.startsAt!.difference(at))}';
  }
  if (at.isBefore(s.endsAt!)) {
    return 'Live now · ${_span(s.endsAt!.difference(at))} left';
  }
  return 'Ended';
}

String spaceSchedule(SocialSpace s) {
  if (s.startsAt == null) return '${s.memberCount} / ${s.capacity} members';
  final start = s.startsAt!.toLocal(), end = s.endsAt!.toLocal();
  final sameDay =
      start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  final until = sameDay
      ? spaceClock(end)
      : '${spaceDay(end)}, ${spaceClock(end)}';
  return '${spaceDay(start)}, ${spaceClock(start)} – $until (your time)\n'
      'Host zone: ${s.timezone}';
}

/// "2 / 50 members · Host approval"
String spaceMeta(SocialSpace s) =>
    '${s.memberCount} / ${s.capacity} ${s.kind == 'community' ? 'members' : 'joined'}'
    ' · ${spaceVisibility[s.visibility] ?? s.visibility}';
