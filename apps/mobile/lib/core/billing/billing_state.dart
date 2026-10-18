import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api.dart';
import '../state.dart';
import 'ads_service.dart';
import 'billing_api.dart';
import 'billing_models.dart';
import 'purchase_service.dart';

/// The store side of buying. Where there is no store (web, desktop) it is [NoPurchaseService].
final purchaseServiceProvider = Provider<PurchaseService>((ref) {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  return mobile ? InAppPurchaseService() : const NoPurchaseService();
});

/// Rewarded ads. Without an ad unit for this build there are none.
final adsServiceProvider = Provider<AdsService>((ref) => GoogleAdsService());

/// Which store this phone buys from.
final purchaseStoreProvider = Provider<PurchaseStore>(
  (ref) => defaultTargetPlatform == TargetPlatform.iOS
      ? PurchaseStore.appStore
      : PurchaseStore.googlePlay,
);

/// The billing routes, signed in as the current member.
final billingBackendProvider = Provider<BillingBackend>((ref) {
  final api = ref.watch(apiProvider);
  final session = ref.watch(sessionProvider).asData?.value;
  return HttpBillingBackend((method, path, {body}) {
    if (session == null) throw const ApiFailure('Sign in to continue.');
    return api.send(session, method, path, body: body);
  });
});

/// How often the app asks whether a rewarded ad was credited, and for how long (a test shortens both).
final adsPollProvider = Provider<({Duration every, Duration upTo})>(
  (ref) =>
      (every: const Duration(seconds: 2), upTo: const Duration(seconds: 20)),
);

/// The member's billing state. While it has not loaded, after a failure, on web, and for a member who cannot buy, [BillingState.showsPlans] is
/// false and nothing about plans appears (fail closed).
final billingStateProvider =
    AsyncNotifierProvider<BillingController, BillingState>(
      BillingController.new,
      // No automatic retry: a failed read leaves nothing showing, and the Shop offers "Retry".
      retry: (count, error) => null,
    );

class BillingController extends AsyncNotifier<BillingState> {
  @override
  Future<BillingState> build() async {
    if (kIsWeb) return BillingState.none;
    final session = ref.watch(sessionProvider).asData?.value;
    if (session == null || !session.onboarded) return BillingState.none;
    return ref.read(billingBackendProvider).state();
  }

  /// Reads the state again; a failed read keeps what is on screen.
  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(billingBackendProvider).state());
    } catch (_) {
      // The next open of the shop reads it again.
    }
  }

  /// A balance the server just reported (after a spend or a reward).
  void applyBalance(int balance) {
    final current = state.asData?.value;
    if (current != null) state = AsyncData(current.withBalance(balance));
  }
}

/// The state to gate on: the loaded one, or nothing.
BillingState billingOf(WidgetRef ref) =>
    ref.watch(billingStateProvider).asData?.value ?? BillingState.none;

/// True only when the server says locks apply to this adult member: the one condition for any lock, price, upsell or coin pill.
final showsPlansProvider = Provider<bool>(
  (ref) => ref.watch(billingStateProvider).asData?.value.showsPlans ?? false,
);

/// True when the Shop may exist for this member on this device.
final shopAvailableProvider = Provider<bool>((ref) {
  if (kIsWeb) return false;
  final state = ref.watch(billingStateProvider).asData?.value;
  return state != null &&
      state.shop &&
      ref.watch(purchaseServiceProvider).supported;
});

/// The store's products (with their own localized prices) for everything the catalog sells.
final storeProductsProvider =
    FutureProvider.autoDispose<Map<String, StoreProduct>>((ref) async {
      final state = ref.watch(billingStateProvider).asData?.value;
      final service = ref.watch(purchaseServiceProvider);
      if (state == null || !state.shop || !service.supported) return const {};
      if (!await service.isAvailable()) return const {};
      final store = ref.watch(purchaseStoreProvider);
      return service.products({
        for (final p in state.coinPacks)
          store == PurchaseStore.googlePlay
              ? p.googleProductId
              : p.appProductId,
        for (final p in state.plans)
          store == PurchaseStore.googlePlay
              ? p.googleProductId
              : p.appProductId,
      });
    });

