// Package billing is the protocol side of plans, coins and purchases: the product catalog, the Google Play and
// App Store verification clients, the store notification parsers and the AdMob server-side-verification check.
// It touches no database: store/coins.go keeps the ledger and httpapi/billing*.go ties the two together.
// Nothing here logs or stores a receipt, a purchase token or a key.
package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"

	"hiyall/services/api/internal/domain"
)

// Store names, as stored in purchases.store and subscriptions.store.
const (
	StoreGoogle = "google_play"
	StoreApple  = "app_store"
)

// CoinPack is a consumable product that grants coins.
type CoinPack struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Coins      int    `json:"coins"`
	BonusCoins int    `json:"bonusCoins"`
	// PriceTier only orders the products. Prices are the stores' own (localized), never in the catalog.
	PriceTier int `json:"priceTier"`
	// GoogleProductID and AppleProductID are the store ids; empty means the catalog id.
	GoogleProductID string `json:"googleProductId,omitempty"`
	AppleProductID  string `json:"appleProductId,omitempty"`
}

// Total is every coin the pack grants.
func (p CoinPack) Total() int { return p.Coins + p.BonusCoins }

// SubscriptionProduct is an auto-renewing Premium subscription.
type SubscriptionProduct struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	PeriodMonths    int    `json:"periodMonths"`
	PriceTier       int    `json:"priceTier"`
	GoogleProductID string `json:"googleProductId,omitempty"`
	AppleProductID  string `json:"appleProductId,omitempty"`
}

// AdsConfig is what a rewarded ad is worth.
type AdsConfig struct {
	CoinsPerAd     int `json:"coinsPerAd"`
	DailyCap       int `json:"dailyCap"`
	SessionMinutes int `json:"sessionMinutes"`
}

// Catalog is the whole billing configuration that is data, not code.
type Catalog struct {
	Policy        domain.PlanPolicy
	CoinPacks     []CoinPack
	Subscriptions []SubscriptionProduct
	Ads           AdsConfig
	// ProfileCompletionCoins is the one-time bonus for a complete profile (0: no bonus).
	ProfileCompletionCoins int
}

// DefaultCatalog is used when BILLING_CATALOG_FILE is unset. It is config/billing-catalog.example.json.
func DefaultCatalog() Catalog {
	return Catalog{
		Policy: domain.DefaultPlanPolicy(),
		CoinPacks: []CoinPack{
			{ID: "coins_s", Name: "Pocket of coins", Coins: 40, PriceTier: 1},
			{ID: "coins_m", Name: "Handful of coins", Coins: 120, BonusCoins: 10, PriceTier: 2},
			{ID: "coins_l", Name: "Bag of coins", Coins: 300, BonusCoins: 40, PriceTier: 3},
			{ID: "coins_xl", Name: "Chest of coins", Coins: 700, BonusCoins: 120, PriceTier: 4},
		},
		Subscriptions: []SubscriptionProduct{
			{ID: "premium_1m", Name: "Premium, 1 month", PeriodMonths: 1, PriceTier: 1},
			{ID: "premium_3m", Name: "Premium, 3 months", PeriodMonths: 3, PriceTier: 2},
			{ID: "premium_12m", Name: "Premium, 12 months", PeriodMonths: 12, PriceTier: 3},
		},
		Ads:                    AdsConfig{CoinsPerAd: 1, DailyCap: 5, SessionMinutes: 10},
		ProfileCompletionCoins: 5,
	}
}

type catalogFile struct {
	Policy *struct {
		PremiumFeatures       []string `json:"premiumFeatures"`
		FreeNewChatsPerDay    *int     `json:"freeNewChatsPerDay"`
		ChatSlotCoinCost      *int     `json:"chatSlotCoinCost"`
		ProfileDetailCoinCost *int     `json:"profileDetailCoinCost"`
		ProfileDetailDays     *int     `json:"profileDetailDays"`
	} `json:"policy"`
	CoinPacks     []CoinPack            `json:"coinPacks"`
	Subscriptions []SubscriptionProduct `json:"subscriptions"`
	Ads           *AdsConfig            `json:"ads"`
	Bonuses       *struct {
		ProfileCompletion *int `json:"profileCompletion"`
	} `json:"bonuses"`
}

var idPattern = regexp.MustCompile(`^[a-z0-9_.]{2,60}$`)

