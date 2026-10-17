import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/realtime/realtime_client.dart';
import 'package:hiyall/core/realtime/socket.dart';

class FakeSocket implements RealtimeSocket {
  final incoming = StreamController<String>();
  final sent = <String>[];
  bool closed = false;
  @override
  int? closeCode;

  /// The server closes the socket with [code].
  void serverClose(int code) {
    closeCode = code;
    incoming.close();
  }

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

  test(
    'The socket never opens, and no token is sent, over a plain http address',
    () {
      fakeAsync((async) {
        var connects = 0;
        Future<RealtimeSocket> connect(Uri url, String token) async {
          connects++;
          throw StateError('should not connect');
        }

        final insecure = RealtimeClient(
          'http://api.example.test',
          'secret-token',
          connect: connect,
          debugBuild: true,
        )..start();
        // A release build refuses even this machine's own http.
        final release = RealtimeClient(
          'http://127.0.0.1:8080',
          'secret-token',
          connect: connect,
          debugBuild: false,
        )..start();
        async.elapse(const Duration(minutes: 2));
        expect(connects, 0);
        insecure.dispose();
        release.dispose();

        // https and this machine's http in a debug build are allowed.
        final ok = RealtimeClient(
          'https://api.example.test',
          't',
          connect: connect,
          debugBuild: false,
        )..start();
        final local = RealtimeClient(
          'http://127.0.0.1:8080',
          't',
          connect: connect,
          debugBuild: true,
        )..start();
        async.flushMicrotasks();
        expect(connects, 2);
        ok.dispose();
        local.dispose();
      });
    },
  );

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

  test(
    'Pause and resume during a handshake leaves exactly one socket',
    () async {
      final pending = <Completer<RealtimeSocket>>[];
      final client = RealtimeClient(
        'http://127.0.0.1:8080',
        't',
        connect: (_, _) {
          final c = Completer<RealtimeSocket>();
          pending.add(c);
          return c.future;
        },
      );
      client.start(); // App opens; the handshake is in flight.
      client.stop(); // Paused before it finishes.
      client.start(); // Resumed straight away.
      final a = FakeSocket(), b = FakeSocket();
      pending[0].complete(a);
      pending[1].complete(b);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(a.closed, isTrue, reason: 'the stale handshake is closed');
      expect(b.closed, isFalse);
      expect(client.connected.value, isTrue);
      client.stop();
      await Future<void>.delayed(Duration.zero);
      expect(a.closed && b.closed, isTrue);
      expect(client.connected.value, isFalse);
    },
  );

  test('A handshake that finishes after dispose is closed quietly', () async {
    final pending = Completer<RealtimeSocket>();
    final client = RealtimeClient(
      'http://127.0.0.1:8080',
      't',
      connect: (_, _) => pending.future,
    );
    client.start();
    client.dispose();
    final s = FakeSocket();
    pending.complete(s);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(s.closed, isTrue);
  });

  test('A session-ended close retries once with a fresh token', () {
    fakeAsync((async) {
      final tokens = <String>[];
      final sockets = <FakeSocket>[];
      var ended = 0;
      var fresh = 'token-1';
      final client = RealtimeClient(
        'http://127.0.0.1:8080',
        'token-1',
        tokenOf: () => fresh,
        refreshToken: () async => fresh = 'token-2',
        onSessionEnded: () => ended++,
        connect: (url, token) async {
          tokens.add(token);
          final s = FakeSocket();
          sockets.add(s);
          return s;
        },
      );
      client.start();
      async.flushMicrotasks();
      // 1013 is an ordinary "resync": reconnect with backoff, same token.
      sockets.last.serverClose(1013);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(tokens, ['token-1', 'token-1']);
      sockets.last.incoming.add(jsonEncode({'type': 'ready'}));
      async.flushMicrotasks();

      // 1008: the session ended. One immediate retry with a fresh token.
      sockets.last.serverClose(1008);
      async.flushMicrotasks();
      expect(tokens, ['token-1', 'token-1', 'token-2']);
      expect(client.connected.value, isTrue);
      expect(ended, 0);

      // Refused again: stop for good and hand over to the session layer.
      sockets.last.serverClose(1008);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      expect(tokens, hasLength(3));
      expect(ended, 1);
      expect(client.connected.value, isFalse);
      client.dispose();
    });
  });

  test('A refused handshake after a fresh token stops reconnecting', () {
    fakeAsync((async) {
      var attempts = 0, ended = 0;
      final client = RealtimeClient(
        'http://127.0.0.1:8080',
        'token-1',
        refreshToken: () async => 'token-2',
        onSessionEnded: () => ended++,
        connect: (url, token) async {
          attempts++;
          throw const RealtimeUnauthorized(401, 'UNAUTHENTICATED');
        },
      );
      client.start();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      expect(attempts, 2);
      expect(ended, 1);
      client.dispose();
    });
  });

  test(
    'A 401 APP_CHECK_REQUIRED stops the client without ending the session',
    () {
      fakeAsync((async) {
        var attempts = 0, ended = 0, appCheck = 0;
        var refreshed = 0;
        final client = RealtimeClient(
          'http://127.0.0.1:8080',
          'token-1',
          refreshToken: () async {
            refreshed++;
            return 'token-2';
          },
          onSessionEnded: () => ended++,
          onAppCheckRequired: () => appCheck++,
          connect: (url, token) async {
            attempts++;
            throw const RealtimeUnauthorized(401, 'APP_CHECK_REQUIRED');
          },
        );
        client.start();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        expect(attempts, 1, reason: 'no retry storm');
        expect(refreshed, 0);
        expect(ended, 0);
        expect(appCheck, 1);
        client.dispose();
      });
    },
  );

  test(
    'A refusal whose reason could not be read is retried, never a sign-out',
    () {
      fakeAsync((async) {
        var attempts = 0, ended = 0;
        final client = RealtimeClient(
          'http://127.0.0.1:8080',
          'token-1',
          onSessionEnded: () => ended++,
          connect: (url, token) async {
            attempts++;
            throw const RealtimeUnauthorized(401);
          },
        );
        client.start();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));
        expect(attempts, greaterThan(1), reason: 'backs off and retries');
        expect(ended, 0);
        client.dispose();
      });
    },
  );

  test('A 403 is not a sign-out either', () {
    fakeAsync((async) {
      var ended = 0;
      final client = RealtimeClient(
        'http://127.0.0.1:8080',
        'token-1',
        onSessionEnded: () => ended++,
        connect: (url, token) async =>
            throw const RealtimeUnauthorized(403, 'ONBOARDING_REQUIRED'),
      );
      client.start();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(ended, 0);
      client.dispose();
    });
  });
}
