import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/billing/ads_service.dart';
import 'package:hiyall/core/billing/billing_api.dart';
import 'package:hiyall/core/billing/billing_models.dart';
import 'package:hiyall/core/billing/billing_state.dart';
import 'package:hiyall/core/billing/purchase_service.dart';

import 'support/billing_fakes.dart';

class _Adapter implements HttpClientAdapter {
  final int status;
  final Map<String, dynamic> body;
  _Adapter(this.status, this.body);
  RequestOptions? last;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> adultContainer(
  FakeBilling billing, {
  FakePurchases? purchases,
  FakeAds? ads,
  PurchaseStore store = PurchaseStore.googlePlay,
}) async {
  final container = ProviderContainer(
    overrides: billingOverrides(
      billing: billing,
      purchases: purchases,
      ads: ads,
      store: store,
    ),
  );
  addTearDown(container.dispose);
  await container.read(billingStateProvider.future);
  return container;
}

void main() {
  group('models', () {
    test('the adult example of docs/api/28-billing.md', () {
      final s = BillingState.fromJson(
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
      expect(s.showsPlans, isTrue);
      expect(s.shop, isTrue);
      expect(s.balance, 7);
      expect(s.coinPacks.map((p) => p.id), [
        'coins_s',
        'coins_m',
        'coins_l',
        'coins_xl',
      ]);
      expect(s.coinPacks[1].total, 130);
      expect(s.plans.map((p) => p.periodMonths), [1, 3, 12]);
      expect(s.plan.isPremium, isTrue);
      expect(s.plan.autoRenew, isTrue);
      expect(s.entitlements.freeNewChatsPerDay, 3);
      expect(s.entitlements.has('genderFilter'), isFalse);
      expect(s.benefits.first.free.kind, BenefitKind.limit);
      expect(s.benefits.first.premium.kind, BenefitKind.unlimited);
      expect(s.ads.remainingToday, 4);
      expect(s.profileBonusCoins, 5);
    });

    test(
      'a member who cannot buy shows nothing, whatever else the answer says',
      () {
        for (final json in [
          billingJson(
            monetizable: false,
            reason: 'minor',
            locksApply: false,
            shop: false,
            ads: false,
          ),
          // A server that (wrongly) says locks apply to someone it also says cannot buy: fail closed.
          billingJson(
            monetizable: false,
            reason: 'age_unknown',
            locksApply: true,
            shop: true,
            ads: true,
          ),
        ]) {
          final s = BillingState.fromJson(json);
          expect(s.showsPlans, isFalse, reason: '$json');
          expect(s.shop, isFalse);
          expect(s.adsEligible, isFalse);
          expect(s.coinPacks, isEmpty);
          expect(s.benefits, isEmpty);
        }
        expect(BillingState.none.showsPlans, isFalse);
        expect(BillingState.fromJson(const {}).showsPlans, isFalse);
      },
    );

    test('garbage fields read as nothing, not as an error', () {
      final s = BillingState.fromJson({
        'balance': 'many',
        'catalog': {'coinPacks': 'x'},
        'benefits': [1, 2],
        'plan': 5,
      });
      expect(s.balance, 0);
      expect(s.coinPacks, isEmpty);
      expect(s.plan.status, 'none');
    });

    test('verify, ad and unlock answers', () {
      final v = VerifyResult.fromJson({
        'state': 'pending',
        'kind': 'coins',
        'productId': 'coins_s',
        'coinsGranted': 0,
        'balance': 3,
        'alreadyProcessed': false,
        'plan': {},
      });
      expect(v.pending, isTrue);
      expect(
        AdReward.fromJson({'status': 'credited', 'coins': 1, 'balance': 8})
            .status,
        'credited',
      );
      expect(
        DetailsUnlock.fromJson({
          'unlocked': true,
          'expiresAt': '2026-12-01T00:00:00Z',
          'cost': 1,
          'balance': 2,
        }).expiresAt,
        isNotNull,
      );
      expect(
        LedgerPage.fromJson({
          'items': [
            {
              'id': '4',
              'reason': 'purchase',
              'delta': 40,
              'balanceAfter': 40,
              'createdAt': '2026-10-18T00:00:00Z',
            },
          ],
          'nextCursor': 'c',
        }).items.single.delta,
        40,
      );
    });
  });

  group('rewarded ad units', () {
    test('Google test ids only in debug', () {
      expect(
        rewardedAdUnitId(debug: true, platform: TargetPlatform.android),
        googleTestRewardedAndroid,
      );
      expect(
        rewardedAdUnitId(debug: true, platform: TargetPlatform.iOS),
        googleTestRewardedIos,
      );
      expect(
        googleTestRewardedAndroid,
        'ca-app-pub-3940256099942544/5224354917',
      );
      expect(googleTestRewardedIos, 'ca-app-pub-3940256099942544/1712485313');
    });
    test(
      'a release build without the defines has no ads, with them it uses them',
      () {
        expect(
          rewardedAdUnitId(
            debug: false,
            platform: TargetPlatform.android,
            android: '',
            ios: '',
          ),
          isNull,
        );
        expect(
          rewardedAdUnitId(
            debug: false,
            platform: TargetPlatform.iOS,
            android: 'a',
            ios: '',
          ),
          isNull,
        );
        expect(
          rewardedAdUnitId(
            debug: false,
            platform: TargetPlatform.android,
            android: 'ca-app-pub-1/2',
            ios: '',
          ),
          'ca-app-pub-1/2',
        );
        expect(
          rewardedAdUnitId(
            debug: false,
            platform: TargetPlatform.iOS,
            android: '',
            ios: 'ca-app-pub-1/3',
          ),
          'ca-app-pub-1/3',
        );
      },
    );
    test('no ads on desktop or web platforms', () {
      expect(
        rewardedAdUnitId(debug: true, platform: TargetPlatform.macOS),
        isNull,
      );
      expect(const NoAdsService().configured, isFalse);
      expect(const NoPurchaseService().supported, isFalse);
    });
  });

  group('the API client keeps the 402 details', () {
    test(
      'a spend refusal carries cost and balance, with the server words',
      () async {
        final adapter = _Adapter(402, {
          'success': false,
          'error': {
            'code': 'SPEND_CONFIRMATION_REQUIRED',
            'message': 'This costs coins. Confirm to continue.',
            'details': {'reason': 'chat_slot', 'cost': 2, 'balance': 5},
          },
        });
        final api = ApiClient(
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
            ..httpClientAdapter = adapter,
        );
        try {
          await api.send(
            const Session('t', 'u'),
            'POST',
            '/v1/conversations',
            body: {'userId': 'x'},
          );
          fail('expected a failure');
        } on ApiFailureDetails catch (e) {
          expect(e.status, 402);
          expect(e.code, 'SPEND_CONFIRMATION_REQUIRED');
          expect(e.message, 'This costs coins. Confirm to continue.');
          expect(e.details['cost'], 2);
          expect(e.details['balance'], 5);
        }
      },
    );
    test('the billing codes show the server wording', () async {
      for (final code in [
        'AGE_RESTRICTED',
        'PURCHASE_CLAIMED',
        'PURCHASE_INVALID',
        'STORE_UNAVAILABLE',
        'BILLING_NOT_CONFIGURED',
        'ADS_UNAVAILABLE',
      ]) {
        final api = ApiClient(
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
            ..httpClientAdapter = _Adapter(403, {
              'success': false,
              'error': {'code': code, 'message': 'words for $code'},
            }),
        );
        await expectLater(
          api.send(const Session('t', 'u'), 'GET', '/v1/me/billing'),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.displayMessage,
              'message',
              'words for $code',
            ),
          ),
        );
      }
    });
  });

