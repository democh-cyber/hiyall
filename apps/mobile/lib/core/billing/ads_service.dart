import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' as ads;

/// Release ad unit ids come from the build (`--dart-define=ADMOB_REWARDED_ANDROID=...`, `ADMOB_REWARDED_IOS`); never from the repository.
const _releaseAndroid = String.fromEnvironment('ADMOB_REWARDED_ANDROID');
const _releaseIos = String.fromEnvironment('ADMOB_REWARDED_IOS');

/// Google's published TEST rewarded ad unit ids (https://developers.google.com/admob/android/test-ads and /ios/test-ads). They are used in debug builds
/// only, and they serve test ads that earn nothing.
const googleTestRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
const googleTestRewardedIos = 'ca-app-pub-3940256099942544/1712485313';

/// The rewarded ad unit for this build, or null when ads are not configured (a release build without the defines): then there are no ads.
String? rewardedAdUnitId({
  required bool debug,
  required TargetPlatform platform,
  String android = _releaseAndroid,
  String ios = _releaseIos,
}) {
  final String id;
  switch (platform) {
    case TargetPlatform.android:
      id = debug ? googleTestRewardedAndroid : android;
    case TargetPlatform.iOS:
      id = debug ? googleTestRewardedIos : ios;
    default:
      return null;
  }
  return id.isEmpty ? null : id;
}

/// How a rewarded ad ended.
enum AdOutcome { rewarded, dismissed, unavailable, noConsent }

/// Rewarded video ads: an interface so the flow is tested with a fake and no test touches the ads SDK.
abstract class AdsService {
  /// Whether ads can exist at all in this build and on this platform (an ad unit is configured).
  bool get configured;

  /// Sets the audience flags and runs the consent flow (Google's User Messaging Platform, when it is required), then starts the SDK.
  /// [confirmedAdult] is the server's word that the member is an adult with a known age: every other state is treated as child-directed.
  /// True when ads may be requested.
  Future<bool> prepare({required bool confirmedAdult});

  /// Loads and shows one rewarded ad. [userId] and [customData] go to AdMob as the server-side verification options.
  Future<AdOutcome> showRewarded({
    required String userId,
    required String customData,
  });
}

class NoAdsService implements AdsService {
  const NoAdsService();
  @override
  bool get configured => false;
  @override
  Future<bool> prepare({required bool confirmedAdult}) async => false;
  @override
  Future<AdOutcome> showRewarded({
    required String userId,
    required String customData,
  }) async => AdOutcome.unavailable;
}

/// The official `google_mobile_ads` plugin.
class GoogleAdsService implements AdsService {
  final String? _unitId;
  GoogleAdsService({String? unitId})
    : _unitId =
          unitId ??
          rewardedAdUnitId(debug: kDebugMode, platform: defaultTargetPlatform);

  bool _started = false;

  @override
  bool get configured =>
      !kIsWeb &&
      _unitId != null &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<bool> prepare({required bool confirmedAdult}) async {
    if (!configured) return false;
    try {
      // Anything but a confirmed adult gets child treatment (child-directed, under the age of consent), whatever else is known.
      await ads.MobileAds.instance.updateRequestConfiguration(
        ads.RequestConfiguration(
          // The package's current replacement of the child-directed and under-age-of-consent tags.
          ageRestrictedTreatment: confirmedAdult
              ? ads.AgeRestrictedTreatment.unspecified
              : ads.AgeRestrictedTreatment.child,
          maxAdContentRating: ads.MaxAdContentRating.pg,
        ),
      );
      if (!confirmedAdult) return false;
      if (!await _consent()) return false;
      if (!_started) {
        await ads.MobileAds.instance.initialize();
        _started = true;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Google's User Messaging Platform: asks for the consent the member's region requires, and says whether ads may be requested.
  Future<bool> _consent() async {
    final updated = Completer<bool>();
    ads.ConsentInformation.instance.requestConsentInfoUpdate(
      ads.ConsentRequestParameters(tagForUnderAgeOfConsent: false),
      () => updated.complete(true),
      (_) => updated.complete(false),
    );
    // A failed update can still leave consent from an earlier session; canRequestAds says.
    await updated.future;
    final formDone = Completer<void>();
    unawaited(
      ads.ConsentForm.loadAndShowConsentFormIfRequired((_) {
        if (!formDone.isCompleted) formDone.complete();
      }),
    );
    await formDone.future;
    return ads.ConsentInformation.instance.canRequestAds();
  }

  @override
  Future<AdOutcome> showRewarded({
    required String userId,
    required String customData,
  }) async {
    final unit = _unitId;
    if (!configured || unit == null) return AdOutcome.unavailable;
    final loaded = Completer<ads.RewardedAd?>();
    await ads.RewardedAd.load(
      adUnitId: unit,
      request: const ads.AdRequest(),
      rewardedAdLoadCallback: ads.RewardedAdLoadCallback(
        onAdLoaded: loaded.complete,
        onAdFailedToLoad: (_) => loaded.complete(null),
      ),
    );
    final ad = await loaded.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => null,
    );
    if (ad == null) return AdOutcome.unavailable;
    await ad.setServerSideOptions(
      ads.ServerSideVerificationOptions(userId: userId, customData: customData),
    );
    final done = Completer<AdOutcome>();
    var earned = false;
    ad.fullScreenContentCallback =
        ads.FullScreenContentCallback<ads.RewardedAd>(
          onAdDismissedFullScreenContent: (ad) {
            ad.dispose();
            if (!done.isCompleted) {
              done.complete(earned ? AdOutcome.rewarded : AdOutcome.dismissed);
            }
          },
          onAdFailedToShowFullScreenContent: (ad, _) {
            ad.dispose();
            if (!done.isCompleted) done.complete(AdOutcome.unavailable);
          },
        );
    await ad.show(onUserEarnedReward: (_, _) => earned = true);
    return done.future;
  }
}
