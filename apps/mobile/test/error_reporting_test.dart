import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/error_reporting.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('scrubbing text and URLs', () {
    test('query strings, fragments and ids leave URLs', () {
      expect(
        scrubUrl(
          'https://api.hiyall.app/v1/media/019a4000-0000-7000-8000-000000000001?X-Amz-Signature=abc&sig=1#frag',
        ),
        'https://api.hiyall.app/v1/media/:id',
      );
      expect(
        scrubRoute(
          '/chats/019a4000-0000-7000-8000-000000000001?peer=x&name=Niko',
        ),
        '/chats/:id',
      );
    });

    test('tokens, emails and URLs inside messages are masked', () {
      final out = scrubText(
        'Failed https://r2.example/p.jpg?X-Amz-Signature=zzz for ana@example.com with '
        'Bearer eyJhbGciOi.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and eyJhbGciOiJSUzI1.eyJzdWIiOiIx.c2ln',
      );
      expect(out, isNot(contains('zzz')));
      expect(out, isNot(contains('ana@example.com')));
      expect(out, isNot(contains('eyJ')));
      expect(out, contains('[email]'));
    });
    test('a payload quoted inside an exception message is removed', () {
      final json = scrubText(
        const FormatException(
          'Unexpected character',
          '{"birthDate":"2010-01-01","displayName":"Ana","token":"abc"}',
          3,
        ).toString(),
      );
      expect(json, isNot(contains('birthDate')));
      expect(json, isNot(contains('Ana')));
      expect(json, contains('[json]'));
      expect(
        json,
        contains('Unexpected character'),
        reason: 'the kind of error stays',
      );

      final list = scrubText('Bad state\n[{"id":"1","body":"hello there"}]');
      expect(list, isNot(contains('hello there')));
      expect(list, startsWith('Bad state'));
    });

    test(
      'long base64 fragments are removed, ordinary words and short ids stay',
      () {
        const blob =
            'aGVsbG8gd29ybGQgdGhpcyBpcyBzb21lIGNpcGhlcnRleHQgYnl0ZXM0Mg==';
        final out = scrubText('Could not decode $blob at offset 3');
        expect(out, isNot(contains(blob)));
        expect(out, contains('[data]'));
        expect(out, contains('at offset 3'));
        // Url-safe base64 (a signature or key).
        expect(
          scrubText(
            'key=Zm9vYmFyLWJhei1xdXV4LWNvcmdlLWdyYXVsdC13YWxkby1mcmVkLXBsdWdo_AB12',
          ),
          isNot(contains('Zm9vYmFy')),
        );
        expect(
          scrubText('NoSuchMethodError: method not found'),
          contains('NoSuchMethodError'),
        );
        expect(
          scrubText(
            'package:hiyall/features/profile_editor/photo_step.dart failed',
          ),
          contains('package:hiyall/features/profile_editor/photo_step.dart'),
        );
        expect(scrubText('code abc123'), 'code abc123');
      },
    );

    test('a JWT longer than the base64 limit is still masked as a token', () {
      final jwt = 'eyJ${'a' * 60}.eyJ${'b' * 90}.${'c' * 80}';
      final out = scrubText('Failed with $jwt now');
      expect(out, isNot(contains('eyJ')));
      expect(out, isNot(contains('bbbbbbbb')));
    });
  });

  group('breadcrumbs', () {
    test('console and print lines are dropped', () {
      for (final category in ['console', 'print', 'log']) {
        expect(
          scrubBreadcrumb(
            Breadcrumb(message: 'hello', category: category),
            Hint(),
          ),
          isNull,
        );
      }
    });

    test('anything about a chat is dropped, wherever it appears', () {
      expect(
        scrubBreadcrumb(
          Breadcrumb(message: 'opened /chats/abc', category: 'navigation'),
          Hint(),
        ),
        isNull,
      );
      expect(
        scrubBreadcrumb(
          Breadcrumb(category: 'ui', data: {'route': '/chats/abc?name=Niko'}),
          Hint(),
        ),
        isNull,
      );
      expect(
        scrubBreadcrumb(
          Breadcrumb(message: 'chat sent', category: 'chat'),
          Hint(),
        ),
        isNull,
      );
    });

    test(
      'navigation crumbs keep the page but not queries, bodies or headers',
      () {
        final crumb = scrubBreadcrumb(
          Breadcrumb(
            category: 'navigation',
            message: 'to /discover?q=secret',
            data: {
              'to': '/discover?q=secret',
              'request_body': '{"password":"x"}',
              'headers': {'Authorization': 'Bearer t'},
              'status_code': 200,
            },
          ),
          Hint(),
        )!;
        expect(crumb.message, 'to /discover');
        expect(crumb.data!['to'], '/discover');
        expect(crumb.data!.containsKey('request_body'), isFalse);
        expect(crumb.data!.containsKey('headers'), isFalse);
        expect(crumb.data!['status_code'], 200);
      },
    );
  });

  group('events', () {
    SentryEvent dirty() => SentryEvent(
      user: SentryUser(
        id: 'u1',
        email: 'ana@example.com',
        ipAddress: '1.2.3.4',
      ),
      serverName: 'ana-phone',
      transaction: '/person/019a4000-0000-7000-8000-000000000001?x=1',
      message: SentryMessage(
        'GET https://api.hiyall.app/v1/me?token=abc failed',
      ),
      exceptions: [
        SentryException(
          type: 'DioException',
          value: 'Bearer abc.def.ghi to https://x.example/p?sig=1 by ana@example.com',
        ),
      ],
      request: SentryRequest(
        url: 'https://api.hiyall.app/v1/me/profile?token=abc',
        method: 'GET',
        cookies: 'sid=1',
        queryString: 'token=abc',
        data: {'birthDate': '2010-01-01'},
        headers: {
          'Authorization': 'Bearer abc',
          'Cookie': 'sid=1',
          'Content-Type': 'application/json',
          'X-Client-Version': '1.0.0',
        },
      ),
      breadcrumbs: [
        Breadcrumb(message: 'print: hello', category: 'console'),
        Breadcrumb(message: 'opened /chats/x', category: 'navigation'),
        Breadcrumb(message: 'to /home', category: 'navigation'),
      ],
    );

    test('no user, no request body, no credentials survive', () {
      final event = scrubEvent(dirty(), Hint())!;
      expect(event.user, isNull);
      expect(event.serverName, isNull);
      final r = event.request!;
      expect(r.url, 'https://api.hiyall.app/v1/me/profile');
      expect(r.queryString, isNull);
      expect(r.cookies, isNull);
      expect(r.data, isNull);
      expect(
        r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(r.headers['Content-Type'], 'application/json');
    });

    test('messages, exceptions, transactions and breadcrumbs are scrubbed', () {
      final event = scrubEvent(dirty(), Hint())!;
      expect(event.message!.formatted, isNot(contains('token=abc')));
      final text = event.exceptions!.single.value!;
      expect(text, isNot(contains('abc.def.ghi')));
      expect(text, isNot(contains('ana@example.com')));
      expect(text, isNot(contains('sig=1')));
      expect(event.transaction, '/person/:id');
      expect(event.breadcrumbs!.map((b) => b.message), ['to /home']);
    });
  });

  group('what is reported as fatal', () {
    tearDown(() {
      ErrorReporting.onCapture = null;
      FlutterError.onError = FlutterError.presentError;
      PlatformDispatcher.instance.onError = null;
    });

    test(
      'an error the framework caught is not a crash; an uncaught one is',
      () {
        final seen = <(String, bool)>[];
        ErrorReporting.onCapture = (error, fatal) =>
            seen.add(('$error', fatal));
        ErrorReporting.installHandlers();

        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('overflow in a list')),
        );
        PlatformDispatcher.instance.onError!(
          StateError('uncaught'),
          StackTrace.empty,
        );
        // Even a "silent" framework error stays non-fatal.
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('quiet'), silent: true),
        );

        expect(seen, [
          ('Bad state: overflow in a list', false),
          ('Bad state: uncaught', true),
          ('Bad state: quiet', false),
        ]);
      },
    );

    test('only a fatal error is reported to Sentry as unhandled', () {
      final handled = ErrorReporting.throwableFor(
        StateError('x'),
        fatal: false,
      );
      expect(handled, isA<StateError>());
      final crash = ErrorReporting.throwableFor(StateError('x'), fatal: true);
      expect(crash, isA<ThrowableMechanism>());
      expect((crash as ThrowableMechanism).mechanism.handled, isFalse);
      expect(crash.throwable, isA<StateError>());
    });
  });

  group('configuration', () {
    test('privacy-relevant options are fixed', () {
      final o = SentryFlutterOptions();
      ErrorReporting.configure(o);
      expect(o.sendDefaultPii, isFalse);
      expect(o.attachScreenshot, isFalse);
      expect(o.enablePrintBreadcrumbs, isFalse);
      expect(o.maxRequestBodySize, MaxRequestBodySize.never);
      expect(o.beforeSend, isNotNull);
      expect(o.beforeBreadcrumb, isNotNull);
      expect(o.release, startsWith('hiyall@'));
    });

    test(
      'without a DSN nothing is initialised and capture is a no-op',
      () async {
        expect(ErrorReporting.dsn, isEmpty);
        expect(ErrorReporting.enabled, isFalse);
        var ran = false;
        await ErrorReporting.start(() => ran = true);
        expect(ran, isTrue);
        expect(ErrorReporting.enabled, isFalse);
        ErrorReporting.capture(StateError('x'), StackTrace.current);
      },
    );
  });
}
