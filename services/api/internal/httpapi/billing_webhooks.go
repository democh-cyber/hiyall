package httpapi

// Store and ad callbacks: server to server, no member token (they are served before authentication, see Handler). Each one proves itself:
// Google Play by the secret token in its Pub/Sub push URL, App Store by Apple's signed JWS chain, AdMob by Google's published keys.
// A notification never carries trust: it only says where to look, and the server re-reads the purchase from the store.

import (
	"context"
	"crypto/subtle"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"hiyall/services/api/internal/billing"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

const (
	googleRTDNPath    = "/v1/billing/google/rtdn"
	appleNotifyPath   = "/v1/billing/apple/notifications"
	admobCallbackPath = "/v1/billing/admob/ssv"
)

// serveWebhook answers the callbacks above; false means the request is not one of them.
func (a *API) serveWebhook(w http.ResponseWriter, r *http.Request) bool {
	switch {
	case r.Method == http.MethodPost && r.URL.Path == googleRTDNPath:
		a.googleRTDN(w, r)
	case r.Method == http.MethodPost && r.URL.Path == appleNotifyPath:
		a.appleNotification(w, r)
	case r.Method == http.MethodGet && r.URL.Path == admobCallbackPath:
		a.admobCallback(w, r)
	default:
		return false
	}
	return true
}

func (a *API) webhookOK(w http.ResponseWriter, r *http.Request) { a.ok(w, r, map[string]any{}) }

func (a *API) webhookBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 256<<10))
	if err != nil {
		a.failure(w, r, 413, "TOO_LARGE", "Body too large")
		return nil, false
	}
	return raw, true
}

// webhookStoreError answers a failed store lookup: a store that was down or our credentials being refused are retried by the sender (503);
// a purchase the store does not know is acknowledged and dropped.
func (a *API) webhookStoreError(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, billing.ErrInvalid) {
		a.webhookOK(w, r)
		return
	}
	purchasesTotal.Inc("store_error")
	if errors.Is(err, billing.ErrMisconfigured) {
		slog.Error("the store refused our credentials while handling a notification", "requestId", r.Context().Value(requestIDKey{}))
	}
	a.failure(w, r, 503, "STORE_UNAVAILABLE", "Try again")
}

// googleRTDN is POST /v1/billing/google/rtdn?token=…
func (a *API) googleRTDN(w http.ResponseWriter, r *http.Request) {
	ctx, bs := r.Context(), a.billingService()
	if bs.Google == nil || bs.RTDNToken == "" {
		a.error(w, r, domain.ErrBillingNotConfigured)
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("token")), []byte(bs.RTDNToken)) != 1 {
		a.failure(w, r, 401, "UNAUTHENTICATED", "Not allowed")
		return
	}
	raw, ok := a.webhookBody(w, r)
	if !ok {
		return
	}
	n, err := billing.ParseRTDN(raw)
	if err != nil {
		a.failure(w, r, 422, "VALIDATION", "Not a notification")
		return
	}
	if n.PackageName != "" && n.PackageName != bs.Google.Package {
		a.webhookOK(w, r)
		return
	}
	switch {
	case n.Voided != nil && n.Voided.PurchaseToken != "":
		hash := billing.Hash(billing.StoreGoogle, n.Voided.PurchaseToken)
		orig := ""
		if n.Voided.ProductType == 1 {
			orig = hash
		}
		user, found, err := a.Store.RefundPurchase(ctx, hash, orig, "refunded")
		if err != nil {
			a.error(w, r, err)
			return
		}
		if found {
			purchasesTotal.Inc("refunded")
			bs.invalidate(user)
		}
	case n.Subscription != nil && n.Subscription.PurchaseToken != "":
		if err := a.googleSubscriptionEvent(ctx, n); err != nil {
			a.webhookStoreError(w, r, err)
			return
		}
	case n.OneTimeProduct != nil && n.OneTimeProduct.PurchaseToken != "":
		if err := a.googleProductEvent(ctx, n); err != nil {
			a.webhookStoreError(w, r, err)
			return
		}
	}
	a.webhookOK(w, r)
}

