import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_reactions.dart' show quickReaction;
import 'package:hiyall/core/chat/chat_snapshot.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay;
import 'chat_robustness_test.dart' show Api;
import 'chat_snapshot_test.dart' show CrashFiles, Crash;

// Re-audit CHAT-1 (key upload in chunks), CHAT-2 (device notices that cannot be bypassed), CHAT-3 (the aux
// hint cannot carry a message), CHAT-5 (an account that cannot be unlocked starts again) and the shutdown
// of an engine before a wipe. All on the real Olm core with an in-memory relay.

/// An API that records every key upload, can fail chosen ones, and keeps what the relay says about removals.
class LimitApi extends Api {
  LimitApi(super.relay, super.user);

  /// Keys per upload request, failed attempts included.
  final attempts = <List<String>>[];
  final fallbackSent = <bool>[];

  /// One entry per upload request, consumed in order: null lets it through, anything else is thrown.
  final plan = <Object?>[];
  int get uploaded => attempts.length;

  @override
  Future<int> uploadKeys(
    String deviceId,
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  ) async {
    attempts.add([for (final k in oneTimeKeys) k['keyId']!]);
    fallbackSent.add(fallbackKey != null);
    if (plan.isNotEmpty) {
      final next = plan.removeAt(0);
      if (next != null) throw next;
    }
    return super.uploadKeys(deviceId, oneTimeKeys, fallbackKey);
  }
}

/// A sender that marks every message auxiliary, as a stranger dodging the first-contact cap would.
class DisguisingApi extends Api {
  DisguisingApi(super.relay, super.user);
  @override
  Future<DateTime?> send(
    String conversationId,
    Map<String, dynamic> message, {
    List<String> blobIds = const [],
    bool aux = false,
  }) => super.send(conversationId, message, blobIds: blobIds, aux: true);
}

/// A store whose deletes can be made to fail from the Nth one on, as if the process was killed there.
class KillingStore extends MemoryChatStore {
  int? killAtDelete;
  int deletes = 0;
  final deleted = <String>[];
  @override
  Future<void> delete(String key) async {
    if (killAtDelete != null && deletes >= killAtDelete!) throw Crash();
    deletes++;
    deleted.add(key);
    return super.delete(key);
  }
}

class FailingReads extends MemoryChatStore {
  int failReads = 0;
  @override
  Future<String?> read(String key) {
    if (failReads > 0) {
      failReads--;
      throw const FileSystemException('keystore not ready');
    }
    return super.read(key);
  }
}

/// Slows every write down, so work is still in flight when a test wipes.
class SlowStore extends MemoryChatStore {
  final writes = <String>[];
  @override
  Future<void> write(String key, String value) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    writes.add(key);
    return super.write(key, value);
  }
}

