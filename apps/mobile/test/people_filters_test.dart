import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/people_filters.dart';

import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

class DiscoveryTestApi extends FakeApi {
  final queries = <Map<String, dynamic>>[];
  ApiFailure? failure;
  List<Map<String, dynamic>> items = [];
  String? next;
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async {
    queries.add(Map.from(filters));
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    return {'items': items, 'nextCursor': next};
  }
}

class DenseDiscoveryApi extends DiscoveryTestApi {
  @override
  Future<Profile> profile(Session s) async => const Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: '',
    profession: '',
    version: '1',
    interests: [
      'Music',
      'Photography',
      'Learning',
      'Books',
      'Food',
      'Travel',
      'Art',
      'Tech',
      'Movies',
      'Gaming',
    ],
    languages: [
      ProfileLanguage('en'),
      ProfileLanguage('hi'),
      ProfileLanguage('ko'),
      ProfileLanguage('ja'),
      ProfileLanguage('es'),
      ProfileLanguage('fr'),
      ProfileLanguage('de'),
      ProfileLanguage('it'),
      ProfileLanguage('pt'),
    ],
    currentVibe: 'Reading and making things after midnight',
  );
}

void main() {
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

  final appCapture = GlobalKey();

  Future<ProviderContainer> launch(
    WidgetTester tester,
    DiscoveryTestApi api,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        child: RepaintBoundary(key: appCapture, child: const HiyallApp()),
      ),
    );
    // Home asks for a few suggestions; count only what Discover sends.
    await tester.pumpAndSettle();
    api.queries.clear();
    container.read(routerProvider).go('/people');
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> captureApplied(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_APPLIED_FILTERS')) return;
    void repaint(RenderObject render) {
      render.markNeedsPaint();
      render.visitChildren(repaint);
    }

    repaint(appCapture.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final image =
          await (appCapture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.runtime/filter-previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      350,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('filter-content')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openFilters(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Filter people'));
    await tester.pumpAndSettle();
  }

  Future<void> showPeople(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Show people'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseLanguage(
    WidgetTester tester,
    String language, {
    int selectedCount = 1,
  }) async {
    final picker = find.text('Choose languages');
    await reveal(tester, picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), language);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, language));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(
        'Use $selectedCount ${selectedCount == 1 ? 'language' : 'languages'}',
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Discover opens on everyone; filters apply only on explicit search',
    (tester) async {
      final api = DiscoveryTestApi();
      await launch(tester, api);
      expect(api.queries, hasLength(1));
      expect(api.queries.single['interests'], isEmpty);
      await openFilters(tester);
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('filter-content')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(1));
      await openFilters(tester);
      expect(find.text('1 selected'), findsNothing);
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.queries, hasLength(2));
      expect(api.queries.last['interests'], ['Music']);
      expect(find.text('No one here just yet.'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      await openFilters(tester);
      await reveal(tester, find.text('1 selected'));
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('clear-active-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(2));
      await openFilters(tester);
      await reveal(tester, find.text('1 selected'));
      expect(find.text('1 selected'), findsOneWidget);
      expect(api.saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Searchable pickers send real country and language codes, not display labels',
    (tester) async {
      final api = DiscoveryTestApi();
      await launch(tester, api);
      await openFilters(tester);
      await tester.tap(find.text('Choose country'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'India');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'India'));
      await tester.pumpAndSettle();
      await chooseLanguage(tester, 'Korean');
      await chooseLanguage(tester, 'Hindi', selectedCount: 2);
      expect(find.text('Korean · Hindi'), findsOneWidget);
      await showPeople(tester);
      expect(api.queries.last['languages'], containsAll(['ko', 'hi']));
      expect(api.queries.last['country'], 'IN');
      expect(
        api.queries.last.keys,
        unorderedEquals(['interests', 'languages', 'country', 'vibe']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Real pages show field-backed explanations and reuse filters for pagination',
    (tester) async {
      final api = DiscoveryTestApi();
      await launch(tester, api);
      api
        ..items = [
          {
            'userId': nikoId,
            'username': 'niko',
            'displayName': 'Niko',
            'headline': 'A real test fixture',
            'interests': ['Music'],
          },
        ]
        ..next = 'opaque-server-cursor';
      await openFilters(tester);
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      // The row's own context line and the active-filter chip under the categories.
      expect(find.text('Music'), findsNWidgets(2));
      expect(
        find.byKey(const Key('active-filter-interest-Music')),
        findsOneWidget,
      );
      expect(find.textContaining('% match'), findsNothing);
      api.items = [
        {
          'userId': '019a4000-0000-7000-8000-000000000003',
          'username': 'test_person',
          'displayName': 'Another test person',
          'interests': ['Music'],
        },
      ];
      api.next = null;
      final more = find.text('Explore more people');
      await tester.scrollUntilVisible(
        more,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(api.queries.last['cursor'], 'opaque-server-cursor');
      expect(api.queries.last['interests'], ['Music']);
      expect(find.text('Another test person'), findsOneWidget);
      expect(find.text('Explore more people'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Refused searches never become an empty success or fabricated people',
    (tester) async {
      final api = DiscoveryTestApi()
        ..failure = const ApiFailure(
          'Your session has expired. Sign in again.',
          401,
        );
      await launch(tester, api);
      expect(
        find.text('Your session has expired. Sign in again.'),
        findsOneWidget,
      );
      expect(find.text('No one here just yet.'), findsNothing);
      expect(find.textContaining('people match'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Any language resets only languages and preserves the other draft choices',
    (tester) async {
      final api = DiscoveryTestApi();
      await launch(tester, api);
      await openFilters(tester);
      await chooseLanguage(tester, 'Korean');
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      // Back up to the language section.
      await tester.drag(
        find.byKey(const Key('filter-content')),
        const Offset(0, 1200),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Any language'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.queries.last['languages'], isEmpty);
      expect(api.queries.last['interests'], ['Music']);
      expect(api.saved, isNull);
    },
  );

  testWidgets(
    'Empty-result recovery clears temporary filters and uses the same search endpoint',
    (tester) async {
      final api = DiscoveryTestApi();
      await launch(tester, api);
      await openFilters(tester);
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(3));
      expect(api.queries.last['interests'], isEmpty);
      expect(find.text('Clear filters'), findsNothing);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(4));
      expect(api.queries.last['languages'], isEmpty);
      expect(api.saved, isNull);
    },
  );

  testWidgets(
    'Loading skeletons resolve to compact rows backed by supplied public details',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final api = DiscoveryTestApi()
        ..pending = Completer<Map<String, dynamic>>();
      await launch(tester, api);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.bySemanticsLabel('Finding people'), findsOneWidget);
      expect(find.text('No one here just yet.'), findsNothing);
      api.pending!.complete({
        'items': [
          {
            'userId': nikoId,
            'username': 'niko',
            'displayName': 'Niko',
            'headline': 'A quiet hello',
            'bio': 'Books and side quests.',
            'country': 'IN',
            'languages': [
              {'code': 'ko', 'level': 'conversational'},
            ],
            'interests': ['Music', 'Books'],
            'currentVibe': 'Chill',
          },
        ],
        'nextCursor': null,
      });
      await tester.pumpAndSettle();
      for (final visible in ['Niko', 'A quiet hello', 'Music · Books']) {
        expect(find.text(visible), findsOneWidget);
      }
      // Rows stay at two lines: the languages and the country badge are left
      // to the profile (the spoken label still says the languages).
      expect(find.text('IN'), findsNothing);
      expect(find.text('Korean · Conversational'), findsNothing);
      for (final spoken in [
        'Korean · Conversational',
        'Into Music, Books',
        'A quiet hello',
      ]) {
        expect(find.bySemanticsLabel(RegExp(RegExp.escape(spoken))), findsOne);
      }
      expect(find.text('Connect'), findsNothing);
      expect(find.text('Online now'), findsNothing);
      expect(find.textContaining('% match'), findsNothing);
      expect(find.bySemanticsLabel('Finding people'), findsNothing);
      await tester.tap(find.text('Niko'));
      await tester.pumpAndSettle();
      expect(find.text('This profile is unavailable.'), findsOneWidget);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A new search supersedes one still loading instead of being dropped',
    (tester) async {
      final api = DiscoveryTestApi()
        ..pending = Completer<Map<String, dynamic>>();
      await launch(tester, api);
      final slow = api.pending!;
      api.pending = null;
      await openFilters(tester);
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.queries, hasLength(2));
      expect(api.queries.last['interests'], ['Music']);
      slow.complete({
        'items': [
          {'userId': nikoId, 'username': 'niko', 'displayName': 'Stale'},
        ],
        'nextCursor': null,
      });
      await tester.pumpAndSettle();
      expect(find.text('Stale'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('filter-count'))).data,
        '1',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Connectivity failures remain truthful and retry preserves the applied filters',
    (tester) async {
      final api = DiscoveryTestApi()
        ..failure = const ApiFailure(
          'Could not connect. Check your connection and retry.',
        );
      await launch(tester, api);
      expect(find.text('Couldn’t connect.'), findsOneWidget);
      await openFilters(tester);
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(find.text('Couldn’t connect.'), findsOneWidget);
      expect(find.text('You’re offline.'), findsNothing);
      expect(find.text('No one here just yet.'), findsNothing);
      api.failure = null;
      await tester.tap(find.byKey(const Key('discovery-retry')));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(3));
      expect(api.queries.last['interests'], ['Music']);
      expect(find.text('Couldn’t connect.'), findsNothing);
      expect(find.text('No one here just yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'The chips stay pinned while scrolling, and the filter button counts and resets',
    (tester) async {
      final api = DiscoveryTestApi()
        ..items = List.generate(
          20,
          (i) => {
            'userId':
                '019a4000-0000-7000-8000-${(i + 2).toString().padLeft(12, '0')}',
            'username': 'test_person_$i',
            'displayName': 'Test person $i',
            'bio': 'Test-only result for scrolling.',
          },
        );
      final container = await launch(tester, api);
      await openFilters(tester);
      await tester.tap(find.text('Choose country'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'India');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'India'));
      await tester.pumpAndSettle();
      await chooseLanguage(tester, 'English');
      await reveal(tester, find.text('Music'));
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Chill'));
      await tester.tap(find.text('Chill').last);
      await tester.pumpAndSettle();
      await showPeople(tester);
      final count = find.byKey(const Key('filter-count'));
      expect(tester.widget<Text>(count).data, '4');
      for (final dark in [false, true]) {
        container.read(themeProvider.notifier).toggle(dark);
        await tester.pumpAndSettle();
        await captureApplied(
          tester,
          'applied-filters-test-${dark ? 'dark' : 'light'}',
        );
      }
      final chips = find.byKey(const Key('discover-chips'));
      final top = tester.getTopLeft(chips).dy;
      final scroll = find
          .descendant(
            of: find.byKey(const Key('discovery-results-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(scroll, const Offset(0, -1200));
      await tester.pumpAndSettle();
      // The Explore row has scrolled away; the chips are pinned at the top.
      expect(find.byKey(const Key('discover-filters')), findsNothing);
      expect(tester.getTopLeft(chips).dy, lessThan(top));
      expect(chips.hitTestable(), findsOneWidget);
      await tester.drag(scroll, const Offset(0, 1500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discover-reset')));
      await tester.pumpAndSettle();
      expect(api.queries.last['country'], '');
      expect(api.queries.last['interests'], isEmpty);
      expect(api.queries.last['languages'], isEmpty);
      expect(api.queries.last['vibe'], '');
      expect(count, findsNothing);
      expect(find.byKey(const Key('discover-reset')), findsNothing);
      expect(api.saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Chips and long selections stay reachable on small phones with doubled text',
    (tester) async {
      final api = DenseDiscoveryApi();
      final container = await launch(tester, api);
      tester.view.physicalSize = const Size(320, 740);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 740),
              textScaler: TextScaler.linear(2),
            ),
            child: RepaintBoundary(key: appCapture, child: const HiyallApp()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tab = find.byKey(const Key('chip-interests'));
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(api.queries.last['interests'], hasLength(10));
      // A category chip stands for itself: no filter count on the button.
      expect(find.byKey(const Key('filter-count')), findsNothing);
      await openFilters(tester);
      await reveal(tester, find.text('Chill'));
      await tester.tap(find.text('Chill').last);
      await tester.pumpAndSettle();
      await showPeople(tester);
      final count = find.byKey(const Key('filter-count'));
      expect(tester.widget<Text>(count).data, '11');
      // At 320 px and 2x text the filter button keeps its icon and its count,
      // and is still a 48 dp target.
      expect(find.text('Filters'), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('discover-filters'))).height,
        greaterThanOrEqualTo(48),
      );
      await captureApplied(tester, 'applied-filters-small-large-text');
      await tester.tap(find.byKey(const Key('discover-reset')));
      await tester.pumpAndSettle();
      expect(api.queries.last['vibe'], '');
      expect(api.queries.last['interests'], isEmpty);
      expect(count, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Filter sheet and sticky actions adapt to phones, themes and large text',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [
        const Size(320, 740),
        const Size(390, 844),
        const Size(430, 932),
        const Size(679, 1314),
        const Size(1440, 1000),
      ]) {
        for (final scale in [1.0, 2.0]) {
          for (final dark in [false, true]) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            final boundary = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                    padding: const EdgeInsets.only(bottom: 34),
                    disableAnimations: true,
                  ),
                  child: RepaintBoundary(
                    key: boundary,
                    child: PeopleFilterScreen(
                      key: ValueKey('$size-$scale-$dark'),
                      initial: PeopleFilters(
                        interests: ['Music'],
                        languages: ['en'],
                        country: 'IN',
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$size scale=$scale dark=$dark',
            );
            final button = find.widgetWithText(FilledButton, 'Show people');
            expect(
              tester.getRect(button).bottom,
              lessThanOrEqualTo(size.height - 34),
            );
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
            if (size.width == 390 &&
                scale == 1 &&
                const bool.fromEnvironment('CAPTURE_FILTERS')) {
              void repaint(RenderObject render) {
                render.markNeedsPaint();
                render.visitChildren(repaint);
              }

              repaint(boundary.currentContext!.findRenderObject()!);
              await tester.pump();
              await tester.runAsync(() async {
                final img =
                    await (boundary.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage(pixelRatio: 1);
                final bytes = await img.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '../../.runtime/filter-previews/filters-${dark ? 'dark' : 'light'}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                img.dispose();
              });
            }
            await reveal(tester, find.text('Night owl'));
            expect(
              tester.takeException(),
              isNull,
              reason: 'Scrolled $size scale=$scale dark=$dark',
            );
            // Age, location and gender filters are part of the sheet now.
            expect(find.text('Nearby'), findsNothing);
          }
        }
      }
    },
  );
}
