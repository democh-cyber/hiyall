import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/notification_prefs.dart';
import 'package:hiyall/core/push/push_controller.dart';
import 'package:hiyall/core/push/push_prefs.dart';
import 'package:hiyall/core/push/push_service.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/notification_settings.dart';

import 'push_test.dart' show FakeBackend, FakePush;
import 'support/scripted_api.dart';
import 'widget_test.dart' show SignedIn;

/// The server's side of GET and PATCH /v1/me/notifications.
class PrefsServer {
  final values = <String, bool>{
    'enabled': true,
    'chat': true,
    'follows': true,
    'friendRequests': true,
    'comments': true,
    'replies': true,
    'reactions': true,
    'visits': false,
    'hideNames': false,
    'social': true,
  };
  final patches = <Map<String, dynamic>>[];
  Object? fail;

  /// Holds a PATCH open until the test lets it go.
  Completer<void>? gate;

  void install(ScriptedApi api) {
    api.on('GET /v1/me/notifications', (_, _) => {...values});
    api.on('PATCH /v1/me/notifications', (body, _) async {
      final patch = Map<String, dynamic>.from(body! as Map);
      patches.add(patch);
      await gate?.future;
      final error = fail;
      if (error != null) throw error;
      for (final e in patch.entries) {
        values[e.key] = e.value as bool;
      }
      return {...values};
    });
  }
}

ProviderContainer containerFor(ScriptedApi api) => ProviderContainer(
  overrides: [
    apiProvider.overrideWithValue(api),
    sessionProvider.overrideWith(SignedIn.new),
    pushServiceProvider.overrideWithValue(
      FakePush(permissionNow: PushPermission.granted),
    ),
    pushBackendProvider.overrideWithValue(FakeBackend()),
    pushPrefsStoreProvider.overrideWithValue(MemoryPushPrefsStore()),
    chatEngineSourceProvider.overrideWith((ref) async => null),
  ],
);

