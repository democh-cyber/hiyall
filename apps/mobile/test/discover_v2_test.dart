import 'package:flutter/material.dart';

import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/discover_prefs.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/features/discovery.dart' show discoverFiltersProvider;

import 'discover_helpers.dart';
import 'support/fixtures.dart';

const anjali = anjaliId;

/// The category row scrolls sideways: bring the chip into view, then tap it.
Future<void> tapChip(WidgetTester tester, String id) async {
  final chip = find.byKey(Key('chip-$id'));
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

Map<String, dynamic> matchPerson(
  String id,
  String name,
  List<String> reasons,
) => person(
  id,
  name,
  headline: '$name’s headline',
  interests: ['Music', 'Travel'],
  shared: ['Music'],
  reasons: reasons,
);

void main() {
  group('rows: languages, personality and local time', () {
    List<Map<String, dynamic>> people() => [
      person(
        'mira',
        'Mira',
        headline: 'Film photos',
        languages: [
          {'code': 'en', 'level': 4},
          {'code': 'ko', 'level': 2},
        ],
        personalityTags: ['curious', 'maker'],
        localTime: {'utcOffsetMinutes': 330, 'label': 'UTC+5:30'},
      ),
      person('arjun', 'Arjun', headline: 'Games'),
    ];

    testWidgets(
      'chips with the level, a local time that follows the offset, and nothing for a person who shows none',
      (tester) async {
        final handle = tester.ensureSemantics();
        await mountDiscover(tester, DiscoverFake(people: people()));
        expect(find.byKey(const Key('row-language-mira-en')), findsOneWidget);
        expect(find.byKey(const Key('row-language-mira-ko')), findsOneWidget);
        expect(find.byKey(const Key('row-tag-mira-curious')), findsOneWidget);
        expect(find.bySemanticsLabel('English, fluent'), findsOneWidget);
        expect(find.bySemanticsLabel('Korean, beginner'), findsOneWidget);
        expect(find.byKey(const Key('local-time-mira')), findsOneWidget);
        expect(find.textContaining(' there'), findsOneWidget);
        expect(find.byKey(const Key('row-chips-arjun')), findsNothing);
        expect(find.byKey(const Key('local-time-arjun')), findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'tapping a language chip is the drill-down: Discover searches by it',
      (tester) async {
        final api = DiscoverFake(people: people());
        final container = await mountDiscover(tester, api);
        await tester.tap(find.byKey(const Key('row-language-mira-en')));
        await tester.pumpAndSettle();
        expect(container.read(discoverFiltersProvider).languages, ['en']);
        expect(api.searches.last['languages'], ['en']);
        // The filter is shown as removable.
        expect(
          find.byKey(const Key('active-filter-language-en')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('active-filter-language-en')));
        await tester.pumpAndSettle();
        expect(api.searches.last['languages'], isEmpty);
      },
    );

    testWidgets('tapping a personality chip searches by the tag', (
      tester,
    ) async {
      final api = DiscoverFake(people: people());
      final container = await mountDiscover(tester, api);
      // The chips are one scrolling line; the tag is past the languages.
      await tester.drag(
        find.byKey(const Key('row-chips-mira')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-tag-mira-maker')));
      await tester.pumpAndSettle();
      expect(container.read(discoverFiltersProvider).personalityTags, [
        'maker',
      ]);
      expect(api.searches.last['personalityTags'], ['maker']);
    });

    testWidgets('a nearby row with no distance prints none', (tester) async {
      final api = DiscoverFake(
        people: [person('mira', 'Mira', headline: 'Hi', distanceKm: null)],
      );
      await mountDiscover(tester, api);
      expect(find.textContaining('null'), findsNothing);
      expect(find.textContaining(' km'), findsNothing);
    });

    for (final dark in [true, false]) {
      testWidgets(
        'fits 320 px at text scale 2.0 (${dark ? 'dark' : 'light'})',
        (tester) async {
          await mountDiscover(
            tester,
            DiscoverFake(people: people()),
            size: const Size(320, 800),
            scale: 2,
            dark: dark,
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('row-chips-mira')), findsOneWidget);
        },
      );
    }

    testWidgets('right to left lays the chips out from the right', (
      tester,
    ) async {
      await mountDiscover(
        tester,
        DiscoverFake(people: people()),
        wrap: (app) =>
            Directionality(textDirection: TextDirection.rtl, child: app),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('filters', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('discover-filters')));
      await tester.pumpAndSettle();
    }

    Future<void> reveal(WidgetTester tester, Finder target) =>
        tester.scrollUntilVisible(
          target,
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('filter-content')),
                matching: find.byType(Scrollable),
              )
              .first,
        );

    testWidgets(
      'the minimum level is offered only once a language is chosen and is sent with it',
      (tester) async {
        final api = DiscoverFake(people: busyPeople());
        final container = await mountDiscover(tester, api);
        container
            .read(discoverFiltersProvider.notifier)
            .set(PeopleFilters(languages: ['hi']));
        await tester.pumpAndSettle();
        await openSheet(tester);
        await reveal(tester, find.byKey(const Key('filter-min-level-4')));
        expect(find.byKey(const Key('filter-min-level-0')), findsOneWidget);
        expect(find.byKey(const Key('filter-min-level-3')), findsOneWidget);
        expect(find.byKey(const Key('filter-min-level-5')), findsOneWidget);
        expect(find.byKey(const Key('filter-min-level-6')), findsOneWidget);
        await tester.tap(find.byKey(const Key('filter-min-level-4')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show people'));
        await tester.pumpAndSettle();
        expect(api.searches.last['languages'], ['hi']);
        expect(api.searches.last['languageMinLevel'], 4);
        expect(find.byKey(const Key('active-filter-level')), findsOneWidget);
      },
    );

    testWidgets('without a language there is no level to pick', (tester) async {
      await mountDiscover(tester, DiscoverFake(people: busyPeople()));
      await openSheet(tester);
      await tester.scrollUntilVisible(
        find.text('Vibe'),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('filter-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const Key('filter-min-level-4')), findsNothing);
    });

    testWidgets('personality tags are multi-select and any-of', (tester) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      await openSheet(tester);
      for (final id in ['curious', 'maker']) {
        await reveal(tester, find.byKey(Key('filter-tag-$id')));
        await tester.tap(find.byKey(Key('filter-tag-$id')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Show people'));
      await tester.pumpAndSettle();
      expect(api.searches.last['personalityTags'], ['curious', 'maker']);
      expect(
        find.byKey(const Key('active-filter-tag-curious')),
        findsOneWidget,
      );
    });

    testWidgets(
      '"same country" is off, with the reason, when your profile has no country',
      (tester) async {
        final api = DiscoverFake(people: busyPeople());
        await mountDiscover(tester, api);
        await openSheet(tester);
        final row = find.byKey(const Key('filter-same-country'));
        expect(row, findsOneWidget);
        expect(
          find.text('Add your country in your profile first'),
          findsOneWidget,
        );
        final toggle = find.descendant(of: row, matching: find.byType(Switch));
        expect(tester.widget<Switch>(toggle).onChanged, isNull);
      },
    );

    testWidgets('"same country" sends the shortcut, not a country code', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople())
        ..own = const Profile(
          userId: anjali,
          username: 'anjali',
          displayName: 'Anjali',
          bio: '',
          profession: '',
          version: '1',
          country: 'IN',
        );
      await mountDiscover(tester, api);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('filter-same-country')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show people'));
      await tester.pumpAndSettle();
      expect(api.searches.last['sameCountry'], isTrue);
      expect(api.searches.last['country'], '');
      expect(
        find.byKey(const Key('active-filter-same-country')),
        findsOneWidget,
      );
    });

    testWidgets('the server refusing the shortcut says so and drops it', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople())
        ..own = const Profile(
          userId: anjali,
          username: 'anjali',
          displayName: 'Anjali',
          bio: '',
          profession: '',
          version: '1',
          country: 'IN',
        );
      final container = await mountDiscover(tester, api);
      api.failure = const ApiFailure(
        'Add your country',
        422,
        'COUNTRY_NOT_SET',
      );
      container
          .read(discoverFiltersProvider.notifier)
          .set(PeopleFilters(sameCountry: true));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Add your country in your profile first'),
        findsWidgets,
      );
      expect(container.read(discoverFiltersProvider).sameCountry, isFalse);
    });

    testWidgets('Reset clears the new filters too', (tester) async {
      final api = DiscoverFake(people: busyPeople());
      final container = await mountDiscover(tester, api);
      container
          .read(discoverFiltersProvider.notifier)
          .set(
            PeopleFilters(
              languages: ['en'],
              languageMinLevel: 4,
              personalityTags: ['maker'],
            ),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discover-reset')));
      await tester.pumpAndSettle();
      expect(container.read(discoverFiltersProvider).isEmpty, isTrue);
      expect(api.searches.last['personalityTags'], anyOf(isNull, isEmpty));
      expect(find.byKey(const Key('discover-active-filters')), findsNothing);
    });
  });

  group('saved filters on this device', () {
    testWidgets(
      'the filters used last come back, search by them, and are removable',
      (tester) async {
        final store = MemoryDiscoverPrefsStore();
        await store.saveFilters(
          anjali,
          PeopleFilters(interests: ['Music'], personalityTags: ['maker']),
        );
        final api = DiscoverFake(people: busyPeople());
        final container = await mountDiscover(
          tester,
          api,
          discoverPrefs: store,
        );
        expect(container.read(discoverFiltersProvider).interests, ['Music']);
        expect(api.searches.last['interests'], ['Music']);
        expect(api.searches.last['personalityTags'], ['maker']);
        expect(
          find.byKey(const Key('active-filter-interest-Music')),
          findsOneWidget,
        );
      },
    );

    testWidgets('every change is saved, and Reset forgets them', (
      tester,
    ) async {
      final store = MemoryDiscoverPrefsStore();
      final api = DiscoverFake(people: busyPeople());
      final container = await mountDiscover(tester, api, discoverPrefs: store);
      container
          .read(discoverFiltersProvider.notifier)
          .set(PeopleFilters(languages: ['en'], languageMinLevel: 5));
      await tester.pumpAndSettle();
      final saved = await store.savedFilters(anjali);
      expect(saved!.languages, ['en']);
      expect(saved.languageMinLevel, 5);
      await tester.tap(find.byKey(const Key('discover-reset')));
      await tester.pumpAndSettle();
      expect(await store.savedFilters(anjali), isNull);
    });

    testWidgets('a tag drill-down wins over the saved filters for that visit', (
      tester,
    ) async {
      final store = MemoryDiscoverPrefsStore();
      await store.saveFilters(anjali, PeopleFilters(interests: ['Music']));
      final api = DiscoverFake(people: busyPeople());
      final container = await mountDiscover(
        tester,
        api,
        discoverPrefs: store,
        extra: [],
      );
      container
          .read(discoverFiltersProvider.notifier)
          .set(PeopleFilters(personalityTags: ['curious']));
      await tester.pumpAndSettle();
      expect(api.searches.last['personalityTags'], ['curious']);
      expect(api.searches.last['interests'], isEmpty);
    });

    testWidgets('modes are not saved: Nearby and Possible matches', (
      tester,
    ) async {
      final store = MemoryDiscoverPrefsStore();
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api, discoverPrefs: store);
      await tapChip(tester, 'possible');
      await tester.pumpAndSettle();
      expect(await store.savedFilters(anjali), isNull);
    });

    testWidgets("another account's saved filters are never applied", (
      tester,
    ) async {
      final store = MemoryDiscoverPrefsStore();
      await store.saveFilters(nikoId, PeopleFilters(interests: ['Chess']));
      final api = DiscoverFake(people: busyPeople());
      final container = await mountDiscover(tester, api, discoverPrefs: store);
      expect(container.read(discoverFiltersProvider).isEmpty, isTrue);
      expect(api.searches.last['interests'], isEmpty);
    });
  });

  group('possible matches', () {
    List<Map<String, dynamic>> matches(int n) => [
      for (var i = 0; i < n; i++)
        matchPerson(
          'm$i',
          'Match$i',
          i.isEven ? ['interests', 'personality'] : ['languages'],
        ),
    ];

    testWidgets(
      'the chip lists the server ranking in order, with why each was suggested',
      (tester) async {
        final api = DiscoverFake(people: busyPeople())..possible = matches(3);
        await mountDiscover(tester, api);
        await tapChip(tester, 'possible');
        await tester.pumpAndSettle();
        expect(api.possibleCalls.single.excludeFollowing, isFalse);
        // Only the search made when Discover opened: the possible matches list is its own call.
        expect(api.searches, hasLength(1));
        expect(find.text('Match0'), findsOneWidget);
        expect(
          find.text('Shares your interest in Music · Similar personality'),
          findsNWidgets(2),
        );
        expect(find.text('Good language match'), findsOneWidget);
        final y = [
          for (final i in [0, 1, 2]) tester.getTopLeft(find.text('Match$i')).dy,
        ];
        expect(y, orderedEquals([...y]..sort()));
      },
    );

    testWidgets('pages with the server cursor', (tester) async {
      final api = DiscoverFake(people: busyPeople(), pageSize: 2)
        ..possible = matches(30);
      await mountDiscover(tester, api);
      await tapChip(tester, 'possible');
      await tester.pumpAndSettle();
      expect(api.possibleCalls.single.cursor, isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('discover-more')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('discover-more')));
      await tester.pumpAndSettle();
      expect(api.possibleCalls.last.cursor, '20');
    });

    testWidgets('the first-use tip shows once, can be dismissed for good', (
      tester,
    ) async {
      final store = MemoryDiscoverPrefsStore();
      final api = DiscoverFake(people: busyPeople())..possible = matches(2);
      await mountDiscover(tester, api, discoverPrefs: store);
      await tapChip(tester, 'possible');
      await tester.pumpAndSettle();
      expect(find.text('Possible matches'), findsWidgets);
      expect(
        find.byKey(const ValueKey('coach-tip-discover.possible_matches')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Dismiss tip'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('coach-tip-discover.possible_matches')),
        findsNothing,
      );
      expect(await store.dismissedTips(anjali), {'discover.possible_matches'});
      // Away and back: it stays away.
      await tapChip(tester, 'everyone');
      await tapChip(tester, 'possible');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('coach-tip-discover.possible_matches')),
        findsNothing,
      );
    });

    testWidgets('nobody yet: a hint to fill the profile, with a way there', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      await tapChip(tester, 'possible');
      await tester.pumpAndSettle();
      expect(find.text('No matches yet'), findsOneWidget);
      expect(find.text('Edit profile'), findsOneWidget);
    });

    testWidgets('a failure is the usual retry card, not an empty success', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople())
        ..possibleFailure = const ApiFailure(
          'You’ve searched a lot today. Try again tomorrow.',
          429,
          'DAILY_LIMIT',
        );
      await mountDiscover(tester, api);
      await tapChip(tester, 'possible');
      await tester.pumpAndSettle();
      expect(find.text('No matches yet'), findsNothing);
      expect(find.textContaining('searched a lot today'), findsWidgets);
    });

    testWidgets(
      'it is a chip like the others: selected state and a 48 dp target',
      (tester) async {
        final api = DiscoverFake(people: busyPeople())..possible = matches(1);
        await mountDiscover(tester, api);
        final chip = find.byKey(const Key('chip-possible'));
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        final handle = tester.ensureSemantics();
        expect(
          tester.getSemantics(chip).flagsCollection.isSelected,
          Tristate.isTrue,
        );
        handle.dispose();
      },
    );
  });
}
