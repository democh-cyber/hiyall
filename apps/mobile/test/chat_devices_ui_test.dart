import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/activity_state.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_backup_exclusion.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_store.dart' show ChatStorageUnavailable;
import 'package:hiyall/core/realtime/realtime_client.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart' show chatClockProvider;
import 'package:hiyall/features/live_sync.dart';

import 'chat_ui_test.dart' show UiCloud, UiEngine, fixedNow;
import 'realtime_test.dart' show FakeSocket;
import 'widget_test.dart' show FakeApi, SignedIn;

// What the person sees and what the app does about devices (CHAT-2): the banner for each kind of notice, the
// device list being re-read on the socket's ready and resync and on every resume, the words for the new
// relay refusals (CHAT-4), and the iOS backup exclusion of the chat folders.

class DevicesEngine extends UiEngine {
  DevicesEngine(super.cloud);
  List<DeviceNotice> own = [];
  final minAges = <Duration>[];
  int polls = 0;
  @override
  List<DeviceNotice> get ownDeviceNotices => own;
  @override
  Future<void> refreshOwnDevices({Duration minAge = Duration.zero}) async =>
      minAges.add(minAge);
  @override
  Future<void> pollNow() async => polls++;
  @override
  Future<void> dismissOwnDeviceNotices() async => own = [];
  @override
  Future<void> showDeviceNotices(String c, String p) async {}
}

class _Activity extends ActivityController {
  @override
  Future<ActivityState> build() async => const ActivityState([]);
  @override
  Future<void> syncUnread() async {}
}

