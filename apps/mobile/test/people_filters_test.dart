import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/discovery.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/core/theme.dart';
import 'package:kairova/features/people_filters.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

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
        child: RepaintBoundary(key: appCapture, child: const KairovaApp()),
      ),
    );
    // Home asks for a few suggestions; count only what Discover sends.
    await tester.pumpAndSettle();
    api.queries.clear();
    container.read(routerProvider).go('/discover');
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

  testWidgets(
    'Discover opens on everyone; filters apply only on explicit search',
    (tester) async {
      final api = DiscoveryTestApi();
      await launch(tester, api);
      expect(api.queries, hasLength(1));
      expect(api.queries.single['interests'], isEmpty);
      await openFilters(tester);
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(1));
      await openFilters(tester);
      expect(find.text('1 selected'), findsNothing);
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.queries, hasLength(2));
      expect(api.queries.last['interests'], ['Music']);
      expect(find.text('Your orbit is a little quiet.'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      await openFilters(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('clear-active-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(2));
      await openFilters(tester);
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
      await reveal(tester, find.text('Korean'));
      await tester.tap(find.text('Korean').last);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('More languages'));
      await tester.tap(find.text('More languages'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hindi');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Hindi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use 2 languages'));
      await tester.pumpAndSettle();
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
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(find.text('Into Music'), findsOneWidget);
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
    'Eligibility errors never become an empty success or fabricated people',
    (tester) async {
      final api = DiscoveryTestApi()
        ..failure = const ApiFailure(
          'Adult eligibility needs confirmation.',
          403,
        );
      await launch(tester, api);
      expect(
        find.text('Adult eligibility needs confirmation.'),
        findsOneWidget,
      );
      expect(find.text('Your orbit is a little quiet.'), findsNothing);
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
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Korean'));
      await tester.tap(find.text('Korean').last);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Any language'));
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
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(3));
      expect(api.queries.last['interests'], isEmpty);
      expect(find.text('Clear filters'), findsNothing);
      await tester.tap(find.text('Explore everyone'));
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
      expect(find.text('Your orbit is a little quiet.'), findsNothing);
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
      for (final visible in ['Niko', 'IN', 'KO', 'A quiet hello']) {
        expect(find.text(visible), findsOneWidget);
      }
      for (final spoken in [
        'India',
        'Korean, Conversational',
        'Into Music, Books',
        'Vibe: Chill',
        'Books and side quests.',
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
      expect(find.byKey(const ValueKey('applied-interest-Music')), findsOne);
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
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(find.text('Couldn’t connect.'), findsOneWidget);
      expect(find.text('You’re offline.'), findsNothing);
      expect(find.text('Your orbit is a little quiet.'), findsNothing);
      api.failure = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(3));
      expect(api.queries.last['interests'], ['Music']);
      expect(find.text('Couldn’t connect.'), findsNothing);
      expect(find.text('Your orbit is a little quiet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Applied filters stay pinned at the top and removal preserves the other dimensions',
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
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
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

      final before = <String, Rect>{
        for (final key in ['applied-country-IN', 'applied-language-en'])
          key: tester.getRect(find.byKey(ValueKey(key))),
      };
      for (final rect in before.values) {
        expect(rect.bottom, lessThan(300));
      }
      final scroll = find
          .descendant(
            of: find.byKey(const Key('discovery-results-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(scroll, const Offset(0, -1200));
      await tester.pumpAndSettle();
      for (final entry in before.entries) {
        expect(tester.getRect(find.byKey(ValueKey(entry.key))), entry.value);
      }
      await tester.tap(find.byKey(const ValueKey('applied-country-IN')));
      await tester.pumpAndSettle();
      expect(api.queries.last['country'], '');
      expect(api.queries.last['interests'], ['Music']);
      expect(api.queries.last['languages'], ['en']);
      expect(api.queries.last['vibe'], 'Chill');
      expect(tester.widget<Text>(count).data, '3');
      expect(find.byKey(const ValueKey('applied-country-IN')), findsNothing);
      final clear = find.byKey(const Key('clear-applied-filters'));
      await tester.scrollUntilVisible(
        clear,
        150,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('applied-filter-summary')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(api.queries.last['interests'], isEmpty);
      expect(api.queries.last['languages'], isEmpty);
      expect(api.queries.last['vibe'], '');
      expect(find.byKey(const Key('applied-filter-summary')), findsNothing);
      expect(api.saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Profile tabs and long selections stay reachable on small phones with doubled text',
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
            child: RepaintBoundary(key: appCapture, child: const KairovaApp()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tab = find.text('Your interests');
      await tester.scrollUntilVisible(
        tab,
        80,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('discover-tabs')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(api.queries.last['interests'], hasLength(10));
      await openFilters(tester);
      await reveal(tester, find.text('Chill'));
      await tester.tap(find.text('Chill').last);
      await tester.pumpAndSettle();
      await showPeople(tester);
      final count = find.byKey(const Key('filter-count'));
      expect(tester.widget<Text>(count).data, '11');
      final summary = find.byKey(const Key('applied-filter-summary'));
      expect(tester.getRect(summary).bottom, lessThan(400));
      final last = find.byKey(const ValueKey('applied-vibe-Chill'));
      await tester.scrollUntilVisible(
        last,
        120,
        scrollable: find
            .descendant(of: summary, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      await captureApplied(tester, 'applied-filters-small-large-text');
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(api.queries.last['vibe'], '');
      expect(api.queries.last['interests'], hasLength(10));
      expect(last, findsNothing);
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
                theme: kairovaTheme(dark ? Brightness.dark : Brightness.light),
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
            expect(find.text('Nearby'), findsNothing);
            expect(find.byType(RangeSlider), findsNothing);
          }
        }
      }
    },
  );
}
