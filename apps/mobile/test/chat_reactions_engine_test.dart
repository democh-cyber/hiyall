import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_history.dart';
import 'package:hiyall/core/chat/chat_reactions.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, descriptor, meId, peerId;

const heart = '❤️';
const laugh = '\u{1F602}';
const thumbs = '\u{1F44D}';

String uid(int n) =>
    '5e5e0000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

// ----------------------------------------------------------- the relay

/// The relay's rules that matter here, in memory: exact device sets,
/// idempotency by message id, the `aux` hint (no unread for the peer, and the
/// 2 KiB envelope cap), one-time key claims and per-device inboxes. Nothing in
/// it ever sees plaintext.
class MemoryRelay {
  final devices = <String, Map<String, Map<String, dynamic>>>{};
  final keys = <String, Map<String, List<Map<String, String>>>>{};
  final inboxes = <String, List<Map<String, dynamic>>>{};
  final stored = <String, Map<String, dynamic>>{};

  /// Every send request as the wire saw it (envelopes reduced to sizes).
  final wire = <Map<String, dynamic>>[];
  final unread = <String, int>{};
  final lastBumps = <String>[];
  Object? failNext;
  int clock = 0;

  DateTime tick() => DateTime.utc(2026, 10, 13, 12, 0, clock++);
}

class RelayApi extends ChatApi {
  RelayApi(this.relay, this.user) : super('http://127.0.0.1:1', 't');
  final MemoryRelay relay;
  final String user;

  @override
  Future<void> registerDevice(Map<String, String> d) async =>
      (relay.devices[user] ??= {})[d['deviceId']!] = {...d};
  @override
  Future<int> keyCount(String deviceId) async =>
      relay.keys[user]?[deviceId]?.length ?? 0;
  @override
  Future<int> uploadKeys(
    String deviceId,
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  ) async {
    (relay.keys[user] ??= {})[deviceId] = [...oneTimeKeys];
    return oneTimeKeys.length;
  }

  @override
  Future<List<Map<String, dynamic>>> devices(String userId) async => [
    for (final d in (relay.devices[userId] ?? {}).values) {...d},
  ];
  @override
  Future<Map<String, dynamic>> claim(String userId, String deviceId) async {
    final pool = relay.keys[userId]![deviceId]!;
    return {...pool.removeAt(0), 'fallback': false, 'deviceId': deviceId};
  }

  @override
  Future<DateTime?> send(
    String conversationId,
    Map<String, dynamic> message, {
    List<String> blobIds = const [],
    bool aux = false,
  }) async {
    final id = message['messageId'] as String;
    final envelopes = (message['envelopes'] as List).cast<Map>();
    relay.wire.add({
      'from': user,
      'messageId': id,
      'aux': aux,
      'sizes': [
        for (final e in envelopes) _raw(e['ciphertext'] as String).length,
      ],
    });
    final failure = relay.failNext;
    if (failure != null) {
      relay.failNext = null;
      throw failure;
    }
    final known = relay.stored[id];
    if (known != null) return known['createdAt'] as DateTime;
    final peer = relay.devices.keys.firstWhere((u) => u != user);
    final expected = {
      ...?relay.devices[peer]?.keys,
      for (final d in (relay.devices[user] ?? {}).keys)
        if (d != message['senderDeviceId']) d,
    };
    if (expected.length != envelopes.length ||
        !envelopes.every((e) => expected.contains(e['deviceId']))) {
      throw const ChatFailure('DEVICES_CHANGED', 'device set', 409);
    }
    if (aux) {
      for (final e in envelopes) {
        if (_raw(e['ciphertext'] as String).length > 2048) {
          throw const ChatFailure('TOO_LARGE', 'too big', 413);
        }
      }
    }
    final at = relay.tick();
    relay.stored[id] = {'createdAt': at, 'aux': aux};
    if (!aux) {
      relay.unread[peer] = (relay.unread[peer] ?? 0) + 1;
      relay.lastBumps.add(id);
    }
    final senderIdentity =
        relay.devices[user]![message['senderDeviceId']]!['identityKey'];
    for (final e in envelopes) {
      (relay.inboxes[e['deviceId'] as String] ??= []).add({
        'conversationId': conversationId,
        'senderId': user,
        'messageId': id,
        'senderDeviceId': message['senderDeviceId'],
        'senderIdentityKey': senderIdentity,
        'type': e['type'],
        'ciphertext': e['ciphertext'],
        'createdAt': at.toIso8601String(),
      });
    }
    return at;
  }