/// What the purchase flow tells the screen.
class PurchaseUi {
  /// The catalog id being bought right now (one at a time).
  final String? buying;
  final bool restoring, pending;
  final String? message;
  final bool messageIsError;
  const PurchaseUi({
    this.buying,
    this.restoring = false,
    this.pending = false,
    this.message,
    this.messageIsError = false,
  });
  bool get busy => buying != null || restoring;
  PurchaseUi copyWith({
    Object? buying = _keep,
    bool? restoring,
    bool? pending,
    Object? message = _keep,
    bool? messageIsError,
  }) => PurchaseUi(
    buying: identical(buying, _keep) ? this.buying : buying as String?,
    restoring: restoring ?? this.restoring,
    pending: pending ?? this.pending,
    message: identical(message, _keep) ? this.message : message as String?,
    messageIsError: messageIsError ?? this.messageIsError,
  );
  static const _keep = Object();
}

/// Buying, restoring and the purchases the store hands over (new ones, restored ones, and ones it re-delivers because they were never completed).
/// Store purchase -> server verify -> complete with the store -> refresh. The purchase token is passed to the server and forgotten.
final purchaseControllerProvider =
    NotifierProvider<PurchaseController, PurchaseUi>(PurchaseController.new);

class PurchaseController extends Notifier<PurchaseUi> {
  StreamSubscription<StorePurchase>? _sub;
  final _inFlight = <String>{};
  final _done = <String>{};
  Timer? _retry, _restoreTimer;
  int _retries = 0, _restoredSeen = 0;

  @override
  PurchaseUi build() {
    final service = ref.watch(purchaseServiceProvider);
    // Listens only while the shop exists for this member (an adult, locks apply, a store is configured, a phone).
    final open = ref.watch(shopAvailableProvider);
    if (open && service.supported) {
      _sub = service.updates.listen(_onPurchase, onError: (_) {});
    }
    ref.onDispose(() {
      _sub?.cancel();
      _retry?.cancel();
      _restoreTimer?.cancel();
    });
    return const PurchaseUi();
  }

  PurchaseService get _service => ref.read(purchaseServiceProvider);
  BillingState get _billing =>
      ref.read(billingStateProvider).asData?.value ?? BillingState.none;

  String? _userId() => ref.read(sessionProvider).asData?.value?.userId;

  void clearMessage() => state = state.copyWith(message: null);

  /// Starts buying [catalogId] (a coin pack or a Premium plan). The result arrives as a purchase update.
  Future<void> buy(String catalogId) async {
    if (state.busy || !_billing.shop) return;
    final store = ref.read(purchaseStoreProvider);
    final userId = _userId();
    CoinPack? pack;
    PremiumPlan? plan;
    for (final p in _billing.coinPacks) {
      if (p.id == catalogId) pack = p;
    }
    for (final p in _billing.plans) {
      if (p.id == catalogId) plan = p;
    }
    final storeId = pack != null
        ? (store == PurchaseStore.googlePlay
              ? pack.googleProductId
              : pack.appProductId)
        : plan != null
        ? (store == PurchaseStore.googlePlay
              ? plan.googleProductId
              : plan.appProductId)
        : null;
    final product = storeId == null
        ? null
        : (await ref.read(storeProductsProvider.future))[storeId];
    if (product == null || userId == null) {
      state = state.copyWith(
        message: 'The store doesn’t list this right now. Try again later.',
        messageIsError: true,
      );
      return;
    }
    state = state.copyWith(
      buying: catalogId,
      message: null,
      messageIsError: false,
    );
    try {
      await _service.buy(product, subscription: plan != null, userId: userId);
    } catch (_) {
      state = state.copyWith(
        buying: null,
        message: 'The purchase couldn’t be started. Nothing was charged.',
        messageIsError: true,
      );
    }
  }

