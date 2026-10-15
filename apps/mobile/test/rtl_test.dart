import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/help_safety.dart' show HelpContacts;

import 'discover_helpers.dart';
import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

/// Right-to-left layouts. The app has no RTL language yet; the direction is
/// forced through [textDirectionOverrideProvider] so the day one is added the
/// screens already mirror.
Future<ProviderContainer> open(
  WidgetTester tester,
  FakeApi api,
  String at, {
  required TextDirection direction,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      textDirectionOverrideProvider.overrideWithValue(direction),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
  );
  container.read(routerProvider).go(at);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  const width = 390.0;

  group('Home header', () {
    for (final (direction, logoOnLeft) in [
      (TextDirection.ltr, true),
      (TextDirection.rtl, false),
    ]) {
      testWidgets('$direction: the logo starts the bar, the bell ends it', (
        tester,
      ) async {
        await open(tester, FakeApi(), '/home', direction: direction);
        expect(tester.takeException(), isNull);
        final logo = tester.getCenter(find.text('hiyall').first).dx;
        final bell = tester.getCenter(find.byTooltip('Open notifications')).dx;
        expect(logo < bell, logoOnLeft, reason: 'logo $logo, bell $bell');
        expect(logo < width / 2, logoOnLeft);
      });
    }
  });

  group('Settings list', () {
    for (final (direction, iconOnLeft) in [
      (TextDirection.ltr, true),
      (TextDirection.rtl, false),
    ]) {
      testWidgets('$direction: rows lead with their icon on the start side', (
        tester,
      ) async {
        await open(
          tester,
          FakeApi(),
          '/profile/settings',
          direction: direction,
        );
        expect(tester.takeException(), isNull);
        final row = find.byType(ListTile).first;
        final tile = tester.getRect(row);
        final icon = tester.getCenter(
          find.descendant(of: row, matching: find.byType(Icon)).first,
        );
        expect(icon.dx < tile.center.dx, iconOnLeft);
        final title = tester.getRect(
          find.descendant(of: row, matching: find.byType(Text)).first,
        );
        // The text sits next to the icon, not across the row from it.
        expect((title.center.dx - icon.dx).abs() < tile.width / 2, isTrue);
      });
    }
  });

  group('Help & Safety', () {
    setUp(() => HelpContacts.showPlaceholders = true);
    tearDown(() => HelpContacts.showPlaceholders = false);
    for (final (direction, backOnLeft) in [
      (TextDirection.ltr, true),
      (TextDirection.rtl, false),
    ]) {
      testWidgets('$direction: Back sits at the start, rows do not overflow', (
        tester,
      ) async {
        await open(tester, FakeApi(), '/profile/help', direction: direction);
        expect(tester.takeException(), isNull);
        final back = tester.getCenter(find.text('Back')).dx;
        expect(back < width / 2, backOnLeft);
        final contact = tester.getRect(
          find.byKey(const Key('help-contact-Safety concerns')),
        );
        expect(contact.left >= 0 && contact.right <= width, isTrue);
      });
    }
  });

  group('Discover row', () {
    for (final (direction, avatarOnLeft) in [
      (TextDirection.ltr, true),
      (TextDirection.rtl, false),
    ]) {
      testWidgets('$direction: the avatar starts the row', (tester) async {
        final api = DiscoverFake(
          people: [person(nikoId, 'Niko', headline: 'Climber', online: true)],
        );
        await mountDiscover(
          tester,
          api,
          extra: [textDirectionOverrideProvider.overrideWithValue(direction)],
        );
        expect(tester.takeException(), isNull);
        final row = tester.getRect(find.byKey(const Key('person-$nikoId')));
        final name = tester.getRect(find.text('Niko').first);
        // The name starts on the start side of the row, so it is nearer that edge.
        final nearStart = direction == TextDirection.ltr
            ? name.left - row.left < row.right - name.right
            : row.right - name.right < name.left - row.left;
        expect(nearStart, isTrue, reason: 'row $row, name $name');
        expect(name.center.dx < row.center.dx, avatarOnLeft);
      });
    }
  });
}
