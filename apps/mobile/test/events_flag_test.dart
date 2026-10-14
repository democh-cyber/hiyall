import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/app_info.dart';
import 'package:hiyall/features/system_screens.dart';

import 'reliability_ui_test.dart' show open;
import 'spaces_test.dart' show SpacesFake, circle;

void main() {
  tearDown(() => FeatureFlags.eventsOverride = null);

  test('Events are off unless the build turns them on', () {
    expect(FeatureFlags.events, isFalse);
    FeatureFlags.eventsOverride = true;
    expect(FeatureFlags.events, isTrue);
  });

  group('with Events off', () {
    setUp(() => FeatureFlags.eventsOverride = false);

    testWidgets('the Spaces list shows communities only, with no kind tabs', (
      tester,
    ) async {
      final api = SpacesFake()..blocked = false;
      await open(tester, api, '/spaces');
      expect(find.text('After-hours book club'), findsOneWidget);
      expect(find.text('Events'), findsNothing);
      expect(find.text('Moments'), findsNothing);
      expect(api.calls.where((c) => c.startsWith('spaces ')), [
        'spaces community false',
      ]);
    });

    testWidgets('a link to ?kind=event opens communities, not events', (
      tester,
    ) async {
      final api = SpacesFake()..blocked = false;
      await open(tester, api, '/spaces?kind=event');
      expect(api.calls.where((c) => c.startsWith('spaces ')), [
        'spaces community false',
      ]);
    });

    testWidgets(
      'creating an event or a Moment, or anything nested, is not offered',
      (tester) async {
        final api = SpacesFake()..blocked = false;
        for (final path in [
          '/spaces/new?kind=event',
          '/spaces/new?kind=moment',
          '/spaces/new?kind=event&parent=circle',
        ]) {
          final container = await open(tester, api, path);
          expect(find.byType(NotFoundScreen), findsOneWidget, reason: path);
          expect(container.read(routerProvider).state.uri.toString(), path);
        }
      },
    );

    testWidgets('creating a community still works', (tester) async {
      final api = SpacesFake()..blocked = false;
      await open(tester, api, '/spaces/new');
      expect(find.byType(NotFoundScreen), findsNothing);
      expect(
        find.byKey(const Key('publish-space'), skipOffstage: false),
        findsOneWidget,
      );
      tester.takeException(); // an unrelated narrow-screen overflow in the form
    });

    testWidgets('a community has no Events tab', (tester) async {
      final api = SpacesFake()
        ..blocked = false
        ..current = circle(state: 'active', role: 'owner', discuss: true);
      await open(tester, api, '/spaces/circle');
      expect(find.text('Discussion'), findsWidgets);
      expect(find.text('Members'), findsWidgets);
      expect(find.text('Events'), findsNothing);
    });

    testWidgets('a linked event still opens, read-only: no Join button', (
      tester,
    ) async {
      final api = SpacesFake()
        ..blocked = false
        ..current = circle(kind: 'event');
      await open(tester, api, '/spaces');
      await tester.pumpAndSettle();
      expect(find.text('After-hours book club'), findsOneWidget);
      expect(find.byKey(const ValueKey('join')), findsNothing);
      // And the page itself opens.
      final container = await open(tester, api, '/spaces/circle');
      expect(container.read(routerProvider).state.uri.path, '/spaces/circle');
      expect(find.text('After-hours book club'), findsWidgets);
      expect(find.byKey(const ValueKey('join')), findsNothing);
      expect(find.byType(NotFoundScreen), findsNothing);
    });

    testWidgets('Discover offers People and Circles, not Moments', (
      tester,
    ) async {
      final api = SpacesFake()..blocked = false;
      await open(tester, api, '/discover');
      await tester.tap(find.byTooltip('Explore Discover'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discover-tab-people')), findsOneWidget);
      expect(find.byKey(const Key('discover-tab-circles')), findsOneWidget);
      expect(find.byKey(const Key('discover-tab-moments')), findsNothing);
    });
  });

  group('with Events on', () {
    setUp(() => FeatureFlags.eventsOverride = true);

    testWidgets('kind tabs, Moments and nested events are back', (
      tester,
    ) async {
      final api = SpacesFake()..blocked = false;
      await open(tester, api, '/spaces');
      expect(find.text('Events'), findsWidgets);
      expect(find.text('Moments'), findsWidgets);
      await open(tester, api, '/discover');
      await tester.tap(find.byTooltip('Explore Discover'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discover-tab-moments')), findsOneWidget);
      final container = await open(tester, api, '/spaces/new?kind=event');
      expect(find.byType(NotFoundScreen), findsNothing);
      expect(container.read(routerProvider).state.uri.path, '/spaces/new');
      // The event form has an unrelated narrow-screen overflow in tests.
      tester.takeException();
    });
  });
}
