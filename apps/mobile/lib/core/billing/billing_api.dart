import '../api.dart';
import 'billing_models.dart';

/// The billing routes (docs/api/28-billing.md). An interface so screens and flows are tested with a fake.
abstract class BillingBackend {
  Future<BillingState> state();
  Future<LedgerPage> history({String? cursor, int limit = 20});
  Future<VerifyResult> verify({
    required PurchaseStore store,
    required String productId,
    String? purchaseToken,
    String? transactionId,
  });
  Future<AdSession> startAdSession();
  Future<AdReward> adReward(String nonce);
  Future<ProfileBonusResult> claimProfileBonus();
  Future<DetailsUnlock> unlockProfileDetails(String userId, {int? confirmCost});
}

/// One request: method, path, optional JSON body. The app binds it to the signed-in [ApiClient.send].
typedef BillingRequest = Future<dynamic> Function(
  String method,
  String path, {
  Object? body,
});

class HttpBillingBackend implements BillingBackend {
  final BillingRequest _send;
  const HttpBillingBackend(this._send);

  Map<String, dynamic> _object(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    throw const ApiFailure('Something went wrong. Try again.');
  }

  @override
  Future<BillingState> state() async =>
      BillingState.fromJson(_object(await _send('GET', '/v1/me/billing')));

  @override
  Future<LedgerPage> history({String? cursor, int limit = 20}) async {
    final query =
        'limit=$limit${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}';
    return LedgerPage.fromJson(
      _object(await _send('GET', '/v1/me/billing/history?$query')),
    );
  }

  @override
  Future<VerifyResult> verify({
    required PurchaseStore store,
    required String productId,
    String? purchaseToken,
    String? transactionId,
  }) async => VerifyResult.fromJson(
    _object(
      await _send(
        'POST',
        '/v1/me/billing/purchases/verify',
        body: {
          'store': store.wire,
          'productId': productId,
          'purchaseToken': ?purchaseToken,
          'transactionId': ?transactionId,
        },
      ),
    ),
  );

  @override
  Future<AdSession> startAdSession() async => AdSession.fromJson(
    _object(await _send('POST', '/v1/me/billing/ads/session')),
  );

  @override
  Future<AdReward> adReward(String nonce) async => AdReward.fromJson(
    _object(
      await _send('POST', '/v1/me/billing/ads/reward', body: {'nonce': nonce}),
    ),
  );

  @override
  Future<ProfileBonusResult> claimProfileBonus() async =>
      ProfileBonusResult.fromJson(
        _object(
          await _send('POST', '/v1/me/billing/bonuses/profile-completion'),
        ),
      );

  @override
  Future<DetailsUnlock> unlockProfileDetails(
    String userId, {
    int? confirmCost,
  }) async => DetailsUnlock.fromJson(
    _object(
      await _send(
        'POST',
        '/v1/users/$userId/profile-details/unlock',
        body: {'confirmCost': ?confirmCost},
      ),
    ),
  );
}
