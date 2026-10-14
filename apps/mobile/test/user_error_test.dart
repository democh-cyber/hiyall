import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/user_error.dart';

String msg(DioExceptionType t, int? status, String path, [String? code]) =>
    ApiClient.failureMessage(t, status, code, path);

void main() {
  group('messages are chosen by endpoint and code', () {
    const bad = DioExceptionType.badResponse;
    test('404 names what was missing', () {
      expect(msg(bad, 404, '/v1/spaces/x'), 'This space is unavailable.');
      expect(
        msg(bad, 404, '/v1/users/x/profile'),
        'This profile is unavailable.',
      );
      expect(
        msg(bad, 404, '/v1/posts/x/like'),
        'This post is no longer available.',
      );
      expect(
        msg(bad, 404, '/v1/auth/sessions/x'),
        'That session has already ended.',
      );
      expect(
        msg(bad, 404, '/v1/friend-requests/x'),
        'That request is no longer open.',
      );
      expect(msg(bad, 404, '/v1/anything'), 'That’s no longer available.');
      expect(msg(bad, 404, '/v1/spaces/x'), isNot(contains('profile')));
    });

    test('409 says "username taken" only for that code', () {
      expect(
        msg(bad, 409, '/v1/me/profile', 'USERNAME_TAKEN'),
        'That username is already taken.',
      );
      expect(
        msg(bad, 409, '/v1/spaces/x/join', 'SOMETHING_ELSE'),
        isNot(contains('username')),
      );
    });

    test(
      'server errors, timeouts and being offline are three different messages',
      () {
        final server = msg(bad, 503, '/v1/me/profile');
        final timeout = msg(
          DioExceptionType.receiveTimeout,
          null,
          '/v1/me/profile',
        );
        final offline = msg(
          DioExceptionType.connectionError,
          null,
          '/v1/me/profile',
        );
        expect({server, timeout, offline}, hasLength(3));
        expect(server, contains('our side'));
        expect(timeout, contains('taking too long'));
        expect(offline, contains('offline'));
        expect(msg(bad, 500, '/x'), server);
      },
    );

    test('other statuses', () {
      expect(msg(bad, 401, '/x'), contains('session has expired'));
      expect(msg(bad, 412, '/x'), contains('settings changed'));
      expect(msg(bad, 422, '/x'), contains('Check your entries'));
      expect(msg(bad, 429, '/x'), contains('wait a moment'));
      expect(msg(bad, 413, '/x'), contains('too large'));
      expect(msg(bad, 418, '/x'), contains('Try again'));
    });

    test('transport failures carry a code the app can branch on', () {
      expect(
        ApiClient.transportCode(DioExceptionType.connectionTimeout, null),
        'TIMEOUT',
      );
      expect(
        ApiClient.transportCode(DioExceptionType.connectionError, null),
        'OFFLINE',
      );
      expect(
        ApiClient.transportCode(DioExceptionType.badResponse, 500),
        isNull,
      );
    });
  });

  group('friendlyError never shows a raw exception', () {
    test('known failures keep their words', () {
      expect(friendlyError(const ApiFailure('Nope.', 403, 'X')), 'Nope.');
      expect(
        friendlyError(const AuthFailure('Wrong password.')),
        'Wrong password.',
      );
      expect(
        friendlyError(
          const ApiFailure(
            'You can send 5 a day. Try again later.',
            429,
            'QUOTA',
            Duration(hours: 5),
          ),
        ),
        contains('Try again in about 5 hours'),
      );
    });

    test('text a screen already worded passes through unchanged', () {
      expect(friendlyError('Access removed'), 'Access removed');
    });

    test('anything else becomes the generic message', () {
      for (final error in <Object?>[
        StateError('type \'Null\' is not a subtype of type \'String\''),
        const FormatException('Unexpected character at 3'),
        Exception('secret https://x.example/p?sig=1'),
        null,
      ]) {
        final text = friendlyError(error);
        expect(text, genericFailure);
        expect(text, isNot(contains('subtype')));
        expect(text, isNot(contains('Exception')));
        expect(text, isNot(contains('sig=1')));
      }
    });
  });
}
