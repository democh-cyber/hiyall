import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart' as iap;

/// A product as the store shows it. The price text is the store's own, localized: it is never computed or hard-coded here.
class StoreProduct {
  final String id, title, price;
  final Object? raw;
  const StoreProduct(this.id, this.title, this.price, [this.raw]);
}

enum StorePurchaseStatus { pending, purchased, restored, error, canceled }

/// One purchase event from the store. [token] is what the server verifies with (a Google purchase token, an App Store
/// transaction id). It is passed on and forgotten: never logged, never stored.
class StorePurchase {
  final String productId;
  final StorePurchaseStatus status;
  final String? token;
  final String? errorMessage;
  final Object? raw;
  const StorePurchase({
    required this.productId,
    required this.status,
    this.token,
    this.errorMessage,
    this.raw,
  });
}

/// The store side of buying: an interface so the flow is tested with a fake and never touches a platform channel in a test.
abstract class PurchaseService {
  /// False where there is no store (web, desktop, tests without a fake).
  bool get supported;
  Future<bool> isAvailable();

  /// Purchase events: new purchases, restored ones, and ones the store re-delivers because they were never completed.
  Stream<StorePurchase> get updates;
  Future<Map<String, StoreProduct>> products(Set<String> storeIds);

  /// Starts a purchase; the result arrives on [updates]. [userId] is attached to it (Google obfuscatedAccountId, Apple
  /// appAccountToken) so the server can tie a store notification to the member.
  Future<void> buy(
    StoreProduct product, {
    required bool subscription,
    required String userId,
  });
  Future<void> restore(String userId);

  /// Tells the store the server has delivered the purchase (acknowledges or consumes it).
  Future<void> complete(StorePurchase purchase);
}

/// No store: the Shop never opens here.
class NoPurchaseService implements PurchaseService {
  const NoPurchaseService();
  @override
  bool get supported => false;
  @override
  Future<bool> isAvailable() async => false;
  @override
  Stream<StorePurchase> get updates => const Stream.empty();
  @override
  Future<Map<String, StoreProduct>> products(Set<String> storeIds) async =>
      const {};
  @override
  Future<void> buy(
    StoreProduct product, {
    required bool subscription,
    required String userId,
  }) async {}
  @override
  Future<void> restore(String userId) async {}
  @override
  Future<void> complete(StorePurchase purchase) async {}
}

/// The official `in_app_purchase` plugin (Google Play Billing, StoreKit).
class InAppPurchaseService implements PurchaseService {
  final iap.InAppPurchase? _plugin;
  InAppPurchaseService([this._plugin]);

  // Resolved on first use, so building the service touches no platform channel.
  iap.InAppPurchase get _iap => _plugin ?? iap.InAppPurchase.instance;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<bool> isAvailable() async {
    if (!supported) return false;
    try {
      return await _iap.isAvailable();
    } catch (_) {
      return false;
    }
  }

  StorePurchaseStatus _status(iap.PurchaseStatus s) => switch (s) {
    iap.PurchaseStatus.pending => StorePurchaseStatus.pending,
    iap.PurchaseStatus.purchased => StorePurchaseStatus.purchased,
    iap.PurchaseStatus.restored => StorePurchaseStatus.restored,
    iap.PurchaseStatus.error => StorePurchaseStatus.error,
    iap.PurchaseStatus.canceled => StorePurchaseStatus.canceled,
  };

  @override
  Stream<StorePurchase> get updates => _iap.purchaseStream.expand(
    (list) => [
      for (final p in list)
        StorePurchase(
          productId: p.productID,
          status: _status(p.status),
          // Google: the purchase token. Apple: the transaction id.
          token: defaultTargetPlatform == TargetPlatform.iOS
              ? p.purchaseID
              : p.verificationData.serverVerificationData,
          errorMessage: p.error?.message,
          raw: p,
        ),
    ],
  );

  @override
  Future<Map<String, StoreProduct>> products(Set<String> storeIds) async {
    if (storeIds.isEmpty) return const {};
    final response = await _iap.queryProductDetails(storeIds);
    return {
      for (final p in response.productDetails)
        p.id: StoreProduct(p.id, p.title, p.price, p),
    };
  }

  @override
  Future<void> buy(
    StoreProduct product, {
    required bool subscription,
    required String userId,
  }) async {
    final details = product.raw as iap.ProductDetails;
    final param = iap.PurchaseParam(
      productDetails: details,
      applicationUserName: userId,
    );
    if (subscription) {
      await _iap.buyNonConsumable(purchaseParam: param);
    } else {
      // Google consumes it at once (so the pack can be bought again); if the app dies before the server
      // verified it, the store's notification to the server (the purchase carries the member's id) grants it.
      await _iap.buyConsumable(purchaseParam: param);
    }
  }

  @override
  Future<void> restore(String userId) =>
      _iap.restorePurchases(applicationUserName: userId);

  @override
  Future<void> complete(StorePurchase purchase) async {
    final raw = purchase.raw;
    if (raw is iap.PurchaseDetails && raw.pendingCompletePurchase) {
      await _iap.completePurchase(raw);
    }
  }
}