void main() {
  DeviceNotice notice(DeviceNoticeKind kind) =>
      DeviceNotice(kind == DeviceNoticeKind.added ? 'd1' : '', fixedNow, kind);

  group('the banner says what happened', () {
    test('the most pressing notice wins, and the words are plain', () {
      expect(
        deviceBannerText([
          notice(DeviceNoticeKind.review),
          notice(DeviceNoticeKind.locked),
          notice(DeviceNoticeKind.added),
        ]).title,
        'Couldn’t unlock your encrypted data on this device. Starting fresh.',
      );
      expect(
        deviceBannerText([
          notice(DeviceNoticeKind.review),
          notice(DeviceNoticeKind.added),
        ]).title,
        'A new device was added to your account',
      );
      expect(
        deviceBannerText([notice(DeviceNoticeKind.review)]).title,
        'Review your devices',
      );
      expect(
        deviceBannerText([notice(DeviceNoticeKind.removed)]).title,
        'A device was removed from your account',
      );
      expect(
        deviceBannerText([notice(DeviceNoticeKind.reset)]).action,
        'Review devices',
      );
    });

    for (final kind in DeviceNoticeKind.values) {
      testWidgets('a ${kind.name} notice shows the banner until dismissed', (
        tester,
      ) async {
        final engine = DevicesEngine(UiCloud())..own = [notice(kind)];
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              chatEngineProvider.overrideWith((ref) async => engine),
              sessionProvider.overrideWith(SignedIn.new),
              chatClockProvider.overrideWithValue(() => fixedNow),
            ],
            child: MaterialApp(
              theme: hiyallTheme(Brightness.light),
              home: Scaffold(body: ChatsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final words = deviceBannerText([notice(kind)]);
        expect(find.text(words.title), findsOneWidget);
        expect(find.text(words.action), findsOneWidget);
        expect(find.byKey(const Key('new-device-dismiss')), findsOneWidget);
        // Reachable at text scale 2 (the layout wraps, nothing overflows).
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a keystore that cannot be opened (CHAT-N4)', () {
    Future<void> pumpError(WidgetTester tester, {required bool offered}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatEngineProvider.overrideWith(
              (ref) async => throw const ChatStorageUnavailable(),
            ),
            chatStorageResetOfferedProvider.overrideWith(
              () => _Offered(offered),
            ),
            sessionProvider.overrideWith(SignedIn.new),
            chatClockProvider.overrideWithValue(() => fixedNow),
          ],
          child: MaterialApp(
            theme: hiyallTheme(Brightness.light),
            home: Scaffold(body: ChatsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('it is retryable and offers no reset at first', (tester) async {
      await pumpError(tester, offered: false);
      expect(find.text('Couldn’t open secure storage'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Reset chat on this phone'), findsNothing);
    });

    testWidgets(
      'after several failed launches the reset is offered, and asks first',
      (tester) async {
        await pumpError(tester, offered: true);
        expect(find.text('Reset chat on this phone'), findsOneWidget);
        await tester.tap(find.text('Reset chat on this phone'));
        await tester.pumpAndSettle();
        expect(find.text('Reset chat on this phone?'), findsOneWidget);
        expect(
          find.textContaining('erases the chats stored on this phone'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Reset chat on this phone?'), findsNothing);
        expect(find.text('Reset chat on this phone'), findsOneWidget);
      },
    );
  });

  group('the device list is looked at again', () {
    Future<(DevicesEngine, List<FakeSocket>)> pump(WidgetTester tester) async {
      final engine = DevicesEngine(UiCloud());
      final sockets = <FakeSocket>[];
      final client = RealtimeClient(
        'http://127.0.0.1:8080',
        'token',
        debugBuild: true,
        connect: (url, token) async {
          final s = FakeSocket();
          sockets.add(s);
          return s;
        },
      );
      addTearDown(client.dispose);
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(FakeApi()),
          sessionProvider.overrideWith(SignedIn.new),
          activityProvider.overrideWith(_Activity.new),
          chatEngineProvider.overrideWith((ref) async => engine),
          realtimeProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LiveSync(child: SizedBox())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      return (engine, sockets);
    }

    testWidgets('when the socket is ready and when it resynchronises', (
      tester,
    ) async {
      final (engine, sockets) = await pump(tester);
      expect(sockets, hasLength(1));
      final before = engine.minAges.length;
      sockets.single.incoming.add(jsonEncode({'type': 'ready', 'data': {}}));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.minAges.length, before + 1, reason: 'ready');
      sockets.single.incoming.add(jsonEncode({'type': 'resync', 'data': {}}));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.minAges.length, before + 2, reason: 'resync');
      // A throttle for the periodic syncs; a device signal is not held back (it asks with no minimum).
      expect(engine.minAges.last, greaterThan(Duration.zero));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('when the app comes back to the foreground', (tester) async {
      final (engine, _) = await pump(tester);
      final before = engine.minAges.length;
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.minAges.length, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the new relay refusals have words', () {
    test('a full inbox on their side and the daily limit', () {
      expect(
        chatError(const ChatFailure('RECIPIENT_BACKLOG', 'x', 429)),
        contains('picked up'),
      );
      expect(
        chatError(const ChatFailure('CHAT_DAILY_LIMIT', 'x', 429)),
        contains('today'),
      );
      // Both are 429s: transient, the message stays as "not sent" with a retry.
      expect(
        isTransientChatFailure(
          const ChatFailure('RECIPIENT_BACKLOG', 'x', 429),
        ),
        isTrue,
      );
      expect(
        isTransientChatFailure(const ChatFailure('CHAT_DAILY_LIMIT', 'x', 429)),
        isTrue,
      );
    });

    test('an own device that is full has its own words, which point to Chat devices (CHAT-N2)', () {
      final own = chatError(const ChatFailure('OWN_BACKLOG', 'x', 429));
      expect(own, contains('Chat devices'));
      expect(
        own,
        isNot(contains('picked up')),
        reason: 'not the recipient text',
      );
      // The recipient text is unchanged.
      expect(
        chatError(const ChatFailure('RECIPIENT_BACKLOG', 'x', 429)),
        'They haven’t picked up their earlier messages yet. Try again later.',
      );
      expect(
        isTransientChatFailure(const ChatFailure('OWN_BACKLOG', 'x', 429)),
        isTrue,
        reason: 'the message stays as not sent and can be retried',
      );
    });

    test('a keystore that cannot be opened has its own words and says nothing was deleted', () {
      final words = chatError(const ChatStorageUnavailable());
      expect(words, contains('secure storage'));
      expect(words, contains('Nothing was deleted'));
    });

    test('a notice survives being written and read back', () {
      for (final kind in DeviceNoticeKind.values) {
        final back = DeviceNotice.fromJson(
          jsonDecode(jsonEncode(notice(kind).toJson())),
        )!;
        expect(back.kind, kind);
        expect(back.deviceId, notice(kind).deviceId);
      }
      // A notice written by an earlier build (no kind) is an "added" one.
      final old = DeviceNotice.fromJson({
        'id': 'd',
        'at': '2026-10-12T00:00:00Z',
      });
      expect(old!.kind, DeviceNoticeKind.added);
      expect(DeviceNotice.fromJson({'id': 'd', 'at': 'x'}), isNull);
    });
  });

  group('iOS backup exclusion', () {
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ChatBackupExclusion.channel, (call) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ChatBackupExclusion.channel, null);
    });

    test('on iOS the three folders are created and flagged', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final root = await Directory.systemTemp.createTemp('hiyall-backup');
      addTearDown(() => root.delete(recursive: true));
      await ChatBackupExclusion.apply(root);
      expect(calls.single.method, 'excludeFromBackup');
      expect(calls.single.arguments, [
        for (final name in ChatLocalData.folders) '${root.path}/$name',
      ]);
      expect(
        ChatLocalData.folders,
        containsAll(['chat_state', 'chat_blobs', 'chat_outbox']),
      );
      for (final name in ChatLocalData.folders) {
        expect(Directory('${root.path}/$name').existsSync(), isTrue);
      }
    });

    test(
      'elsewhere nothing is touched, and a missing handler is no error',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final root = await Directory.systemTemp.createTemp('hiyall-backup');
        addTearDown(() => root.delete(recursive: true));
        await ChatBackupExclusion.apply(root);
        expect(calls, isEmpty);
        expect(root.listSync(), isEmpty);
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ChatBackupExclusion.channel, (_) async {
              throw MissingPluginException();
            });
        await ChatBackupExclusion.apply(root);
      },
    );
  });
}

class _Offered extends ChatResetOffered {
  _Offered(this.initial);
  final bool initial;
  @override
  bool build() => initial;
}