  /// Asks the store for purchases this account already owns (subscriptions) and verifies each with the server.
  Future<void> restore() async {
    final userId = _userId();
    if (state.busy || userId == null || !_billing.shop) return;
    _restoredSeen = 0;
    state = state.copyWith(
      restoring: true,
      message: null,
      messageIsError: false,
    );
    try {
      await _service.restore(userId);
    } catch (_) {
      state = state.copyWith(
        restoring: false,
        message: 'The store couldn’t be reached. Try again in a moment.',
        messageIsError: true,
      );
      return;
    }
    _restoreTimer?.cancel();
    _restoreTimer = Timer(const Duration(seconds: 6), () {
      if (!state.restoring) return;
      state = state.copyWith(
        restoring: false,
        message: _restoredSeen == 0
            ? 'Nothing to restore on this store account.'
            : null,
      );
    });
  }

  Future<void> _onPurchase(StorePurchase p) async {
    switch (p.status) {
      case StorePurchaseStatus.pending:
        state = state.copyWith(
          pending: true,
          message: 'Waiting for the store to confirm your payment. Nothing is added until it does.',
          messageIsError: false,
        );
      case StorePurchaseStatus.canceled:
        state = state.copyWith(buying: null, restoring: false);
      case StorePurchaseStatus.error:
        state = state.copyWith(
          buying: null,
          restoring: false,
          message: 'The purchase didn’t go through. You haven’t been charged.',
          messageIsError: true,
        );
      case StorePurchaseStatus.purchased:
      case StorePurchaseStatus.restored:
        if (p.status == StorePurchaseStatus.restored) _restoredSeen++;
        await _verify(p);
    }
  }

  String? _catalogId(String storeProductId) {
    final google = ref.read(purchaseStoreProvider) == PurchaseStore.googlePlay;
    for (final p in _billing.coinPacks) {
      if ((google ? p.googleProductId : p.appProductId) == storeProductId) {
        return p.id;
      }
    }
    for (final p in _billing.plans) {
      if ((google ? p.googleProductId : p.appProductId) == storeProductId) {
        return p.id;
      }
    }
    return null;
  }

  Future<void> _verify(StorePurchase p) async {
    final token = p.token;
    final catalogId = _catalogId(p.productId);
    if (token == null || token.isEmpty || catalogId == null) {
      state = state.copyWith(buying: null, restoring: false);
      return;
    }
    // The same purchase can arrive twice (a re-delivery, a restore): it is verified once at a time and not again once done.
    if (_done.contains(token) || !_inFlight.add(token)) return;
    final store = ref.read(purchaseStoreProvider);
    try {
      final result = await ref
          .read(billingBackendProvider)
          .verify(
            store: store,
            productId: catalogId,
            purchaseToken: store == PurchaseStore.googlePlay ? token : null,
            transactionId: store == PurchaseStore.appStore ? token : null,
          );
      if (result.pending) {
        state = state.copyWith(
          buying: null,
          restoring: false,
          pending: true,
          message: 'Your payment is pending. We’ll add it as soon as the store confirms it.',
          messageIsError: false,
        );
        return;
      }
      _retries = 0;
      _done.add(token);
      await _service.complete(p);
      ref.read(billingStateProvider.notifier).applyBalance(result.balance);
      unawaited(ref.read(billingStateProvider.notifier).refresh());
      state = state.copyWith(
        buying: null,
        restoring: false,
        pending: false,
        message: result.kind == 'subscription'
            ? 'Premium is on.'
            : result.alreadyProcessed
            ? 'That purchase was already added.'
            : '${result.coinsGranted} coins added.',
        messageIsError: false,
      );
    } on ApiFailure catch (e) {
      final definite =
          e.code == 'PURCHASE_CLAIMED' || e.code == 'PURCHASE_INVALID';
      if (definite) {
        // The store will never confirm it for this account: complete it so it stops coming back.
        _done.add(token);
        await _service.complete(p);
      } else {
        _scheduleRetry(p);
      }
      state = state.copyWith(
        buying: null,
        restoring: false,
        message: definite ? e.displayMessage : 'We couldn’t confirm your purchase yet. It is safe with the store and we’ll try again.',
        messageIsError: true,
      );
    } catch (_) {
      _scheduleRetry(p);
      state = state.copyWith(
        buying: null,
        restoring: false,
        message: 'We couldn’t confirm your purchase yet. It is safe with the store and we’ll try again.',
        messageIsError: true,
      );
    } finally {
      _inFlight.remove(token);
    }
  }

