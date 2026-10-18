package domain

import (
	"errors"
	"strings"
)

// Plans, features and coins (docs/architecture/11-plans-and-entitlements.md, docs/api/28-billing.md).
//
// PlanFree and PlanPremium are DATA: two answers of EntitlementsFor. Whether the Free answer is applied is
// a deployment switch, PLANS_ENFORCED (default false): until the owner turns it on, every member is
// effectively unlocked (Premium numbers, every feature, nothing costs coins). Members who cannot buy
// anything (under 18, or whose age is unknown) are never gated or charged, whatever the switch says.

// PlanPremium is the paid plan (a store subscription).
const PlanPremium Plan = "premium"

// Feature names a capability that Premium may reserve. The names are the JSON keys the app reads.
type Feature string

const (
	FeatureAutoTranslate   Feature = "autoTranslate"
	FeatureVisitorsList    Feature = "visitorsList"
	FeatureNearbyFilter    Feature = "nearbyFilter"
	FeatureGenderFilter    Feature = "genderFilter"
	FeatureDetailedProfile Feature = "detailedProfile"
	FeatureGroupChat       Feature = "groupChat"
)

// AllFeatures is every feature, in the order the benefits table lists them.
var AllFeatures = []Feature{FeatureAutoTranslate, FeatureVisitorsList, FeatureNearbyFilter, FeatureGenderFilter, FeatureDetailedProfile, FeatureGroupChat}

// ParseFeature is the Feature named s, false for a name that is not one.
func ParseFeature(s string) (Feature, bool) {
	for _, f := range AllFeatures {
		if string(f) == s {
			return f, true
		}
	}
	return "", false
}

// Features says, per feature, whether the member may use it. The app reads it for hints; the server checks it
// wherever the feature has a server path (the app's hints never replace those checks).
type Features struct {
	AutoTranslate   bool `json:"autoTranslate"`
	VisitorsList    bool `json:"visitorsList"`
	NearbyFilter    bool `json:"nearbyFilter"`
	GenderFilter    bool `json:"genderFilter"`
	DetailedProfile bool `json:"detailedProfile"`
	GroupChat       bool `json:"groupChat"`
}

// AllFeaturesOn is Features with everything allowed.
func AllFeaturesOn() Features {
	return Features{true, true, true, true, true, true}
}

// Has says whether f is on.
func (fs Features) Has(f Feature) bool {
	switch f {
	case FeatureAutoTranslate:
		return fs.AutoTranslate
	case FeatureVisitorsList:
		return fs.VisitorsList
	case FeatureNearbyFilter:
		return fs.NearbyFilter
	case FeatureGenderFilter:
		return fs.GenderFilter
	case FeatureDetailedProfile:
		return fs.DetailedProfile
	case FeatureGroupChat:
		return fs.GroupChat
	}
	return false
}

// Without is fs with the listed features off.
func (fs Features) Without(off ...Feature) Features {
	for _, f := range off {
		switch f {
		case FeatureAutoTranslate:
			fs.AutoTranslate = false
		case FeatureVisitorsList:
			fs.VisitorsList = false
		case FeatureNearbyFilter:
			fs.NearbyFilter = false
		case FeatureGenderFilter:
			fs.GenderFilter = false
		case FeatureDetailedProfile:
			fs.DetailedProfile = false
		case FeatureGroupChat:
			fs.GroupChat = false
		}
	}
	return fs
}

// Allows says whether the member may use f. When the entitlements are not enforced (the beta, a member who
// cannot buy anything, tests that use Free()) every feature is allowed.
func (e Entitlements) Allows(f Feature) bool { return !e.Enforced || e.Features.Has(f) }

// ChatSlotCost is what the next conversation the member starts costs, in coins: 0 when it is free (not
// enforced, Premium, or still inside the free allowance), otherwise the price. started is the number of
// conversations the member has started in the last 24 hours.
func (e Entitlements) ChatSlotCost(started int) int {
	if !e.Enforced || e.FreeNewChatsPerDay <= 0 || started < e.FreeNewChatsPerDay {
		return 0
	}
	return e.ChatSlotCoinCost
}

// PlanPolicy is the part of the plans that is configuration, not code (BILLING_CATALOG_FILE): which
// features Premium reserves, how many conversations a Free member starts per day before one costs coins,
// and the two coin prices.
type PlanPolicy struct {
	PremiumOnly           []Feature
	FreeNewChatsPerDay    int
	ChatSlotCoinCost      int
	ProfileDetailCoinCost int
	ProfileDetailDays     int
}

// DefaultPlanPolicy is the policy when no catalog file says otherwise.
func DefaultPlanPolicy() PlanPolicy {
	return PlanPolicy{PremiumOnly: AllFeatures, FreeNewChatsPerDay: 3, ChatSlotCoinCost: 2, ProfileDetailCoinCost: 1, ProfileDetailDays: 30}
}

// Resolve is the one place that turns what is known about a member into their entitlements.
//
//   - A member who cannot buy anything (monetizable false: under 18, or age unknown) is never gated: Free
//     numbers, every feature, no coin prices. Plans are not shown to them at all.
//   - Not enforced (the beta): Premium numbers, every feature, no coin prices, for every adult.
//   - Enforced: Premium numbers and every feature for an active subscriber (plan PlanPremium); for everyone
//     else the Free numbers, the features Premium does not reserve, and the coin prices of the policy.
func Resolve(plan Plan, enforced, monetizable bool, pol PlanPolicy) Entitlements {
	switch {
	case !monetizable:
		e := EntitlementsFor(PlanFree)
		e.Features = AllFeaturesOn()
		return e
	case !enforced:
		e := EntitlementsFor(PlanPremium)
		e.Plan = plan
		return e
	case plan == PlanPremium:
		e := EntitlementsFor(PlanPremium)
		e.Enforced = true
		e.ProfileDetailDays = pol.ProfileDetailDays
		return e
	}
	e := EntitlementsFor(PlanFree)
	e.Enforced = true
	e.Features = AllFeaturesOn().Without(pol.PremiumOnly...)
	e.FreeNewChatsPerDay = pol.FreeNewChatsPerDay
	e.ChatSlotCoinCost = pol.ChatSlotCoinCost
	e.ProfileDetailCoinCost = pol.ProfileDetailCoinCost
	e.ProfileDetailDays = pol.ProfileDetailDays
	return e
}

