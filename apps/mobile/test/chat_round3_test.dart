import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_key_upload.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_snapshot.dart';
import 'package:hiyall/core/chat/chat_storage_health.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/api/e2ee.dart' show PublicKeyEntry;
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay;
import 'chat_robustness_test.dart' show Api;
import 'chat_snapshot_test.dart' show CrashFiles, FakeSealer;

// Round 3 chat findings: CHAT-N4 (keystore errors never regenerate), N5 (a key upload failure does not fail
// start), N6 (pin and notice in one commit), N8 (a rolled-back or lost snapshot is a lost identity), N9
// (every unpublished key is uploaded, in chunks) and the https rule of ChatApi.

/// A keystore that can fail the way a locked or busy platform keystore does, and remembers every change.
class FlakyKeystore extends MemoryChatStore {
  bool failing = false;
  final changes = <String>[];
  void _maybeFail() {
    if (failing) throw const ChatStorageUnavailable('keystore busy');
  }

  @override
  Future<String?> read(String key) {
    _maybeFail();
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    _maybeFail();
    changes.add('write $key');
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) {
    _maybeFail();
    changes.add('delete $key');
    return super.delete(key);
  }

  @override
  Future<List<String>> keys() {
    _maybeFail();
    return super.keys();
  }
}

class CountingApi extends Api {
  CountingApi(super.relay, super.user);
  int keyCounts = 0;
  final plan = <Object?>[];
  int uploads = 0;
  @override
  Future<int> keyCount(String deviceId) {
    keyCounts++;
    return super.keyCount(deviceId);
  }

  @override
  Future<int> uploadKeys(
    String deviceId,
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  ) async {
    uploads++;
    if (plan.isNotEmpty) {
      final next = plan.removeAt(0);
      if (next != null) throw next;
    }
    return super.uploadKeys(deviceId, oneTimeKeys, fallbackKey);
  }
}

Future<SnapshotChatStore> openStore(
  CrashFiles files,
  ChatStore secure, {
  int keyByte = 9,
}) => SnapshotChatStore.open(
  secure: secure,
  userId: meId,
  files: files,
  newKey: () => List<int>.filled(32, keyByte),
  sealerFor: FakeSealer.new,
);

String diskDigest(CrashFiles f) =>
    jsonEncode({for (final e in f.disk.entries) e.key: base64Encode(e.value)});

