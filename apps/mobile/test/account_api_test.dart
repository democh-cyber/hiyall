import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/api_config.dart';
import 'package:hiyall/core/app_info.dart';
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

  test('An Apple account sends its one-time authorization code too', () async {
    final seen = <String>[];
    final api = clientWith(
      seen,
      (o) => json(o, 200, {
        'success': true,
        'data': {'pending': true, 'canCancel': true},
      }),
    );
    await api.scheduleDeletion(
      session,
      'anjali',
      appleAuthorizationCode: 'c.abc',
    );
    expect(
      seen.single,
      'POST /v1/me/deletion Bearer tok {"confirmUsername":"anjali","appleAuthorizationCode":"c.abc"}',
    );
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

  group(
    'The export goes through the same request path as every other call',
    () {
      List<int> envelope(String code) => utf8.encode(
        jsonEncode({
          'success': false,
          'error': {'code': code, 'message': 'x'},
        }),
      );

      test('it carries the app version and the bearer token', () async {
        final headers = <Map<String, dynamic>>[];
        final api = clientWith([], (o) {
          headers.add(Map.of(o.headers));
          return json(o, 200, utf8.encode('{}'));
        });
        await api.exportData(session);
        expect(headers.single[clientVersionHeader], AppInfo.version);
        expect(headers.single['Authorization'], 'Bearer tok');
      });

      test(
        'plain http to another host is refused before anything is sent',
        () async {
          var sent = 0;
          final dio = Dio(BaseOptions(baseUrl: 'http://api.example.test'))
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (o, h) {
                  sent++;
                  h.resolve(json(o, 200, utf8.encode('{}')));
                },
              ),
            );
          await expectLater(
            ApiClient(dio: dio).exportData(session),
            throwsA(
              isA<ApiFailure>().having(
                (e) => e.message,
                'message',
                contains('not configured'),
              ),
            ),
          );
          expect(sent, 0, reason: 'the export holds personal data');
        },
      );

      test(
        'a 401 is retried once with a fresh token, and the session is kept',
        () async {
          final auths = <Object?>[];
          var unauthorized = 0;
          final api =
              clientWith([], (o) {
                  auths.add(o.headers['Authorization']);
                  return auths.length == 1
                      ? json(o, 401, envelope('UNAUTHENTICATED'))
                      : json(o, 200, utf8.encode('{"exportVersion":1}'));
                })
                ..tokenRefresher = (() async => 'fresh')
                ..onUnauthorized = () => unauthorized++;
          expect(
            utf8.decode(await api.exportData(session)),
            '{"exportVersion":1}',
          );
          expect(auths, ['Bearer tok', 'Bearer fresh']);
          expect(unauthorized, 0);
        },
      );

      test('a 401 that survives the refresh ends the session', () async {
        var unauthorized = 0;
        final api =
            clientWith([], (o) => json(o, 401, envelope('UNAUTHENTICATED')))
              ..tokenRefresher = (() async => 'fresh')
              ..onUnauthorized = () => unauthorized++;
        await expectLater(
          api.exportData(session),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
        );
        expect(unauthorized, 1);
      });

      test('426 UPGRADE_REQUIRED shows the update screen', () async {
        var upgrades = 0;
        final api = clientWith(
          [],
          (o) => json(o, 426, envelope(upgradeRequiredCode)),
        )..onUpgradeRequired = () => upgrades++;
        await expectLater(
          api.exportData(session),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.code,
              'code',
              upgradeRequiredCode,
            ),
          ),
        );
        expect(upgrades, 1);
      });

      test(
        'a 429 with no body still says to wait a day and carries Retry-After',
        () async {
          final api = clientWith(
            [],
            (o) => json(o, 429, utf8.encode(''), {
              'retry-after': ['600'],
            }),
          );
          await expectLater(
            api.exportData(session),
            throwsA(
              isA<ApiFailure>()
                  .having((e) => e.message, 'message', contains('once a day'))
                  .having(
                    (e) => e.retryAfter,
                    'retryAfter',
                    const Duration(minutes: 10),
                  ),
            ),
          );
        },
      );
    },
  );

  group('The shared transport rule', () {
    test(
      'https is always fine; plain http only to this machine in a debug build',
      () {
        expect(
          isSecureTransport(Uri.parse('https://api.example.test')),
          isTrue,
        );
        expect(
          isSecureTransport(Uri.parse('http://127.0.0.1:8080'), debug: true),
          isTrue,
        );
        expect(
          isSecureTransport(Uri.parse('http://localhost:8080'), debug: true),
          isTrue,
        );
        expect(
          isSecureTransport(Uri.parse('http://10.0.2.2:8080'), debug: true),
          isTrue,
        );
        expect(
          isSecureTransport(Uri.parse('http://127.0.0.1:8080'), debug: false),
          isFalse,
        );
        expect(
          isSecureTransport(Uri.parse('http://api.example.test'), debug: true),
          isFalse,
        );
        expect(
          isSecureTransport(Uri.parse('ws://127.0.0.1'), debug: true),
          isFalse,
        );
        expect(isSecureTransport(null), isFalse);
        expect(isSecureTransport(Uri.parse('')), isFalse);
        expect(isLoopbackHttp(Uri.parse('http://localhost')), isTrue);
        expect(isLoopbackHttp(Uri.parse('https://localhost')), isFalse);
      },
    );
  });

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
