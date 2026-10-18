package httpapi

// Plans, coins and purchases (docs/api/28-billing.md). Member routes here; the store and ad callbacks (no member token) are in
// billing_webhooks.go. Every route that moves money or coins first checks, from the stored birth date, that the member is an adult with a
// known age: a minor gets 403 AGE_RESTRICTED whatever the app does.

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"hiyall/services/api/internal/billing"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

var (
	purchasesTotal = metrics.NewCounter("hiyall_purchases_total", "Store purchase verifications and notifications, by result.", "result")
	adRewardsTotal = metrics.NewCounter("hiyall_ad_rewards_total", "Rewarded ad callbacks, by result.", "result")
)

func init() {
	for _, r := range []string{"verified", "pending", "replay", "invalid", "claimed", "refunded", "revoked", "store_error"} {
		purchasesTotal.Preset(r)
	}
	for _, r := range []string{"credited", "replay", "rejected", "invalid"} {
		adRewardsTotal.Preset(r)
	}
}

// BillingService is the billing configuration an API serves: the catalog, the master switch and the store clients. A nil client is a
// store that is not configured. The zero value (and a nil *BillingService) is "nothing configured, nothing enforced".
type BillingService struct {
	Catalog  billing.Catalog
	Enforced bool
	Google   *billing.Google
	Apple    *billing.Apple
	// RTDNToken is the secret the Google Pub/Sub push URL carries (?token=).
	RTDNToken string
	AdMob     *billing.AdMob
	// CacheTTL is how long a member's resolved entitlements are reused (default 20 s); a purchase or a store notification handled on this
	// node drops the member's entry at once.
	CacheTTL time.Duration

	mu    sync.Mutex
	cache map[string]cachedEntitlements
}

type cachedEntitlements struct {
	e  domain.Entitlements
	at time.Time
}

// NewBillingService returns a service with the default catalog.
func NewBillingService() *BillingService { return &BillingService{Catalog: billing.DefaultCatalog()} }

func (b *BillingService) ttl() time.Duration {
	if b.CacheTTL > 0 {
		return b.CacheTTL
	}
	return 20 * time.Second
}

// invalidate forgets a member's cached entitlements.
func (b *BillingService) invalidate(user string) {
	if b == nil {
		return
	}
	b.mu.Lock()
	delete(b.cache, user)
	b.mu.Unlock()
}

// resolve is the member's entitlements: domain.Resolve of their plan, the master switch and whether they can buy anything. A failure to read
// the plan never locks anyone: the member then gets the unlocked Free entitlements and the failure is logged.
func (b *BillingService) resolve(ctx context.Context, db *store.Store, user string) domain.Entitlements {
	b.mu.Lock()
	if c, ok := b.cache[user]; ok && time.Since(c.at) < b.ttl() {
		b.mu.Unlock()
		return c.e
	}
	b.mu.Unlock()
	st, err := db.PlanState(ctx, user)
	if err != nil {
		slog.Warn("plan lookup failed; entitlements are unlocked for this request", "requestId", ctx.Value(requestIDKey{}))
		return domain.Resolve(domain.PlanFree, false, false, b.Catalog.Policy)
	}
	e := domain.Resolve(st.Plan(), b.Enforced, st.Monetizable(), b.Catalog.Policy)
	b.mu.Lock()
	if b.cache == nil || len(b.cache) > 20000 {
		b.cache = map[string]cachedEntitlements{}
	}
	b.cache[user] = cachedEntitlements{e, time.Now()}
	b.mu.Unlock()
	return e
}

func (a *API) billingService() *BillingService {
	if a.Billing != nil {
		return a.Billing
	}
	return &BillingService{Catalog: billing.DefaultCatalog()}
}

// failureDetails is failure with an error.details object.
func (a *API) failureDetails(w http.ResponseWriter, r *http.Request, status int, code, message string, details map[string]any) {
	a.write(w, r, status, map[string]any{"success": false, "error": map[string]any{"code": code, "message": message, "details": details}})
}

