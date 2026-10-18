import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/billing/billing_models.dart';
import 'package:hiyall/core/billing/billing_state.dart';
import 'package:hiyall/core/user_error.dart';
import 'package:hiyall/features/shop/locked_feature_sheet.dart';
import 'package:hiyall/features/shop/profile_details_card.dart';
import 'package:hiyall/features/shop/spend_gate.dart';

import 'support/billing_fakes.dart';

/// Renders the Shop and its sheets with realistic fake data and writes PNGs to `.runtime/shop-previews-v7/` (git-ignored). Skipped unless run with
/// `--dart-define=CAPTURE_SHOP=true`.
const capturing = bool.fromEnvironment('CAPTURE_SHOP');

Future<void> clearAll(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<void> shoot(WidgetTester tester, GlobalKey key, String name) async {
    void repaint(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(repaint);
    }

    repaint(key.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.runtime/shop-previews-v7/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<ProviderContainer> open(
    WidgetTester tester,
    GlobalKey key, {
    FakeBilling? billing,
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection? direction,
    Widget? shop,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (textScale != 1) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    final container = ProviderContainer(
      overrides: [
        ...billingOverrides(
          billing: billing ?? FakeBilling(),
          launches: Launches(),
        ),
        premiumRequiredHandlerProvider.overrideWithValue(
          (context, feature) =>
              showLockedFeatureSheet(context, feature: feature),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(billingStateProvider.future);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(
      shopApp(
        container: container,
        brightness: brightness,
        direction: direction,
        captureKey: key,
        shop: shop,
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('Shop screens', (tester) async {
    if (!capturing) return;
    final key = GlobalKey();
    final billing = FakeBilling(billingJson(balance: 12))
      ..historyPages.add(
        LedgerPage([
          LedgerEntry(
            '4',
            'spend_chat_slot',
            -2,
            12,
            DateTime.utc(2026, 10, 17),
          ),
          LedgerEntry('3', 'reward_ad', 1, 14, DateTime.utc(2026, 10, 16)),
          LedgerEntry('2', 'purchase', 130, 13, DateTime.utc(2026, 10, 15)),
          LedgerEntry(
            '1',
            'profile_completion',
            5,
            5,
            DateTime.utc(2026, 10, 14),
          ),
        ], null),
      );
    await open(tester, key, billing: billing);
    await shoot(tester, key, '01-shop-top');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -620));
    await tester.pumpAndSettle();
    await shoot(tester, key, '02-shop-premium-and-table');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await shoot(tester, key, '03-shop-earn-and-history');
    await clearAll(tester);
  });

  testWidgets(
    'Shop dark, narrow with large text, right to left, active Premium',
    (tester) async {
      if (!capturing) return;
      final key = GlobalKey();
      await open(tester, key, brightness: Brightness.dark);
      await shoot(tester, key, '04-shop-dark');
      await open(tester, key, size: const Size(320, 640), textScale: 2.0);
      await shoot(tester, key, '05-shop-320-text-2x');
      await open(tester, key, direction: TextDirection.rtl);
      await shoot(tester, key, '06-shop-rtl');
      final premium = billingJson(
        plan: {
          'id': 'premium',
          'status': 'active',
          'store': 'google_play',
          'productId': 'premium_3m',
          'currentPeriodEnd': '2026-12-01T00:00:00Z',
          'autoRenew': true,
          'graceUntil': null,
        },
      );
      await open(tester, key, billing: FakeBilling(premium));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -620));
      await tester.pumpAndSettle();
      await shoot(tester, key, '07-shop-premium-active');
      await clearAll(tester);
    },
  );

  testWidgets('Sheets', (tester) async {
    if (!capturing) return;
    final key = GlobalKey();
    final host = Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                key: const Key('a'),
                onPressed: () => showFailure(
                  context,
                  const ApiFailureDetails(
                    'This is part of Premium.',
                    402,
                    'PREMIUM_REQUIRED',
                    {'feature': 'genderFilter'},
                  ),
                ),
                child: const Text('locked'),
              ),
              FilledButton(
                key: const Key('b'),
                onPressed: () => confirmSpend(
                  context,
                  title: 'Start this chat?',
                  what: 'You’ve started all your free chats for today. Another one costs coins, or you can wait until tomorrow.',
                  cost: 2,
                  balance: 5,
                ),
                child: const Text('spend'),
              ),
              FilledButton(
                key: const Key('c'),
                onPressed: () => confirmSpend(
                  context,
                  title: 'Start this chat?',
                  what: 'You’ve started all your free chats for today. Another one costs coins, or you can wait until tomorrow.',
                  cost: 2,
                  balance: 1,
                ),
                child: const Text('short'),
              ),
            ],
          ),
        ),
      ),
    );
    await open(tester, key, shop: host);
    await tester.tap(find.byKey(const Key('a')));
    await tester.pumpAndSettle();
    await shoot(tester, key, '08-locked-feature-sheet');
    await tester.tap(find.byKey(const Key('locked-not-now')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('b')));
    await tester.pumpAndSettle();
    await shoot(tester, key, '09-spend-confirmation');
    await tester.tap(find.byKey(const Key('spend-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('c')));
    await tester.pumpAndSettle();
    await shoot(tester, key, '10-spend-not-enough-coins');
    await tester.tap(find.byKey(const Key('spend-cancel')));
    await tester.pumpAndSettle();
    await open(
      tester,
      key,
      shop: const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: ProfileDetailsLockedCard(
              userId: '019a4000-0000-7000-8000-000000000002',
            ),
          ),
        ),
      ),
    );
    await shoot(tester, key, '11-profile-details-locked');
    await clearAll(tester);
  });
}
