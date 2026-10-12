import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/screens.dart';

import 'spaces_test.dart' show SpacesFake, circle;
import 'widget_test.dart' show SignedIn;

Future<GoRouter> launchApp(WidgetTester tester, SpacesFake api) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
  await tester.pumpAndSettle();
  return container.read(routerProvider);
}

SpacesFake joinedSpace() => SpacesFake()
  ..blocked = false
  ..current = circle(state: 'active', discuss: true)
  ..notes.add(
    SpaceEntry(
      'e1',
      'Chapter three tonight',
      const Person(nikoId, 'niko', 'Niko'),
      DateTime.now(),
      false,
    ),
  );

void main() {
  testWidgets('A member opened inside a space returns to the space', (
    tester,
  ) async {
    final router = await launchApp(tester, joinedSpace());
    router.push('/spaces/circle');
    await tester.pumpAndSettle();
    expect(find.text('Chapter three tonight'), findsOneWidget);
    final author = find.text('Niko').hitTestable();
    await tester.tap(author.first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(router.state.uri.path, '/person/$nikoId');
    expect(find.byType(PersonScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/spaces/circle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Docked profile links still open inside Discover', (
    tester,
  ) async {
    final router = await launchApp(tester, SpacesFake()..blocked = false);
    router.go('/discover/person/$nikoId');
    await tester.pumpAndSettle();
    expect(find.byType(PersonScreen), findsOneWidget);
    // Opened directly, so back has nowhere to pop to but Discover.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/discover');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back from a profile opened from Activity returns to it', (
    tester,
  ) async {
    final api = SpacesFake()
      ..blocked = false
      ..activity = [
        {
          'notificationId': 'n1',
          'type': 'follow',
          'actors': [
            {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
          ],
          'count': 1,
          'targetType': 'user',
          'targetId': nikoId,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'readAt': DateTime.now().toUtc().toIso8601String(),
          'text': 'Niko followed you.',
        },
      ];
    final router = await launchApp(tester, api);
    router.go('/notifications');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Niko followed you.'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/discover/person/$nikoId');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/notifications');
    expect(tester.takeException(), isNull);
  });
}
