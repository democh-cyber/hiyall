import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart' show AppLocalizations;
import 'api.dart';
import 'state.dart';

/// The notice board: short posts from the Hiyall team
/// (docs/api/27-stories-notices-support.md, section 6). What is unread is one pointer per member on
/// the server; nothing here records what was read or opened.
enum NoticeCategory {
  safety,
  news,
  update;

  /// A category this app does not know (a newer server) reads as News.
  static NoticeCategory parse(Object? value) => values.firstWhere(
    (c) => c.name == value,
    orElse: () => NoticeCategory.news,
  );
}

class Notice {
  final String id;
  final NoticeCategory category;
  final String title;

  /// Limited markup: paragraphs, `**bold**` and `[label](https://address)` (see `notice_markup.dart`).
  final String body;
  final bool pinned, unread;
  final DateTime? publishedAt;
  const Notice({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    this.pinned = false,
    this.unread = false,
    this.publishedAt,
  });
  factory Notice.fromJson(Map<String, dynamic> json) => Notice(
    id: json['noticeId'] as String,
    category: NoticeCategory.parse(json['category']),
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    pinned: json['pinned'] as bool? ?? false,
    unread: json['unread'] as bool? ?? false,
    publishedAt: DateTime.tryParse(json['publishedAt'] as String? ?? ''),
  );

  Notice asUnread() => Notice(
    id: id,
    category: category,
    title: title,
    body: body,
    pinned: pinned,
    unread: true,
    publishedAt: publishedAt,
  );
}

List<Notice> _notices(Object? json) => [
  for (final item in (json as List? ?? const []))
    Notice.fromJson(Map<String, dynamic>.from(item as Map)),
];

/// What Home needs for the pinned safety banner and Settings for the unread dot.
class NoticeSummary {
  final UnreadBadge unread;
  final List<Notice> pinned;
  const NoticeSummary(this.unread, this.pinned);
  static const empty = NoticeSummary(UnreadBadge(0), []);
  factory NoticeSummary.fromJson(Map<String, dynamic> json) =>
      NoticeSummary(UnreadBadge.fromJson(json), _notices(json['pinned']));

  bool get hasUnread => unread.count > 0 || unread.more;

  /// The first pinned notice of category safety, or null.
  Notice? get pinnedSafety => pinned
      .where((n) => n.category == NoticeCategory.safety)
      .cast<Notice?>()
      .firstOrNull;
}

/// The language the app is shown in, which picks the notices written for it (the server matches the first
/// subtag). The device's language when the app has strings for it, English otherwise.
final noticeLocaleProvider = Provider<String>((ref) {
  final device = PlatformDispatcher.instance.locale.languageCode;
  final supported = AppLocalizations.supportedLocales.map(
    (l) => l.languageCode,
  );
  return supported.contains(device) ? device : 'en';
});

String _query(String locale, [String? cursor]) =>
    '?locale=${Uri.encodeQueryComponent(locale)}'
    '${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}';

/// Unread count and pinned notices. Read by Home (the safety banner), Help & Safety and Settings.
/// A failed read stays quiet: those places simply show nothing.
final noticeSummaryProvider = FutureProvider<NoticeSummary>((ref) async {
  final session = requireSession(ref);
  final locale = ref.watch(noticeLocaleProvider);
  return NoticeSummary.fromJson(
    await ref
            .watch(apiProvider)
            .send(session, 'GET', '/v1/notices/summary${_query(locale)}')
        as Map<String, dynamic>,
  );
}, retry: (_, _) => null);

class NoticeBoard {
  final List<Notice> pinned;

  /// Every live notice, pinned ones included, newest first.
  final List<Notice> items;
  final String? nextCursor;
  final bool loadingMore;
  const NoticeBoard(
    this.pinned,
    this.items, {
    this.nextCursor,
    this.loadingMore = false,
  });