  void _scheduleRetry(StorePurchase p) {
    if (_retries >= 5) return;
    _retries++;
    _retry?.cancel();
    _retry = Timer(
      Duration(seconds: 20 * _retries),
      () => unawaited(_verify(p)),
    );
  }
}

/// What the rewarded-ad flow tells the screen.
class AdsUi {
  final bool busy;
  final String? message;
  const AdsUi({this.busy = false, this.message});
}

/// Watching a short video for coins: session -> ad -> poll for the server's credit. Adults only, and only when the server says ads are on.
final adsControllerProvider = NotifierProvider<AdsController, AdsUi>(
  AdsController.new,
);

class AdsController extends Notifier<AdsUi> {
  bool _prepared = false;

  @override
  AdsUi build() => const AdsUi();

  Future<void> watch() async {
    final billing =
        ref.read(billingStateProvider).asData?.value ?? BillingState.none;
    final service = ref.read(adsServiceProvider);
    if (state.busy ||
        !billing.showsPlans ||
        !billing.adsEligible ||
        !billing.ads.enabled ||
        billing.ads.remainingToday <= 0 ||
        !service.configured) {
      return;
    }
    state = const AdsUi(busy: true);
    try {
      if (!_prepared) {
        _prepared = await service.prepare(confirmedAdult: billing.monetizable);
      }
      if (!_prepared) {
        state = const AdsUi(
          message: 'Rewarded videos aren’t available right now.',
        );
        return;
      }
      final backend = ref.read(billingBackendProvider);
      final session = await backend.startAdSession();
      final outcome = await service.showRewarded(
        userId: session.userId,
        customData: session.customData,
      );
      switch (outcome) {
        case AdOutcome.rewarded:
          state = const AdsUi(busy: true, message: 'Adding your coins…');
          state = AdsUi(message: await _poll(backend, session));
        case AdOutcome.dismissed:
          state = const AdsUi(
            message:
                'The video was closed before the end, so no coins were added.',
          );
        case AdOutcome.unavailable:
          state = const AdsUi(
            message: 'No video is available right now. Try again later.',
          );
        case AdOutcome.noConsent:
          state = const AdsUi(
            message: 'Rewarded videos need your choice on ads first.',
          );
      }
    } on ApiFailure catch (e) {
      state = AdsUi(message: e.displayMessage);
    } catch (_) {
      state = const AdsUi(message: 'Something went wrong. Try again.');
    } finally {
      unawaited(ref.read(billingStateProvider.notifier).refresh());
    }
  }

  Future<String> _poll(BillingBackend backend, AdSession session) async {
    final timing = ref.read(adsPollProvider);
    final deadline = DateTime.now().add(timing.upTo);
    while (true) {
      final reward = await backend.adReward(session.nonce);
      switch (reward.status) {
        case 'credited':
          ref.read(billingStateProvider.notifier).applyBalance(reward.balance);
          return '${reward.coins} ${reward.coins == 1 ? 'coin' : 'coins'} added.';
        case 'rejected':
          return 'That reward couldn’t be added.';
        case 'expired':
          return 'That video took too long, so no coins were added.';
      }
      if (DateTime.now().isAfter(deadline)) {
        return 'Your reward is on its way. Check your balance in a moment.';
      }
      await Future<void>.delayed(timing.every);
    }
  }
}
