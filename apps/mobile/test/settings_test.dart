import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/settings.dart';

import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

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

/// The server's settings move to version 2 behind the app's back.
class StaleSettingsApi extends FakeApi {
  String serverVersion = '1';
  final sentVersions = <String>[];
  @override
  Future<Privacy> privacy(Session s) async =>
      Privacy({...(await super.privacy(s)).values, 'version': serverVersion});
  @override
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async {
    sentVersions.add(p.version);
    if (p.version != serverVersion) {
      throw const ApiFailure(
        'Your settings changed. Reload before saving.',
        412,
      );
    }
    saved = patch;
    return Privacy({...p.values, ...patch, 'version': '${p.version}+'});
  }
}

/// The server blanks the identity of a barred member.
class BarredReportsApi extends SettingsApi {
  @override
  Future<ApiPage<Map<String, dynamic>>> myReports(
    Session s, [
    String? cursor,
  ]) async => const ApiPage([
    {
      'reportId': 'r2',
      'targetType': 'conversation',
      'targetId': 'c1',
      'subject': {'userId': nikoId, 'username': '', 'displayName': ''},
      'reasonCode': 'scam',
      'status': 'open',
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
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
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

  test('Report subjects without a name read as unavailable', () {
    expect(
      reportSubjectName({'displayName': 'Niko', 'username': 'niko'}),
      'Niko',
    );
    expect(
      reportSubjectName({'displayName': ' ', 'username': 'niko'}),
      '@niko',
    );
    expect(
      reportSubjectName({'displayName': '', 'username': ''}),
      'Account unavailable',
    );
    expect(reportSubjectName(null), 'Account unavailable');
  });

  testWidgets('A report about a barred account shows a neutral label', (
    tester,
  ) async {
    await open(tester, BarredReportsApi(), '/profile/reports');
    expect(find.text('Chat with Account unavailable'), findsOneWidget);
    expect(find.textContaining('@'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('A refused online change re-reads settings for the next try', (
    tester,
  ) async {
    final api = StaleSettingsApi();
    await open(tester, api, '/profile/settings');
    api.serverVersion = '2';
    final toggle = find.byKey(const Key('online-toggle'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.text('Your settings changed. Reload before saving.'),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    // Let the message go so it doesn't cover the switch.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(api.sentVersions, ['1', '2']);
    expect(api.saved, {'onlineAudience': 'everyone'});
  });

  group('the one presence switch', () {
    testWidgets(
      'says online and last seen, and is off by default for a hidden account',
      (tester) async {
        await open(tester, FakeApi(), '/profile/settings');
        expect(find.text('Show when I’m online and last seen'), findsOneWidget);
        expect(
          find.text(
            'Everyone can see when you’re active. Turn off to hide both.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('green dot'), findsNothing);
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('online-toggle')))
              .value,
          isFalse,
        );
      },
    );

    testWidgets(
      'turns on to everyone and off to nobody, one setting for both',
      (tester) async {
        final api = OnlineApi();
        await open(tester, api, '/profile/settings');
        final toggle = find.byKey(const Key('online-toggle'));
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(api.saved, {'onlineAudience': 'nobody'});
        expect(api.saved!.keys, [
          'onlineAudience',
        ], reason: 'no lastSeenAudience');
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(api.saved, {'onlineAudience': 'everyone'});
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      },
    );
  });
}

/// An account that shows when it is online.
class OnlineApi extends FakeApi {
  String audience = 'everyone';
  @override
  Future<Privacy> privacy(Session s) async =>
      Privacy({...(await super.privacy(s)).values, 'onlineAudience': audience});
  @override
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async {
    audience = patch['onlineAudience'] as String;
    return super.updatePrivacy(s, p, patch);
  }
}
