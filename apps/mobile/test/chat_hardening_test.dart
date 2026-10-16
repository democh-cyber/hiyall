import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/push/push_service.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay;
import 'chat_robustness_test.dart' show Api;

// Leftovers of the chat audit: fallback key rotation (F11), size padding
// (F16), outgoing text rules (S9), the version headers and 426 mapping of the
// chat API, and the background pause of the inbox timer.

class CountingApi extends Api {
  CountingApi(super.relay, super.user);
  int inboxCalls = 0;
  @override
  Future<List<Map<String, dynamic>>> inbox(String deviceId) {
    inboxCalls++;
    return super.inbox(deviceId);
  }
}

/// A sender's API that, when a device has no one-time key left, claims the
/// fallback key a test chose to have the relay offer.
class FbApi extends Api {
  FbApi(super.relay, super.user);
  static final offered = <String, Map<String, String>>{};
  @override
  Future<Map<String, dynamic>> claim(String userId, String deviceId) async {
    if (relay.keys[userId]![deviceId]!.isNotEmpty) {
      return super.claim(userId, deviceId);
    }
    return {...offered[deviceId]!, 'fallback': true, 'deviceId': deviceId};
  }
}

/// A Dio adapter that records requests and answers with a fixed status.
class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
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
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('a tap on the new-device push opens the chat devices screen', () {
    final tap = PushTap.fromData({'kind': 'device'})!;
    expect(tap.location, '/profile/devices');
    expect(
      PushTap.fromData({'kind': 'chat', 'conversationId': conv})!.location,
      '/chats/$conv',
    );
    expect(PushTap.fromData({'kind': 'social'})!.location, '/notifications');
  });

  group('the chat API client', () {
    test('sends the version and platform on every request', () async {
      final adapter = _Adapter()
        ..body = {
          'data': {'oneTimeKeyCount': 3},
        };
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
        ..httpClientAdapter = adapter;
      final api = ChatApi(
        'http://127.0.0.1:8080',
        't',
        dio: dio,
        clientVersion: '1.2.3',
        clientPlatform: 'ios',
      );
      await api.keyCount('d');
      await api.devices('u').catchError((_) => <Map<String, dynamic>>[]);
      expect(adapter.requests.length, 2);
      for (final r in adapter.requests) {
        expect(r.headers['X-Client-Version'], '1.2.3');
        expect(r.headers['X-Client-Platform'], 'ios');
        expect(r.headers['Authorization'], 'Bearer t');
      }
    });

    test('without them nothing is sent', () async {
      final adapter = _Adapter()
        ..body = {
          'data': {'oneTimeKeyCount': 3},
        };
      final api = ChatApi(
        'http://127.0.0.1:8080',
        't',
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
          ..httpClientAdapter = adapter,
      );
      await api.keyCount('d');
      expect(
        adapter.requests.single.headers.containsKey('X-Client-Version'),
        isFalse,
      );
    });

    test(
      '426 UPGRADE_REQUIRED calls the blocking-screen hook and fails',
      () async {
        final adapter = _Adapter()
          ..status = 426
          ..body = {
            'error': {'code': 'UPGRADE_REQUIRED', 'message': 'old'},
          };
        var blocked = 0;
        final api = ChatApi(
          'http://127.0.0.1:8080',
          't',
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
            ..httpClientAdapter = adapter,
          onUpgradeRequired: () => blocked++,
        );
        await expectLater(
          api.keyCount('d'),
          throwsA(
            isA<ChatFailure>()
                .having((f) => f.code, 'code', 'UPGRADE_REQUIRED')
                .having((f) => f.status, 'status', 426),
          ),
        );
        expect(blocked, 1);
      },
    );

    test('another 426 or another status does not trip it', () async {
      final adapter = _Adapter()
        ..status = 426
        ..body = {
          'error': {'code': 'SOMETHING', 'message': 'x'},
        };
      var blocked = 0;
      final api = ChatApi(
        'http://127.0.0.1:8080',
        't',
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
          ..httpClientAdapter = adapter,
        onUpgradeRequired: () => blocked++,
      );
      await expectLater(api.keyCount('d'), throwsA(isA<ChatFailure>()));
      expect(blocked, 0);
    });
  });

  group('on a real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await (_core ??= RustLib.init(
        externalLibrary: ExternalLibrary.open(_corePath),
      ));
    });

    late MemoryRelay relay;
    late CountingApi aliceApi;
    late Api bobApi;
    late ChatEngine alice, bob;
    late MemoryChatStore aliceStore;
    var now = DateTime.utc(2026, 10, 14, 12);
    final spare = <ChatEngine>[];

    Future<ChatEngine> device(
      String user,
      Api api,
      MemoryChatStore store, {
      Duration poll = Duration.zero,
    }) async {
      final engine = ChatEngine(
        userId: user,
        api: api,
        store: store,
        platform: 'test',
        reactionRetryDelays: const [Duration.zero, Duration.zero],
        clock: () => now,
      );
      await engine.start(poll: poll);
      spare.add(engine);
      return engine;
    }

    setUp(() async {
      now = DateTime.utc(2026, 10, 14, 12);
      relay = MemoryRelay();
      aliceApi = CountingApi(relay, meId);
      bobApi = Api(relay, peerId);
      aliceStore = MemoryChatStore();
      alice = await device(meId, aliceApi, aliceStore);
      bob = await device(peerId, bobApi, MemoryChatStore());
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

    group('fallback key rotation (F11)', () {
      Future<ChatEngine> newBobDevice() =>
          device(peerId, FbApi(relay, peerId), MemoryChatStore());

      /// Makes the relay hand out [fallback] and nothing else for alice.
      void offerOnly(Map<String, String> fallback) {
        relay.keys[meId]![alice.deviceId]!.clear();
        FbApi.offered[alice.deviceId] = fallback;
      }

      test('the key is replaced every 7 days, not before', () async {
        final first = aliceApi.fallbacks[alice.deviceId]!['keyId'];
        now = now.add(const Duration(days: 6));
        await alice.pollNow();
        expect(aliceApi.fallbacks[alice.deviceId]!['keyId'], first);
        now = now.add(const Duration(days: 2));
        await alice.pollNow();
        expect(aliceApi.fallbacks[alice.deviceId]!['keyId'], isNot(first));
        final second = aliceApi.fallbacks[alice.deviceId]!['keyId'];
        await alice.pollNow(); // not again at once
        expect(aliceApi.fallbacks[alice.deviceId]!['keyId'], second);
      });

      test('the schedule survives a restart', () async {
        now = now.add(const Duration(days: 8));
        await alice.pollNow();
        final rotated = aliceApi.fallbacks[alice.deviceId]!['keyId'];
        alice.dispose();
        final again = await device(meId, aliceApi, aliceStore);
        await again.pollNow();
        expect(aliceApi.fallbacks[again.deviceId]!['keyId'], rotated);
      });

      test('the old key still works during the grace period', () async {
        final old = {...aliceApi.fallbacks[alice.deviceId]!};
        now = now.add(const Duration(days: 8));
        await alice.pollNow();
        expect(
          aliceApi.fallbacks[alice.deviceId]!['keyId'],
          isNot(old['keyId']),
        );
        offerOnly(old); // a peer that fetched the old key just before
        final newcomer = await newBobDevice();
        await newcomer.send(conv, meId, 'made for the old key');
        await alice.pollNow();
        expect(await texts(alice), contains('made for the old key'));
      });

      test('after the grace period the old key is forgotten', () async {
        final old = {...aliceApi.fallbacks[alice.deviceId]!};
        now = now.add(const Duration(days: 8));
        await alice.pollNow();
        now = now.add(const Duration(hours: 25));
        await alice.pollNow(); // the inbox is empty: it is forgotten now
        offerOnly(old);
        final newcomer = await newBobDevice();
        await newcomer.send(conv, meId, 'too late');
        await alice.pollNow();
        expect(await texts(alice), isNot(contains('too late')));
        // The current key still works.
        offerOnly({...aliceApi.fallbacks[alice.deviceId]!});
        final another = await newBobDevice();
        await another.send(conv, meId, 'on time');
        await alice.pollNow();
        expect(await texts(alice), contains('on time'));
      });

      test(
        'it is forgotten only after the inbox was read to the end',
        () async {
          final old = {...aliceApi.fallbacks[alice.deviceId]!};
          now = now.add(const Duration(days: 8));
          await alice.pollNow();
          // Alice is away for two days; a message for the old key waits.
          offerOnly(old);
          final newcomer = await newBobDevice();
          await newcomer.send(conv, meId, 'waited on the relay');
          now = now.add(const Duration(days: 2));
          await alice.pollNow();
          expect(await texts(alice), contains('waited on the relay'));
        },
      );
    });

    test('text payloads are padded to a size bucket (F16)', () async {
      Future<int> sizeOf(String text) async {
        await alice.send(conv, peerId, text);
        return (relay.wire.last['sizes'] as List).first as int;
      }

      final short = await sizeOf('hi');
      final a = await sizeOf('ok see you');
      final b = await sizeOf('sounds good to me');
      expect(a, short);
      expect(b, short, reason: 'both fit the same bucket');
      final long = await sizeOf('x' * 300);
      expect(long, greaterThan(short));
      // The padded messages read back as sent.
      await bob.pollNow();
      expect(await texts(bob), [
        'hi',
        'ok see you',
        'sounds good to me',
        'x' * 300,
      ]);
    });

    test('a payload without a pad still parses, a bad pad does not', () {
      Map<String, dynamic> body([Object? pad = #none]) => {
        'v': 1,
        'kind': 'text',
        'text': 'plain',
        'messageId': 'm1',
        'conversationId': conv,
        'senderId': peerId,
        'sentAt': '2026-10-14T12:00:00Z',
        if (pad != #none) 'pad': pad,
      };
      ChatMessage parse(Map<String, dynamic> b) => messageFromBody(
        b,
        messageId: 'm1',
        conversationId: conv,
        senderId: peerId,
        me: meId,
      );
      expect(parse(body()).text, 'plain');
      expect(parse(body('AAAA')).text, 'plain');
      expect(() => parse(body(5)), throwsA(isA<ChatFailure>()));
      expect(() => parse(body('A' * 20000)), throwsA(isA<ChatFailure>()));
    });

    test('outgoing text follows the API text rules (S9)', () async {
      await alice.send(conv, peerId, 'hi\u200B there\u202E e\u0301');
      await bob.pollNow();
      expect(await texts(alice), ['hi there é']);
      expect(await texts(bob), ['hi there é']);
      await expectLater(
        alice.send(conv, peerId, '\u200B\u202E'),
        throwsA(
          isA<ChatFailure>().having((f) => f.code, 'code', 'INVALID_TEXT'),
        ),
      );
      expect(await texts(alice), ['hi there é'], reason: 'nothing stored');
    });

    test('received text is cleaned, not rejected (S9)', () {
      final message = messageFromBody(
        {
          'v': 1,
          'kind': 'text',
          'text': 'a\u200Bb\u202Ec\u0000dz${'\u0301' * 9}',
          'messageId': 'm1',
          'conversationId': conv,
          'senderId': peerId,
          'sentAt': '2026-10-14T12:00:00Z',
        },
        messageId: 'm1',
        conversationId: conv,
        senderId: peerId,
        me: meId,
      );
      expect(message.text, startsWith('abcd'));
      expect(message.text.runes.length, lessThan(14));
    });

    test(
      'the inbox timer stops in the background and resumes (perf)',
      () async {
        final e = await device(
          meId,
          aliceApi,
          MemoryChatStore(),
          poll: const Duration(milliseconds: 30),
        );
        expect(e.polling, isTrue);
        e.pause();
        expect(e.polling, isFalse);
        final calls = aliceApi.inboxCalls;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(aliceApi.inboxCalls, calls, reason: 'no polling while paused');
        e.setPollInterval(const Duration(milliseconds: 40));
        expect(e.polling, isFalse, reason: 'a new interval does not wake it');
        e.resume();
        expect(e.polling, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(aliceApi.inboxCalls, greaterThan(calls));
        e.resume(); // harmless when running
        e.pause();
        e.pause();
        expect(e.polling, isFalse);
      },
    );
  });
}

Future<void>? _core;
final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';
String? _coreMissing() => File(_corePath).existsSync()
    ? null
    : 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
