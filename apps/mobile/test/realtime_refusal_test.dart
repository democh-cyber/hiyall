import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/realtime/connect_io.dart';
import 'package:hiyall/core/realtime/socket.dart';

/// A real loopback server standing in for the API's /v1/realtime when it refuses the handshake.
Future<HttpServer> refusing(int status, String? code) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      code == null
          ? 'plain text'
          : jsonEncode({
              'error': {'code': code, 'message': 'x'},
            }),
    );
    await request.response.close();
  });
  return server;
}

void main() {
  for (final (status, code) in [
    (401, 'UNAUTHENTICATED'),
    (401, 'APP_CHECK_REQUIRED'),
    (403, 'ONBOARDING_REQUIRED'),
  ]) {
    test('a $status $code handshake refusal carries its code', () async {
      final server = await refusing(status, code);
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('ws://127.0.0.1:${server.port}/v1/realtime');
      await expectLater(
        connectSocket(url, 'tok'),
        throwsA(
          isA<RealtimeUnauthorized>()
              .having((e) => e.status, 'status', status)
              .having((e) => e.code, 'code', code),
        ),
      );
    });
  }

  test('a refusal that is not JSON has no code', () async {
    final server = await refusing(401, null);
    addTearDown(() => server.close(force: true));
    final url = Uri.parse('ws://127.0.0.1:${server.port}/v1/realtime');
    await expectLater(
      connectSocket(url, 'tok'),
      throwsA(
        isA<RealtimeUnauthorized>().having((e) => e.code, 'code', isNull),
      ),
    );
  });

  test('the reason is asked for with the same token', () async {
    final headers = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      headers.add(request.headers.value('authorization'));
      request.response.statusCode = 401;
      await request.response.close();
    });
    final url = Uri.parse('ws://127.0.0.1:${server.port}/v1/realtime');
    await expectLater(
      connectSocket(url, 'tok'),
      throwsA(isA<RealtimeUnauthorized>()),
    );
    expect(headers, everyElement('Bearer tok'));
  });
}
