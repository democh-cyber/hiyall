import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/core/location_service.dart';
import 'package:hiyall/core/location_sync.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/discovery.dart' show distanceLabel;
import 'package:hiyall/shared/presence_dot.dart';
import 'package:hiyall/shared/press_scale.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class FakeLocation implements LocationService {
  LocationFailure? failure;
  int reads = 0;
  LocationProblem? openedFor;
  @override
  Future<LocationFix> current() async {
    reads++;
    if (failure != null) throw failure!;
    return const LocationFix(12.9716, 77.5946);
  }

  @override
  Future<void> openSettings(LocationProblem problem) async =>
      openedFor = problem;
}

Profile near(String id, String name, int km, {bool? online}) => Profile(
  userId: id,
  username: name.toLowerCase(),
  displayName: name,
  bio: '',
  profession: '',
  version: '',
  headline: '$name’s headline',
  country: 'IN',
  online: online,
  distanceKm: km,
);

Profile everyone(String id, String name) => Profile(
  userId: id,
  username: name.toLowerCase(),
  displayName: name,
  bio: '',
  profession: '',
  version: '',
  headline: '$name’s headline',
);

class DiscoverApi extends FakeApi {
  List<Profile> everyoneList = [everyone('e1', 'Everyone')];
  List<Profile> nearbyList = [];
  ApiFailure? nearbyFailure;
  final log = <String>[];
  final nearbyFilters = <PeopleFilters?>[];
  final searches = <Map<String, dynamic>>[];
  ({double lat, double lon})? shared;

  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async {
    log.add('search');
    searches.add(filters);
    return {
      'items': [
        for (final p in everyoneList)
          {
            'userId': p.userId,
            'username': p.username,
            'displayName': p.displayName,
            'headline': p.headline,
          },
      ],
      'nextCursor': null,
    };
  }

  @override
  Future<ApiPage<Profile>> nearby(
    Session s, {
    PeopleFilters? filters,
    int radiusKm = 50,
    String? cursor,
  }) async {
    log.add('nearby');
    nearbyFilters.add(filters);
    if (nearbyFailure != null) throw nearbyFailure!;
    return ApiPage(nearbyList, null);
  }

  @override
  Future<LocationStatus> shareLocation(
    Session s,
    double latitude,
    double longitude,
  ) async {
    log.add('share');
    shared = (lat: latitude, lon: longitude);
    return LocationStatus(true, DateTime.now());
  }

  @override
  Future<void> stopSharingLocation(Session s) async => log.add('stop');
  @override
  Future<void> logout(Session s) async => log.add('logout');
}

