import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/people_filters.dart';
import 'package:hiyall/features/people_lists.dart';
import 'package:hiyall/shared/person_avatar.dart';

import 'people_lists_test.dart' show ListsApi, ravi, mira;
import 'widget_test.dart' show SignedIn;

/// The screen under a right-to-left [Directionality], as an Arabic or Hebrew
/// phone would show it.
Future<void> pumpRtl(
  WidgetTester tester,
  Widget screen, {
  ListsApi? api,
  bool rtl = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api ?? ListsApi()),
        sessionProvider.overrideWith(SignedIn.new),
      ],
      child: MaterialApp(
        builder: (context, child) => Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: child!,
        ),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double centerX(WidgetTester tester, Finder finder) =>
    tester.getCenter(finder).dx;

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

  testWidgets('Following list mirrors: back button right, row actions right', (
    tester,
  ) async {
    await pumpRtl(tester, const ConnectionsScreen(kind: 'following'));
    expect(tester.takeException(), isNull);
    expect(
      centerX(tester, find.byKey(const Key('list-back'))),
      greaterThan(195),
    );
    // The action line starts at the start edge, which is the right in RTL.
    expect(
      centerX(tester, find.byKey(Key('message-${mira.userId}'))),
      greaterThan(195),
    );
  });

  testWidgets('Same screen in LTR keeps the back button on the left', (
    tester,
  ) async {
    await pumpRtl(
      tester,
      const ConnectionsScreen(kind: 'following'),
      rtl: false,
    );
    expect(centerX(tester, find.byKey(const Key('list-back'))), lessThan(195));
    expect(
      centerX(tester, find.byKey(Key('message-${mira.userId}'))),
      lessThan(195),
    );
  });

  testWidgets('Visitors list mirrors: the menu sits on the left', (
    tester,
  ) async {
    await pumpRtl(tester, const VisitorsScreen());
    expect(tester.takeException(), isNull);
    expect(
      centerX(tester, find.byKey(Key('visitor-menu-${ravi.userId}'))),
      lessThan(195),
    );
    expect(centerX(tester, find.byType(PersonAvatar).first), greaterThan(195));
  });

  testWidgets('My stories mirrors: delete button on the left', (tester) async {
    await pumpRtl(tester, const MyStoriesScreen());
    expect(tester.takeException(), isNull);
    expect(
      centerX(tester, find.byKey(const Key('story-delete-s1'))),
      lessThan(195),
    );
  });

  testWidgets('Filter sheet mirrors: close button on the left', (tester) async {
    await pumpRtl(
      tester,
      PeopleFilterScreen(
        initial: PeopleFilters(interests: ['Music'], languages: ['en']),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(centerX(tester, find.byTooltip('Close filters')), lessThan(195));
    expect(
      centerX(tester, find.byKey(const Key('filter-sheet-count'))),
      greaterThan(195),
    );
  });
}
