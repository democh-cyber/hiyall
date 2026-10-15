import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hiyall/shared/person_avatar.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/auth/firebase_gateway.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/auth/auth_widgets.dart'
    show SocialSignIn, validateEmail;
import 'package:hiyall/features/auth/onboarding_screen.dart';
import 'package:hiyall/core/avatar_upload.dart';

import 'avatar_helpers.dart';
import 'widget_test.dart' show FakeApi;
import 'support/fixtures.dart';

/// An identity provider that behaves like Firebase: it reports the signed-in
/// account when listened to, then every change.
class FakeGateway implements AuthGateway {
  final _changes = StreamController<AuthUser?>.broadcast();
  AuthUser? user;
  AuthFailure? failure;

  /// An exception that is not an AuthFailure, as an unmapped provider error would be.
  Object? crash;
  bool verifiedOnReload = false;
  int resends = 0, reloads = 0;
  String token = 'token-1';

  FakeGateway([this.user]);

  @override
  bool get configured => true;
  @override
  AuthUser? get currentUser => user;
  @override
  String? get cachedToken => token;
  @override
  Stream<AuthUser?> userChanges() => Stream<AuthUser?>.multi((c) {
    c.add(user);
    final sub = _changes.stream.listen(c.add);
    c.onCancel = sub.cancel;
  });

  void _emit(AuthUser? next) {
    user = next;
    _changes.add(next);
  }

  AuthUser _account(AuthMethod method, {bool verified = true}) => AuthUser(
    uid: 'uid-1',
    method: method,
    email: 'sam@example.com',
    displayName: method == AuthMethod.google ? 'Sam Rivera' : null,
    emailVerified: verified,
  );

  @override
  Future<AuthUser> signInWithEmail(String email, String password) async {
    if (failure != null) throw failure!;
    final next = _account(AuthMethod.password);
    _emit(next);
    return next;
  }

  @override
  Future<AuthUser> signUpWithEmail(String email, String password) async {
    if (crash != null) throw crash!;
    if (failure != null) throw failure!;
    final next = _account(AuthMethod.password, verified: false);
    _emit(next);
    return next;
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    if (failure != null) throw failure!;
    final next = _account(AuthMethod.google);
    _emit(next);
    return next;
  }

  @override
  Future<AuthUser> signInWithFacebook() async {
    final next = _account(AuthMethod.facebook);
    _emit(next);
    return next;
  }

  @override
  Future<AuthUser> signInWithApple() async {
    if (failure != null) throw failure!;
    final next = _account(AuthMethod.apple);
    _emit(next);
    return next;
  }

  @override
  Future<void> sendEmailVerification() async => resends++;
  @override
  Future<AuthUser?> reload() async {
    reloads++;
    if (verifiedOnReload && user != null) {
      user = _account(AuthMethod.password);
    }
    return user;
  }

  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<void> signOut() async => _emit(null);
  @override
  Future<String> idToken() async => token;
  @override
  Future<String?> refreshToken() async => token = 'token-2';
}

class AuthApi extends FakeApi {
  bool onboarded = false;

  /// The terms revision the service asks the person to accept.
  String termsVersion = '2026-10-01';
  bool usernameFree = true;
  bool failProfileRead = false;
  ApiFailure? completeFailure, updateFailure, ageFailure;
  final ageChecks = <String>[];
  Object? uploadFailure;
  ApiFailure? attachFailure;
  Map<String, dynamic>? profilePatch, privacyPatch;
  final patches = <Map<String, dynamic>>[];
  Map<String, String>? completed;
  final checked = <String>[];

  @override
  Future<Profile> profile(Session s) async {
    if (failProfileRead) {
      throw const ApiFailure(
        'Could not connect. Check your connection and retry.',
      );
    }
    return Profile(
      userId: samId,
      username: onboarded ? 'sam_r' : 'member_0a1b2c3d4e5f',
      displayName: onboarded ? 'Sam' : 'Hiyall member',
      bio: '',
      profession: '',
      version: '1',
    );
  }

  @override
  Future<void> logout(Session s) async {}

  @override
  Future<OnboardingStatus> onboarding(Session s) async =>
      OnboardingStatus(onboarded, termsVersion);

  @override
  Future<bool> usernameAvailable(Session s, String username) async {
    checked.add(username);
    return usernameFree;
  }

  @override
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async {
    if (patch.containsKey('avatarMediaId')) {
      if (attachFailure != null) throw attachFailure!;
      patches.add(patch);
      calls.add('attach ${patch['avatarMediaId']}');
      return p;
    }
    if (updateFailure != null) throw updateFailure!;
    profilePatch = patch;
    calls.add('profile');
    return p;
  }

