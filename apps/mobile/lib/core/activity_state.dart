import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'state.dart';

class ActivityState {
  final List<Map<String, dynamic>> items;
  final String? nextCursor;
  final int unread;
  final bool loadingMore;
  const ActivityState(
    this.items, {
    this.nextCursor,
    this.unread = 0,
    this.loadingMore = false,
  });
  ActivityState copyWith({
    List<Map<String, dynamic>>? items,
    String? Function()? nextCursor,
    int? unread,
    bool? loadingMore,
  }) => ActivityState(
    items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    unread: unread ?? this.unread,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// The signed-in account's notifications, newest first, loaded a page at a time.
/// Mutations update local state first and roll back if the server refuses.
final activityProvider =
    AsyncNotifierProvider<ActivityController, ActivityState>(
      ActivityController.new,
      retry: apiReadRetry,
    );

class ActivityController extends AsyncNotifier<ActivityState> {
  ApiClient get _api => ref.read(apiProvider);
  Session get _session => requireSession(ref);

  /// Bumped whenever the first page replaces the list, so a slower page
  /// fetched for the old list is dropped instead of overwriting the new one.
  int _epoch = 0;

  /// Applies [change] to the newest state, never to a snapshot taken before
  /// an await, so concurrent refreshes and mutations are kept.
  void _update(ActivityState Function(ActivityState) change) {
    final latest = state.asData?.value;
    if (latest != null) state = AsyncData(change(latest));
  }

  @override
  Future<ActivityState> build() async {
    _epoch++;
    final (page, unread) = await ref
        .watch(apiProvider)
        .notifications(requireSession(ref));
    return ActivityState(
      page.items,
      nextCursor: page.nextCursor,
      unread: unread,
    );
  }

  Future<void> refresh() async {
    final (page, unread) = await _api.notifications(_session);
    _epoch++;
    state = AsyncData(
      ActivityState(page.items, nextCursor: page.nextCursor, unread: unread),
    );
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || current.nextCursor == null || current.loadingMore) {
      return;
    }
    final epoch = _epoch;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final (page, unread) = await _api.notifications(
        _session,
        current.nextCursor,
      );
      // The list was reloaded meanwhile; this page continues the old one.
      if (epoch != _epoch) return;
      _update((latest) {
        final seen = {for (final i in latest.items) i['notificationId']};
        return latest.copyWith(
          items: [
            ...latest.items,
            ...page.items.where((i) => !seen.contains(i['notificationId'])),
          ],
          nextCursor: () => page.nextCursor,
          // A local mark-read in the meantime is newer than this count.
          unread: latest.unread == current.unread ? unread : latest.unread,
          loadingMore: false,
        );
      });
    } catch (_) {
      if (epoch == _epoch) _update((l) => l.copyWith(loadingMore: false));
      rethrow;
    }
  }

  /// Refreshes only the unread count, for the tab badge.
  Future<void> syncUnread() async {
    final current = state.asData?.value;
    if (current == null) return;
    final unread = await _api.unreadNotifications(_session);
    if (unread != current.unread) {
      // A new count means new or changed items; reload the first page.
      await refresh();
    }
  }

  Future<void> markRead(String id) async {
    final current = state.asData?.value;
    if (current == null) return;
    final index = current.items.indexWhere((i) => i['notificationId'] == id);
    if (index < 0 || current.items[index]['readAt'] != null) return;
    final items = [...current.items];
    items[index] = {
      ...items[index],
      'readAt': DateTime.now().toUtc().toIso8601String(),
    };
    state = AsyncData(
      current.copyWith(
        items: items,
        unread: (current.unread - 1).clamp(0, 1 << 30),
      ),
    );
    try {
      await _api.markNotificationRead(_session, id);
    } catch (_) {
      _update((latest) {
        final at = latest.items.indexWhere((i) => i['notificationId'] == id);
        if (at < 0 || latest.items[at]['readAt'] == null) return latest;
        final items = [...latest.items];
        items[at] = {...items[at], 'readAt': null};
        return latest.copyWith(items: items, unread: latest.unread + 1);
      });
      rethrow;
    }
  }

  Future<void> markAllRead() async {
    final current = state.asData?.value;
    if (current == null || current.unread == 0) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final wereUnread = {
      for (final i in current.items)
        if (i['readAt'] == null) i['notificationId'],
    };
    state = AsyncData(
      current.copyWith(
        items: [
          for (final i in current.items) {...i, 'readAt': i['readAt'] ?? now},
        ],
        unread: 0,
      ),
    );
    try {
      await _api.markAllNotificationsRead(_session);
    } catch (_) {
      _update(
        (latest) => latest.copyWith(
          items: [
            for (final i in latest.items)
              wereUnread.contains(i['notificationId'])
                  ? {...i, 'readAt': null}
                  : i,
          ],
          unread: latest.unread + current.unread,
        ),
      );
      rethrow;
    }
  }

  /// Accepts or declines the request behind a follow/friend request notification.
  /// The server removes the notification once the request is answered.
  Future<void> respond(Map<String, dynamic> item, bool accept) async {
    final current = state.asData?.value;
    if (current == null) return;
    final actor = (item['actors'] as List).first as Map<String, dynamic>;
    final id = item['notificationId'];
    final index = current.items.indexWhere((i) => i['notificationId'] == id);
    state = AsyncData(
      current.copyWith(
        items: [
          for (final i in current.items)
            if (i['notificationId'] != id) i,
        ],
        unread: item['readAt'] == null
            ? (current.unread - 1).clamp(0, 1 << 30)
            : current.unread,
      ),
    );
    try {
      if (item['type'] == 'friend_request') {
        await _api.respondFriendRequest(
          _session,
          item['targetId'] as String,
          accept,
        );
      } else {
        await _api.respondFollowRequest(
          _session,
          actor['userId'] as String,
          accept,
        );
      }
    } catch (_) {
      _update((latest) {
        if (latest.items.any((i) => i['notificationId'] == id)) return latest;
        final items = [...latest.items];
        items.insert(index < 0 ? 0 : index.clamp(0, items.length), item);
        return latest.copyWith(
          items: items,
          unread: item['readAt'] == null ? latest.unread + 1 : latest.unread,
        );
      });
      rethrow;
    }
    // Counts on both profiles change when a request is accepted.
    ref.invalidate(profileProvider);
    ref.invalidate(otherProfileProvider(actor['userId'] as String));
  }
}

/// Whether a notification is an open request this account can answer.
bool isPendingRequest(Map<String, dynamic> item) =>
    item['targetType'] == 'request' &&
    (item['actors'] as List? ?? const []).isNotEmpty &&
    (item['type'] == 'friend_request' || item['type'] == 'follow');