// requireAdult answers 403 AGE_RESTRICTED unless the member is an adult with a known age (the one rule every money route shares).
func (a *API) requireAdult(w http.ResponseWriter, r *http.Request, p store.Principal) (store.PlanState, bool) {
	st, err := a.Store.PlanState(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return st, false
	}
	if !st.Monetizable() {
		a.error(w, r, domain.ErrAgeRestricted)
		return st, false
	}
	return st, true
}

// featureAllowed answers 402 PREMIUM_REQUIRED when the member's plan lacks f while plans are enforced.
func (a *API) featureAllowed(w http.ResponseWriter, r *http.Request, p store.Principal, f domain.Feature) bool {
	if a.entitlementsFor(r.Context(), p.UserID).Allows(f) {
		return true
	}
	a.error(w, r, domain.ErrPremiumRequired(f))
	return false
}

func planView(st store.PlanState) map[string]any {
	v := map[string]any{"id": string(st.Plan()), "status": "none", "store": nil, "productId": nil, "currentPeriodEnd": nil, "autoRenew": false, "graceUntil": nil}
	if s := st.Sub; s != nil {
		status := s.Status
		if !s.Entitled && (status == billing.SubActive || status == billing.SubGrace) {
			status = billing.SubExpired
		}
		v["status"], v["store"], v["productId"], v["currentPeriodEnd"], v["autoRenew"], v["graceUntil"] = status, s.Store, s.ProductID, s.PeriodEnd, s.AutoRenew, s.GraceUntil
	}
	return v
}

// getBilling is GET /v1/me/billing.
func (a *API) getBilling(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, bs := r.Context(), a.billingService()
	st, err := a.Store.PlanState(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	mon := st.Monetizable()
	locks := bs.Enforced && mon
	stores := map[string]bool{"googlePlay": mon && bs.Google != nil, "appStore": mon && bs.Apple != nil}
	adsOn := locks && bs.AdMob != nil && bs.Catalog.Ads.CoinsPerAd > 0 && bs.Catalog.Ads.DailyCap > 0
	var reason any
	switch {
	case mon:
	case st.AgeKnown:
		reason = "minor"
	default:
		reason = "age_unknown"
	}
	e := domain.Resolve(st.Plan(), bs.Enforced, mon, bs.Catalog.Policy)
	ent := map[string]any{"features": e.Features, "freeNewChatsPerDay": nil, "chatSlotCoinCost": 0, "profileDetailCoinCost": 0, "profileDetailDays": 0}
	if locks {
		if e.FreeNewChatsPerDay > 0 {
			ent["freeNewChatsPerDay"] = e.FreeNewChatsPerDay
		}
		ent["chatSlotCoinCost"], ent["profileDetailCoinCost"], ent["profileDetailDays"] = e.ChatSlotCoinCost, e.ProfileDetailCoinCost, e.ProfileDetailDays
	}
	out := map[string]any{
		"enforced": bs.Enforced, "locksApply": locks,
		"eligibility": map[string]any{"monetizable": mon, "reason": reason, "shop": locks && (stores["googlePlay"] || stores["appStore"]), "stores": stores, "ads": adsOn},
		"balance":     int64(0), "plan": planView(store.PlanState{AgeKnown: st.AgeKnown, Adult: st.Adult}), "entitlements": ent,
		"catalog": map[string]any{"coinPacks": []any{}, "subscriptions": []any{}}, "benefits": []any{},
		"ads":     map[string]any{"enabled": false, "coinsPerAd": 0, "dailyCap": 0, "watchedToday": 0},
		"bonuses": map[string]any{},
	}
	if mon {
		out["plan"] = planView(st)
		if out["balance"], err = a.Store.CoinBalance(ctx, p.UserID); err != nil {
			a.error(w, r, err)
			return
		}
		out["catalog"] = bs.Catalog.View()
		out["benefits"] = billing.Benefits(domain.Resolve(domain.PlanFree, true, true, bs.Catalog.Policy), domain.Resolve(domain.PlanPremium, true, true, bs.Catalog.Policy))
		watched := 0
		if adsOn {
			if watched, err = a.Store.AdsWatchedToday(ctx, p.UserID); err != nil {
				a.error(w, r, err)
				return
			}
		}
		out["ads"] = map[string]any{"enabled": adsOn, "coinsPerAd": bs.Catalog.Ads.CoinsPerAd, "dailyCap": bs.Catalog.Ads.DailyCap, "watchedToday": watched}
		if coins := bs.Catalog.ProfileCompletionCoins; coins > 0 {
			claimed, err := a.Store.ProfileBonusClaimed(ctx, p.UserID)
			if err != nil {
				a.error(w, r, err)
				return
			}
			out["bonuses"] = map[string]any{"profileCompletion": map[string]any{"coins": coins, "claimed": claimed}}
		}
	}
	a.ok(w, r, out)
}

// strict reads a JSON body whose keys must all be in allowed.
func (a *API) strict(w http.ResponseWriter, r *http.Request, allowed ...string) (map[string]json.RawMessage, bool) {
	body, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return nil, false
	}
next:
	for key := range body {
		for _, k := range allowed {
			if k == key {
				continue next
			}
		}
		a.failure(w, r, 422, "VALIDATION", key+" is not accepted")
		return nil, false
	}
	return body, true
}