// premiumFrom raises the numbers that Premium raises. Safety limits (follows, requests, search pages, profile
// views, Nearby queries, location changes, the chat relay caps) never differ by plan.
func premiumFrom(free Entitlements) Entitlements {
	e := free
	e.Plan = PlanPremium
	e.UploadsPerDay = 100
	e.UploadBytesPerDay = 600 << 20
	e.PostsPerDay = 40
	e.StoriesPerDay = 60
	e.StorageBytes = 5 << 30
	e.BlobsPerDay = 200
	e.BlobBytesPerDay = 600 << 20
	e.ChatPinsMax = 10
	e.ProfilePhotosMax = 12
	e.Features = AllFeaturesOn()
	return e
}

// Coin reasons (coin_ledger.reason). The ledger is append-only: a spend or a refund is a new row.
const (
	CoinPurchase          = "purchase"
	CoinRewardAd          = "reward_ad"
	CoinProfileCompletion = "profile_completion"
	CoinReviewBonus       = "review_bonus" // reserved, nothing grants it
	CoinSpendChatSlot     = "spend_chat_slot"
	CoinSpendProfile      = "spend_profile_detail"
	CoinRefund            = "refund"
	CoinRefundReversal    = "refund_reversal"
	CoinAdminAdjust       = "admin_adjust"
)

// CoinReasons is every reason the ledger accepts (the CHECK of migration 0051).
var CoinReasons = []string{CoinPurchase, CoinRewardAd, CoinProfileCompletion, CoinReviewBonus, CoinSpendChatSlot, CoinSpendProfile, CoinRefund, CoinRefundReversal, CoinAdminAdjust}

// Billing errors. Every refusal of the money paths is one of these, so a client can map them.
var (
	// ErrAgeRestricted: purchases, coins and rewarded ads are for adults whose age is known. The message
	// does not mention age: nothing about the refusal needs to single anyone out.
	ErrAgeRestricted = &PolicyError{403, "AGE_RESTRICTED", "This isn’t available for your account."}
	// ErrBillingNotConfigured: no store credentials are set on this deployment (a documented no-op).
	ErrBillingNotConfigured = &PolicyError{503, "BILLING_NOT_CONFIGURED", "Purchases aren’t available right now."}
	// ErrStoreUnavailable: the store could not be asked right now. The purchase is kept by the store; retry.
	ErrStoreUnavailable = &PolicyError{502, "STORE_UNAVAILABLE", "We couldn’t reach the store. Try again in a moment."}
	// ErrPurchaseInvalid: the store does not say this purchase is a completed one for this app and product.
	ErrPurchaseInvalid = &PolicyError{422, "PURCHASE_INVALID", "This purchase couldn’t be confirmed."}
	// ErrPurchaseClaimed: the purchase already belongs to another Hiyall account.
	ErrPurchaseClaimed = &PolicyError{409, "PURCHASE_CLAIMED", "This purchase is already linked to another account."}
	// ErrAdsUnavailable: rewarded ads are not configured, or not available to this member right now.
	ErrAdsUnavailable = &PolicyError{503, "ADS_UNAVAILABLE", "Rewards aren’t available right now."}
)

// SpendError is a 402 refusal of something that costs coins or needs Premium. It carries the facts the app shows
// (what it costs, what the member has) in the error's "details".
type SpendError struct {
	*PolicyError
	Details map[string]any
}

func (e *SpendError) Unwrap() error { return e.PolicyError }

// SpendReason names what a spend is for in a SpendError and in metrics.
const (
	SpendChatSlot      = "chat_slot"
	SpendProfileDetail = "profile_detail"
)

// ErrSpendConfirmation is returned when a request would cost coins and the member has not confirmed the price.
func ErrSpendConfirmation(reason string, cost int, balance int64) error {
	return &SpendError{&PolicyError{402, "SPEND_CONFIRMATION_REQUIRED", "This costs coins. Confirm to continue."},
		map[string]any{"reason": reason, "cost": cost, "balance": balance}}
}

// ErrInsufficientCoins is returned when the member confirmed a spend but the balance does not cover it.
func ErrInsufficientCoins(reason string, cost int, balance int64) error {
	return &SpendError{&PolicyError{402, "INSUFFICIENT_COINS", "You don’t have enough coins for this."},
		map[string]any{"reason": reason, "cost": cost, "balance": balance}}
}

// ErrPremiumRequired is returned for a feature the member's plan does not include, when plans are enforced.
func ErrPremiumRequired(f Feature) error {
	return &SpendError{&PolicyError{402, "PREMIUM_REQUIRED", "This is part of Premium."}, map[string]any{"feature": string(f)}}
}

// ErrNegativeBalance is the store refusing to take a balance below zero (never reaches a client: callers turn
// it into ErrInsufficientCoins with the price).
var ErrNegativeBalance = errors.New("coin balance would be negative")

// SpendReasonForLedger is the ledger reason of a SpendReason.
func SpendReasonForLedger(reason string) string {
	if strings.HasPrefix(reason, SpendChatSlot) {
		return CoinSpendChatSlot
	}
	return CoinSpendProfile
}
