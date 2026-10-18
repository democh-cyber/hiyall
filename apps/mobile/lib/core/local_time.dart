import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'api.dart';

/// What time it is, for "it's 3:42 PM there". Replaced in tests to pin the minute.
final localTimeClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The wall-clock time in the member's zone: [now] in UTC moved by their offset. Only the clock fields of the
/// result mean anything (it is not a moment in this phone's zone).
DateTime localTimeThere(LocalTimeInfo info, DateTime now) =>
    now.toUtc().add(Duration(minutes: info.utcOffsetMinutes));

/// "3:42 PM", or "15:42" when [use24Hour] is set.
String formatLocalTime(
  LocalTimeInfo info,
  DateTime now, {
  bool use24Hour = false,
}) {
  final there = localTimeThere(info, now);
  // Newer locale data puts a narrow no-break space before AM and PM; a plain space reads the same everywhere.
  return (use24Hour ? DateFormat.Hm() : DateFormat.jm())
      .format(there)
      .replaceAll('\u202f', ' ');
}

/// How far the member's time is from this phone's, in words for the long form: "3 hours ahead", "same time",
/// "30 minutes behind". Null when the offset of this phone is the same.
String? localTimeDifference(LocalTimeInfo info, DateTime now) {
  final here = now.timeZoneOffset.inMinutes;
  final delta = info.utcOffsetMinutes - here;
  if (delta == 0) return null;
  final minutes = delta.abs();
  final hours = minutes ~/ 60, rest = minutes % 60;
  final parts = [
    if (hours > 0) hours == 1 ? '1 hour' : '$hours hours',
    if (rest > 0) '$rest minutes',
  ].join(' ');
  return '$parts ${delta > 0 ? 'ahead' : 'behind'}';
}

/// How long until the minute changes, so a clock can tick exactly on it.
Duration untilNextMinute(DateTime now) =>
    Duration(seconds: 60 - now.second, milliseconds: -now.millisecond);
