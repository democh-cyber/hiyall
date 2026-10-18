# Billing: plans, coins, purchases and rewarded ads

**Status:** built; every store and ad credential is optional. With none set, the server answers
`503 BILLING_NOT_CONFIGURED` on the purchase endpoints and the app shows no shop. With `PLANS_ENFORCED=false` (the
default) nothing is limited or charged for anyone.

Design note: `docs/architecture/11-plans-and-entitlements.md`. Owner steps (store products, keys, endpoints):
`docs/deployment/10-deploy-guide.md#12-billing-plans-coins-and-ads`.

## Rules that hold everywhere

* **Adults only.** Purchases, coins, Premium and rewarded ads exist for members whose age is known and 18 or over. A
  member under 18, or whose age is unknown, gets `403 AGE_RESTRICTED` on every route below that moves money or
  coins, and is never gated or charged for anything else (their entitlements are unlocked, see `Resolve`). This is
  checked on the server from the stored birth date, never from anything the app says.
* **The server decides.** The app sends a store transaction identifier; the server asks the store itself and trusts only the
  store's signed answer. A grant happens once per store transaction (a hashed `tx_hash` is `UNIQUE`). Receipts and purchase tokens are
  never stored or logged.
* **Ledger.** Coins are an append-only ledger with idempotency keys; the balance can never be negative (a database `CHECK`);
  concurrent spends are serialised per member. A refund or chargeback is a ledger row that takes the coins back (as many as
  the balance still holds).
* **No surprise charges.** A spend is only made after the app sent the price the member confirmed (`SPEND_CONFIRMATION_REQUIRED`
  tells the app the price first). A price that changed since is a new confirmation.
* **Limits are on the server** (`domain.Entitlements`). The booleans the app reads are hints; the server checks them where
  the feature has a server path.

Envelope as everywhere (`{success, data, meta}`); errors may carry `error.details`.

## Error codes

| Status | Code | Meaning |
|---|---|---|
| 403 | `AGE_RESTRICTED` | Not an adult with a known age. Never shown as an age message. |
| 503 | `BILLING_NOT_CONFIGURED` | No credentials for the store of this request, or ads are off. |
| 502 | `STORE_UNAVAILABLE` | The store could not be reached. Keep the purchase and retry (it is idempotent). |
| 422 | `PURCHASE_INVALID` | The store does not confirm a completed purchase of this product for this app. |
| 409 | `PURCHASE_CLAIMED` | The purchase belongs to another Hiyall account. |
| 402 | `SPEND_CONFIRMATION_REQUIRED` | The request would cost coins. `details`: `reason`, `cost`, `balance`. Ask, then repeat with the price. |
| 402 | `INSUFFICIENT_COINS` | Confirmed, but the balance is too small. `details`: `reason`, `cost`, `balance`. |
| 402 | `PREMIUM_REQUIRED` | A Premium feature, while plans are enforced. `details`: `feature`. |
| 503 | `ADS_UNAVAILABLE` | Rewarded ads are not configured. |
| 429 | `DAILY_LIMIT` | The daily rewarded-ad cap is used up (`Retry-After`: next UTC midnight). |
| 422 | `VALIDATION` | A bad field. |

## GET /v1/me/billing

The one call the shop and the settings badge read. For a member who cannot buy (minor or age unknown) it still answers 200
with `eligibility.monetizable=false`, `shop=false`, empty `catalog` and `benefits`, and `locksApply=false`: the app shows
nothing about plans or coins.

```json
{
  "enforced": false,
  "locksApply": false,
  "eligibility": {"monetizable": true, "reason": null, "shop": false, "stores": {"googlePlay": true, "appStore": false}, "ads": false},
  "balance": 0,
  "plan": {"id": "free", "status": "none", "store": null, "productId": null, "currentPeriodEnd": null, "autoRenew": false, "graceUntil": null},
  "entitlements": {
    "features": {"autoTranslate": true, "visitorsList": true, "nearbyFilter": true, "genderFilter": true, "detailedProfile": true, "groupChat": true},
    "freeNewChatsPerDay": 3, "chatSlotCoinCost": 2, "profileDetailCoinCost": 1, "profileDetailDays": 30
  },
  "catalog": {
    "coinPacks": [{"id": "coins_s", "name": "Starter pack", "coins": 40, "bonusCoins": 0, "priceTier": 1, "storeProductIds": {"googlePlay": "coins_s", "appStore": "coins_s"}}],
    "subscriptions": [{"id": "premium_1m", "name": "Premium, 1 month", "periodMonths": 1, "priceTier": 1, "storeProductIds": {"googlePlay": "premium_1m", "appStore": "premium_1m"}}]
  },
  "benefits": [{"key": "newChats", "title": "Start new chats", "free": {"type": "limit", "value": 3, "unit": "day"}, "premium": {"type": "unlimited"}}],
  "ads": {"enabled": false, "coinsPerAd": 1, "dailyCap": 5, "watchedToday": 0},
  "bonuses": {"profileCompletion": {"coins": 5, "claimed": false}}
}
```

