import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_info.dart';
import 'package:hiyall/core/deep_link.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/system_screens.dart';

import 'spaces_test.dart' show SpacesFake;
import 'support/fixtures.dart';

class _Capture implements HttpClientAdapter {
  _Capture(this.status, [this.body = const {}]);
  final int status;
  final Map<String, dynamic> body;
  final headers = <Map<String, dynamic>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    headers.add(Map.of(options.headers));
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A session the test can switch on and off.
class _Switch extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
  void signIn({bool onboarded = true}) =>
      state = AsyncData(Session('t', anjaliId, onboarded: onboarded));
}

void main() {
  group('X-Client-Version and 426', () {
    test('every API call carries the app version', () async {
      final adapter = _Capture(200, {
        'success': true,
        'data': {'sharing': false, 'updatedAt': null},
      });
      final api = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
          ..httpClientAdapter = adapter,
      );
      await api.stopSharingLocation(const Session('tok', 'u'));
      await api
          .profile(const Session('tok', 'u'))
          .catchError(
            (_) => Profile.fromJson({
              'userId': 'u',
              'username': 'u',
              'displayName': 'U',
            }),
          );
      expect(adapter.headers, hasLength(2));
      for (final h in adapter.headers) {
        expect(h[clientVersionHeader], AppInfo.version);
        expect(h['Authorization'], 'Bearer tok');
      }
      expect(clientVersionHeader, 'X-Client-Version');
      expect(AppInfo.version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });

    test(
      '426 UPGRADE_REQUIRED tells the app and fails with that code',
      () async {
        final api = ApiClient(
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
            ..httpClientAdapter = _Capture(426, {
              'success': false,
              'error': {
                'code': 'UPGRADE_REQUIRED',
                'message': 'Update the app.',
              },
            }),
        );
        var told = 0;
        api.onUpgradeRequired = () => told++;
        await expectLater(
          api.profile(const Session('tok', 'u')),
          throwsA(
            isA<ApiFailure>()
                .having((f) => f.status, 'status', 426)
                .having((f) => f.code, 'code', 'UPGRADE_REQUIRED'),
          ),
        );
        expect(told, 1);
      },
    );

    test('a 426 without that code is an ordinary failure', () async {
      final api = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
          ..httpClientAdapter = _Capture(426, {'success': false}),
      );
      var told = 0;
      api.onUpgradeRequired = () => told++;
      await expectLater(
        api.profile(const Session('t', 'u')),
        throwsA(isA<ApiFailure>()),
      );
      expect(told, 0);
    });
  });

  group('the Update Hiyall screen', () {
    testWidgets('is the only thing shown once the server asks for an update', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(SpacesFake()..blocked = false),
          sessionProvider.overrideWith(_Switch.new),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier);
      (container.read(sessionProvider.notifier) as _Switch).signIn();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      final router = container.read(routerProvider);
      expect(router.state.uri.path, '/home');

      container.read(upgradeRequiredProvider.notifier).set();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/update');
      expect(find.text('Update Hiyall'), findsOneWidget);

      // Nothing else can be opened.
      router.go('/profile');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/update');
    });

    testWidgets(
      'offers the store for this platform and says which version this is',
      (tester) async {
        // Tests run as Android by default.
        await tester.pumpWidget(
          const MaterialApp(home: UpdateRequiredScreen()),
        );
        expect(find.byKey(const Key('update-open-store')), findsOneWidget);
        expect(find.textContaining(AppInfo.display), findsOneWidget);
        expect(
          storeUrlFor(web: false, platform: TargetPlatform.android),
          AppInfo.playStoreUrl,
        );
        expect(
          storeUrlFor(web: false, platform: TargetPlatform.iOS),
          AppInfo.appStoreUrl,
        );
        expect(storeUrlFor(web: true), isEmpty);
      },
    );
  });

  group('deep links', () {
    test('only real destinations are remembered', () {
      final memory = DeepLinkMemory();
      for (final skip in [
        '/welcome',
        '/login',
        '/splash',
        '/onboarding',
        '/home',
        '/',
        '/verify-email',
      ]) {
        memory.remember(Uri.parse(skip));
        expect(memory.pending, isNull, reason: skip);
      }
      memory.remember(Uri.parse('/chats/abc?peer=1&name=Niko'));
      expect(memory.take(), '/chats/abc?peer=1&name=Niko');
      expect(memory.take(), isNull, reason: 'taken once');
    });

    testWidgets('a link opened while signed out is opened after signing in', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(SpacesFake()..blocked = false),
          sessionProvider.overrideWith(_Switch.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      final router = container.read(routerProvider);
      expect(router.state.uri.path, '/welcome');

      router.go('/person/$nikoId');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/welcome', reason: 'signed out');

      (container.read(sessionProvider.notifier) as _Switch).signIn();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/person/$nikoId');
      expect(container.read(deepLinkMemoryProvider).pending, isNull);
    });

    testWidgets('a signed-in launch without a link still lands on Home', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(SpacesFake()..blocked = false),
          sessionProvider.overrideWith(_Switch.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      (container.read(sessionProvider.notifier) as _Switch).signIn();
      await tester.pumpAndSettle();
      expect(container.read(routerProvider).state.uri.path, '/home');
    });

    testWidgets('the link survives onboarding', (tester) async {
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(SpacesFake()..blocked = false),
          sessionProvider.overrideWith(_Switch.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      final router = container.read(routerProvider);
      router.go('/discover/person/$nikoId');
      await tester.pumpAndSettle();
      (container.read(sessionProvider.notifier) as _Switch).signIn(
        onboarded: false,
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/onboarding');
      container.read(sessionProvider.notifier).markOnboarded();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/discover/person/$nikoId');
    });
  });

  group('404 and Back', () {
    testWidgets('an unknown link shows the branded page, with a way home', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(SpacesFake()..blocked = false),
          sessionProvider.overrideWith(_Switch.new),
        ],
      );
      addTearDown(container.dispose);
      (container.read(sessionProvider.notifier) as _Switch).signIn();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/no/such/page');
      await tester.pumpAndSettle();
      expect(find.text('This page wandered off'), findsOneWidget);
      await tester.tap(find.byKey(const Key('not-found-home')));
      await tester.pumpAndSettle();
      expect(container.read(routerProvider).state.uri.path, '/home');
    });

    testWidgets(
      'Back from Sign up returns to Welcome instead of leaving the app',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(SpacesFake()..blocked = false),
            sessionProvider.overrideWith(_Switch.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const HiyallApp(),
          ),
        );
        await tester.pumpAndSettle();
        final router = container.read(routerProvider);
        await tester.ensureVisible(find.byKey(const Key('create-account')));
        await tester.tap(find.byKey(const Key('create-account')));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/signup');
        expect(router.canPop(), isTrue);
        router.pop();
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/welcome');
      },
    );
  });
}
