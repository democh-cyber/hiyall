import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/features/discover_person.dart';
import 'package:hiyall/features/screens.dart' show PersonScreen;
import 'package:hiyall/features/say_hi_ui.dart' show SayHiProfileButton;
import 'package:hiyall/shared/press_scale.dart';

import 'discover_helpers.dart';
import 'say_hi_test.dart' show confirmedStore, mount, pathOf;
import 'support/fixtures.dart';

/// Every background colour and border painted inside [of], as a comparable list.
List<String> paints(WidgetTester tester, Finder of) => [
  for (final w in tester.widgetList<DecoratedBox>(
    find.descendant(of: of, matching: find.byType(DecoratedBox)),
  ))
    '${(w.decoration as BoxDecoration).color}|${(w.decoration as BoxDecoration).border}|${(w.decoration as BoxDecoration).boxShadow}',
];

Finder inProfile(String id) => find.descendant(
  of: find.byType(PersonScreen),
  matching: find.byKey(Key('say-hi-$id')),
);

void main() {
  group('Discover row feedback', () {
    testWidgets(
      'a mouse hovering or pressing a row paints no block, tint or shadow',
      (tester) async {
        await mount(tester, store: confirmedStore());
        final row = find.byKey(const Key('person-mira'));
        final before = paints(tester, row);
        // No stock Material hover/press layer: no ink, no extra animated fill.
        expect(
          find.descendant(of: row, matching: find.byType(AnimatedContainer)),
          findsNothing,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(row));
        await tester.pumpAndSettle();
        expect(paints(tester, row), before, reason: 'hovered');
        expect(
          find.descendant(of: row, matching: find.byType(AnimatedContainer)),
          findsNothing,
        );
        // The cursor over a row is the pointer.
        expect(
          tester
              .widget<MouseRegion>(
                find
                    .descendant(of: row, matching: find.byType(MouseRegion))
                    .first,
              )
              .cursor,
          SystemMouseCursors.click,
        );
        await mouse.down(tester.getCenter(row));
        await tester.pump(const Duration(milliseconds: 200));
        expect(paints(tester, row), before, reason: 'pressed');
        // Pressing still scales the row a little.
        final scale = tester.widget<AnimatedScale>(
          find.descendant(of: row, matching: find.byType(AnimatedScale)),
        );
        expect(scale.scale, .98);
        await mouse.up();
        await tester.pumpAndSettle();
        // The tap still opened the profile.
        expect(find.byType(PersonScreen), findsOneWidget);
      },
    );

    testWidgets('the Say hi control paints no hover block either', (
      tester,
    ) async {
      await mount(tester, store: confirmedStore());
      // The tooltip that hover raises is an overlay, not part of the control.
      final hi = find.descendant(
        of: find.byKey(const Key('say-hi-mira')),
        matching: find.byType(PressScale),
      );
      final before = paints(tester, hi);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(hi));
      await tester.pumpAndSettle();
      expect(paints(tester, hi), before);
    });

    testWidgets('keyboard focus shows a thin ring, a mouse click does not', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PressScale(
                key: const Key('target'),
                onTap: () => taps++,
                semanticLabel: 'Target',
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        ),
      );
      Color ring() {
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('target')),
            matching: find.byType(DecoratedBox),
          ),
        );
        return (box.decoration as BoxDecoration).border!.top.color;
      }

      // A click focuses it, but that is not keyboard focus: no ring.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('target'))));
      await mouse.down(tester.getCenter(find.byKey(const Key('target'))));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(ring().a, 0);
      // Tabbing in is: a thin outline, not a fill.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ring().a, greaterThan(0));
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(const Key('target')),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect((box.decoration as BoxDecoration).color, isNull);
      expect((box.decoration as BoxDecoration).border!.top.width, 1.5);
    });
  });

  group('Say hi control', () {
    testWidgets(
      'has no word, keeps its name for screen readers, and is the outlined wave square',
      (tester) async {
        final handle = tester.ensureSemantics();
        await mount(tester, store: confirmedStore());
        expect(find.text('Say hi'), findsNothing);
        expect(find.bySemanticsLabel('Say hi to Mira Kapoor'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('say-hi-mira')),
            matching: find.byIcon(Icons.waving_hand_rounded),
          ),
          findsOneWidget,
        );
        handle.dispose();
      },
    );
  });

  group('profile wave', () {
    Future<ProviderContainer> openProfile(
      WidgetTester tester,
      HiLog hi, {
      bool chat = true,
      String id = 'mira',
    }) async {
      final container = await mount(tester, hi: hi, chat: chat);
      container.read(routerProvider).go('/discover/person/$id');
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('sends one wave from the profile and shows it sent', (
      tester,
    ) async {
      final hi = HiLog();
      final container = await openProfile(tester, hi);
      expect(pathOf(container), '/discover/person/mira');
      expect(inProfile('mira'), findsOneWidget);
      expect(find.byKey(const Key('message-person')), findsOneWidget);
      expect(
        tester.getSize(inProfile('mira')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(inProfile('mira'));
      await tester.pumpAndSettle();
      expect(hi.sent, [('conv-1', 'mira', '👋')]);
      expect(
        tester.widget<SayHiButton>(inProfile('mira')).state,
        SayHiState.done,
      );
      // A second tap sends nothing more, and the profile stays open.
      await tester.tap(inProfile('mira'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(hi.sent, hasLength(1));
      expect(pathOf(container), '/discover/person/mira');
      expect(find.text('👋 sent to Mira Kapoor'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('is hidden on the web (no chat)', (tester) async {
      await openProfile(tester, HiLog(), chat: false);
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(find.byKey(const Key('message-person')), findsOneWidget);
      expect(inProfile('mira'), findsNothing);
      expect(find.byType(SayHiProfileButton), findsOneWidget);
    });

    testWidgets('is hidden on your own profile', (tester) async {
      await openProfile(tester, HiLog(), id: anjaliId);
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(inProfile(anjaliId), findsNothing);
    });
  });
}
