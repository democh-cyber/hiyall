import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/billing/billing_models.dart';
import 'package:hiyall/core/billing/billing_state.dart';
import 'package:hiyall/core/billing/purchase_service.dart'
    show StorePurchaseStatus;
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/features/settings.dart' show SettingsScreen;
import 'package:hiyall/features/shop/coin_pill.dart';
import 'package:hiyall/features/shop/locked_feature_sheet.dart';
import 'package:hiyall/features/shop/profile_details_card.dart';
import 'package:hiyall/features/shop/settings_billing_tile.dart';
import 'package:hiyall/features/shop/spend_gate.dart';
import 'package:hiyall/core/user_error.dart';

import 'support/billing_fakes.dart';

/// Unmounts what an earlier pump in the same test left, so provider disposal timers run before the next tree.
Future<void> clearTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Map<String, dynamic> minorJson() => billingJson(
  monetizable: false,
  reason: 'minor',
  locksApply: false,
  shop: false,
  ads: false,
);

Future<ProviderContainer> pumpShop(
  WidgetTester tester, {
  FakeBilling? billing,
  FakePurchases? purchases,
  FakeAds? ads,
  Launches? launches,
  Size size = const Size(390, 3600),
  double textScale = 1,
  TextDirection? direction,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
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
    overrides: billingOverrides(
      billing: billing ?? FakeBilling(),
      purchases: purchases,
      ads: ads,
      launches: launches,
    ),
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    shopApp(
      container: container,
      direction: direction,
      reduceMotion: reduceMotion,
      brightness: brightness,
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'an adult sees the coins, the plans, the table, the earn rows, restore and the history',
    (tester) async {
      final billing = FakeBilling()
        ..historyPages.add(
          LedgerPage([
            LedgerEntry(
              '2',
              'spend_chat_slot',
              -2,
              5,
              DateTime.utc(2026, 10, 17),
            ),
            LedgerEntry('1', 'purchase', 40, 7, DateTime.utc(2026, 10, 16)),
          ], null),
        );
      await pumpShop(tester, billing: billing);
      expect(find.byKey(const Key('shop')), findsOneWidget);
      expect(find.byKey(const Key('coin-pill')), findsOneWidget);
      expect(find.text('7'), findsWidgets);
      for (final id in ['coins_s', 'coins_m', 'coins_l', 'coins_xl']) {
        expect(find.byKey(Key('pack-$id')), findsOneWidget);
      }
      // The prices are the store's, and what is bought is stated.
      expect(find.text(r'$2.99'), findsOneWidget);
      expect(find.text('130 coins'), findsOneWidget);
      expect(find.textContaining('120 plus 10 extra'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('plan-premium_12m')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining(r'$34.99 every 1 year'), findsOneWidget);
      expect(find.textContaining('cancel it'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('benefits-table')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Start new chats'), findsOneWidget);
      expect(find.text('3 a day'), findsOneWidget);
      expect(find.text('Unlimited'), findsOneWidget);
      expect(find.text('1 coin each, for 30 days'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('earn-ad')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Watch a short video for 1 coin'), findsOneWidget);
      expect(find.text('4 left today'), findsOneWidget);
      expect(find.byKey(const Key('earn-profile')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('history')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Started an extra chat'), findsOneWidget);
      expect(find.text('-2'), findsOneWidget);
      expect(find.text('+40'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('restore-purchases')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('restore-purchases')), findsOneWidget);
      expect(
        find.byKey(const Key('manage-subscription')),
        findsNothing,
        reason: 'no subscription yet',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a minor, an unknown age and a failed read get nothing and are sent away or told to retry',
    (tester) async {
      await pumpShop(tester, billing: FakeBilling(minorJson()));
      expect(
        find.byKey(const Key('home')),
        findsOneWidget,
        reason: 'sent away',
      );
      expect(find.byKey(const Key('shop')), findsNothing);
      expect(find.byKey(const Key('coin-pill')), findsNothing);
      final unknown = billingJson(
        monetizable: false,
        reason: 'age_unknown',
        locksApply: true,
        shop: true,
      );
      await pumpShop(tester, billing: FakeBilling(unknown));
      expect(find.byKey(const Key('home')), findsOneWidget);
      expect(find.byKey(const Key('pack-coins_s')), findsNothing);
      // Not enforced (the beta): no shop either.
      await pumpShop(
        tester,
        billing: FakeBilling(
          billingJson(
            enforced: false,
            locksApply: false,
            shop: false,
            ads: false,
          ),
        ),
      );
      expect(find.byKey(const Key('home')), findsOneWidget);
      // A failed read: nothing of the shop, a retry.
      await pumpShop(
        tester,
        billing: FakeBilling()
          ..stateError = const ApiFailure('You’re offline.'),
      );
      expect(find.byKey(const Key('shop')), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      // No store on this platform (web, desktop): sent away.
      await pumpShop(tester, purchases: FakePurchases()..supported = false);
      expect(find.byKey(const Key('home')), findsOneWidget);
    },
  );

  testWidgets(
    'buying a pack starts the store purchase and a successful verify shows the new balance',
    (tester) async {
      final billing = FakeBilling();
      final purchases = FakePurchases();
      final container = await pumpShop(
        tester,
        billing: billing,
        purchases: purchases,
      );
      await tester.tap(find.byKey(const Key('buy-coins_m')));
      await tester.pump();
      expect(purchases.bought.single, startsWith('coins_m:coins:'));
      billing.json = billingJson(balance: 137);
      purchases.emit('coins_m', StorePurchaseStatusForTest.purchased);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shop-message')), findsOneWidget);
      expect(find.text('130 coins added.'), findsOneWidget);
      expect(find.text('137'), findsWidgets);
      expect(container.read(billingStateProvider).asData!.value.balance, 137);
    },
  );

  testWidgets(
    'a price the store does not know cannot be bought, and nothing says a price the store did not give',
    (tester) async {
      final purchases = FakePurchases()..catalog.remove('coins_l');
      await pumpShop(tester, purchases: purchases);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('buy-coins_l')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('buy-coins_s')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('restore purchases and manage subscription', (tester) async {
    final billing = FakeBilling(
      billingJson(
        plan: {
          'id': 'premium',
          'status': 'active',
          'store': 'google_play',
          'productId': 'premium_1m',
          'currentPeriodEnd': '2026-12-01T00:00:00Z',
          'autoRenew': true,
          'graceUntil': null,
        },
      ),
    );
    final purchases = FakePurchases();
    final launches = Launches();
    await pumpShop(
      tester,
      billing: billing,
      purchases: purchases,
      launches: launches,
    );
    expect(find.byKey(const Key('plan-status')), findsOneWidget);
    expect(find.textContaining('renews on 1 Dec 2026'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('buy-premium_1m')))
          .onPressed,
      isNull,
      reason: 'already Premium',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('manage-subscription')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('manage-subscription')));
    await tester.pump();
    expect(launches.uris.single.host, 'play.google.com');
    expect(launches.uris.single.queryParameters['sku'], 'premium_1m');
    expect(
      launches.uris.single.queryParameters['package'],
      'app.hiyall.hiyall',
    );
    await tester.tap(find.byKey(const Key('restore-purchases')));
    await tester.pump();
    expect(purchases.restores, hasLength(1));
    await tester.pump(const Duration(seconds: 7));
    expect(
      find.text('Nothing to restore on this store account.'),
      findsOneWidget,
    );
  });

  testWidgets('an App Store subscription is managed in the App Store', (
    tester,
  ) async {
    final launches = Launches();
    final billing = FakeBilling(
      billingJson(
        plan: {
          'id': 'premium',
          'status': 'grace',
          'store': 'app_store',
          'productId': 'premium_1m',
          'currentPeriodEnd': '2026-12-01T00:00:00Z',
          'autoRenew': true,
          'graceUntil': null,
        },
      ),
    );
    await pumpShop(tester, billing: billing, launches: launches);
    expect(
      find.textContaining('You still have Premium while it tries again'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('manage-subscription')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('manage-subscription')));
    expect(launches.uris.single.host, 'apps.apple.com');
  });

  testWidgets(
    'watching a video: the ad shows with the server options and the coins arrive',
    (tester) async {
      final billing = FakeBilling()
        ..rewards.add(const AdReward('credited', 1, 8));
      final ads = FakeAds();
      await pumpShop(tester, billing: billing, ads: ads);
      await tester.scrollUntilVisible(
        find.byKey(const Key('watch-ad')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('watch-ad')));
      await tester.pumpAndSettle();
      expect(ads.shown, 1);
      expect(find.byKey(const Key('ads-message')), findsOneWidget);
      expect(find.text('1 coin added.'), findsOneWidget);
    },
  );

  testWidgets(
    'the video row is absent without ads configured or for a server that turned them off',
    (tester) async {
      await pumpShop(tester, ads: FakeAds()..configured = false);
      expect(find.byKey(const Key('earn-ad')), findsNothing);
      await pumpShop(
        tester,
        billing: FakeBilling(billingJson(adsEnabled: false, bonus: false)),
      );
      expect(find.byKey(const Key('earn-ad')), findsNothing);
      expect(find.text('Earn coins'), findsNothing);
      await clearTree(tester);
    },
  );

  testWidgets('the profile bonus claim', (tester) async {
    final billing = FakeBilling();
    await pumpShop(tester, billing: billing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('claim-profile-bonus')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('claim-profile-bonus')));
    await tester.pumpAndSettle();
    expect(billing.bonusClaims, 1);
    expect(find.text('5 coins added.'), findsOneWidget);
  });

  group('layout', () {
    testWidgets('320 wide at text scale 2.0 does not overflow', (tester) async {
      await pumpShop(tester, size: const Size(320, 640), textScale: 2.0);
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('right to left', (tester) async {
      await pumpShop(tester, direction: TextDirection.rtl);
      expect(tester.takeException(), isNull);
      final pill = tester.getTopLeft(find.byKey(const Key('coin-pill')));
      final title = tester.getTopLeft(find.text('Shop'));
      expect(
        pill.dx < title.dx,
        isTrue,
        reason:
            'the coin pill is at the start side, on the left, in right-to-left',
      );
      await tester.dragUntilVisible(
        find.byKey(const Key('benefits-table')),
        find.byType(Scrollable).first,
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('dark and reduced motion', (tester) async {
      await pumpShop(tester, brightness: Brightness.dark, reduceMotion: true);
      expect(find.byKey(const Key('shop')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every control is at least 48 logical pixels', (tester) async {
      await pumpShop(tester);
      for (final key in ['buy-coins_s', 'buy-coins_xl', 'buy-premium_1m']) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(
          size.height >= 48 && size.width >= 48,
          isTrue,
          reason: '$key is $size',
        );
      }
    });
  });

  group('the settings entry', () {
    Future<void> pumpTile(
      WidgetTester tester,
      FakeBilling billing, {
      FakePurchases? purchases,
    }) async {
      final container = ProviderContainer(
        overrides: billingOverrides(billing: billing, purchases: purchases),
      );
      addTearDown(container.dispose);
      await container
          .read(billingStateProvider.future)
          .catchError((_) => BillingState.none);
      await clearTree(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: BillingSettingsGroup()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an adult who can shop sees the shop with the balance', (
      tester,
    ) async {
      await pumpTile(tester, FakeBilling());
      expect(find.byKey(const Key('settings-shop')), findsOneWidget);
      expect(find.byKey(const Key('coin-pill')), findsOneWidget);
    });

    testWidgets('nobody else sees anything', (tester) async {
      await pumpTile(tester, FakeBilling(minorJson()));
      expect(find.byKey(const Key('settings-shop')), findsNothing);
      await pumpTile(tester, FakeBilling()..stateError = const ApiFailure('x'));
      expect(find.byKey(const Key('settings-shop')), findsNothing);
      await pumpTile(
        tester,
        FakeBilling(),
        purchases: FakePurchases()..supported = false,
      );
      expect(find.byKey(const Key('settings-shop')), findsNothing);
      await pumpTile(
        tester,
        FakeBilling(
          billingJson(
            enforced: false,
            locksApply: false,
            shop: false,
            ads: false,
          ),
        ),
      );
      expect(find.byKey(const Key('settings-shop')), findsNothing);
    });
  });

  group('spending asks first', () {
    Future<bool?> askSpend(
      WidgetTester tester, {
      required int cost,
      required int balance,
      bool canOpenShop = true,
    }) async {
      bool? answer;
      await clearTree(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async => answer = await confirmSpend(
                    context,
                    title: 'Start this chat?',
                    what: 'It costs coins.',
                    cost: cost,
                    balance: balance,
                    canOpenShop: canOpenShop,
                  ),
                  child: const Text('ask'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets(
      'the confirmation shows the cost and the balance, and only Spend says yes',
      (tester) async {
        bool? answer;
        await clearTree(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () async => answer = await confirmSpend(
                    context,
                    title: 'Start this chat?',
                    what: 'It costs coins.',
                    cost: 2,
                    balance: 5,
                  ),
                  child: const Text('ask'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('ask'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('spend-cost')), findsOneWidget);
        expect(find.text('2 coins'), findsOneWidget);
        expect(find.byKey(const Key('coin-pill')), findsOneWidget);
        expect(find.text('Spend 2 coins'), findsOneWidget);
        expect(answer, isNull, reason: 'nothing is decided before a tap');
        await tester.tap(find.byKey(const Key('spend-cancel')));
        await tester.pumpAndSettle();
        expect(answer, isFalse);
        await tester.tap(find.text('ask'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('spend-confirm-yes')));
        await tester.pumpAndSettle();
        expect(answer, isTrue);
      },
    );

    testWidgets(
      'not enough coins: no spend button, the way to the shop instead',
      (tester) async {
        await askSpend(tester, cost: 2, balance: 1);
        expect(find.byKey(const Key('spend-short')), findsOneWidget);
        expect(find.byKey(const Key('spend-confirm-yes')), findsNothing);
        expect(find.byKey(const Key('spend-open-shop')), findsOneWidget);
        expect(find.byKey(const Key('spend-cancel')), findsOneWidget);
      },
    );

    testWidgets('a member without a shop is only told, with no way to buy', (
      tester,
    ) async {
      await askSpend(tester, cost: 2, balance: 1, canOpenShop: false);
      expect(find.byKey(const Key('spend-open-shop')), findsNothing);
      expect(find.byKey(const Key('spend-confirm-yes')), findsNothing);
    });

    testWidgets(
      'chat start: a 402 asks, a "no" opens nothing, a "yes" retries with the confirmed price',
      (tester) async {
        final calls = <int?>[];
        Future<String> open(int? cost) async {
          calls.add(cost);
          if (cost == null) {
            throw const ChatFailure(
              'SPEND_CONFIRMATION_REQUIRED',
              'This costs coins.',
              402,
              null,
              {'reason': 'chat_slot', 'cost': 2, 'balance': 5},
            );
          }
          return 'conv-1';
        }

        final container = ProviderContainer(
          overrides: billingOverrides(billing: FakeBilling()),
        );
        addTearDown(container.dispose);
        await container.read(billingStateProvider.future);
        String? result = 'unset';
        late WidgetRef widgetRef;
        await clearTree(tester);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) {
                  widgetRef = ref;
                  return Scaffold(
                    body: FilledButton(
                      onPressed: () async =>
                          result = await openChatConfirmingSpend(
                            context,
                            widgetRef,
                            open: open,
                          ),
                      child: const Text('go'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        expect(find.text('Start this chat?'), findsOneWidget);
        expect(calls, [null]);
        await tester.tap(find.byKey(const Key('spend-cancel')));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(calls, [null], reason: 'declining spends and opens nothing');
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('spend-confirm-yes')));
        await tester.pumpAndSettle();
        expect(result, 'conv-1');
        expect(calls, [null, null, 2]);
      },
    );

    testWidgets('other chat failures are not swallowed', (tester) async {
      final container = ProviderContainer(
        overrides: billingOverrides(billing: FakeBilling()),
      );
      addTearDown(container.dispose);
      Object? error;
      await clearTree(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    try {
                      await openChatConfirmingSpend(
                        context,
                        ref,
                        open: (_) async => throw const ChatFailure(
                          'RECIPIENT_BACKLOG',
                          'busy',
                          429,
                        ),
                      );
                    } catch (e) {
                      error = e;
                    }
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(error, isA<ChatFailure>());
    });
  });

  group('locked features', () {
    Future<void> pumpHost(
      WidgetTester tester,
      FakeBilling billing, {
      bool bind = true,
    }) async {
      final container = ProviderContainer(
        overrides: [
          ...billingOverrides(billing: billing),
          if (bind)
            premiumRequiredHandlerProvider.overrideWithValue(
              (context, feature) =>
                  showLockedFeatureSheet(context, feature: feature),
            ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(billingStateProvider.future)
          .catchError((_) => BillingState.none);
      await clearTree(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => showFailure(
                    context,
                    const ApiFailureDetails(
                      'This is part of Premium.',
                      402,
                      'PREMIUM_REQUIRED',
                      {'feature': 'genderFilter'},
                    ),
                  ),
                  child: const Text('use'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('use'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a 402 explains Premium plainly, with "Not now" as prominent as the way in',
      (tester) async {
        await pumpHost(tester, FakeBilling());
        expect(find.byKey(const Key('locked-feature')), findsOneWidget);
        expect(find.text('Filtering people by gender'), findsOneWidget);
        expect(find.textContaining('cancel any time'), findsOneWidget);
        expect(find.byKey(const Key('locked-see-premium')), findsOneWidget);
        expect(find.byKey(const Key('locked-not-now')), findsOneWidget);
        await tester.tap(find.byKey(const Key('locked-not-now')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('locked-feature')), findsNothing);
      },
    );

    testWidgets(
      'for a member who cannot shop there is no sheet and no upsell',
      (tester) async {
        await pumpHost(tester, FakeBilling(minorJson()));
        expect(find.byKey(const Key('locked-feature')), findsNothing);
        expect(find.byKey(const Key('locked-see-premium')), findsNothing);
      },
    );

    testWidgets('without the app binding a plain message is shown', (
      tester,
    ) async {
      await pumpHost(tester, FakeBilling(), bind: false);
      expect(find.byKey(const Key('locked-feature')), findsNothing);
      expect(find.text('This is part of Premium.'), findsOneWidget);
    });
  });

  group('profile details', () {
    Future<FakeBilling> pumpCard(
      WidgetTester tester, {
      FakeBilling? billing,
    }) async {
      final b = billing ?? FakeBilling();
      final container = ProviderContainer(
        overrides: billingOverrides(billing: b),
      );
      addTearDown(container.dispose);
      await container
          .read(billingStateProvider.future)
          .catchError((_) => BillingState.none);
      await clearTree(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileDetailsLockedCard(
                  userId: '019a4000-0000-7000-8000-000000000002',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return b;
    }

    testWidgets(
      'says what it costs and unlocks only after the confirmation, with the confirmed price',
      (tester) async {
        final billing = FakeBilling()
          ..unlockBehavior = (confirm) =>
              confirm == null ? spendRequired(1, 7) : null;
        await pumpCard(tester, billing: billing);
        expect(find.byKey(const Key('details-locked')), findsOneWidget);
        expect(find.text('Unlock for 1 coin'), findsOneWidget);
        expect(find.textContaining('or with Premium'), findsOneWidget);
        await tester.tap(find.byKey(const Key('unlock-details')));
        await tester.pumpAndSettle();
        expect(billing.unlockCalls, [
          null,
        ], reason: 'the first call only asks the price');
        expect(find.byKey(const Key('spend-confirm')), findsOneWidget);
        await tester.tap(find.byKey(const Key('spend-cancel')));
        await tester.pumpAndSettle();
        expect(billing.unlockCalls, [null], reason: 'declining spends nothing');
        await tester.tap(find.byKey(const Key('unlock-details')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('spend-confirm-yes')));
        await tester.pumpAndSettle();
        expect(billing.unlockCalls, [null, null, 1]);
      },
    );

    testWidgets('nothing for a member who cannot shop', (tester) async {
      await pumpCard(tester, billing: FakeBilling(minorJson()));
      expect(find.byKey(const Key('details-locked')), findsNothing);
    });
  });

  testWidgets(
    'the Settings screen carries the shop entry only for an adult who can shop',
    (tester) async {
      Future<void> check(FakeBilling b, {required bool shown}) async {
        final container = ProviderContainer(
          overrides: billingOverrides(billing: b),
        );
        await container
            .read(billingStateProvider.future)
            .catchError((_) => BillingState.none);
        tester.view.physicalSize = const Size(390, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await clearTree(tester);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(const Key('settings-shop')),
          shown ? findsOneWidget : findsNothing,
        );
        // The container goes first: it cancels the retries of the Settings screen's other providers.
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pump(const Duration(seconds: 1));
      }

      await check(FakeBilling(), shown: true);
      await check(FakeBilling(minorJson()), shown: false);
    },
  );

  test(
    'nothing about Premium is written into the pill or the model for a minor',
    () {
      final s = BillingState.fromJson(minorJson());
      expect(s.showsPlans, isFalse);
      expect(const CoinPill(0).balance, 0);
      expect(SystemChannels.platform, isNotNull);
    },
  );
}

/// The store's purchase status, re-exported under a name that reads well in these tests.
typedef StorePurchaseStatusForTest = StorePurchaseStatus;
