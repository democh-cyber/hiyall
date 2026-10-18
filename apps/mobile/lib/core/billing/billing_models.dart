/// The billing API's data (docs/api/28-billing.md), parsed defensively: a field the server leaves out reads as
/// "nothing here", never as an error that would put a half-parsed shop on screen.
library;

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};
List<Map<String, dynamic>> _list(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is Map) Map<String, dynamic>.from(e),
      ]
    : const [];
int _int(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// The two stores.
enum PurchaseStore { googlePlay, appStore }

extension PurchaseStoreWire on PurchaseStore {
  String get wire =>
      this == PurchaseStore.googlePlay ? 'google_play' : 'app_store';
}

/// What a plan feature is worth in a plan, one cell of the "Free vs Premium" table.
enum BenefitKind { included, notIncluded, unlimited, limit, coins }

class BenefitCell {
  final BenefitKind kind;
  final int value;
  final String unit;
  final int days;
  const BenefitCell(this.kind, {this.value = 0, this.unit = '', this.days = 0});
  factory BenefitCell.fromJson(Object? json) {
    final m = _map(json);
    final kind = switch (m['type']) {
      'included' => BenefitKind.included,
      'unlimited' => BenefitKind.unlimited,
      'limit' => BenefitKind.limit,
      'coins' => BenefitKind.coins,
      _ => BenefitKind.notIncluded,
    };
    return BenefitCell(
      kind,
      value: _int(m['value']),
      unit: _str(m['unit']) ?? '',
      days: _int(m['days']),
    );
  }
}

class Benefit {
  final String key, title;
  final BenefitCell free, premium;
  const Benefit(this.key, this.title, this.free, this.premium);
  factory Benefit.fromJson(Map<String, dynamic> m) => Benefit(
    _str(m['key']) ?? '',
    _str(m['title']) ?? '',
    BenefitCell.fromJson(m['free']),
    BenefitCell.fromJson(m['premium']),
  );
}

/// A coin pack. The price is the store's, shown from its product details; the server only says what is granted.
class CoinPack {
  final String id, name;
  final int coins, bonusCoins, priceTier;
  final String googleProductId, appProductId;
  const CoinPack({
    required this.id,
    required this.name,
    required this.coins,
    required this.bonusCoins,
    required this.priceTier,
    required this.googleProductId,
    required this.appProductId,
  });
  int get total => coins + bonusCoins;
  factory CoinPack.fromJson(Map<String, dynamic> m) {
    final ids = _map(m['storeProductIds']);
    final id = _str(m['id']) ?? '';
    return CoinPack(
      id: id,
      name: _str(m['name']) ?? id,
      coins: _int(m['coins']),
      bonusCoins: _int(m['bonusCoins']),
      priceTier: _int(m['priceTier']),
      googleProductId: _str(ids['googlePlay']) ?? id,
      appProductId: _str(ids['appStore']) ?? id,
    );
  }
}

class PremiumPlan {
  final String id, name;
  final int periodMonths, priceTier;
  final String googleProductId, appProductId;
  const PremiumPlan({
    required this.id,
    required this.name,
    required this.periodMonths,
    required this.priceTier,
    required this.googleProductId,
    required this.appProductId,
  });
  factory PremiumPlan.fromJson(Map<String, dynamic> m) {
    final ids = _map(m['storeProductIds']);
    final id = _str(m['id']) ?? '';
    return PremiumPlan(
      id: id,
      name: _str(m['name']) ?? id,
      periodMonths: _int(m['periodMonths'], 1),
      priceTier: _int(m['priceTier']),
      googleProductId: _str(ids['googlePlay']) ?? id,
      appProductId: _str(ids['appStore']) ?? id,
    );
  }
}

/// The member's subscription as the server last knew it.
class PlanInfo {
  final String id, status;
  final String? store, productId;
  final DateTime? currentPeriodEnd, graceUntil;
  final bool autoRenew;
  const PlanInfo({
    this.id = 'free',
    this.status = 'none',
    this.store,
    this.productId,
    this.currentPeriodEnd,
    this.graceUntil,
    this.autoRenew = false,
  });
  bool get isPremium => id == 'premium';
  bool get hasSubscription => status != 'none';
  factory PlanInfo.fromJson(Object? json) {
    final m = _map(json);
    return PlanInfo(
      id: _str(m['id']) ?? 'free',
      status: _str(m['status']) ?? 'none',
      store: _str(m['store']),
      productId: _str(m['productId']),
      currentPeriodEnd: _time(m['currentPeriodEnd']),
      graceUntil: _time(m['graceUntil']),
      autoRenew: m['autoRenew'] == true,
    );
  }
}

/// What the member may use, from `entitlements`.
class Entitlements {
  final Map<String, bool> features;

  /// Conversations a Free member may start per day before one costs coins; null: no limit.
  final int? freeNewChatsPerDay;
  final int chatSlotCoinCost, profileDetailCoinCost, profileDetailDays;
  const Entitlements({
    this.features = const {},
    this.freeNewChatsPerDay,
    this.chatSlotCoinCost = 0,
    this.profileDetailCoinCost = 0,
    this.profileDetailDays = 0,
  });
  bool has(String feature) => features[feature] ?? true;
  factory Entitlements.fromJson(Object? json) {
    final m = _map(json);
    return Entitlements(
      features: {
        for (final e in _map(m['features']).entries) e.key: e.value == true,
      },
      freeNewChatsPerDay: m['freeNewChatsPerDay'] is num
          ? _int(m['freeNewChatsPerDay'])
          : null,
      chatSlotCoinCost: _int(m['chatSlotCoinCost']),
      profileDetailCoinCost: _int(m['profileDetailCoinCost']),
      profileDetailDays: _int(m['profileDetailDays']),
    );
  }
}

class AdsInfo {
  final bool enabled;
  final int coinsPerAd, dailyCap, watchedToday;
  const AdsInfo({
    this.enabled = false,
    this.coinsPerAd = 0,
    this.dailyCap = 0,
    this.watchedToday = 0,
  });
  int get remainingToday => (dailyCap - watchedToday).clamp(0, dailyCap);
  factory AdsInfo.fromJson(Object? json) {
    final m = _map(json);
    return AdsInfo(
      enabled: m['enabled'] == true,
      coinsPerAd: _int(m['coinsPerAd']),
      dailyCap: _int(m['dailyCap']),
      watchedToday: _int(m['watchedToday']),
    );
  }
}

/// GET /v1/me/billing.
class BillingState {
  final bool enforced, locksApply, monetizable, shop, adsEligible;
  final bool googlePlay, appStore;
  final String? reason;
  final int balance;
  final PlanInfo plan;
  final Entitlements entitlements;
  final List<CoinPack> coinPacks;
  final List<PremiumPlan> plans;
  final List<Benefit> benefits;
  final AdsInfo ads;
  final int profileBonusCoins;
  final bool profileBonusClaimed;
  const BillingState({
    this.enforced = false,
    this.locksApply = false,
    this.monetizable = false,
    this.shop = false,
    this.adsEligible = false,
    this.googlePlay = false,
    this.appStore = false,
    this.reason,
    this.balance = 0,
    this.plan = const PlanInfo(),
    this.entitlements = const Entitlements(),
    this.coinPacks = const [],
    this.plans = const [],
    this.benefits = const [],
    this.ads = const AdsInfo(),
    this.profileBonusCoins = 0,
    this.profileBonusClaimed = false,
  });

  /// Nothing about plans is shown: the state before it loads, after a failure, and for a member who cannot buy.
  static const none = BillingState();

  /// The ONLY condition under which locks, prices, upsells and the coin pill appear.
  bool get showsPlans => locksApply && monetizable;

  BillingState withBalance(int value) => BillingState(
    enforced: enforced,
    locksApply: locksApply,
    monetizable: monetizable,
    shop: shop,
    adsEligible: adsEligible,
    googlePlay: googlePlay,
    appStore: appStore,
    reason: reason,
    balance: value,
    plan: plan,
    entitlements: entitlements,
    coinPacks: coinPacks,
    plans: plans,
    benefits: benefits,
    ads: ads,
    profileBonusCoins: profileBonusCoins,
    profileBonusClaimed: profileBonusClaimed,
  );

  factory BillingState.fromJson(Map<String, dynamic> m) {
    final elig = _map(m['eligibility']);
    final stores = _map(elig['stores']);
    final catalog = _map(m['catalog']);
    final bonus = _map(_map(m['bonuses'])['profileCompletion']);
    final monetizable = elig['monetizable'] == true;
    return BillingState(
      enforced: m['enforced'] == true,
      // Fail closed: nothing shows unless the member can buy and the server says locks apply.
      locksApply: m['locksApply'] == true && monetizable,
      monetizable: monetizable,
      shop: elig['shop'] == true && monetizable,
      adsEligible: elig['ads'] == true && monetizable,
      googlePlay: stores['googlePlay'] == true,
      appStore: stores['appStore'] == true,
      reason: _str(elig['reason']),
      balance: _int(m['balance']),
      plan: PlanInfo.fromJson(m['plan']),
      entitlements: Entitlements.fromJson(m['entitlements']),
      coinPacks: [
        for (final e in _list(catalog['coinPacks'])) CoinPack.fromJson(e),
      ],
      plans: [
        for (final e in _list(catalog['subscriptions']))
          PremiumPlan.fromJson(e),
      ],
      benefits: [for (final e in _list(m['benefits'])) Benefit.fromJson(e)],
      ads: AdsInfo.fromJson(m['ads']),
      profileBonusCoins: _int(bonus['coins']),
      profileBonusClaimed: bonus['claimed'] == true,
    );
  }
}

/// One row of the usage history.
class LedgerEntry {
  final String id, reason;
  final int delta, balanceAfter;
  final DateTime createdAt;
  const LedgerEntry(
    this.id,
    this.reason,
    this.delta,
    this.balanceAfter,
    this.createdAt,
  );
  factory LedgerEntry.fromJson(Map<String, dynamic> m) => LedgerEntry(
    _str(m['id']) ?? '',
    _str(m['reason']) ?? '',
    _int(m['delta']),
    _int(m['balanceAfter']),
    _time(m['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
}

class LedgerPage {
  final List<LedgerEntry> items;
  final String? nextCursor;
  const LedgerPage(this.items, this.nextCursor);
  factory LedgerPage.fromJson(Map<String, dynamic> m) => LedgerPage([
    for (final e in _list(m['items'])) LedgerEntry.fromJson(e),
  ], _str(m['nextCursor']));
}

/// The answer to verifying a purchase.
class VerifyResult {
  final String state, kind, productId;
  final int coinsGranted, balance;
  final bool alreadyProcessed;
  final PlanInfo plan;
  const VerifyResult({
    required this.state,
    required this.kind,
    required this.productId,
    required this.coinsGranted,
    required this.balance,
    required this.alreadyProcessed,
    required this.plan,
  });
  bool get pending => state == 'pending';
  factory VerifyResult.fromJson(Map<String, dynamic> m) => VerifyResult(
    state: _str(m['state']) ?? 'pending',
    kind: _str(m['kind']) ?? 'coins',
    productId: _str(m['productId']) ?? '',
    coinsGranted: _int(m['coinsGranted']),
    balance: _int(m['balance']),
    alreadyProcessed: m['alreadyProcessed'] == true,
    plan: PlanInfo.fromJson(m['plan']),
  );
}

/// What to give the ad SDK before showing a rewarded ad.
class AdSession {
  final String nonce, userId, customData;
  final int coins, remainingToday;
  const AdSession(
    this.nonce,
    this.userId,
    this.customData,
    this.coins,
    this.remainingToday,
  );
  factory AdSession.fromJson(Map<String, dynamic> m) => AdSession(
    _str(m['nonce']) ?? '',
    _str(m['userId']) ?? '',
    _str(m['customData']) ?? '',
    _int(m['coins']),
    _int(m['remainingToday']),
  );
}

/// pending, credited, rejected or expired.
class AdReward {
  final String status;
  final int coins, balance;
  const AdReward(this.status, this.coins, this.balance);
  factory AdReward.fromJson(Map<String, dynamic> m) => AdReward(
    _str(m['status']) ?? 'pending',
    _int(m['coins']),
    _int(m['balance']),
  );
}

class ProfileBonusResult {
  final bool granted, alreadyClaimed;
  final int coins, balance;
  const ProfileBonusResult(
    this.granted,
    this.alreadyClaimed,
    this.coins,
    this.balance,
  );
  factory ProfileBonusResult.fromJson(Map<String, dynamic> m) =>
      ProfileBonusResult(
        m['granted'] == true,
        m['alreadyClaimed'] == true,
        _int(m['coins']),
        _int(m['balance']),
      );
}

class DetailsUnlock {
  final bool unlocked;
  final DateTime? expiresAt;
  final int cost, balance;
  const DetailsUnlock(this.unlocked, this.expiresAt, this.cost, this.balance);
  factory DetailsUnlock.fromJson(Map<String, dynamic> m) => DetailsUnlock(
    m['unlocked'] == true,
    _time(m['expiresAt']),
    _int(m['cost']),
    _int(m['balance']),
  );
}
