import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/chat/chat_api.dart';

/// Records each request and refuses the first [refusals] as unauthenticated.
class Recorder implements HttpClientAdapter {
  Recorder([this.refusals = 1]);
  final int refusals;
  final bodies = <String>[];
  final auths = <String?>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final c in requestStream) {
        chunks.addAll(c);
      }
    }
    bodies.add(utf8.decode(chunks));
    auths.add(options.headers['Authorization'] as String?);
    final first = bodies.length <= refusals;
    return ResponseBody.fromString(
      jsonEncode(
        first
            ? {
                'success': false,
                'error': {'code': 'UNAUTHENTICATED', 'message': 'expired'},
              }
            : {
                'success': true,
                'data': {'sharing': true, 'updatedAt': null},
              },
      ),
      first ? 401 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('API address rules', () {
    Future<Object?> call(String baseUrl) async {
      final dio = Dio(BaseOptions(baseUrl: baseUrl))
        ..httpClientAdapter = Recorder(0);
      try {
        await ApiClient(dio: dio).shareLocation(const Session('t', 'u'), 1, 2);
        return null;
      } on ApiFailure catch (failure) {
        return failure.message;
      }
    }

    test('A debug build may use plain http for its own machine', () async {
      for (final url in [
        'http://127.0.0.1:8080',
        'http://localhost:8080',
        'http://10.0.2.2:8080',
      ]) {
        expect(await call(url), isNot('The service is not configured yet.'));
      }
    });

    test('Plain http to any other host is refused', () async {
      // Dev login adds its own wording for the same refusal.
      final refusal = anyOf(
        'The service is not configured yet.',
        'Development login requires a local service.',
      );
      expect(await call('http://api.example.com'), refusal);
      expect(await call('http://192.168.1.20:8080'), refusal);
    });

    test('An address that is missing or not a URL is refused', () async {
      expect(await call(''), 'The service is not configured yet.');
    });
  });

  test('A 401 retry resends the original body with the fresh token', () async {
    final adapter = Recorder();
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://127.0.0.1:8080',
        contentType: 'application/json',
      ),
    )..httpClientAdapter = adapter;
    var expired = 0;
    final api = ApiClient(dio: dio)
      ..tokenRefresher = (() async => 'fresh')
      ..onUnauthorized = () => expired++;
    await api.shareLocation(const Session('stale', 'u'), 12.97, 77.59);
    expect(adapter.bodies, hasLength(2));
    expect(adapter.bodies[1], adapter.bodies[0]);
    expect(adapter.bodies[1], isNot(contains('UNAUTHENTICATED')));
    expect(adapter.auths, ['Bearer stale', 'Bearer fresh']);
    expect(expired, 0);
  });

  test('The chat relay refreshes a stale token once, then expires', () async {
    Dio dio(Recorder adapter) => Dio(
      BaseOptions(
        baseUrl: 'http://127.0.0.1:8080',
        contentType: 'application/json',
      ),
    )..httpClientAdapter = adapter;
    var expired = 0;
    final ok = Recorder();
    final chat = ChatApi(
      'http://127.0.0.1:8080',
      'stale',
      tokenRefresher: () async => 'fresh',
      onUnauthorized: () => expired++,
      dio: dio(ok),
    );
    await chat.markRead('c1', DateTime.utc(2026));
    expect(ok.auths, ['Bearer stale', 'Bearer fresh']);
    expect(ok.bodies[1], ok.bodies[0]);
    expect(expired, 0);

    final revoked = Recorder(2);
    final gone = ChatApi(
      'http://127.0.0.1:8080',
      'stale',
      tokenRefresher: () async => 'fresh',
      onUnauthorized: () => expired++,
      dio: dio(revoked),
    );
    await expectLater(
      gone.markRead('c1', DateTime.utc(2026)),
      throwsA(
        isA<ChatFailure>()
            .having((f) => f.status, 'status', 401)
            .having((f) => f.code, 'code', 'UNAUTHENTICATED'),
      ),
    );
    expect(revoked.auths, hasLength(2));
    expect(expired, 1);
  });
}
