import 'package:flutter/material.dart';

// Presentation groups use only Notification.type values in the existing
// contract. They are not new categories or fields in notification records.
const activityGroups = {
  'like': 'Social',
  'reaction': 'Social',
  'comment': 'Social',
  'visit': 'Social',
  'follow': 'Connections',
  'friend_request': 'Connections',
  'community': 'Circles',
  'message': 'Messages',
  'message_request': 'Messages',
  'security': 'System',
  'moderation': 'System',
};

/// Filter chips in display order; a group shows only when an item uses it.
const activityGroupOrder = [
  'Social',
  'Connections',
  'Circles',
  'Messages',
  'System',
];

DateTime? _received(Map<String, dynamic> item) =>
    DateTime.tryParse(item['createdAt'] as String? ?? '')?.toLocal();

String activityDayLabel(
  Map<String, dynamic> item,
  DateTime now,
  BuildContext context,
) {
  final date = _received(item);
  if (date == null) return '';
  if (DateUtils.isSameDay(date, now)) {
    return 'Today';
  }
  if (DateUtils.isSameDay(date, DateTime(now.year, now.month, now.day - 1))) {
    return 'Yesterday';
  }
  return MaterialLocalizations.of(context).formatMediumDate(date);
}

String activityTimeLabel(
  Map<String, dynamic> item,
  DateTime now,
  BuildContext context,
) {
  final date = _received(item);
  if (date == null) return '';
  final elapsed = now.difference(date);
  if (elapsed.inMinutes < 1) {
    return 'Just now';
  }
  if (elapsed.inHours < 1) {
    return '${elapsed.inMinutes}m';
  }
  if (elapsed.inDays < 1) {
    return '${elapsed.inHours}h';
  }
  if (elapsed.inDays < 7) {
    return '${elapsed.inDays}d';
  }
  return MaterialLocalizations.of(context).formatShortDate(date);
}