* `enforced` is the deployment switch; `locksApply` is `enforced && monetizable`: the ONLY condition under which the app shows locks,
  prices, upsells or a shop entry. `eligibility.shop` is `locksApply` and at least one store configured.
* `entitlements.features` are what the member may use now (all `true` when nothing is enforced). `freeNewChatsPerDay` is `null` for Premium
  (no limit) and for everyone while nothing is enforced.
* Prices are **not** in the catalog: the app shows the store's own localized price from the store (`in_app_purchase`
  `ProductDetails.price`). `priceTier` only orders the packs. The catalog says what each product grants.
* `benefits` cells: `{"type": "included"}`, `{"type": "notIncluded"}`, `{"type": "unlimited"}`, `{"type": "limit", "value": 3, "unit": "day"}`,
  `{"type": "coins", "value": 1, "days": 30}`. The app localizes the `key`s it knows and falls back to `title`.
* `plan.status`: `none`, `active`, `grace` (the store is retrying a payment: still Premium), `on_hold`, `paused`, `expired`, `revoked`.
* `ads.enabled` is `locksApply && ad units configured`.

## POST /v1/me/billing/purchases/verify

Body, one of (strict, unknown keys refused):

```json
{"store": "google_play", "productId": "coins_m", "purchaseToken": "…"}
{"store": "app_store", "productId": "coins_m", "transactionId": "…"}
```

`productId` is the catalog `id`. The server fetches the purchase from the store with its own credentials, checks the package/bundle, the
product, that the purchase is completed, and (when the store tells) that it was made for this account. Success:

```json
{"state": "verified", "kind": "coins", "productId": "coins_m", "coinsGranted": 130, "alreadyProcessed": false, "balance": 130, "plan": {…}}
```

* `state: "pending"`: the store says the payment is not finished yet (Google pending purchases, Apple Ask to Buy). Nothing is granted yet;
  the store's notification completes it later. The app shows a pending state and refreshes `GET /v1/me/billing`.
* Repeating the call for a processed purchase answers the same result with `alreadyProcessed: true` and grants nothing.
* A purchase that the store later refunds or revokes takes the coins back and ends the subscription (through the store notifications).
* Subscription results carry `kind: "subscription"`, `coinsGranted: 0` and the new `plan`.
* Errors: `AGE_RESTRICTED`, `BILLING_NOT_CONFIGURED`, `STORE_UNAVAILABLE`, `PURCHASE_INVALID`, `PURCHASE_CLAIMED`, `VALIDATION`.

**Restore purchases** is this call again, once per purchase the store reports on a restore (subscriptions). A purchase that belongs
to another Hiyall account is refused with `PURCHASE_CLAIMED`.

For `in_app_purchase`: set `applicationUserName` to the member's `userId` when buying (Google `obfuscatedAccountId`, Apple `appAccountToken`);
the server uses it to tie a store notification to the member even when the app never got to call verify.

## GET /v1/me/billing/history

`?limit=1..50&cursor=` newest first: `{"items": [{"id": "12", "reason": "purchase", "delta": 130, "balanceAfter": 130, "createdAt": "…"}], "nextCursor": null, "hasMore": false}`.
`reason` is one of `purchase`, `reward_ad`, `profile_completion`, `spend_chat_slot`, `spend_profile_detail`, `refund`, `refund_reversal`, `admin_adjust`.

## Spending coins

Both spends need the confirmed price.

* **Start a chat past the free allowance.** `POST /v1/conversations` as before, with the header `Spend-Confirm: <cost>` (the number the member saw).
  When a new conversation (not a reopening) is over the `freeNewChatsPerDay` of the last 24 hours and the member is not Premium, without the header the
  answer is `402 SPEND_CONFIRMATION_REQUIRED` and nothing happens; with the right cost it is taken from the balance in the same transaction
  that creates the conversation (`INSUFFICIENT_COINS` when short). Only the member who starts a conversation is charged, never one who is written to.