func str(body map[string]json.RawMessage, key string, max int) (string, bool) {
	var s string
	if raw, ok := body[key]; !ok || json.Unmarshal(raw, &s) != nil || s == "" || len(s) > max || strings.ContainsAny(s, "\x00\r\n") {
		return "", false
	}
	return s, true
}

// storeFailure turns a store client's error into the member-facing refusal and counts it.
func (a *API) storeFailure(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, billing.ErrInvalid):
		purchasesTotal.Inc("invalid")
		a.error(w, r, domain.ErrPurchaseInvalid)
	case errors.Is(err, billing.ErrMisconfigured):
		slog.Error("the store refused our credentials; check the store configuration", "requestId", r.Context().Value(requestIDKey{}))
		purchasesTotal.Inc("store_error")
		a.error(w, r, domain.ErrStoreUnavailable)
	default:
		purchasesTotal.Inc("store_error")
		a.error(w, r, domain.ErrStoreUnavailable)
	}
}

// verifyPurchase is POST /v1/me/billing/purchases/verify.
func (a *API) verifyPurchase(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, bs := r.Context(), a.billingService()
	if _, ok := a.requireAdult(w, r, p); !ok {
		return
	}
	body, ok := a.strict(w, r, "store", "productId", "purchaseToken", "transactionId")
	if !ok {
		return
	}
	storeName, _ := str(body, "store", 20)
	productID, okProduct := str(body, "productId", 100)
	product, found := bs.Catalog.Product(productID)
	if !okProduct || !found {
		a.failure(w, r, 422, "VALIDATION", "productId is not a product")
		return
	}
	var v billing.Verified
	var err error
	switch storeName {
	case "google_play":
		token, ok := str(body, "purchaseToken", 4096)
		if !ok || len(body) != 3 {
			a.failure(w, r, 422, "VALIDATION", "purchaseToken is required")
			return
		}
		if bs.Google == nil {
			a.error(w, r, domain.ErrBillingNotConfigured)
			return
		}
		if product.Subscription {
			v, err = bs.Google.Subscription(ctx, product.StoreID(billing.StoreGoogle), token)
		} else {
			v, err = bs.Google.Product(ctx, product.StoreID(billing.StoreGoogle), token)
		}
	case "app_store":
		id, ok := str(body, "transactionId", 64)
		if !ok || len(body) != 3 {
			a.failure(w, r, 422, "VALIDATION", "transactionId is required")
			return
		}
		if bs.Apple == nil {
			a.error(w, r, domain.ErrBillingNotConfigured)
			return
		}
		v, err = bs.Apple.Transaction(ctx, id, product.StoreID(billing.StoreApple))
	default:
		a.failure(w, r, 422, "VALIDATION", "store must be google_play or app_store")
		return
	}
	if err != nil {
		a.storeFailure(w, r, err)
		return
	}
	// A purchase must be of the kind the product is, and made for this account when the store says whose it is.
	if (v.Subscription != nil) != product.Subscription || v.Revoked {
		purchasesTotal.Inc("invalid")
		a.error(w, r, domain.ErrPurchaseInvalid)
		return
	}
	if v.AccountID != "" && !strings.EqualFold(v.AccountID, p.UserID) {
		purchasesTotal.Inc("claimed")
		a.error(w, r, domain.ErrPurchaseClaimed)
		return
	}
	out, err := a.recordVerified(ctx, p.UserID, product, v)
	if err != nil {
		if errors.Is(err, domain.ErrPurchaseClaimed) {
			purchasesTotal.Inc("claimed")
		}
		a.error(w, r, err)
		return
	}
	switch {
	case out.State == "refunded" || out.State == "revoked":
		purchasesTotal.Inc("invalid")
		a.error(w, r, domain.ErrPurchaseInvalid)
		return
	case out.AlreadyProcessed:
		purchasesTotal.Inc("replay")
	default:
		purchasesTotal.Inc(out.State)
	}
	st, err := a.Store.PlanState(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	kind := "coins"
	if product.Subscription {
		kind = "subscription"
	}
	a.ok(w, r, map[string]any{"state": out.State, "kind": kind, "productId": product.ID, "coinsGranted": out.CoinsGranted, "alreadyProcessed": out.AlreadyProcessed, "balance": out.Balance, "plan": planView(st)})
}

// recordVerified writes a verified purchase and, for a first-time Google purchase, acknowledges it with the store.
func (a *API) recordVerified(ctx context.Context, user string, product billing.Product, v billing.Verified) (store.PurchaseOutcome, error) {
	bs := a.billingService()
	in := store.PurchaseInput{UserID: user, Store: v.Store, TxHash: billing.Hash(v.Store, v.TxKey), ProductID: product.ID, State: v.State, Test: v.Test, Coins: product.Coins, Kind: "coins"}
	if product.Subscription {
		in.Kind, in.Coins = "subscription", 0
		s := v.Subscription
		in.Sub = &store.SubInput{OriginalHash: billing.Hash(v.Store, s.OriginalKey), Status: s.Status, PeriodEnd: s.PeriodEnd, GraceUntil: s.GraceUntil, AutoRenew: s.AutoRenew}
	}
	out, err := a.Store.RecordPurchase(ctx, in)
	if err != nil {
		return out, err
	}
	bs.invalidate(user)
	if v.NeedsAck && v.Store == billing.StoreGoogle && bs.Google != nil && out.State == billing.StateVerified {
		// Best effort, and again by the next notification: an unacknowledged purchase is refunded by Google after three days.
		ackCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 8*time.Second)
		defer cancel()
		if err := bs.Google.Acknowledge(ackCtx, product.Subscription, v.StoreProductID, v.TxKey); err != nil {
			slog.Warn("could not acknowledge a Google Play purchase", "reason", err.Error())
		}
	}
	return out, nil
}

