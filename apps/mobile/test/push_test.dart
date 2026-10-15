import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/push/push_controller.dart';
import 'package:hiyall/core/push/push_prefs.dart';
import 'package:hiyall/core/push/push_service.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/features/notification_settings.dart';

import 'widget_test.dart' show SignedIn;
import 'support/fixtures.dart';

const conversation = '019a4000-0000-7000-8000-0000000000c1';

class FakePush implements PushService {
  FakePush({this.permissionNow = PushPermission.notAsked});
  PushPermission permissionNow;

  /// What the system dialog answers.
  PushPermission dialogAnswer = PushPermission.granted;
  String? current = 'token-1';
  PushTap? initial;
  int requested = 0, deleted = 0;
  final refresh = StreamController<String>.broadcast();
  final tapped = StreamController<PushTap>.broadcast();
  @override
  bool get supported => true;
  @override
  Future<PushPermission> permission() async => permissionNow;
  @override
  Future<PushPermission> requestPermission() async {
    requested++;
    if (permissionNow == PushPermission.notAsked) permissionNow = dialogAnswer;
    return permissionNow;
  }

  @override
  Future<String?> token() async => current;
  @override
  Stream<String> get tokenRefresh => refresh.stream;
  @override
  Future<void> deleteToken() async {
    deleted++;
    current = null;
  }

  @override
  Stream<PushTap> get taps => tapped.stream;
  @override
  Future<PushTap?> initialTap() async {
    final tap = initial;
    initial = null;
    return tap;
  }
}

class FakeBackend implements PushBackend {
  final registered = <(String, String)>[];
  final cleared = <String>[];
  final patches = <Map<String, bool>>[];
  var chat = true, social = true;
  bool offline = false;
  @override
  Future<String?> deviceId() async => 'device-1';
  @override
  Future<void> register(String deviceId, String token) async {
    if (offline) throw StateError('offline');
    registered.add((deviceId, token));
  }

  @override
  Future<void> clear(String deviceId) async => cleared.add(deviceId);
  @override
  Future<Map<String, bool>> prefs() async => {'chat': chat, 'social': social};
  @override
  Future<Map<String, bool>> setPrefs(Map<String, bool> patch) async {
    patches.add(patch);
    chat = patch['chat'] ?? chat;
    social = patch['social'] ?? social;
    return prefs();
  }
}

/// A session the test can sign in and out.
class Switchable extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
  void signIn({bool onboarded = true}) => state = AsyncData(
    Session('test-only-token', anjaliId, onboarded: onboarded),
  );
}

class Rig {
  Rig({
    PushService? service,
    this.signedIn = true,
    PushPrefsStore? store,
    DateTime? now,
    this.api,
  }) : service = service ?? FakePush(),
       store = store ?? MemoryPushPrefsStore(),
       clock = now ?? DateTime.utc(2026, 10, 13, 12) {
    container = ProviderContainer(
      overrides: [
        pushServiceProvider.overrideWithValue(this.service),
        pushBackendProvider.overrideWithValue(backend),
        pushPrefsStoreProvider.overrideWithValue(this.store),
        pushClockProvider.overrideWithValue(() => clock),
        pushOpenerProvider.overrideWithValue(opened.add),
        chatEngineSourceProvider.overrideWith((ref) async => null),
        if (api != null) apiProvider.overrideWithValue(api!),
        sessionProvider.overrideWith(signedIn ? SignedIn.new : Switchable.new),
      ],
    );
  }
  final PushService service;
  final PushPrefsStore store;
  final ApiClient? api;
  final bool signedIn;
  DateTime clock;
  final backend = FakeBackend();
  final opened = <String>[];
  late final ProviderContainer container;

  FakePush get fake => service as FakePush;
  PushController get controller =>
      container.read(pushControllerProvider.notifier);
  PushState get state => container.read(pushControllerProvider);

  /// Starts the controller the way the app shell does and lets it settle.
  Future<void> start() async {
    container.listen(pushControllerProvider, (_, _) {});
    await pumpEventQueue();
  }

  void dispose() => container.dispose();
}

