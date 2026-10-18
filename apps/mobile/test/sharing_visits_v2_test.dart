import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';

import 'support/fixtures.dart';
import 'widget_test.dart' show FakeApi, SignedIn;

/// Privacy settings, the visitor lists and what the server answers to them.
class SharingApi extends FakeApi {
  bool minor = false;
  int privVersion = 1;
  Map<String, dynamic> values = {
    'showLocalTime': true,
    'showDistance': true,
    'visitorsVisibleToOthers': false,
    'showBirthday': false,
    'onlineAudience': 'everyone',
  };
  Map<String, dynamic> audiences = {'birthday': 'friends'};
  final patches = <Map<String, dynamic>>[];
  ApiFailure? patchFailure;

  List<VisitedPerson> places = [];
  List<VisitedPerson> visitorList = [];
  ApiFailure? visitorsFailure;
  int placesCleared = 0;
  final placeCursors = <String?>[];
  String? nextPlaces;

  @override
  Future<NearbyStatus> nearbyStatus(Session s) async =>
      NearbyStatus(minor: minor);

  @override
  Future<Privacy> privacy(Session s) async => Privacy({
    ...values,
    'version': '$privVersion',
    'fieldAudiences': {...audiences},
  });

  @override
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async {
    patches.add(patch);
    if (patchFailure != null) throw patchFailure!;
    privVersion++;
    for (final e in patch.entries) {
      if (e.key == 'fieldAudiences') {
        audiences.addAll(Map<String, dynamic>.from(e.value as Map));
      } else {
        values[e.key] = e.value;
      }
    }
    return privacy(s);
  }

  @override
  Future<ApiPage<VisitedPerson>> placesVisited(
    Session s, [
    String? cursor,
  ]) async {
    placeCursors.add(cursor);
    if (cursor == null && nextPlaces != null) {
      return ApiPage(places.take(2).toList(), nextPlaces);
    }
    return ApiPage(cursor == null ? places : places.skip(2).toList(), null);
  }

  @override
  Future<void> clearPlacesVisited(Session s) async {
    placesCleared++;
    places = [];
  }

  @override
  Future<ApiPage<VisitedPerson>> recentVisitors(
    Session s,
    String userId, [
    String? cursor,
  ]) async {
    if (visitorsFailure != null) throw visitorsFailure!;
    return ApiPage(visitorList, null);
  }

  @override
  Future<Profile> otherProfile(Session session, String userId) async => Profile(
    userId: userId,
    username: 'niko',
    displayName: 'Niko',
    bio: '',
    profession: '',
    version: '1',
    visitorsVisible: true,
  );
}

VisitedPerson visited(String id, String name, {int daysAgo = 1}) =>
    VisitedPerson(
      Person(id, name.toLowerCase(), name),
      DateTime.now().subtract(Duration(days: daysAgo)),
    );