type coinCursor struct {
	User string `json:"u"`
	ID   int64  `json:"i"`
	Exp  int64  `json:"e"`
}

// billingHistory is GET /v1/me/billing/history.
func (a *API) billingHistory(w http.ResponseWriter, r *http.Request, p store.Principal) {
	if _, ok := a.requireAdult(w, r, p); !ok {
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 50 {
			a.failure(w, r, 422, "VALIDATION", "limit must be 1–50")
			return
		}
		limit = n
	}
	var before int64
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		var c coinCursor
		if !openCursor(a, "coins\x00", raw, &c) || c.User != p.UserID || c.Exp <= time.Now().Unix() || c.ID <= 0 {
			a.failure(w, r, 422, "INVALID_CURSOR", "Reload this list")
			return
		}
		before = c.ID
	}
	items, err := a.Store.CoinHistory(r.Context(), p.UserID, before, limit+1)
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(items) > limit {
		items = items[:limit]
		id, _ := strconv.ParseInt(items[limit-1].ID, 10, 64)
		next = sealCursor(a, "coins\x00", coinCursor{User: p.UserID, ID: id, Exp: time.Now().Add(15 * time.Minute).Unix()})
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next, "hasMore": next != nil})
}

// adsSession is POST /v1/me/billing/ads/session.
func (a *API) adsSession(w http.ResponseWriter, r *http.Request, p store.Principal) {
	bs := a.billingService()
	if _, ok := a.requireAdult(w, r, p); !ok {
		return
	}
	if !bs.Enforced || bs.AdMob == nil || bs.Catalog.Ads.CoinsPerAd <= 0 || bs.Catalog.Ads.DailyCap <= 0 {
		a.error(w, r, domain.ErrAdsUnavailable)
		return
	}
	s, err := a.Store.StartAdSession(r.Context(), p.UserID, time.Duration(bs.Catalog.Ads.SessionMinutes)*time.Minute, bs.Catalog.Ads.DailyCap)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"nonce": s.Nonce, "userId": p.UserID, "customData": s.Nonce, "coins": bs.Catalog.Ads.CoinsPerAd, "remainingToday": s.RemainingToday, "expiresAt": s.ExpiresAt})
}