// LoadCatalog reads and validates a catalog file; sections it leaves out keep the defaults. Unknown keys are refused so a
// misspelt knob does not silently do nothing.
func LoadCatalog(path string) (Catalog, error) {
	c := DefaultCatalog()
	raw, err := os.ReadFile(path)
	if err != nil {
		return c, errors.New("cannot read BILLING_CATALOG_FILE")
	}
	var f catalogFile
	dec := json.NewDecoder(bytesReader(raw))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&f); err != nil {
		return c, fmt.Errorf("BILLING_CATALOG_FILE is not valid: %w", err)
	}
	if p := f.Policy; p != nil {
		if p.PremiumFeatures != nil {
			c.Policy.PremiumOnly = nil
			for _, name := range p.PremiumFeatures {
				feat, ok := domain.ParseFeature(name)
				if !ok {
					return c, fmt.Errorf("BILLING_CATALOG_FILE: unknown premium feature %q", name)
				}
				c.Policy.PremiumOnly = append(c.Policy.PremiumOnly, feat)
			}
		}
		setInt := func(dst *int, src *int) {
			if src != nil {
				*dst = *src
			}
		}
		setInt(&c.Policy.FreeNewChatsPerDay, p.FreeNewChatsPerDay)
		setInt(&c.Policy.ChatSlotCoinCost, p.ChatSlotCoinCost)
		setInt(&c.Policy.ProfileDetailCoinCost, p.ProfileDetailCoinCost)
		setInt(&c.Policy.ProfileDetailDays, p.ProfileDetailDays)
	}
	if f.CoinPacks != nil {
		c.CoinPacks = f.CoinPacks
	}
	if f.Subscriptions != nil {
		c.Subscriptions = f.Subscriptions
	}
	if f.Ads != nil {
		c.Ads = *f.Ads
	}
	if f.Bonuses != nil && f.Bonuses.ProfileCompletion != nil {
		c.ProfileCompletionCoins = *f.Bonuses.ProfileCompletion
	}
	return c, c.Validate()
}

// Validate refuses a catalog that could grant nothing, grant a negative amount or name a product twice.
func (c Catalog) Validate() error {
	p := c.Policy
	if p.FreeNewChatsPerDay < 0 || p.FreeNewChatsPerDay > 1000 || p.ChatSlotCoinCost < 0 || p.ChatSlotCoinCost > 1000 ||
		p.ProfileDetailCoinCost < 0 || p.ProfileDetailCoinCost > 1000 || p.ProfileDetailDays < 1 || p.ProfileDetailDays > 365 {
		return errors.New("BILLING_CATALOG_FILE: policy numbers are out of range")
	}
	seen := map[string]bool{}
	for _, pack := range c.CoinPacks {
		if !idPattern.MatchString(pack.ID) || pack.Coins < 1 || pack.Coins > 100000 || pack.BonusCoins < 0 || pack.BonusCoins > 100000 || pack.Name == "" {
			return fmt.Errorf("BILLING_CATALOG_FILE: coin pack %q is invalid", pack.ID)
		}
		if seen[pack.ID] {
			return fmt.Errorf("BILLING_CATALOG_FILE: product %q is listed twice", pack.ID)
		}
		seen[pack.ID] = true
	}
	for _, sub := range c.Subscriptions {
		if !idPattern.MatchString(sub.ID) || sub.PeriodMonths < 1 || sub.PeriodMonths > 12 || sub.Name == "" {
			return fmt.Errorf("BILLING_CATALOG_FILE: subscription %q is invalid", sub.ID)
		}
		if seen[sub.ID] {
			return fmt.Errorf("BILLING_CATALOG_FILE: product %q is listed twice", sub.ID)
		}
		seen[sub.ID] = true
	}
	if c.Ads.CoinsPerAd < 0 || c.Ads.CoinsPerAd > 100 || c.Ads.DailyCap < 0 || c.Ads.DailyCap > 100 || c.Ads.SessionMinutes < 1 || c.Ads.SessionMinutes > 60 {
		return errors.New("BILLING_CATALOG_FILE: ads numbers are out of range")
	}
	if c.ProfileCompletionCoins < 0 || c.ProfileCompletionCoins > 1000 {
		return errors.New("BILLING_CATALOG_FILE: the profile completion bonus is out of range")
	}
	return nil
}

// Product is a catalog entry found by id.
type Product struct {
	ID           string
	Subscription bool
	Coins        int // total coins of a pack, 0 for a subscription
	PeriodMonths int
	google       string
	apple        string
}

// StoreID is the product id the store knows.
func (p Product) StoreID(store string) string {
	if store == StoreGoogle {
		return p.google
	}
	return p.apple
}

func orID(override, id string) string {
	if override != "" {
		return override
	}
	return id
}

// Product finds a product by its catalog id.
func (c Catalog) Product(id string) (Product, bool) {
	for _, p := range c.CoinPacks {
		if p.ID == id {
			return Product{ID: p.ID, Coins: p.Total(), google: orID(p.GoogleProductID, p.ID), apple: orID(p.AppleProductID, p.ID)}, true
		}
	}
	for _, s := range c.Subscriptions {
		if s.ID == id {
			return Product{ID: s.ID, Subscription: true, PeriodMonths: s.PeriodMonths, google: orID(s.GoogleProductID, s.ID), apple: orID(s.AppleProductID, s.ID)}, true
		}
	}
	return Product{}, false
}