void main() {
  group('permission timing', () {
    test('nothing is asked at launch', () async {
      final rig = Rig();
      addTearDown(rig.dispose);
      await rig.start();
      expect(rig.fake.requested, 0);
      expect(rig.state.explainerDue, isFalse);
      expect(rig.backend.registered, isEmpty);
    });

    test('a first message or follow asks for the explainer, once', () async {
      final rig = Rig();
      addTearDown(rig.dispose);
      await rig.start();
      rig.container.read(apiProvider).onFollowed!();
      await pumpEventQueue();
      expect(rig.state.explainerDue, isTrue);
      expect(
        rig.fake.requested,
        0,
        reason: 'the system dialog follows the sheet',
      );

      await rig.controller.accept();
      expect(rig.fake.requested, 1);
      expect(rig.state.explainerDue, isFalse);
      expect(rig.state.permission, PushPermission.granted);
      expect(rig.backend.registered, [('device-1', 'token-1')]);
    });

    test('a sent message counts too', () async {
      // The chat relay tells the app after it accepted a message.
      var told = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
        ..httpClientAdapter = _Accepts();
      final chat = ChatApi(
        'http://127.0.0.1:8080',
        't',
        onSent: () => told++,
        dio: dio,
      );
      await chat.send(conversation, {'messageId': 'm1'});
      expect(told, 1);
    });

    test('"Not now" is remembered and the ask waits 14 days', () async {
      final store = MemoryPushPrefsStore();
      var rig = Rig(store: store);
      await rig.start();
      await rig.controller.engaged();
      expect(rig.state.explainerDue, isTrue);
      await rig.controller.notNow();
      expect(rig.state.explainerDue, isFalse);
      expect(store.notNow[anjaliId], DateTime.utc(2026, 10, 13, 12));
      // Still the same run: no second ask however often they engage.
      await rig.controller.engaged();
      expect(rig.state.explainerDue, isFalse);
      rig.dispose();

      for (final (days, asks) in [
        (1, false),
        (13, false),
        (14, true),
        (30, true),
      ]) {
        rig = Rig(
          store: store,
          now: DateTime.utc(2026, 10, 13, 12).add(Duration(days: days)),
        );
        await rig.start();
        await rig.controller.engaged();
        expect(rig.state.explainerDue, asks, reason: 'after $days days');
        rig.dispose();
      }
    });

    test('a refusal at the system dialog ends the asking', () async {
      final rig = Rig(
        service: FakePush()..dialogAnswer = PushPermission.denied,
      );
      addTearDown(rig.dispose);
      await rig.start();
      await rig.controller.engaged();
      await rig.controller.accept();
      expect(rig.state.permission, PushPermission.denied);
      expect(rig.backend.registered, isEmpty);
      await rig.controller.engaged();
      expect(rig.state.explainerDue, isFalse);
    });

    test('a system-level refusal is never asked about', () async {
      final rig = Rig(service: FakePush(permissionNow: PushPermission.denied));
      addTearDown(rig.dispose);
      await rig.start();
      await rig.controller.engaged();
      expect(rig.state.explainerDue, isFalse);
      expect(rig.fake.requested, 0);
    });
  });

  group('token registration', () {
    test('a granted device registers at launch and on every refresh', () async {
      final rig = Rig(service: FakePush(permissionNow: PushPermission.granted));
      addTearDown(rig.dispose);
      await rig.start();
      expect(rig.backend.registered, [('device-1', 'token-1')]);
      expect(rig.state.registered, isTrue);
      // The same token again changes nothing; a new one is sent.
      rig.fake.refresh.add('token-1');
      rig.fake.refresh.add('token-2');
      await pumpEventQueue();
      expect(rig.backend.registered, [
        ('device-1', 'token-1'),
        ('device-1', 'token-2'),
      ]);
    });

    test(
      'a token that could not be sent is retried on the next trigger',
      () async {
        final rig = Rig(
          service: FakePush(permissionNow: PushPermission.granted),
        );
        addTearDown(rig.dispose);
        rig.backend.offline = true;
        await rig.start();
        expect(rig.state.registered, isFalse);
        rig.backend.offline = false;
        await rig.controller.engaged();
        expect(rig.backend.registered, [('device-1', 'token-1')]);
      },
    );

    test('nothing registers while signed out', () async {
      final rig = Rig(
        service: FakePush(permissionNow: PushPermission.granted),
        signedIn: false,
      );
      addTearDown(rig.dispose);
      await rig.start();
      rig.fake.refresh.add('token-2');
      await pumpEventQueue();
      expect(rig.backend.registered, isEmpty);
    });

    test('sign-out clears the token on the server and on the device', () async {
      final rig = Rig(service: FakePush(permissionNow: PushPermission.granted));
      addTearDown(rig.dispose);
      await rig.start();
      await rig.controller.beforeSignOut();
      expect(rig.backend.cleared, ['device-1']);
      expect(rig.fake.deleted, 1);
      expect(rig.state.registered, isFalse);
    });

    test(
      'the real sign-out clears the token before the session is revoked',
      () async {
        final rig = Rig(
          service: FakePush(permissionNow: PushPermission.granted),
          api: _SignOutApi(),
        );
        addTearDown(rig.dispose);
        await rig.start();
        await rig.container.read(sessionProvider.notifier).logout();
        expect(rig.backend.cleared, ['device-1']);
        expect(rig.fake.deleted, 1);
        expect((rig.api as _SignOutApi).order, ['stopSharing', 'logout']);
      },
    );

    test(
      'switching off in Settings clears it and stays off after a restart',
      () async {
        final store = MemoryPushPrefsStore();
        var rig = Rig(
          service: FakePush(permissionNow: PushPermission.granted),
          store: store,
        );
        await rig.start();
        await rig.controller.disable();
        expect(rig.backend.cleared, ['device-1']);
        expect(rig.state.on, isFalse);
        rig.dispose();

        rig = Rig(
          service: FakePush(permissionNow: PushPermission.granted),
          store: store,
        );
        addTearDown(rig.dispose);
        await rig.start();
        expect(rig.backend.registered, isEmpty);
        await rig.controller.enable();
        expect(rig.backend.registered, [('device-1', 'token-1')]);
        expect(rig.state.on, isTrue);
      },
    );
  });

  group('tap routing', () {
    test(
      'a chat tap opens that conversation, a social tap opens Activity',
      () async {
        final rig = Rig(
          service: FakePush(permissionNow: PushPermission.granted),
        );
        addTearDown(rig.dispose);
        await rig.start();
        rig.fake.tapped.add(
          PushTap.fromData({'kind': 'chat', 'conversationId': conversation})!,
        );
        rig.fake.tapped.add(
          PushTap.fromData({'kind': 'social', 'event': 'follow'})!,
        );
        await pumpEventQueue();
        expect(rig.opened, ['/chats/$conversation', '/notifications']);
      },
    );

    test('a cold start tap opens once the app is up', () async {
      final fake = FakePush(permissionNow: PushPermission.granted)
        ..initial = const PushTap.chat(conversation);
      final rig = Rig(service: fake);
      addTearDown(rig.dispose);
      await rig.start();
      expect(rig.opened, ['/chats/$conversation']);
    });

    test('a cold start tap waits for sign-in', () async {
      final fake = FakePush(permissionNow: PushPermission.granted)
        ..initial = const PushTap.social();
      final rig = Rig(service: fake, signedIn: false);
      addTearDown(rig.dispose);
      await rig.start();
      expect(rig.opened, isEmpty);
      (rig.container.read(sessionProvider.notifier) as Switchable).signIn(
        onboarded: false,
      );
      await pumpEventQueue();
      expect(rig.opened, isEmpty, reason: 'onboarding comes first');
      (rig.container.read(sessionProvider.notifier) as Switchable).signIn();
      await pumpEventQueue();
      expect(rig.opened, ['/notifications']);
    });

    test('payloads that are not ours are ignored', () {
      expect(PushTap.fromData({'kind': 'chat'}), isNull);
      expect(
        PushTap.fromData({'kind': 'chat', 'conversationId': '../../etc'}),
        isNull,
      );
      expect(PushTap.fromData({'kind': 'other'}), isNull);
      expect(PushTap.fromData({}), isNull);
    });
  });

  group('web and tests', () {
    test('without a platform service every call is a no-op', () async {
      final container = ProviderContainer(
        overrides: [
          chatEngineSourceProvider.overrideWith((ref) async => null),
          sessionProvider.overrideWith(SignedIn.new),
        ],
      );
      addTearDown(container.dispose);
      expect(pushPlatformSupported, isFalse);
      expect(container.read(pushServiceProvider).supported, isFalse);
      final controller = container.read(pushControllerProvider.notifier);
      await controller.engaged();
      await controller.beforeSignOut();
      await pumpEventQueue();
      expect(container.read(pushControllerProvider).explainerDue, isFalse);
      expect(container.read(pushControllerProvider).on, isFalse);
      expect(await const NoopPushService().initialTap(), isNull);
    });
  });

  group('screens', () {
    Future<Rig> pumpApp(WidgetTester tester, Rig rig) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: rig.container,
          child: const MaterialApp(
            home: PushHost(
              child: Scaffold(
                body: SingleChildScrollView(child: NotificationSettingsGroup()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return rig;
    }

    testWidgets('the settings group is absent where push is unsupported', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          chatEngineSourceProvider.overrideWith((ref) async => null),
          sessionProvider.overrideWith(SignedIn.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: NotificationSettingsGroup()),
          ),
        ),
      );
      expect(find.text('NOTIFICATIONS'), findsNothing);
    });

    testWidgets(
      'the explainer sheet: Not now is remembered and nothing is asked',
      (tester) async {
        final rig = Rig();
        addTearDown(rig.dispose);
        await pumpApp(tester, rig);
        expect(find.byKey(const Key('push-explainer-accept')), findsNothing);
        await tester.runAsync(() => rig.controller.engaged());
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('push-explainer-accept')), findsOneWidget);
        await tester.tap(find.byKey(const Key('push-explainer-not-now')));
        await tester.pumpAndSettle();
        await tester.runAsync(pumpEventQueue);
        expect(rig.store, isA<MemoryPushPrefsStore>());
        expect((rig.store as MemoryPushPrefsStore).notNow, isNotEmpty);
        expect(rig.fake.requested, 0);
      },
    );

    testWidgets('the explainer sheet: Turn on registers the device', (
      tester,
    ) async {
      final rig = Rig();
      addTearDown(rig.dispose);
      await pumpApp(tester, rig);
      await tester.runAsync(() => rig.controller.engaged());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('push-explainer-accept')));
      await tester.pumpAndSettle();
      await tester.runAsync(pumpEventQueue);
      expect(rig.fake.requested, 1);
      expect(rig.backend.registered, [('device-1', 'token-1')]);
    });

    testWidgets(
      'Settings: the switch asks first, the choices are saved on the server',
      (tester) async {
        final rig = Rig();
        addTearDown(rig.dispose);
        await pumpApp(tester, rig);
        await tester.pumpAndSettle();
        expect(find.text('NOTIFICATIONS'), findsOneWidget);
        // Off: the two choices wait for it.
        final chat = find.byKey(const Key('notifications-chat'));
        expect(tester.widget<SwitchListTile>(chat).onChanged, isNull);

        await tester.tap(find.byKey(const Key('notifications-push')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('push-explainer-accept')), findsOneWidget);
        await tester.tap(find.byKey(const Key('push-explainer-accept')));
        await tester.pumpAndSettle();
        await tester.runAsync(pumpEventQueue);
        await tester.pumpAndSettle();
        expect(rig.state.on, isTrue);

        await tester.tap(chat);
        await tester.pumpAndSettle();
        await tester.runAsync(pumpEventQueue);
        expect(rig.backend.patches, [
          {'chat': false},
        ]);

        await tester.tap(find.byKey(const Key('notifications-push')));
        await tester.pumpAndSettle();
        await tester.runAsync(pumpEventQueue);
        expect(rig.backend.cleared, ['device-1']);
      },
    );

    testWidgets(
      'Settings: a refusal at the system level is explained, not asked again',
      (tester) async {
        final rig = Rig(
          service: FakePush(permissionNow: PushPermission.denied),
        );
        addTearDown(rig.dispose);
        await pumpApp(tester, rig);
        await tester.runAsync(pumpEventQueue);
        await tester.pumpAndSettle();
        expect(find.textContaining('Off in your phone'), findsOneWidget);
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('notifications-push')),
              )
              .onChanged,
          isNull,
        );
      },
    );
  });
}

class _Accepts implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'success': true,
      'data': {'messageId': 'm1', 'createdAt': '2026-10-13T12:00:00Z'},
    }),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  void close({bool force = false}) {}
}

class _SignOutApi extends ApiClient {
  final order = <String>[];
  @override
  Future<void> stopSharingLocation(Session s) async => order.add('stopSharing');
  @override
  Future<void> logout(Session s) async => order.add('logout');
}
