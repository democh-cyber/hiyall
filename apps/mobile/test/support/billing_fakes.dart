import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/billing/ads_service.dart';
import 'package:hiyall/core/billing/billing_api.dart';
import 'package:hiyall/core/billing/billing_models.dart';
import 'package:hiyall/core/billing/billing_state.dart';
import 'package:hiyall/core/billing/purchase_service.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/shop/shop_screen.dart';

import '../widget_test.dart' show SignedIn;

/// The GET /v1/me/billing answer of docs/api/28-billing.md for an adult with plans enforced (override the pieces a test cares about).
Map<String, dynamic> billingJson({
  bool enforced = true,
  bool locksApply = true,
  bool monetizable = true,
  bool shop = true,
  bool ads = true,
  String? reason,
  int balance = 7,
  Map<String, dynamic>? plan,
  bool adsEnabled = true,
  int watchedToday = 1,
  bool bonus = true,
}) => {
  'enforced': enforced,
  'locksApply': locksApply,
  'eligibility': {
    'monetizable': monetizable,
    'reason': reason,
    'shop': shop,
    'stores': {'googlePlay': true, 'appStore': true},
    'ads': ads,
  },
  'balance': balance,
  'plan':
      plan ??
      {
        'id': 'free',
        'status': 'none',
        'store': null,
        'productId': null,
        'currentPeriodEnd': null,
        'autoRenew': false,
        'graceUntil': null,
      },
  'entitlements': {
    'features': {
      'autoTranslate': false,
      'visitorsList': false,
      'nearbyFilter': false,
      'genderFilter': false,
      'detailedProfile': false,
      'groupChat': false,
    },
    'freeNewChatsPerDay': 3,
    'chatSlotCoinCost': 2,
    'profileDetailCoinCost': 1,
    'profileDetailDays': 30,
  },
  'catalog': monetizable
      ? {
          'coinPacks': [
            _pack('coins_s', 'Pocket of coins', 40, 0, 1),
            _pack('coins_m', 'Handful of coins', 120, 10, 2),
            _pack('coins_l', 'Bag of coins', 300, 40, 3),
            _pack('coins_xl', 'Chest of coins', 700, 120, 4),
          ],
          'subscriptions': [
            _plan('premium_1m', 'Premium, 1 month', 1, 1),
            _plan('premium_3m', 'Premium, 3 months', 3, 2),
            _plan('premium_12m', 'Premium, 12 months', 12, 3),
          ],
        }
      : {'coinPacks': [], 'subscriptions': []},
  'benefits': monetizable
      ? [
          {
            'key': 'newChats',
            'title': 'Start new chats',
            'free': {'type': 'limit', 'value': 3, 'unit': 'day'},
            'premium': {'type': 'unlimited'},
          },
          {
            'key': 'profileDetails',
            'title': 'Detailed profiles',
            'free': {'type': 'coins', 'value': 1, 'days': 30},
            'premium': {'type': 'included'},
          },
          {
            'key': 'genderFilter',
            'title': 'Gender filter',
            'free': {'type': 'notIncluded'},
            'premium': {'type': 'included'},
          },
        ]
      : [],
  'ads': {
    'enabled': adsEnabled && ads,
    'coinsPerAd': 1,
    'dailyCap': 5,
    'watchedToday': watchedToday,
  },
  'bonuses': bonus && monetizable
      ? {
          'profileCompletion': {'coins': 5, 'claimed': false},
        }
      : {},
};

Map<String, dynamic> _pack(
  String id,
  String name,
  int coins,
  int bonus,
  int tier,
) => {
  'id': id,
  'name': name,
  'coins': coins,
  'bonusCoins': bonus,
  'priceTier': tier,
  'storeProductIds': {'googlePlay': id, 'appStore': id},
};
Map<String, dynamic> _plan(String id, String name, int months, int tier) => {
  'id': id,
  'name': name,
  'periodMonths': months,
  'priceTier': tier,
  'storeProductIds': {'googlePlay': id, 'appStore': id},
};

/// A scripted billing backend that records its calls.
class FakeBilling implements BillingBackend {
  Map<String, dynamic> json;
  Object? stateError;
  int stateReads = 0;
  final verifies = <Map<String, Object?>>[];
  Object? verifyError;
  VerifyResult? verifyResult;
  final historyPages = <LedgerPage>[];
  int adSessions = 0;
  final rewards = <AdReward>[];
  final unlockCalls = <int?>[];
  Object? Function(int? confirm)? unlockBehavior;
  ProfileBonusResult bonusResult = const ProfileBonusResult(true, false, 5, 12);
  int bonusClaims = 0;

  FakeBilling([Map<String, dynamic>? json]) : json = json ?? billingJson();

  @override
  Future<BillingState> state() async {
    stateReads++;
    if (stateError != null) throw stateError!;
    return BillingState.fromJson(json);
  }

  @override
  Future<LedgerPage> history({String? cursor, int limit = 20}) async =>
      historyPages.isEmpty
      ? const LedgerPage([], null)
      : historyPages.removeAt(0);

  @override
  Future<VerifyResult> verify({
    required PurchaseStore store,
    required String productId,
    String? purchaseToken,
    String? transactionId,
  }) async {
    verifies.add({
      'store': store.wire,
      'productId': productId,
      'token': purchaseToken,
      'txid': transactionId,
    });
    if (verifyError != null) throw verifyError!;
    return verifyResult ??
        VerifyResult(
          state: 'verified',
          kind: 'coins',
          productId: productId,
          coinsGranted: 130,
          balance: 137,
          alreadyProcessed: false,
          plan: const PlanInfo(),
        );
  }