  group('the HTTP backend asks the documented routes', () {
    test('verify, history, ads, bonus and unlock', () async {
      final calls = <String>[];
      final backend = HttpBillingBackend((method, path, {body}) async {
        calls.add('$method $path ${jsonEncode(body)}');
        return switch (path) {
          '/v1/me/billing' => billingJson(),
          '/v1/me/billing/ads/session' => {
            'nonce': 'n',
            'userId': 'u',
            'customData': 'n',
            'coins': 1,
            'remainingToday': 4,
          },
          _ => <String, dynamic>{},
        };
      });
      await backend.state();
      await backend.verify(
        store: PurchaseStore.googlePlay,
        productId: 'coins_s',
        purchaseToken: 'tok',
      );
      await backend.verify(
        store: PurchaseStore.appStore,
        productId: 'coins_s',
        transactionId: '77',
      );
      await backend.history(cursor: 'a b', limit: 5);
      expect((await backend.startAdSession()).nonce, 'n');
      await backend.adReward('n');
      await backend.claimProfileBonus();
      await backend.unlockProfileDetails('abc', confirmCost: 1);
      await backend.unlockProfileDetails('abc');
      expect(calls, [
        'GET /v1/me/billing null',
        'POST /v1/me/billing/purchases/verify {"store":"google_play","productId":"coins_s","purchaseToken":"tok"}',
        'POST /v1/me/billing/purchases/verify {"store":"app_store","productId":"coins_s","transactionId":"77"}',
        'GET /v1/me/billing/history?limit=5&cursor=a+b null',
        'POST /v1/me/billing/ads/session null',
        'POST /v1/me/billing/ads/reward {"nonce":"n"}',
        'POST /v1/me/billing/bonuses/profile-completion null',
        'POST /v1/users/abc/profile-details/unlock {"confirmCost":1}',
        'POST /v1/users/abc/profile-details/unlock {}',
      ]);
    });
  });