// googleSubscriptionEvent re-reads a subscription after a notification and applies it.
func (a *API) googleSubscriptionEvent(ctx context.Context, n billing.RTDN) error {
	bs := a.billingService()
	token := n.Subscription.PurchaseToken
	hash := billing.Hash(billing.StoreGoogle, token)
	if n.Subscription.NotificationType == 12 { // SUBSCRIPTION_REVOKED
		user, found, err := a.Store.RefundPurchase(ctx, hash, hash, "revoked")
		if found && err == nil {
			purchasesTotal.Inc("revoked")
			bs.invalidate(user)
		}
		return err
	}
	v, err := bs.Google.Subscription(ctx, "", token)
	if err != nil {
		return err
	}
	return a.applyStoreSubscription(ctx, v, hash)
}

// applyStoreSubscription updates a subscription we know, or (for one the app never got to verify) records it for the member the store says it
// was bought for.
func (a *API) applyStoreSubscription(ctx context.Context, v billing.Verified, txHash string) error {
	bs := a.billingService()
	s := v.Subscription
	in := store.SubInput{OriginalHash: billing.Hash(v.Store, s.OriginalKey), Status: s.Status, PeriodEnd: s.PeriodEnd, GraceUntil: s.GraceUntil, AutoRenew: s.AutoRenew}
	user, found, err := a.Store.UpdateSubscription(ctx, in)
	if err != nil {
		return err
	}
	if found {
		bs.invalidate(user)
		return nil
	}
	product, ok := bs.Catalog.ByStoreID(v.Store, v.StoreProductID)
	if !ok || !product.Subscription || v.State != billing.StateVerified {
		return nil
	}
	return a.recordForAccount(ctx, v, product)
}

// recordForAccount records a purchase that the store says belongs to a member (the id the app attached when buying), for a purchase the app never
// got to verify (it was closed, or offline). Without that id there is nobody to credit: the app's own verify call does it later.
func (a *API) recordForAccount(ctx context.Context, v billing.Verified, product billing.Product) error {
	if !isID(strings.ToLower(v.AccountID)) {
		return nil
	}
	user := strings.ToLower(v.AccountID)
	ok, err := a.Store.BillableMember(ctx, user)
	if err != nil || !ok {
		return err
	}
	out, err := a.recordVerified(ctx, user, product, v)
	if errors.Is(err, domain.ErrPurchaseClaimed) {
		return nil
	}
	if err == nil && !out.AlreadyProcessed {
		purchasesTotal.Inc(out.State)
	}
	return err
}

// googleProductEvent handles a one-time product notification: a purchase that was pending completes, or one that the app never reported appears.
func (a *API) googleProductEvent(ctx context.Context, n billing.RTDN) error {
	bs := a.billingService()
	o := n.OneTimeProduct
	if o.NotificationType != 1 { // ONE_TIME_PRODUCT_PURCHASED; a canceled pending purchase needs nothing
		return nil
	}
	product, ok := bs.Catalog.ByStoreID(billing.StoreGoogle, o.SKU)
	if !ok || product.Subscription {
		return nil
	}
	v, err := bs.Google.Product(ctx, o.SKU, o.PurchaseToken)
	if err != nil {
		return err
	}
	hash := billing.Hash(billing.StoreGoogle, o.PurchaseToken)
	user, _, state, _, found, err := a.Store.PurchaseOwner(ctx, hash)
	if err != nil {
		return err
	}
	if found {
		if state != "pending" || v.State != billing.StateVerified {
			return nil
		}
		out, err := a.recordVerified(ctx, user, product, v)
		if err == nil && !out.AlreadyProcessed {
			purchasesTotal.Inc(out.State)
		}
		return err
	}
	return a.recordForAccount(ctx, v, product)
}

