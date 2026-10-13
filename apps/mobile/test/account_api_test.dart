import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/reauth.dart';

/// An ApiClient whose HTTP layer answers with [reply] and records what was asked.
ApiClient clientWith(
  List<String> seen,
  Response<Object?> Function(RequestOptions) reply,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          seen.add(
            '${options.method} ${options.path} ${options.headers['Authorization']} ${options.data is Map ? jsonEncode(options.data) : ''}',
          );
          final response = reply(options);
          if ((response.statusCode ?? 200) >= 400) {
            handler.reject(
              DioException(requestOptions: options, response: response),
            );
          } else {
            handler.resolve(response);
          }
        },
      ),
    );
  return ApiClient(dio: dio);
}

Response<Object?> json(
  RequestOptions o,
  int status,
  Object body, [
  Map<String, List<String>> headers = const {},
]) => Response(
  requestOptions: o,
  statusCode: status,
  data: body,
  headers: Headers.fromMap(headers),
);

Response<Object?> failure(
  RequestOptions o,
  int status,
  String code,
  String message, [
  Map<String, List<String>> headers = const {},
]) => json(o, status, {
  'success': false,
  'error': {'code': code, 'message': message},
}, headers);

void main() {
  const session = Session('tok', 'me');

  test('Scheduling sends only the username and reads the status', () async {
    final seen = <String>[];
    final api = clientWith(
      seen,
      (o) => json(o, 200, {
        'success': true,
        'data': {
          'pending': true,
          'scheduledAt': '2026-10-13T10:00:00Z',
          'dueAt': '2026-11-12T10:00:00Z',
          'canCancel': true,
        },
      }),
    );
    final status = await api.scheduleDeletion(session, 'anjali');
    expect(
      seen.single,
      'POST /v1/me/deletion Bearer tok {"confirmUsername":"anjali"}',
    );
    expect(status.pending && status.canCancel, isTrue);
  });

  test('A stale sign-in is REAUTH_REQUIRED with the server\'s words', () async {
    final api = clientWith(
      [],
      (o) => failure(
        o,
        403,
        'REAUTH_REQUIRED',
        'Confirm it\'s you by signing in again.',
      ),
    );
    await expectLater(
      api.scheduleDeletion(session, 'anjali'),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.code, 'code', 'REAUTH_REQUIRED')
            .having((e) => e.status, 'status', 403)
            .having((e) => e.message, 'message', contains('signing in again')),
      ),
    );
  });

  test('A wrong username is shown as the server says it', () async {
    final api = clientWith(
      [],
      (o) => failure(o, 422, 'VALIDATION', 'that is not your username'),
    );
    await expectLater(
      api.scheduleDeletion(session, 'x'),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.message,
          'message',
          'that is not your username',
        ),
      ),
    );
  });

  test('Cancelling after the window, and when nothing is scheduled', () async {
    var status = 409;
    final api = clientWith(
      [],
      (o) => status == 409
          ? failure(
              o,
              409,
              'DELETION_WINDOW_CLOSED',
              'The 30 days to keep this account have passed.',
            )
          : failure(o, 404, 'NOT_FOUND', 'This resource is unavailable'),
    );
    await expectLater(
      api.cancelDeletion(session),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.code,
          'code',
          'DELETION_WINDOW_CLOSED',
        ),
      ),
    );
    status = 404;
    await expectLater(
      api.cancelDeletion(session),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.message,
          'message',
          'Your account is not scheduled for deletion.',
        ),
      ),
    );
  });

  test('The export comes back as the raw bytes', () async {
    final seen = <String>[];
    final api = clientWith(seen, (o) {
      expect(o.responseType, ResponseType.bytes);
      return json(o, 200, utf8.encode('{"exportVersion":1}'));
    });
    expect(utf8.decode(await api.exportData(session)), '{"exportVersion":1}');
    expect(seen.single, startsWith('GET /v1/me/export Bearer tok'));
  });

  test('The daily export limit carries its wait', () async {
    final api = clientWith(
      [],
      (o) => json(
        o,
        429,
        utf8.encode(
          jsonEncode({
            'success': false,
            'error': {'code': 'RATE_LIMITED', 'message': 'Once a day.'},
          }),
        ),
        {
          'retry-after': ['3600'],
        },
      ),
    );
    await expectLater(
      api.exportData(session),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.code, 'code', 'RATE_LIMITED')
            .having((e) => e.retryAfter, 'retryAfter', const Duration(hours: 1))
            .having((e) => e.message, 'message', 'Once a day.'),
      ),
    );
  });

  test(
    'An export that fails for another reason is not mistaken for the limit',
    () async {
      final api = clientWith([], (o) => json(o, 500, utf8.encode('nope')));
      await expectLater(
        api.exportData(session),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', isNull)),
      );
    },
  );

  group('Re-authentication errors', () {
    test('read as plain words', () {
      expect(
        FirebaseReauthenticator.failureFor('wrong-password').message,
        'That password doesn’t match.',
      );
      expect(
        FirebaseReauthenticator.failureFor('invalid-credential').code,
        'invalid-credential',
      );
      expect(
        FirebaseReauthenticator.failureFor('popup-closed-by-user').cancelled,
        isTrue,
      );
      expect(
        FirebaseReauthenticator.failureFor('user-mismatch').message,
        contains('account you are signed in with'),
      );
      expect(
        FirebaseReauthenticator.failureFor('weird').message,
        contains('weird'),
      );
    });
  });
}
