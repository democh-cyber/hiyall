import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/story_draft.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/story_composer.dart';

import 'pulse_test.dart' as pt;
import 'widget_test.dart' show SignedIn;

Future<void> open(WidgetTester tester, TextDirection direction) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(pt.PulseApi()),
        sessionProvider.overrideWith(SignedIn.new),
        storyDraftStoreProvider.overrideWithValue(MemoryStoryDraftStore()),
      ],
      child: MaterialApp(
        theme: hiyallTheme(Brightness.dark),
        builder: (context, child) =>
            Directionality(textDirection: direction, child: child!),
        home: const StoryComposerScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final direction in TextDirection.values) {
    final rtl = direction == TextDirection.rtl;
    testWidgets('story composer lays out for $direction without overflow', (
      tester,
    ) async {
      await open(tester, direction);
      expect(tester.takeException(), isNull);
      final mid = 390 / 2;
      final close = tester.getCenter(find.byKey(const Key('story-close'))).dx;
      final share = tester.getCenter(find.byKey(const Key('share-story'))).dx;
      // Close leads the top bar and Share trails it, whichever way the text runs.
      expect(close < mid, !rtl);
      expect(share > mid, !rtl);
      // The first tab sits at the start edge.
      final first = tester.getCenter(find.byKey(const Key('tool-colour'))).dx;
      final last = tester.getCenter(find.byKey(const Key('tool-who'))).dx;
      expect(first < last, !rtl);
      // Opening a panel changes nothing about the layout direction.
      await tester.ensureVisible(find.byKey(const Key('tool-time')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tool-time')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hours-hint')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