// ByStoreID finds the product a store id belongs to (a notification names only the store's id).
func (c Catalog) ByStoreID(store, storeID string) (Product, bool) {
	for _, p := range c.CoinPacks {
		if pr, _ := c.Product(p.ID); pr.StoreID(store) == storeID {
			return pr, true
		}
	}
	for _, s := range c.Subscriptions {
		if pr, _ := c.Product(s.ID); pr.StoreID(store) == storeID {
			return pr, true
		}
	}
	return Product{}, false
}

// View is the catalog as GET /v1/me/billing shows it.
func (c Catalog) View() map[string]any {
	type ids struct {
		GooglePlay string `json:"googlePlay"`
		AppStore   string `json:"appStore"`
	}
	packs := make([]map[string]any, 0, len(c.CoinPacks))
	for _, p := range c.CoinPacks {
		pr, _ := c.Product(p.ID)
		packs = append(packs, map[string]any{"id": p.ID, "name": p.Name, "coins": p.Coins, "bonusCoins": p.BonusCoins, "priceTier": p.PriceTier, "storeProductIds": ids{pr.google, pr.apple}})
	}
	subs := make([]map[string]any, 0, len(c.Subscriptions))
	for _, s := range c.Subscriptions {
		pr, _ := c.Product(s.ID)
		subs = append(subs, map[string]any{"id": s.ID, "name": s.Name, "periodMonths": s.PeriodMonths, "priceTier": s.PriceTier, "storeProductIds": ids{pr.google, pr.apple}})
	}
	return map[string]any{"coinPacks": packs, "subscriptions": subs}
}

// Cell is one cell of the Free versus Premium table.
type Cell struct {
	Type  string `json:"type"` // included, notIncluded, unlimited, limit, coins
	Value int    `json:"value,omitempty"`
	Unit  string `json:"unit,omitempty"`
	Days  int    `json:"days,omitempty"`
}

// Benefit is one row of the table.
type Benefit struct {
	Key     string `json:"key"`
	Title   string `json:"title"`
	Free    Cell   `json:"free"`
	Premium Cell   `json:"premium"`
}

// Benefits builds the "Free vs Premium" table from the two plans' entitlements, so the table can never disagree with what the
// server enforces.
func Benefits(free, premium domain.Entitlements) []Benefit {
	feature := func(f domain.Feature) (Cell, Cell) {
		c := func(e domain.Entitlements) Cell {
			if e.Features.Has(f) {
				return Cell{Type: "included"}
			}
			return Cell{Type: "notIncluded"}
		}
		return c(free), c(premium)
	}
	row := func(key, title string, f domain.Feature) Benefit {
		a, b := feature(f)
		return Benefit{Key: key, Title: title, Free: a, Premium: b}
	}
	chats := Cell{Type: "unlimited"}
	if free.FreeNewChatsPerDay > 0 {
		chats = Cell{Type: "limit", Value: free.FreeNewChatsPerDay, Unit: "day"}
	}
	details := Cell{Type: "included"}
	if !free.Features.DetailedProfile {
		details = Cell{Type: "coins", Value: free.ProfileDetailCoinCost, Days: free.ProfileDetailDays}
		if free.ProfileDetailCoinCost == 0 {
			details = Cell{Type: "notIncluded"}
		}
	}
	chatsMore := Benefit{Key: "newChats", Title: "Start new chats", Free: chats, Premium: Cell{Type: "unlimited"}}
	if free.FreeNewChatsPerDay > 0 && free.ChatSlotCoinCost > 0 {
		// Past the allowance a chat costs coins; the table states the allowance, the app's confirmation states the price.
		chatsMore.Free = Cell{Type: "limit", Value: free.FreeNewChatsPerDay, Unit: "day"}
	}
	return []Benefit{
		chatsMore,
		{Key: "profileDetails", Title: "Detailed profiles", Free: details, Premium: Cell{Type: "included"}},
		row("autoTranslate", "Auto-translate chat", domain.FeatureAutoTranslate),
		row("visitorsList", "See who visited you", domain.FeatureVisitorsList),
		row("nearbyFilter", "Nearby filters", domain.FeatureNearbyFilter),
		row("genderFilter", "Gender filter", domain.FeatureGenderFilter),
		row("groupChat", "Group chat", domain.FeatureGroupChat),
		{Key: "uploads", Title: "Photo uploads", Free: Cell{Type: "limit", Value: free.UploadsPerDay, Unit: "day"}, Premium: Cell{Type: "limit", Value: premium.UploadsPerDay, Unit: "day"}},
		{Key: "storage", Title: "Photo storage", Free: Cell{Type: "limit", Value: int(free.StorageBytes >> 30), Unit: "GB"}, Premium: Cell{Type: "limit", Value: int(premium.StorageBytes >> 30), Unit: "GB"}},
	}
}