// adsReward is POST /v1/me/billing/ads/reward: the status of a started ad (credited by the AdMob callback, not by this call).
func (a *API) adsReward(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	if _, ok := a.requireAdult(w, r, p); !ok {
		return
	}
	body, ok := a.strict(w, r, "nonce")
	if !ok {
		return
	}
	nonce, okNonce := str(body, "nonce", 36)
	if !okNonce || !isID(nonce) {
		a.failure(w, r, 422, "VALIDATION", "nonce is required")
		return
	}
	st, err := a.Store.AdSessionStatus(ctx, p.UserID, nonce)
	if err != nil {
		a.error(w, r, err)
		return
	}
	balance, err := a.Store.CoinBalance(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"status": st.Status, "coins": st.Coins, "balance": balance})
}

// profileCompletionBonus is POST /v1/me/billing/bonuses/profile-completion.
func (a *API) profileCompletionBonus(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, bs := r.Context(), a.billingService()
	if _, ok := a.requireAdult(w, r, p); !ok {
		return
	}
	coins := bs.Catalog.ProfileCompletionCoins
	if coins <= 0 {
		a.ok(w, r, map[string]any{"granted": false})
		return
	}
	claimed, err := a.Store.ProfileBonusClaimed(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if claimed {
		a.ok(w, r, map[string]any{"granted": false, "alreadyClaimed": true})
		return
	}
	complete, err := a.Store.ProfileComplete(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if !complete {
		a.ok(w, r, map[string]any{"granted": false})
		return
	}
	granted, claimed, balance, err := a.Store.ClaimProfileBonus(ctx, p.UserID, coins)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if !granted {
		a.ok(w, r, map[string]any{"granted": false, "alreadyClaimed": claimed})
		return
	}
	a.ok(w, r, map[string]any{"granted": true, "coins": coins, "balance": balance})
}

// detailedProfileKeys are the fields of another member's profile that are "detailed": longer text about the person. They are left out of
// the profile response (with detailsLocked) when the viewer's plan lacks DetailedProfile and they have not unlocked this profile.
var detailedProfileKeys = []string{"bio", "aboutMe", "hometown", "personalityTags", "profession", "education", "websiteUrl"}

func hasValue(v any) bool {
	raw, err := json.Marshal(v)
	if err != nil {
		return true
	}
	switch string(raw) {
	case "null", `""`, "[]", "{}":
		return false
	}
	return true
}

// gateProfileDetails removes the detailed fields from a profile response when the viewer may not see them yet. An error is a failed lookup:
// the caller answers it rather than showing the details.
func (a *API) gateProfileDetails(ctx context.Context, viewer, target string, value map[string]any) error {
	if viewer == target || value["locked"] == true {
		return nil
	}
	if a.entitlementsFor(ctx, viewer).Allows(domain.FeatureDetailedProfile) {
		return nil
	}
	until, err := a.Store.ProfileDetailsUnlockedUntil(ctx, viewer, target)
	if err != nil {
		return err
	}
	if !until.IsZero() {
		value["detailsUnlockedUntil"] = until
		return nil
	}
	had := false
	for _, k := range detailedProfileKeys {
		if v, ok := value[k]; ok {
			had = had || hasValue(v)
			delete(value, k)
		}
	}
	if had {
		value["detailsLocked"] = true
	}
	return nil
}

// unlockProfileDetails is POST /v1/users/{userId}/profile-details/unlock.
func (a *API) unlockProfileDetails(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, target := r.Context(), r.PathValue("userId")
	if _, ok := a.requireAdult(w, r, p); !ok {
		return
	}
	// No body at all is the same as {}: the first call only asks what it costs.
	body := map[string]json.RawMessage{}
	if r.ContentLength != 0 {
		var ok bool
		if body, ok = a.strict(w, r, "confirmCost"); !ok {
			return
		}
	}
	confirmed := 0
	if raw, has := body["confirmCost"]; has {
		if json.Unmarshal(raw, &confirmed) != nil || confirmed < 0 || confirmed > 100000 {
			a.failure(w, r, 422, "VALIDATION", "confirmCost must be a whole number")
			return
		}
	}
	e := a.entitlementsFor(ctx, p.UserID)
	balance, err := a.Store.CoinBalance(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if target == p.UserID || e.Allows(domain.FeatureDetailedProfile) {
		a.ok(w, r, map[string]any{"unlocked": true, "expiresAt": nil, "cost": 0, "balance": balance})
		return
	}
	// Only a profile this member may open can be unlocked (a block, the other age band and an unknown member all answer 404).
	view, err := a.Store.VisibleProfile(ctx, p.UserID, target, a.presence, a.signer(ctx))
	if err != nil {
		a.error(w, r, err)
		return
	}
	if view["locked"] == true {
		a.error(w, r, domain.ErrNotFound)
		return
	}
	res, err := a.Store.UnlockProfileDetails(ctx, p.UserID, target, e.ProfileDetailCoinCost, e.ProfileDetailDays, confirmed)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]any{"unlocked": true, "expiresAt": res.ExpiresAt, "cost": res.Charged, "balance": res.Balance})
}

// spendConsentFrom reads the Spend-Confirm header (the price the member confirmed) into the request context.
func spendConsentFrom(r *http.Request) context.Context {
	if raw := r.Header.Get("Spend-Confirm"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n >= 0 && n <= 100000 {
			return store.WithSpendConsent(r.Context(), n)
		}
	}
	return r.Context()
}

// nearbyFiltersAllowed gates Nearby: any filter besides the radius needs NearbyFilter, and the gender filter needs GenderFilter.
func (a *API) nearbyFiltersAllowed(w http.ResponseWriter, r *http.Request, p store.Principal, f domain.PeopleFilters) bool {
	if f.Gender != "" && !a.featureAllowed(w, r, p, domain.FeatureGenderFilter) {
		return false
	}
	other := len(f.Interests) > 0 || len(f.Languages) > 0 || f.Country != "" || f.Vibe != "" || f.AgeMin != nil || f.AgeMax != nil || f.Online
	if other && !a.featureAllowed(w, r, p, domain.FeatureNearbyFilter) {
		return false
	}
	return true
}
