package config

import "testing"

func billingEnv(t *testing.T, kv map[string]string) (Config, error) {
	t.Helper()
	for _, k := range []string{"PLANS_ENFORCED", "BILLING_CATALOG_FILE", "BILLING_ALLOW_TEST_PURCHASES", "GOOGLE_PLAY_PACKAGE_NAME", "GOOGLE_PLAY_SERVICE_ACCOUNT_FILE", "GOOGLE_PLAY_RTDN_TOKEN",
		"APPLE_IAP_BUNDLE_ID", "APPLE_IAP_ISSUER_ID", "APPLE_IAP_KEY_ID", "APPLE_IAP_PRIVATE_KEY_FILE", "APPLE_IAP_ROOT_CERT_FILE", "ADMOB_SSV_AD_UNIT_IDS"} {
		t.Setenv(k, "")
	}
	for k, v := range kv {
		t.Setenv(k, v)
	}
	c := Config{Env: "development"}
	if kv["APP_ENV_FOR_TEST"] != "" {
		c.Env = kv["APP_ENV_FOR_TEST"]
	}
	return c, c.loadBilling()
}

func TestBillingDefaultsAreInert(t *testing.T) {
	c, err := billingEnv(t, nil)
	if err != nil || c.PlansEnforced || !c.BillingAllowTestPurchases || c.GooglePlayConfigured() || c.AppStoreConfigured() || c.AdsConfigured() {
		t.Fatalf("%+v %v", c.Billing, err)
	}
}

func TestBillingConfigRules(t *testing.T) {
	good := map[string]map[string]string{
		"google":   {"GOOGLE_PLAY_PACKAGE_NAME": "app.x", "GOOGLE_PLAY_SERVICE_ACCOUNT_FILE": "/f.json", "GOOGLE_PLAY_RTDN_TOKEN": "0123456789012345678901234"},
		"apple":    {"APPLE_IAP_BUNDLE_ID": "a.b", "APPLE_IAP_ISSUER_ID": "i", "APPLE_IAP_KEY_ID": "k", "APPLE_IAP_PRIVATE_KEY_FILE": "/k.p8", "APPLE_IAP_ROOT_CERT_FILE": "/r.pem"},
		"ads":      {"ADMOB_SSV_AD_UNIT_IDS": " ca-app-pub-1/2 , ,3 "},
		"enforced": {"PLANS_ENFORCED": "true"},
		"no test":  {"BILLING_ALLOW_TEST_PURCHASES": "false"},
	}
	for name, env := range good {
		if _, err := billingEnv(t, env); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	bad := map[string]map[string]string{
		"enforced typo":      {"PLANS_ENFORCED": "yes"},
		"test typo":          {"BILLING_ALLOW_TEST_PURCHASES": "maybe"},
		"google half":        {"GOOGLE_PLAY_PACKAGE_NAME": "app.x"},
		"rtdn alone":         {"GOOGLE_PLAY_RTDN_TOKEN": "0123456789012345678901234"},
		"rtdn short":         {"GOOGLE_PLAY_PACKAGE_NAME": "app.x", "GOOGLE_PLAY_SERVICE_ACCOUNT_FILE": "/f.json", "GOOGLE_PLAY_RTDN_TOKEN": "short"},
		"apple partial":      {"APPLE_IAP_BUNDLE_ID": "a.b", "APPLE_IAP_KEY_ID": "k"},
		"production enforce": {"APP_ENV_FOR_TEST": "production", "PLANS_ENFORCED": "true"},
	}
	for name, env := range bad {
		if _, err := billingEnv(t, env); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	c, _ := billingEnv(t, good["ads"])
	if len(c.AdMobSSVAdUnitIDs) != 2 || c.AdMobSSVAdUnitIDs[1] != "3" {
		t.Fatalf("%v", c.AdMobSSVAdUnitIDs)
	}
	if _, err := billingEnv(t, map[string]string{"APP_ENV_FOR_TEST": "production", "PLANS_ENFORCED": "true", "APPLE_IAP_BUNDLE_ID": "a.b", "APPLE_IAP_ISSUER_ID": "i", "APPLE_IAP_KEY_ID": "k", "APPLE_IAP_PRIVATE_KEY_FILE": "/k.p8", "APPLE_IAP_ROOT_CERT_FILE": "/r.pem"}); err != nil {
		t.Errorf("production with a store: %v", err)
	}
}