Future<ProviderContainer> openDiscover(
  WidgetTester tester,
  DiscoverApi api,
  FakeLocation location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      locationServiceProvider.overrideWithValue(location),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
  );
  container.read(routerProvider).go('/discover');
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('models and requests', () {
    test('Distances are shown as rounded-up buckets', () {
      expect(distanceLabel(1), 'Within 1 km');
      expect(distanceLabel(0), 'Within 1 km');
      expect(distanceLabel(5), 'Within 5 km');
    });

    test('A result carries its distance bucket and presence', () {
      final person = Profile.fromJson({
        'userId': 'u1',
        'username': 'niko',
        'displayName': 'Niko',
        'distanceKm': 3,
        'online': true,
      });
      expect(person.distanceKm, 3);
      expect(person.online, isTrue);
      final plain = Profile.fromJson({
        'userId': 'u2',
        'username': 'a',
        'displayName': 'A',
      });
      expect(plain.distanceKm, isNull);
      expect(plain.online, isNull);
    });

    test('Location status never carries coordinates', () {
      final status = LocationStatus.fromJson({
        'sharing': true,
        'updatedAt': '2026-10-10T10:00:00Z',
      });
      expect(status.sharing, isTrue);
      expect(status.updatedAt, DateTime.utc(2026, 10, 10, 10));
      expect(LocationStatus.fromJson({'sharing': false}).updatedAt, isNull);
    });

    test('Nearby is a filter that clears and counts like the others', () {
      expect(PeopleFilters().isEmpty, isTrue);
      expect(PeopleFilters(nearby: true).isEmpty, isFalse);
      // It is not a search field: it picks another route.
      expect(
        PeopleFilters(nearby: true).toJson().containsKey('nearby'),
        isFalse,
      );
    });

    test('Each location problem has its own plain message', () {
      final messages = {for (final p in LocationProblem.values) p: p.message};
      expect(messages.values.toSet().length, LocationProblem.values.length);
    });

    test('The nearby request carries the filters and a fixed radius', () async {
      late RequestOptions seen;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seen = options;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': {
                      'items': [
                        {
                          'userId': 'u1',
                          'username': 'niko',
                          'displayName': 'Niko',
                          'distanceKm': 2,
                        },
                      ],
                      'nextCursor': 'next',
                    },
                  },
                ),
              );
            },
          ),
        );
      final api = ApiClient(dio: dio);
      final page = await api.nearby(
        const Session('t', 'me'),
        filters: PeopleFilters(country: 'IN', languages: ['en'], nearby: true),
      );
      expect(seen.method, 'POST');
      expect(seen.path, '/v1/discover/nearby');
      expect(seen.data, {
        'interests': <String>[],
        'languages': ['en'],
        'country': 'IN',
        'vibe': '',
        'radiusKm': 50,
      });
      expect(page.items.single.distanceKm, 2);
      expect(page.nextCursor, 'next');
    });
  });

  group('age and gender filters', () {
    test('Age and gender are sent only when chosen', () {
      expect(PeopleFilters().toJson().keys, isNot(contains('ageMin')));
      expect(PeopleFilters().toJson().keys, isNot(contains('gender')));
      final json = PeopleFilters(
        ageMin: 18,
        ageMax: 34,
        gender: 'woman',
      ).toJson();
      expect(json['ageMin'], 18);
      expect(json['ageMax'], 34);
      expect(json['gender'], 'woman');
      expect(
        PeopleFilters(ageMin: 18).toJson().keys,
        isNot(contains('ageMax')),
      );
      expect(PeopleFilters(ageMax: 17).isEmpty, isFalse);
      expect(PeopleFilters(gender: 'man').isEmpty, isFalse);
      expect(PeopleFilters(ageMin: 18).hasAge, isTrue);
    });

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

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
    }

    Future<void> showPeople(WidgetTester tester) async {
      await tester.tap(find.text('Show people'));
      await tester.pumpAndSettle();
    }

    testWidgets('The sheet starts open-ended and sends nothing until changed', (
      tester,
    ) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      await openSheet(tester);
      expect(find.byKey(const Key('filter-age-label')), findsOneWidget);
      expect(find.text('13 to 60+ years old'), findsOneWidget);
      await showPeople(tester);
      // Nothing changed, so no filter chips appear.
      expect(find.textContaining('years'), findsNothing);
    });

    testWidgets(
      'An age range and a gender narrow the search and show as chips',
      (tester) async {
        final api = DiscoverApi();
        await openDiscover(tester, api, FakeLocation());
        await openSheet(tester);
        final slider = tester.widget<RangeSlider>(
          find.byKey(const Key('filter-age')),
        );
        slider.onChanged!(const RangeValues(18, 34));
        await tester.pumpAndSettle();
        expect(find.text('18 to 34 years old'), findsOneWidget);
        await reveal(tester, find.byKey(const Key('filter-gender-woman')));
        await tester.tap(find.byKey(const Key('filter-gender-woman')));
        await tester.pumpAndSettle();
        await showPeople(tester);
        expect(api.searches.last['ageMin'], 18);
        expect(api.searches.last['ageMax'], 34);
        expect(api.searches.last['gender'], 'woman');
        expect(
          tester.widget<Text>(find.byKey(const Key('filter-count'))).data,
          '2',
        );
      },
    );

    testWidgets('A gender alone shows as a chip that can be removed', (
      tester,
    ) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      await openSheet(tester);
      await reveal(tester, find.byKey(const Key('filter-gender-nonbinary')));
      await tester.tap(find.byKey(const Key('filter-gender-nonbinary')));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.searches.last['gender'], 'nonbinary');
      expect(find.byKey(const Key('filter-count')), findsOneWidget);
      await tester.tap(find.byKey(const Key('discover-reset')));
      await tester.pumpAndSettle();
      expect(api.searches.last.keys, isNot(contains('gender')));
    });

    testWidgets('Dragging to the top stop means no upper limit', (
      tester,
    ) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      await openSheet(tester);
      tester
          .widget<RangeSlider>(find.byKey(const Key('filter-age')))
          .onChanged!(const RangeValues(21, 60));
      await tester.pumpAndSettle();
      expect(find.text('21 to 60+ years old'), findsOneWidget);
      await showPeople(tester);
      expect(api.searches.last['ageMin'], 21);
      expect(api.searches.last.keys, isNot(contains('ageMax')));
      expect(find.byKey(const Key('filter-count')), findsOneWidget);
    });

    testWidgets('Removing the age chip searches again without it', (
      tester,
    ) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      await openSheet(tester);
      tester
          .widget<RangeSlider>(find.byKey(const Key('filter-age')))
          .onChanged!(const RangeValues(18, 25));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.searches.last['ageMin'], 18);
      await tester.tap(find.byKey(const Key('discover-reset')));
      await tester.pumpAndSettle();
      expect(api.searches.last.keys, isNot(contains('ageMin')));
      expect(api.searches.last.keys, isNot(contains('ageMax')));
    });

    testWidgets('Reset clears age and gender with the rest', (tester) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      await openSheet(tester);
      tester
          .widget<RangeSlider>(find.byKey(const Key('filter-age')))
          .onChanged!(const RangeValues(18, 25));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-active-filters')));
      await tester.pumpAndSettle();
      expect(find.text('13 to 60+ years old'), findsOneWidget);
    });

    testWidgets('Age and gender combine with My surroundings', (tester) async {
      final api = DiscoverApi()..nearbyList = [near('n1', 'Niko', 2)];
      await openDiscover(tester, api, FakeLocation());
      await openSheet(tester);
      tester
          .widget<RangeSlider>(find.byKey(const Key('filter-age')))
          .onChanged!(const RangeValues(18, 30));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const Key('filter-nearby')));
      await tester.tap(find.byKey(const Key('filter-nearby')));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const Key('filter-gender-man')));
      await tester.tap(find.byKey(const Key('filter-gender-man')));
      await tester.pumpAndSettle();
      await showPeople(tester);
      expect(api.log.last, 'nearby');
      final used = api.nearbyFilters.last!;
      expect(
        (used.ageMin, used.ageMax, used.gender, used.nearby),
        (18, 30, 'man', true),
      );
    });
  });

  group('Discover', () {
    testWidgets('Everyone is the default and no location controls exist', (
      tester,
    ) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      expect(api.log.where((e) => e == 'search'), isNotEmpty);
      expect(find.text('Nearby'), findsOneWidget);
      expect(find.textContaining('Share my location'), findsNothing);
      expect(find.textContaining('Stop sharing'), findsNothing);
      expect(find.text('Everyone'), findsWidgets);
    });

    testWidgets('The Nearby tab lists people with distances and presence', (
      tester,
    ) async {
      final api = DiscoverApi()
        ..nearbyList = [
          near('n1', 'Niko', 1, online: true),
          near('n2', 'Anjali', 5),
        ];
      await openDiscover(tester, api, FakeLocation());
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      expect(api.log.last, 'nearby');
      expect(api.nearbyFilters.last!.nearby, isTrue);
      expect(find.text('Niko'), findsOneWidget);
      expect(find.text('Within 1 km'), findsOneWidget);
      expect(find.text('Within 5 km'), findsOneWidget);
      expect(find.byKey(const Key('online-dot-n1')), findsOneWidget);
      expect(find.byKey(const Key('online-dot-n2')), findsNothing);
      // The shared dot, and nothing at all for a person who is not online or hides it.
      expect(find.byType(PresenceDot), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('My surroundings in the filters combines with the others', (
      tester,
    ) async {
      final api = DiscoverApi()..nearbyList = [near('n1', 'Niko', 2)];
      await openDiscover(tester, api, FakeLocation());
      await tester.tap(find.text('Filters'));
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
      expect(api.log.last, 'nearby');
      expect(find.text('Niko'), findsOneWidget);
      // It is exactly the Nearby category, so that chip is the selected one.
      expect(
        tester
            .widget<PressScale>(find.byKey(const Key('chip-nearby')))
            .selected,
        isTrue,
      );
    });

    testWidgets('Switching back to Everyone searches normally again', (
      tester,
    ) async {
      final api = DiscoverApi()..nearbyList = [near('n1', 'Niko', 2)];
      await openDiscover(tester, api, FakeLocation());
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Everyone'));
      await tester.pumpAndSettle();
      expect(api.log.last, 'search');
      expect(find.text('Everyone'), findsWidgets);
    });

    testWidgets('An empty area says so without offering a toggle', (
      tester,
    ) async {
      final api = DiscoverApi();
      await openDiscover(tester, api, FakeLocation());
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nobody nearby right now'), findsOneWidget);
    });

    testWidgets('Without a position it explains and can retry', (tester) async {
      final api = DiscoverApi()
        ..nearbyFailure = const ApiFailure(
          'Share your location to see people nearby.',
          409,
          'LOCATION_NOT_SHARED',
        );
      final location = FakeLocation();
      await openDiscover(tester, api, location);
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('needs-location')), findsOneWidget);
      expect(find.byKey(const Key('location-settings')), findsNothing);
      // The position becomes available and the list loads.
      api
        ..nearbyFailure = null
        ..nearbyList = [near('n1', 'Niko', 3)];
      await tester.tap(find.byKey(const Key('location-retry')));
      await tester.pumpAndSettle();
      expect(api.shared, (lat: 12.9716, lon: 77.5946));
      expect(find.text('Niko'), findsOneWidget);
      expect(find.byKey(const Key('needs-location')), findsNothing);
    });

    testWidgets('A blocked permission offers the device settings', (
      tester,
    ) async {
      final api = DiscoverApi()
        ..nearbyFailure = const ApiFailure(
          'Share your location to see people nearby.',
          409,
          'LOCATION_NOT_SHARED',
        );
      final location = FakeLocation()
        ..failure = const LocationFailure(LocationProblem.deniedForever);
      final container = await openDiscover(tester, api, location);
      // The automatic read at start-up already failed.
      expect(
        container.read(locationProblemProvider),
        LocationProblem.deniedForever,
      );
      await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
      await tester.tap(find.byKey(const Key('chip-nearby')));
      await tester.pumpAndSettle();
      expect(find.textContaining('device settings'), findsOneWidget);
      await tester.tap(find.byKey(const Key('location-settings')));
      await tester.pump();
      expect(location.openedFor, LocationProblem.deniedForever);
    });
  });

  group('automatic location', () {
    testWidgets('Opening the app reads the position once and shares it', (
      tester,
    ) async {
      final api = DiscoverApi();
      final location = FakeLocation();
      await openDiscover(tester, api, location);
      expect(location.reads, 1);
      expect(api.shared, (lat: 12.9716, lon: 77.5946));
      expect(api.log.where((e) => e == 'share'), hasLength(1));
    });

    testWidgets('Coming back soon after does not read it again', (
      tester,
    ) async {
      final api = DiscoverApi();
      final location = FakeLocation();
      await openDiscover(tester, api, location);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(location.reads, 1);
    });

    testWidgets('Returning after the interval reads it again', (tester) async {
      final api = DiscoverApi();
      final location = FakeLocation();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(api),
            sessionProvider.overrideWith(SignedIn.new),
            locationServiceProvider.overrideWithValue(location),
          ],
          child: const MaterialApp(
            home: LocationSync(interval: Duration.zero, child: SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(location.reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(location.reads, 2);
    });

    testWidgets('Nothing is read before onboarding is finished', (
      tester,
    ) async {
      final api = DiscoverApi();
      final location = FakeLocation();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(api),
            sessionProvider.overrideWith(NotOnboarded.new),
            locationServiceProvider.overrideWithValue(location),
          ],
          child: const MaterialApp(home: LocationSync(child: SizedBox())),
        ),
      );
      await tester.pumpAndSettle();
      expect(location.reads, 0);
      expect(api.log, isEmpty);
    });

    testWidgets(
      'A refused permission is remembered and a later success clears it',
      (tester) async {
        final api = DiscoverApi();
        final location = FakeLocation()
          ..failure = const LocationFailure(LocationProblem.denied);
        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiProvider.overrideWithValue(api),
              sessionProvider.overrideWith(SignedIn.new),
              locationServiceProvider.overrideWithValue(location),
            ],
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const MaterialApp(
                  home: LocationSync(
                    interval: Duration.zero,
                    child: SizedBox(),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(container.read(locationProblemProvider), LocationProblem.denied);
        expect(api.log, isEmpty, reason: 'no position, nothing sent');
        location.failure = null;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(container.read(locationProblemProvider), isNull);
        expect(api.log, ['share']);
      },
    );

    testWidgets('A position read before signing out is never sent', (
      tester,
    ) async {
      final api = DiscoverApi();
      final location = SlowLocation()..gate = Completer();
      final container = await syncing(tester, api, location);
      await container.read(sessionProvider.notifier).logout();
      location.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.log, ['stop', 'logout']);
    });

    testWidgets('Signing out waits for a position already on its way', (
      tester,
    ) async {
      final api = SlowShareApi()..gate = Completer();
      final container = await syncing(tester, api, FakeLocation());
      await tester.pump();
      expect(api.log, ['share sent']);
      final out = container.read(sessionProvider.notifier).logout();
      await tester.pump();
      expect(api.log, ['share sent'], reason: 'the removal waits');
      api.gate!.complete();
      await out;
      await tester.pumpAndSettle();
      expect(api.log, ['share sent', 'share', 'stop', 'logout']);
    });

    test('Signing out stops sharing the position', () async {
      final api = DiscoverApi();
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(SignedIn.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).logout();
      expect(api.log, ['stop', 'logout']);
      expect(container.read(sessionProvider).asData?.value, isNull);
    });
  });
}

/// A position read and an upload that each wait on their own gate.
class SlowLocation extends FakeLocation {
  Completer<void>? gate;
  @override
  Future<LocationFix> current() async {
    await gate?.future;
    return super.current();
  }
}

class SlowShareApi extends DiscoverApi {
  Completer<void>? gate;
  @override
  Future<LocationStatus> shareLocation(
    Session s,
    double latitude,
    double longitude,
  ) async {
    log.add('share sent');
    await gate?.future;
    return super.shareLocation(s, latitude, longitude);
  }
}

Future<ProviderContainer> syncing(
  WidgetTester tester,
  DiscoverApi api,
  LocationService location,
) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
        locationServiceProvider.overrideWithValue(location),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return const MaterialApp(home: LocationSync(child: SizedBox()));
        },
      ),
    ),
  );
  await tester.pump();
  return container;
}

class NotOnboarded extends SessionController {
  @override
  AsyncValue<Session?> build() =>
      const AsyncData(Session('t', anjaliId, onboarded: false));
}