  @override
  Future<AdSession> startAdSession() async {
    adSessions++;
    return const AdSession('n-1', 'u-1', 'n-1', 1, 3);
  }

  @override
  Future<AdReward> adReward(String nonce) async =>
      rewards.isEmpty ? const AdReward('pending', 0, 7) : rewards.removeAt(0);

  @override
  Future<ProfileBonusResult> claimProfileBonus() async {
    bonusClaims++;
    return bonusResult;
  }

  @override
  Future<DetailsUnlock> unlockProfileDetails(
    String userId, {
    int? confirmCost,
  }) async {
    unlockCalls.add(confirmCost);
    final failure = unlockBehavior?.call(confirmCost);
    if (failure != null) throw failure;
    return DetailsUnlock(true, DateTime.utc(2026, 12, 1), 1, 2);
  }
}

/// A scripted store.
class FakePurchases implements PurchaseService {
  @override
  bool supported = true;
  bool available = true;
  final controller = StreamController<StorePurchase>.broadcast();
  final bought = <String>[];
  final completed = <String>[];
  final restores = <String>[];
  Object? buyError;
  Map<String, StoreProduct> catalog = {
    for (final e in const {
      'coins_s': r'$0.99',
      'coins_m': r'$2.99',
      'coins_l': r'$6.99',
      'coins_xl': r'$13.99',
      'premium_1m': r'$4.99',
      'premium_3m': r'$11.99',
      'premium_12m': r'$34.99',
    }.entries)
      e.key: StoreProduct(e.key, e.key, e.value),
  };

  @override
  Future<bool> isAvailable() async => available;
  @override
  Stream<StorePurchase> get updates => controller.stream;
  @override
  Future<Map<String, StoreProduct>> products(Set<String> storeIds) async => {
    for (final id in storeIds)
      if (catalog.containsKey(id)) id: catalog[id]!,
  };
  @override
  Future<void> buy(
    StoreProduct product, {
    required bool subscription,
    required String userId,
  }) async {
    if (buyError != null) throw buyError!;
    bought.add('${product.id}:${subscription ? 'sub' : 'coins'}:$userId');
  }

  @override
  Future<void> restore(String userId) async => restores.add(userId);
  @override
  Future<void> complete(StorePurchase purchase) async =>
      completed.add(purchase.productId);

  void emit(
    String productId,
    StorePurchaseStatus status, {
    String? token = 'tok-1',
  }) => controller.add(
    StorePurchase(productId: productId, status: status, token: token),
  );
}

/// A scripted ads SDK.
class FakeAds implements AdsService {
  @override
  bool configured = true;
  bool prepareResult = true;
  AdOutcome outcome = AdOutcome.rewarded;
  final prepared = <bool>[];
  int shown = 0;
  String? lastUser, lastCustom;

  @override
  Future<bool> prepare({required bool confirmedAdult}) async {
    prepared.add(confirmedAdult);
    return prepareResult;
  }

  @override
  Future<AdOutcome> showRewarded({
    required String userId,
    required String customData,
  }) async {
    shown++;
    lastUser = userId;
    lastCustom = customData;
    return outcome;
  }
}

class Launches {
  final uris = <Uri>[];
}

/// The overrides that put the billing feature on fakes, signed in as an adult.
List<Override> billingOverrides({
  required FakeBilling billing,
  FakePurchases? purchases,
  FakeAds? ads,
  Launches? launches,
  PurchaseStore store = PurchaseStore.googlePlay,
}) => [
  sessionProvider.overrideWith(SignedIn.new),
  billingBackendProvider.overrideWithValue(billing),
  purchaseServiceProvider.overrideWithValue(purchases ?? FakePurchases()),
  adsServiceProvider.overrideWithValue(ads ?? FakeAds()),
  purchaseStoreProvider.overrideWithValue(store),
  adsPollProvider.overrideWithValue((
    every: const Duration(milliseconds: 10),
    upTo: const Duration(milliseconds: 60),
  )),
  if (launches != null)
    shopLauncherProvider.overrideWithValue((uri) async {
      launches.uris.add(uri);
      return true;
    }),
];

/// The Shop on a tiny router that has a /home to be sent to, so a refusal is visible as a navigation.
Widget shopApp({
  required ProviderContainer container,
  TextDirection? direction,
  Size? unused,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
  Widget? shop,
  GlobalKey? captureKey,
}) {
  final router = GoRouter(
    initialLocation: '/shop',
    routes: [
      GoRoute(
        path: '/shop',
        builder: (c, s) => Scaffold(body: shop ?? const ShopScreen()),
      ),
      GoRoute(
        path: '/home',
        builder: (c, s) => const Scaffold(
          body: Center(child: Text('home-screen', key: Key('home'))),
        ),
      ),
      GoRoute(
        path: '/profile/settings',
        builder: (c, s) => const Scaffold(body: Text('settings-screen')),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: hiyallTheme(brightness),
      routerConfig: router,
      builder: (context, child) => RepaintBoundary(
        key: captureKey,
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: direction ?? TextDirection.ltr,
            child: child!,
          ),
        ),
      ),
    ),
  );
}

ApiFailureDetails spendRequired(
  int cost,
  int balance, {
  String code = 'SPEND_CONFIRMATION_REQUIRED',
  String reason = 'profile_detail',
}) => ApiFailureDetails('This costs coins. Confirm to continue.', 402, code, {
  'reason': reason,
  'cost': cost,
  'balance': balance,
});

bool get isDebug => kDebugMode;