* **See a member's detailed profile.** `GET /v1/users/{userId}/profile` leaves the detailed fields out and adds `"detailsLocked": true` for a member without
  `detailedProfile` who has not unlocked this profile. `POST /v1/users/{userId}/profile-details/unlock` with `{"confirmCost": 1}` spends the coins (once per
  member per `profileDetailDays`, nothing again while unlocked) and answers `{"unlocked": true, "expiresAt": "…", "cost": 1, "balance": 7}`; repeat the profile GET.
  Without `confirmCost` (or a different one): `402 SPEND_CONFIRMATION_REQUIRED`.

## Premium features

While enforced and the plan lacks the feature: gender filter in people search and Nearby, any Nearby filter, the visitors list, and the detailed
profile fields answer `402 PREMIUM_REQUIRED` (or, for details, `detailsLocked`). Auto-translate and group chat are checked by their own endpoints with
the same entitlement.

## Rewarded ads (adults, when ad units are configured)

1. `POST /v1/me/billing/ads/session` (no body) → `{"nonce": "…", "userId": "…", "customData": "…", "coins": 1, "remainingToday": 4, "expiresAt": "…"}`. The app passes
   `userId` and `customData` as the ad's server-side verification options before showing the ad. `429 DAILY_LIMIT` at the cap, `503 ADS_UNAVAILABLE` when off.
2. After the ad is shown to the end, the app calls `POST /v1/me/billing/ads/reward` with `{"nonce": "…"}` → `{"status": "credited"|"pending"|"rejected"|"expired", "coins": 1, "balance": 6}` and
   polls (every 2 s for up to 20 s) while `pending`. Coins are only credited from Google's signed callback (`GET /v1/billing/admob/ssv`), never from the app's word.

## POST /v1/me/billing/bonuses/profile-completion

Adults, once: the server checks that the profile has a photo, a bio, an interest and a language, then credits the configured coins. `{"granted": true, "coins": 5, "balance": 12}` or
`{"granted": false}` when incomplete; repeating after a grant is `{"granted": false, "alreadyClaimed": true}`.

## Store notifications (server to server, no member token)

* `POST /v1/billing/google/rtdn?token=<GOOGLE_PLAY_RTDN_TOKEN>`: a Pub/Sub push of Google Play real-time developer notifications. The token is compared in constant time.
  The server re-reads the purchase from Google (the notification only says where to look) and updates subscriptions, grants a completed pending purchase,
  and applies voided purchases (refunds, chargebacks).
* `POST /v1/billing/apple/notifications`: App Store Server Notifications V2 (`{"signedPayload": "…"}`). The JWS chain is verified to Apple's root, and the bundle id is checked.
* `GET /v1/billing/admob/ssv`: AdMob server-side verification callback; the signature is verified against Google's published keys.

All answer 200 `{}` when handled or deliberately ignored (a store retries anything else), 401 when the token or signature is wrong, 503 when that store is not configured.

## Metrics

`hiyall_purchases_total{result}` (`verified`, `pending`, `invalid`, `claimed`, `replay`, `refunded`, `revoked`, `store_error`) and `hiyall_coin_spend_total{reason}` (coins spent, by ledger reason).
`hiyall_coin_grant_total{reason}` counts coins granted. No receipt, token, account or product id is ever a label.

## Support adjustments

There is no admin UI for coins. A person changes a balance with one function that also writes the operator audit, run as the table owner (`hiyall_migrate`) in `psql`:

```sql
SELECT coin_admin_adjust('<member uuid>', 20, 'support:<your name>', 'ticket 123: compensation for failed purchase');
```

A positive number gives coins, a negative number takes them (never below zero). An empty actor or reason is refused. The row lands in `coin_ledger` as
`admin_adjust` and in `operator_audit` as `coin_adjustment`. A refund of a store purchase is not done here: refund in the store, and the notification reverses the coins.

## Data kept, export and deletion

Stored: the coin balance and ledger, purchases and subscriptions with the store identifiers **hashed** (SHA-256 of store and id; receipts and tokens are never stored or logged), ad-reward sessions (3 days), detail unlocks (until 30 days after they expire). Included in "Download my data" (`coins`: balance, ledger, purchases, subscriptions without hashes). Account deletion removes all of it (`purge_member_billing`, migration 0051); the stores keep their own receipts, and a **live subscription is not cancelled by deleting the account**: the member cancels it in the store. Data shared with the stores: what a purchase or ad already involves (Google Play / App Store for purchases, Google AdMob for rewarded ads, which sees an ad request and, with consent, an advertising id); Hiyall sends AdMob the member id and a one-time nonce as server-side verification data, nothing else.
