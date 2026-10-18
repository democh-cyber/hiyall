import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/notices.dart';
import 'package:hiyall/features/notices.dart' show NoticesScreen;

import 'support/app_host.dart';
import 'support/scripted_api.dart';

Map<String, dynamic> notice(
  String id,
  String category,
  String title, {
  bool pinned = false,
  bool unread = false,
  String body = 'Hello **there**.',
}) => {
  'noticeId': id,
  'category': category,
  'title': title,
  'body': body,
  'pinned': pinned,
  'unread': unread,
  'publishedAt': '2026-10-10T09:00:00Z',
};

final safety = notice(
  'n1',
  'safety',
  'Never share your code',
  pinned: true,
  unread: true,
);
final news = notice('n2', 'news', 'Hiyall is growing', unread: true);
final update = notice('n3', 'update', 'Version 1.1 is out');

ScriptedApi boardApi({
  List<Map<String, dynamic>>? items,
  List<Map<String, dynamic>>? pinned,
  String? next,
  int unread = 2,
}) {
  final api = ScriptedApi();
  final all = items ?? [safety, news, update];
  api.on(
    'GET /v1/notices',
    (_, path) => path.contains('cursor=')
        ? {
            'items': [notice('n9', 'news', 'An older note')],
            'nextCursor': null,
            'unreadCount': 0,
            'pinned': <Object>[],
          }
        : {
            'items': all,
            'nextCursor': next,
            'unreadCount': unread,
            'unreadMore': false,
            'pinned': pinned ?? [safety],
          },
  );
  api.on('POST /v1/notices/seen', (_, _) => {'seen': true});
  api.on(
    'GET /v1/notices/summary',
    (_, _) => {
      'unreadCount': unread,
      'unreadMore': false,
      'pinned': pinned ?? [safety],
    },
  );
  api.on('GET /v1/support/unread', (_, _) => {'unreadCount': 0});
  return api;
}

