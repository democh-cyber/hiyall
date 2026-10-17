import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/features/chat.dart' show chatError, deviceBannerText;
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay;
import 'chat_robustness_test.dart' show Api;

// Round 4 chat findings on the engine: CHAT-N1 (a device the relay signed out as idle comes back with the same
// keys, peers see nothing, a calm note for the owner's other devices, PEER_NO_DEVICES), CHAT-N5 (a re-register
// that fails backs off and rewrites nothing), CHAT-N6 (a pin never leads the notice that announces it). All on
// the real Olm core with an in-memory relay.

/// A relay API that can sign devices out as idle, count registrations, fail them, and answer 404 for a device
/// the relay does not hold (as the real inbox does).
class IdleApi extends Api {
  IdleApi(super.relay, super.user);

  /// Devices the relay removed as idle: the inbox says 404 until the device registers again.
  final idle = <String>{};
  final registrations = <String>[];
  Object? registerFailure;

  /// Takes [deviceId] out of the relay as an idle removal does: it is no longer listed, and its keys are gone.
  void signOutIdle(String deviceId) {
    idle.add(deviceId);
    relay.devices[user]?.remove(deviceId);
    relay.keys[user]?.remove(deviceId);
  }

  @override
  Future<void> registerDevice(Map<String, String> d) async {
    registrations.add(d['deviceId']!);
    if (unknown.contains(d['deviceId'])) {
      throw const ChatFailure('DEVICE_CONFLICT', 'revoked', 409);
    }
    final failure = registerFailure;
    if (failure != null) throw failure;
    idle.remove(d['deviceId']);
    return super.registerDevice(d);
  }

  @override
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async {
    if (idle.contains(deviceId) ||
        !(relay.devices[user]?.containsKey(deviceId) ?? false)) {
      throw const ChatFailure('NOT_FOUND', 'gone', 404);
    }
    return super.inbox(deviceId);
  }
}

/// Counts every write, and can refuse the one that files a "new device" notice in a conversation.
class WatchedStore extends MemoryChatStore {
  int writes = 0;
  bool failNotice = false;
  @override
  Future<void> write(String key, String value) {
    if (failNotice && key.contains('.history.') && value.contains('"notice-')) {
      failNotice = false;
      throw const FileSystemException('disk full');
    }
    writes++;
    return super.write(key, value);
  }
}