  /// The pinned notices once, then the rest.
  List<Notice> get ordered {
    final pinnedIds = {for (final n in pinned) n.id};
    return [...pinned, ...items.where((n) => !pinnedIds.contains(n.id))];
  }

  NoticeBoard copyWith({
    List<Notice>? items,
    String? Function()? nextCursor,
    bool? loadingMore,
  }) => NoticeBoard(
    pinned,
    items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// The Notices screen's list: the first page with the pinned notices, then pages by cursor. Opening it
/// marks everything read (one call that moves the member's pointer); the unread dots on this screen stay
/// until it is left, so the member can see which ones were new.
final noticeBoardProvider =
    AsyncNotifierProvider.autoDispose<NoticeBoardController, NoticeBoard>(
      NoticeBoardController.new,
      retry: apiReadRetry,
    );

class NoticeBoardController extends AsyncNotifier<NoticeBoard> {
  ApiClient get _api => ref.read(apiProvider);
  int _epoch = 0;

  Future<NoticeBoard> _first() async {
    final session = requireSession(ref);
    final locale = ref.read(noticeLocaleProvider);
    final data = await _api.send(
      session,
      'GET',
      '/v1/notices${_query(locale)}',
    ) as Map<String, dynamic>;
    return NoticeBoard(
      _notices(data['pinned']),
      _notices(data['items']),
      nextCursor: data['nextCursor'] as String?,
    );
  }

  @override
  Future<NoticeBoard> build() async {
    _epoch++;
    final board = await _first();
    // Seen as soon as the list is on screen. Best effort: the dot goes after the next summary read.
    unawaited(markSeen());
    return board;
  }

  Future<void> refresh() async {
    final fresh = await _first();
    _epoch++;
    if (!ref.mounted) return;
    // The pointer moved when the screen opened, so the server now calls everything read; the ones that were
    // new when the member arrived keep their dot until they leave.
    final wasUnread = {
      for (final n in [
        ...?state.asData?.value.pinned,
        ...?state.asData?.value.items,
      ])
        if (n.unread) n.id,
    };
    Notice keep(Notice n) => wasUnread.contains(n.id) ? n.asUnread() : n;
    state = AsyncData(
      NoticeBoard(
        fresh.pinned.map(keep).toList(),
        fresh.items.map(keep).toList(),
        nextCursor: fresh.nextCursor,
      ),
    );
    unawaited(markSeen());
  }

  Future<void> markSeen() async {
    try {
      await _api.send(requireSession(ref), 'POST', '/v1/notices/seen');
      if (ref.mounted) ref.invalidate(noticeSummaryProvider);
    } catch (_) {
      // The next visit moves the pointer.
    }
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || current.nextCursor == null || current.loadingMore) {
      return;
    }
    final epoch = _epoch;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final data = await _api.send(
        requireSession(ref),
        'GET',
        '/v1/notices${_query(ref.read(noticeLocaleProvider), current.nextCursor)}',
      ) as Map<String, dynamic>;
      if (epoch != _epoch || !ref.mounted) return;
      final latest = state.asData?.value ?? current;
      final known = {for (final n in latest.items) n.id};
      state = AsyncData(
        latest.copyWith(
          items: [
            ...latest.items,
            ..._notices(data['items']).where((n) => !known.contains(n.id)),
          ],
          nextCursor: () => data['nextCursor'] as String?,
          loadingMore: false,
        ),
      );
    } catch (_) {
      final latest = state.asData?.value;
      if (epoch == _epoch && ref.mounted && latest != null) {
        state = AsyncData(latest.copyWith(loadingMore: false));
      }
      rethrow;
    }
  }
}

/// Notices whose Home banner the member hid. Kept in memory only: it is gone when the app closes, and
/// nothing about it is saved or sent.
final dismissedBannersProvider =
    NotifierProvider<DismissedBanners, Set<String>>(DismissedBanners.new);

class DismissedBanners extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void hide(String noticeId) => state = {...state, noticeId};
}
