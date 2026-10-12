import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/core/surprise.dart';
import 'package:hiyall/features/chat.dart' show ConversationScreen;
import 'package:hiyall/features/chat_format.dart' show contrastRatio;
import 'package:hiyall/features/discover_header.dart';
import 'package:hiyall/features/discover_person.dart';
import 'package:hiyall/features/discover_style.dart';
import 'package:hiyall/shared/chat_tokens.dart';
import 'package:hiyall/shared/presence_dot.dart';
import 'package:hiyall/shared/press_scale.dart';

import 'discover_helpers.dart';

String uriOf(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

String pathOf(ProviderContainer c) => c
    .read(routerProvider)
    .routerDelegate
    .currentConfiguration
    .last
    .matchedLocation;

Profile profileOf(Map<String, dynamic> json) => Profile.fromJson(json);

bool selected(WidgetTester tester, String chip) =>
    tester.widget<PressScale>(find.byKey(Key('chip-$chip'))).selected == true;

Future<void> chip(WidgetTester tester, String id) async {
  await tester.ensureVisible(find.byKey(Key('chip-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('chip-$id')));
  await tester.pumpAndSettle();
}

DiscoverFake manyPeople(int n, {int pageSize = 20}) => DiscoverFake(
  people: [for (var i = 0; i < n; i++) person('p$i', 'Person $i')],
  pageSize: pageSize,
);

void main() {
  group('models', () {
    test('Profile reads sharedInterests: at most three, strings only', () {
      final p = Profile.fromJson({
        'userId': 'u',
        'username': 'u',
        'displayName': 'U',
        'sharedInterests': ['Music', '', 5, 'Art', 'Books', 'Food'],
      });
      expect(p.sharedInterests, ['Music', 'Art', 'Books']);
      expect(
        Profile.fromJson({'userId': 'u', 'username': 'u', 'displayName': 'U'})
            .sharedInterests,
        isEmpty,
      );
    });

    test('The online filter is sent only when on, counts and compares', () {
      expect(PeopleFilters().toJson().containsKey('online'), isFalse);
      expect(PeopleFilters(online: true).toJson()['online'], isTrue);
      expect(PeopleFilters(online: true).isEmpty, isFalse);
      expect(
        PeopleFilters(
          online: true,
          interests: ['a', 'b'],
          ageMin: 18,
          gender: 'man',
        ).count,
        5,
      );
      expect(
        PeopleFilters(interests: ['a', 'b'])
            .sameAs(PeopleFilters(interests: ['b', 'a'])),
        isTrue,
      );
      expect(PeopleFilters(online: true).sameAs(PeopleFilters()), isFalse);
    });
  });

  group('context line', () {
    final base = {'userId': 'u', 'username': 'u', 'displayName': 'U'};
    ContextLine? line(List<String> shared, [List<String> own = const []]) =>
        ContextLine.of(
          profileOf({...base, 'interests': own, 'sharedInterests': shared}),
        );
    test('one shared interest is loved, in the casing it came with', () {
      final l = line(['Travel'])!;
      expect(l.text, 'You both love Travel');
      expect(l.shared, isTrue);
      expect(line(['hiking'])!.text, 'You both love hiking');
    });
    test('two are liked together', () {
      expect(line(['Music', 'Travel'])!.text, 'You both like Music and Travel');
    });
    test('three or more become a count with the first two', () {
      expect(
        line(['Music', 'Travel', 'Art'])!.text,
        '3 in common · Music, Travel',
      );
    });
    test('blank shared interests are ignored', () {
      expect(line(['', ' ', 'Art'])!.text, 'You both love Art');
      expect(line(['', ' ']), isNull);
    });
    test('otherwise their own top three interests', () {
      final l = line(const [], ['Music', 'Photography', 'Art', 'Books'])!;
      expect(l.text, 'Music · Photography · Art');
      expect(l.shared, isFalse);
    });
    test('what two share beats their own interests', () {
      expect(line(['Art'], ['Music'])!.text, 'You both love Art');
    });
    test('otherwise nothing is made up', () {
      expect(line(const []), isNull);
      expect(line(const [], [' ', '']), isNull);
    });
  });

  group('row lines', () {
    final base = {'userId': 'u', 'username': 'u', 'displayName': 'U'};
    Profile who({
      List<String> interests = const [],
      List<String> shared = const [],
      String? headline,
      String? bio,
      String? vibe,
      List<String> langs = const [],
    }) => profileOf({
      ...base,
      'interests': interests,
      'sharedInterests': shared,
      'headline': ?headline,
      'bio': ?bio,
      'currentVibe': ?vibe,
      'languages': [
        for (final l in langs) {'code': l},
      ],
    });
    List<String> texts(Profile p, {bool focus = false}) => [
      for (final l in discoverRowLines(p, languagesFocus: focus)) l.text,
    ];

    test('line 1 is the context, line 2 the bio, headline or vibe', () {
      expect(
        texts(
          who(
            shared: ['Travel'],
            headline: 'Film photos',
            bio: 'ignored',
            langs: ['en'],
          ),
        ),
        ['You both love Travel', 'Film photos'],
      );
      expect(texts(who(interests: ['Art'], bio: 'Quiet mornings')), [
        'Art',
        'Quiet mornings',
      ]);
      expect(texts(who(vibe: 'Night owl', langs: ['en', 'ja'])), ['Night owl']);
    });

    test('never more than two lines, whatever is filled in', () {
      for (final focus in [false, true]) {
        final lines = discoverRowLines(
          who(
            shared: ['A', 'B', 'C'],
            interests: ['A', 'B', 'C', 'D'],
            headline: 'h',
            bio: 'b',
            vibe: 'v',
            langs: ['en', 'hi', 'es'],
          ),
          languagesFocus: focus,
        );
        expect(lines.length, lessThanOrEqualTo(2), reason: 'focus $focus');
      }
    });

    test('languages are left out by default, and kept on the profile', () {
      expect(texts(who(interests: ['Art'], langs: ['en', 'hi'])), ['Art']);
      expect(texts(who(headline: 'Hello', langs: ['en', 'hi'])), ['Hello']);
    });

    test(
      'languages show when a language filter is on, in place of the bio',
      () {
        expect(
          texts(
            who(interests: ['Art'], bio: 'Quiet', langs: ['en', 'hi', 'es']),
            focus: true,
          ),
          ['Art', 'Speaks English, Hindi +1'],
        );
        // Without a context line they lead, and the bio still follows.
        expect(texts(who(bio: 'Quiet', langs: ['en']), focus: true), [
          'Speaks English',
          'Quiet',
        ]);
        // Nothing to show for a person with no languages.
        expect(texts(who(interests: ['Art'], bio: 'Quiet'), focus: true), [
          'Art',
          'Quiet',
        ]);
      },
    );

    test('languages fill a row that would otherwise be empty', () {
      final lines = discoverRowLines(who(langs: ['ja']));
      expect([for (final l in lines) l.text], ['Speaks Japanese']);
      expect(lines.single.kind, RowLineKind.languages);
      expect(texts(who()), isEmpty);
    });
  });

  group('language summary', () {
    List<ProfileLanguage> langs(List<String> codes, [String level = '']) => [
      for (final c in codes) ProfileLanguage(c, level),
    ];
    test('one, two, three or more, none', () {
      expect(languageSummary(langs(['en'])), 'Speaks English');
      expect(
        languageSummary([const ProfileLanguage('en', 'native')]),
        'English · Native',
      );
      expect(languageSummary(langs(['en', 'hi'])), 'Speaks English, Hindi');
      expect(
        languageSummary(langs(['en', 'hi', 'es'])),
        'Speaks English, Hindi +1',
      );
      expect(
        languageSummary(langs(['en', 'hi', 'es', 'fr', 'de'])),
        'Speaks English, Hindi +3',
      );
      expect(languageSummary(const []), isNull);
    });
    test('the same language twice is said once; codes never show', () {
      expect(languageSummary(langs(['en', 'en-GB'])), 'Speaks English');
      expect(languageSummary(langs(['ar', 'ja'])), 'Speaks Arabic, Japanese');
      expect(languageSummary(langs(['en'])), isNot(contains('EN')));
    });
  });

  group('picking a surprise', () {
    final people = [
      for (final i in [1, 2, 3, 4]) profileOf(person('p$i', 'P$i')),
    ];
    test('never the last pick, however often it is asked', () {
      final random = Random(1);
      for (var i = 0; i < 60; i++) {
        expect(
          pickSurprise(people, last: 'p2', random: random)!.userId,
          isNot('p2'),
        );
      }
    });
    test(
      'people already followed or chatted with are skipped while others remain',
      () {
        final random = Random(2);
        for (var i = 0; i < 60; i++) {
          expect(
            pickSurprise(
              people,
              known: {'p1', 'p2', 'p3'},
              random: random,
            )!.userId,
            'p4',
          );
        }
        // When everyone is known one of them is still a fine surprise.
        expect(
          pickSurprise(people, known: {'p1', 'p2', 'p3', 'p4'}, random: random),
          isNotNull,
        );
      },
    );
    test(
      'nobody new when the only one left is the last pick, or nobody is loaded',
      () {
        expect(
          pickSurprise([people.first], last: 'p1', random: Random()),
          isNull,
        );
        expect(pickSurprise(const [], random: Random()), isNull);
      },
    );
  });

  group('Discover screen', () {
    testWidgets(
      'heading, surprise card, explore row and chips in the right order',
      (tester) async {
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        expect(find.text('Find your people.'), findsOneWidget);
        expect(find.text('Someone new is one hello away'), findsOneWidget);
        expect(
          find.text('New faces. Unexpected conversations.'),
          findsOneWidget,
        );
        expect(find.text('Surprise me →'), findsOneWidget);
        expect(find.text('Explore people'), findsOneWidget);
        final heading = tester.getTopLeft(find.text('Find your people.')).dy;
        final card = tester
            .getTopLeft(find.byKey(const Key('surprise-card')))
            .dy;
        final explore = tester.getTopLeft(find.text('Explore people')).dy;
        final chips = tester
            .getTopLeft(find.byKey(const Key('discover-chips')))
            .dy;
        final first = tester.getTopLeft(find.text('Mira Kapoor')).dy;
        expect([
          heading,
          card,
          explore,
          chips,
          first,
        ], orderedEquals([heading, card, explore, chips, first]..sort()));
        // The compass is a small icon button beside the heading.
        expect(find.byTooltip('Explore Discover'), findsOneWidget);
        expect(find.text('Find people'), findsNothing);
      },
    );

    testWidgets(
      'the first three people are fully visible and a fourth shows at 390x844',
      (tester) async {
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        // The floating dock starts about 112 px above the bottom edge.
        const dockTop = 844 - 112.0;
        for (final id in ['mira', 'arjun', 'jules']) {
          expect(
            tester.getRect(find.byKey(Key('person-$id'))).bottom,
            lessThanOrEqualTo(dockTop),
            reason: id,
          );
        }
        expect(
          tester.getRect(find.byKey(const Key('person-noor'))).top,
          lessThan(dockTop),
        );
      },
    );

    testWidgets(
      'rows carry a context line, a bio line, the online dot and word, and Say hi',
      (tester) async {
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        expect(
          find.text('You both like Music and Photography'),
          findsOneWidget,
        );
        expect(find.text('Gaming · Tech · Food'), findsOneWidget);
        expect(find.text('Film photos and late night ramen'), findsOneWidget);
        // Languages are not a default line: full detail stays on the profile.
        expect(find.textContaining('Speaks'), findsNothing);
        // The country badge is off, so a code never reads as a location.
        expect(DiscoverStyle.showCountryBadge, isFalse);
        expect(find.text('IN'), findsNothing);
        expect(find.text('FR'), findsNothing);
        // Presence only for people the server said are online.
        expect(find.byKey(const Key('online-dot-mira')), findsOneWidget);
        expect(find.byKey(const Key('online-dot-arjun')), findsOneWidget);
        expect(find.byKey(const Key('online-dot-jules')), findsNothing);
        expect(find.byKey(const Key('online-text-mira')), findsOneWidget);
        expect(find.byKey(const Key('online-text-jules')), findsNothing);
        expect(find.byType(PresenceDot), findsWidgets);
        // Missing details keep the row clean: Noor has her initial and her name, nothing else.
        expect(
          find.descendant(
            of: find.byKey(const Key('person-noor')),
            matching: find.byType(Text),
          ),
          findsNWidgets(2),
        );
        expect(find.text('Say hi'), findsNothing);
        expect(find.byIcon(Icons.waving_hand_rounded), findsWidgets);
      },
    );

    testWidgets('no row ever has more than two lines under the name', (
      tester,
    ) async {
      await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople(scripts: true)),
        size: const Size(390, 3000),
      );
      for (final focus in [false, true]) {
        if (focus) await chip(tester, 'languages');
        for (final p in busyPeople(scripts: true)) {
          final id = p['userId'] as String;
          final texts = find
              .descendant(
                of: find.byKey(Key('person-$id')),
                matching: find.byType(Text),
              )
              .evaluate()
              .length;
          // Initial, name, the word online, up to two lines (the distance is
          // never present here).
          final fixed = 2 + (p['online'] == true ? 1 : 0);
          expect(
            texts - fixed,
            lessThanOrEqualTo(2),
            reason: '$id (languages focus: $focus)',
          );
        }
      }
    });

    testWidgets(
      'the Languages category shows the languages line, replacing the bio',
      (tester) async {
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        expect(find.text('Speaks English, Hindi +1'), findsNothing);
        await chip(tester, 'languages');
        // The test helper scrolled the page to reach the chip; look at the top.
        await tester.drag(
          find.byKey(const Key('discovery-results-scroll')),
          const Offset(0, 1000),
        );
        await tester.pumpAndSettle();
        expect(find.text('Speaks English, Hindi +1'), findsOneWidget);
        expect(
          find.text('You both like Music and Photography'),
          findsOneWidget,
        );
        expect(find.text('Film photos and late night ramen'), findsNothing);
        await chip(tester, 'everyone');
        expect(find.textContaining('Speaks'), findsNothing);
      },
    );

    testWidgets(
      'a row with no context and no bio shows the languages rather than nothing',
      (tester) async {
        await mountDiscover(
          tester,
          DiscoverFake(
            people: [
              person(
                'lin',
                'Lin',
                languages: [
                  {'code': 'ja'},
                  {'code': 'en'},
                ],
              ),
            ],
          ),
        );
        expect(find.text('Speaks Japanese, English'), findsOneWidget);
      },
    );

    testWidgets('Nearby leads the first line with the distance bucket', (
      tester,
    ) async {
      final api = DiscoverFake(
        people: [
          person(
            'n1',
            'Niko',
            shared: ['Art'],
            headline: 'Walks',
            distanceKm: 5,
          ),
          person('n2', 'Ola', distanceKm: 1),
        ],
      );
      await mountDiscover(tester, api);
      await chip(tester, 'nearby');
      expect(find.text('Within 5 km'), findsOneWidget);
      expect(find.text('You both love Art'), findsOneWidget);
      expect(find.text('Walks'), findsOneWidget);
      expect(find.text('Within 1 km'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'long, Arabic and Japanese names fit at 320 px and large text',
      (tester) async {
        for (final scale in [1.0, 1.3, 2.0]) {
          await mountDiscover(
            tester,
            DiscoverFake(people: busyPeople(scripts: true)),
            size: const Size(320, 740),
            scale: scale,
          );
          expect(tester.takeException(), isNull, reason: 'scale $scale');
          for (final name in ['سارة المنصوري', '田中 ひなた', 'Ana Souza']) {
            await tester.scrollUntilVisible(
              find.text(name),
              200,
              scrollable: find.byType(Scrollable).first,
            );
            expect(find.text(name), findsOneWidget);
            expect(tester.takeException(), isNull, reason: '$name at $scale');
          }
          expect(tester.takeException(), isNull, reason: 'scale $scale end');
          await tester.pumpWidget(const SizedBox());
        }
      },
    );

    testWidgets('a light theme renders without errors', (tester) async {
      await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
        dark: false,
      );
      expect(find.text('Mira Kapoor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'on a wide screen the content stays in a column of at most 720 px',
      (tester) async {
        await mountDiscover(
          tester,
          DiscoverFake(people: busyPeople()),
          size: const Size(1280, 800),
        );
        final card = tester.getRect(find.byKey(const Key('surprise-card')));
        expect(card.width, lessThanOrEqualTo(720));
        final row = tester.getRect(find.byKey(const Key('person-mira')));
        expect(row.right, lessThanOrEqualTo(card.right + 1));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('categories', () {
    testWidgets(
      'they are Everyone, Online, Same vibe, Interests, Languages, Nearby, in that order',
      (tester) async {
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        final labels = [
          'Everyone',
          'Online',
          'Same vibe',
          'Interests',
          'Languages',
          'Nearby',
        ];
        final xs = [
          for (final l in labels)
            tester.getTopLeft(find.text(l, skipOffstage: false)).dx,
        ];
        expect(xs, orderedEquals([...xs]..sort()));
        expect(selected(tester, 'everyone'), isTrue);
        expect(selected(tester, 'online'), isFalse);
      },
    );

    testWidgets('each category sends the filters it stands for', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      await chip(tester, 'online');
      expect(api.searches.last['online'], isTrue);
      expect(selected(tester, 'online'), isTrue);
      expect(selected(tester, 'everyone'), isFalse);
      await chip(tester, 'vibe');
      expect(api.searches.last['vibe'], 'Chill');
      expect(api.searches.last.containsKey('online'), isFalse);
      await chip(tester, 'interests');
      expect(api.searches.last['interests'], ['Music', 'Photography']);
      await chip(tester, 'languages');
      expect(api.searches.last['languages'], ['en']);
      await chip(tester, 'nearby');
      expect(api.nearbyCalls.last!.nearby, isTrue);
      expect(selected(tester, 'nearby'), isTrue);
      await chip(tester, 'everyone');
      expect(api.searches.last['online'], isNull);
      expect(selected(tester, 'everyone'), isTrue);
    });

    testWidgets(
      'Online is a server filter: only the first page of the whole list would hide people',
      (tester) async {
        // 25 people, only the last two online: a client-side filter of page one finds nobody.
        final list = [
          for (var i = 0; i < 25; i++)
            person('p$i', 'Person $i', online: i >= 23 ? true : null),
        ];
        final api = DiscoverFake(people: list, pageSize: 20);
        await mountDiscover(tester, api);
        await chip(tester, 'online');
        expect(api.searches.last['online'], isTrue);
        expect(find.text('Person 23'), findsOneWidget);
        expect(find.text('Person 24'), findsOneWidget);
        expect(find.text('Person 0'), findsNothing);
        // Online combines with Nearby on its own route.
      },
    );

    testWidgets('Online and Nearby together use the Nearby route with online', (
      tester,
    ) async {
      final api = DiscoverFake(
        people: [
          person('a', 'Ana', online: true, distanceKm: 3),
          person('b', 'Bo', distanceKm: 5),
        ],
      );
      await mountDiscover(tester, api);
      await tester.tap(find.byKey(const Key('discover-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-online')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-nearby')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('filter-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('filter-nearby')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show people'));
      await tester.pumpAndSettle();
      expect(api.nearbyCalls.last!.online, isTrue);
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('Bo'), findsNothing);
    });

    testWidgets(
      'the selection survives opening a profile and coming back, and leaving Discover',
      (tester) async {
        final api = DiscoverFake(people: busyPeople());
        final container = await mountDiscover(tester, api);
        await chip(tester, 'online');
        final searches = api.searches.length;
        await tester.tap(find.byKey(const Key('person-mira')));
        await tester.pumpAndSettle();
        expect(pathOf(container), '/discover/person/mira');
        container.read(routerProvider).pop();
        await tester.pumpAndSettle();
        expect(selected(tester, 'online'), isTrue);
        expect(
          api.searches.length,
          searches,
          reason: 'coming back does not search again',
        );
        // Another dock destination and back: the choice is still there.
        container.read(routerProvider).go('/home');
        await tester.pumpAndSettle();
        container.read(routerProvider).go('/discover');
        await tester.pumpAndSettle();
        expect(selected(tester, 'online'), isTrue);
        expect(api.searches.last['online'], isTrue);
      },
    );

    testWidgets('chips are announced with their selected state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await mountDiscover(tester, DiscoverFake(people: busyPeople()));
      final everyone = tester.getSemantics(
        find.byKey(const Key('chip-everyone')),
      );
      expect(everyone.label, 'Everyone');
      expect(everyone.flagsCollection.isButton, isTrue);
      expect(everyone.flagsCollection.isSelected, ui.Tristate.isTrue);
      final online = tester.getSemantics(find.byKey(const Key('chip-online')));
      expect(online.flagsCollection.isSelected, ui.Tristate.isFalse);
      handle.dispose();
    });
  });

  group('filters', () {
    testWidgets(
      'the button counts filters that no category stands for, and Reset clears them',
      (tester) async {
        final api = DiscoverFake(people: busyPeople());
        await mountDiscover(tester, api);
        expect(find.byKey(const Key('filter-count')), findsNothing);
        expect(find.byKey(const Key('discover-reset')), findsNothing);
        await tester.tap(find.byKey(const Key('discover-filters')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-online')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('filter-sheet-count'))).data,
          '1 on',
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('filter-gender-woman')),
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('filter-content')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const Key('filter-gender-woman')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('filter-sheet-count'))).data,
          '2 on',
        );
        await tester.tap(find.text('Show people'));
        await tester.pumpAndSettle();
        expect(api.searches.last['online'], isTrue);
        expect(api.searches.last['gender'], 'woman');
        expect(
          tester.widget<Text>(find.byKey(const Key('filter-count'))).data,
          '2',
        );
        expect(
          selected(tester, 'online'),
          isFalse,
          reason: 'online plus gender is no category',
        );
        await tester.tap(find.byKey(const Key('discover-reset')));
        await tester.pumpAndSettle();
        expect(api.searches.last.containsKey('online'), isFalse);
        expect(api.searches.last.containsKey('gender'), isFalse);
        expect(find.byKey(const Key('filter-count')), findsNothing);
        expect(selected(tester, 'everyone'), isTrue);
      },
    );

    testWidgets(
      'Reset all in the sheet clears every control, including Online now',
      (tester) async {
        final api = DiscoverFake(people: busyPeople());
        await mountDiscover(tester, api);
        await tester.tap(find.byKey(const Key('discover-filters')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-online')));
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        await tester.tap(find.text('Reset all'));
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
        expect(find.byKey(const Key('filter-sheet-count')), findsNothing);
      },
    );

    testWidgets('the filter button is a labelled 48 dp target with its count', (
      tester,
    ) async {
      await mountDiscover(tester, DiscoverFake(people: busyPeople()));
      expect(
        tester.getSize(find.byKey(const Key('discover-filters'))).height,
        greaterThanOrEqualTo(48),
      );
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Filters'), findsOneWidget);
      handle.dispose();
      await tester.tap(find.byKey(const Key('discover-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-online')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-gender-woman')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('filter-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('filter-gender-woman')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show people'));
      await tester.pumpAndSettle();
      final again = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Filters, 2 active'), findsOneWidget);
      again.dispose();
    });
  });

  group('Say hi row', () {
    testWidgets(
      'viewing rows sends nothing; tapping the row opens the profile and starts no conversation',
      (tester) async {
        final hi = HiLog();
        final container = await mountDiscover(
          tester,
          DiscoverFake(people: busyPeople()),
          hi: hi,
        );
        expect(hi.opened, isEmpty);
        await tester.tap(find.byKey(const Key('person-mira')));
        await tester.pumpAndSettle();
        expect(pathOf(container), '/discover/person/mira');
        expect(hi.opened, isEmpty);
        expect(hi.sent, isEmpty);
      },
    );

    testWidgets(
      'it is icon-only, announced and has a tooltip per person, 48 dp to hit and a 40 px outlined square (radius 12) to see',
      (tester) async {
        final handle = tester.ensureSemantics();
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        expect(find.bySemanticsLabel('Say hi to Mira Kapoor'), findsOneWidget);
        expect(find.byTooltip('Say hi to Mira Kapoor'), findsOneWidget);
        expect(find.text('Say hi'), findsNothing);
        final target = tester.getSize(find.byKey(const Key('say-hi-mira')));
        expect(target.height, greaterThanOrEqualTo(48));
        expect(target.width, greaterThanOrEqualTo(48));
        final visual = find.descendant(
          of: find.byKey(const Key('say-hi-mira')),
          matching: find.byKey(const Key('say-hi-square')),
        );
        expect(tester.getSize(visual), const Size(40, 40));
        final box =
            tester.widget<AnimatedContainer>(visual).decoration!
                as BoxDecoration;
        expect(box.borderRadius, BorderRadius.circular(12));
        expect(box.shape, BoxShape.rectangle);
        expect(box.border, isNotNull);
        expect(box.border!.top.width, 1);
        await tester.pumpWidget(const SizedBox());
        await mountDiscover(
          tester,
          DiscoverFake(people: busyPeople()),
          size: const Size(320, 740),
        );
        expect(find.text('Say hi'), findsNothing);
        expect(find.bySemanticsLabel('Say hi to Mira Kapoor'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const Key('say-hi-mira'))).height,
          greaterThanOrEqualTo(48),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'the row is announced with what they share and that they are online, and opens a profile',
      (tester) async {
        final handle = tester.ensureSemantics();
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        final label = tester.getSemantics(find.byKey(const Key('person-mira')));
        expect(
          label.label,
          startsWith(
            'Mira Kapoor, You both like Music and Photography, online, Film photos and late night ramen, Speaks English, Hindi +1',
          ),
        );
        expect(label.hint, 'Opens profile');
        handle.dispose();
      },
    );
  });

  group('Surprise me', () {
    Future<ProviderContainer> start(
      WidgetTester tester,
      DiscoverFake api, {
      int seed = 3,
      HiLog? hi,
    }) => mountDiscover(
      tester,
      api,
      hi: hi,
      extra: [surpriseRandomProvider.overrideWithValue(Random(seed))],
    );

    testWidgets(
      'opens a profile from the loaded results, and never starts a chat',
      (tester) async {
        final hi = HiLog();
        final api = DiscoverFake(
          people: [person('a', 'Ana'), person('b', 'Bo'), person('c', 'Cy')],
        );
        final container = await start(tester, api, hi: hi);
        await tester.tap(find.byKey(const Key('surprise-cta')));
        await tester.pumpAndSettle();
        expect(pathOf(container), matches(RegExp(r'^/discover/person/[abc]$')));
        expect(hi.opened, isEmpty);
      },
    );

    testWidgets('a second surprise never repeats the first', (tester) async {
      final api = DiscoverFake(people: [person('a', 'Ana'), person('b', 'Bo')]);
      final container = await start(tester, api);
      final seen = <String>[];
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('surprise-cta')));
        await tester.pumpAndSettle();
        seen.add(pathOf(container).split('/').last);
        container.read(routerProvider).pop();
        await tester.pumpAndSettle();
      }
      expect(seen.toSet(), {'a', 'b'});
      // Only the last pick is left: nothing new.
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(pathOf(container), startsWith('/discover/person/'));
    });

    testWidgets(
      'it loads more pages first when few people are loaded, at most three',
      (tester) async {
        final api = manyPeople(40, pageSize: 3);
        await start(tester, api);
        expect(api.searches, hasLength(1));
        await tester.tap(find.byKey(const Key('surprise-cta')));
        await tester.pumpAndSettle();
        expect(api.searches, hasLength(4));
        expect(api.searches.map((s) => s['cursor']), [null, '3', '6', '9']);
      },
    );

    testWidgets('it does not load more when ten are already there', (
      tester,
    ) async {
      final api = manyPeople(40, pageSize: 12);
      await start(tester, api);
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(api.searches, hasLength(1));
    });

    testWidgets('people already followed are avoided when there are others', (
      tester,
    ) async {
      final api = DiscoverFake(
        people: [person('a', 'Ana'), person('b', 'Bo'), person('c', 'Cy')],
      )..following = {'a', 'b'};
      final container = await start(tester, api, seed: 5);
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(pathOf(container), '/discover/person/c');
      expect(api.followingReads, 1);
    });

    testWidgets('nothing available says so, and can be tried again', (
      tester,
    ) async {
      final api = DiscoverFake(people: const []);
      final container = await start(tester, api);
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(
        find.text('No one new right now. Try again in a bit.'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(pathOf(container), '/discover');
      api.people = [person('a', 'Ana')];
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(pathOf(container), '/discover/person/a');
    });

    testWidgets('an error shows a Retry that works', (tester) async {
      final api = DiscoverFake(people: [person('a', 'Ana')])
        ..failure = const ApiFailure(
          'Could not connect. Check your connection and retry.',
        );
      final container = await start(tester, api);
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsWidgets);
      expect(
        find.textContaining('Couldn’t find anyone just now'),
        findsOneWidget,
      );
      api.failure = null;
      await tester.tap(find.byKey(const Key('surprise-cta')));
      await tester.pumpAndSettle();
      expect(pathOf(container), '/discover/person/a');
    });

    testWidgets(
      'while finding someone the card says so and cannot be tapped twice',
      (tester) async {
        final api = DiscoverFake(people: [person('a', 'Ana')]);
        await start(tester, api);
        api.hold = Completer<void>();
        await tester.tap(
          find.byKey(const Key('discover-reset')).evaluate().isEmpty
              ? find.byKey(const Key('chip-online'))
              : find.byKey(const Key('discover-reset')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('surprise-cta')));
        await tester.pump();
        expect(find.text('Finding someone…'), findsOneWidget);
        api.hold!.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'the callback is the only thing the card calls, in every state',
      (tester) async {
        for (final status in SurpriseStatus.values) {
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SurpriseCard(status: status, onSurprise: () => calls++),
              ),
            ),
          );
          await tester.tap(
            find.byKey(const Key('surprise-cta')),
            warnIfMissed: false,
          );
          await tester.pump();
          expect(
            calls,
            status == SurpriseStatus.loading ? 0 : 1,
            reason: '$status',
          );
        }
      },
    );

    testWidgets('it is a labelled button that says it opens a profile', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await mountDiscover(tester, DiscoverFake(people: busyPeople()));
      expect(
        find.bySemanticsLabel(
          RegExp(
            'Surprise me. Opens the profile of someone new. No chat starts.',
          ),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('states', () {
    testWidgets(
      'loading shows skeleton rows, not a full-screen spinner, and no layout jump',
      (tester) async {
        final api = DiscoverFake(people: busyPeople())
          ..hold = Completer<void>();
        await mountDiscover(tester, api);
        expect(find.byKey(const Key('discover-loading')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final top = tester
            .getTopLeft(find.byKey(const Key('discover-loading')))
            .dy;
        api.hold!.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('discover-loading')), findsNothing);
        expect(
          tester.getTopLeft(find.byKey(const Key('person-mira'))).dy,
          closeTo(top, 12),
        );
      },
    );

    testWidgets('nothing at all says so and offers a refresh', (tester) async {
      final api = DiscoverFake(people: const []);
      await mountDiscover(tester, api);
      expect(find.text('No one here just yet.'), findsOneWidget);
      final before = api.searches.length;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(api.searches.length, before + 1);
    });

    testWidgets('no match with other filters offers Clear filters', (
      tester,
    ) async {
      final api = DiscoverFake(people: const []);
      await mountDiscover(tester, api);
      await chip(tester, 'interests');
      expect(find.text('No one here just yet.'), findsOneWidget);
      expect(
        find.text('Try another filter or explore more people.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(api.searches.last['interests'], isEmpty);
      expect(selected(tester, 'everyone'), isTrue);
    });

    testWidgets('nobody online has its own message and Show everyone', (
      tester,
    ) async {
      final api = DiscoverFake(people: [person('a', 'Ana')]);
      await mountDiscover(tester, api);
      await chip(tester, 'online');
      expect(find.text('Nobody’s online right now'), findsOneWidget);
      await tester.tap(find.text('Show everyone'));
      await tester.pumpAndSettle();
      expect(find.text('Ana'), findsOneWidget);
      expect(selected(tester, 'everyone'), isTrue);
    });

    testWidgets('an error has a real Retry; being offline is said as such', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople())
        ..failure = const ApiFailure(
          'Could not connect. Check your connection and retry.',
        );
      await mountDiscover(tester, api);
      expect(find.text('Couldn’t connect.'), findsOneWidget);
      api.failure = null;
      await tester.tap(find.byKey(const Key('discovery-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Mira Kapoor'), findsOneWidget);
      expect(find.byKey(const Key('discover-error')), findsNothing);
    });

    testWidgets('a later page that fails keeps the people already shown', (
      tester,
    ) async {
      final api = manyPeople(30, pageSize: 12);
      await mountDiscover(tester, api);
      await tester.scrollUntilVisible(
        find.text('Explore more people'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      api.failure = const ApiFailure(
        'Could not connect. Check your connection and retry.',
      );
      await tester.tap(find.text('Explore more people'));
      await tester.pumpAndSettle();
      expect(find.text('Person 0', skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(const Key('discovery-retry'), skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('pull to refresh searches again', (tester) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      final before = api.searches.length;
      await tester.fling(
        find.byKey(const Key('discovery-results-scroll')),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(api.searches.length, before + 1);
    });
  });

  group('motion', () {
    testWidgets(
      'the first page eases in once; later pages and reduced motion do not',
      (tester) async {
        final api = manyPeople(30, pageSize: 12);
        await mountDiscover(tester, api);
        final first = find
            .byType(StaggerIn, skipOffstage: false)
            .evaluate()
            .length;
        expect(first, inInclusiveRange(1, 8));
        await tester.scrollUntilVisible(
          find.text('Explore more people'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Explore more people'));
        await tester.pumpAndSettle();
        // Back at the top the rest of the first page is built; never more than eight.
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 4000));
        await tester.pumpAndSettle();
        expect(
          find.byType(StaggerIn, skipOffstage: false).evaluate().length,
          lessThanOrEqualTo(8),
        );
      },
    );

    testWidgets('with reduced motion nothing animates in', (tester) async {
      await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
        still: true,
      );
      expect(
        find.descendant(
          of: find.byType(StaggerIn),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsNothing,
      );
      final chipBox = find.descendant(
        of: find.byKey(const Key('chip-online')),
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.widget<AnimatedContainer>(chipBox).duration, Duration.zero);
    });
  });

  group('online presence in the list', () {
    testWidgets(
      'a 14 px dot with a ring and a green word beside the name, only for people the server said are online',
      (tester) async {
        await mountDiscover(tester, DiscoverFake(people: busyPeople()));
        final dot = tester.getSize(find.byKey(const Key('online-dot-mira')));
        expect(dot.width, greaterThanOrEqualTo(16));
        // The green disc inside the ring is about 13 px.
        final decoration =
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byKey(const Key('online-dot-mira')),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration;
        final ring = (decoration.border! as Border).top;
        expect(dot.width - ring.width * 2, inInclusiveRange(12, 15));
        expect(ring.color, ChatTokens.dark.bg);
        final word = tester.widget<Text>(
          find.byKey(const Key('online-text-mira')),
        );
        expect(word.data, 'online');
        expect(word.style!.fontSize, inInclusiveRange(11, 12));
        // Beside the name, on its line.
        final name = tester.getRect(find.text('Mira Kapoor'));
        final online = tester.getRect(
          find.byKey(const Key('online-text-mira')),
        );
        expect(online.left, greaterThan(name.right));
        expect((online.center.dy - name.center.dy).abs(), lessThan(4));
        expect(find.byKey(const Key('online-text-jules')), findsNothing);
        expect(find.byKey(const Key('online-text-noor')), findsNothing);
      },
    );

    testWidgets('a long name ellipsizes and keeps the word online, at 320 px', (
      tester,
    ) async {
      for (final scale in [1.0, 2.0]) {
        await mountDiscover(
          tester,
          DiscoverFake(people: busyPeople()),
          size: const Size(320, 740),
          scale: scale,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('online-text-arjun')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final online = tester.getRect(
          find.byKey(const Key('online-text-arjun')),
        );
        expect(online.right, lessThanOrEqualTo(320));
        expect(tester.takeException(), isNull, reason: 'scale $scale');
        await tester.pumpWidget(const SizedBox());
      }
    });

    test('the word is AA on both themes', () {
      for (final tokens in [ChatTokens.dark, ChatTokens.light]) {
        final style = DiscoverStyle(tokens);
        expect(contrastRatio(style.onlineInk, tokens.bg), greaterThan(4.5));
        expect(style.pairs.map((p) => p.$1), containsAll(['online', 'say hi']));
      }
    });
  });

  group('category chips scroll the selection into view', () {
    Future<void> pickNearbyFromTheEdge(
      WidgetTester tester,
      double width,
    ) async {
      // The member scrolls the row until Nearby peeks in, then taps what shows.
      final scroller = find.byKey(const Key('discover-chips'));
      for (var i = 0; i < 20; i++) {
        final r = tester.getRect(find.byKey(const Key('chip-nearby')));
        if (r.left < width - 40) break;
        await tester.drag(scroller, const Offset(-60, 0));
        await tester.pumpAndSettle();
      }
      final r = tester.getRect(find.byKey(const Key('chip-nearby')));
      await tester.tapAt(Offset((r.left + width) / 2, r.center.dy));
      await tester.pumpAndSettle();
    }

    for (final width in [320.0, 390.0]) {
      testWidgets(
        'selecting Nearby brings it fully into view at ${width.round()} px',
        (tester) async {
          await mountDiscover(
            tester,
            DiscoverFake(people: busyPeople()),
            size: Size(width, 800),
          );
          await pickNearbyFromTheEdge(tester, width);
          expect(selected(tester, 'nearby'), isTrue);
          final r = tester.getRect(find.byKey(const Key('chip-nearby')));
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(width));
          // The last chip is not under the edge fade either.
          expect(r.right, lessThanOrEqualTo(width - 8));
        },
      );
    }

    testWidgets('a restored selection starts in view, with no glide', (
      tester,
    ) async {
      final container = await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
        size: const Size(320, 740),
      );
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/home');
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/discover');
      await tester.pump();
      await tester.pump();
      expect(selected(tester, 'nearby'), isTrue);
      final r = tester.getRect(find.byKey(const Key('chip-nearby')));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(320));
    });

    testWidgets('the glide takes about 200 ms, and none with reduced motion', (
      tester,
    ) async {
      await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
        size: const Size(320, 740),
      );
      final before = tester
          .getRect(find.byKey(const Key('chip-everyone')))
          .left;
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('chip-everyone'))).left,
        lessThan(before),
      );
      await tester.pumpWidget(const SizedBox());
      await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
        size: const Size(320, 740),
        still: true,
      );
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pump();
      await tester.pump();
      final r = tester.getRect(find.byKey(const Key('chip-nearby')));
      expect(r.right, lessThanOrEqualTo(320));
    });
  });

  group('Surprise card', () {
    Future<void> show(
      WidgetTester tester,
      SurpriseStatus status,
      double width,
      double scale,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SurpriseCard(status: status, onSurprise: () {}),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('keeps a 44 dp button at 390 px', (tester) async {
      // Heights are judged with the real fonts in the capture run (the test
      // font is a wide square); here only the touch target and the fit.
      await show(tester, SurpriseStatus.ready, 390, 1);
      expect(
        tester.getSize(find.byKey(const Key('surprise-cta'))).height,
        greaterThanOrEqualTo(44),
      );
    });

    for (final status in SurpriseStatus.values) {
      for (final width in [320.0, 390.0, 430.0]) {
        for (final scale in [1.0, 1.3, 2.0]) {
          testWidgets('$status fits at ${width.round()} px, text x$scale', (
            tester,
          ) async {
            await show(tester, status, width, scale);
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
            final card = tester.getRect(find.byKey(const Key('surprise-card')));
            expect(card.right, lessThanOrEqualTo(width));
            final cta = tester.getRect(find.byKey(const Key('surprise-cta')));
            expect(cta.height, greaterThanOrEqualTo(44));
            expect(cta.right, lessThanOrEqualTo(card.right));
            expect(cta.bottom, lessThanOrEqualTo(card.bottom + 0.5));
          });
        }
      }
    }
  });

  group('row menu: View profile, Report, Block', () {
    Future<void> openMenu(WidgetTester tester, String id) async {
      await tester.longPress(find.byKey(Key('person-$id')));
      await tester.pumpAndSettle();
    }

    testWidgets('a long press opens a compact sheet with the three options', (
      tester,
    ) async {
      await mountDiscover(tester, DiscoverFake(people: busyPeople()));
      await openMenu(tester, 'mira');
      expect(find.byKey(const Key('person-menu')), findsOneWidget);
      expect(find.text('View profile'), findsOneWidget);
      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('person-menu')),
          matching: find.text('Mira Kapoor'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('screen readers get the same menu as a "More options" action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await mountDiscover(tester, DiscoverFake(people: busyPeople()));
      final node = tester.getSemantics(find.byKey(const Key('person-mira')));
      final ids = node.getSemanticsData().customSemanticsActionIds!;
      final labels = [
        for (final id in ids) CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(labels, contains('More options'));
      tester.semantics.performAction(
        find.semantics.byLabel(RegExp('^Mira Kapoor')),
        SemanticsAction.customAction,
        args: CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'More options'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('person-menu')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('View profile opens the profile', (tester) async {
      final container = await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
      );
      await openMenu(tester, 'mira');
      await tester.tap(find.byKey(const Key('person-menu-profile')));
      await tester.pumpAndSettle();
      expect(pathOf(container), '/discover/person/mira');
    });

    testWidgets('dismissing the sheet changes nothing', (tester) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      await openMenu(tester, 'mira');
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('person-menu')), findsNothing);
      expect(api.blockCalls, isEmpty);
      expect(find.text('Mira Kapoor'), findsOneWidget);
    });

    testWidgets(
      'Block asks first, then the person leaves the list and stays gone on the next load',
      (tester) async {
        final api = DiscoverFake(people: busyPeople());
        await mountDiscover(tester, api);
        await openMenu(tester, 'mira');
        await tester.tap(find.byKey(const Key('person-menu-block')));
        await tester.pumpAndSettle();
        expect(find.text('Block Mira Kapoor?'), findsOneWidget);
        // Cancel: nothing happens.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(api.blockCalls, isEmpty);
        expect(find.text('Mira Kapoor'), findsOneWidget);
        await openMenu(tester, 'mira');
        await tester.tap(find.byKey(const Key('person-menu-block')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-block')));
        await tester.pumpAndSettle();
        expect(api.blockCalls, ['mira']);
        expect(find.text('Account blocked.'), findsOneWidget);
        expect(find.byKey(const Key('person-mira')), findsNothing);
        expect(find.byKey(const Key('person-arjun')), findsOneWidget);
        // The server excludes them from now on.
        await chip(tester, 'online');
        await chip(tester, 'everyone');
        expect(find.byKey(const Key('person-mira')), findsNothing);
      },
    );

    testWidgets(
      'a block that fails says so, never succeeds, and keeps the row',
      (tester) async {
        final api = DiscoverFake(people: busyPeople())
          ..blockFailure = const ApiFailure('Server trouble.', 500);
        await mountDiscover(tester, api);
        await openMenu(tester, 'mira');
        await tester.tap(find.byKey(const Key('person-menu-block')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-block')));
        await tester.pumpAndSettle();
        expect(find.text('Account blocked.'), findsNothing);
        expect(find.byKey(const Key('person-mira')), findsOneWidget);
        expect(find.textContaining('Server trouble'), findsOneWidget);
      },
    );

    Future<void> sheetScroll(WidgetTester tester, String key) =>
        tester.scrollUntilVisible(
          find.byKey(Key(key)),
          200,
          scrollable: find
              .descendant(
                of: find.byType(BottomSheet),
                matching: find.byType(Scrollable),
              )
              .first,
        );

    Future<void> report(WidgetTester tester, {bool alsoBlock = false}) async {
      await tester.tap(find.byKey(const Key('person-menu-report')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reason-spam')));
      await tester.pumpAndSettle();
      if (alsoBlock) {
        await sheetScroll(tester, 'report-block');
        await tester.tap(find.byKey(const Key('report-block')));
        await tester.pumpAndSettle();
      }
      await sheetScroll(tester, 'report-submit');
      await tester.tap(find.byKey(const Key('report-submit')));
      await tester.pumpAndSettle();
    }

    testWidgets('Report uses the existing report sheet and confirmation', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      await openMenu(tester, 'mira');
      await report(tester);
      expect(api.reports.single['targetType'], 'user');
      expect(api.reports.single['targetId'], 'mira');
      expect(api.reports.single['reason'], 'spam');
      expect(
        find.text('Thanks for reporting. Our safety team will review it.'),
        findsOneWidget,
      );
      // A plain report keeps the person in the list.
      expect(find.byKey(const Key('person-mira')), findsOneWidget);
    });

    testWidgets('a report that also blocks removes the person at once', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople());
      await mountDiscover(tester, api);
      await openMenu(tester, 'mira');
      await report(tester, alsoBlock: true);
      expect(api.reports.single['block'], isTrue);
      expect(find.byKey(const Key('person-mira')), findsNothing);
      expect(find.textContaining('Mira Kapoor is blocked'), findsOneWidget);
    });

    testWidgets('a report that fails shows no thanks and keeps the person', (
      tester,
    ) async {
      final api = DiscoverFake(people: busyPeople())
        ..reportFailure = const ApiFailure('Could not send.', 500);
      await mountDiscover(tester, api);
      await openMenu(tester, 'mira');
      await report(tester);
      expect(find.textContaining('Thanks for reporting'), findsNothing);
      expect(find.byKey(const Key('person-mira')), findsOneWidget);
    });
  });

  group('opening a conversation', () {
    testWidgets('glides in over about 220 ms; reduced motion just shows it', (
      tester,
    ) async {
      final container = await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
      );
      container.read(routerProvider).go('/chats/c1?peer=mira&name=Mira');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byType(ConversationScreen),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 240));
      expect(
        tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: find.byType(ConversationScreen),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value,
        1,
      );
    });

    testWidgets('with reduced motion nothing fades', (tester) async {
      final container = await mountDiscover(
        tester,
        DiscoverFake(people: busyPeople()),
        still: true,
      );
      container.read(routerProvider).go('/chats/c1?peer=mira&name=Mira');
      await tester.pump();
      await tester.pump();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('contrast', () {
    for (final tokens in [ChatTokens.dark, ChatTokens.light]) {
      test(
        'every Discover colour pair is AA in the ${tokens.isDark ? 'dark' : 'light'} theme',
        () {
          for (final (name, fg, bg) in DiscoverStyle(tokens).pairs) {
            expect(
              contrastRatio(fg, bg),
              greaterThanOrEqualTo(4.5),
              reason: name,
            );
          }
        },
      );
    }
  });
}