// appleNotification is POST /v1/billing/apple/notifications (App Store Server Notifications V2).
func (a *API) appleNotification(w http.ResponseWriter, r *http.Request) {
	ctx, bs := r.Context(), a.billingService()
	if bs.Apple == nil {
		a.error(w, r, domain.ErrBillingNotConfigured)
		return
	}
	raw, ok := a.webhookBody(w, r)
	if !ok {
		return
	}
	n, err := bs.Apple.ParseNotification(raw)
	if err != nil {
		// The signature, the chain or the bundle id did not check out: nothing of this is trusted.
		a.failure(w, r, 401, "UNAUTHENTICATED", "Not allowed")
		return
	}
	if n.Transaction == nil || (n.Environment == "Sandbox" && !bs.Apple.AllowSandbox) {
		a.webhookOK(w, r)
		return
	}
	tx := n.Transaction
	hash := billing.Hash(billing.StoreApple, tx.TransactionID)
	orig := billing.Hash(billing.StoreApple, tx.OriginalTransactionID)
	switch n.Type {
	case "REFUND", "REVOKE":
		state := "refunded"
		if n.Type == "REVOKE" {
			state = "revoked"
		}
		user, found, err := a.Store.RefundPurchase(ctx, hash, orig, state)
		if err != nil {
			a.error(w, r, err)
			return
		}
		if found {
			purchasesTotal.Inc(state)
			bs.invalidate(user)
		}
	case "REFUND_REVERSED":
		user, found, err := a.Store.ReverseRefund(ctx, hash, orig)
		if err != nil {
			a.error(w, r, err)
			return
		}
		if found {
			bs.invalidate(user)
		}
	case "CONSUMPTION_REQUEST", "TEST", "PRICE_INCREASE", "RENEWAL_EXTENSION":
	default:
		if err := a.appleEvent(ctx, n, hash); err != nil {
			a.error(w, r, err)
			return
		}
	}
	a.webhookOK(w, r)
}

// appleEvent applies a subscription or one-time-charge notification.
func (a *API) appleEvent(ctx context.Context, n billing.Notification, txHash string) error {
	bs := a.billingService()
	tx := n.Transaction
	product, ok := bs.Catalog.ByStoreID(billing.StoreApple, tx.ProductID)
	if !ok {
		return nil
	}
	v := billing.Verified{Store: billing.StoreApple, StoreProductID: tx.ProductID, TxKey: tx.TransactionID, State: billing.StateVerified, Test: tx.Environment != "Production",
		AccountID: strings.ToLower(tx.AppAccountToken), Revoked: tx.RevocationDate != 0}
	if product.Subscription {
		v.Subscription = bs.Apple.SubscriptionFromNotification(n)
		if v.Subscription == nil {
			return nil
		}
		return a.applyStoreSubscription(ctx, v, txHash)
	}
	if _, _, _, _, found, err := a.Store.PurchaseOwner(ctx, txHash); err != nil || found {
		return err
	}
	return a.recordForAccount(ctx, v, product)
}

// admobCallback is GET /v1/billing/admob/ssv: Google's server-side verification of a rewarded ad. The signature covers the query, so
// nothing in it can be changed by the app; the reward is the catalog's, never the query's reward_amount.
func (a *API) admobCallback(w http.ResponseWriter, r *http.Request) {
	ctx, bs := r.Context(), a.billingService()
	if bs.AdMob == nil {
		a.error(w, r, domain.ErrAdsUnavailable)
		return
	}
	reward, err := bs.AdMob.Verify(ctx, r.URL.RawQuery)
	switch {
	case errors.Is(err, billing.ErrInvalid):
		adRewardsTotal.Inc("invalid")
		a.failure(w, r, 401, "UNAUTHENTICATED", "Not allowed")
		return
	case err != nil:
		a.failure(w, r, 503, "STORE_UNAVAILABLE", "Try again")
		return
	}
	user, nonce := strings.ToLower(reward.UserID), strings.ToLower(reward.CustomData)
	if !isID(user) || !isID(nonce) {
		adRewardsTotal.Inc("invalid")
		a.webhookOK(w, r)
		return
	}
	result, err := a.Store.CreditAdReward(ctx, user, nonce, billing.Hash("admob", reward.TransactionID), bs.Catalog.Ads.CoinsPerAd, bs.Catalog.Ads.DailyCap)
	if err != nil {
		a.error(w, r, err)
		return
	}
	adRewardsTotal.Inc(string(result))
	a.webhookOK(w, r)
}
