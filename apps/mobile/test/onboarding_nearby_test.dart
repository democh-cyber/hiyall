import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/location_service.dart';
import 'package:hiyall/core/state.dart';

import 'auth_test.dart'
    show
        AuthApi,
        FakeGateway,
        chooseBirthDate,
        fillOnboarding,
        launch,
        location,
        next,
        type;

/// What the "Find people near you" step does: it explains, asks nothing until the person taps, and nothing it
/// does can keep anyone out of the app.
class NearbyAuthApi extends AuthApi {
  final nearbyCalls = <String>[];
  Object? nearbyFailure;
  @override
  Future<NearbyStatus> nearbyStatus(Session s) async {
    nearbyCalls.add('status');
    return const NearbyStatus();
  }

  @override
  Future<NearbyStatus> showMeInNearby(Session s) async {
    nearbyCalls.add('on');
    if (nearbyFailure != null) throw nearbyFailure!;
    return const NearbyStatus(visible: true);
  }

  @override
  Future<LocationStatus> shareLocation(
    Session s,
    double latitude,
    double longitude,
  ) async {
    nearbyCalls.add('share');
    return LocationStatus(true, DateTime(2026));
  }
}

class CountingLocation implements LocationService {
  int reads = 0;
  LocationFailure? failure;
  @override
  Future<LocationFix> current() async {
    reads++;
    if (failure != null) throw failure!;
    return const LocationFix(12.9716, 77.5946);
  }

  @override
  Future<void> openSettings(LocationProblem problem) async {}
}

AuthGateway gateway() => FakeGateway(
  const AuthUser(
    uid: 'u',
    method: AuthMethod.google,
    email: 'sam@example.com',
    emailVerified: true,
  ),
);

void main() {
  testWidgets(
    'the last step is the optional Nearby step and says what it shares',
    (tester) async {
      final api = NearbyAuthApi();
      final place = CountingLocation();
      await launch(
        tester,
        api: api,
        gateway: gateway(),
        overrides: [locationServiceProvider.overrideWithValue(place)],
      );
      await fillOnboarding(tester);
      expect(find.text('STEP 6 OF 6'), findsOneWidget);
      expect(find.text('Find people near you'), findsWidgets);
      expect(find.byKey(const Key('onb-nearby-step')), findsOneWidget);
      // What is shared, for how long, who sees it, how to stop.
      expect(find.text('What’s shared'), findsOneWidget);
      expect(find.text('Who can see it'), findsOneWidget);
      expect(find.text('How long'), findsOneWidget);
      expect(find.text('How to stop'), findsOneWidget);
      expect(find.textContaining('24 hours'), findsOneWidget);
      expect(find.textContaining('Never your exact spot'), findsOneWidget);
      expect(find.byKey(const Key('onb-nearby-on')), findsOneWidget);
      expect(find.byKey(const Key('onb-finish')), findsOneWidget);
      expect(find.text('Turn on Nearby'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      // Looking at it asked for nothing.
      expect(place.reads, 0);
      expect(api.nearbyCalls, isEmpty);
    },
  );

  testWidgets(
    '"Not now" enters the app and touches neither Nearby nor the location',
    (tester) async {
      final api = NearbyAuthApi();
      final place = CountingLocation();
      final container = await launch(
        tester,
        api: api,
        gateway: gateway(),
        overrides: [locationServiceProvider.overrideWithValue(place)],
      );
      await fillOnboarding(tester);
      await next(tester, 'onb-finish');
      expect(api.completed, isNotNull);
      expect(location(container), isNot('/onboarding'));
      expect(api.nearbyCalls, isEmpty);
      expect(place.reads, 0);
    },
  );

  testWidgets(
    '"Turn on Nearby" finishes sign-up first, then switches it on and shares an area',
    (tester) async {
      final api = NearbyAuthApi();
      final place = CountingLocation();
      final container = await launch(
        tester,
        api: api,
        gateway: gateway(),
        overrides: [locationServiceProvider.overrideWithValue(place)],
      );
      await fillOnboarding(tester);
      await next(tester, 'onb-nearby-on');
      await tester.pumpAndSettle();
      expect(api.completed, isNotNull);
      expect(location(container), isNot('/onboarding'));
      expect(api.nearbyCalls, ['on', 'share']);
      expect(place.reads, 1);
    },
  );

  testWidgets('a refused location permission never blocks sign-up', (
    tester,
  ) async {
    final api = NearbyAuthApi();
    final place = CountingLocation()
      ..failure = const LocationFailure(LocationProblem.denied);
    final container = await launch(
      tester,
      api: api,
      gateway: gateway(),
      overrides: [locationServiceProvider.overrideWithValue(place)],
    );
    await fillOnboarding(tester);
    await next(tester, 'onb-nearby-on');
    await tester.pumpAndSettle();
    expect(api.completed, isNotNull);
    expect(location(container), isNot('/onboarding'));
    expect(tester.takeException(), isNull);
    // Nearby is on without an area; nothing is shown about the person.
    expect(api.nearbyCalls, ['on']);
  });

  testWidgets('a server failure while turning Nearby on never blocks sign-up', (
    tester,
  ) async {
    final api = NearbyAuthApi()..nearbyFailure = const ApiFailure('down', 503);
    final container = await launch(
      tester,
      api: api,
      gateway: gateway(),
      overrides: [
        locationServiceProvider.overrideWithValue(CountingLocation()),
      ],
    );
    await fillOnboarding(tester);
    await next(tester, 'onb-nearby-on');
    await tester.pumpAndSettle();
    expect(api.completed, isNotNull);
    expect(location(container), isNot('/onboarding'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an adult sees the adult wording, a member under 18 the stronger one',
    (tester) async {
      Future<void> reach(String year) async {
        await launch(tester, api: NearbyAuthApi(), gateway: gateway());
        await chooseBirthDate(tester, year: year);
        await tester.tap(find.byKey(const Key('onb-terms')));
        await tester.pump();
        await next(tester);
        await type(tester, 'Display name', 'Sam Rivera');
        await type(tester, 'Username', 'sam_r');
        await next(tester);
        await tester.tap(find.byKey(const Key('onb-skip')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('onb-skip')));
        await tester.pumpAndSettle();
        for (final interest in ['Music', 'Art', 'Travel']) {
          await tester.tap(find.widgetWithText(FilterChip, interest));
          await tester.pump();
        }
        await next(tester);
      }

      await reach('2000');
      expect(find.byKey(const Key('nearby-explainer-minor')), findsNothing);
      expect(find.textContaining('about 1 km wide'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await reach('${DateTime.now().year - 15}');
      expect(find.byKey(const Key('nearby-explainer-minor')), findsOneWidget);
      expect(find.textContaining('about 10 km wide'), findsOneWidget);
      expect(find.textContaining('Only other people under 18'), findsOneWidget);
      // Still skippable.
      expect(find.text('Not now'), findsOneWidget);
    },
  );

  testWidgets(
    'the step fits 320 px at text scale 2.0 and the buttons stay reachable',
    (tester) async {
      final api = NearbyAuthApi();
      await launch(tester, api: api, gateway: gateway());
      await fillOnboarding(tester);
      // On the last step, narrow the screen and double the text.
      tester.view.physicalSize = const Size(320, 700);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('onb-nearby-on')));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('onb-finish')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('onb-nearby-on'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const Key('onb-finish'))).height,
        greaterThanOrEqualTo(48),
      );
    },
  );
}