  group('billing state', () {
    test(
      'a failed or missing read leaves nothing showing (fail closed)',
      () async {
        final billing = FakeBilling()..stateError = const ApiFailure('offline');
        final container = ProviderContainer(
          overrides: billingOverrides(billing: billing),
        );
        addTearDown(container.dispose);
        await expectLater(
          container.read(billingStateProvider.future),
          throwsA(isA<ApiFailure>()),
        );
        expect(container.read(showsPlansProvider), isFalse);
        expect(container.read(shopAvailableProvider), isFalse);
      },
    );

    test(
      'an adult with a store and locks has the shop; a minor never does',
      () async {
        final adult = await adultContainer(FakeBilling());
        expect(adult.read(shopAvailableProvider), isTrue);
        expect(adult.read(showsPlansProvider), isTrue);
        final minor = await adultContainer(
          FakeBilling(
            billingJson(
              monetizable: false,
              reason: 'minor',
              locksApply: false,
              shop: false,
              ads: false,
            ),
          ),
        );
        expect(minor.read(shopAvailableProvider), isFalse);
        expect(minor.read(showsPlansProvider), isFalse);
        final noStore = await adultContainer(
          FakeBilling(),
          purchases: FakePurchases()..supported = false,
        );
        expect(
          noStore.read(shopAvailableProvider),
          isFalse,
          reason: 'no store on this platform',
        );
        final beta = await adultContainer(
          FakeBilling(
            billingJson(
              enforced: false,
              locksApply: false,
              shop: false,
              ads: false,
            ),
          ),
        );
        expect(
          beta.read(showsPlansProvider),
          isFalse,
          reason: 'plans are not enforced yet',
        );
      },
    );

    test('products come from the store with their own prices', () async {
      final container = await adultContainer(FakeBilling());
      final products = await container.read(storeProductsProvider.future);
      expect(products['coins_m']!.price, r'$2.99');
      expect(products.keys, containsAll(['premium_1m', 'premium_12m']));
    });
  });

