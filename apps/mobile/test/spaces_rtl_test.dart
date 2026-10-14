import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/app_info.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/spaces.dart';

import 'space_screen_test.dart' show LiveSpace;
import 'spaces_test.dart' show SpacesFake, circle;
import 'widget_test.dart' show SignedIn;

Future<void> pumpRtl(WidgetTester t, SpacesFake a, Widget child) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(a),
        sessionProvider.overrideWith(SignedIn.new),
      ],
      child: MaterialApp(
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: child,
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  setUp(() => FeatureFlags.eventsOverride = true);
  tearDown(() => FeatureFlags.eventsOverride = null);

  double mid(WidgetTester t) =>
      t.view.physicalSize.width / t.view.devicePixelRatio / 2;

  testWidgets('Spaces list mirrors: emblem and create button flip sides', (
    t,
  ) async {
    await pumpRtl(t, SpacesFake(), const SpacesScreen());
    expect(t.takeException(), isNull);
    expect(t.getCenter(find.byType(SpaceEmblem)).dx, greaterThan(mid(t)));
    expect(
      t.getCenter(find.byKey(const Key('new-space'))).dx,
      lessThan(mid(t)),
    );
  });

  testWidgets('Space page mirrors: menu on the left, entries lead right', (
    t,
  ) async {
    await pumpRtl(t, LiveSpace(), const SpaceScreen(id: 'circle'));
    expect(t.takeException(), isNull);
    expect(
      t.getCenter(find.byKey(const Key('space-menu'))).dx,
      lessThan(mid(t)),
    );
    expect(t.getCenter(find.byType(SpaceEmblem)).dx, greaterThan(mid(t)));
    await t.scrollUntilVisible(
      find.text('Newest thought'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(t.takeException(), isNull);
    expect(
      t.getTopLeft(find.text('Newest thought')).dx,
      greaterThan(mid(t) / 2),
    );
    await t.tap(find.byKey(const Key('space-tab-members')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('Participants and create form lay out in RTL', (t) async {
    final a = SpacesFake()..current = circle(state: 'active', role: 'owner');
    await pumpRtl(t, a, const SpaceMembersScreen(id: 'circle'));
    expect(t.takeException(), isNull);
    expect(find.text('Anjali'), findsOneWidget);
    expect(
      t.getCenter(find.text('Invite someone')).dx,
      greaterThan(mid(t) / 2),
    );
    await pumpRtl(t, a, const CreateSpaceScreen());
    expect(t.takeException(), isNull);
    expect(t.getCenter(find.byKey(const Key('space-title'))).dx, mid(t));
  });
}
