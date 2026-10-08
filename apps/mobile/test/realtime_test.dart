import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/core/chat/chat_engine.dart';
import 'package:kairova/core/realtime/realtime_client.dart';
import 'package:kairova/core/realtime/socket.dart';

class FakeSocket implements RealtimeSocket {
  final incoming = StreamController<String>();
  final sent = <String>[];
  bool closed = false;
  @override
  Stream<String> get messages => incoming.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

void main() {
  test('Safety numbers match on both sides and change with any device', () {
    const a = '019a4000-0000-7000-8000-000000000001';
    const b = '019a4000-0000-7000-8000-000000000002';
    final aKeys = ['keyA1', 'keyA2'], bKeys = ['keyB1'];
    final fromA = computeSafetyNumber(a, aKeys, b, bKeys);
    final fromB = computeSafetyNumber(b, bKeys, a, aKeys.reversed.toList());
    expect(fromA, fromB);
    expect(fromA, matches(RegExp(r'^\d{60}$')));
    expect(computeSafetyNumber(a, [...aKeys, 'keyA3'], b, bKeys), isNot(fromA));
    expect(computeSafetyNumber(a, aKeys, b, ['keyB2']), isNot(fromA));
  });

  test('Socket URL follows the API scheme and path', () {
    expect(
      RealtimeClient('http://127.0.0.1:8080', 't').url.toString(),
      'ws://127.0.0.1:8080/v1/realtime',
    );
    expect(
      RealtimeClient('https://api.example.com/', 't').url.toString(),
      'wss://api.example.com/v1/realtime',
    );
  });

  test('Client parses signals, reconnects after a drop and stops cleanly', () {
    fakeAsync((async) {
      final sockets = <FakeSocket>[];
      var attempts = 0;
      final client = RealtimeClient(
        'http://127.0.0.1:8080',
        'token',
        connect: (url, token) async {
          attempts++;
          expect(token, 'token');
          if (attempts == 2) throw Exception('refused');
          final s = FakeSocket();
          sockets.add(s);
          return s;
        },
      );
      final events = <String>[];
      client.events.listen(
        (e) => events.add('${e.type}:${e.data['conversationId'] ?? ''}'),
      );
      client.start();
      async.flushMicrotasks();
      expect(client.connected.value, isTrue);
      sockets.single.incoming.add(jsonEncode({'type': 'ready'}));
      sockets.single.incoming.add('not json');
      sockets.single.incoming.add(
        jsonEncode({
          'type': 'inbox',
          'data': {'conversationId': 'c1'},
        }),
      );
      client.sendTyping('c1');
      async.flushMicrotasks();
      expect(events, ['ready:', 'inbox:c1']);
      expect(jsonDecode(sockets.single.sent.single), {
        'type': 'typing',
        'conversationId': 'c1',
      });

      // Drop: one failed retry, then a successful one, with backoff between.
      sockets.single.incoming.close();
      async.flushMicrotasks();
      expect(client.connected.value, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(attempts, 2);
      async.elapse(const Duration(seconds: 2));
      expect(attempts, 3);
      expect(client.connected.value, isTrue);

      client.stop();
      expect(sockets.last.closed, isTrue);
      async.elapse(const Duration(minutes: 1));
      expect(attempts, 3);
      client.dispose();
    });
  });
}
