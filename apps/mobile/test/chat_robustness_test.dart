import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_history.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/chat/chat_text.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay, RelayApi;

// The relay of the reactions tests, plus what these tests need from it: the
// fallback key (claimed when no one-time key is left), a recorded list of
// removed devices, devices the relay no longer knows, and a conversation read.
class Api extends RelayApi {
  Api(super.relay, super.user);
  final fallbacks = <String, Map<String, String>>{};
  final revoked = <String>[];
  final unknown = <String>{};
  Object? failRevoke;

  @override
  Future<int> uploadKeys(
    String deviceId,
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  ) async {
    if (fallbackKey != null) fallbacks[deviceId] = fallbackKey;
    return super.uploadKeys(deviceId, oneTimeKeys, fallbackKey);
  }

  @override
  Future<Map<String, dynamic>> claim(String userId, String deviceId) async {
    final pool = relay.keys[userId]![deviceId]!;
    if (pool.isNotEmpty) return super.claim(userId, deviceId);
    final fb = (relay.fallbackOf[deviceId])!;
    return {...fb, 'fallback': true, 'deviceId': deviceId};
  }

  @override
  Future<void> registerDevice(Map<String, String> d) async {
    if (unknown.contains(d['deviceId'])) {
      throw const ChatFailure('DEVICE_CONFLICT', 'revoked', 409);
    }
    return super.registerDevice(d);
  }

  @override
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async {
    if (unknown.contains(deviceId)) {
      throw const ChatFailure('NOT_FOUND', 'gone', 404);
    }
    return super.inbox(deviceId);
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    final failure = failRevoke;
    if (failure != null) throw failure;
    revoked.add(deviceId);
  }

  @override
  Future<Map<String, dynamic>> conversation(String id) async => {
    'peer': {'userId': user == meId ? peerId : meId},
  };
}

extension on MemoryRelay {
  static final _fallbacks = Expando<Map<String, Map<String, String>>>();
  Map<String, Map<String, String>> get fallbackOf =>
      _fallbacks[this] ??= <String, Map<String, String>>{};
}

/// Writes of the history can be made to fail once.
class FlakyStore extends MemoryChatStore {
  bool failHistory = false;
  @override
  Future<void> write(String key, String value) {
    if (failHistory && key.contains('.history.')) {
      failHistory = false;
      throw const FileSystemException('disk full');
    }
    return super.write(key, value);
  }
}

