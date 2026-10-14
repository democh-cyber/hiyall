import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_snapshot.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay;
import 'chat_robustness_test.dart' show Api;

// The encrypted snapshot store (audit C8): one sealed file per account,
// committed by temp file + sync + rename. These tests use an in-memory disk
// that can "kill the process" at any step.

class Crash implements Exception {
  @override
  String toString() => 'crash';
}

/// An in-memory disk. [crashAt] counts operations: when the counter reaches
/// it, that operation does not happen (for a write, only [partial] bytes of it
/// do) and every operation after it fails too, as if the process was gone.
class CrashFiles implements SnapshotFiles {
  Map<String, Uint8List> disk = {};
  int ops = 0;
  int? crashAt;
  int? partial; // bytes of the crashing write that reach the disk
  bool dead = false;
  final log = <String>[];

  void _step(String what) {
    if (dead) throw Crash();
    if (crashAt != null && ops == crashAt) {
      dead = true;
      throw Crash();
    }
    ops++;
    log.add(what);
  }

  /// What a restarted process finds.
  CrashFiles reboot() => CrashFiles()..disk = Map.of(disk);

  int get commits => log.where((l) => l.startsWith('write')).length;

  @override
  Future<Uint8List?> read(String name) async => disk[name];

  @override
  Future<void> writeSynced(String name, Uint8List bytes) async {
    if (dead) throw Crash();
    if (crashAt != null && ops == crashAt) {
      dead = true;
      final cut = partial;
      if (cut != null) disk[name] = Uint8List.sublistView(bytes, 0, cut);
      throw Crash();
    }
    ops++;
    log.add('write $name');
    disk[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> rename(String from, String to) async {
    _step('rename $from $to');
    final data = disk.remove(from);
    if (data == null) throw const FileSystemException('missing');
    disk[to] = data;
  }

  @override
  Future<void> delete(String name) async {
    _step('delete $name');
    disk.remove(name);
  }
}

/// Authenticates but does not hide: enough to test the framing, the AAD and
/// failure on a wrong key without the native core.
class FakeSealer implements SnapshotSealer {
  final List<int> key;
  FakeSealer(this.key);
  Uint8List _tag(Uint8List plain, Uint8List aad) =>
      Uint8List.fromList(Hmac(sha256, key).convert([...aad, ...plain]).bytes);
  @override
  Future<Uint8List> seal(Uint8List plain, Uint8List aad) async =>
      Uint8List.fromList([..._tag(plain, aad), ...plain]);
  @override
  Future<Uint8List> open(Uint8List sealed, Uint8List aad) async {
    if (sealed.length < 32) throw const FormatException('short');
    final plain = Uint8List.sublistView(sealed, 32);
    final tag = Uint8List.sublistView(sealed, 0, 32);
    final want = _tag(plain, aad);
    for (var i = 0; i < 32; i++) {
      if (tag[i] != want[i]) throw const FormatException('bad tag');
    }
    return Uint8List.fromList(plain);
  }
}

const user = 'user-1';
String k(String name) => 'hiyall.chat.$user.$name';

Future<SnapshotChatStore> open(
  CrashFiles files,
  ChatStore secure, {
  String who = user,
  int keyByte = 7,
}) => SnapshotChatStore.open(
  secure: secure,
  userId: who,
  files: files,
  newKey: () => List<int>.filled(32, keyByte),
  sealerFor: FakeSealer.new,
);

void main() {
  group('the snapshot store', () {
    late CrashFiles files;
    late MemoryChatStore secure;
    setUp(() {
      files = CrashFiles();
      secure = MemoryChatStore();
    });

    test(
      'entries survive a reopen; three secrets stay in the keystore',
      () async {
        final store = await open(files, secure);
        await store.write(k('history.c1'), 'one');
        await store.write(k('state'), 'two');
        await store.write(k('pickleKey'), 'secret');
        await store.write(k('deviceId'), 'dev');
        await store.write('hiyall.chatowner', user);
        expect(secure.values[k('pickleKey')], 'secret');
        expect(secure.values[k('deviceId')], 'dev');
        expect(secure.values['hiyall.chatowner'], user);
        expect(secure.values.containsKey(k('state')), isFalse);
        expect(secure.values.containsKey(k('snapKey')), isTrue);
        final again = await open(files.reboot(), secure);
        expect(await again.read(k('history.c1')), 'one');
        expect(await again.read(k('state')), 'two');
        expect(await again.read(k('pickleKey')), 'secret');
        expect(again.info.generation, store.generation);
        expect(await again.keys(), containsAll([k('state'), k('pickleKey')]));
      },
    );

    test(
      'the file holds no entry in the clear with the real cipher',
      skip: _coreMissing(),
      () async {
        await _initCore();
        final store = await SnapshotChatStore.open(
          secure: secure,
          userId: user,
          files: files,
        );
        await store.write(k('history.c1'), 'a very private sentence');
        final bytes = files.disk[store.snapshotName]!;
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains('private')),
        );
        final again = await SnapshotChatStore.open(
          secure: secure,
          userId: user,
          files: files.reboot(),
        );
        expect(await again.read(k('history.c1')), 'a very private sentence');
      },
    );

    test(
      'writes in one turn share a commit; each write returns after it',
      () async {
        final store = await open(files, secure);
        await Future.wait([
          store.write(k('a'), '1'),
          store.write(k('b'), '2'),
          store.write(k('c'), '3'),
        ]);
        expect(files.commits, 1);
        await store.write(k('a'), '1'); // same value: nothing to do
        expect(files.commits, 1);
        await store.write(k('a'), '9');
        expect(files.commits, 2);
        expect(store.generation, 2);
      },
    );

    test('a batch is one commit and lands whole', () async {
      final store = await open(files, secure);
      final result = await store.batch(() async {
        await store.write(k('a'), '1');
        await store.write(k('b'), '2');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await store.write(k('c'), '3');
        return 42;
      });
      expect(result, 42);
      expect(files.commits, 1);
      expect(store.generation, 1);
    });

    test('a batch that throws changes nothing', () async {
      final store = await open(files, secure);
      await store.write(k('a'), 'old');
      await expectLater(
        store.batch(() async {
          await store.write(k('a'), 'new');
          await store.write(k('b'), 'new');
          throw StateError('no');
        }),
        throwsStateError,
      );
      expect(await store.read(k('a')), 'old');
      expect(await store.read(k('b')), isNull);
      expect(files.commits, 1);
    });

    test(
      'a failed commit puts the entries back and reports the failure',
      () async {
        final store = await open(files, secure);
        await store.write(k('a'), 'old');
        files.crashAt = files.ops; // the next operation fails
        await expectLater(
          store.batch(() async {
            await store.write(k('a'), 'new');
            await store.write(k('b'), 'new');
          }),
          throwsA(isA<Crash>()),
        );
        expect(await store.read(k('a')), 'old');
        expect(await store.read(k('b')), isNull);
      },
    );

    test('a failed single write puts that entry back', () async {
      final store = await open(files, secure);
      await store.write(k('a'), 'old');
      files.crashAt = files.ops;
      await expectLater(store.write(k('a'), 'new'), throwsA(isA<Crash>()));
      expect(await store.read(k('a')), 'old');
    });

    test(
      'other writers wait for a running batch instead of joining it',
      () async {
        final store = await open(files, secure);
        final gate = Completer<void>();
        final order = <String>[];
        final batch = store.batch(() async {
          await store.write(k('a'), '1');
          await gate.future;
          order.add('batch done');
        });
        await Future<void>.delayed(Duration.zero);
        final outside = store.write(k('b'), '2').then((_) => order.add('b'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(order, isEmpty, reason: 'b waits for the batch');
        gate.complete();
        await Future.wait([batch, outside]);
        expect(order, ['batch done', 'b']);
        expect(files.commits, 2);
      },
    );

    test('a batch inside a batch just runs', () async {
      final store = await open(files, secure);
      await store.batch(() async {
        await store.write(k('a'), '1');
        await store.batch(() async => store.write(k('b'), '2'));
      });
      expect(files.commits, 1);
    });

    for (final cut in [null, 0, 5, 40]) {
      test('a crash at any step of a commit leaves the old snapshot or the new '
          'one, never a mix (partial write: $cut bytes)', () async {
        var steps = 0;
        // Learn how many operations a commit takes.
        {
          final f = CrashFiles();
          final s = await open(f, MemoryChatStore());
          await s.write(k('a'), 'old');
          final before = f.ops;
          await s.batch(() async {
            await s.write(k('a'), 'new');
            await s.write(k('b'), 'new');
          });
          steps = f.ops - before;
        }
        expect(steps, greaterThanOrEqualTo(3));
        var sawOld = 0, sawNew = 0;
        for (var crash = 0; crash <= steps; crash++) {
          final f = CrashFiles();
          final sec = MemoryChatStore();
          final s = await open(f, sec);
          await s.write(k('a'), 'old');
          await s.write(k('b'), 'old');
          f
            ..crashAt = f.ops + crash
            ..partial = cut;
          try {
            await s.batch(() async {
              await s.write(k('a'), 'new');
              await s.write(k('b'), 'new');
            });
          } on Crash {
            // expected for every step but the last
          }
          final back = await open(f.reboot(), sec);
          final a = await back.read(k('a')), b = await back.read(k('b'));
          expect(a, b, reason: 'crash at step $crash: a=$a b=$b');
          expect(a, anyOf('old', 'new'));
          a == 'old' ? sawOld++ : sawNew++;
        }
        expect(sawOld, greaterThan(0));
        expect(sawNew, greaterThan(0));
      });
    }

    test('a snapshot that was damaged falls back to the spare', () async {
      final store = await open(files, secure);
      await store.write(k('a'), '1');
      await store.write(k('a'), '2');
      final name = store.snapshotName;
      files.disk[name] = Uint8List.fromList([...files.disk[name]!]..[20] ^= 1);
      final again = await open(files.reboot(), secure);
      expect(await again.read(k('a')), '1');
      expect(again.info.loadedFrom, store.previousName);
    });

    test(
      'files that nothing opens are removed and the account starts empty',
      () async {
        final store = await open(files, secure);
        await store.write(k('a'), '1');
        secure.values.remove(k('snapKey')); // the key is gone
        final reopened = files.reboot();
        final again = await open(reopened, secure, keyByte: 9);
        expect(again.info.lost, isTrue);
        expect(await again.read(k('a')), isNull);
        expect(reopened.disk.keys, isEmpty);
      },
    );

    test('a snapshot cannot be moved to another account', () async {
      final store = await open(files, secure);
      await store.write(k('a'), '1');
      final other = CrashFiles()
        ..disk = {'user-2.snap': files.disk[store.snapshotName]!};
      final sec2 = MemoryChatStore()
        ..values['hiyall.chat.user-2.snapKey'] = secure.values[k('snapKey')]!;
      final taken = await open(other, sec2, who: 'user-2');
      expect(taken.info.lost, isTrue);
    });

    test(
      'entries from earlier builds move into the snapshot, then go',
      () async {
        secure.values
          ..[k('pickleKey')] = 'pk'
          ..[k('deviceId')] = 'dev'
          ..[k('state')] = 'old-state'
          ..[k('trust')] = '{}'
          ..[k('history.c1')] = '[1]'
          ..['hiyall.chat.other.state'] = 'someone else'
          ..['hiyall.chatowner'] = user;
        final store = await open(files, secure);
        expect(store.info.migrated, 3);
        expect(await store.read(k('state')), 'old-state');
        expect(await store.read(k('history.c1')), '[1]');
        expect(secure.values.containsKey(k('state')), isFalse);
        expect(secure.values.containsKey(k('trust')), isFalse);
        expect(secure.values[k('pickleKey')], 'pk');
        expect(secure.values[k('deviceId')], 'dev');
        expect(secure.values['hiyall.chat.other.state'], 'someone else');
        expect(secure.values['hiyall.chatowner'], user);
        final again = await open(files.reboot(), secure);
        expect(await again.read(k('state')), 'old-state');
        expect(again.info.migrated, 0);
      },
    );

    test('a crash during migration loses nothing', () async {
      for (var crash = 0; crash < 8; crash++) {
        final f = CrashFiles();
        final sec = _CrashySecure({
          k('state'): 's',
          k('history.c1'): 'h',
          k('snapKey'): base64Encode(List.filled(32, 7)),
        });
        f.crashAt = crash;
        // Deleting the old entries counts as steps too.
        sec.crashAfterDeletes = crash > 3 ? crash - 3 : null;
        try {
          await open(f, sec);
        } catch (_) {}
        sec.crashAfterDeletes = null;
        final back = await open(f.reboot(), sec);
        expect(await back.read(k('state')), 's', reason: 'crash $crash');
        expect(await back.read(k('history.c1')), 'h');
        expect(
          sec.values.keys.where((e) => e == k('state') || e == k('history.c1')),
          isEmpty,
          reason: 'old copies are gone once the snapshot is open',
        );
      }
    });

    test('the snapshot wins over leftovers of an earlier migration', () async {
      final store = await open(files, secure);
      await store.write(k('state'), 'new');
      secure.values[k('state')] = 'stale-legacy';
      final again = await open(files.reboot(), secure);
      expect(await again.read(k('state')), 'new');
      expect(secure.values.containsKey(k('state')), isFalse);
    });
  });

  group('the engine over the snapshot', skip: _coreMissing(), () {
    setUpAll(() async {
      await _initCore();
    });

    var now = DateTime.utc(2026, 10, 14, 12);

    Future<ChatEngine> device(String who, Api api, ChatStore store) async {
      final engine = ChatEngine(
        userId: who,
        api: api,
        store: store,
        platform: 'test',
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        clock: () => now,
      );
      await engine.start(poll: Duration.zero);
      return engine;
    }

    Future<List<String>> texts(ChatEngine e) async => [
      for (final m in await e.history(conv))
        if (!m.notice) m.text,
    ];
    Future<int> notices(ChatEngine e) async =>
        (await e.history(conv)).where((m) => m.notice).length;

    test(
      'receiving commits the message and the ratchet together: a crash at '
      'any step leaves both old or both new, and the message arrives once',
      () async {
        // How many disk operations does the receiving poll take?
        Future<
          ({
            MemoryRelay relay,
            Api aliceApi,
            CrashFiles files,
            MemoryChatStore secure,
            ChatEngine alice,
            ChatEngine bob,
          })
        >
        setup() async {
          now = DateTime.utc(2026, 10, 14, 12);
          final relay = MemoryRelay();
          final aliceApi = Api(relay, meId), bobApi = Api(relay, peerId);
          final files = CrashFiles(), secure = MemoryChatStore();
          final aliceStore = await SnapshotChatStore.open(
            secure: secure,
            userId: meId,
            files: files,
          );
          final alice = await device(meId, aliceApi, aliceStore);
          final bob = await device(peerId, bobApi, MemoryChatStore());
          relay.fallbackOf(alice.deviceId, aliceApi.fallbacks[alice.deviceId]!);
          await alice.pollNow(); // pins bob's devices, nothing else
          await bob.pollNow();
          await bob.send(conv, meId, 'first');
          await bob.send(conv, meId, 'second');
          return (
            relay: relay,
            aliceApi: aliceApi,
            files: files,
            secure: secure,
            alice: alice,
            bob: bob,
          );
        }

        final probe = await setup();
        final base = probe.files.ops;
        await probe.alice.pollNow();
        final steps = probe.files.ops - base;
        expect(steps, greaterThan(2));
        expect(await texts(probe.alice), ['first', 'second']);
        probe.alice.dispose();
        probe.bob.dispose();

        for (var crash = 0; crash <= steps; crash++) {
          final s = await setup();
          s.files.crashAt = s.files.ops + crash;
          await s.alice.pollNow().catchError((_) {});
          s.alice.dispose();
          // A restart: the keystore survives, the disk is what was synced.
          final files = s.files.reboot();
          final store = await SnapshotChatStore.open(
            secure: s.secure,
            userId: meId,
            files: files,
          );
          final alice = await device(meId, s.aliceApi, store);
          await alice.pollNow();
          expect(await texts(alice), [
            'first',
            'second',
          ], reason: 'crash at step $crash: each message once, in order');
          expect(await notices(alice), 0, reason: 'crash at step $crash');
          // And the ratchet still works in both directions.
          await s.bob.send(conv, meId, 'third');
          await alice.pollNow();
          await alice.send(conv, peerId, 'reply');
          await s.bob.pollNow();
          expect(await texts(alice), ['first', 'second', 'third', 'reply']);
          expect(await texts(s.bob), contains('reply'));
          expect(await notices(s.bob), 0);
          alice.dispose();
          s.bob.dispose();
        }
      },
    );

    test(
      'a poll of one message is a single commit for message and ratchet',
      () async {
        now = DateTime.utc(2026, 10, 14, 12);
        final relay = MemoryRelay();
        final aliceApi = Api(relay, meId), bobApi = Api(relay, peerId);
        final files = CrashFiles(), secure = MemoryChatStore();
        final aliceStore = await SnapshotChatStore.open(
          secure: secure,
          userId: meId,
          files: files,
        );
        final alice = await device(meId, aliceApi, aliceStore);
        final bob = await device(peerId, bobApi, MemoryChatStore());
        await alice.pollNow();
        await bob.send(conv, meId, 'hello');
        await alice.pollNow(); // first contact: pins bob, then opens
        await bob.send(conv, meId, 'again');
        final before = files.commits;
        await alice.pollNow();
        expect(files.commits - before, 1);
        expect(await texts(alice), ['hello', 'again']);
        alice.dispose();
        bob.dispose();
      },
    );

    test('an engine started on a store of the old kind moves over', () async {
      final relay = MemoryRelay();
      final aliceApi = Api(relay, meId);
      final secure = MemoryChatStore();
      final first = await device(meId, aliceApi, secure);
      final identity = first.identityKey, id = first.deviceId;
      first.dispose();
      final store = await SnapshotChatStore.open(
        secure: secure,
        userId: meId,
        files: CrashFiles(),
      );
      expect(store.info.migrated, greaterThan(0));
      final second = await device(meId, aliceApi, store);
      expect(second.identityKey, identity);
      expect(second.deviceId, id);
      expect(secure.values.containsKey('hiyall.chat.$meId.state'), isFalse);
      second.dispose();
    });
  });
}

class _CrashySecure extends MemoryChatStore {
  _CrashySecure(Map<String, String> initial) {
    values.addAll(initial);
  }
  int? crashAfterDeletes;
  int _deletes = 0;
  @override
  Future<void> delete(String key) {
    if (crashAfterDeletes != null && _deletes++ >= crashAfterDeletes!) {
      throw Crash();
    }
    return super.delete(key);
  }
}

extension on MemoryRelay {
  void fallbackOf(String deviceId, Map<String, String> key) {}
}

final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';

String? _coreMissing() => File(_corePath).existsSync()
    ? null
    : 'the debug Rust core is not built (cargo build in apps/mobile/rust)';

Future<void>? _core;
Future<void> _initCore() =>
    _core ??= RustLib.init(externalLibrary: ExternalLibrary.open(_corePath));