void main() {
  late ProviderContainer container;
  Future<void> open(
    WidgetTester tester,
    SharingApi api,
    String at, {
    Size size = const Size(390, 3000),
    double scale = 1,
    TextDirection? dir,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    container = ProviderContainer(
      overrides: <Override>[
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: scale == 1 && dir == null
            ? const HiyallApp()
            : MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Directionality(
                  textDirection: dir ?? TextDirection.ltr,
                  child: const HiyallApp(),
                ),
              ),
      ),
    );
    container.read(routerProvider).go(at);
    await tester.pumpAndSettle();
  }

  bool on(WidgetTester tester, String key) =>
      tester.widget<SwitchListTile>(find.byKey(Key('sharing-$key'))).value;

  group('what you show', () {
    testWidgets(
      'adult defaults: local time and distance on, visitors and birthday off',
      (tester) async {
        await open(tester, SharingApi(), '/profile/settings');
        expect(find.byKey(const Key('sharing-group')), findsOneWidget);
        expect(on(tester, 'showLocalTime'), isTrue);
        expect(on(tester, 'showDistance'), isTrue);
        expect(on(tester, 'visitorsVisibleToOthers'), isFalse);
        expect(on(tester, 'showBirthday'), isFalse);
        // The honest notes are there in words.
        expect(find.textContaining('never the year'), findsOneWidget);
        expect(find.textContaining('work out your birth date'), findsOneWidget);
        expect(find.textContaining('last 30 days'), findsWidgets);
      },
    );

    testWidgets('each switch sends exactly its own setting', (tester) async {
      final api = SharingApi();
      await open(tester, api, '/profile/settings');
      for (final key in [
        'showLocalTime',
        'showDistance',
        'visitorsVisibleToOthers',
        'showBirthday',
      ]) {
        await tester.ensureVisible(find.byKey(Key('sharing-$key')));
        await tester.tap(find.byKey(Key('sharing-$key')));
        await tester.pumpAndSettle();
      }
      expect(api.patches, [
        {'showLocalTime': false},
        {'showDistance': false},
        {'visitorsVisibleToOthers': true},
        {'showBirthday': true},
      ]);
      expect(on(tester, 'showLocalTime'), isFalse);
      expect(on(tester, 'showBirthday'), isTrue);
    });

    testWidgets(
      'the birthday audience appears with the switch and is saved on its own',
      (tester) async {
        final api = SharingApi();
        api.values['showBirthday'] = true;
        await open(tester, api, '/profile/settings');
        await tester.ensureVisible(
          find.byKey(const Key('sharing-birthday-audience')),
        );
        expect(
          find.byKey(const Key('sharing-birthday-audience')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('sharing-birthday-audience')),
            matching: find.byType(OutlinedButton),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('audience-nobody')));
        await tester.pumpAndSettle();
        expect(api.patches.single, {
          'fieldAudiences': {'birthday': 'nobody'},
        });
      },
    );

    testWidgets(
      'minor: visitors and birthday are off, disabled, and say why; nothing is sent',
      (tester) async {
        final api = SharingApi()..minor = true;
        api.values['showLocalTime'] = false;
        api.values['showDistance'] = false;
        await open(tester, api, '/profile/settings');
        for (final key in ['visitorsVisibleToOthers', 'showBirthday']) {
          await tester.ensureVisible(find.byKey(Key('sharing-$key')));
          final tile = tester.widget<SwitchListTile>(
            find.byKey(Key('sharing-$key')),
          );
          expect(tile.value, isFalse, reason: key);
          expect(tile.onChanged, isNull, reason: key);
        }
        expect(
          find.text('Not available for members under 18.'),
          findsNWidgets(2),
        );
        expect(
          find.byKey(const Key('sharing-birthday-audience')),
          findsNothing,
        );
        // Local time and distance are the minor's own choice, off by default.
        expect(on(tester, 'showLocalTime'), isFalse);
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('sharing-showLocalTime')),
              )
              .onChanged,
          isNotNull,
        );
        expect(api.patches, isEmpty);
      },
    );

    testWidgets('a refused change re-reads the settings and says so', (
      tester,
    ) async {
      final api = SharingApi()
        ..patchFailure = const ApiFailure(
          'Your settings changed. Reload before saving.',
          412,
        );
      await open(tester, api, '/profile/settings');
      await tester.ensureVisible(find.byKey(const Key('sharing-showDistance')));
      await tester.tap(find.byKey(const Key('sharing-showDistance')));
      await tester.pumpAndSettle();
      expect(on(tester, 'showDistance'), isTrue);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('a locked answer from the server is not swallowed', (
      tester,
    ) async {
      final api = SharingApi()
        ..patchFailure = const ApiFailure(
          'This setting stays more private for members under 18.',
          422,
          'MINOR_SETTING_LOCKED',
        );
      await open(tester, api, '/profile/settings');
      await tester.ensureVisible(
        find.byKey(const Key('sharing-visitorsVisibleToOthers')),
      );
      await tester.tap(
        find.byKey(const Key('sharing-visitorsVisibleToOthers')),
      );
      await tester.pumpAndSettle();
      expect(on(tester, 'visitorsVisibleToOthers'), isFalse);
    });

    for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
      testWidgets('320 px wide at text scale 2.0 does not overflow ($dir)', (
        tester,
      ) async {
        final api = SharingApi();
        api.values['showBirthday'] = true;
        await open(
          tester,
          api,
          '/profile/settings',
          size: const Size(320, 900),
          scale: 2,
          dir: dir,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('sharing-showBirthday')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('settings-/profile/places')),
          findsOneWidget,
        );
      });
    }

    testWidgets('the way to "Places I\'ve visited" is on the settings screen', (
      tester,
    ) async {
      await open(tester, SharingApi(), '/profile/settings');
      await tester.ensureVisible(
        find.byKey(const Key('settings-/profile/places')),
      );
      await tester.tap(find.byKey(const Key('settings-/profile/places')));
      await tester.pumpAndSettle();
      expect(find.text('Places I’ve visited'), findsOneWidget);
    });
  });

  group('places I have visited', () {
    testWidgets(
      'own history, newest first, with the plain note that only you see it',
      (tester) async {
        final api = SharingApi()
          ..places = [
            visited('p1', 'Mira', daysAgo: 1),
            visited('p2', 'Arjun', daysAgo: 3),
          ];
        await open(tester, api, '/profile/places');
        expect(find.byKey(const Key('places-note')), findsOneWidget);
        expect(
          find.textContaining('Only you can see this list'),
          findsOneWidget,
        );
        expect(find.text('Mira'), findsOneWidget);
        expect(find.textContaining('yesterday'), findsOneWidget);
        expect(find.textContaining('3 days ago'), findsOneWidget);
      },
    );

    testWidgets('empty and error states are calm', (tester) async {
      await open(tester, SharingApi(), '/profile/places');
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.byKey(const Key('places-clear')), findsNothing);
    });

    testWidgets('clearing asks first, deletes, and shows the empty state', (
      tester,
    ) async {
      final api = SharingApi()..places = [visited('p1', 'Mira')];
      await open(tester, api, '/profile/places');
      await tester.tap(find.byKey(const Key('places-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Clear your history?'), findsOneWidget);
      expect(
        find.textContaining('doesn’t change anyone’s visitor count'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(api.placesCleared, 0);
      await tester.tap(find.byKey(const Key('places-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.placesCleared, 1);
      expect(find.text('Nothing here yet'), findsOneWidget);
    });

    testWidgets('long histories page', (tester) async {
      final api = SharingApi()
        ..places = [for (var i = 0; i < 4; i++) visited('p$i', 'Person$i')]
        ..nextPlaces = 'c2';
      await open(tester, api, '/profile/places');
      expect(find.text('Person0'), findsOneWidget);
      expect(find.text('Person3'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('list-more')));
      await tester.tap(find.byKey(const Key('list-more')));
      await tester.pumpAndSettle();
      expect(api.placeCursors, [null, 'c2']);
      expect(find.text('Person3'), findsOneWidget);
    });

    testWidgets('320 px at text scale 2.0, right to left', (tester) async {
      final api = SharingApi()..places = [visited('p1', 'Mira')];
      await open(
        tester,
        api,
        '/profile/places',
        size: const Size(320, 800),
        scale: 2,
        dir: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('recent visitors of someone else', () {
    testWidgets('the list, with the note that visiting adds you for 30 days', (
      tester,
    ) async {
      final api = SharingApi()
        ..visitorList = [
          visited('v1', 'Mira', daysAgo: 2),
          visited('v2', 'Arjun', daysAgo: 5),
        ];
      await open(tester, api, '/person/$nikoId/visitors');
      expect(find.byKey(const Key('recent-visitors-note')), findsOneWidget);
      expect(find.textContaining('show up here for 30 days'), findsOneWidget);
      expect(find.text('Mira'), findsOneWidget);
      expect(find.text('Arjun'), findsOneWidget);
    });

    testWidgets('empty: nobody in the last 30 days', (tester) async {
      await open(tester, SharingApi(), '/person/$nikoId/visitors');
      expect(find.text('No recent visitors'), findsOneWidget);
    });

    testWidgets(
      'a member who does not share is a calm refusal, not an error to retry',
      (tester) async {
        final api = SharingApi()
          ..visitorsFailure = const ApiFailure('no', 403, 'VISITORS_PRIVATE');
        await open(tester, api, '/person/$nikoId/visitors');
        expect(find.text('Not shared'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
      },
    );

    testWidgets('a member who is unavailable is a calm "not available"', (
      tester,
    ) async {
      final api = SharingApi()
        ..visitorsFailure = const ApiFailure('gone', 404, 'NOT_FOUND');
      await open(tester, api, '/person/$nikoId/visitors');
      expect(find.text('Not available'), findsOneWidget);
    });

    testWidgets(
      'a profile that shares its visitors offers the list and says visiting adds you',
      (tester) async {
        await open(tester, SharingApi(), '/person/$nikoId');
        final entry = find.byKey(const Key('recent-visitors-entry'));
        expect(entry, findsOneWidget);
        expect(find.textContaining('show up here for 30 days'), findsOneWidget);
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('recent-visitors-note')), findsOneWidget);
      },
    );
  });
}