ChatMessage msg(
  String id, {
  required DateTime sentAt,
  DateTime? serverAt,
  bool mine = false,
  String text = 'hi',
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: text,
  sentAt: sentAt,
  serverAt: serverAt,
  mine: mine,
);

String uid(int n) =>
    '7a7a0000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

void main() {
  group('relay time orders the conversation (C4)', () {
    final base = DateTime.utc(2026, 10, 13, 12);

    test('a future-dated burst cannot reorder or evict', () async {
      final store = MemoryChatStore();
      final dropped = <int>[];
      final history = ChatHistory(
        store,
        (c) => 'h.$c',
        onDropped: (_, gone, _) => dropped.add(gone.length),
      );
      // Five real messages, then a hostile burst that claims the year 2099 but
      // reached the relay a second apart.
      for (var i = 0; i < 5; i++) {
        await history.append(
          conv,
          msg(
            uid(i),
            sentAt: base.add(Duration(minutes: i)),
            serverAt: base.add(Duration(minutes: i)),
            mine: i.isEven,
            text: 'real $i',
          ),
        );
      }
      for (var i = 0; i < 100; i++) {
        await history.append(
          conv,
          msg(
            uid(1000 + i),
            sentAt: DateTime.utc(2099, 1, 1, 0, 0, i),
            serverAt: base.add(Duration(hours: 1, seconds: i)),
            text: 'burst $i',
          ),
        );
      }
      // A message from this account after the burst belongs after it, not
      // among the real ones.
      await history.append(
        conv,
        msg(
          uid(2000),
          sentAt: base.add(const Duration(hours: 2)),
          serverAt: base.add(const Duration(hours: 2)),
          mine: true,
          text: 'mine, last',
        ),
      );
      final list = await history.read(conv);
      expect(list.first.text, 'real 0');
      expect(list.last.text, 'mine, last');
      expect(list.map((m) => m.text).toList().sublist(5, 105), [
        for (var i = 0; i < 100; i++) 'burst $i',
      ], reason: 'the burst keeps the relay\'s order');
      expect(dropped, isEmpty);
    });

    test('eviction drops the oldest by relay time', () async {
      final dropped = <String>[];
      final history = ChatHistory(
        MemoryChatStore(),
        (c) => 'h.$c',
        onDropped: (_, gone, _) => dropped.addAll(gone.map((m) => m.text)),
      );
      // The oldest by the relay's clock claims to be the newest.
      await history.append(
        conv,
        msg(
          uid(1),
          sentAt: DateTime.utc(2099),
          serverAt: base,
          text: 'oldest, future sentAt',
        ),
      );
      for (var i = 0; i < ChatHistory.limit; i++) {
        await history.append(
          conv,
          msg(
            uid(10 + i),
            sentAt: base.add(Duration(minutes: i + 1)),
            serverAt: base.add(Duration(minutes: i + 1)),
            text: 'm$i',
          ),
        );
      }
      expect(dropped, ['oldest, future sentAt']);
      final list = await history.read(conv);
      expect(list.length, ChatHistory.limit);
      expect(list.first.text, 'm0');
    });

    test('the sender time shows only within ten minutes of the relay', () {
      final relay = base;
      expect(
        msg(
          'a',
          sentAt: relay.add(const Duration(minutes: 9)),
          serverAt: relay,
        ).shownAt,
        relay.add(const Duration(minutes: 9)),
      );
      expect(
        msg(
          'a',
          sentAt: relay.subtract(const Duration(minutes: 10)),
          serverAt: relay,
        ).shownAt,
        relay.subtract(const Duration(minutes: 10)),
      );
      expect(
        msg(
          'a',
          sentAt: relay.add(const Duration(minutes: 11)),
          serverAt: relay,
        ).shownAt,
        relay,
      );
      expect(
        msg('a', sentAt: DateTime.utc(2099), serverAt: relay).shownAt,
        relay,
      );
      // Without a relay time (a message not sent yet) its own time shows.
      expect(msg('a', sentAt: DateTime.utc(2099)).shownAt, DateTime.utc(2099));
      expect(msg('a', sentAt: DateTime.utc(2099)).at, DateTime.utc(2099));
    });

    test('a received message is placed by the relay time', () {
      final incoming = parseIncoming(
        {
          'v': 1,
          'kind': 'text',
          'text': 'from the future',
          'messageId': uid(5),
          'conversationId': conv,
          'senderId': peerId,
          'sentAt': DateTime.utc(2099).toIso8601String(),
        },
        messageId: uid(5),
        conversationId: conv,
        senderId: peerId,
        me: meId,
        serverAt: base,
      );
      final m = (incoming as IncomingMessage).message;
      expect(m.at, base);
      expect(m.shownAt, base);
    });
  });

  group('text from peers (F23)', () {
    test('bidirectional and zero-width controls are removed', () {
      expect(displayText('exe\u202Egnp.txt'), 'exegnp.txt');
      expect(
        displayText('a\u200Bb\u200Ec\u200Fd\u2066e\u2069f\uFEFFg'),
        'abcdefg',
      );
      expect(displayText('x\u0000y\u0085z\u009F'), 'xyz');
      // Emoji joiners, line breaks and tabs stay.
      expect(
        displayText('👨\u200D👩\u200D👧\nok\t.'),
        '👨\u200D👩\u200D👧\nok\t.',
      );
      final same = 'nothing to remove';
      expect(identical(displayText(same), same), isTrue);
    });

    test('a received message is cleaned, and drawing cleans again', () {
      final incoming = parseIncoming(
        {
          'v': 1,
          'kind': 'text',
          'text': 'pay\u202E 100',
          'messageId': uid(7),
          'conversationId': conv,
          'senderId': peerId,
          'sentAt': DateTime.utc(2026).toIso8601String(),
        },
        messageId: uid(7),
        conversationId: conv,
        senderId: peerId,
        me: meId,
      );
      expect((incoming as IncomingMessage).message.text, 'pay 100');
      final dirty = msg(uid(8), sentAt: DateTime.utc(2026), text: 'a\u200Bb');
      expect(dirty.display.text, 'ab');
    });

    test('one bad history entry does not break the conversation', () async {
      final store = MemoryChatStore();
      final good = msg(uid(1), sentAt: DateTime.utc(2026), text: 'kept');
      store.values['h.$conv'] = jsonEncode([
        good.toJson(),
        {'id': 5, 'oops': true},
        'not even a map',
        {...msg(uid(2), sentAt: DateTime.utc(2026, 1, 2)).toJson(), 'at': 'x'},
        msg(
          uid(3),
          sentAt: DateTime.utc(2026, 1, 3),
          text: 'also kept',
        ).toJson(),
      ]);
      final history = ChatHistory(store, (c) => 'h.$c');
      expect((await history.read(conv)).map((m) => m.text), [
        'kept',
        'also kept',
      ]);
      // A list that is not JSON at all is an empty conversation, not a crash.
      store.values['h.other'] = '{{{';
      expect(await history.read('other'), isEmpty);
    });
  });

  group('received photo descriptors are capped (C10)', () {
    Map<String, dynamic> descriptor({
      int w = 1536,
      int h = 2048,
      int tw = 240,
      int th = 320,
      String caption = 'hi',
    }) {
      const chunk = 65536;
      const plain = 3000, thumbPlain = 200;
      final ct = ciphertextLength(plain, chunk);
      final thumbCt = ciphertextLength(thumbPlain, chunk);
      final hash = base64Encode(List.filled(32, 3));
      return {
        'v': 1,
        'key': base64Encode(List.filled(32, 1)),
        'salt': uid(40),
        'mime': 'image/jpeg',
        'w': w,
        'h': h,
        'chunk': chunk,
        'plainLen': plain,
        'ctSize': ct,
        'ctSha256': hash,
        'blobs': {'full': uid(41)},
        'thumb': {
          'blob': uid(42),
          'w': tw,
          'h': th,
          'plainLen': thumbPlain,
          'ctSize': thumbCt,
          'ctSha256': hash,
        },
        'preview': {'t': 'thumbhash', 'd': base64Encode(List.filled(21, 4))},
        'caption': caption,
      };
    }

    test('what the sender sends is accepted', () {
      expect(() => ChatAttachment.parse(descriptor()), returnsNormally);
      expect(
        () => ChatAttachment.parse(
          descriptor(w: 2048, h: 2048, tw: 320, th: 320),
        ),
        returnsNormally,
        reason: '2048 x 2048 is the largest square the sender makes',
      );
      expect(
        () => ChatAttachment.parse(descriptor(caption: 'x' * maxCaption)),
        returnsNormally,
      );
    });

    test('anything bigger is refused', () {
      for (final bad in [
        descriptor(w: 2049, h: 100),
        descriptor(w: 100, h: 2049),
        descriptor(w: 12000, h: 3000),
        descriptor(w: 2048, h: 2049),
        descriptor(tw: 321, th: 100),
        descriptor(tw: 100, th: 321),
        descriptor(caption: 'x' * (maxCaption + 1)),
      ]) {
        expect(() => ChatAttachment.parse(bad), throwsFormatException);
      }
    });

    test(
      'a photo over the caps becomes an unsupported photo, not an error',
      () {
        final incoming = parseIncoming(
          {
            'v': 1,
            'kind': 'image',
            'text': 'hi',
            'messageId': uid(60),
            'conversationId': conv,
            'senderId': peerId,
            'sentAt': DateTime.utc(2026).toIso8601String(),
            'att': descriptor(w: 9000, h: 9000),
          },
          messageId: uid(60),
          conversationId: conv,
          senderId: peerId,
          me: meId,
        );
        expect((incoming as IncomingMessage).message.unsupportedPhoto, isTrue);
      },
    );
  });

  group('chat data on the device (C2)', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('hiyall_wipe'));
    tearDown(() => root.deleteSync(recursive: true));

    Future<MemoryChatStore> filled() async {
      final store = MemoryChatStore();
      for (final user in [meId, peerId]) {
        for (final name in [
          'pickleKey',
          'state',
          'account',
          'sessions',
          'trust',
          'deviceId',
          'outbox',
          'history.$conv',
          'verified',
        ]) {
          store.values['hiyall.chat.$user.$name'] = 'x-$name';
        }
      }
      store.values['hiyall.chat.$meId.deviceId'] = 'device-of-me';
      store.values[ChatLocalData.ownerKey] = meId;
      store.values['other_feature'] = 'stays';
      for (final dir in ChatLocalData.folders) {
        Directory('${root.path}/$dir').createSync();
        File('${root.path}/$dir/a').writeAsStringSync('ciphertext');
      }
      return store;
    }

    test('signing out erases every key of the account and its files', () async {
      final store = await filled();
      final revoked = <String>[];
      await ChatLocalData.wipeAccount(
        root: root,
        store: store,
        userId: meId,
        revoke: (id) async => revoked.add(id),
      );
      expect(
        store.values.keys.where((k) => k.startsWith('hiyall.chat.$meId.')),
        isEmpty,
      );
      expect(revoked, ['device-of-me']);
      // Nothing else is touched: another account's data and other features.
      expect(
        store.values.keys.where((k) => k.startsWith('hiyall.chat.$peerId.')),
        isNotEmpty,
      );
      expect(store.values['other_feature'], 'stays');
      expect(store.values.containsKey(ChatLocalData.ownerKey), isFalse);
      for (final dir in ChatLocalData.folders) {
        expect(Directory('${root.path}/$dir').existsSync(), isFalse);
      }
      expect(await ChatLocalData.pendingRevoke(store, meId), isNull);
    });

    test(
      'a server removal that fails is remembered for the next launch',
      () async {
        final store = await filled();
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: meId,
          revoke: (id) async => throw const ChatFailure('NETWORK', 'offline'),
        );
        expect(await ChatLocalData.pendingRevoke(store, meId), 'device-of-me');
        expect(
          store.values.keys.where((k) => k.startsWith('hiyall.chat.$meId.')),
          isEmpty,
        );
        // Without any attempt (the credential is gone) it is remembered too.
        final other = await filled();
        await ChatLocalData.wipeAccount(root: root, store: other, userId: meId);
        expect(await ChatLocalData.pendingRevoke(other, meId), 'device-of-me');
      },
    );

    test('a fresh install erases what the keychain kept', () async {
      final store = await filled();
      // No marker in the app folder: the files went with the app, the keychain
      // items did not.
      final marker = File('${root.path}/${ChatLocalData.markerName}');
      for (final dir in ChatLocalData.folders) {
        Directory('${root.path}/$dir').deleteSync(recursive: true);
      }
      expect(marker.existsSync(), isFalse);
      final erased = await ChatLocalData.eraseAfterReinstall(
        root: root,
        store: store,
      );
      expect(erased, 2);
      expect(
        store.values.keys.where((k) => k.startsWith(ChatLocalData.anyPrefix)),
        isEmpty,
      );
      expect(store.values['other_feature'], 'stays');
      expect(marker.existsSync(), isTrue);
      // The old devices are remembered so the server can be told.
      expect(await ChatLocalData.pendingRevoke(store, meId), 'device-of-me');
      expect(await ChatLocalData.pendingRevoke(store, peerId), 'x-deviceId');

      // A normal launch (the marker is there) leaves new data alone.
      store.values['hiyall.chat.$meId.pickleKey'] = 'new';
      expect(
        await ChatLocalData.eraseAfterReinstall(root: root, store: store),
        0,
      );
      expect(store.values['hiyall.chat.$meId.pickleKey'], 'new');
    });

    test(
      'a first launch with nothing to erase only writes the marker',
      () async {
        final store = MemoryChatStore();
        expect(
          await ChatLocalData.eraseAfterReinstall(root: root, store: store),
          0,
        );
        expect(
          File('${root.path}/${ChatLocalData.markerName}').existsSync(),
          isTrue,
        );
      },
    );
  });

  group('two devices over the real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_corePath));
    });

    late MemoryRelay relay;
    late Api aliceApi, bobApi;
    late ChatEngine alice, bob;
    late MemoryChatStore aliceStore, bobStore;
    var now = DateTime.utc(2026, 10, 13, 12);
    final spare = <ChatEngine>[];

    Future<ChatEngine> device(
      String user,
      Api api,
      MemoryChatStore store, {
      DateTime Function()? clock,
    }) async {
      final engine = ChatEngine(
        userId: user,
        api: api,
        store: store,
        platform: 'test',
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        clock: clock ?? () => now,
      );
      await engine.start(poll: Duration.zero);
      spare.add(engine);
      return engine;
    }

    /// Starts a device again from what it saved, as the app does on launch.
    Future<ChatEngine> restart(ChatEngine old, Api api, MemoryChatStore store) {
      old.dispose();
      return device(old.userId, api, store);
    }

    setUp(() async {
      now = DateTime.utc(2026, 10, 13, 12);
      relay = MemoryRelay();
      aliceApi = Api(relay, meId);
      bobApi = Api(relay, peerId);
      aliceStore = MemoryChatStore();
      bobStore = MemoryChatStore();
      alice = await device(meId, aliceApi, aliceStore);
      bob = await device(peerId, bobApi, bobStore);
      // The relay hands out the fallback key when no one-time key is left.
      relay.fallbackOf[alice.deviceId] = aliceApi.fallbacks[alice.deviceId]!;
      relay.fallbackOf[bob.deviceId] = bobApi.fallbacks[bob.deviceId]!;
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
    Future<int> notices(ChatEngine e) async =>
        (await e.history(conv)).where((m) => m.notice).length;

    group('Olm sessions that cross (C1)', () {
      test('both sides start a session before either polls', () async {
        await alice.send(conv, peerId, 'a1');
        await bob.send(conv, meId, 'b1');
        await alice.pollNow();
        await bob.pollNow();
        expect(await texts(alice), containsAll(['a1', 'b1']));
        expect(await texts(bob), containsAll(['a1', 'b1']));
        // Both sessions are kept.
        expect(alice.debugSessionCount(bob.deviceId), 2);
        expect(bob.debugSessionCount(alice.deviceId), 2);
        // And the conversation carries on in both directions, again and again.
        for (var i = 0; i < 5; i++) {
          await alice.send(conv, peerId, 'a-next-$i');
          await bob.pollNow();
          await bob.send(conv, meId, 'b-next-$i');
          await alice.pollNow();
        }
        for (final e in [alice, bob]) {
          expect(await notices(e), 0, reason: 'nothing was undecryptable');
          final seen = await texts(e);
          for (var i = 0; i < 5; i++) {
            expect(seen, containsAll(['a-next-$i', 'b-next-$i']));
          }
        }
        // Nobody had to start over.
        expect(
          relay.wire.where((w) => w['aux'] == true),
          isEmpty,
          reason: 'no unwedging message was needed',
        );
      });

      test('bursts that cross are all read', () async {
        for (var i = 0; i < 3; i++) {
          await alice.send(conv, peerId, 'x$i');
          await bob.send(conv, meId, 'y$i');
        }
        await alice.pollNow();
        await bob.pollNow();
        for (final e in [alice, bob]) {
          expect(await notices(e), 0);
          expect(
            await texts(e),
            containsAll([
              for (var i = 0; i < 3; i++) ...['x$i', 'y$i'],
            ]),
          );
        }
        await alice.send(conv, peerId, 'after');
        await bob.pollNow();
        await bob.send(conv, meId, 'back');
        await alice.pollNow();
        expect(await texts(bob), contains('after'));
        expect(await texts(alice), contains('back'));
      });

      test('sending uses the session that last decrypted', () async {
        await alice.send(conv, peerId, 'a1');
        await bob.send(conv, meId, 'b1');
        await alice.pollNow();
        await bob.pollNow();
        // Alice just opened Bob's pre-key message, so that session is first.
        final first = alice.debugSessionIds(bob.deviceId).first;
        await alice.send(conv, peerId, 'a2');
        expect(alice.debugSessionIds(bob.deviceId).first, first);
        await bob.pollNow();
        // Bob opened it with the session it belongs to, which moved to the front.
        await bob.send(conv, meId, 'b2');
        await alice.pollNow();
        expect(alice.debugSessionIds(bob.deviceId).first, first);
      });

      test('at most five sessions are kept per device, newest first', () async {
        await alice.send(conv, peerId, 'first');
        await bob.pollNow();
        var current = alice;
        for (var i = 0; i < 7; i++) {
          // Alice loses her sessions and starts a fresh one each time.
          final saved = jsonDecode(
            aliceStore.values['hiyall.chat.$meId.state']!,
          ) as Map<String, dynamic>;
          saved['sessions'] = <String, dynamic>{};
          aliceStore.values['hiyall.chat.$meId.state'] = jsonEncode(saved);
          current = await restart(current, aliceApi, aliceStore);
          alice = current;
          await alice.send(conv, peerId, 'again $i');
          await bob.pollNow();
        }
        expect(
          bob.debugSessionCount(alice.deviceId),
          ChatEngine.maxSessionsPerDevice,
        );
        expect(await texts(bob), contains('again 6'));
        expect(await notices(bob), 0);
      });

      test('a replayed pre-key message does not replace a working session', () async {
        // No one-time keys left: Alice's first message uses Bob's fallback key.
        relay.keys[peerId]![bob.deviceId]!.clear();
        await alice.send(conv, peerId, 'one');
        final replay = Map<String, dynamic>.from(
          relay.inboxes[bob.deviceId]!.single,
        );
        expect(replay['type'], 0);
        await bob.pollNow();
        await bob.send(conv, meId, 'two');
        await alice.pollNow();
        await alice.send(conv, peerId, 'three');
        await bob.pollNow();
        final working = bob.debugSessionIds(alice.deviceId);
        expect(working, isNotEmpty);

        // The relay delivers the same pre-key ciphertext again, as a new item.
        relay.inboxes[bob.deviceId]!.add({...replay, 'messageId': uid(900)});
        await bob.pollNow();
        // The replay is not a message, the working session is still there, and
        // nothing was shown twice.
        expect(bob.debugSessionIds(alice.deviceId), containsAll(working));
        expect((await texts(bob)).where((t) => t == 'one'), hasLength(1));

        // Whatever Bob sent to straighten things out (a quiet message on a new
        // session) is read by Alice, and the chat still works both ways.
        await alice.pollNow();
        await alice.send(conv, peerId, 'four');
        await bob.pollNow();
        await bob.send(conv, meId, 'five');
        await alice.pollNow();
        expect(await texts(bob), contains('four'));
        expect(await texts(alice), contains('five'));
      });
    });

    group('unwedging (C1)', () {
      Future<ChatEngine> bobLosesHisSessions() async {
        final key = 'hiyall.chat.$peerId.state';
        final saved = jsonDecode(bobStore.values[key]!) as Map<String, dynamic>;
        saved['sessions'] = <String, dynamic>{};
        bobStore.values[key] = jsonEncode(saved);
        return bob = await restart(bob, bobApi, bobStore);
      }

      test(
        'one fresh session and a quiet noop, once an hour per device',
        () async {
          await alice.send(conv, peerId, 'one');
          await bob.pollNow();
          await bob.send(conv, meId, 'two');
          await alice.pollNow();
          await bobLosesHisSessions();

          await alice.send(conv, peerId, 'three');
          await bob.pollNow();
          expect(await notices(bob), 1, reason: 'three could not be read');
          final noops = relay.wire.where(
            (w) => w['aux'] == true && w['from'] == peerId,
          );
          expect(noops, hasLength(1), reason: 'one quiet message to unwedge');

          // Alice opens it silently and now has a session Bob can read.
          await alice.pollNow();
          expect(await notices(alice), 0);
          expect(await texts(alice), ['one', 'two', 'three']);
          await alice.send(conv, peerId, 'four');
          await bob.pollNow();
          expect(await texts(bob), contains('four'));
          await bob.send(conv, meId, 'five');
          await alice.pollNow();
          expect(await texts(alice), contains('five'));

          // Bob loses them again within the hour: no second noop.
          await bobLosesHisSessions();
          await alice.send(conv, peerId, 'six');
          await bob.pollNow();
          expect(
            relay.wire.where((w) => w['aux'] == true && w['from'] == peerId),
            hasLength(1),
          );

          // An hour later it is allowed once more.
          now = now.add(const Duration(minutes: 61));
          await bobLosesHisSessions();
          await alice.send(conv, peerId, 'seven');
          await bob.pollNow();
          expect(
            relay.wire.where((w) => w['aux'] == true && w['from'] == peerId),
            hasLength(2),
          );
        },
      );

      test('the noop is invisible: no bubble, no unread, no notice', () async {
        await alice.send(conv, peerId, 'one');
        await bob.pollNow();
        await bobLosesHisSessions();
        await alice.send(conv, peerId, 'two');
        await bob.pollNow();
        final unreadBefore = relay.unread[meId] ?? 0;
        await alice.pollNow();
        expect(relay.unread[meId] ?? 0, unreadBefore);
        expect((await alice.history(conv)).map((m) => m.text), ['one', 'two']);
      });
    });

    group('text that is sent before the network (C9)', () {
      test(
        'a failed send stays as not sent and a retry reuses its id',
        () async {
          relay.failNext = const ChatFailure('NETWORK', 'offline');
          await expectLater(
            alice.send(conv, peerId, 'hello'),
            throwsA(isA<ChatFailure>()),
          );
          var list = await alice.history(conv);
          expect(list, hasLength(1));
          expect(list.single.status, SendStatus.failed);
          expect(list.single.failure, 'NETWORK');
          final id = list.single.messageId;

          await alice.retryText(conv, peerId, id);
          list = await alice.history(conv);
          expect(list, hasLength(1));
          expect(list.single.status, SendStatus.sent);
          expect(list.single.messageId, id);
          expect(list.single.serverAt, isNotNull);
          // The relay saw the same id twice and stored it once.
          expect(relay.wire.where((w) => w['messageId'] == id), hasLength(2));
          expect(relay.stored.keys.where((k) => k == id), hasLength(1));
          await bob.pollNow();
          expect((await bob.history(conv)).map((m) => m.text), ['hello']);
        },
      );

      test('a send whose reply was lost is not delivered twice', () async {
        // The relay stored it, the answer never came back.
        await alice.send(conv, peerId, 'once');
        final id = (await alice.history(conv)).single.messageId;
        // Pretend the app crashed before the result was written.
        final key = 'hiyall.chat.$meId.history.$conv';
        final stored = jsonDecode(aliceStore.values[key]!) as List;
        (stored.single as Map)['st'] = 'sending';
        aliceStore.values[key] = jsonEncode(stored);
        alice = await restart(alice, aliceApi, aliceStore);
        var m = (await alice.history(conv)).single;
        expect(
          m.status,
          SendStatus.failed,
          reason: 'a restart shows it not sent',
        );
        expect(m.failure, 'INTERRUPTED');
        await alice.retryText(conv, peerId, id);
        m = (await alice.history(conv)).single;
        expect(m.status, SendStatus.sent);
        await bob.pollNow();
        expect((await bob.history(conv)).map((m) => m.text), ['once']);
      });

      test(
        'the message is in the history before the network is touched',
        () async {
          // Stop the relay from ever answering by failing at the very start.
          relay.failNext = const ChatFailure('NETWORK', 'offline');
          final sending = alice.send(conv, peerId, 'draft');
          await expectLater(sending, throwsA(isA<ChatFailure>()));
          // It is in the persisted history, ready for a retry after a restart.
          final raw = jsonDecode(
            aliceStore.values['hiyall.chat.$meId.history.$conv']!,
          ) as List;
          expect(raw, hasLength(1));
          expect((raw.single as Map)['text'], 'draft');
          expect((raw.single as Map)['st'], 'failed');
        },
      );

      test('a refusal removes the message and says why', () async {
        relay.failNext = const ChatFailure('AWAITING_REPLY', 'wait', 403);
        await expectLater(
          alice.send(conv, peerId, 'too many'),
          throwsA(
            isA<ChatFailure>().having((e) => e.code, 'code', 'AWAITING_REPLY'),
          ),
        );
        expect(await alice.history(conv), isEmpty);
      });

      test('delete removes a message that never went out', () async {
        relay.failNext = const ChatFailure('NETWORK', 'offline');
        await expectLater(
          alice.send(conv, peerId, 'never'),
          throwsA(isA<ChatFailure>()),
        );
        final id = (await alice.history(conv)).single.messageId;
        await alice.discardText(conv, id);
        expect(await alice.history(conv), isEmpty);
        // A delivered message cannot be discarded.
        await alice.send(conv, peerId, 'delivered');
        await alice.discardText(
          conv,
          (await alice.history(conv)).single.messageId,
        );
        expect(await alice.history(conv), hasLength(1));
      });
    });

    group('receive order (C8)', () {
      test('a failed history write is not acknowledged and is read again', () async {
        final flaky = FlakyStore();
        bob.dispose();
        bob = await device(peerId, bobApi, flaky);
        await alice.send(conv, peerId, 'first');
        await alice.send(conv, peerId, 'second');
        flaky.failHistory = true;
        await bob.pollNow();
        // The first stayed on the relay; the second was read (its ratchet moved
        // past the first, whose key was kept for later).
        expect(relay.inboxes[bob.deviceId], hasLength(1));
        expect(
          relay.inboxes[bob.deviceId]!.single['messageId'],
          (await alice.history(conv)).first.messageId,
        );
        await bob.pollNow();
        expect(relay.inboxes[bob.deviceId], isEmpty);
        expect(await texts(bob), ['first', 'second']);
        expect(await notices(bob), 0);
        // And the chat carries on.
        await alice.send(conv, peerId, 'third');
        await bob.pollNow();
        expect(await texts(bob), ['first', 'second', 'third']);
      });

      test('account and sessions are saved in one entry', () async {
        await alice.send(conv, peerId, 'x');
        await bob.pollNow();
        final keys = bobStore.values.keys.where(
          (k) => k.contains('.$peerId.') || k.startsWith('hiyall.chat.$peerId'),
        );
        expect(keys, contains('hiyall.chat.$peerId.state'));
        expect(keys, isNot(contains('hiyall.chat.$peerId.account')));
        expect(keys, isNot(contains('hiyall.chat.$peerId.sessions')));
        final state = jsonDecode(bobStore.values['hiyall.chat.$peerId.state']!);
        expect((state as Map).keys, containsAll(['account', 'sessions']));
      });

      test('state written by the earlier build is read and moved', () async {
        await alice.send(conv, peerId, 'x');
        await bob.pollNow();
        final state = jsonDecode(
          bobStore.values['hiyall.chat.$peerId.state']!,
        ) as Map<String, dynamic>;
        // Rewrite it the old way: separate entries, one session per device.
        final sessions = (state['sessions'] as Map).map(
          (k, v) => MapEntry(k, (v as List).first),
        );
        bobStore.values
          ..remove('hiyall.chat.$peerId.state')
          ..['hiyall.chat.$peerId.account'] = state['account'] as String
          ..['hiyall.chat.$peerId.sessions'] = jsonEncode(sessions);
        bob = await restart(bob, bobApi, bobStore);
        expect(
          bobStore.values.containsKey('hiyall.chat.$peerId.account'),
          isFalse,
        );
        expect(
          bobStore.values.containsKey('hiyall.chat.$peerId.state'),
          isTrue,
        );
        await alice.send(conv, peerId, 'y');
        await bob.pollNow();
        expect(await texts(bob), ['x', 'y']);
      });
    });

    group('a removed device starts over (C5)', () {
      test('a conflict at registration makes a new identity', () async {
        await alice.send(conv, peerId, 'before');
        await bob.pollNow();
        final old = bob.deviceId;
        bobApi.unknown.add(old);
        bob = await restart(bob, bobApi, bobStore);
        expect(bob.deviceId, isNot(old));
        expect(relay.devices[peerId]!.containsKey(bob.deviceId), isTrue);
        // History is kept, and the new device receives.
        expect(await texts(bob), ['before']);
        await alice.send(conv, peerId, 'after');
        await bob.pollNow();
        expect(await texts(bob), ['before', 'after']);
      });

      test('a device the relay forgot is replaced when polling', () async {
        final old = bob.deviceId;
        bobApi.unknown.add(old);
        await bob.pollNow();
        expect(bob.deviceId, isNot(old));
        expect(relay.devices[peerId]!.containsKey(bob.deviceId), isTrue);
        relay.devices[peerId]!.remove(old);
        await alice.send(conv, peerId, 'new device');
        await bob.pollNow();
        expect(await texts(bob), ['new device']);
      });
    });

    group('removing this device on the server (C2)', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('hiyall_revoke'));
      tearDown(() => tmp.deleteSync(recursive: true));

      test(
        'a removal that could not be sent is retried on the next start',
        () async {
          final old = bob.deviceId;
          // Sign-out while offline.
          await ChatLocalData.wipeAccount(
            root: tmp,
            store: bobStore,
            userId: peerId,
          );
          expect(
            bobStore.values.keys.where(
              (k) => k.startsWith('hiyall.chat.$peerId.'),
            ),
            isEmpty,
          );
          expect(await ChatLocalData.pendingRevoke(bobStore, peerId), old);
          // Signing in again as the same account: the old device is removed.
          bob.dispose();
          bob = await device(peerId, bobApi, bobStore);
          expect(bobApi.revoked, [old]);
          expect(await ChatLocalData.pendingRevoke(bobStore, peerId), isNull);
          expect(bob.deviceId, isNot(old));
        },
      );

      test('a removal that fails again stays pending', () async {
        final old = bob.deviceId;
        await ChatLocalData.wipeAccount(
          root: tmp,
          store: bobStore,
          userId: peerId,
        );
        bobApi.failRevoke = const ChatFailure('NETWORK', 'offline');
        bob.dispose();
        bob = await device(peerId, bobApi, bobStore);
        expect(await ChatLocalData.pendingRevoke(bobStore, peerId), old);
      });

      test(
        'revoking this device uses the account credential and forgets the id',
        () async {
          final id = bob.deviceId;
          await bob.revokeThisDevice();
          expect(bobApi.revoked, [id]);
          expect(
            bobStore.values.containsKey('hiyall.chat.$peerId.deviceId'),
            isFalse,
          );
        },
      );
    });

    group('a device added to an account (C3)', () {
      Future<ChatEngine> tablet() async {
        final api = Api(relay, peerId);
        final e = await device(peerId, api, MemoryChatStore());
        return e;
      }

      test('peers see it in every conversation the next time it is opened', () async {
        const second = '00000000-0000-4000-8000-0000000000c2';
        await alice.send(conv, peerId, 'hi');
        await bob.pollNow();
        await alice.send(second, peerId, 'hi there too');
        final added = await tablet();
        // Alice sends in the first conversation and learns of the device there.
        await alice.send(conv, peerId, 'again');
        var first = await alice.history(conv);
        expect(first.where((m) => m.notice), hasLength(1));
        expect(
          first.firstWhere((m) => m.notice).text,
          'A new device was added to this account.',
        );
        expect(
          first.firstWhere((m) => m.notice).messageId,
          'notice-${added.deviceId}',
        );
        // The second conversation has not heard of it yet...
        expect((await alice.history(second)).where((m) => m.notice), isEmpty);
        // ...until it is opened.
        await alice.showDeviceNotices(second, peerId);
        expect(
          (await alice.history(second)).where((m) => m.notice),
          hasLength(1),
        );
        // Showing again adds nothing, and it is shown once in the first too.
        await alice.showDeviceNotices(second, peerId);
        await alice.showDeviceNotices(conv, peerId);
        expect(
          (await alice.history(second)).where((m) => m.notice),
          hasLength(1),
        );
        first = await alice.history(conv);
        expect(first.where((m) => m.notice), hasLength(1));
      });

      test('the notices survive a restart', () async {
        await alice.send(conv, peerId, 'hi');
        await tablet();
        await alice.send(conv, peerId, 'again');
        alice = await restart(alice, aliceApi, aliceStore);
        await alice.showDeviceNotices(
          '00000000-0000-4000-8000-0000000000c3',
          peerId,
        );
        expect(
          (await alice.history('00000000-0000-4000-8000-0000000000c3'))
              .where((m) => m.notice),
          hasLength(1),
        );
      });

      test(
        'the owner is told about a device added to their own account',
        () async {
          final added = Api(relay, meId);
          final changes = <void>[];
          final sub = alice.ownDeviceChanges.listen(changes.add);
          addTearDown(sub.cancel);
          expect(alice.ownDeviceNotices, isEmpty);
          final second = await device(meId, added, MemoryChatStore());
          await alice.refreshOwnDevices();
          await Future<void>.delayed(Duration.zero);
          expect(alice.ownDeviceNotices.map((n) => n.deviceId), [
            second.deviceId,
          ]);
          expect(changes, hasLength(1));
          // It is remembered across a restart until dismissed.
          alice = await restart(alice, aliceApi, aliceStore);
          expect(alice.ownDeviceNotices, hasLength(1));
          await alice.dismissOwnDeviceNotices();
          expect(alice.ownDeviceNotices, isEmpty);
          alice = await restart(alice, aliceApi, aliceStore);
          expect(alice.ownDeviceNotices, isEmpty);
        },
      );

      test(
        'the device that was just registered is not announced to itself',
        () async {
          final second = await device(
            meId,
            Api(relay, meId),
            MemoryChatStore(),
          );
          expect(second.ownDeviceNotices, isEmpty);
        },
      );
    });

    group('the safety number never pins silently (C3)', () {
      test('a new device is shown as a change and is not pinned', () async {
        await alice.send(conv, peerId, 'hi');
        await bob.pollNow();
        var info = await alice.safetyInfo(peerId);
        expect(info.newDevices, 0);
        expect(info.verified, isFalse);
        await alice.markVerified(peerId, info);
        expect(alice.isVerified(peerId), isTrue);
        expect((await alice.safetyInfo(peerId)).verified, isTrue);

        final trustBefore = aliceStore.values['hiyall.chat.$meId.trust'];
        await device(peerId, Api(relay, peerId), MemoryChatStore());
        info = await alice.safetyInfo(peerId);
        expect(info.newDevices, 1, reason: 'the change is what is shown first');
        expect(info.verified, isFalse);
        expect(info.changedSinceVerified, isTrue);
        expect(info.changed, isTrue);
        expect(alice.isVerified(peerId), isFalse, reason: 'the mark cleared');
        // Looking pinned nothing, wrote no notice and changed the number.
        expect(aliceStore.values['hiyall.chat.$meId.trust'], trustBefore);
        expect((await alice.history(conv)).where((m) => m.notice), isEmpty);
        // The next message pins it, with a notice in the chat.
        await alice.send(conv, peerId, 'again');
        expect(
          (await alice.history(conv)).where((m) => m.notice),
          hasLength(1),
        );
        expect((await alice.safetyInfo(peerId)).newDevices, 0);
        // Verified again, the mark holds.
        final fresh = await alice.safetyInfo(peerId);
        await alice.markVerified(peerId, fresh);
        expect(alice.isVerified(peerId), isTrue);
        expect((await alice.safetyInfo(peerId)).changedSinceVerified, isFalse);
      });

      test(
        'the mark survives a restart and clears when the peer\'s keys change',
        () async {
          await alice.send(conv, peerId, 'hi');
          await bob.pollNow();
          await alice.markVerified(peerId, await alice.safetyInfo(peerId));
          alice = await restart(alice, aliceApi, aliceStore);
          expect(alice.isVerified(peerId), isTrue);
          // The peer's device list changes: a device is removed.
          relay.devices[peerId]!.remove(bob.deviceId);
          await device(peerId, Api(relay, peerId), MemoryChatStore());
          await alice.safetyInfo(peerId);
          expect(alice.isVerified(peerId), isFalse);
        },
      );

      test('one\'s own devices changing clears every mark', () async {
        await alice.send(conv, peerId, 'hi');
        await bob.pollNow();
        await alice.markVerified(peerId, await alice.safetyInfo(peerId));
        await device(meId, Api(relay, meId), MemoryChatStore());
        await alice.refreshOwnDevices();
        expect(alice.isVerified(peerId), isFalse);
      });
    });
  });
}

final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';

String? _coreMissing() {
  if (File(_corePath).existsSync()) return null;
  if (Platform.environment['REQUIRE_RUST_CORE'] == '1') {
    throw StateError('REQUIRE_RUST_CORE=1 but $_corePath is missing');
  }
  return 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
}