void main() {
  group('Notices screen', () {
    testWidgets('lists notices, pinned first, with unread dots', (
      tester,
    ) async {
      final api = boardApi();
      await launchApp(tester, api, '/profile/notices');
      expect(find.text('Notices'), findsWidgets);
      expect(find.text('Never share your code'), findsOneWidget);
      expect(find.text('Hiyall is growing'), findsOneWidget);
      expect(find.text('Version 1.1 is out'), findsOneWidget);
      // Safety / News / Update labels, each with its own icon.
      expect(find.text('Safety'), findsOneWidget);
      expect(find.text('News'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      expect(find.byIcon(Icons.campaign_outlined), findsWidgets);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      // The pinned one comes first, even though the list is newest first.
      expect(
        tester.getTopLeft(find.text('Never share your code')).dy,
        lessThan(tester.getTopLeft(find.text('Hiyall is growing')).dy),
      );
      // Dots for the unread ones only.
      expect(find.byKey(const Key('notice-unread-n1')), findsOneWidget);
      expect(find.byKey(const Key('notice-unread-n2')), findsOneWidget);
      expect(find.byKey(const Key('notice-unread-n3')), findsNothing);
      // A notice that is both pinned and in the list shows once.
      expect(find.byKey(const Key('notice-n1')), findsOneWidget);
      // Bold renders (no asterisks on screen).
      expect(find.textContaining('**', findRichText: true), findsNothing);
    });

    testWidgets('opening it asks for the app locale and calls seen once', (
      tester,
    ) async {
      final api = boardApi();
      await launchApp(tester, api, '/profile/notices');
      expect(
        api.sent.where((c) => c.startsWith('GET /v1/notices?locale=en')),
        hasLength(1),
      );
      expect(api.count('POST /v1/notices/seen'), 1);
      // The dots stay while the screen is open, so the member sees what was new.
      expect(find.byKey(const Key('notice-unread-n1')), findsOneWidget);
    });

    testWidgets('pages by cursor when scrolled to the end', (tester) async {
      final api = boardApi(next: 'cursor-1');
      await launchApp(
        tester,
        api,
        '/profile/notices',
        size: const Size(390, 500),
      );
      await tester.drag(
        find.byKey(const Key('notices-list')),
        const Offset(0, -1500),
      );
      await tester.pumpAndSettle();
      expect(api.sent.any((c) => c.contains('cursor=cursor-1')), isTrue);
      await tester.drag(
        find.byKey(const Key('notices-list')),
        const Offset(0, -1500),
      );
      await tester.pumpAndSettle();
      expect(find.text('An older note'), findsOneWidget);
    });

    testWidgets('pull to refresh reads again', (tester) async {
      final api = boardApi();
      await launchApp(tester, api, '/profile/notices');
      await tester.fling(
        find.byKey(const Key('notices-list')),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(api.count('GET /v1/notices'), 2);
      // Still shows what was new when the member arrived.
      expect(find.byKey(const Key('notice-unread-n2')), findsOneWidget);
    });

    testWidgets('empty state', (tester) async {
      final api = boardApi(items: [], pinned: [], unread: 0);
      await launchApp(tester, api, '/profile/notices');
      expect(find.byKey(const Key('notices-empty')), findsOneWidget);
      expect(find.text('Nothing new right now'), findsOneWidget);
    });

    testWidgets('error state with retry', (tester) async {
      final api = boardApi();
      api.routes.remove('GET /v1/notices');
      await launchApp(tester, api, '/profile/notices');
      expect(find.byKey(const Key('notices-error')), findsOneWidget);
      expect(api.count('POST /v1/notices/seen'), 0);
      boardApi();
      api.on(
        'GET /v1/notices',
        (_, _) => {
          'items': [update],
          'nextCursor': null,
          'unreadCount': 0,
          'pinned': <Object>[],
        },
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Version 1.1 is out'), findsOneWidget);
    });

    testWidgets('a link in a body: https opens, http does not', (tester) async {
      final api = boardApi(
        items: [
          notice(
            'l1',
            'news',
            'Links',
            body: '[a](https://example.com) [b](http://example.com)',
          ),
        ],
        pinned: [],
        unread: 0,
      );
      await launchApp(tester, api, '/profile/notices');
      final text = tester.widget<Text>(
        find.byKey(const Key('notice-paragraph-0')),
      );
      var tappable = 0;
      text.textSpan!.visitChildren((s) {
        if (s is TextSpan && s.recognizer != null) tappable++;
        return true;
      });
      expect(tappable, 1);
    });
  });

  group('Home banner', () {
    testWidgets('shows the first pinned safety notice and opens Notices', (
      tester,
    ) async {
      final api = boardApi(
        pinned: [
          notice('p0', 'news', 'Pinned news', pinned: true),
          safety,
          notice('p2', 'safety', 'Second safety', pinned: true),
        ],
      );
      await launchApp(tester, api, '/home');
      expect(find.byKey(const Key('home-safety-banner')), findsOneWidget);
      expect(find.text('Never share your code'), findsOneWidget);
      expect(find.text('Second safety'), findsNothing);
      expect(find.text('Pinned news'), findsNothing);
      await tester.tap(find.byKey(const Key('home-safety-banner')));
      await tester.pumpAndSettle();
      expect(find.byType(NoticesScreen), findsOneWidget);
    });

    testWidgets('can be dismissed for the session, nothing is saved', (
      tester,
    ) async {
      final api = boardApi();
      final c = await launchApp(tester, api, '/home');
      await tester.tap(find.byKey(const Key('home-safety-banner-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-safety-banner')), findsNothing);
      expect(c.read(dismissedBannersProvider), {'n1'});
      // Only reads were sent: nothing about the dismissal.
      expect(api.sent.where((s) => !s.startsWith('GET ')), isEmpty);
    });

    testWidgets(
      'no banner without a pinned safety notice, or when the read fails',
      (tester) async {
        var api = boardApi(pinned: [notice('p0', 'news', 'Pinned news')]);
        await launchApp(tester, api, '/home');
        expect(find.byKey(const Key('home-safety-banner')), findsNothing);
      },
    );

    testWidgets('a failed summary read stays quiet', (tester) async {
      final api = boardApi();
      api.routes.remove('GET /v1/notices/summary');
      await launchApp(tester, api, '/home');
      expect(find.byKey(const Key('home-safety-banner')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Help & Safety entries', () {
    testWidgets('Notices row and the Settings row carry a dot when unread', (
      tester,
    ) async {
      final api = boardApi();
      final c = await launchApp(tester, api, '/profile/settings');
      // The Help group is far down Settings: scroll to it.
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-help')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('settings-help-unread')), findsOneWidget);
      c.read(routerProvider).go('/profile/help');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('help-notices')), findsOneWidget);
      expect(find.text('There’s something new'), findsOneWidget);
      await tester.tap(find.byKey(const Key('help-notices')));
      await tester.pumpAndSettle();
      expect(find.byType(NoticesScreen), findsOneWidget);
      expect(api.count('POST /v1/notices/seen'), 1);
    });

    testWidgets('no dot when nothing is unread', (tester) async {
      final api = boardApi(unread: 0);
      await launchApp(tester, api, '/profile/settings');
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-help')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('settings-help-unread')), findsNothing);
    });
  });

  test('NoticeSummary reads the pinned safety notice', () {
    final s = NoticeSummary.fromJson({
      'unreadCount': 100,
      'unreadMore': true,
      'pinned': [notice('a', 'news', 'x'), safety],
    });
    expect(s.pinnedSafety!.id, 'n1');
    expect(s.unread.label, '99+');
    expect(s.hasUnread, isTrue);
    expect(NoticeCategory.parse('mystery'), NoticeCategory.news);
  });

  testWidgets('summary is a quiet failure, never an exception', (tester) async {
    final api = ScriptedApi();
    final c = await launchApp(tester, api, '/home');
    expect(c.read(noticeSummaryProvider).hasError, isTrue);
    expect(tester.takeException(), isNull);
    expect(const ApiFailure('x'), isA<Exception>());
  });
}