  group('purchase flow', () {
    Future<(ProviderContainer, FakeBilling, FakePurchases)> start({
      FakeBilling? billing,
    }) async {
      final b = billing ?? FakeBilling();
      final p = FakePurchases();
      final container = await adultContainer(b, purchases: p);
      container.read(purchaseControllerProvider); // starts listening
      await container.read(storeProductsProvider.future);
      return (container, b, p);
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('buy starts the store purchase with the member id and one purchase runs at a time', () async {
      final (c, _, p) = await start();
      final controller = c.read(purchaseControllerProvider.notifier);
      await controller.buy('coins_m');
      await controller.buy('coins_l'); // refused: another is in flight
      expect(p.bought, ['coins_m:coins:019a4000-0000-7000-8000-000000000001']);
      expect(c.read(purchaseControllerProvider).buying, 'coins_m');
      await controller.buy('premium_1m');
      expect(p.bought.length, 1);
    });

    test('a subscription is bought as a non-consumable', () async {
      final (c, _, p) = await start();
      await c.read(purchaseControllerProvider.notifier).buy('premium_3m');
      expect(p.bought.single, startsWith('premium_3m:sub:'));
    });

    test('purchase -> server verify -> complete -> refresh', () async {
      final (c, b, p) = await start();
      await c.read(purchaseControllerProvider.notifier).buy('coins_m');
      b.json = billingJson(balance: 137);
      p.emit('coins_m', StorePurchaseStatus.purchased);
      await settle();
      expect(b.verifies.single, {
        'store': 'google_play',
        'productId': 'coins_m',
        'token': 'tok-1',
        'txid': null,
      });
      expect(p.completed, ['coins_m']);
      final ui = c.read(purchaseControllerProvider);
      expect(ui.buying, isNull);
      expect(ui.message, '130 coins added.');
      expect(ui.messageIsError, isFalse);
      expect(c.read(billingStateProvider).asData!.value.balance, 137);
    });

    test('on the App Store the transaction id is sent, not a token', () async {
      final b = FakeBilling();
      final p = FakePurchases();
      final c = await adultContainer(
        b,
        purchases: p,
        store: PurchaseStore.appStore,
      );
      c.read(purchaseControllerProvider);
      p.emit('coins_s', StorePurchaseStatus.purchased, token: '1000123');
      await settle();
      expect(b.verifies.single, {
        'store': 'app_store',
        'productId': 'coins_s',
        'token': null,
        'txid': '1000123',
      });
    });

    test('the same purchase delivered twice is verified once', () async {
      final (c, b, p) = await start();
      p.emit('coins_s', StorePurchaseStatus.purchased);
      p.emit('coins_s', StorePurchaseStatus.purchased);
      p.emit('coins_s', StorePurchaseStatus.restored);
      await settle();
      expect(b.verifies.length, 1);
      expect(p.completed.length, 1);
      expect(c.read(purchaseControllerProvider).message, '130 coins added.');
    });

    test(
      'a pending payment is shown as pending, nothing is completed',
      () async {
        final b = FakeBilling()
          ..verifyResult = const VerifyResult(
            state: 'pending',
            kind: 'coins',
            productId: 'coins_s',
            coinsGranted: 0,
            balance: 7,
            alreadyProcessed: false,
            plan: PlanInfo(),
          );
        final (c, _, p) = await start(billing: b);
        p.emit('coins_s', StorePurchaseStatus.pending);
        await settle();
        expect(c.read(purchaseControllerProvider).pending, isTrue);
        expect(
          c.read(purchaseControllerProvider).message,
          contains('Nothing is added'),
        );
        p.emit('coins_s', StorePurchaseStatus.purchased);
        await settle();
        expect(p.completed, isEmpty);
        expect(c.read(purchaseControllerProvider).message, contains('pending'));
      },
    );

    test(
      'a store that cannot be reached keeps the purchase for another try',
      () async {
        final b = FakeBilling()
          ..verifyError = const ApiFailure(
            'Try again',
            502,
            'STORE_UNAVAILABLE',
          );
        final (c, _, p) = await start(billing: b);
        p.emit('coins_s', StorePurchaseStatus.purchased);
        await settle();
        expect(
          p.completed,
          isEmpty,
          reason: 'an unconfirmed purchase is not completed',
        );
        final ui = c.read(purchaseControllerProvider);
        expect(ui.messageIsError, isTrue);
        expect(ui.message, contains('safe with the store'));
      },
    );

    test(
      'a purchase that belongs to another account is completed and explained',
      () async {
        final b = FakeBilling()
          ..verifyError = const ApiFailure(
            'This purchase is already linked to another account.',
            409,
            'PURCHASE_CLAIMED',
          );
        final (c, _, p) = await start(billing: b);
        p.emit('coins_s', StorePurchaseStatus.purchased);
        await settle();
        expect(p.completed, ['coins_s']);
        expect(
          c.read(purchaseControllerProvider).message,
          'This purchase is already linked to another account.',
        );
      },
    );

    test('store errors and cancellations clear the busy state', () async {
      final (c, _, p) = await start();
      final controller = c.read(purchaseControllerProvider.notifier);
      await controller.buy('coins_s');
      p.emit('coins_s', StorePurchaseStatus.canceled);
      await settle();
      expect(c.read(purchaseControllerProvider).busy, isFalse);
      await controller.buy('coins_s');
      p.emit('coins_s', StorePurchaseStatus.error);
      await settle();
      expect(c.read(purchaseControllerProvider).busy, isFalse);
      expect(
        c.read(purchaseControllerProvider).message,
        contains('haven’t been charged'),
      );
    });

    test(
      'a store that refuses to start the purchase says nothing was charged',
      () async {
        final (c, _, p) = await start();
        p.buyError = StateError('x');
        await c.read(purchaseControllerProvider.notifier).buy('coins_s');
        expect(c.read(purchaseControllerProvider).busy, isFalse);
        expect(
          c.read(purchaseControllerProvider).message,
          contains('Nothing was charged'),
        );
      },
    );

    test('a product the store does not list is not bought', () async {
      final b = FakeBilling();
      final p = FakePurchases()..catalog = {};
      final c = await adultContainer(b, purchases: p);
      c.read(purchaseControllerProvider);
      await c.read(purchaseControllerProvider.notifier).buy('coins_s');
      expect(p.bought, isEmpty);
      expect(c.read(purchaseControllerProvider).messageIsError, isTrue);
    });

    test(
      'restore asks the store and each restored purchase is verified',
      () async {
        final (c, b, p) = await start();
        await c.read(purchaseControllerProvider.notifier).restore();
        expect(p.restores, ['019a4000-0000-7000-8000-000000000001']);
        expect(c.read(purchaseControllerProvider).restoring, isTrue);
        b.verifyResult = VerifyResult(
          state: 'verified',
          kind: 'subscription',
          productId: 'premium_1m',
          coinsGranted: 0,
          balance: 7,
          alreadyProcessed: false,
          plan: const PlanInfo(id: 'premium', status: 'active'),
        );
        p.emit('premium_1m', StorePurchaseStatus.restored, token: 'sub-tok');
        await settle();
        expect(b.verifies.single['productId'], 'premium_1m');
        expect(c.read(purchaseControllerProvider).message, 'Premium is on.');
        expect(c.read(purchaseControllerProvider).restoring, isFalse);
      },
    );

    test(
      'nothing listens while the shop does not exist for the member',
      () async {
        final p = FakePurchases();
        final minor = await adultContainer(
          FakeBilling(
            billingJson(
              monetizable: false,
              reason: 'minor',
              locksApply: false,
              shop: false,
              ads: false,
            ),
          ),
          purchases: p,
        );
        minor.read(purchaseControllerProvider);
        expect(p.controller.hasListener, isFalse);
        await minor.read(purchaseControllerProvider.notifier).buy('coins_s');
        expect(p.bought, isEmpty);
      },
    );
  });

  group('rewarded ads flow', () {
    test(
      'session -> ad with the server options -> credited by polling',
      () async {
        final b = FakeBilling()
          ..rewards.addAll(const [
            AdReward('pending', 0, 7),
            AdReward('credited', 1, 8),
          ]);
        final ads = FakeAds();
        final c = await adultContainer(b, ads: ads);
        await c.read(adsControllerProvider.notifier).watch();
        expect(ads.prepared, [true], reason: 'a confirmed adult');
        expect(ads.lastUser, 'u-1');
        expect(ads.lastCustom, 'n-1');
        expect(b.adSessions, 1);
        expect(c.read(adsControllerProvider).message, '1 coin added.');
        expect(c.read(adsControllerProvider).busy, isFalse);
      },
    );

    test('closing the video early earns nothing and polls nothing', () async {
      final b = FakeBilling();
      final ads = FakeAds()..outcome = AdOutcome.dismissed;
      final c = await adultContainer(b, ads: ads);
      await c.read(adsControllerProvider.notifier).watch();
      expect(
        c.read(adsControllerProvider).message,
        contains('closed before the end'),
      );
    });

    test('a reward that never arrives says it is on its way', () async {
      final b = FakeBilling(); // every poll answers pending
      final c = await adultContainer(b, ads: FakeAds());
      await c.read(adsControllerProvider.notifier).watch();
      expect(c.read(adsControllerProvider).message, contains('on its way'));
    });

    test('rejected and expired rewards are explained', () async {
      for (final (status, text) in [
        ('rejected', 'couldn’t be added'),
        ('expired', 'took too long'),
      ]) {
        final b = FakeBilling()..rewards.add(AdReward(status, 0, 7));
        final c = await adultContainer(b, ads: FakeAds());
        await c.read(adsControllerProvider.notifier).watch();
        expect(c.read(adsControllerProvider).message, contains(text));
      }
    });

    test('no consent, no ad and no session', () async {
      final b = FakeBilling();
      final ads = FakeAds()..prepareResult = false;
      final c = await adultContainer(b, ads: ads);
      await c.read(adsControllerProvider.notifier).watch();
      expect(ads.shown, 0);
      expect(b.adSessions, 0);
      expect(
        c.read(adsControllerProvider).message,
        contains('aren’t available'),
      );
    });

    test('never for a minor, an unconfigured build, a cap that is used up, or when the server says ads are off', () async {
      final cases = <(String, Map<String, dynamic>, FakeAds)>[
        (
          'minor',
          billingJson(
            monetizable: false,
            reason: 'minor',
            locksApply: false,
            shop: false,
            ads: false,
          ),
          FakeAds(),
        ),
        ('not configured', billingJson(), FakeAds()..configured = false),
        ('cap used', billingJson(watchedToday: 5), FakeAds()),
        ('server off', billingJson(adsEnabled: false), FakeAds()),
      ];
      for (final (name, json, ads) in cases) {
        final b = FakeBilling(json);
        final c = await adultContainer(b, ads: ads);
        await c.read(adsControllerProvider.notifier).watch();
        expect(ads.shown, 0, reason: name);
        expect(ads.prepared, isEmpty, reason: name);
        expect(b.adSessions, 0, reason: name);
      }
    });

    test('the server refusing a session (the day cap) is explained', () async {
      final b = _CappedBilling();
      final c = await adultContainer(b, ads: FakeAds());
      await c.read(adsControllerProvider.notifier).watch();
      expect(
        c.read(adsControllerProvider).message,
        'You’ve watched all of today’s rewarded videos. Come back tomorrow.',
      );
    });
  });
}

class _CappedBilling extends FakeBilling {
  @override
  Future<AdSession> startAdSession() async => throw const ApiFailure(
    'You’ve watched all of today’s rewarded videos. Come back tomorrow.',
    429,
    'DAILY_LIMIT',
  );
}
