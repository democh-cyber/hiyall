import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/settings.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class SettingsApi extends FakeApi {
  final sessionList = <Map<String, dynamic>>[
    {
      'sessionId': 'other',
      'platform': 'web',
      'current': false,
      'createdAt': '2026-10-01T09:00:00Z',
      'lastSeenAt': '2026-10-02T09:00:00Z',
      'expiresAt': '2026-12-01T09:00:00Z',
    },
    {
      'sessionId': 'mine',
      'platform': 'android',
      'current': true,
      'createdAt': '2026-10-05T09:00:00Z',
      'lastSeenAt': '2026-10-08T09:00:00Z',
      'expiresAt': '2026-12-01T09:00:00Z',
    },
    {
      'sessionId': 'tablet',
      'platform': 'ios',
      'current': false,
      'createdAt': '2026-10-03T09:00:00Z',
      'lastSeenAt': '2026-10-03T09:00:00Z',
      'expiresAt': '2026-12-01T09:00:00Z',
    },
  ];

  @override
  Future<Map<String, dynamic>> sessions(Session s, [String? cursor]) async => {
    'items': sessionList,
    'nextCursor': null,
  };

  @override
  Future<void> revokeSession(Session s, String id) async {
    calls.add('revoke $id');
    sessionList.removeWhere((x) => x['sessionId'] == id);
  }

  @override
  Future<int> revokeOtherSessions(Session s) async {
    calls.add('revoke-others');
    final before = sessionList.length;
    sessionList.removeWhere((x) => x['current'] != true);
    return before - sessionList.length;
  }

  @override
  Future<ApiPage<Map<String, dynamic>>> myReports(
    Session s, [
    String? cursor,
  ]) async => const ApiPage([
    {
      'reportId': 'r1',
      'targetType': 'user',
      'targetId': nikoId,
      'subject': {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
      'reasonCode': 'scam',
      'status': 'dismissed',
      'createdAt': '2026-10-07T09:00:00Z',
    },
  ], null);
}

Future<ProviderContainer> open(
  WidgetTester tester,
  FakeApi api,
  String at,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const KairovaApp()),
  );
  container.read(routerProvider).go(at);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test('Relative times read naturally', () {
    final now = DateTime(2026, 10, 8, 12);
    expect(timeAgo(now.subtract(const Duration(seconds: 30)), now), 'just now');
    expect(timeAgo(now.subtract(const Duration(minutes: 7)), now), '7 min ago');
    expect(timeAgo(now.subtract(const Duration(hours: 3)), now), '3 h ago');
    expect(timeAgo(now.subtract(const Duration(days: 1)), now), 'yesterday');
    expect(timeAgo(now.subtract(const Duration(days: 4)), now), '4 days ago');
    expect(timeAgo(DateTime(2026, 9, 1, 12), now), '1/9/2026');
  });

  test('A refused signed-in request reports the session ended', () async {
    var ended = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 401,
                data: {
                  'error': {'code': 'UNAUTHENTICATED', 'message': 'x'},
                },
              ),
            ),
          ),
        ),
      );
    final api = ApiClient(dio: dio)..onUnauthorized = () => ended++;
    await expectLater(
      api.profile(const Session('t', anjaliId)),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
    );
    expect(ended, 1);
  });

  testWidgets('An ended session returns to sign-in and says why', (
    tester,
  ) async {
    final container = await open(tester, FakeApi(), '/home');
    container.read(sessionProvider.notifier).expire();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-ended')), findsOneWidget);
    expect(container.read(sessionProvider).asData?.value, isNull);
  });

  testWidgets('Sessions put this device first and sign others out', (
    tester,
  ) async {
    final api = SettingsApi();
    await open(tester, api, '/profile/sessions');
    final tiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => t.key)
        .toList();
    expect(tiles.first, const Key('session-mine'));
    expect(find.text('THIS DEVICE'), findsOneWidget);
    expect(find.text('Web browser'), findsOneWidget);
    expect(find.text('iPhone'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('session-other')),
        matching: find.text('Sign out'),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.calls, contains('revoke other'));
    expect(find.text('Web browser'), findsNothing);

    final others = find.byKey(const Key('revoke-others'));
    await tester.scrollUntilVisible(
      others,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(others);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-revoke-others')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('revoke-others'));
    expect(find.text('iPhone'), findsNothing);
    expect(find.text('Signed out of 1 session.'), findsOneWidget);
    expect(find.byKey(const Key('revoke-others')), findsNothing);
  });

  testWidgets(
    'Privacy explains Discover needs a public profile and can discard',
    (tester) async {
      final api = FakeApi();
      await open(tester, api, '/profile/privacy');
      final discover = find.byKey(const Key('privacy-discoverable'));
      await tester.scrollUntilVisible(
        discover,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('discover-needs-public')), findsNothing);
      await tester.tap(discover);
      await tester.pumpAndSettle();
      // The fixture's profile is friends-only.
      expect(find.byKey(const Key('discover-needs-public')), findsOneWidget);
      expect(find.text('Save privacy settings'), findsOneWidget);
      await tester.tap(find.byKey(const Key('privacy-discard')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discover-needs-public')), findsNothing);
      expect(find.text('Save privacy settings'), findsNothing);
      expect(api.saved, isNull);
    },
  );

  testWidgets('Reports show where each one stands', (tester) async {
    await open(tester, SettingsApi(), '/profile/reports');
    expect(find.text('Niko'), findsOneWidget);
    expect(find.text('NO VIOLATION FOUND'), findsOneWidget);
    expect(find.textContaining('Scam or fraud'), findsOneWidget);
  });

  testWidgets('Appearance choice applies immediately', (tester) async {
    final container = await open(tester, FakeApi(), '/profile/settings');
    final choice = find.byKey(const Key('theme-choice'));
    await tester.scrollUntilVisible(
      choice,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(container.read(themeProvider), ThemeMode.dark);
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(container.read(themeProvider), ThemeMode.system);
  });
}
