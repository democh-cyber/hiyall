package config

import (
	"errors"
	"os"
	"strings"
)

// Billing is the plans, coins and store configuration (docs/api/28-billing.md, docs/deployment/10-deploy-guide.md).
// Every credential is a file path or a value in the environment, never in the repository. Each store is optional and a
// documented no-op while unset: the purchase endpoint then answers 503 BILLING_NOT_CONFIGURED and the app shows no shop.
type Billing struct {
	// PlansEnforced (PLANS_ENFORCED, default false) is the master switch. Off: every adult member is unlocked (Premium
	// numbers, every feature, nothing costs coins) and the app shows no shop. On: Free members get the Free limits and
	// the features Premium reserves, and coins and Premium become relevant. The owner turns it on at launch.
	PlansEnforced bool
	// BillingCatalogFile (BILLING_CATALOG_FILE) is a JSON file with the products (grants, price tiers), the Free/Premium
	// policy, the benefits table and the ad rewards. Unset: the built-in default catalog (see config/billing-catalog.example.json).
	BillingCatalogFile string
	// BillingAllowTestPurchases (BILLING_ALLOW_TEST_PURCHASES, default true) accepts Google Play license-tester purchases
	// and Apple Sandbox transactions (TestFlight and App Review use the sandbox, so production needs them at first).
	BillingAllowTestPurchases bool

	// Google Play: the package name, a service account that has the "View financial data" and "Manage orders" permissions
	// in Play Console, and the token that the Pub/Sub push subscription for real-time developer notifications carries
	// in its URL (?token=). All three go together.
	GooglePlayPackageName, GooglePlayServiceAccountFile, GooglePlayRTDNToken string

	// Apple: the App Store Server API credentials (issuer id, key id, the .p8 key) with the app's bundle id, and the PEM
	// file of Apple's root certificate(s) that signed transactions must chain to (Apple Root CA - G3). All five go together.
	AppleIAPBundleID, AppleIAPIssuerID, AppleIAPKeyID, AppleIAPPrivateKeyFile, AppleIAPRootCertFile string

	// AdMobSSVAdUnitIDs (ADMOB_SSV_AD_UNIT_IDS, comma separated) are the rewarded ad units whose server-side verification
	// callbacks credit coins; a callback for any other unit is refused. Unset: rewarded ads are off.
	AdMobSSVAdUnitIDs []string
}

// GooglePlayConfigured says whether Google Play purchases can be verified.
func (b Billing) GooglePlayConfigured() bool {
	return b.GooglePlayPackageName != "" && b.GooglePlayServiceAccountFile != ""
}

// AppStoreConfigured says whether App Store purchases can be verified.
func (b Billing) AppStoreConfigured() bool {
	return b.AppleIAPBundleID != "" && b.AppleIAPIssuerID != "" && b.AppleIAPKeyID != "" && b.AppleIAPPrivateKeyFile != "" && b.AppleIAPRootCertFile != ""
}

// AdsConfigured says whether rewarded ads can credit coins.
func (b Billing) AdsConfigured() bool { return len(b.AdMobSSVAdUnitIDs) > 0 }

func (c *Config) loadBilling() error {
	var err error
	b := &c.Billing
	if b.PlansEnforced, err = boolEnv("PLANS_ENFORCED"); err != nil {
		return err
	}
	switch os.Getenv("BILLING_ALLOW_TEST_PURCHASES") {
	case "", "true":
		b.BillingAllowTestPurchases = true
	case "false":
		b.BillingAllowTestPurchases = false
	default:
		return errors.New("BILLING_ALLOW_TEST_PURCHASES must be true or false")
	}
	b.BillingCatalogFile = os.Getenv("BILLING_CATALOG_FILE")
	b.GooglePlayPackageName, b.GooglePlayServiceAccountFile, b.GooglePlayRTDNToken = os.Getenv("GOOGLE_PLAY_PACKAGE_NAME"), os.Getenv("GOOGLE_PLAY_SERVICE_ACCOUNT_FILE"), os.Getenv("GOOGLE_PLAY_RTDN_TOKEN")
	b.AppleIAPBundleID, b.AppleIAPIssuerID, b.AppleIAPKeyID = os.Getenv("APPLE_IAP_BUNDLE_ID"), os.Getenv("APPLE_IAP_ISSUER_ID"), os.Getenv("APPLE_IAP_KEY_ID")
	b.AppleIAPPrivateKeyFile, b.AppleIAPRootCertFile = os.Getenv("APPLE_IAP_PRIVATE_KEY_FILE"), os.Getenv("APPLE_IAP_ROOT_CERT_FILE")
	for _, id := range strings.Split(os.Getenv("ADMOB_SSV_AD_UNIT_IDS"), ",") {
		if id = strings.TrimSpace(id); id != "" {
			b.AdMobSSVAdUnitIDs = append(b.AdMobSSVAdUnitIDs, id)
		}
	}
	set := 0
	for _, v := range []string{b.GooglePlayPackageName, b.GooglePlayServiceAccountFile} {
		if v != "" {
			set++
		}
	}
	if set == 1 {
		return errors.New("GOOGLE_PLAY_PACKAGE_NAME and GOOGLE_PLAY_SERVICE_ACCOUNT_FILE go together")
	}
	if b.GooglePlayRTDNToken != "" && set == 0 {
		return errors.New("GOOGLE_PLAY_RTDN_TOKEN needs GOOGLE_PLAY_PACKAGE_NAME and GOOGLE_PLAY_SERVICE_ACCOUNT_FILE")
	}
	if b.GooglePlayRTDNToken != "" && len(b.GooglePlayRTDNToken) < 24 {
		return errors.New("GOOGLE_PLAY_RTDN_TOKEN must be at least 24 characters (a random secret)")
	}
	set = 0
	for _, v := range []string{b.AppleIAPBundleID, b.AppleIAPIssuerID, b.AppleIAPKeyID, b.AppleIAPPrivateKeyFile, b.AppleIAPRootCertFile} {
		if v != "" {
			set++
		}
	}
	if set != 0 && set != 5 {
		return errors.New("APPLE_IAP_BUNDLE_ID, APPLE_IAP_ISSUER_ID, APPLE_IAP_KEY_ID, APPLE_IAP_PRIVATE_KEY_FILE and APPLE_IAP_ROOT_CERT_FILE go together")
	}
	if c.Env == "production" && b.PlansEnforced && !b.GooglePlayConfigured() && !b.AppStoreConfigured() {
		return errors.New("PLANS_ENFORCED=true needs a configured store (GOOGLE_PLAY_* or APPLE_IAP_*): Free members could otherwise never buy anything")
	}
	return nil
}