  late String deviceOfEngine;
  @override
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async => [
    ...?relay.inboxes[deviceId],
  ];
  @override
  Future<void> ack(String deviceId, List<String> messageIds) async => relay
      .inboxes[deviceId]
      ?.removeWhere((m) => messageIds.contains(m['messageId']));
}

// -------------------------------------------------- history without Olm

ChatMessage text(
  String id, {
  bool mine = false,
  DateTime? at,
  String body = 'hello',
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: body,
  sentAt: at ?? DateTime.utc(2026, 10, 13, 9),
  mine: mine,
);

Map<String, dynamic> reactionBody(
  String messageId, {
  String? to,
  Object? emoji = heart,
  Object? op = 'add',
  String sender = peerId,
  DateTime? at,
  String conversation = conv,
}) => {
  'v': 1,
  'kind': 'reaction',
  'text': '',
  'to': to ?? uid(1),
  'emoji': emoji,
  'op': op,
  'messageId': messageId,
  'conversationId': conversation,
  'senderId': sender,
  'sentAt': (at ?? DateTime.utc(2026, 10, 13, 10)).toIso8601String(),
};

Incoming read(
  Map<String, dynamic> body, {
  required String messageId,
  String sender = peerId,
  DateTime? serverAt,
}) => parseIncoming(
  body,
  messageId: messageId,
  conversationId: conv,
  senderId: sender,
  me: meId,
  serverAt: serverAt,
);

Future<bool> react(
  ChatHistory h,
  String target,
  String sender,
  String? emoji,
  DateTime at,
  String id,
) => h.applyReaction(
  conv,
  ReactionEvent(
    target: target,
    sender: sender,
    state: ReactionState(emoji: emoji, at: at, id: id),
  ),
);

Future<Map<String, String>> reactionsOf(ChatHistory h, String id) async =>
    (await h.read(conv)).firstWhere((m) => m.messageId == id).reactions;

void main() {
  group('reaction payloads', () {
    test('a valid reaction parses with its sender and ordering key', () {
      final i = read(reactionBody(uid(9)), messageId: uid(9));
      expect(i, isA<IncomingReaction>());
      final e = (i as IncomingReaction).event;
      expect(e.target, uid(1));
      expect(e.sender, peerId);
      expect(e.state.emoji, heart);
      expect(e.state.id, uid(9));
      final removed = read(
        reactionBody(uid(9), op: 'remove'),
        messageId: uid(9),
      );
      expect((removed as IncomingReaction).event.state.emoji, isNull);
    });

    test('only the six allow-listed strings are accepted, exactly', () {
      for (final ok in reactionEmojis) {
        expect(
          read(reactionBody(uid(9), emoji: ok), messageId: uid(9)),
          isA<IncomingReaction>(),
          reason: ok,
        );
      }
      for (final bad in <Object?>[
        '❤', // heart without the variation selector
        '\u{1F44D}\u{1F3FD}', // thumbs up with a skin tone
        '\u{1F602}\u{1F602}',
        '😀',
        '',
        ' $heart',
        '$heart ',
        'heart',
        '❤️❤️',
        null,
        1,
        ['x'],
      ]) {
        expect(
          read(reactionBody(uid(9), emoji: bad), messageId: uid(9)),
          isA<IncomingIgnored>(),
          reason: '$bad',
        );
      }
    });

    test('a bad op, target, or date is ignored, never an error or a row', () {
      for (final body in [
        reactionBody(uid(9), op: 'toggle'),
        reactionBody(uid(9), op: null),
        reactionBody(uid(9), to: 'not-a-uuid'),
        reactionBody(uid(9), to: uid(1).toUpperCase()),
        {...reactionBody(uid(9)), 'to': 5},
        {...reactionBody(uid(9)), 'sentAt': 'yesterday'},
        {...reactionBody(uid(9))}..remove('sentAt'),
      ]) {
        expect(read(body, messageId: uid(9)), isA<IncomingIgnored>());
      }
    });

    test('the relay metadata binding still rejects a replayed reaction', () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (b) => b['senderId'] = meId,
        (b) => b['conversationId'] = 'other',
        (b) => b['messageId'] = uid(10),
        (b) => b['v'] = 2,
        (b) => b.remove('text'),
      ]) {
        final b = reactionBody(uid(9));
        change(b);
        expect(
          () => read(b, messageId: uid(9)),
          throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'MISMATCH')),
        );
      }
    });

    test('a reaction dated well after the relay stored it is ignored', () {
      final at = DateTime.utc(2026, 10, 13, 10);
      expect(
        read(
          reactionBody(uid(9), at: at.add(const Duration(days: 400))),
          messageId: uid(9),
          serverAt: at,
        ),
        isA<IncomingIgnored>(),
      );
      expect(
        read(
          reactionBody(uid(9), at: at.add(const Duration(minutes: 5))),
          messageId: uid(9),
          serverAt: at,
        ),
        isA<IncomingReaction>(),
      );
    });

    test(
      'unknown kinds from newer apps are ignored; old payloads still read',
      () {
        final body = {
          'v': 1,
          'kind': 'poll',
          'text': 'Vote!',
          'messageId': uid(9),
          'conversationId': conv,
          'senderId': peerId,
          'sentAt': '2026-10-13T10:00:00Z',
        };
        expect(read(body, messageId: uid(9)), isA<IncomingIgnored>());
        // No kind at all is a text message, as the first builds wrote them.
        final old = {...body}..remove('kind');
        expect(read(old, messageId: uid(9)), isA<IncomingMessage>());
        // A reaction is never a message.
        expect(
          () => messageFromBody(
            reactionBody(uid(9)),
            messageId: uid(9),
            conversationId: conv,
            senderId: peerId,
            me: meId,
          ),
          throwsA(isA<ChatFailure>()),
        );
      },
    );
  });

  group('reply payloads', () {
    Map<String, dynamic> textBody({Object? re, String kind = 'text'}) => {
      'v': 1,
      'kind': kind,
      'text': 'sure',
      'messageId': uid(20),
      'conversationId': conv,
      'senderId': peerId,
      'sentAt': '2026-10-13T10:00:00Z',
      're': ?re,
      if (kind == 'image') 'att': descriptor(),
    };
    Map<String, dynamic> re({
      Object? id,
      Object? by,
      Object? snip = 'are you coming?',
      Object? k = 'text',
    }) => {'id': id ?? uid(1), 'by': by ?? meId, 'snip': snip, 'k': k};
    ChatMessage parsed(Map<String, dynamic> b) =>
        (read(b, messageId: uid(20)) as IncomingMessage).message;

    test('a valid quote rides on text and image messages', () {
      for (final kind in ['text', 'image']) {
        final m = parsed(textBody(re: re(), kind: kind));
        expect(m.reply?.id, uid(1), reason: kind);
        expect(m.reply?.by, meId);
        expect(m.reply?.snippet, 'are you coming?');
        expect(m.reply?.kind, 'text');
      }
      final image = parsed(
        textBody(
          re: re(k: 'image', snip: ''),
        ),
      );
      expect(image.reply?.isImage, isTrue);
      expect(image.reply?.snippet, '');
    });

    test('every malformed quote is dropped and the message still shows', () {
      final cases = <String, Object?>{
        'id not a uuid': re(id: 'abc'),
        'id upper case': re(id: uid(1).toUpperCase()),
        'by not a uuid': re(by: 'me'),
        'by a stranger': re(by: uid(77)),
        'snippet too long': re(snip: 'x' * 121),
        'snippet newline': re(snip: 'a\nb'),
        'snippet control': re(snip: 'a\u0007b'),
        'snippet bidi override': re(snip: 'a\u202Eb'),
        'snippet not text': re(snip: 5),
        'kind unknown': re(k: 'video'),
        'kind missing': re(k: null),
        'not a map': 'quote',
        'a list': [1, 2],
      };
      cases.forEach((name, value) {
        final m = parsed(textBody(re: value));
        expect(m.reply, isNull, reason: name);
        expect(m.text, 'sure', reason: name);
      });
      // The limit is 120 code points, inclusive.
      expect(parsed(textBody(re: re(snip: 'x' * 120))).reply, isNotNull);
      expect(parsed(textBody(re: re(snip: '😀' * 120))).reply, isNotNull);
      expect(parsed(textBody(re: re(snip: '😀' * 121))).reply, isNull);
    });

    test('a quote on a reaction is not read', () {
      final body = {...reactionBody(uid(9)), 're': re()};
      expect(read(body, messageId: uid(9)), isA<IncomingReaction>());
    });

    test('the snippet a reply builds is plain, one line and cut', () {
      expect(snippetOf('  hello \n\n  there\t you '), 'hello there you');
      expect(snippetOf('a\u202Eb'), 'a b');
      expect(snippetOf('x' * 500).runes.length, maxReplySnippet);
      expect(snippetOf('x' * 500).endsWith('…'), isTrue);
      expect(isPlainSnippet(snippetOf('x' * 500)), isTrue);
      // Never ends in half an emoji.
      expect(
        snippetOf('${'a' * 118}\u{1F468}‍\u{1F469}'),
        isNot(contains('‍')),
      );
    });

    test(
      'a quote never nests: replyOf quotes only the message\'s own text',
      () {
        final inner = text(uid(2), body: 'original');
        final reply = text(
          uid(3),
          mine: true,
          body: 'my answer',
        ).copyWith(reply: replyOf(inner, meId));
        final quoted = replyOf(reply, meId)!;
        expect(quoted.snippet, 'my answer');
        expect(quoted.by, meId);
        expect(quoted.toJson().keys.toSet(), {'id', 'by', 'snip', 'k'});
      },
    );

    test('the local original wins over what the sender wrote', () {
      final original = text(uid(1), mine: true, body: 'the real words');
      final claimed = ChatReply(
        id: uid(1),
        by: peerId,
        snippet: 'something I never said',
        kind: 'image',
      );
      final fixed = resolveReply(claimed, original, meId);
      expect(fixed.snippet, 'the real words');
      expect(fixed.by, meId);
      expect(fixed.kind, 'text');
    });
  });

  group('last writer wins', () {
    late ChatHistory h;
    final t0 = DateTime.utc(2026, 10, 13, 10);
    setUp(() async {
      h = ChatHistory(MemoryChatStore(), (id) => 'h:$id');
      await h.append(conv, text(uid(1)));
    });

    test('add, replace, remove', () async {
      await react(h, uid(1), peerId, heart, t0, uid(50));
      expect(await reactionsOf(h, uid(1)), {peerId: heart});
      await react(
        h,
        uid(1),
        peerId,
        laugh,
        t0.add(const Duration(seconds: 1)),
        uid(51),
      );
      expect(await reactionsOf(h, uid(1)), {peerId: laugh});
      await react(h, uid(1), meId, thumbs, t0, uid(52));
      expect(await reactionsOf(h, uid(1)), {peerId: laugh, meId: thumbs});
      await react(
        h,
        uid(1),
        peerId,
        null,
        t0.add(const Duration(seconds: 2)),
        uid(53),
      );
      expect(await reactionsOf(h, uid(1)), {meId: thumbs});
    });

    test('reordering cannot resurrect a removed reaction', () async {
      // Arrival order: remove, then the older add, then an even older add.
      await react(
        h,
        uid(1),
        peerId,
        null,
        t0.add(const Duration(seconds: 5)),
        uid(60),
      );
      await react(
        h,
        uid(1),
        peerId,
        heart,
        t0.add(const Duration(seconds: 1)),
        uid(61),
      );
      await react(h, uid(1), peerId, laugh, t0, uid(62));
      expect(await reactionsOf(h, uid(1)), isEmpty);
      // A genuinely newer add works again.
      await react(
        h,
        uid(1),
        peerId,
        thumbs,
        t0.add(const Duration(seconds: 9)),
        uid(63),
      );
      expect(await reactionsOf(h, uid(1)), {peerId: thumbs});
    });

    test(
      'an equal time is broken by message id, in any arrival order',
      () async {
        final a = ChatHistory(MemoryChatStore(), (id) => 'a:$id');
        final b = ChatHistory(MemoryChatStore(), (id) => 'b:$id');
        for (final x in [a, b]) {
          await x.append(conv, text(uid(1)));
        }
        await react(a, uid(1), peerId, heart, t0, uid(70));
        await react(a, uid(1), peerId, laugh, t0, uid(71));
        await react(b, uid(1), peerId, laugh, t0, uid(71));
        await react(b, uid(1), peerId, heart, t0, uid(70));
        expect(await reactionsOf(a, uid(1)), {peerId: laugh});
        expect(await reactionsOf(b, uid(1)), {peerId: laugh});
      },
    );

    test('a replayed event changes nothing', () async {
      await react(h, uid(1), peerId, heart, t0, uid(80));
      await react(h, uid(1), peerId, heart, t0, uid(80));
      expect((await h.read(conv)).single.reactions, {peerId: heart});
    });

    test(
      'a reaction never creates a message row or counts as unread',
      () async {
        await react(h, uid(1), peerId, heart, t0, uid(90));
        final all = await h.read(conv);
        expect(all, hasLength(1));
        final changes = <String>[];
        final watched = ChatHistory(
          MemoryChatStore(),
          (id) => 'w:$id',
          onChange: changes.add,
        );
        await watched.append(conv, text(uid(1)));
        expect(changes, hasLength(1));
        await react(watched, uid(1), peerId, heart, t0, uid(91));
        expect((await watched.read(conv)).where((m) => !m.mine), hasLength(1));
      },
    );
  });

  group('reactions waiting for their message', () {
    final t0 = DateTime.utc(2026, 10, 13, 10);
    var now = DateTime.utc(2026, 10, 13, 12);
    late MemoryChatStore store;
    late ChatHistory h;
    ChatHistory open() => ChatHistory(store, (id) => 'h:$id', clock: () => now);
    setUp(() {
      now = DateTime.utc(2026, 10, 13, 12);
      store = MemoryChatStore();
      h = open();
    });

    test('is applied when the target arrives, and then forgotten', () async {
      expect(await react(h, uid(1), peerId, heart, t0, uid(40)), isFalse);
      expect(await h.pendingReactionCount(conv), 1);
      await h.append(conv, text(uid(1)));
      expect(await reactionsOf(h, uid(1)), {peerId: heart});
      expect(await h.pendingReactionCount(conv), 0);
      expect(store.values.keys.where((k) => k.endsWith('.reactions')), isEmpty);
    });

    test(
      'survives a restart and keeps last-writer-wins while waiting',
      () async {
        await react(h, uid(1), peerId, laugh, t0, uid(41));
        await react(
          h,
          uid(1),
          peerId,
          null,
          t0.add(const Duration(seconds: 3)),
          uid(42),
        );
        await react(
          h,
          uid(1),
          peerId,
          heart,
          t0.add(const Duration(seconds: 1)),
          uid(43),
        );
        final again = open();
        await again.append(conv, text(uid(1)));
        expect(await reactionsOf(again, uid(1)), isEmpty);
      },
    );

    test('is dropped after seven days', () async {
      await react(h, uid(1), peerId, heart, t0, uid(44));
      now = now.add(const Duration(days: 7, minutes: 1));
      final later = open();
      await later.append(conv, text(uid(1)));
      expect(await reactionsOf(later, uid(1)), isEmpty);
      // Inside the window it is kept.
      now = DateTime.utc(2026, 10, 13, 12);
      final fresh = ChatHistory(
        MemoryChatStore(),
        (id) => 'x:$id',
        clock: () => now,
      );
      await react(fresh, uid(2), peerId, heart, t0, uid(45));
      now = now.add(const Duration(days: 6, hours: 23));
      await fresh.append(conv, text(uid(2)));
      expect(await reactionsOf(fresh, uid(2)), {peerId: heart});
    });

    test('is capped at 200 targets, oldest arrivals dropped first', () async {
      for (var i = 0; i < 205; i++) {
        now = DateTime.utc(2026, 10, 13, 12).add(Duration(seconds: i));
        await react(h, uid(1000 + i), peerId, heart, t0, uid(2000 + i));
      }
      expect(await h.pendingReactionCount(conv), pendingReactionCap);
      await h.append(conv, text(uid(1000))); // the oldest: dropped
      await h.append(conv, text(uid(1204))); // the newest: kept
      expect(await reactionsOf(h, uid(1000)), isEmpty);
      expect(await reactionsOf(h, uid(1204)), {peerId: heart});
    });

    test('a notice row is never a target', () async {
      await h.append(
        conv,
        ChatMessage(
          messageId: 'notice-x',
          senderId: peerId,
          text: 'A new device was added to this account.',
          sentAt: t0,
          mine: false,
          notice: true,
        ),
      );
      expect(await react(h, 'notice-x', peerId, heart, t0, uid(46)), isFalse);
    });
  });

  group('history storage', () {
    test('history written before reactions and replies still loads', () {
      final old = {
        'id': uid(1),
        'from': peerId,
        'text': 'hi',
        'at': '2026-10-12T10:00:00.000Z',
        'mine': false,
        'notice': false,
      };
      final m = ChatMessage.fromJson(old);
      expect(m.reactions, isEmpty);
      expect(m.reply, isNull);
      expect(m.toJson().containsKey('rx'), isFalse);
      expect(m.toJson().containsKey('re'), isFalse);
    });

    test('reactions and a quote survive the JSON and a restart', () async {
      final store = MemoryChatStore();
      final h = ChatHistory(store, (id) => 'h:$id');
      final reply = ChatReply(
        id: uid(1),
        by: meId,
        snippet: 'hello',
        kind: 'text',
      );
      await h.append(conv, text(uid(2), body: 'hi').copyWith(reply: reply));
      await react(h, uid(2), peerId, heart, DateTime.utc(2026), uid(3));
      await react(h, uid(2), meId, laugh, DateTime.utc(2026), uid(4));
      await react(h, uid(2), meId, null, DateTime.utc(2027), uid(5));
      final read = (await ChatHistory(store, (id) => 'h:$id').read(conv))
          .single;
      expect(read.reactions, {peerId: heart});
      expect(read.reactionStates[meId]!.emoji, isNull); // the removal is kept
      expect(read.reply?.snippet, 'hello');
      expect(read.reply?.by, meId);
    });

    test('a damaged stored entry is skipped, not fatal', () {
      final m = ChatMessage.fromJson({
        'id': uid(1),
        'from': peerId,
        'text': 'hi',
        'at': '2026-10-12T10:00:00.000Z',
        'mine': false,
        're': {'id': 'x'},
        'rx': {
          peerId: {
            'e': 'not allowed',
            'at': '2026-10-12T10:00:00Z',
            'id': uid(2),
          },
          meId: 'junk',
        },
      });
      expect(m.reply, isNull);
      expect(m.reactionStates, isEmpty);
    });

    test('the 500 message cap applies with reactions attached', () async {
      final h = ChatHistory(MemoryChatStore(), (id) => 'h:$id');
      for (var i = 0; i < 505; i++) {
        await h.append(
          conv,
          text(
            uid(i + 1),
            at: DateTime.utc(2026, 10, 13).add(Duration(minutes: i)),
          ),
        );
      }
      await react(h, uid(505), peerId, heart, DateTime.utc(2026), uid(9000));
      final all = await h.read(conv);
      expect(all, hasLength(ChatHistory.limit));
      expect(all.last.reactions, {peerId: heart});
    });

    test('a reaction to an image keeps the photo and its quote', () async {
      final h = ChatHistory(MemoryChatStore(), (id) => 'h:$id');
      final att = ChatAttachment.parse(descriptor());
      await h.append(
        conv,
        ChatMessage(
          messageId: uid(1),
          senderId: peerId,
          text: photoFallbackText,
          sentAt: DateTime.utc(2026, 10, 13),
          mine: false,
          attachment: att,
        ),
      );
      await react(
        h,
        uid(1),
        meId,
        heart,
        DateTime.utc(2026, 10, 13, 1),
        uid(2),
      );
      final m = (await h.read(conv)).single;
      expect(m.attachment, isNotNull);
      expect(m.reactions, {meId: heart});
      expect(replyOf(m, meId)!.kind, 'image');
      expect(replyOf(m, meId)!.snippet, 'hello'); // the caption
    });
  });

  group('two devices over the real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_corePath));
    });

    var clockTick = 0;
    late MemoryRelay relay;
    late ChatEngine alice, bob;
    late RelayApi aliceApi, bobApi;

    Future<ChatEngine> device(
      String user,
      MemoryRelay relay,
      RelayApi api,
    ) async {
      final e = ChatEngine(
        userId: user,
        api: api,
        store: MemoryChatStore(),
        platform: 'test',
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        // Not DateTime.now(): the relay stamps messages with fixed 2026-10-13 times and the engine drops a
        // reaction dated more than ten minutes after that, so a wall clock made these tests date-dependent.
        clock: () => DateTime.utc(2026, 10, 13, 12, 0, 0, 0, clockTick++ * 10),
      );
      await e.start(poll: Duration.zero);
      return e;
    }

    setUp(() async {
      relay = MemoryRelay();
      aliceApi = RelayApi(relay, meId);
      bobApi = RelayApi(relay, peerId);
      alice = await device(meId, relay, aliceApi);
      bob = await device(peerId, relay, bobApi);
    });
    tearDown(() {
      alice.dispose();
      bob.dispose();
    });

    Future<ChatMessage> sendText(
      ChatEngine from,
      ChatEngine to,
      String body,
    ) async {
      final peer = identical(from, alice) ? peerId : meId;
      await from.send(conv, peer, body);
      await to.pollNow();
      final mine = (await from.history(conv)).last;
      return mine;
    }

    test('a text round trip works (the harness is sound)', () async {
      await sendText(alice, bob, 'hi bob');
      final seen = await bob.history(conv);
      expect(seen.single.text, 'hi bob');
      expect(seen.single.mine, isFalse);
      expect(relay.wire.single['aux'], isFalse);
    });

    test(
      'a reaction reaches the peer, with the aux hint, and is no message',
      () async {
        final sent = await sendText(alice, bob, 'good morning');
        final unreadBefore = relay.unread[meId] ?? 0;
        await bob.react(conv, meId, sent.messageId, heart);
        // Optimistic on Bob's own device at once.
        expect((await bob.history(conv)).single.reactions, {peerId: heart});

        await alice.pollNow();
        final history = await alice.history(conv);
        expect(history, hasLength(1), reason: 'a reaction is not a bubble');
        expect(history.single.reactions, {peerId: heart});
        expect(history.single.text, 'good morning');
        // The relay saw the hint on the reaction only, and no unread for Alice.
        expect(relay.wire.map((w) => w['aux']), [false, true]);
        expect(relay.unread[meId] ?? 0, unreadBefore);
        // The reaction's envelope is far below the relay's 2 KiB cap.
        final size = (relay.wire.last['sizes'] as List).cast<int>().reduce(
          (a, b) => a > b ? a : b,
        );
        expect(size, lessThan(1024));
      },
    );

    test('replace, remove and the peer reacting to your own message', () async {
      final sent = await sendText(alice, bob, 'one');
      await bob.react(conv, meId, sent.messageId, heart);
      await bob.react(conv, meId, sent.messageId, laugh);
      await alice.react(conv, peerId, sent.messageId, thumbs);
      await alice.pollNow();
      await bob.pollNow();
      for (final e in [alice, bob]) {
        expect((await e.history(conv)).single.reactions, {
          peerId: laugh,
          meId: thumbs,
        }, reason: e.userId);
      }
      await bob.react(conv, meId, sent.messageId, null);
      await alice.pollNow();
      expect((await alice.history(conv)).single.reactions, {meId: thumbs});
      // Removing what is not there changes nothing and sends nothing.
      final wires = relay.wire.length;
      await bob.react(conv, meId, sent.messageId, null);
      expect(relay.wire.length, wires);
    });

    test(
      'a failed reaction is rolled back, and a transient one retried',
      () async {
        final sent = await sendText(alice, bob, 'two');
        relay.failNext = const ChatFailure('NETWORK', 'offline');
        final wires = relay.wire.length;
        await bob.react(
          conv,
          meId,
          sent.messageId,
          heart,
        ); // the retry succeeds
        expect(relay.wire.length, wires + 2);
        expect(relay.wire.last['messageId'], relay.wire[wires]['messageId']);
        expect((await bob.history(conv)).single.reactions, {peerId: heart});

        // A final failure takes the reaction back and says why.
        relay.failNext = const ChatFailure('MESSAGES_NOT_ALLOWED', 'no', 403);
        await expectLater(
          bob.react(conv, meId, sent.messageId, laugh),
          throwsA(isA<ChatFailure>()),
        );
        expect((await bob.history(conv)).single.reactions, {peerId: heart});
        relay.failNext = const ChatFailure('MESSAGES_NOT_ALLOWED', 'no', 403);
        await expectLater(
          bob.react(conv, meId, sent.messageId, null),
          throwsA(isA<ChatFailure>()),
        );
        expect((await bob.history(conv)).single.reactions, {peerId: heart});
      },
    );

    test(
      'a resend of the same reaction id is idempotent on the relay',
      () async {
        final sent = await sendText(alice, bob, 'three');
        relay.failNext = const ChatFailure('NETWORK', 'lost reply');
        await bob.react(conv, meId, sent.messageId, heart);
        final ids = relay.wire
            .where((w) => w['aux'] == true)
            .map((w) => w['messageId'])
            .toSet();
        expect(ids, hasLength(1));
        await alice.pollNow();
        expect((await alice.history(conv)).single.reactions, {peerId: heart});
      },
    );

    test(
      'only allow-listed reactions on delivered messages can be sent',
      () async {
        final sent = await sendText(alice, bob, 'four');
        for (final bad in ['😀', '❤', '']) {
          await expectLater(
            bob.react(conv, meId, sent.messageId, bad),
            throwsA(
              isA<ChatFailure>().having((e) => e.code, 'code', 'BAD_REACTION'),
            ),
          );
        }
        await expectLater(
          bob.react(conv, meId, uid(404), heart),
          throwsA(isA<ChatFailure>()),
        );
        expect(relay.wire.where((w) => w['aux'] == true), isEmpty);
      },
    );

    test('a reply carries a quote of the original, and quotes never nest', () async {
      final original = await sendText(
        alice,
        bob,
        'are we still on for friday?',
      );
      final bobsOriginal = (await bob.history(conv)).single;
      await bob.send(conv, meId, 'yes!', replyTo: bobsOriginal);
      await alice.pollNow();
      final reply = (await alice.history(conv)).last;
      expect(reply.text, 'yes!');
      expect(reply.reply?.id, original.messageId);
      expect(reply.reply?.snippet, 'are we still on for friday?');
      expect(reply.reply?.by, meId); // Alice wrote the original
      expect(reply.reply?.kind, 'text');
      // Alice answers the reply: the quote is of "yes!", not of what it quoted.
      await alice.send(conv, peerId, 'great', replyTo: reply);
      await bob.pollNow();
      final second = (await bob.history(conv)).last;
      expect(second.reply?.snippet, 'yes!');
      expect(second.reply?.by, peerId);
      // A reply is an ordinary message for the relay: not aux.
      expect(relay.wire.where((w) => w['aux'] == true), isEmpty);
    });

    test(
      'a reaction that overtakes its message on another device waits',
      () async {
        final tablet = await device(meId, relay, RelayApi(relay, meId));
        addTearDown(tablet.dispose);
        final sent = await sendText(alice, bob, 'late arrival');
        await bob.react(conv, meId, sent.messageId, heart);
        // The tablet's inbox hands over the reaction before the message.
        final inbox = relay.inboxes[tablet.deviceId]!;
        expect(inbox, hasLength(2));
        relay.inboxes[tablet.deviceId] = inbox.reversed.toList();
        await tablet.pollNow();
        final history = await tablet.history(conv);
        expect(history, hasLength(1));
        expect(history.single.text, 'late arrival');
        expect(history.single.reactions, {peerId: heart});
      },
    );

    test('a reaction from your own other device reaches this one', () async {
      // Alice has a second device; the relay hands her phone a copy.
      final tablet = await device(meId, relay, RelayApi(relay, meId));
      addTearDown(tablet.dispose);
      final sent = await sendText(alice, bob, 'for both of my devices');
      await tablet.pollNow();
      expect((await tablet.history(conv)).single.messageId, sent.messageId);
      await tablet.react(conv, peerId, sent.messageId, thumbs);
      await alice.pollNow();
      expect((await alice.history(conv)).single.reactions, {meId: thumbs});
      await bob.pollNow();
      expect((await bob.history(conv)).single.reactions, {meId: thumbs});
    });
  });
}

/// The debug Rust core for the host: `.dylib` on macOS, `.so` on Linux (CI).
final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';

/// Skips the real-Olm group when the core is not built locally. CI builds it
/// first and sets REQUIRE_RUST_CORE=1, so a missing library fails there
/// instead of silently skipping.
String? _coreMissing() {
  if (File(_corePath).existsSync()) return null;
  if (Platform.environment['REQUIRE_RUST_CORE'] == '1') {
    throw StateError('REQUIRE_RUST_CORE=1 but $_corePath is missing');
  }
  return 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
}

/// The relay's ciphertext is unpadded base64; this is its decoded length source.
List<int> _raw(String text) => base64Decode(base64.normalize(text));
