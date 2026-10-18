# Shop, coins, Premium and rewarded ads (app)

Server contract: docs/api/28-billing.md. Owner steps for the stores: docs/deployment/10-deploy-guide.md, section 12.

## Rules the app keeps

* **Adults only, decided by the server.** `GET /v1/me/billing` says `locksApply` and `eligibility.shop`. Everything about plans (the Shop route, the Settings entry and coin pill, locked-feature sheets, spend confirmations, the profile "details locked" card, ads) appears only when `BillingState.showsPlans` is true (`locksApply && monetizable`). While the state is loading, after a failed read, on the web, for a minor or a member with no known age, and while plans are not enforced, nothing appears (fail closed). `/shop` sends anyone who may not shop to `/home`.
* **Prices are the store's**, read from `ProductDetails.price`. The catalog says only what is granted. No countdowns, no scarcity, no pre-selected plan; "Restore purchases" and "Manage or cancel Premium" (the store's subscription page) are always visible.
* **Every spend asks first**, with the cost and the balance (`confirmSpend`): starting a chat past the free allowance sends the confirmed price as the `Spend-Confirm` header; unlocking profile details sends `{"confirmCost": n}`. Declining sends nothing. Short of coins the sheet offers the Shop instead of a spend button.
* **Nothing about a purchase is stored or logged.** The token goes from the store to the server and is forgotten.

## Code

`lib/core/billing/`: `billing_models.dart` (defensive parsing), `billing_api.dart` (`BillingBackend` interface and the HTTP client over `ApiClient.send`), `purchase_service.dart` (`PurchaseService` over `in_app_purchase`, `NoPurchaseService`), `ads_service.dart` (`AdsService` over `google_mobile_ads`, `rewardedAdUnitId`), `billing_state.dart` (providers and the `PurchaseController` / `AdsController` flows). `lib/features/shop/`: `ShopScreen`, `LockedFeatureSheet`, `confirmSpend` and `openChatConfirmingSpend`, `ProfileDetailsLockedCard`, `BillingSettingsGroup`, `CoinPill`. `ApiFailureDetails` (core/api.dart) carries the 402 `error.details`; `premiumRequiredHandlerProvider` (bound in `lib/bindings.dart`) makes `showFailure` open the Premium sheet for `PREMIUM_REQUIRED`.

**Purchase flow**: store purchase -> `POST /v1/me/billing/purchases/verify` -> `complete` with the store -> refresh. Pending payments show a pending state and complete later from the server's notification. A store that cannot be reached keeps the purchase (it is not completed; the store re-delivers it and a retry runs); a purchase the store will never confirm for this account (`PURCHASE_CLAIMED`, `PURCHASE_INVALID`) is completed so it stops coming back. The same purchase delivered twice is verified once. Coin packs are consumed by the plugin at purchase time; if the app dies before verifying, the server grants it from Google's notification (the purchase carries the member's id as `applicationUserName`). Unfinished purchases are delivered when Settings or the Shop is next opened.

**Rewarded ads**: `POST .../ads/session` -> the SDK is given `userId` and `customData` as server-side verification options -> the app polls `POST .../ads/reward` (every 2 s up to 20 s). Coins are credited by Google's signed callback only. Only for a confirmed adult, with consent (Google's User Messaging Platform) and with ads enabled by the server. Anything but a confirmed adult gets `AgeRestrictedTreatment.child`. Debug builds use Google's published test ad units; release builds need `--dart-define=ADMOB_REWARDED_ANDROID` / `ADMOB_REWARDED_IOS`, otherwise there are no ads.

## Build configuration

* Android: `com.android.vending.BILLING` permission; the AdMob app id is a manifest placeholder `admobAppId` from `ADMOB_APP_ID_ANDROID` (environment or gradle property). Debug builds default to Google's test app id; a **release build fails** without it (and refuses the test id).
* iOS: `GADApplicationIdentifier` is `$(ADMOB_APP_ID_IOS)`; `Debug.xcconfig` carries Google's test id, `Release.xcconfig` is empty and includes an optional git-ignored `Admob.xcconfig` the release build writes. The In-App Purchase capability must be enabled on the app id and the target in Xcode (an owner step; nothing in the repository enables it). AdMob also recommends the `SKAdNetworkItems` list in Info.plist (owner step). The app never requests App Tracking Transparency; ads are not personalized without consent.

## Tests

Fakes for the store, the ads SDK and the billing API are in `test/support/billing_fakes.dart`. `test/billing_core_test.dart` (models, fail-closed, purchase and ad flows, 402 details), `test/shop_screen_test.dart` (the Shop, minors, 320 px at text scale 2.0, right to left, reduced motion, 48 px targets, spend gate, locked sheet, details card, Settings entry). Previews: `flutter test test/shop_preview_test.dart --dart-define=CAPTURE_SHOP=true` writes `.runtime/shop-previews-v7/`.