Future<void> pumpGroup(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(400, 2600),
  double textScale = 1,
  TextDirection? direction,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: direction == null
            ? null
            : (context, child) =>
                  Directionality(textDirection: direction, child: child!),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: NotificationSettingsGroup(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder tile(String field) => find.byKey(Key('notifications-$field'));
bool isOn(WidgetTester tester, String field) =>
    tester.widget<SwitchListTile>(tile(field)).value;
bool enabled(WidgetTester tester, String field) =>
    tester.widget<SwitchListTile>(tile(field)).onChanged != null;

void main() {
  late PrefsServer server;
  late ScriptedApi api;
  late ProviderContainer container;
  setUp(() {
    server = PrefsServer();
    api = ScriptedApi();
    server.install(api);
    container = containerFor(api);
  });
  tearDown(() => container.dispose());

  testWidgets('every choice is shown; profile visits start off', (
    tester,
  ) async {
    await pumpGroup(tester, container);
    for (final f in [
      'enabled',
      'chat',
      'follows',
      'friendRequests',
      'comments',
      'replies',
      'reactions',
      'visits',
      'hideNames',
    ]) {
      expect(tile(f), findsOneWidget, reason: f);
    }
    expect(isOn(tester, 'visits'), isFalse);
    expect(isOn(tester, 'follows'), isTrue);
    expect(find.text('Profile visits'), findsOneWidget);
    expect(
      find.textContaining('opens your profile for the first time'),
      findsOneWidget,
    );
    expect(find.textContaining('instead of naming the person'), findsOneWidget);
    // Nothing is sent just by opening the screen.
    expect(server.patches, isEmpty);
  });

  testWidgets('hide names follows what the server says (on for a minor)', (
    tester,
  ) async {
    server.values['hideNames'] = true;
    await pumpGroup(tester, container);
    expect(isOn(tester, 'hideNames'), isTrue);
  });

  testWidgets('each switch sends only its own field', (tester) async {
    await pumpGroup(tester, container);
    final cases = {
      'chat': false,
      'follows': false,
      'friendRequests': false,
      'comments': false,
      'replies': false,
      'reactions': false,
      'visits': true,
      'hideNames': true,
    };
    for (final e in cases.entries) {
      await tester.tap(tile(e.key));
      await tester.pumpAndSettle();
      expect(server.patches.last, {e.key: e.value}, reason: e.key);
      expect(isOn(tester, e.key), e.value, reason: e.key);
    }
    expect(server.patches, hasLength(cases.length));
    expect(
      server.patches.any((p) => p.containsKey('social')),
      isFalse,
      reason: 'the legacy umbrella is never sent',
    );
  });

  testWidgets('master off disables the rest and says why', (tester) async {
    await pumpGroup(tester, container);
    expect(enabled(tester, 'chat'), isTrue);
    await tester.tap(tile('enabled'));
    await tester.pumpAndSettle();
    expect(server.patches.single, {'enabled': false});
    for (final f in [
      'chat',
      'follows',
      'friendRequests',
      'comments',
      'replies',
      'reactions',
      'visits',
      'hideNames',
    ]) {
      expect(enabled(tester, f), isFalse, reason: f);
    }
    // The master itself can be turned back on.
    expect(enabled(tester, 'enabled'), isTrue);
    expect(find.textContaining('Security alerts'), findsOneWidget);
    // Their values are kept, not reset.
    expect(isOn(tester, 'follows'), isTrue);

    await tester.tap(tile('enabled'));
    await tester.pumpAndSettle();
    expect(server.patches.last, {'enabled': true});
    expect(enabled(tester, 'chat'), isTrue);
  });

  testWidgets('a refused change rolls back and shows the server’s words', (
    tester,
  ) async {
    await pumpGroup(tester, container);
    server.fail = const ApiFailure('Please wait a moment and try again.', 429);
    server.gate = Completer();
    await tester.tap(tile('comments'));
    await tester.pump();
    // Optimistic: the switch moved at once, while the server has not answered.
    expect(isOn(tester, 'comments'), isFalse);
    server.gate!.complete();
    await tester.pumpAndSettle();
    expect(isOn(tester, 'comments'), isTrue);
    expect(find.text('Please wait a moment and try again.'), findsOneWidget);
    expect(server.values['comments'], isTrue);
  });

  testWidgets('a failed rollback keeps other switches as they were', (
    tester,
  ) async {
    await pumpGroup(tester, container);
    await tester.tap(tile('reactions'));
    await tester.pumpAndSettle();
    server.fail = const ApiFailure('Nope', 500);
    await tester.tap(tile('replies'));
    await tester.pumpAndSettle();
    expect(isOn(tester, 'replies'), isTrue);
    expect(isOn(tester, 'reactions'), isFalse);
  });

  testWidgets('offline: an error row with Retry, then the switches', (
    tester,
  ) async {
    api.routes.remove('GET /v1/me/notifications');
    await pumpGroup(tester, container);
    expect(find.byKey(const Key('notifications-error')), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(tile('follows'), findsNothing);

    server.install(api);
    await tester.tap(find.byKey(const Key('notifications-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications-error')), findsNothing);
    expect(tile('follows'), findsOneWidget);
  });

  test('the model fills in what an older server leaves out', () {
    final p = NotificationPrefs.fromJson({'chat': false});
    expect(p[NotificationPref.chat], isFalse);
    expect(p[NotificationPref.enabled], isTrue);
    expect(p[NotificationPref.visits], isFalse);
  });

  for (final scale in [1.0, 2.0]) {
    for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
      for (final b in Brightness.values) {
        testWidgets('fits 320 wide at text x$scale, $dir, ${b.name}', (
          tester,
        ) async {
          await pumpGroup(
            tester,
            container,
            size: const Size(320, 6000),
            textScale: scale,
            direction: dir,
            brightness: b,
          );
          expect(tester.takeException(), isNull);
          expect(tile('visits'), findsOneWidget);
        });
      }
    }
  }
}
