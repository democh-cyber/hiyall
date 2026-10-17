import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/system_screens.dart';

import 'auth_test.dart' show location;
import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

void main() {
  Future<ProviderContainer> app(WidgetTester tester, {ApiClient? api}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        if (api != null) apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const HiyallApp()),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the real API client raises the App Check flag', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appCheckRequiredProvider), isFalse);
    container.read(apiProvider).onAppCheckRequired!();
    expect(container.read(appCheckRequiredProvider), isTrue);
  });

  testWidgets(
    'a refused app shows "Update or verify this app" and keeps the session',
    (tester) async {
      final container = await app(tester, api: FakeApi());
      expect(location(container), '/home');
      container.read(appCheckRequiredProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(location(container), '/verify-app');
      expect(find.text('Update or verify this app'), findsOneWidget);
      expect(find.textContaining('still signed in'), findsOneWidget);
      expect(find.byKey(const Key('verify-try-again')), findsOneWidget);
      // Nothing signed out, nothing marked as expired.
      expect(container.read(sessionProvider).asData?.value?.userId, anjaliId);
      expect(container.read(sessionExpiredProvider), isFalse);
      // No way around it by navigation.
      container.read(routerProvider).go('/profile/settings');
      await tester.pumpAndSettle();
      expect(location(container), '/verify-app');
      // Try again clears it and goes back.
      await tester.tap(find.byKey(const Key('verify-try-again')));
      await tester.pumpAndSettle();
      expect(container.read(appCheckRequiredProvider), isFalse);
      expect(location(container), '/home');
      expect(container.read(sessionProvider).asData?.value?.userId, anjaliId);
    },
  );

  for (final rtl in [false, true]) {
    testWidgets(
      'the screen fits 320 wide at double text (${rtl ? 'right to left' : 'left to right'})',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: hiyallTheme(Brightness.light),
              builder: (context, child) => Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: child!,
              ),
              home: const AppCheckRequiredScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const Key('verify-try-again'))).height,
          greaterThanOrEqualTo(48),
        );
        // Reachable by scrolling, nothing clipped off the side.
        await tester.ensureVisible(find.byKey(const Key('verify-try-again')));
        final box = tester.getRect(find.byKey(const Key('verify-try-again')));
        expect(box.left, greaterThanOrEqualTo(0));
        expect(box.right, lessThanOrEqualTo(320));
      },
    );
  }
}
