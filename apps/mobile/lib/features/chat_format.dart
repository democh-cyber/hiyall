import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat/chat_attachment.dart' show SendStatus;
import '../core/chat/chat_engine.dart';
import '../shared/chat_tokens.dart' show ChatMetrics;

/// "Now" for everything the chat screens print as a relative time or a day
/// heading. Replaced in tests so "Today" and "5m" are deterministic.
final chatClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// "12 Oct", with the year only when it is not this one.
String shortDate(DateTime at, DateTime now) =>
    '${at.day} ${_months[at.month - 1]}${at.year == now.year ? '' : ' ${at.year}'}';

/// The right-hand time on a chat row: now, 5m, 2h, Yesterday, Mon, 12 Oct.
String chatListTime(DateTime at, DateTime now) {
  final a = at.toLocal(), n = now.toLocal();
  final elapsed = n.difference(a);
  if (elapsed.inMinutes < 1) return 'now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m';
  final days = _day(n).difference(_day(a)).inDays;
  if (days <= 0) return '${elapsed.inHours}h';
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdays[a.weekday - 1];
  return shortDate(a, n);
}

/// What the conversation header says when the peer is not online but the server
/// gave a last-seen time: "last seen just now", "last seen 25 min ago", "last
/// seen today at 14:20", "last seen yesterday at 21:05", "last seen Mon" within
/// the last week and "last seen 12 Oct" after that.
///
/// [at] is a five-minute bucket (its start), never an exact moment, so the
/// text never claims more precision than that: under five minutes is "just
/// now", under an hour counts down in steps of five, and a time of day is the
/// bucket's own. Everything is compared in the viewer's local time, and
/// [timeOf] formats a local time the way the device does (12 or 24 hour).
String lastSeenText(
  DateTime at,
  DateTime now,
  String Function(DateTime local) timeOf,
) {
  final a = at.toLocal(), n = now.toLocal();
  final elapsed = n.difference(a);
  if (elapsed < const Duration(minutes: 5)) return 'last seen just now';
  if (elapsed < const Duration(hours: 1)) {
    return 'last seen ${elapsed.inMinutes ~/ 5 * 5} min ago';
  }
  // Calendar days, counted on UTC dates so a daylight-saving change cannot make a day 23 or 25 hours long.
  final days = DateTime.utc(
    n.year,
    n.month,
    n.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  if (days <= 0) return 'last seen today at ${timeOf(a)}';
  if (days == 1) return 'last seen yesterday at ${timeOf(a)}';
  if (days < 7) return 'last seen ${_weekdays[a.weekday - 1]}';
  return 'last seen ${shortDate(a, n)}';
}

/// The chip between days in a conversation: Today, Yesterday, 12 Oct.
String chatDayLabel(DateTime at, DateTime now) {
  final a = at.toLocal(), n = now.toLocal();
  final days = _day(n).difference(_day(a)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return shortDate(a, n);
}

/// Whether [text] is one to three emoji and nothing else, which the thread
/// shows large with no bubble.
bool isEmojiOnly(String text) {
  final clusters = text.trim().characters.where((c) => c.trim().isNotEmpty);
  final list = clusters.toList();
  if (list.isEmpty || list.length > 3) return false;
  return list.every(_isEmoji);
}

bool _isEmoji(String cluster) {
  final runes = cluster.runes.toList();
  // A keycap such as 1️⃣ is a digit, #, or * with U+FE0F and U+20E3.
  if (runes.length >= 2 &&
      runes.last == 0x20E3 &&
      (runes.first == 0x23 ||
          runes.first == 0x2A ||
          (runes.first >= 0x30 && runes.first <= 0x39))) {
    return true;
  }
  for (final rune in runes) {
    if (rune == 0x200D || rune == 0xFE0F) continue;
    // The tag characters that end a subdivision flag such as 🏴󠁧󠁢󠁥󠁮󠁧󠁿.
    if (rune >= 0xE0020 && rune <= 0xE007F) continue;
    if (rune >= 0x1F000 && rune <= 0x1FAFF) continue;
    if (rune >= 0x2600 && rune <= 0x27BF) continue;
    if (rune >= 0x2300 && rune <= 0x23FF) continue;
    if (rune >= 0x2B00 && rune <= 0x2BFF) continue;
    if (rune == 0x203C || rune == 0x2049 || rune == 0x2122 || rune == 0x2139) {
      continue;
    }
    if (rune == 0x3030 || rune == 0x303D || rune == 0x3297 || rune == 0x3299) {
      continue;
    }
    return false;
  }
  return true;
}

/// Chats whose name, username or last message contains [query], ignoring case
/// and a leading `@`. An empty query keeps everything.
List<ChatConversation> filterConversations(
  List<ChatConversation> all,
  String query,
) {
  final q = query.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
  if (q.isEmpty) return all;
  bool hit(String? s) => s != null && s.toLowerCase().contains(q);
  return [
    for (final c in all)
      if (hit(c.peerName) ||
          hit(c.peerUsername) ||
          hit(c.last == null || c.last!.notice ? null : c.last!.preview))
        c,
  ];
}

/// The two list filters that real data backs: everything, or chats with
/// unread messages. (Presence is only what each person lets this account see, so there is no "Active".)
enum ChatFilter { all, unread }

/// [filterConversations] narrowed by [filter] as well. A muted chat with
/// unread messages still counts as unread.
List<ChatConversation> filterChats(
  List<ChatConversation> all, {
  String query = '',
  ChatFilter filter = ChatFilter.all,
}) {
  final byText = filterConversations(all, query);
  if (filter == ChatFilter.all) return byText;
  return [
    for (final c in byText)
      if (c.unreadCount > 0) c,
  ];
}

/// How many chats have something unread.
int unreadChatCount(List<ChatConversation> all) =>
    all.where((c) => c.unreadCount > 0).length;

/// The line under "Chats": real counts from the conversations, or null while
/// they are still loading.
String? chatsSubtitle(List<ChatConversation>? all) {
  if (all == null) return null;
  if (all.isEmpty) return 'No conversations yet';
  final n = unreadChatCount(all);
  if (n == 0) return 'All caught up';
  return n == 1 ? '1 unread chat' : '$n unread chats';
}

/// A count as it appears in a badge: exact up to 99, then "99+".
String badgeCount(int count) => count > 99 ? '99+' : '$count';

/// What a last message is, for the list preview. New message types get a
/// value here and a line in [previewFor]; anything not handled reads
/// "Message" rather than nothing.
enum ChatPreviewKind { none, text, photo, notice, failed }

class ChatPreview {
  final ChatPreviewKind kind;
  final String text;

  /// Prefixed with "You: " in the list.
  final bool mine;
  const ChatPreview(this.kind, this.text, {this.mine = false});

  /// The whole line as read aloud and shown: "You: sounds good".
  String get line => (mine ? 'You: ' : '') + text;
  bool get isPhoto => kind == ChatPreviewKind.photo;
  bool get isFailed => kind == ChatPreviewKind.failed;
}

/// The one-line preview of [last], or of the @handle before anything is sent.
ChatPreview previewFor(ChatMessage? last, {required String username}) {
  if (last == null) return ChatPreview(ChatPreviewKind.none, '@$username');
  final kind = last.status == SendStatus.failed
      ? ChatPreviewKind.failed
      : last.notice
      ? ChatPreviewKind.notice
      : last.isPhoto
      ? ChatPreviewKind.photo
      : ChatPreviewKind.text;
  final text = switch (kind) {
    ChatPreviewKind.failed => 'Not sent',
    ChatPreviewKind.none => '@$username',
    ChatPreviewKind.notice ||
    ChatPreviewKind.photo ||
    ChatPreviewKind.text => last.preview.trim(),
  };
  return ChatPreview(
    kind,
    text.isEmpty ? 'Message' : text,
    mine: last.mine && kind != ChatPreviewKind.notice && !last.notice,
  );
}

/// Whether the thread should jump to its newest message after history was
/// loaded again. Only when it is the first load, the person is already reading
/// the bottom, or they just sent something; never while they read older
/// messages (a delivery tick or an incoming message must not yank them away).
bool shouldAutoScroll({
  required bool firstLoad,
  required bool nearBottom,
  required bool sentNewOwnMessage,
}) => firstLoad || nearBottom || sentNewOwnMessage;

/// Whether a scroll position counts as "at the bottom", with some slack so a
/// few pixels of overscroll or a new typing row do not count as scrolling away.
bool isNearBottom({
  required double pixels,
  required double maxExtent,
  double slack = 160,
}) => maxExtent - pixels <= slack;

/// Corner radii of a bubble. The sender's far side is always [radius]. On the
/// near side (the one facing the page edge the sender is on) a run keeps
/// [radius] at its very top, narrows to [join] where it meets a neighbour and
/// ends in the smallest [tail] on the last bubble, so a run reads as one soft
/// shape and a lone bubble as a pill with a small tail. A bubble shorter than
/// twice [radius] (an "ok", one emoji) is scaled by the framework into a pill.
BorderRadius bubbleRadii({
  required bool mine,
  required bool first,
  required bool last,
  double radius = ChatMetrics.bubbleRadius,
  double join = ChatMetrics.bubbleJoin,
  double tail = ChatMetrics.bubbleTail,
}) {
  final top = Radius.circular(first ? radius : join);
  final bottom = Radius.circular(last ? tail : join);
  final r = Radius.circular(radius);
  return mine
      ? BorderRadius.only(
          topLeft: r,
          bottomLeft: r,
          topRight: top,
          bottomRight: bottom,
        )
      : BorderRadius.only(
          topRight: r,
          bottomRight: r,
          topLeft: top,
          bottomLeft: bottom,
        );
}

/// What one line of the thread is.
sealed class ThreadRow {
  const ThreadRow();
}

class DayRow extends ThreadRow {
  final DateTime day;
  const DayRow(this.day);
}

class NoticeRow extends ThreadRow {
  final ChatMessage message;
  const NoticeRow(this.message);
}

class UnreadRow extends ThreadRow {
  const UnreadRow();
}

class TypingRow extends ThreadRow {
  const TypingRow();
}

class MessageRow extends ThreadRow {
  final ChatMessage message;

  /// First and last bubble of a run from one person.
  final bool first, last;
  const MessageRow(this.message, {required this.first, required this.last});

  /// The small avatar sits by the last incoming bubble of a run.
  bool get showAvatar => !message.mine && last;
}

/// Messages from one person close together read as one run.
const groupGap = Duration(minutes: 5);

bool _joins(ChatMessage a, ChatMessage b) =>
    !a.notice &&
    !b.notice &&
    a.mine == b.mine &&
    _day(a.sentAt.toLocal()) == _day(b.sentAt.toLocal()) &&
    b.sentAt.difference(a.sentAt).abs() <= groupGap;

/// Lays a conversation out as day chips, runs of bubbles, an optional "new
/// messages" divider before [unreadFrom], and the typing bubble at the end.
List<ThreadRow> buildThread(
  List<ChatMessage> messages, {
  String? unreadFrom,
  bool typing = false,
}) {
  final rows = <ThreadRow>[];
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final prev = i == 0 ? null : messages[i - 1];
    final at = m.sentAt.toLocal();
    if (prev == null || _day(prev.sentAt.toLocal()) != _day(at)) {
      rows.add(DayRow(_day(at)));
    }
    if (m.notice) {
      rows.add(NoticeRow(m));
      continue;
    }
    if (unreadFrom != null && m.messageId == unreadFrom) {
      rows.add(const UnreadRow());
    }
    final next = i + 1 < messages.length ? messages[i + 1] : null;
    final startsRun =
        prev == null ||
        !_joins(prev, m) ||
        (unreadFrom != null && m.messageId == unreadFrom);
    final endsRun =
        next == null ||
        !_joins(m, next) ||
        (unreadFrom != null && next.messageId == unreadFrom);
    rows.add(MessageRow(m, first: startsRun, last: endsRun));
  }
  if (typing) rows.add(const TypingRow());
  return rows;
}

/// WCAG contrast ratio between two opaque colours.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}