void main() {
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
      Directory? root,
      List<Duration> keyRetryDelays = const [Duration(hours: 1)],
    }) {
      final engine = ChatEngine(
        userId: user,
        api: api,
        store: store,
        platform: 'test',
        mediaRoot: root,
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        keyRetryDelays: keyRetryDelays,
        clock: () => now,
      );
      spare.add(engine);
      return engine;
    }

    Future<ChatEngine> start(
      String user,
      Api api,
      ChatStore store, {
      Directory? root,
    }) async {
      final engine = make(user, api, store, root: root);
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

    Future<List<String>> texts(ChatEngine e) async => [
      for (final m in await e.history(conv))
        if (!m.notice) m.text,
    ];

    int relayKeys(String user, String device) =>
        relay.keys[user]?[device]?.length ?? 0;

    // ------------------------------------------------------------ CHAT-1
    group('key upload (CHAT-1)', () {
      test(
        'every request carries at most 50 keys and the relay ends at 60',
        () async {
          final api = LimitApi(relay, meId);
          final alice = await start(meId, api, MemoryChatStore());
          expect(api.attempts.map((a) => a.length), [50, 10]);
          expect(api.fallbackSent, [true, false], reason: 'it travels first');
          expect(relayKeys(meId, alice.deviceId), 60);
        },
      );

      test(
        'offline on the first run: the restart retries exactly what failed',
        () async {
          final api = LimitApi(relay, meId)
            ..plan.add(const ChatFailure('NETWORK', 'offline'));
          final store = MemoryChatStore();
          final first = make(meId, api, store);
          // The failed upload does not fail the start (audit CHAT-N5): the device is registered and chat opens.
          await first.start(poll: Duration.zero);
          final offered = api.attempts.single;
          expect(offered, hasLength(50));
          // The app is restarted: the keys come back from the saved account, not from new ones.
          first.dispose();
          final again = await start(meId, api, store);
          expect(api.attempts.skip(1).every((a) => a.length <= 50), isTrue);
          expect(api.attempts[1], offered, reason: 'the same keys, no more');
          expect(relayKeys(meId, again.deviceId), 60);
        },
      );

      test('a refused upload (422) does not wedge later starts', () async {
        final api = LimitApi(relay, meId)
          ..plan.addAll([
            const ChatFailure('VALIDATION', 'too many', 422),
            const ChatFailure('VALIDATION', 'too many', 422),
            const ChatFailure('VALIDATION', 'too many', 422),
          ]);
        final store = MemoryChatStore();
        for (var i = 0; i < 3; i++) {
          final e = make(meId, api, store);
          await e.start(poll: Duration.zero);
          e.dispose();
        }
        // Three failed runs on one account left no growing pile of keys: every attempt offered the same 50.
        expect(api.attempts.every((a) => a.length == 50), isTrue);
        expect(api.attempts.map((a) => a.join(',')).toSet(), hasLength(1));
        final ok = await start(meId, api, store);
        expect(api.attempts.every((a) => a.length <= 50), isTrue);
        expect(relayKeys(meId, ok.deviceId), 60);
      });

      test('the second chunk failing leaves the first published and the rest for later', () async {
        final api = LimitApi(relay, meId)
          ..plan.addAll([null, const ChatFailure('NETWORK', 'offline')]);
        final store = MemoryChatStore();
        final first = make(meId, api, store);
        await first.start(poll: Duration.zero);
        final device = first.deviceId;
        expect(relayKeys(meId, device), 50);
        first.dispose();
        // 50 are on the relay, so a restart needs nothing; once keys are claimed away it tops up in chunks.
        final again = await start(meId, api, store);
        expect(relayKeys(meId, device), 50);
        relay.keys[meId]![device]!.removeRange(0, 40); // claimed by peers
        await again.pollNow(); // nothing waits on the relay, so no replenish
        final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
        await bob.send(conv, meId, 'hello');
        await again.pollNow();
        expect(api.attempts.every((a) => a.length <= 50), isTrue);
        expect(relayKeys(meId, device), lessThanOrEqualTo(100));
        expect(await texts(again), contains('hello'));
      });

      test(
        'fallback rotation is not starved by failing one-time uploads',
        () async {
          final api = LimitApi(relay, meId);
          final store = MemoryChatStore();
          final alice = await start(meId, api, store);
          final first = api.fallbacks[alice.deviceId]!['keyId'];
          now = now.add(const Duration(days: 8));
          api.plan.addAll([
            const ChatFailure('VALIDATION', 'refused', 422),
            const ChatFailure('NETWORK', 'offline'),
          ]);
          await alice.pollNow(); // fails quietly
          await alice.pollNow(); // fails quietly
          expect(api.fallbacks[alice.deviceId]!['keyId'], first);
          await alice.pollNow();
          expect(api.fallbacks[alice.deviceId]!['keyId'], isNot(first));
          expect(api.attempts.every((a) => a.length <= 50), isTrue);
          // It was the same unpublished fallback key each time: three attempts, one new key.
          expect(api.fallbackSent.where((f) => f).length, 4);
        },
      );

      test('a depleted relay is topped up to 60 in two requests', () async {
        final api = LimitApi(relay, meId);
        final alice = await start(meId, api, MemoryChatStore());
        final before = api.attempts.length;
        relay.keys[meId]![alice.deviceId]!.removeRange(0, 55); // 5 left
        final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
        await bob.send(conv, meId, 'ping');
        await alice.pollNow();
        expect(api.attempts.skip(before).map((a) => a.length).toList(), [
          50,
          6,
        ]);
        expect(relayKeys(meId, alice.deviceId), 60);
      });
    });

    // ------------------------------------------------------------ CHAT-3
    group('the aux hint (CHAT-3)', () {
      Map<String, dynamic> body(String kind, String id, {String text = ''}) => {
        'v': 1,
        'kind': kind,
        'text': text,
        'messageId': id,
        'conversationId': conv,
        'senderId': peerId,
        'sentAt': '2026-10-15T12:00:00Z',
        if (kind == 'reaction') ...{
          'to': '7a7a0000-0000-4000-8000-000000000001',
          'emoji': quickReaction,
          'op': 'add',
        },
      };
      const id = '7a7a0000-0000-4000-8000-0000000000aa';
      Incoming parse(Map<String, dynamic> b, {required bool aux}) =>
          parseIncoming(
            b,
            messageId: id,
            conversationId: conv,
            senderId: peerId,
            me: meId,
            aux: aux,
          );

      test(
        'a marked message whose kind is not reaction or noop is dropped',
        () {
          expect(
            parse(body('text', id, text: 'quiet hello'), aux: true),
            isA<IncomingIgnored>(),
          );
          expect(parse(body('image', id), aux: true), isA<IncomingIgnored>());
          expect(
            parse(body('whatever', id), aux: true),
            isA<IncomingIgnored>(),
          );
          // The same payloads unmarked are what they were.
          expect(
            parse(body('text', id, text: 'hello'), aux: false),
            isA<IncomingMessage>(),
          );
        },
      );

      test('a marked reaction and noop are kept, as before', () {
        expect(parse(body('reaction', id), aux: true), isA<IncomingReaction>());
        expect(parse(body('noop', id), aux: true), isA<IncomingIgnored>());
      });

      test('over the relay: text sent as aux never reaches the history, and is acknowledged', () async {
        final alice = await start(meId, Api(relay, meId), MemoryChatStore());
        final stranger = await start(
          peerId,
          DisguisingApi(relay, peerId),
          MemoryChatStore(),
        );
        await stranger.send(conv, meId, 'ignore me, I am "quiet"');
        expect(
          relay.inboxes[alice.deviceId]!.single['aux'],
          true,
          reason: 'the relay says the sender marked it',
        );
        await alice.pollNow();
        expect(await texts(alice), isEmpty);
        expect(
          (await alice.history(conv)).where((m) => m.notice),
          isEmpty,
          reason: 'no bubble, no notice',
        );
        expect(relay.inboxes[alice.deviceId], isEmpty, reason: 'acknowledged');
      });

      test(
        'a real reaction and the quiet noop still pass the cross-check',
        () async {
          now = DateTime.utc(
            2026,
            10,
            13,
            12,
            5,
          ); // the relay's clock in these tests
          final alice = await start(meId, Api(relay, meId), MemoryChatStore());
          final bob = await start(
            peerId,
            Api(relay, peerId),
            MemoryChatStore(),
          );
          await alice.send(conv, peerId, 'real');
          await bob.pollNow();
          final target = (await bob.history(conv)).single;
          await bob.react(conv, meId, target.messageId, quickReaction);
          expect(relay.inboxes[alice.deviceId]!.single['aux'], true);
          await alice.pollNow();
          final mine = (await alice.history(conv)).single;
          expect(mine.reactions[peerId], quickReaction);
          expect(relay.inboxes[alice.deviceId], isEmpty);
        },
      );
    });

    // ------------------------------------------------------------ CHAT-2
    group('device notices (CHAT-2)', () {
      late LimitApi aliceApi;
      late MemoryChatStore aliceStore;
      late ChatEngine alice;

      setUp(() async {
        aliceApi = LimitApi(relay, meId);
        aliceStore = MemoryChatStore();
        alice = await start(meId, aliceApi, aliceStore);
        await start(peerId, Api(relay, peerId), MemoryChatStore());
        await alice.send(conv, peerId, 'hi'); // pins bob
      });

      List<DeviceNoticeKind> kinds(ChatEngine e) => [
        for (final n in e.ownDeviceNotices) n.kind,
      ];

      test('the first device of an account has nothing to review', () {
        expect(alice.ownDeviceNotices, isEmpty);
      });

      test('a reset keeps the pins of other people and of the account\'s other devices', () async {
        await start(meId, Api(relay, meId), MemoryChatStore());
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.added]);
        await alice.dismissOwnDeviceNotices();
        // The relay forgets this phone (someone removed it).
        final old = alice.deviceId;
        aliceApi.unknown.add(old);
        relay.devices[meId]!.remove(old); // the relay no longer lists it
        await alice.pollNow();
        expect(alice.deviceId, isNot(old));
        expect(kinds(alice), [DeviceNoticeKind.reset]);
        // The tablet stays pinned, so it is not announced again, and nothing is "reviewed" from scratch.
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.reset]);
        // Bob's pins survived too: a device he adds after this reset is announced in the chat, which a phone
        // that had forgotten him would pin silently as a first contact.
        await start(peerId, Api(relay, peerId), MemoryChatStore());
        await alice.send(conv, peerId, 'still there?');
        expect(
          (await alice.history(conv)).where((m) => m.notice),
          hasLength(1),
        );
      });

      test('a device added while the phone was being reset is announced, never pinned silently', () async {
        final old = alice.deviceId;
        // The thief's device registers while this phone is offline; then it removes this phone.
        final thief = await start(meId, Api(relay, meId), MemoryChatStore());
        aliceApi.unknown.add(old);
        relay.devices[meId]!.remove(old);
        await alice.pollNow(); // 404: starts over
        await alice.refreshOwnDevices();
        expect(
          kinds(alice),
          containsAll([DeviceNoticeKind.reset, DeviceNoticeKind.review]),
          reason:
              'this phone knew none of the account\'s devices after the reset',
        );
        expect(
          alice.ownDeviceNotices.any((n) => n.deviceId == thief.deviceId),
          isFalse,
          reason: 'the review notice is about the list, not one id',
        );
        // The banner stays across restarts until it is dismissed.
        alice.dispose();
        final again = await start(meId, aliceApi, aliceStore);
        expect(
          kinds(again),
          containsAll([DeviceNoticeKind.reset, DeviceNoticeKind.review]),
        );
        await again.dismissOwnDeviceNotices();
        expect(again.ownDeviceNotices, isEmpty);
      });

      test('a fresh install that finds other devices says so', () async {
        final phone = await start(meId, Api(relay, meId), MemoryChatStore());
        expect(kinds(phone), [DeviceNoticeKind.review]);
        // The first phone learns of the new one the usual way.
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.added]);
        // Looking again does not repeat either.
        await phone.refreshOwnDevices();
        await alice.refreshOwnDevices();
        expect(kinds(phone), [DeviceNoticeKind.review]);
        expect(kinds(alice), [DeviceNoticeKind.added]);
      });

      test('a removal by another session is noticed once, for a device this phone knew', () async {
        final tablet = await start(meId, Api(relay, meId), MemoryChatStore());
        await alice.refreshOwnDevices();
        await alice.dismissOwnDeviceNotices();
        // The relay's record: the tablet and a device nobody here ever saw were removed by another session.
        relay.devices[meId]!.remove(tablet.deviceId);
        aliceApi.removed
          ..add({
            'deviceId': tablet.deviceId,
            'removedAt': '2026-10-15T11:00:00Z',
          })
          ..add({
            'deviceId': '7a7a0000-0000-4000-8000-0000000000ee',
            'removedAt': '2026-10-15T11:01:00Z',
          });
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.removed]);
        expect(alice.ownDeviceNotices.single.deviceId, tablet.deviceId);
        await alice.refreshOwnDevices();
        expect(kinds(alice), [DeviceNoticeKind.removed], reason: 'once');
      });

      test(
        'removing a device from this phone is not announced back to it',
        () async {
          final tablet = await start(meId, Api(relay, meId), MemoryChatStore());
          await alice.refreshOwnDevices();
          await alice.dismissOwnDeviceNotices();
          await alice.revokeDevice(tablet.deviceId);
          relay.devices[meId]!.remove(tablet.deviceId);
          aliceApi.removed.add({
            'deviceId': tablet.deviceId,
            'removedAt': '2026-10-15T12:00:00Z',
          });
          await alice.refreshOwnDevices();
          expect(alice.ownDeviceNotices, isEmpty);
        },
      );

      test('refreshing can be throttled for the periodic syncs, never for a signal', () async {
        final calls = <int>[];
        final counting = _CountingDevices(relay, meId, calls);
        final phone = await start(meId, counting, MemoryChatStore());
        calls.clear();
        await phone.refreshOwnDevices(minAge: const Duration(seconds: 25));
        await phone.refreshOwnDevices(minAge: const Duration(seconds: 25));
        expect(calls, hasLength(1));
        now = now.add(const Duration(seconds: 26));
        await phone.refreshOwnDevices(minAge: const Duration(seconds: 25));
        expect(calls, hasLength(2));
        await phone.refreshOwnDevices();
        expect(calls, hasLength(3));
      });
    });

    // ------------------------------------------------------------ CHAT-5
    group('an account that cannot be unlocked (CHAT-5)', () {
      test('a missing pickle key starts over with the notice', () async {
        final api = Api(relay, meId);
        final store = MemoryChatStore();
        final first = await start(meId, api, store);
        final old = first.identityKey, oldDevice = first.deviceId;
        first.dispose();
        store.values.remove('hiyall.chat.$meId.pickleKey');
        final again = await start(meId, api, store);
        expect(again.identityKey, isNot(old));
        expect(again.deviceId, isNot(oldDevice));
        expect(again.ownDeviceNotices.map((n) => n.kind), [
          DeviceNoticeKind.locked,
        ]);
        // It is a working device: it can be written to.
        final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
        await bob.send(conv, meId, 'are you there');
        await again.pollNow();
        expect(await texts(again), ['are you there']);
      });

      test('a damaged state entry does the same', () async {
        final api = Api(relay, meId);
        final store = MemoryChatStore();
        (await start(meId, api, store)).dispose();
        store.values['hiyall.chat.$meId.state'] = '{"account": 5';
        final again = await start(meId, api, store);
        expect(again.ownDeviceNotices.map((n) => n.kind), [
          DeviceNoticeKind.locked,
        ]);
        store.values['hiyall.chat.$meId.state'] = jsonEncode({
          'v': 2,
          'account': 'not a pickle',
          'sessions': {},
        });
        again.dispose();
        final third = await start(meId, api, store);
        expect(
          third.ownDeviceNotices.map((n) => n.kind),
          contains(DeviceNoticeKind.locked),
        );
      });

      test(
        'a keystore that is only not ready is an error to retry, never a reset',
        () async {
          final api = Api(relay, meId);
          final store = FailingReads();
          final first = await start(meId, api, store);
          final identity = first.identityKey;
          first.dispose();
          store.failReads = 1;
          final failing = make(meId, api, store);
          await expectLater(
            failing.start(poll: Duration.zero),
            throwsA(isA<FileSystemException>()),
          );
          final again = await start(meId, api, store);
          expect(
            again.identityKey,
            identity,
            reason: 'nothing was thrown away',
          );
          expect(again.ownDeviceNotices, isEmpty);
        },
      );

      test(
        'the reset removes the state before the key that opens it',
        () async {
          final api = Api(relay, meId);
          final store = KillingStore();
          final alice = await start(meId, api, store);
          api.unknown.add(alice.deviceId);
          await alice.pollNow();
          final names = [for (final k in store.deleted) k.split('.').last];
          expect(names.indexOf('state'), lessThan(names.indexOf('pickleKey')));
          expect(names.indexOf('state'), 0);
        },
      );

      test('a kill between any two steps of the reset leaves an account that starts again', () async {
        for (var killAt = 0; killAt <= 6; killAt++) {
          final localRelay = MemoryRelay();
          final api = Api(localRelay, meId);
          final store = KillingStore();
          final alice = ChatEngine(
            userId: meId,
            api: api,
            store: store,
            platform: 'test',
            clock: () => now,
          );
          await alice.start(poll: Duration.zero);
          final oldDevice = alice.deviceId;
          api.unknown.add(oldDevice);
          store
            ..deletes = 0
            ..killAtDelete = killAt;
          try {
            await alice.pollNow();
          } catch (_) {
            // killed
          }
          alice.dispose();
          // The process comes back: same keystore and storage, no more kill.
          store.killAtDelete = null;
          final back = ChatEngine(
            userId: meId,
            api: api,
            store: store,
            platform: 'test',
            clock: () => now,
          );
          await back.start(poll: Duration.zero);
          final peer = ChatEngine(
            userId: peerId,
            api: Api(localRelay, peerId),
            store: MemoryChatStore(),
            platform: 'test',
            clock: () => now,
          );
          await peer.start(poll: Duration.zero);
          await peer.send(conv, meId, 'after kill $killAt');
          await back.pollNow();
          expect(
            [
              for (final m in await back.history(conv))
                if (!m.notice) m.text,
            ],
            ['after kill $killAt'],
            reason: 'killed at delete $killAt',
          );
          await back.send(conv, peerId, 'reply');
          await peer.pollNow();
          back.dispose();
          peer.dispose();
        }
      });

      test('over the sealed snapshot: a crash at any file step of the reset recovers', () async {
        for (var step = 0; step <= 8; step++) {
          final localRelay = MemoryRelay();
          final api = Api(localRelay, meId);
          final secure = MemoryChatStore();
          var files = CrashFiles();
          Future<SnapshotChatStore> open() => SnapshotChatStore.open(
            secure: secure,
            userId: meId,
            files: files,
          );
          final alice = ChatEngine(
            userId: meId,
            api: api,
            store: await open(),
            platform: 'test',
            clock: () => now,
          );
          await alice.start(poll: Duration.zero);
          api.unknown.add(alice.deviceId);
          files.crashAt = files.ops + step;
          try {
            await alice.pollNow();
          } catch (_) {
            // crashed
          }
          alice.dispose();
          files = files.reboot();
          final back = ChatEngine(
            userId: meId,
            api: api,
            store: await open(),
            platform: 'test',
            clock: () => now,
          );
          await back.start(poll: Duration.zero);
          final peer = ChatEngine(
            userId: peerId,
            api: Api(localRelay, peerId),
            store: MemoryChatStore(),
            platform: 'test',
            clock: () => now,
          );
          await peer.start(poll: Duration.zero);
          await peer.send(conv, meId, 'step $step');
          await back.pollNow();
          expect(
            [
              for (final m in await back.history(conv))
                if (!m.notice) m.text,
            ],
            ['step $step'],
            reason: 'crash at file step $step',
          );
          back.dispose();
          peer.dispose();
        }
      });
    });

    // ------------------------------------------------------------ dispose before wipe
    group('dispose drains in-flight work before a wipe', () {
      test('nothing is written back after the wipe, and the engine refuses new work', () async {
        final root = await Directory.systemTemp.createTemp('hiyall-wipe');
        addTearDown(() => root.delete(recursive: true));
        final secure = MemoryChatStore();
        final slow = SlowStore();
        // The slow store stands in for the keystore; the snapshot is the real sealed file in chat_state.
        final files = DirectorySnapshotFiles(
          Directory('${root.path}/chat_state'),
        );
        final store = await SnapshotChatStore.open(
          secure: slow,
          userId: meId,
          files: files,
        );
        final api = Api(relay, meId);
        final alice = await start(meId, api, store, root: root);
        final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
        await bob.send(conv, meId, 'incoming');
        // Work in flight: a poll and a send, neither awaited.
        final poll = alice.pollNow().then((_) {}, onError: (_) {});
        final send = alice
            .send(conv, peerId, 'outgoing')
            .then((_) {}, onError: (_) {});
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await ChatLocalData.wipeAccount(root: root, store: slow, userId: meId);
        await Future.wait([poll, send]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // What a wipe leaves on purpose: the note to remove this phone's device on the server later.
        expect(await slow.keys(), [
          'hiyall.chatrevoke.$meId',
        ], reason: 'no entry written back');
        final onDisk = [for (final e in root.listSync(recursive: true)) e.path];
        expect(onDisk, isEmpty, reason: 'no file recreated: $onDisk');
        await expectLater(alice.send(conv, peerId, 'late'), throwsA(anything));
        await expectLater(alice.pollNow(), throwsA(anything));
        expect(await slow.keys(), ['hiyall.chatrevoke.$meId']);
        expect(secure.values, isEmpty);
        expect(root.listSync(recursive: true), isEmpty);
      });

      test('dispose twice is fine and waits for the same shutdown', () async {
        final alice = await start(meId, Api(relay, meId), MemoryChatStore());
        final a = alice.dispose(), b = alice.dispose();
        expect(identical(a, b), isTrue);
        await a;
      });
    });
  });
}

/// Counts the reads of this account's device list.
class _CountingDevices extends Api {
  _CountingDevices(super.relay, super.user, this.calls);
  final List<int> calls;
  @override
  Future<List<Map<String, dynamic>>> devices(String userId) {
    if (userId == user) calls.add(calls.length);
    return super.devices(userId);
  }
}

Future<void>? _core;
final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';
String? _coreMissing() => File(_corePath).existsSync()
    ? null
    : 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
