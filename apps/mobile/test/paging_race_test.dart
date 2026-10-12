import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/activity_state.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/feed_state.dart';
import 'package:hiyall/core/state.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

/// The second page waits on [gate], so tests can change state meanwhile.
class RaceApi extends FakeApi {
  Completer<void>? gate;
  List<Map<String, dynamic>> firstPage = [
    {'notificationId': 'old-1', 'readAt': null},
  ];
  List<Post> firstPosts = [post('p1')];
  @override
  Future<(ApiPage<Map<String, dynamic>>, int)> notifications(
    Session s, [
    String? cursor,
  ]) async {
    if (cursor != null) {
      await gate!.future;
      return (
        ApiPage<Map<String, dynamic>>([
          {'notificationId': 'old-2', 'readAt': null},
        ], null),
        2,
      );
    }
    return (ApiPage(firstPage, 'c1'), firstPage.length);
  }

  @override
  Future<ApiPage<Post>> feed(Session s, String mode, [String? cursor]) async {
    if (cursor != null) {
      await gate!.future;
      return ApiPage([post('p2')], null);
    }
    return ApiPage(firstPosts, 'c1');
  }

  @override
  Future<void> react(Session s, String postId, String? reaction) async {}
}

Post post(String id) => Post(
  postId: id,
  author: const Person(nikoId, 'niko', 'Niko'),
  body: id,
  audience: 'everyone',
  createdAt: DateTime.utc(2026, 10, 9),
);

ProviderContainer containerFor(RaceApi api) {
  final c = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test(
    'A refresh during loadMore is not overwritten by the older page',
    () async {
      final api = RaceApi();
      final c = containerFor(api);
      await c.read(activityProvider.future);
      api.gate = Completer();
      final more = c.read(activityProvider.notifier).loadMore();
      // A new notification arrives; the socket's 'activity' signal refreshes.
      api.firstPage = [
        {'notificationId': 'NEW', 'readAt': null},
        {'notificationId': 'old-1', 'readAt': null},
      ];
      await c.read(activityProvider.notifier).refresh();
      api.gate!.complete();
      await more;
      final value = c.read(activityProvider).value!;
      expect(value.items.map((i) => i['notificationId']), ['NEW', 'old-1']);
      expect(value.nextCursor, 'c1');
      expect(value.loadingMore, isFalse);
    },
  );

  test('A mark-read during loadMore survives the next page', () async {
    final api = RaceApi();
    final c = containerFor(api);
    await c.read(activityProvider.future);
    api.gate = Completer();
    final more = c.read(activityProvider.notifier).loadMore();
    await c.read(activityProvider.notifier).markRead('old-1');
    api.gate!.complete();
    await more;
    final value = c.read(activityProvider).value!;
    expect(value.items.map((i) => i['notificationId']), ['old-1', 'old-2']);
    expect(value.items.first['readAt'], isNotNull);
    expect(value.unread, 0);
  });

  test('Feed paging keeps a reaction and a refresh made meanwhile', () async {
    final api = RaceApi();
    final c = containerFor(api);
    final feed = feedProvider('everyone');
    await c.read(feed.future);
    api.gate = Completer();
    final more = c.read(feed.notifier).loadMore();
    await c.read(feed.notifier).react('p1', 'fire');
    api.gate!.complete();
    await more;
    var value = c.read(feed).value!;
    expect(value.items.map((p) => p.postId), ['p1', 'p2']);
    expect(value.items.first.myReaction, 'fire');

    await c.read(feed.notifier).refresh();
    api.gate = Completer();
    final again = c.read(feed.notifier).loadMore();
    api.firstPosts = [post('p0'), post('p1')];
    await c.read(feed.notifier).refresh();
    api.gate!.complete();
    await again;
    value = c.read(feed).value!;
    expect(value.items.map((p) => p.postId), ['p0', 'p1']);
    expect(value.nextCursor, 'c1');
  });
}
