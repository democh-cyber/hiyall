import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/avatar_upload.dart';

/// Answers the API's photo routes and records what reaches each.
class ApiAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <String>[];
  ({int status, Map<String, String> headers, Map<String, dynamic> body})?
  refusal;

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
    requests.add(options);
    bodies.add(utf8.decode(chunks));
    final refused = refusal;
    if (refused != null) {
      return ResponseBody.fromString(
        jsonEncode(refused.body),
        refused.status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          for (final e in refused.headers.entries) e.key: [e.value],
        },
      );
    }
    final data = options.path == '/v1/media/uploads'
        ? {
            'mediaId': 'm1',
            'uploadUrl': 'https://storage.invalid/uploads/x?X-Amz-Signature=s',
            'method': 'PUT',
            'headers': {'Content-Type': 'image/jpeg'},
            'expiresAt': '2026-01-01T00:00:00Z',
          }
        : {'mediaId': 'm1', 'status': 'ready'};
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': data}),
      options.path == '/v1/media/uploads' ? 201 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Storage: records the request and how many body bytes arrive.
class StorageAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final lengths = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var length = 0;
    if (requestStream != null) {
      await for (final c in requestStream) {
        length += c.length;
      }
    }
    requests.add(options);
    lengths.add(length);
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const session = Session('token', 'user');
  late ApiAdapter api;
  late StorageAdapter storage;
  late ApiClient client;

  setUp(() {
    api = ApiAdapter();
    storage = StorageAdapter();
    client = ApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
        ..httpClientAdapter = api,
      uploads: Dio()..httpClientAdapter = storage,
    );
  });

  group('A photo goes to storage as exactly the declared bytes', () {
    for (final purpose in ['post', 'story', 'avatar']) {
      test('$purpose: raw body, exact length, no Content-Length of our own', () async {
        final bytes = Uint8List.fromList(List.generate(5000, (i) => i % 251));
        final id = await client.uploadPhoto(
          session,
          bytes,
          contentType: 'image/jpeg',
          purpose: purpose,
        );
        expect(id, 'm1');
        // The size it declares is the size it sends.
        expect(jsonDecode(api.bodies.first), {
          'purpose': purpose,
          'contentType': 'image/jpeg',
          'sizeBytes': 5000,
        });
        final put = storage.requests.single;
        expect(put.method, 'PUT');
        expect(storage.lengths.single, 5000);
        // The body is the bytes themselves: no multipart or other wrapping, no encoding.
        expect(put.data, same(bytes));
        final headers = {
          for (final e in put.headers.entries) e.key.toLowerCase(): e.value,
        };
        expect(headers['content-type'], 'image/jpeg');
        // Dio derives the length from the body; one value, equal to the body, no chunking.
        expect(headers['content-length'].toString(), '5000');
        expect(headers.keys, isNot(contains('transfer-encoding')));
        expect(headers.keys, isNot(contains('content-encoding')));
        expect(headers.keys, isNot(contains('authorization')));
        // The signed URL carries no API token and goes to storage, not the API.
        expect(put.uri.host, 'storage.invalid');
        expect(api.requests.map((r) => r.path), [
          '/v1/media/uploads',
          '/v1/media/m1/complete',
        ]);
      });
    }
  });

  group('A refused limit speaks in the server’s words', () {
    void refuse(String message, {String? retry}) => api.refusal = (
      status: 429,
      headers: {'Retry-After': ?retry},
      body: {
        'success': false,
        'error': {'code': 'QUOTA', 'message': message},
      },
    );

    Future<ApiFailure> failure() async {
      try {
        await client.uploadPhoto(
          session,
          Uint8List(10),
          contentType: 'image/jpeg',
          purpose: 'post',
        );
      } on ApiFailure catch (f) {
        return f;
      }
      fail('expected a refusal');
    }

    test('a daily limit carries Retry-After as a short hint', () async {
      refuse(
        'You’ve reached today’s photo upload limit. Try again later.',
        retry: '18000',
      );
      final f = await failure();
      expect(f.status, 429);
      expect(f.code, 'QUOTA');
      expect(f.retryAfter, const Duration(hours: 5));
      expect(f.message, contains('Try again later.'));
      expect(
        f.displayMessage,
        'You’ve reached today’s photo upload limit. Try again in about 5 hours.',
      );
      expect(f.toString(), f.displayMessage);
      // Nothing was sent to storage.
      expect(storage.requests, isEmpty);
    });

    test('a full storage has no hint and no automatic retry', () async {
      refuse(
        'Your photo storage is full. Delete some posts or stories to free space.',
      );
      final f = await failure();
      expect(f.retryAfter, isNull);
      expect(
        f.displayMessage,
        'Your photo storage is full. Delete some posts or stories to free space.',
      );
      expect(api.requests, hasLength(1));
      expect(AvatarError.from(f).canRetry, isFalse);
    });

    test('the hint is rounded to minutes or hours', () {
      String hint(int seconds) => ApiFailure(
        'You’ve reached today’s limit of 20 posts. Try again later.',
        429,
        'QUOTA',
        Duration(seconds: seconds),
      ).displayMessage;
      expect(hint(20), endsWith('Try again in about a minute.'));
      expect(hint(20 * 60 + 5), endsWith('Try again in about 21 minutes.'));
      expect(hint(3600), endsWith('Try again in about 60 minutes.'));
      expect(hint(2 * 3600 + 600), endsWith('Try again in about 2 hours.'));
      expect(hint(86400), endsWith('Try again in about 24 hours.'));
      expect(
        const ApiFailure(
          'Slow down',
          429,
          'RATE_LIMITED',
          Duration(hours: 1),
        ).displayMessage,
        'Slow down',
      );
    });

    test('a photo limit is not a connection problem for the avatar', () {
      final problem = AvatarError.from(
        const ApiFailure(
          'You’ve reached today’s photo upload limit. Try again in about 3 hours.',
          429,
          'QUOTA',
        ),
      );
      expect(problem.problem, AvatarProblem.quota);
      expect(problem.message, contains('photo upload limit'));
      expect(problem.canRetry, isFalse);
      expect(problem.needsAnotherPhoto, isFalse);
      // Other 429s still read as a connection problem that a retry may fix.
      expect(
        AvatarError.from(const ApiFailure('Slow', 429, 'RATE_LIMITED'))
            .canRetry,
        isTrue,
      );
    });
  });

  group(
    'the storage address is checked like every other connection (APP-N6)',
    () {
      test('https is accepted anywhere', () {
        expect(
          checkedUploadUrl('https://storage.example/u?sig=1', debug: false),
          'https://storage.example/u?sig=1',
        );
      });

      test('plain http to this machine is accepted in a debug build only', () {
        expect(
          checkedUploadUrl('http://127.0.0.1:9000/u', debug: true),
          'http://127.0.0.1:9000/u',
        );
        expect(
          () => checkedUploadUrl('http://127.0.0.1:9000/u', debug: false),
          throwsA(isA<ApiFailure>()),
        );
      });

      test('plain http to another host, junk and empty are refused with a clear message and no address', () {
        for (final bad in [
          'http://storage.example/u?sig=secret',
          'ftp://storage.example/u',
          'not a url',
          '',
          '//storage.example/u',
        ]) {
          try {
            checkedUploadUrl(bad, debug: true);
            fail('$bad should be refused');
          } on ApiFailure catch (f) {
            expect(f.code, 'INSECURE_UPLOAD_URL');
            expect(f.message, contains('couldn’t be sent safely'));
            expect(f.message, isNot(contains('secret')));
          }
        }
      });

      test('an upload whose server-given address is plain http to another host sends nothing to storage', () async {
        final insecure = ApiClient(
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8080'))
            ..httpClientAdapter = _InsecureUrlAdapter(),
          uploads: Dio()..httpClientAdapter = storage,
        );
        await expectLater(
          insecure.uploadPhoto(
            session,
            Uint8List(10),
            contentType: 'image/jpeg',
            purpose: 'post',
          ),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.code,
              'code',
              'INSECURE_UPLOAD_URL',
            ),
          ),
        );
        expect(storage.requests, isEmpty);
      });
    },
  );
}

/// An API that hands out a plain-http storage address.
class _InsecureUrlAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'success': true,
      'data': {
        'mediaId': 'm1',
        'uploadUrl': 'http://storage.invalid/uploads/x?X-Amz-Signature=s',
        'method': 'PUT',
        'headers': {'Content-Type': 'image/jpeg'},
      },
    }),
    201,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}
