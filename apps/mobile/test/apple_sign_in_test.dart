import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/auth/firebase_config.dart';
import 'package:hiyall/core/auth/firebase_gateway.dart';
import 'package:hiyall/features/auth/auth_widgets.dart' show SocialSignIn;

import 'auth_test.dart' show AuthApi, FakeGateway, launch, location;

/// Runs [body] as if the app were running on [platform], restoring the real one
/// before the framework checks that tests clean up after themselves.
Future<void> onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('when the Apple button shows', () {
    test('iOS and macOS always show it', () {
      expect(
        AuthProviders.appleAvailable(platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        AuthProviders.appleAvailable(platform: TargetPlatform.macOS),
        isTrue,
      );
      // The web flag has no bearing on a native build.
      expect(
        AuthProviders.appleAvailable(
          platform: TargetPlatform.iOS,
          webEnabled: false,
        ),
        isTrue,
      );
    });

    test('Android, Linux, Windows and Fuchsia never show it', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          AuthProviders.appleAvailable(platform: platform, webEnabled: true),
          isFalse,
          reason: '$platform',
        );
      }
    });

    test('the web shows it only when the build sets APPLE_SIGN_IN_WEB', () {
      expect(AuthProviders.appleAvailable(web: true, webEnabled: true), isTrue);
      expect(
        AuthProviders.appleAvailable(web: true, webEnabled: false),
        isFalse,
      );
      // Not set in this test run, so the default is off.
      expect(AuthProviders.appleWeb, isFalse);
      expect(AuthProviders.appleAvailable(web: true), isFalse);
      // A web build ignores the native platform.
      expect(
        AuthProviders.appleAvailable(
          web: true,
          platform: TargetPlatform.iOS,
          webEnabled: false,
        ),
        isFalse,
      );
    });

    test('it is hidden by default in tests', () {
      expect(AuthProviders.appleAvailable(), isFalse);
    });

    Widget host({bool? showApple, VoidCallback? onApple}) => MaterialApp(
      home: Scaffold(
        body: SocialSignIn(
          enabled: true,
          showApple: showApple,
          onApple: onApple,
          onGoogle: () {},
          onFacebook: () {},
        ),
      ),
    );

    testWidgets('the widget hides it unless injected', (tester) async {
      await tester.pumpWidget(host(onApple: () {}));
      expect(find.byKey(const Key('apple-button')), findsNothing);
      await tester.pumpWidget(host(showApple: false, onApple: () {}));
      expect(find.byKey(const Key('apple-button')), findsNothing);
      // Without a handler there is nothing for it to do.
      await tester.pumpWidget(host(showApple: true));
      expect(find.byKey(const Key('apple-button')), findsNothing);
      var taps = 0;
      await tester.pumpWidget(host(showApple: true, onApple: () => taps++));
      expect(find.text('Continue with Apple'), findsOneWidget);
      await tester.tap(find.byKey(const Key('apple-button')));
      expect(taps, 1);
    });

    testWidgets('the real screens follow the platform', (tester) async {
      final api = AuthApi();
      await onPlatform(TargetPlatform.iOS, () async {
        final container = await launch(tester, api: api);
        container.read(routerProvider).go('/login');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('apple-button')), findsOneWidget);
        container.read(routerProvider).go('/signup');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('apple-button')), findsOneWidget);
      });
      // Android, the default platform of a test run, hides it.
      final container = await launch(tester, api: api);
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('google-button')), findsOneWidget);
      expect(find.byKey(const Key('apple-button')), findsNothing);
    });

    testWidgets('it stays legible in light and dark and is a 48 dp target', (
      tester,
    ) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: SocialSignIn(
                enabled: true,
                showApple: true,
                onApple: () {},
                onGoogle: () {},
                onFacebook: () {},
              ),
            ),
          ),
        );
        final button = tester.widget<FilledButton>(
          find.byKey(const Key('apple-button')),
        );
        final style = button.style!;
        final background = style.backgroundColor!.resolve({})!;
        final foreground = style.foregroundColor!.resolve({})!;
        expect(
          background.computeLuminance() == foreground.computeLuminance(),
          isFalse,
        );
        // Black on white or white on black is the highest contrast there is.
        expect(
          (background.computeLuminance() - foreground.computeLuminance()).abs(),
          closeTo(1, .001),
        );
        expect(
          tester.getSize(find.byKey(const Key('apple-button'))).height,
          greaterThanOrEqualTo(48),
        );
      }
    });
  });

  group('signing in', () {
    Future<(ProviderContainer, FakeGateway, AuthApi)> openLogin(
      WidgetTester tester,
    ) async {
      final gateway = FakeGateway();
      final api = AuthApi();
      final container = await launch(tester, api: api, gateway: gateway);
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      return (container, gateway, api);
    }

    Future<void> tapApple(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('apple-button')));
      await tester.tap(find.byKey(const Key('apple-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('a first Apple sign-in goes through the same onboarding', (
      tester,
    ) async {
      await onPlatform(TargetPlatform.iOS, () async {
        final (container, gateway, api) = await openLogin(tester);
        await tapApple(tester);
        expect(gateway.user?.method, AuthMethod.apple);
        expect(location(container), '/onboarding');
        expect(find.text('First, the basics'), findsOneWidget);
        expect(api.completed, isNull);
        // Nothing is skipped: the date of birth and the terms still gate it.
        final next = tester.widget<FilledButton>(
          find.byKey(const Key('onb-next')),
        );
        expect(next.onPressed, isNull);
      });
    });

    testWidgets('Apple hide-my-email addresses need no verification step', (
      tester,
    ) async {
      await onPlatform(TargetPlatform.iOS, () async {
        const relay = AuthUser(
          uid: 'apple-uid',
          method: AuthMethod.apple,
          email: 'x1y2z3@privaterelay.appleid.com',
          emailVerified: false,
        );
        expect(relay.needsEmailVerification, isFalse);
        final container = await launch(
          tester,
          api: AuthApi(),
          gateway: FakeGateway(relay),
        );
        // Straight to onboarding, never held on the verify-email page.
        expect(location(container), '/onboarding');
      });
    });

    testWidgets('an Apple account without any email address signs in too', (
      tester,
    ) async {
      await onPlatform(TargetPlatform.iOS, () async {
        final container = await launch(
          tester,
          api: AuthApi(),
          gateway: FakeGateway(
            const AuthUser(uid: 'apple-uid', method: AuthMethod.apple),
          ),
        );
        expect(location(container), '/onboarding');
      });
    });

    testWidgets('closing the Apple sheet shows nothing and changes nothing', (
      tester,
    ) async {
      await onPlatform(TargetPlatform.iOS, () async {
        final (container, gateway, _) = await openLogin(tester);
        gateway.failure = const AuthFailure(
          '',
          code: 'cancelled',
          cancelled: true,
        );
        await tapApple(tester);
        expect(location(container), '/login');
        expect(gateway.user, isNull);
        expect(find.byKey(const Key('auth-error')), findsNothing);
        // The button works again afterwards.
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('apple-button')))
              .onPressed,
          isNotNull,
        );
      });
    });

    testWidgets('a provider error is shown in plain words', (tester) async {
      await onPlatform(TargetPlatform.iOS, () async {
        final (container, gateway, _) = await openLogin(tester);
        gateway.failure = const AuthFailure(
          'This sign-in method isn’t enabled yet.',
          code: 'operation-not-allowed',
        );
        await tapApple(tester);
        expect(location(container), '/login');
        expect(
          find.text('This sign-in method isn’t enabled yet.'),
          findsOneWidget,
        );
      });
    });
  });

  group('error copy', () {
    test('cancelling is not an error, whichever way Firebase says it', () {
      for (final code in [
        'canceled',
        'user-cancelled',
        'web-context-canceled',
        'web-context-cancelled',
        'popup-closed-by-user',
        'cancelled-popup-request',
      ]) {
        final failure = FirebaseAuthGateway.failureFor(code);
        expect(failure.cancelled, isTrue, reason: code);
        expect(failure.message, isEmpty, reason: code);
      }
    });

    test('real problems get friendly, specific copy', () {
      expect(
        FirebaseAuthGateway.failureFor('operation-not-allowed').message,
        contains('isn’t enabled yet'),
      );
      expect(
        FirebaseAuthGateway.failureFor(
          'account-exists-with-different-credential',
        ).message,
        contains('Log in with the method you used first'),
      );
      expect(
        FirebaseAuthGateway.failureFor('network-request-failed').message,
        contains('Check your connection'),
      );
      final unknown = FirebaseAuthGateway.failureFor('weird-apple-thing');
      expect(unknown.cancelled, isFalse);
      expect(unknown.message, contains('weird-apple-thing'));
    });

    test('an unconfigured build explains itself', () async {
      await expectLater(
        const UnconfiguredAuthGateway().signInWithApple(),
        throwsA(
          isA<AuthFailure>().having((f) => f.code, 'code', 'not-configured'),
        ),
      );
    });
  });
}
