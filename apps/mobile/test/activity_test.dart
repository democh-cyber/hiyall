import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/activity_state.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/activity.dart';
import 'package:hiyall/shared/navigation_dock.dart';

import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

// Contract-shaped fixtures exist only in tests; no app or database is seeded.
final now = DateTime(2026, 10, 7, 12);
Map<String, dynamic> notification(
  int index, {
  String type = 'like',
  bool read = false,
  int count = 1,
  bool yesterday = false,
}) => {
  'notificationId':
      '019a6000-0000-7000-8000-${index.toString().padLeft(12, '0')}',
  'type': type,
  'actors': [
    {
      'userId': '019a7000-0000-7000-8000-${index.toString().padLeft(12, '0')}',
      'username': 'person_$index',
      'displayName': 'Person $index',
      'verified': false,
      'following': false,
      'friendship': 'none',
    },
    if (count > 1)
      {
        'userId':
            '019a8000-0000-7000-8000-${index.toString().padLeft(12, '0')}',
        'username': 'second_$index',
        'displayName': 'Second $index',
        'verified': false,
        'following': false,
        'friendship': 'none',
      },
  ],
  'count': count,
  'targetType': 'post',
  'targetId': '019a9000-0000-7000-8000-${index.toString().padLeft(12, '0')}',
  'createdAt': now
      .subtract(Duration(minutes: index + 2, days: yesterday ? 1 : 0))
      .toUtc()
      .toIso8601String(),
  if (read) 'readAt': now.toUtc().toIso8601String(),
  'text': 'Person $index shared an update with you.',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<void> host(
    WidgetTester tester,
    AsyncValue<List<Map<String, dynamic>>> activity, {
    Size size = const Size(390, 844),
    double scale = 1,
    bool dark = true,
    bool reduced = false,
    GlobalKey? capture,
    VoidCallback? onRetry,
    Future<void> Function()? onRefresh,
    VoidCallback? Function(Map<String, dynamic>)? open,
    markRead,
    dismiss,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
            padding: const EdgeInsets.only(bottom: 34),
          ),
          child: RepaintBoundary(
            key: capture,
            child: Scaffold(
              body: ActivityView(
                activity: activity,
                now: now,
                onSettings: () {},
                onExplore: () {},
                onRetry: onRetry,
                onRefresh: onRefresh,
                openNotification: open,
                markRead: markRead,
                dismiss: dismiss,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Activity route with no notifications shows the caught-up state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(FakeApi()),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    final capture = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: capture, child: const HiyallApp()),
      ),
    );
    container.read(routerProvider).go('/notifications');
    await tester.pumpAndSettle();
    for (final dark in [true, false]) {
      container.read(themeProvider.notifier).toggle(dark);
      await tester.pumpAndSettle();
      expect(find.text('All caught up.'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Social'), findsNothing);
      expect(find.text('Mentions'), findsNothing);
      expect(find.textContaining('COMING SOON'), findsNothing);
      expect(find.text('Your kind of updates.'), findsNothing);
      expect(find.text('A quieter frequency.'), findsNothing);
      // Pull to refresh fetches from the server now that the feed is wired.
      expect(find.byType(RefreshIndicator), findsOneWidget);
      final destination = tester.widget<DockDestination>(
        find.widgetWithText(DockDestination, 'Activity'),
      );
      expect(destination.selected, isTrue);
      if (const bool.fromEnvironment('CAPTURE_ACTIVITY')) {
        void repaint(RenderObject node) {
          node.markNeedsPaint();
          node.visitChildren(repaint);
        }

        repaint(capture.currentContext!.findRenderObject()!);
        await tester.pump();
        await tester.runAsync(() async {
          final img =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.runtime/activity-previews/empty-${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          img.dispose();
        });
      }
    }
    await tester.tap(find.text('Find your people'));
    await tester.pumpAndSettle();
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/discover',
    );
    container.read(routerProvider).go('/notifications');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Activity visibility'));
    await tester.pumpAndSettle();
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/profile/settings',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Activity layouts fit phones, the user viewport, desktop and double text',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final records = List.generate(
        10,
        (index) =>
            notification(index, type: index.isEven ? 'follow' : 'comment'),
      );
      for (final size in [
        const Size(320, 740),
        const Size(390, 844),
        const Size(430, 932),
        const Size(679, 1314),
        const Size(1440, 1000),
      ]) {
        for (final scale in [1.0, 2.0]) {
          for (final dark in [true, false]) {
            for (final activity in [
              const AsyncData(<Map<String, dynamic>>[]),
              const AsyncLoading<List<Map<String, dynamic>>>(),
              AsyncError<List<Map<String, dynamic>>>(
                Exception('secret stack trace 500'),
                StackTrace.current,
              ),
              AsyncData(records),
            ]) {
              await host(
                tester,
                activity,
                size: size,
                scale: scale,
                dark: dark,
                onRetry: () {},
              );
              expect(
                tester.takeException(),
                isNull,
                reason: '$size $scale $dark $activity',
              );
              expect(find.textContaining('secret stack trace'), findsNothing);
              await tester.drag(
                find.byType(CustomScrollView),
                const Offset(0, -450),
              );
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: 'Scrolled $size $scale $dark',
              );
            }
          }
        }
      }
    },
  );

  testWidgets(
    'Populated list filters actual types and preserves record text, grouping and read state',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final records = [
        notification(1, type: 'comment', count: 4),
        notification(2, type: 'follow', read: true, yesterday: true),
      ];
      final before = jsonEncode(records);
      Map<String, dynamic>? opened;
      final capture = GlobalKey();
      await host(
        tester,
        AsyncData(records),
        capture: capture,
        open: (record) =>
            () => opened = record,
      );
      if (const bool.fromEnvironment('CAPTURE_ACTIVITY')) {
        void repaint(RenderObject node) {
          node.markNeedsPaint();
          node.visitChildren(repaint);
        }

        repaint(capture.currentContext!.findRenderObject()!);
        await tester.pump();
        await tester.runAsync(() async {
          final img =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.runtime/activity-previews/test-contract-list-dark.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          img.dispose();
        });
      }
      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('YESTERDAY'), findsOneWidget);
      expect(find.text('4 updates'), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
      expect(find.text('Person 1 shared an update with you.'), findsOneWidget);
      expect(find.text('System'), findsNothing);
      expect(find.text('Messages'), findsNothing);
      expect(find.text('Mentions'), findsNothing);
      expect(find.byTooltip('Activity actions'), findsNothing);
      await tester.tap(find.text('Person 1 shared an update with you.'));
      expect(identical(opened, records.first), isTrue);
      await tester.tap(find.text('Connections'));
      await tester.pumpAndSettle();
      expect(find.text('Person 1 shared an update with you.'), findsNothing);
      expect(find.text('Person 2 shared an update with you.'), findsOneWidget);
      expect(jsonEncode(records), before);
    },
  );

  testWidgets(
    '100+ notifications render lazily and keep the header accessible',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final records = List.generate(125, (i) => notification(i));
      await host(tester, AsyncData(records));
      expect(find.text('Person 124 shared an update with you.'), findsNothing);
      expect(
        find.textContaining('shared an update').evaluate().length,
        lessThan(20),
      );
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Person 124 shared an update with you.'),
        1600,
        scrollable: scrollable,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Loading and failures remain separate from empty and do not reveal diagnostics',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await host(tester, const AsyncLoading());
      expect(find.text('All caught up.'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      var retried = false;
      await host(
        tester,
        AsyncError(Exception('500 database secrets'), StackTrace.current),
        onRetry: () => retried = true,
      );
      expect(find.text('Something went sideways.'), findsOneWidget);
      expect(find.text('All caught up.'), findsNothing);
      expect(find.textContaining('database secrets'), findsNothing);
      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);
    },
  );

  testWidgets(
    'Accessible actions call supplied handlers without fabricating read or dismissal state',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final record = notification(7);
      var read = false, dismissed = false;
      await host(
        tester,
        AsyncData([record]),
        markRead: (_) =>
            () => read = true,
        dismiss: (_) =>
            () => dismissed = true,
      );
      await tester.tap(find.byTooltip('Activity actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as read'));
      await tester.pumpAndSettle();
      expect(read, isTrue);
      expect(record.containsKey('readAt'), isFalse);
      expect(find.text('New'), findsOneWidget);
      await tester.tap(find.byTooltip('Activity actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(dismissed, isTrue);
      expect(find.text('Person 7 shared an update with you.'), findsOneWidget);
    },
  );

  testWidgets(
    'Pull refresh delegates only when supplied and reduced motion settles after completion',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final completer = Completer<void>();
      var calls = 0;
      await host(
        tester,
        const AsyncData([]),
        reduced: true,
        onRefresh: () {
          calls++;
          return completer.future;
        },
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      completer.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Activity loads server notifications and answers requests', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = FakeApi()
      ..activity = [
        {
          'notificationId': '019a4000-0000-7000-8000-00000000a001',
          'type': 'friend_request',
          'event': 'friend.requested',
          'actors': [
            {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
          ],
          'count': 1,
          'targetType': 'request',
          'targetId': '019a4000-0000-7000-8000-00000000f001',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'text': 'Niko sent you a friend request',
        },
        {
          'notificationId': '019a4000-0000-7000-8000-00000000a002',
          'type': 'follow',
          'event': 'follow.started',
          'actors': [
            {'userId': anjaliId, 'username': 'anjali', 'displayName': 'A'},
          ],
          'count': 1,
          'targetType': 'profile',
          'targetId': anjaliId,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'readAt': DateTime.now().toUtc().toIso8601String(),
          'text': 'A started following you',
        },
      ];
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const HiyallApp()),
    );
    container.read(routerProvider).go('/notifications');
    await tester.pumpAndSettle();

    expect(find.text('Niko sent you a friend request'), findsOneWidget);
    expect(find.text('A started following you'), findsOneWidget);
    // One unread item: the dock shows new activity and the bell counts it.
    expect(
      tester
          .widget<DockDestination>(
            find.widgetWithText(DockDestination, 'Activity'),
          )
          .activityDot,
      isTrue,
    );
    expect(find.byTooltip('Open notifications, 1 unread'), findsOneWidget);
    // Only the open request offers Accept/Decline.
    expect(find.text('Accept'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(api.calls, ['friend 019a4000-0000-7000-8000-00000000f001 true']);
    expect(find.text('Niko sent you a friend request'), findsNothing);
    expect(find.byTooltip('Open notifications'), findsOneWidget);
  });

  testWidgets(
    'More than 99 unread shows 99+ on the bell and keeps it past a read',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final api = FakeApi()
        ..unreadMore = true
        ..activity = [for (var i = 0; i < 99; i++) notification(i)];
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(SignedIn.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      container.read(routerProvider).go('/notifications');
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open notifications, 99+ unread'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
      expect(find.text('100'), findsNothing);
      // One read here: the real count is still above 99, so the badge holds.
      await container
          .read(activityProvider.notifier)
          .markRead(api.activity.first['notificationId'] as String);
      await tester.pump();
      expect(find.byTooltip('Open notifications, 99+ unread'), findsOneWidget);
      // Reading everything clears it.
      api.unreadMore = false;
      await container.read(activityProvider.notifier).markAllRead();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Open notifications'), findsOneWidget);
      expect(
        container.read(activityProvider).asData!.value.unreadMore,
        isFalse,
      );
    },
  );
}