  /// Media routes stay closed until onboarding is complete, as on the server.
  @override
  Future<String> uploadPhoto(
    Session s,
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async {
    if (!onboarded) {
      throw const ApiFailure(
        'Finish setting up first.',
        403,
        'ONBOARDING_REQUIRED',
      );
    }
    if (uploadFailure != null) throw uploadFailure!;
    calls.add('upload $purpose $contentType ${bytes.length}');
    return 'media-1';
  }

  @override
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async {
    privacyPatch = patch;
    return p;
  }

  @override
  Future<void> checkBirthDate(Session s, String birthDate) async {
    ageChecks.add(birthDate);
    if (ageFailure != null) throw ageFailure!;
  }

  @override
  Future<OnboardingStatus> completeOnboarding(
    Session s, {
    required String birthDate,
    required String termsVersion,
  }) async {
    if (completeFailure != null) throw completeFailure!;
    completed = {'birthDate': birthDate, 'termsVersion': termsVersion};
    calls.add('complete');
    onboarded = true;
    return OnboardingStatus(true, termsVersion);
  }
}

/// The provider can't be reached when the account is re-read.
class FailingReload extends FakeGateway {
  FailingReload([super.user]);
  AuthFailure? reloadFailure;
  @override
  Future<AuthUser?> reload() async {
    if (reloadFailure != null) throw reloadFailure!;
    return super.reload();
  }
}

/// Holds the first profile read until [gate] opens.
class GatedAuthApi extends AuthApi {
  Completer<void>? gate;
  @override
  Future<Profile> profile(Session s) async {
    await gate?.future;
    return super.profile(s);
  }
}

Future<ProviderContainer> launch(
  WidgetTester tester, {
  required AuthApi api,
  AuthGateway? gateway,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      if (gateway != null) authGatewayProvider.overrideWithValue(gateway),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
  );
  await tester.pumpAndSettle();
  return container;
}

String location(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Future<void> type(WidgetTester tester, String label, String text) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), text);
  await tester.pump();
}