void main() {
  group('device notice words', () {
    test(
      'an idle sign-out is a calm note, and PEER_NO_DEVICES names the person',
      () {
        final text = deviceBannerText([
          DeviceNotice('d', DateTime.utc(2026, 10, 15), DeviceNoticeKind.idle),
        ]);
        expect(text.title, contains('signed out of chat'));
        expect(text.body, contains('Nothing is wrong'));
        expect(
          chatError(
            const ChatFailure('PEER_NO_DEVICES', 'x', 409),
            peerName: 'Mira',
          ),
          'Mira hasn’t opened Hiyall in a while. Your message can’t be delivered yet.',
        );
        expect(
          chatError(const ChatFailure('PEER_NO_DEVICES', 'x', 409)),
          'They haven’t opened Hiyall in a while. Your message can’t be delivered yet.',
        );
        expect(
          chatError(const ChatFailure('RECIPIENT_BACKLOG', 'x', 429)),
          'They haven’t caught up on earlier messages yet. Try again later.',
        );
      },
    );
  });

  group('on a real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await (_core ??= RustLib.init(
        externalLibrary: ExternalLibrary.open(_corePath),
      ));
    });

    late MemoryRelay relay;
    var now = DateTime.utc(2026, 10, 15, 12);
    final spare = <ChatEngine>[];

    ChatEngine make(
      String user,
      Api api,
      ChatStore store, {
      List<Duration> reregisterDelays = const [Duration(seconds: 30)],
    }) {
      final engine = ChatEngine(
        userId: user,
        api: api,
        store: store,
        platform: 'test',
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        keyRetryDelays: const [Duration(hours: 1)],
        reregisterDelays: reregisterDelays,
        clock: () => now,
      );
      spare.add(engine);
      return engine;
    }

    Future<ChatEngine> start(
      String user,
      Api api,
      ChatStore store, {
      List<Duration> reregisterDelays = const [Duration(seconds: 30)],
    }) async {
      final engine = make(user, api, store, reregisterDelays: reregisterDelays);
      await engine.start(poll: Duration.zero);
      return engine;
    }

    setUp(() {
      now = DateTime.utc(2026, 10, 15, 12);
      relay = MemoryRelay();
    });
    tearDown(() {
      for (final e in spare) {
        e.dispose();
      }
      spare.clear();
    });

    List<DeviceNoticeKind> kinds(ChatEngine e) => [
      for (final n in e.ownDeviceNotices) n.kind,
    ];

    Future<List<String>> texts(ChatEngine e) async => [
      for (final m in await e.history(conv))
        if (!m.notice) m.text,
    ];

    // ------------------------------------------------------------ CHAT-N1
    group('an idle device comes back (CHAT-N1)', () {
      late IdleApi aliceApi;
      late ChatEngine alice, bob;

      setUp(() async {
        aliceApi = IdleApi(relay, meId);
        alice = await start(meId, aliceApi, MemoryChatStore());
        bob = await start(peerId, IdleApi(relay, peerId), MemoryChatStore());
        await alice.send(conv, peerId, 'hi');
        await bob.pollNow();
        await bob.send(conv, meId, 'hello'); // bob pins alice's phone
        await alice.pollNow();
      });

      test('it registers again with the same keys, and nothing is announced to anyone', () async {
        final device = alice.deviceId, identity = alice.identityKey;
        var returned = 0;
        alice.onReregistered = () => returned++;
        aliceApi.signOutIdle(device); // the 35-day sweep
        expect(relay.devices[meId], isNot(contains(device)));
        await alice.pollNow(); // the inbox says 404
        expect(alice.deviceId, device, reason: 'the identity was kept');
        expect(alice.identityKey, identity);
        expect(returned, 1, reason: 'the push token is sent again on return');
        expect(aliceApi.registrations, [
          device,
          device,
        ], reason: 'start, then the return');
        expect(relay.devices[meId], contains(device));
        expect(kinds(alice), isEmpty, reason: 'no reset, no review, no alarm');
        // The keys the sweep took are put back by the same top-up as ever.
        expect(relay.keys[meId]![device], isNotEmpty);
        // Bob never saw a device appear: he pinned this one, with these keys, and writes as before.
        await bob.send(conv, meId, 'welcome back');
        await alice.pollNow();
        expect(await texts(alice), contains('welcome back'));
        expect(
          (await bob.history(conv)).where((m) => m.notice),
          isEmpty,
          reason: 'peers see no "new device" notice for an idle return',
        );
      });

      test('a peer with no device left is told so, and writes again when it returns', () async {
        final device = alice.deviceId;
        aliceApi.signOutIdle(device);
        await expectLater(
          bob.send(conv, meId, 'anyone there?'),
          throwsA(
            isA<ChatFailure>()
                .having((f) => f.code, 'code', 'PEER_NO_DEVICES')
                .having((f) => f.status, 'status', 409),
          ),
        );
        // Not a "devices changed" loop, and no message was left behind as sent.
        expect(relay.stored.length, 2);
        await alice.pollNow();
        await bob.send(conv, meId, 'there you are');
        await alice.pollNow();
        expect(await texts(alice), contains('there you are'));
        expect((await bob.history(conv)).where((m) => m.notice), isEmpty);
      });

      test(
        'a device somebody removed still starts over, with the alarm',
        () async {
          final device = alice.deviceId;
          aliceApi.unknown.add(
            device,
          ); // DEVICE_CONFLICT: removed by another session
          relay.devices[meId]!.remove(device);
          await alice.pollNow();
          expect(alice.deviceId, isNot(device));
          expect(kinds(alice), [DeviceNoticeKind.reset]);
        },
      );

      test('the account\'s other devices get one calm note, which the return takes back', () async {
        final tablet = await start(
          meId,
          IdleApi(relay, meId),
          MemoryChatStore(),
        );
        await alice.refreshOwnDevices();
        await alice.dismissOwnDeviceNotices();
        // The relay signed the tablet out as idle: its removal is listed for the owner's other devices.
        final listed = relay.devices[meId]!.remove(tablet.deviceId)!;
        aliceApi.removed.add({
          'deviceId': tablet.deviceId,
          'removedAt': '2026-10-14T12:00:00Z',
          'reason': 'idle',
        });
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.idle]);
        // Looking again, or after dismissing it, does not repeat it.
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.idle]);
        await alice.dismissOwnDeviceNotices();
        await alice.refreshOwnDevices();
        expect(kinds(alice), isEmpty);
        // The tablet returns with the keys that were pinned: not a new device, and not an alarm.
        relay.devices[meId]![tablet.deviceId] = listed;
        aliceApi.removed.clear();
        await alice.refreshOwnDevices();
        expect(kinds(alice), isNot(contains(DeviceNoticeKind.added)));
      });
    });

    // ------------------------------------------------------------ CHAT-N5
    group('a failed re-register backs off (CHAT-N5)', () {
      test('TOO_MANY_DEVICES: one attempt per wait, a growing wait, and nothing rewritten', () async {
        final api = IdleApi(relay, meId);
        final store = WatchedStore();
        final alice = await start(
          meId,
          api,
          store,
          reregisterDelays: const [Duration(seconds: 30), Duration(minutes: 1)],
        );
        final device = alice.deviceId, identity = alice.identityKey;
        api.signOutIdle(device);
        api.registerFailure = const ChatFailure(
          'TOO_MANY_DEVICES',
          'full',
          409,
        );
        final registered = api.registrations.length;
        Matcher full() => throwsA(
          isA<ChatFailure>().having((f) => f.code, 'code', 'TOO_MANY_DEVICES'),
        );

        await expectLater(alice.pollNow(), full());
        expect(api.registrations.length, registered + 1);
        final writes = store.writes;
        // Polling every two seconds for half a minute asks the relay nothing and rewrites nothing.
        for (var i = 0; i < 14; i++) {
          now = now.add(const Duration(seconds: 2));
          await alice.pollNow();
        }
        expect(api.registrations.length, registered + 1);
        expect(store.writes, writes, reason: 'no snapshot rewrite loop');
        expect(alice.deviceId, device);
        expect(
          alice.identityKey,
          identity,
          reason: 'the identity is untouched',
        );
        expect(
          kinds(alice),
          isEmpty,
          reason: 'no reset was made for a full account',
        );

        // The wait is over: one more attempt, and the next wait is the longer one.
        now = now.add(const Duration(seconds: 5));
        await expectLater(alice.pollNow(), full());
        expect(api.registrations.length, registered + 2);
        now = now.add(const Duration(seconds: 59));
        await alice.pollNow();
        expect(api.registrations.length, registered + 2);
        now = now.add(const Duration(seconds: 2));
        await expectLater(alice.pollNow(), full());
        expect(api.registrations.length, registered + 3);
        // The last wait repeats rather than growing without end.
        now = now.add(const Duration(seconds: 61));
        await expectLater(alice.pollNow(), full());
        expect(api.registrations.length, registered + 4);

        // A slot is freed: the next attempt registers the same identity, and the counter starts over.
        api.registerFailure = null;
        now = now.add(const Duration(minutes: 2));
        await alice.pollNow();
        expect(relay.devices[meId], contains(device));
        expect(alice.deviceId, device);
        api.signOutIdle(device);
        await alice.pollNow();
        expect(
          api.registrations.last,
          device,
          reason: 'a later removal is met at once',
        );
      });

      test('a removal by someone else that also cannot be registered resets once, not at every poll', () async {
        final api = IdleApi(relay, meId);
        final store = WatchedStore();
        final alice = await start(meId, api, store);
        final old = alice.deviceId;
        api.unknown.add(old); // DEVICE_CONFLICT for this id
        relay.devices[meId]!.remove(old);
        api.registerFailure = const ChatFailure(
          'TOO_MANY_DEVICES',
          'full',
          409,
        );
        await expectLater(alice.pollNow(), throwsA(isA<ChatFailure>()));
        final fresh = alice.deviceId;
        expect(fresh, isNot(old), reason: 'the identity was replaced once');
        final writes = store.writes;
        for (var i = 0; i < 10; i++) {
          now = now.add(const Duration(seconds: 2));
          await alice.pollNow();
        }
        expect(alice.deviceId, fresh);
        expect(
          store.writes,
          writes,
          reason: 'no identity is made again while waiting',
        );
        // The account has room again: the identity that was made is the one that registers.
        api.registerFailure = null;
        now = now.add(const Duration(minutes: 1));
        await alice.pollNow();
        expect(alice.deviceId, fresh);
        expect(relay.devices[meId], contains(fresh));
      });
    });

    // ------------------------------------------------------------ CHAT-N6
    group('a pin and its notice are one commit (CHAT-N6)', () {
      test('a notice that cannot be written leaves the new device unpinned, so the next look announces it', () async {
        final store = WatchedStore();
        final bob = await start(peerId, IdleApi(relay, peerId), store);
        await start(meId, IdleApi(relay, meId), MemoryChatStore());
        await bob.send(
          conv,
          meId,
          'first',
        ); // pins alice's phone (first contact: no notice)
        // Alice adds a device. Bob's next look pins it and files the notice in the conversation; the write fails.
        await start(meId, IdleApi(relay, meId), MemoryChatStore());
        store.failNotice = true;
        await expectLater(
          bob.send(conv, meId, 'second'),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          (await bob.history(conv)).where((m) => m.notice),
          isEmpty,
          reason: 'the notice did not land',
        );
        // The device was not pinned in memory behind the failed write: the retry announces it.
        final stuck = (await bob.history(conv)).lastWhere((m) => m.mine);
        await bob.retryText(conv, meId, stuck.messageId);
        expect(
          (await bob.history(conv)).where((m) => m.notice),
          hasLength(1),
          reason: 'a silent pin would leave no notice anywhere',
        );
      });
    });
  });
}

Future<void>? _core;
final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';

String? _coreMissing() {
  if (File(_corePath).existsSync()) return null;
  if (Platform.environment['REQUIRE_RUST_CORE'] == '1') {
    throw StateError('REQUIRE_RUST_CORE=1 but $_corePath is missing');
  }
  return 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
}
