import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/location_service.dart';

import 'nearby_test.dart' show DiscoverApi, FakeLocation, near, openDiscover;

const _off = ApiFailure('Turn on Show me in Nearby first.', 409, 'NEARBY_OFF');

Future<void> openNearby(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
  await tester.tap(find.byKey(const Key('chip-nearby')));
  await tester.pumpAndSettle();
}

void main() {
  group('Show me in Nearby (Discover)', () {
    testWidgets('Opening Nearby while off asks first and reads nothing', (
      tester,
    ) async {
      final api = DiscoverApi()..nearbyFailure = _off;
      final location = FakeLocation();
      await openDiscover(tester, api, location);
      await openNearby(tester);
      expect(find.byKey(const Key('nearby-optin')), findsOneWidget);
      expect(location.reads, 0);
      expect(api.log.where((e) => e == 'share' || e == 'show'), isEmpty);
    });

    testWidgets('The explainer says what is shared, and Not now keeps it off', (
      tester,
    ) async {
      final api = DiscoverApi()..nearbyFailure = _off;
      final location = FakeLocation();
      await openDiscover(tester, api, location);
      await openNearby(tester);
      await tester.tap(find.byKey(const Key('nearby-optin-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nearby-explainer')), findsOneWidget);
      expect(find.text('What’s shared'), findsOneWidget);
      expect(find.text('Who can see it'), findsOneWidget);
      expect(find.text('How long'), findsOneWidget);
      expect(find.text('How to stop'), findsOneWidget);
      expect(find.byKey(const Key('nearby-explainer-minor')), findsNothing);
      await tester.tap(find.byKey(const Key('nearby-explainer-cancel')));
      await tester.pumpAndSettle();
      expect(location.reads, 0);
      expect(api.log.where((e) => e == 'share' || e == 'show'), isEmpty);
      expect(find.byKey(const Key('nearby-optin')), findsOneWidget);
    });

    testWidgets('Agreeing turns it on, reads one position and lists people', (
      tester,
    ) async {
      final api = DiscoverApi()
        ..nearbyFailure = _off
        ..nearbyList = [near('n1', 'Niko', 5)];
      final location = FakeLocation();
      await openDiscover(tester, api, location);
      await openNearby(tester);
      await tester.tap(find.byKey(const Key('nearby-optin-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nearby-explainer-confirm')));
      await tester.pumpAndSettle();
      expect(location.reads, 1);
      expect(api.log.where((e) => e == 'show'), hasLength(1));
      expect(api.shared, (lat: 12.9716, lon: 77.5946));
      expect(find.text('Niko'), findsOneWidget);
      expect(find.byKey(const Key('nearby-optin')), findsNothing);
    });

    testWidgets('A refused permission leaves Nearby on and explains', (
      tester,
    ) async {
      final api = DiscoverApi()
        ..nearbyFailure = _off
        ..keepFailure = true;
      final location = FakeLocation()
        ..failure = const LocationFailure(LocationProblem.denied);
      await openDiscover(tester, api, location);
      await openNearby(tester);
      await tester.tap(find.byKey(const Key('nearby-optin-button')));
      await tester.pumpAndSettle();
      api.nearbyFailure = const ApiFailure(
        'Share your location to see people nearby.',
        409,
        'LOCATION_NOT_SHARED',
      );
      await tester.tap(find.byKey(const Key('nearby-explainer-confirm')));
      await tester.pumpAndSettle();
      expect(api.shared, isNull);
      expect(find.byKey(const Key('needs-location')), findsOneWidget);
    });

    testWidgets('Under 18 gets the stronger explainer', (tester) async {
      final api = DiscoverApi()
        ..nearbyFailure = _off
        ..status = const NearbyStatus(minor: true);
      await openDiscover(tester, api, FakeLocation());
      await openNearby(tester);
      await tester.tap(find.byKey(const Key('nearby-optin-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nearby-explainer-minor')), findsOneWidget);
      expect(find.textContaining('under 18'), findsWidgets);
    });
  });

  group('Show me in Nearby (Settings)', () {
    Future<void> openSettings(
      WidgetTester tester,
      DiscoverApi api,
      FakeLocation location,
    ) async {
      final container = await openDiscover(tester, api, location);
      tester.view.physicalSize = const Size(390, 2400);
      container.read(routerProvider).go('/profile/settings');
      await tester.pumpAndSettle();
    }

    testWidgets('The switch starts off and switching on shows the explainer', (
      tester,
    ) async {
      final api = DiscoverApi();
      final location = FakeLocation();
      await openSettings(tester, api, location);
      final toggle = find.byKey(const Key('nearby-toggle'));
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nearby-explainer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nearby-explainer-confirm')));
      await tester.pumpAndSettle();
      expect(api.log, containsAllInOrder(['show', 'share']));
      expect(location.reads, 1);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    });

    testWidgets('Switching off tells the server, which deletes the area', (
      tester,
    ) async {
      final api = DiscoverApi()..status = const NearbyStatus(visible: true);
      await openSettings(tester, api, FakeLocation());
      final toggle = find.byKey(const Key('nearby-toggle'));
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(api.log, contains('hide'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    });
  });
}