/// The picker opens on today in the year list, with no suggested age. This picks 2000.
Future<void> chooseBirthDate(
  WidgetTester tester, {
  String year = '2000',
}) async {
  await tester.tap(find.byKey(const Key('onb-dob')));
  await tester.pumpAndSettle();
  for (var i = 0; i < 40 && find.text(year).evaluate().isEmpty; i++) {
    await tester.drag(find.byType(YearPicker), const Offset(0, 200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text(year));
  await tester.pumpAndSettle();
  await tester.tap(find.text(year));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> next(WidgetTester tester, [String key = 'onb-next']) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

/// Walks the onboarding steps with valid answers, stopping before Finish.
Future<void> fillOnboarding(WidgetTester tester) async {
  await chooseBirthDate(tester);
  await tester.tap(find.byKey(const Key('onb-terms')));
  await tester.pump();
  await next(tester);
  await type(tester, 'Display name', 'Sam Rivera');
  await type(tester, 'Username', 'sam_r');
  await next(tester);
  // The photo and "about you" steps are optional.
  await tester.tap(find.byKey(const Key('onb-skip')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('onb-skip')));
  await tester.pumpAndSettle();
  for (final interest in ['Music', 'Art', 'Travel']) {
    await tester.tap(find.widgetWithText(FilterChip, interest));
    await tester.pump();
  }
}

void main() {
  group('helpers', () {
    test('Members must be 13 or older on the day', () {
      final today = DateTime(2026, 10, 10);
      expect(meetsMinimumAge(DateTime(2013, 10, 10), today), isTrue);
      expect(meetsMinimumAge(DateTime(2013, 10, 11), today), isFalse);
      expect(meetsMinimumAge(DateTime(2000, 1, 1), today), isTrue);
      expect(meetsMinimumAge(DateTime(2020, 6, 1), today), isFalse);
      expect(minimumAge, 13);
    });
    test('Dates are sent as ISO calendar dates', () {
      expect(isoDate(DateTime(2000, 3, 7)), '2000-03-07');
    });
    test('Usernames are suggested in the server grammar', () {
      expect(suggestUsername('Sam Rivera'), 'sam_rivera');
      expect(suggestUsername('sam.r+news@example.com'), 'sam_r_news');
      expect(suggestUsername('Zo'), '');
      expect(suggestUsername('a' * 50).length, 30);
      expect(
        RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(suggestUsername('Åsa Öberg')),
        isTrue,
      );
    });
    test('Email addresses are checked before sending', () {
      expect(validateEmail(''), isNotNull);
      expect(validateEmail('nope'), isNotNull);
      expect(validateEmail('a@b'), isNotNull);
      expect(validateEmail(' sam@example.com '), isNull);
    });
    test('Provider errors become safe copy and cancellations stay silent', () {
      expect(
        FirebaseAuthGateway.failureFor('invalid-credential').message,
        contains('don’t match'),
      );
      expect(
        FirebaseAuthGateway.failureFor('wrong-password').message,
        contains('don’t match'),
      );
      expect(
        FirebaseAuthGateway.failureFor('email-already-in-use').code,
        'email-already-in-use',
      );
      expect(
        FirebaseAuthGateway.failureFor('popup-closed-by-user').cancelled,
        isTrue,
      );
      expect(FirebaseAuthGateway.failureFor('canceled').cancelled, isTrue);
      expect(
        FirebaseAuthGateway.failureFor('something-new').cancelled,
        isFalse,
      );
      // The two cases that must not reveal which accounts exist read the same.
      expect(
        FirebaseAuthGateway.failureFor('user-not-found').message,
        FirebaseAuthGateway.failureFor('wrong-password').message,
      );
    });
    test('Only password accounts need their email verified', () {
      expect(
        const AuthUser(
          uid: 'a',
          method: AuthMethod.password,
        ).needsEmailVerification,
        isTrue,
      );
      expect(
        const AuthUser(
          uid: 'a',
          method: AuthMethod.password,
          emailVerified: true,
        ).needsEmailVerification,
        isFalse,
      );
      expect(
        const AuthUser(
          uid: 'a',
          method: AuthMethod.google,
        ).needsEmailVerification,
        isFalse,
      );
    });
  });

  group('social buttons', () {
    Widget host(bool facebook) => MaterialApp(
      home: Scaffold(
        body: SocialSignIn(
          enabled: true,
          showFacebook: facebook,
          onGoogle: () {},
          onFacebook: () {},
        ),
      ),
    );
    testWidgets('Facebook is hidden unless the build enables it', (
      tester,
    ) async {
      await tester.pumpWidget(host(false));
      expect(find.byKey(const Key('google-button')), findsOneWidget);
      expect(find.byKey(const Key('facebook-button')), findsNothing);
      await tester.pumpWidget(host(true));
      expect(find.byKey(const Key('facebook-button')), findsOneWidget);
    });
  });

  group('tokens', () {
    Dio rejecting(Set<String> accepted, List<String> seen) =>
        Dio(BaseOptions(baseUrl: 'https://api.example.test'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final bearer = '${options.headers['Authorization']}'
                    .replaceFirst('Bearer ', '');
                seen.add(bearer);
                if (accepted.contains(bearer)) {
                  return handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: {
                        'data': {
                          'userId': samId,
                          'username': 'sam_r',
                          'displayName': 'Sam',
                        },
                      },
                    ),
                  );
                }
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 401,
                      data: {
                        'error': {'code': 'UNAUTHENTICATED', 'message': 'x'},
                      },
                    ),
                  ),
                );
              },
            ),
          );

    test('A stale token is replaced once and the request retried', () async {
      final seen = <String>[];
      var ended = 0;
      final api = ApiClient(dio: rejecting({'fresh'}, seen))
        ..onUnauthorized = (() => ended++)
        ..tokenRefresher = () async => 'fresh';
      final profile = await api.profile(const Session('stale', samId));
      expect(profile.userId, samId);
      expect(seen, ['stale', 'fresh']);
      expect(ended, 0);
    });

    test('If refreshing gives the same token the session ends', () async {
      final seen = <String>[];
      var ended = 0;
      final api = ApiClient(dio: rejecting({'other'}, seen))
        ..onUnauthorized = (() => ended++)
        ..tokenRefresher = () async => 'stale';
      await expectLater(
        api.profile(const Session('stale', samId)),
        throwsA(isA<ApiFailure>()),
      );
      expect(seen, ['stale']);
      expect(ended, 1);
    });

    test('A refused retry is not retried again', () async {
      final seen = <String>[];
      var ended = 0;
      final api = ApiClient(dio: rejecting({'none'}, seen))
        ..onUnauthorized = (() => ended++)
        ..tokenRefresher = () async => 'fresh';
      await expectLater(
        api.profile(const Session('stale', samId)),
        throwsA(isA<ApiFailure>()),
      );
      expect(seen, ['stale', 'fresh']);
      expect(ended, 1);
    });

    test('A live session always reads the newest token', () {
      var current = 'one';
      final session = Session('one', samId, live: () => current);
      expect(session.token, 'one');
      current = 'two';
      expect(session.token, 'two');
      expect(session.copyWith(onboarded: false).token, 'two');
      expect(const Session('fixed', samId).token, 'fixed');
      expect(const Session('fixed', samId).onboarded, isTrue);
    });
  });

  group('signed out', () {
    testWidgets('Visitors land on Welcome and can reach log in and sign up', (
      tester,
    ) async {
      final container = await launch(tester, api: AuthApi());
      expect(location(container), '/welcome');
      expect(find.byKey(const Key('create-account')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('log-in')));
      await tester.tap(find.byKey(const Key('log-in')));
      await tester.pumpAndSettle();
      // Welcome pushes Log in and Sign up so Back returns to it.
      expect(container.read(routerProvider).state.uri.path, '/login');
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.byKey(const Key('google-button')), findsOneWidget);
      // Facebook sign-in is switched off until a Meta app is connected.
      expect(find.byKey(const Key('facebook-button')), findsNothing);
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(container.read(routerProvider).state.uri.path, '/signup');
      expect(find.text('Create your account'), findsOneWidget);
    });

    testWidgets('Private routes send signed-out visitors to Welcome', (
      tester,
    ) async {
      final container = await launch(tester, api: AuthApi());
      for (final path in [
        '/home',
        '/profile',
        '/chats',
        '/spaces',
        '/compose',
        '/onboarding',
      ]) {
        container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        expect(location(container), '/welcome', reason: path);
      }
    });

    testWidgets('Without Firebase keys the forms say so and cannot submit', (
      tester,
    ) async {
      final container = await launch(tester, api: AuthApi());
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('not-configured')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('login-submit')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('google-button')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('Log in checks the form before calling the provider', (
      tester,
    ) async {
      final gateway = FakeGateway();
      final container = await launch(tester, api: AuthApi(), gateway: gateway);
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      expect(gateway.user, isNull);
      await type(tester, 'Email', 'not-an-email');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
    });

    testWidgets('Sign up asks for a password of at least eight characters', (
      tester,
    ) async {
      final gateway = FakeGateway();
      final container = await launch(tester, api: AuthApi(), gateway: gateway);
      container.read(routerProvider).go('/signup');
      await tester.pumpAndSettle();
      await type(tester, 'Email', 'sam@example.com');
      await type(tester, 'Password', 'short');
      await tester.ensureVisible(find.byKey(const Key('signup-submit')));
      await tester.tap(find.byKey(const Key('signup-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(gateway.user, isNull);
    });

    testWidgets('A wrong password shows the provider message and stays put', (
      tester,
    ) async {
      final gateway = FakeGateway()
        ..failure = const AuthFailure('That email and password don’t match.');
      final container = await launch(tester, api: AuthApi(), gateway: gateway);
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      await type(tester, 'Email', 'sam@example.com');
      await type(tester, 'Password', 'wrong-password');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-error')), findsOneWidget);
      expect(find.textContaining('don’t match'), findsOneWidget);
      expect(location(container), '/login');
    });

    testWidgets('Closing the Google sheet shows no error', (tester) async {
      final gateway = FakeGateway()
        ..failure = const AuthFailure('', code: 'cancelled', cancelled: true);
      final container = await launch(tester, api: AuthApi(), gateway: gateway);
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('google-button')));
      await tester.tap(find.byKey(const Key('google-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-error')), findsNothing);
    });

    testWidgets(
      'Password reset confirms without revealing whether the account exists',
      (tester) async {
        final container = await launch(
          tester,
          api: AuthApi(),
          gateway: FakeGateway(),
        );
        container.read(routerProvider).go('/login');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('forgot-password')));
        await tester.pumpAndSettle();
        await type(tester, 'Email', 'who@example.com');
        await tester.tap(find.byKey(const Key('reset-submit')));
        await tester.pumpAndSettle();
        expect(find.text('Check your inbox'), findsOneWidget);
        expect(
          find.textContaining('If an account exists for who@example.com'),
          findsOneWidget,
        );
      },
    );

    testWidgets('An ended session explains itself on Welcome', (tester) async {
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.google,
          emailVerified: true,
        ),
      );
      final api = AuthApi()..onboarded = true;
      final container = await launch(tester, api: api, gateway: gateway);
      expect(location(container), '/home');
      container.read(sessionProvider.notifier).expire();
      await tester.pumpAndSettle();
      expect(location(container), '/welcome');
      expect(find.byKey(const Key('session-ended')), findsOneWidget);
      expect(gateway.user, isNull);
    });
  });

  group('email verification', () {
    testWidgets('An unexpected sign-up error is shown, not swallowed', (
      tester,
    ) async {
      final gateway = FakeGateway()..crash = StateError('boom');
      final container = await launch(tester, api: AuthApi(), gateway: gateway);
      container.read(routerProvider).go('/signup');
      await tester.pumpAndSettle();
      await type(tester, 'Email', 'sam@example.com');
      await type(tester, 'Password', 'a-long-password');
      await tester.ensureVisible(find.byKey(const Key('signup-submit')));
      await tester.tap(find.byKey(const Key('signup-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.textContaining('StateError'), findsOneWidget);
      // The button is usable again and the person is still on the form.
      expect(location(container), '/signup');
      gateway.crash = null;
      await tester.tap(find.byKey(const Key('signup-submit')));
      await tester.pumpAndSettle();
      expect(location(container), '/verify-email');
    });

    test('An unmapped Firebase code is passed through for support', () {
      final failure = FirebaseAuthGateway.failureFor('auth/some-new-code');
      expect(failure.code, 'auth/some-new-code');
      expect(failure.message, contains('auth/some-new-code'));
    });

    testWidgets(
      'A new password account waits on the verify screen, then continues',
      (tester) async {
        final gateway = FakeGateway();
        final api = AuthApi();
        final container = await launch(tester, api: api, gateway: gateway);
        container.read(routerProvider).go('/signup');
        await tester.pumpAndSettle();
        await type(tester, 'Email', 'sam@example.com');
        await type(tester, 'Password', 'a-long-password');
        await tester.ensureVisible(find.byKey(const Key('signup-submit')));
        await tester.tap(find.byKey(const Key('signup-submit')));
        await tester.pumpAndSettle();
        expect(location(container), '/verify-email');
        expect(find.textContaining('sam@example.com'), findsOneWidget);
        // The API was never called for the unverified account.
        expect(container.read(sessionProvider).asData?.value, isNull);

        await tester.tap(find.byKey(const Key('verified-button')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('haven’t seen the verification'),
          findsOneWidget,
        );
        expect(location(container), '/verify-email');

        gateway.verifiedOnReload = true;
        await tester.tap(find.byKey(const Key('verified-button')));
        await tester.pumpAndSettle();
        expect(location(container), '/onboarding');
      },
    );

    testWidgets('Resend is rate limited on screen', (tester) async {
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.password,
          email: 'sam@example.com',
        ),
      );
      await launch(tester, api: AuthApi(), gateway: gateway);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('resend-button')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('Resend email in'), findsOneWidget);
      await tester.pump(const Duration(seconds: 46));
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('resend-button')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('resend-button')));
      await tester.pumpAndSettle();
      expect(gateway.resends, 1);
      expect(find.textContaining('Resend email in'), findsOneWidget);
    });

    testWidgets(
      'Someone can leave the verify screen with a different account',
      (tester) async {
        final gateway = FakeGateway(
          const AuthUser(
            uid: 'uid-1',
            method: AuthMethod.password,
            email: 'sam@example.com',
          ),
        );
        final container = await launch(
          tester,
          api: AuthApi(),
          gateway: gateway,
        );
        expect(location(container), '/verify-email');
        await tester.tap(find.byKey(const Key('verify-signout')));
        await tester.pumpAndSettle();
        expect(location(container), '/welcome');
        expect(gateway.user, isNull);
      },
    );
  });

  group('restoring a sign-in', () {
    testWidgets('A returning member goes straight in', (tester) async {
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.google,
          emailVerified: true,
        ),
      );
      final api = AuthApi()..onboarded = true;
      final container = await launch(tester, api: api, gateway: gateway);
      expect(location(container), '/home');
      final session = container.read(sessionProvider).asData!.value!;
      expect(session.userId, samId);
      expect(session.token, 'token-1');
      gateway.token = 'token-9';
      expect(session.token, 'token-9');
    });

    testWidgets('An account that has not finished onboarding resumes there', (
      tester,
    ) async {
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.facebook,
          emailVerified: true,
        ),
      );
      final container = await launch(tester, api: AuthApi(), gateway: gateway);
      expect(location(container), '/onboarding');
      container.read(routerProvider).go('/home');
      await tester.pumpAndSettle();
      expect(location(container), '/onboarding');
    });

    testWidgets('If the service cannot be reached the member can retry', (
      tester,
    ) async {
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.google,
          emailVerified: true,
        ),
      );
      final api = AuthApi()
        ..onboarded = true
        ..failProfileRead = true;
      final container = await launch(tester, api: api, gateway: gateway);
      expect(location(container), '/splash');
      expect(find.text('Couldn’t reach Hiyall'), findsOneWidget);
      expect(gateway.user, isNotNull);
      api.failProfileRead = false;
      await tester.tap(find.byKey(const Key('retry-session')));
      await tester.pumpAndSettle();
      expect(location(container), '/home');
    });

    testWidgets('A provider failure on retry is shown, not thrown', (
      tester,
    ) async {
      final gateway = FailingReload(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.google,
          emailVerified: true,
        ),
      );
      final api = AuthApi()
        ..onboarded = true
        ..failProfileRead = true;
      final container = await launch(tester, api: api, gateway: gateway);
      expect(location(container), '/splash');
      gateway.reloadFailure = const AuthFailure(
        'No connection. Check your network and try again.',
      );
      await tester.tap(find.byKey(const Key('retry-session')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(location(container), '/splash');
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      gateway.reloadFailure = null;
      api.failProfileRead = false;
      await tester.tap(find.byKey(const Key('retry-session')));
      await tester.pumpAndSettle();
      expect(location(container), '/home');
    });

    testWidgets('Connecting a just-verified account shows the splash', (
      tester,
    ) async {
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.password,
          email: 'sam@example.com',
          emailVerified: false,
        ),
      );
      final api = GatedAuthApi()..onboarded = true;
      final container = await launch(tester, api: api, gateway: gateway);
      expect(location(container), '/verify-email');
      gateway.verifiedOnReload = true;
      api.gate = Completer();
      final refresh = container.read(sessionProvider.notifier).refreshAuth();
      await tester.pump();
      await tester.pump();
      expect(location(container), '/splash');
      expect(find.text('Come as you are.'), findsNothing);
      api.gate!.complete();
      await refresh;
      await tester.pumpAndSettle();
      expect(location(container), '/home');
    });

    testWidgets('Re-checking a signed-in account keeps the current page', (
      tester,
    ) async {
      const user = AuthUser(
        uid: 'uid-1',
        method: AuthMethod.google,
        emailVerified: true,
      );
      final gateway = FakeGateway(user);
      final api = GatedAuthApi()..onboarded = true;
      final container = await launch(tester, api: api, gateway: gateway);
      container.read(routerProvider).go('/discover');
      await tester.pumpAndSettle();
      api.gate = Completer();
      gateway._emit(user);
      await tester.pump();
      await tester.pump();
      expect(location(container), '/discover');
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(location(container), '/discover');
      expect(container.read(sessionProvider).asData?.value?.userId, samId);
    });
  });

  group('onboarding', () {
    Future<ProviderContainer> start(
      WidgetTester tester,
      AuthApi api, [
      PhotoPicker? picker,
    ]) => launch(
      tester,
      api: api,
      overrides: [
        if (picker != null) imagePickerProvider.overrideWithValue(picker),
      ],
      gateway: FakeGateway(
        const AuthUser(
          uid: 'uid-1',
          method: AuthMethod.google,
          email: 'sam@example.com',
          displayName: 'Sam Rivera',
          emailVerified: true,
        ),
      ),
    );

    testWidgets(
      'Continue stays off until a birth date and the terms are given',
      (tester) async {
        final container = await start(tester, AuthApi());
        expect(location(container), '/onboarding');
        expect(find.text('First, the basics'), findsOneWidget);
        FilledButton button() =>
            tester.widget<FilledButton>(find.byKey(const Key('onb-next')));
        expect(button().onPressed, isNull);
        await chooseBirthDate(tester);
        expect(button().onPressed, isNull);
        await tester.tap(find.byKey(const Key('onb-terms')));
        await tester.pump();
        expect(button().onPressed, isNotNull);
      },
    );

    testWidgets(
      'A complete walk-through saves the profile, privacy and age check once',
      (tester) async {
        final api = AuthApi();
        final container = await start(tester, api);
        await fillOnboarding(tester);
        await next(tester, 'onb-finish');

        expect(api.checked, ['sam_r']);
        expect(api.profilePatch, {
          'displayName': 'Sam Rivera',
          'username': 'sam_r',
          'languages': <Object>[],
          'interests': ['Music', 'Art', 'Travel'],
        });
        // There are no privacy choices in onboarding any more.
        expect(api.privacyPatch, isNull);
        expect(api.completed!['birthDate'], startsWith('2000-'));
        expect(api.completed!['termsVersion'], '2026-10-01');
        expect(api.ageChecks, [api.completed!['birthDate']]);
        expect(
          container.read(sessionProvider).asData!.value!.onboarded,
          isTrue,
        );
        expect(location(container), '/home');
      },
    );

    testWidgets(
      'A terms revision this build does not show is never accepted for the person',
      (tester) async {
        final api = AuthApi()..termsVersion = '2099-01-01';
        final container = await start(tester, api);
        await fillOnboarding(tester);
        await next(tester, 'onb-finish');

        expect(
          find.textContaining('terms have changed since this version'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Update the app to continue'),
          findsOneWidget,
        );
        expect(api.completed, isNull, reason: 'nothing was accepted');
        expect(
          container.read(sessionProvider).asData!.value!.onboarded,
          isFalse,
        );
        expect(location(container), '/onboarding');
      },
    );

    testWidgets('The name and username are prefilled from the provider', (
      tester,
    ) async {
      await start(tester, AuthApi());
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      expect(find.widgetWithText(TextFormField, 'Sam Rivera'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'sam_rivera'), findsOneWidget);
    });

    testWidgets('A taken username is reported before moving on', (
      tester,
    ) async {
      final api = AuthApi()..usernameFree = false;
      await start(tester, api);
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      await next(tester);
      expect(find.text('That username is taken. Try another.'), findsOneWidget);
      expect(find.text('Make it yours'), findsOneWidget);
      api.usernameFree = true;
      await next(tester);
      expect(find.text('Add a photo'), findsOneWidget);
      await next(tester);
      expect(find.text('A bit about you'), findsOneWidget);
    });

    testWidgets(
      'Usernames outside the allowed characters are rejected locally',
      (tester) async {
        final api = AuthApi();
        await start(tester, api);
        await chooseBirthDate(tester);
        await tester.tap(find.byKey(const Key('onb-terms')));
        await tester.pump();
        await next(tester);
        await type(tester, 'Username', 'Not Allowed!');
        await next(tester);
        expect(
          find.textContaining('lowercase letters, numbers or underscores'),
          findsWidgets,
        );
        expect(api.checked, isEmpty);
      },
    );

    testWidgets('Common languages are one tap and the rest are searchable', (
      tester,
    ) async {
      final api = AuthApi();
      await start(tester, api);
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      await next(tester);
      await next(tester);
      await tester.tap(find.widgetWithText(FilterChip, 'English'));
      await tester.tap(find.widgetWithText(FilterChip, 'Hindi'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, 'Hindi'));
      await tester.pump();
      expect(find.byKey(const Key('onb-language')), findsOneWidget);
      await next(tester);
      for (final interest in ['Music', 'Art', 'Travel']) {
        await tester.tap(find.widgetWithText(FilterChip, interest));
        await tester.pump();
      }
      await next(tester, 'onb-finish');
      expect(api.profilePatch!['languages'], [
        {'code': 'en'},
      ]);
    });

    testWidgets('Gender is optional and is saved only when chosen', (
      tester,
    ) async {
      final api = AuthApi();
      await start(tester, api);
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      await next(tester);
      await next(tester);
      await tester.tap(find.byKey(const Key('onb-gender-nonbinary')));
      await tester.pump();
      await next(tester);
      for (final interest in ['Music', 'Art', 'Travel']) {
        await tester.tap(find.widgetWithText(FilterChip, interest));
        await tester.pump();
      }
      await next(tester, 'onb-finish');
      expect(api.profilePatch!['gender'], 'nonbinary');
    });

    testWidgets('Leaving gender blank sends no gender', (tester) async {
      final api = AuthApi();
      await start(tester, api);
      await fillOnboarding(tester);
      await next(tester, 'onb-finish');
      expect(api.profilePatch!.keys, isNot(contains('gender')));
    });

    testWidgets('At least three interests are needed', (tester) async {
      await start(tester, AuthApi());
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      await next(tester);
      await tester.tap(find.byKey(const Key('onb-skip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onb-skip')));
      await tester.pumpAndSettle();
      FilledButton button() =>
          tester.widget<FilledButton>(find.byKey(const Key('onb-finish')));
      expect(button().onPressed, isNull);
      await tester.tap(find.widgetWithText(FilterChip, 'Music'));
      await tester.tap(find.widgetWithText(FilterChip, 'Art'));
      await tester.pump();
      expect(button().onPressed, isNull);
      await tester.tap(find.widgetWithText(FilterChip, 'Travel'));
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('Back keeps what was entered', (tester) async {
      await start(tester, AuthApi());
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      await type(tester, 'Display name', 'Samantha');
      await tester.tap(find.byKey(const Key('onb-back')));
      await tester.pumpAndSettle();
      expect(find.text('First, the basics'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('onb-next')))
            .onPressed,
        isNotNull,
      );
      await next(tester);
      expect(find.widgetWithText(TextFormField, 'Samantha'), findsOneWidget);
    });

    testWidgets(
      'The server refusing the age check ends onboarding with a clear page',
      (tester) async {
        final api = AuthApi()
          ..completeFailure = const ApiFailure(
            'Hiyall is for people 18 and over.',
            403,
            'AGE_REQUIREMENT_NOT_MET',
          );
        final container = await start(tester, api);
        await fillOnboarding(tester);
        await next(tester, 'onb-finish');
        expect(find.byKey(const Key('onb-underage')), findsOneWidget);
        expect(
          container.read(sessionProvider).asData!.value!.onboarded,
          isFalse,
        );
        expect(location(container), '/onboarding');
      },
    );

    testWidgets('The date picker opens neutral, with no suggested age', (
      tester,
    ) async {
      await start(tester, AuthApi());
      await tester.tap(find.byKey(const Key('onb-dob')));
      await tester.pumpAndSettle();
      final year = DateTime.now().year.toString();
      // It opens in the year list on the current year, not on an adult default.
      expect(find.text(year), findsWidgets);
      expect(find.text('${DateTime.now().year - 25}'), findsNothing);
    });

    testWidgets('The birth date goes to the server when Continue is tapped', (
      tester,
    ) async {
      final api = AuthApi();
      await start(tester, api);
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      expect(api.ageChecks, hasLength(1));
      expect(api.ageChecks.single, startsWith('2000-'));
      expect(find.text('Make it yours'), findsOneWidget);
    });

    testWidgets(
      'A date under 13 is not blocked on the device: the server refuses',
      (tester) async {
        final api = AuthApi()
          ..ageFailure = const ApiFailure(
            'Hiyall is for people 13 and over.',
            403,
            'AGE_REQUIREMENT_NOT_MET',
          );
        await start(tester, api);
        await chooseBirthDate(tester, year: '${DateTime.now().year - 10}');
        await tester.tap(find.byKey(const Key('onb-terms')));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('onb-next')))
              .onPressed,
          isNotNull,
        );
        await next(tester);
        expect(api.ageChecks, hasLength(1));
        expect(find.byKey(const Key('onb-underage')), findsOneWidget);
        expect(find.textContaining('try again in a few days'), findsNothing);
      },
    );

    testWidgets('A repeat after a refusal shows the calm cooldown message', (
      tester,
    ) async {
      final api = AuthApi()
        ..ageFailure = const ApiFailure(
          'You can’t finish signing up right now.',
          403,
          'AGE_GATE_COOLDOWN',
        );
      await start(tester, api);
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      expect(find.byKey(const Key('onb-underage')), findsOneWidget);
      expect(find.textContaining('try again in a few days'), findsOneWidget);
    });

    testWidgets('A username taken at the last moment returns to that step', (
      tester,
    ) async {
      final api = AuthApi()
        ..updateFailure = const ApiFailure(
          'That username is already taken.',
          409,
        );
      final container = await start(tester, api);
      await fillOnboarding(tester);
      await next(tester, 'onb-finish');
      expect(find.text('Make it yours'), findsOneWidget);
      expect(find.textContaining('just taken'), findsOneWidget);
      expect(container.read(sessionProvider).asData!.value!.onboarded, isFalse);
    });

    testWidgets('A failed save keeps the answers and can be retried', (
      tester,
    ) async {
      final api = AuthApi()
        ..updateFailure = const ApiFailure(
          'Could not connect. Check your connection and retry.',
        );
      final container = await start(tester, api);
      await fillOnboarding(tester);
      await next(tester, 'onb-finish');
      expect(find.byKey(const Key('onb-error')), findsOneWidget);
      expect(api.completed, isNull);
      api.updateFailure = null;
      await next(tester, 'onb-finish');
      expect(api.completed, isNotNull);
      expect(container.read(sessionProvider).asData!.value!.onboarded, isTrue);
    });

    /// Walks to the photo step: age, then name.
    Future<void> toPhotoStep(WidgetTester tester) async {
      await chooseBirthDate(tester);
      await tester.tap(find.byKey(const Key('onb-terms')));
      await tester.pump();
      await next(tester);
      await next(tester);
      expect(find.text('Add a photo'), findsOneWidget);
    }

    Future<void> choosePhoto(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('onb-photo-choose')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-gallery')));
      await tester.pumpAndSettle();
    }

    /// From the "about you" step: skip it, pick interests, finish.
    Future<void> interestsAndFinish(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('onb-skip')));
      await tester.pumpAndSettle();
      for (final interest in ['Music', 'Art', 'Travel']) {
        await tester.tap(find.widgetWithText(FilterChip, interest));
        await tester.pump();
      }
      await next(tester, 'onb-finish');
    }

    const photoFailure =
        'We couldn’t upload your photo. You can add it from your profile.';

    testWidgets('The photo step sits after the name and the counter follows', (
      tester,
    ) async {
      await start(tester, AuthApi());
      expect(find.text('STEP 1 OF 5'), findsOneWidget);
      await toPhotoStep(tester);
      expect(find.text('STEP 3 OF 5'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 3 of 5'), findsOneWidget);
      expect(find.byKey(const Key('onb-photo')), findsOneWidget);
      expect(find.byKey(const Key('onb-photo-choose')), findsOneWidget);
      expect(find.byKey(const Key('onb-photo-remove')), findsNothing);
      expect(find.byKey(const Key('onb-skip')), findsOneWidget);
      expect(find.textContaining('public'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onb-skip')));
      await tester.pumpAndSettle();
      expect(find.text('STEP 4 OF 5'), findsOneWidget);
      await next(tester);
      expect(find.text('STEP 5 OF 5'), findsOneWidget);
      expect(find.byKey(const Key('onb-finish')), findsOneWidget);
    });

    testWidgets('Skipping the photo saves and uploads nothing extra', (
      tester,
    ) async {
      final api = AuthApi();
      final picker = PhotoPicker();
      final container = await start(tester, api, picker);
      await toPhotoStep(tester);
      await tester.tap(find.byKey(const Key('onb-skip')));
      await tester.pumpAndSettle();
      await interestsAndFinish(tester);
      expect(picker.sources, isEmpty);
      expect(api.calls, ['profile', 'complete']);
      expect(location(container), '/home');
      expect(find.text(photoFailure), findsNothing);
    });

    testWidgets('A chosen photo is previewed, removable and kept across Back', (
      tester,
    ) async {
      final picker = PhotoPicker()..bytes = pngBytes;
      final api = AuthApi();
      await start(tester, api, picker);
      await toPhotoStep(tester);
      await choosePhoto(tester);
      expect(picker.sources, [ImageSource.gallery]);
      PersonAvatar avatar() =>
          tester.widget<PersonAvatar>(find.byType(PersonAvatar));
      expect(avatar().bytes, pngBytes);
      expect(find.byKey(const Key('onb-photo-remove')), findsOneWidget);
      // Nothing is sent while onboarding is still open.
      expect(api.calls, isEmpty);
      // Once chosen, Continue is the way on rather than Skip.
      expect(find.byKey(const Key('onb-skip')), findsNothing);
      await tester.tap(find.byKey(const Key('onb-back')));
      await tester.pumpAndSettle();
      await next(tester);
      expect(avatar().bytes, pngBytes);
      await tester.tap(find.byKey(const Key('onb-photo-remove')));
      await tester.pumpAndSettle();
      expect(avatar().bytes, isNull);
      expect(find.byKey(const Key('onb-photo-remove')), findsNothing);
      expect(find.byKey(const Key('onb-skip')), findsOneWidget);
    });

    testWidgets('A refused photo is explained and nothing is kept', (
      tester,
    ) async {
      final picker = PhotoPicker()
        ..bytes = Uint8List.fromList('GIF89a........'.codeUnits);
      await start(tester, AuthApi(), picker);
      await toPhotoStep(tester);
      await choosePhoto(tester);
      expect(find.text('Use a JPEG, PNG or WebP photo.'), findsOneWidget);
      expect(find.byKey(const Key('onb-photo-remove')), findsNothing);
    });

    testWidgets('A chosen photo uploads only after onboarding completes', (
      tester,
    ) async {
      final picker = PhotoPicker()..bytes = pngBytes;
      final api = AuthApi();
      final container = await start(tester, api, picker);
      await toPhotoStep(tester);
      await choosePhoto(tester);
      await next(tester);
      await interestsAndFinish(tester);
      // The photo follows the age check; media routes would refuse it before.
      expect(api.calls, [
        'profile',
        'complete',
        'upload avatar image/png ${pngBytes.length}',
        'attach media-1',
      ]);
      expect(api.patches.single, {'avatarMediaId': 'media-1'});
      expect(container.read(sessionProvider).asData!.value!.onboarded, isTrue);
      expect(location(container), '/home');
      expect(find.text(photoFailure), findsNothing);
    });

    for (final (label, setup) in <(String, void Function(AuthApi))>[
      ('upload fails', (api) => api.uploadFailure = const ApiFailure('x')),
      (
        'upload hits the daily limit',
        (api) => api.uploadFailure = const ApiFailure(
          'You’ve reached today’s photo upload limit. Try again later.',
          429,
          'QUOTA',
        ),
      ),
      (
        'attaching fails',
        (api) => api.attachFailure = const ApiFailure('x', 500),
      ),
    ]) {
      testWidgets('If the photo $label onboarding still finishes', (
        tester,
      ) async {
        final picker = PhotoPicker()..bytes = pngBytes;
        final api = AuthApi();
        setup(api);
        final container = await start(tester, api, picker);
        await toPhotoStep(tester);
        await choosePhoto(tester);
        await next(tester);
        await interestsAndFinish(tester);
        expect(api.completed, isNotNull);
        expect(
          container.read(sessionProvider).asData!.value!.onboarded,
          isTrue,
        );
        expect(location(container), '/home');
        expect(find.byKey(const Key('onb-error')), findsNothing);
        expect(find.text(photoFailure), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
      });
    }

    testWidgets(
      'Onboarding failing before completion never touches the photo',
      (tester) async {
        final picker = PhotoPicker()..bytes = pngBytes;
        final api = AuthApi()
          ..completeFailure = const ApiFailure('Could not connect.');
        final container = await start(tester, api, picker);
        await toPhotoStep(tester);
        await choosePhoto(tester);
        await next(tester);
        await interestsAndFinish(tester);
        expect(find.byKey(const Key('onb-error')), findsOneWidget);
        expect(api.calls.where((c) => c.startsWith('upload')), isEmpty);
        expect(
          container.read(sessionProvider).asData!.value!.onboarded,
          isFalse,
        );
        // Retrying runs the sequence again and the photo follows.
        api.completeFailure = null;
        await next(tester, 'onb-finish');
        expect(api.calls.last, 'attach media-1');
        expect(location(container), '/home');
      },
    );

    testWidgets('Someone can sign out in the middle of onboarding', (
      tester,
    ) async {
      final api = AuthApi();
      final container = await start(tester, api);
      await tester.tap(find.byKey(const Key('onb-signout')));
      await tester.pumpAndSettle();
      expect(location(container), '/welcome');
    });
  });
}
