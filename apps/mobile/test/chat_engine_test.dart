import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_store.dart';

const me = '019a4000-0000-7000-8000-000000000001';
const peer = '019a4000-0000-7000-8000-000000000002';

/// A relay with pending envelopes whose sender's device list can't be read.
class RelayFake extends ChatApi {
  RelayFake(this.failure) : super('http://127.0.0.1:8080', 't');
  final ChatFailure failure;
  int deviceReads = 0;
  final acked = <String>[];
  @override
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async => [
    for (final id in ['m1', 'm2'])
      {
        'conversationId': 'c1',
        'senderId': peer,
        'messageId': id,
        'senderDeviceId': 'd1',
        'senderIdentityKey': 'k',
        'type': 1,
        'ciphertext': 'x',
      },
  ];
  @override
  Future<List<Map<String, dynamic>>> devices(String userId) async {
    deviceReads++;
    throw failure;
  }

  @override
  Future<void> ack(String deviceId, List<String> messageIds) async =>
      acked.addAll(messageIds);
  @override
  Future<int> keyCount(String deviceId) async => 100;
}

void main() {
  test('Transient relay failures are retried later', () {
    for (final f in [
      const ChatFailure('NETWORK', 'offline'),
      const ChatFailure('RATE_LIMITED', 'slow down', 429),
      const ChatFailure('INTERNAL', 'oops', 503),
      const ChatFailure('UNAUTHENTICATED', 'expired', 401),
    ]) {
      expect(isTransientChatFailure(f), isTrue, reason: f.code);
    }
    for (final f in [
      const ChatFailure('KEY_CHANGED', 'changed'),
      const ChatFailure('NOT_FOUND', 'gone', 404),
      Exception('bad'),
    ]) {
      expect(isTransientChatFailure(f), isFalse, reason: '$f');
    }
  });

  for (final failure in [
    const ChatFailure('NETWORK', 'offline'),
    const ChatFailure('RATE_LIMITED', 'slow down', 429),
    const ChatFailure('INTERNAL', 'oops', 502),
  ]) {
    test(
      'A ${failure.code} while reading devices keeps messages on the relay',
      () async {
        final api = RelayFake(failure);
        final engine = ChatEngine(
          userId: me,
          api: api,
          store: MemoryChatStore(),
        )..debugStartWithoutKeys('mine');
        addTearDown(engine.dispose);
        await expectLater(engine.pollNow(), throwsA(failure));
        expect(api.acked, isEmpty);
        expect(await engine.history('c1'), isEmpty);
        expect(api.deviceReads, 1);
      },
    );
  }

  test(
    'A sender that is really gone fails once per page and is acked',
    () async {
      final api = RelayFake(const ChatFailure('NOT_FOUND', 'gone', 404));
      final engine = ChatEngine(userId: me, api: api, store: MemoryChatStore())
        ..debugStartWithoutKeys('mine');
      addTearDown(engine.dispose);
      await engine.pollNow();
      expect(api.deviceReads, 1);
      expect(api.acked, ['m1', 'm2']);
      final history = await engine.history('c1');
      expect(history, hasLength(2));
      expect(history.every((m) => m.notice), isTrue);
    },
  );
}