void main() {
  group('the key upload helper (CHAT-N9)', () {
    List<PublicKeyEntry> entries(int n, [int from = 0]) => [
      for (var i = from; i < from + n; i++)
        PublicKeyEntry(keyId: 'k$i', publicKey: 'p$i'),
    ];

    test('an unpublished set larger than 50 (a pickle from before the core capped it) is uploaded whole, in chunks, and marked published after', () async {
      final uploaded = <List<String>>[];
      var marked = 0;
      final order = <String>[];
      await publishOneTimeKeys(
        onRelay: 0,
        want: 60,
        fallback: null,
        generate: (n) => entries(70),
        sign: (k) => {'keyId': k.keyId},
        save: () async {},
        upload: (keys, _) async {
          uploaded.add([for (final k in keys) k['keyId']!]);
          order.add('upload');
        },
        markPublished: () {
          marked++;
          order.add('mark');
        },
        fallbackPublished: () async {},
      );
      // 70 in the first round (50 + 20); the 10 still wanted are made next round and the core hands back
      // what is unpublished (the same 70 here, since this fake never empties), so only the room is used.
      expect(uploaded.first, hasLength(50));
      expect(uploaded[1], hasLength(20));
      expect(order.sublist(0, 3), ['upload', 'upload', 'mark']);
      expect(
        uploaded.expand((u) => u).toSet().length,
        lessThanOrEqualTo(oneTimeKeysOnRelayMax),
      );
      expect(marked, greaterThanOrEqualTo(1));
    });

    test(
      'every key of a 120 key backlog that the relay has room for is sent',
      () async {
        final uploaded = <String>[];
        var pending = entries(120);
        await publishOneTimeKeys(
          onRelay: 0,
          want: 60,
          fallback: null,
          generate: (n) => pending,
          sign: (k) => {'keyId': k.keyId},
          save: () async {},
          upload: (keys, _) async =>
              uploaded.addAll([for (final k in keys) k['keyId']!]),
          markPublished: () => pending = const [],
          fallbackPublished: () async {},
        );
        expect(uploaded, hasLength(oneTimeKeysOnRelayMax));
        expect(uploaded.toSet(), hasLength(oneTimeKeysOnRelayMax));
        expect(pending, isEmpty, reason: 'nothing stays unpublished');
      },
    );

    test(
      'a failure part-way marks nothing, and the retry sends the same keys',
      () async {
        var pending = entries(70);
        final sent = <List<String>>[];
        var fail = true;
        Future<void> run() => publishOneTimeKeys(
          onRelay: 0,
          want: 0,
          fallback: null,
          generate: (n) => pending,
          sign: (k) => {'keyId': k.keyId},
          save: () async {},
          upload: (keys, _) async {
            sent.add([for (final k in keys) k['keyId']!]);
            if (sent.length == 2 && fail) {
              fail = false;
              throw const ChatFailure('NETWORK', 'offline');
            }
          },
          markPublished: () => pending = const [],
          fallbackPublished: () async {},
        );
        await expectLater(run(), throwsA(isA<ChatFailure>()));
        expect(pending, hasLength(70), reason: 'not marked after a failure');
        await run();
        expect(pending, isEmpty);
        expect(sent.sublist(2).expand((s) => s).length, 70);
        expect(
          sent[2],
          sent[0],
          reason: 'the first chunk goes again, as it was',
        );
      },
    );

    test('the fallback key travels with the first request only', () async {
      final fallbacks = <bool>[];
      var published = 0;
      await publishOneTimeKeys(
        onRelay: 0,
        want: 0,
        fallback: const PublicKeyEntry(keyId: 'fb', publicKey: 'fp'),
        generate: (n) => entries(60),
        sign: (k) => {'keyId': k.keyId},
        save: () async {},
        upload: (keys, fallback) async => fallbacks.add(fallback != null),
        markPublished: () {},
        fallbackPublished: () async => published++,
      );
      expect(fallbacks, [true, false]);
      expect(published, 1);
    });

    test(
      'a relay that is full takes nothing and nothing stays unpublished',
      () async {
        var uploads = 0;
        var marked = false;
        await publishOneTimeKeys(
          onRelay: oneTimeKeysOnRelayMax,
          want: 60,
          fallback: null,
          generate: (n) => entries(10),
          sign: (k) => {'keyId': k.keyId},
          save: () async {},
          upload: (_, _) async => uploads++,
          markPublished: () => marked = true,
          fallbackPublished: () async {},
        );
        expect(uploads, 0);
        expect(marked, isTrue);
      },
    );
  });

  group('the storage failure bookkeeping (CHAT-N4)', () {
    late Directory dir;
    setUp(
      () async => dir = await Directory.systemTemp.createTemp('hiyall-health'),
    );
    tearDown(() => dir.delete(recursive: true));

    test(
      'the reset is offered after three failed launches in a row, not before',
      () async {
        final health = ChatStorageHealth(dir);
        expect(await health.resetOffered(), isFalse);
        expect(await health.recordFailedLaunch(), 1);
        expect(await health.recordFailedLaunch(), 2);
        expect(await health.resetOffered(), isFalse);
        expect(await health.recordFailedLaunch(), 3);
        expect(await health.resetOffered(), isTrue);
        // It survives a restart (a new object over the same folder) and a successful open clears it.
        expect(await ChatStorageHealth(dir).failedLaunches(), 3);
        await health.clear();
        expect(await health.failedLaunches(), 0);
        expect(await health.resetOffered(), isFalse);
      },
    );

    test('a damaged counter file counts as none', () async {
      await File('${dir.path}/${ChatStorageHealth.fileName}')
          .writeAsString('{{');
      expect(await ChatStorageHealth(dir).failedLaunches(), 0);
    });

    test('the explicit reset erases files and keys, and falls back to erasing the keystore', () async {
      await Directory('${dir.path}/chat_state').create();
      await File('${dir.path}/chat_state/a.snap').writeAsString('x');
      final store = MemoryChatStore()
        ..values['hiyall.chat.$meId.pickleKey'] = 'k'
        ..values['hiyall.chat.$meId.deviceId'] = 'd'
        ..values['hiyall.chat.other.pickleKey'] = 'o';
      await ChatLocalData.resetAfterStorageFailure(
        root: dir,
        store: store,
        userId: meId,
      );
      expect(Directory('${dir.path}/chat_state').existsSync(), isFalse);
      expect(
        store.values.keys.where((k) => k.startsWith('hiyall.chat.$meId.')),
        isEmpty,
      );
      expect(store.values['hiyall.chat.other.pickleKey'], 'o');
      expect(
        store.values['hiyall.chatrevoke.$meId'],
        'd',
        reason: 'the old device is remembered',
      );

      // A keystore that will not delete entries: the last resort clears it all.
      final stuck = FlakyKeystore()..failing = true;
      var erased = 0;
      await ChatLocalData.resetAfterStorageFailure(
        root: dir,
        store: stuck,
        userId: meId,
        eraseEverything: () async => erased++,
      );
      expect(erased, 1);
      // And without that last resort the failure is reported, not hidden.
      await expectLater(
        ChatLocalData.resetAfterStorageFailure(
          root: dir,
          store: stuck,
          userId: meId,
        ),
        throwsA(isA<ChatStorageUnavailable>()),
      );
    });
  });

  group('the snapshot store and the keystore (CHAT-N4, N8)', () {
    test(
      'a keystore that cannot be read is an error, never a new key',
      () async {
        final files = CrashFiles();
        final keystore = FlakyKeystore();
        final first = await openStore(files, keystore);
        await first.write('hiyall.chat.$meId.history.c1', 'one');
        final before = (diskDigest(files), jsonEncode(keystore.values));
        keystore.failing = true;
        await expectLater(
          openStore(files, keystore),
          throwsA(isA<ChatStorageUnavailable>()),
        );
        expect((diskDigest(files), jsonEncode(keystore.values)), before);
        expect(keystore.changes.where((c) => c.startsWith('delete')), isEmpty);
        // Back to normal: the same key opens the same snapshot.
        keystore.failing = false;
        final again = await openStore(files, keystore);
        expect(await again.read('hiyall.chat.$meId.history.c1'), 'one');
        expect(again.info.lost, isFalse);
        expect(again.info.rolledBack, isFalse);
      },
    );

    test(
      'opening from the previous generation is flagged as a rollback',
      () async {
        final files = CrashFiles();
        final keystore = FlakyKeystore();
        final first = await openStore(files, keystore);
        await first.write('hiyall.chat.$meId.history.c1', 'one');
        await first.write('hiyall.chat.$meId.history.c1', 'two');
        expect(files.disk.keys, containsAll(['$meId.snap', '$meId.snap.prev']));
        // The current file and a leftover temporary are gone; only the spare remains.
        files.disk.remove('$meId.snap');
        files.disk.remove('$meId.snap.tmp');
        final back = await openStore(files, keystore);
        expect(back.info.rolledBack, isTrue);
        expect(back.info.identityUntrusted, isTrue);
        expect(back.info.lost, isFalse);
        expect(back.info.loadedFrom, back.previousName);
      },
    );

    test('a wiped keystore with surviving files is flagged as lost', () async {
      final files = CrashFiles();
      final first = await openStore(files, FlakyKeystore());
      await first.write('hiyall.chat.$meId.history.c1', 'one');
      final back = await openStore(files, FlakyKeystore(), keyByte: 3);
      expect(back.info.lost, isTrue);
      expect(back.info.identityUntrusted, isTrue);
    });
  });

  group('ChatApi transport (https)', () {
    ChatApi api(String base, [_Adapter? adapter]) => ChatApi(
      base,
      't',
      dio: adapter == null
          ? null
          : (Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter),
    );

    test('the bearer token is never sent to a plain http host', () async {
      final adapter = _Adapter();
      await expectLater(
        api('http://chat.example.com', adapter).keyCount('d'),
        throwsA(
          isA<ChatFailure>().having(
            (f) => f.code,
            'code',
            'INSECURE_TRANSPORT',
          ),
        ),
      );
      expect(adapter.requests, isEmpty, reason: 'nothing left the phone');
      await expectLater(
        api('', adapter).keyCount('d'),
        throwsA(isA<ChatFailure>()),
      );
      // https, and this machine's own http in a debug build, go through.
      for (final base in [
        'https://api.hiyall.example',
        'http://127.0.0.1:8080',
      ]) {
        final ok = _Adapter()
          ..body = {
            'data': {'oneTimeKeyCount': 3},
          };
        expect(await api(base, ok).keyCount('d'), 3);
      }
    });

    test('an upload slot and a download url follow the same rule (no private loopback list)', () async {
      Future<Object?> slot(String url) {
        final adapter = _Adapter()
          ..body = {
            'data': {
              'blobId': 'b1',
              'uploadUrl': url,
              'headers': {'Content-Type': 'application/octet-stream'},
              'method': 'PUT',
            },
          };
        return api('https://api.hiyall.example', adapter)
            .createBlobSlot('c1', 'full', 10, 'sha')
            .then<Object?>((s) => s, onError: (Object e) => e);
      }

      Future<Object?> download(String url) {
        final adapter = _Adapter()
          ..body = {
            'data': {'url': url, 'sizeBytes': 10},
          };
        return api('https://api.hiyall.example', adapter)
            .blobDownloadUrl('c1', 'b1')
            .then<Object?>((s) => s, onError: (Object e) => e);
      }

      expect(await slot('https://r2.example/b1'), isA<BlobSlot>());
      expect(await slot('http://127.0.0.1:9000/b1'), isA<BlobSlot>());
      expect(await slot('http://r2.example/b1'), isA<ChatFailure>());
      expect(await slot('ftp://r2.example/b1'), isA<ChatFailure>());
      expect(await slot(''), isA<ChatFailure>());
      expect(
        (await download('https://r2.example/b1') as dynamic).url,
        isNotEmpty,
      );
      expect(
        (await download('http://localhost:9000/b1') as dynamic).url,
        isNotEmpty,
      );
      // Before this, a download over plain http to any host was accepted.
      expect(await download('http://r2.example/b1'), isA<ChatFailure>());
      expect(await download('file:///etc/passwd'), isA<ChatFailure>());
    });
  });

  group('on a real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await (_core ??= RustLib.init(
        externalLibrary: ExternalLibrary.open(_corePath),
      ));
    });

    var now = DateTime.utc(2026, 10, 16, 12);
    final spare = <ChatEngine>[];
    tearDown(() {
      for (final e in spare) {
        e.dispose();
      }
      spare.clear();
    });

    ChatEngine make(
      String user,
      ChatApi api,
      ChatStore store, {
      List<Duration> keyRetryDelays = const [Duration(hours: 1)],
    }) {
      final engine = ChatEngine(
        userId: user,
        api: api,
        store: store,
        platform: 'test',
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        keyRetryDelays: keyRetryDelays,
        clock: () => now,
      );
      spare.add(engine);
      return engine;
    }

    Future<ChatEngine> start(String user, ChatApi api, ChatStore store) async {
      final engine = make(user, api, store);
      await engine.start(poll: Duration.zero);
      return engine;
    }

    Future<List<String>> texts(ChatEngine e) async => [
      for (final m in await e.history(conv))
        if (!m.notice) m.text,
    ];

    // ------------------------------------------------------------ CHAT-N4
    test(
      'a keystore error while the engine opens deletes and regenerates nothing',
      () async {
        final relay = MemoryRelay();
        final files = CrashFiles();
        final keystore = FlakyKeystore();
        final api = Api(relay, meId);
        final alice = await start(meId, api, await openStore(files, keystore));
        final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
        await alice.pollNow();
        await bob.pollNow();
        await bob.send(conv, meId, 'hi');
        await alice.pollNow();
        expect(await texts(alice), ['hi']);
        final device = alice.deviceId, identity = alice.identityKey;
        alice.dispose();
        final filesBefore = diskDigest(files);
        final keysBefore = jsonEncode(keystore.values);

        // The keystore fails after the snapshot opened: reading the pickle key is the first thing the engine does.
        final store = await openStore(files, keystore);
        keystore.failing = true;
        final broken = make(meId, api, store);
        await expectLater(
          broken.start(poll: Duration.zero),
          throwsA(isA<ChatStorageUnavailable>()),
        );
        keystore.failing = false;
        expect(diskDigest(files), filesBefore);
        expect(jsonEncode(keystore.values), keysBefore);
        expect(keystore.changes.where((c) => c.startsWith('delete')), isEmpty);

        // Once it opens again, it is the same device with the same keys and the same history.
        final back = await start(meId, api, await openStore(files, keystore));
        expect(back.deviceId, device);
        expect(back.identityKey, identity);
        expect(await texts(back), ['hi']);
        expect(back.ownDeviceNotices, isEmpty);
      },
    );

    // ------------------------------------------------------------ CHAT-N5
    test('a key upload that fails does not fail the start; the retry with backoff finishes it', () async {
      final relay = MemoryRelay();
      final api = CountingApi(relay, meId)
        ..plan.addAll([const ChatFailure('NETWORK', 'offline')]);
      final engine = make(
        meId,
        api,
        MemoryChatStore(),
        keyRetryDelays: const [Duration(milliseconds: 20)],
      );
      await engine.start(poll: Duration.zero);
      expect(
        relay.devices[meId],
        contains(engine.deviceId),
        reason: 'registered',
      );
      for (
        var i = 0;
        i < 100 && (relay.keys[meId]?[engine.deviceId]?.length ?? 0) < 60;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(relay.keys[meId]![engine.deviceId], hasLength(60));
      expect(api.uploads, greaterThanOrEqualTo(2));
    });

    test('sends still work from the keys already on the relay when the top-up fails on a restart', () async {
      final relay = MemoryRelay();
      final aliceApi = CountingApi(relay, meId);
      final store = MemoryChatStore();
      final alice = await start(meId, aliceApi, store);
      final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
      alice.dispose();
      // Claimed away down to 10, and the relay refuses uploads when the app starts again.
      relay.keys[meId]![alice.deviceId]!.removeRange(0, 50);
      aliceApi.plan.add(const ChatFailure('NETWORK', 'offline'));
      final again = await start(meId, aliceApi, store);
      await bob.pollNow();
      await bob.send(conv, meId, 'still works');
      await again.pollNow();
      expect(await texts(again), contains('still works'));
      await again.send(conv, peerId, 'and back');
      await bob.pollNow();
      expect(await texts(bob), contains('and back'));
    });

    test(
      'the relay is asked about key counts only after a pre-key message',
      () async {
        final relay = MemoryRelay();
        final aliceApi = CountingApi(relay, meId);
        final alice = await start(meId, aliceApi, MemoryChatStore());
        final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
        await alice.pollNow();
        await bob.pollNow();
        final base = aliceApi.keyCounts;
        await bob.send(
          conv,
          meId,
          'first',
        ); // starts a session: a pre-key message
        await alice.pollNow();
        expect(aliceApi.keyCounts, base + 1);
        await alice.send(conv, peerId, 'reply');
        await bob.pollNow();
        await bob.send(conv, meId, 'second'); // an ordinary message
        await bob.send(conv, meId, 'third');
        await alice.pollNow();
        expect(await texts(alice), containsAll(['first', 'second', 'third']));
        expect(
          aliceApi.keyCounts,
          base + 1,
          reason: 'no look after ordinary messages',
        );
      },
    );

    // ------------------------------------------------------------ CHAT-N6
    test('the pin of this account\'s other device and the review notice land in one commit: a kill at any step never leaves a silent pin', () async {
      // One run: returns how many disk operations the start took, and what a restarted phone finds.
      Future<({int ops, String? trust, String notes, String other})> run(
        int? crashAt,
      ) async {
        final relay = MemoryRelay();
        // The account already has a device on the relay.
        final other = await start(meId, Api(relay, meId), MemoryChatStore());
        var files = CrashFiles();
        final secure = MemoryChatStore();
        final engine = ChatEngine(
          userId: meId,
          api: Api(relay, meId),
          store: await openStore(files, secure),
          platform: 'test',
          clock: () => now,
        );
        files.crashAt = crashAt;
        try {
          await engine.start(poll: Duration.zero);
        } catch (_) {
          // killed
        }
        engine.dispose();
        final ops = files.ops;
        files = files.reboot();
        final back = await openStore(files, secure);
        return (
          ops: ops,
          trust: await back.read('hiyall.chat.$meId.trust'),
          notes: await back.read('hiyall.chat.$meId.devnotes') ?? '',
          other: other.deviceId,
        );
      }

      final whole = await run(null);
      expect(whole.trust, contains(whole.other));
      expect(whole.notes, contains('"k":"review"'));
      for (var step = 0; step <= whole.ops; step++) {
        final r = await run(step);
        if (r.trust != null && r.trust!.contains(r.other)) {
          expect(
            r.notes,
            contains('"k":"review"'),
            reason:
                'the other device is pinned at step $step without its notice',
          );
        }
      }
    });

    // ------------------------------------------------------------ CHAT-N8
    test('a snapshot that opened from the previous generation is a lost identity, said so', () async {
      final relay = MemoryRelay();
      final api = Api(relay, meId);
      final files = CrashFiles();
      final secure = MemoryChatStore();
      final alice = await start(meId, api, await openStore(files, secure));
      // A few commits, so a previous generation exists.
      await alice.pollNow();
      final bob = await start(peerId, Api(relay, peerId), MemoryChatStore());
      await bob.pollNow();
      await bob.send(conv, meId, 'one');
      await alice.pollNow();
      final oldDevice = alice.deviceId;
      alice.dispose();
      expect(files.disk.keys, contains('$meId.snap.prev'));
      files.disk.remove('$meId.snap');
      files.disk.remove('$meId.snap.tmp');

      final store = await openStore(files, secure);
      expect(store.info.rolledBack, isTrue);
      final back = await start(meId, api, store);
      expect(back.deviceId, isNot(oldDevice), reason: 'a new identity');
      expect(
        back.ownDeviceNotices.map((n) => n.kind),
        contains(DeviceNoticeKind.locked),
      );
      expect(
        api.revoked,
        contains(oldDevice),
        reason: 'the old device is taken off the relay',
      );
    });

    test(
      'a wiped keystore with surviving files is a lost identity, said so',
      () async {
        final relay = MemoryRelay();
        final api = Api(relay, meId);
        final files = CrashFiles();
        final first = await start(
          meId,
          api,
          await openStore(files, MemoryChatStore()),
        );
        final oldDevice = first.deviceId;
        first.dispose();
        final store = await openStore(files, MemoryChatStore(), keyByte: 3);
        expect(store.info.lost, isTrue);
        final back = await start(meId, api, store);
        expect(back.deviceId, isNot(oldDevice));
        expect(
          back.ownDeviceNotices.map((n) => n.kind),
          contains(DeviceNoticeKind.locked),
        );
      },
    );

    test(
      'an explicit reset notice is shown once the new identity is made',
      () async {
        final relay = MemoryRelay();
        final engine = ChatEngine(
          userId: meId,
          api: Api(relay, meId),
          store: MemoryChatStore(),
          platform: 'test',
          startNotice: DeviceNoticeKind.storage,
          clock: () => now,
        );
        spare.add(engine);
        await engine.start(poll: Duration.zero);
        expect(engine.ownDeviceNotices.map((n) => n.kind), [
          DeviceNoticeKind.storage,
        ]);
      },
    );
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

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Map<String, dynamic> body = {'data': {}};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
