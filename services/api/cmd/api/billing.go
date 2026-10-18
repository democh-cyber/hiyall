package main

import (
	"errors"
	"log/slog"

	"hiyall/services/api/internal/billing"
	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/logscrub"
)

// billingService builds the plans and store configuration (docs/api/28-billing.md). Every store is optional: an unset store is a no-op
// (its endpoints answer 503 BILLING_NOT_CONFIGURED). A store that is set but unusable stops a production start, like FCM does; in development it
// is disabled and the reason is logged (never the key).
func billingService(cfg config.Config) (*httpapi.BillingService, error) {
	catalog := billing.DefaultCatalog()
	if cfg.BillingCatalogFile != "" {
		c, err := billing.LoadCatalog(cfg.BillingCatalogFile)
		if err != nil {
			return nil, err // a catalog that does not validate stops every start: prices and grants must not be a guess
		}
		catalog = c
	}
	bs := &httpapi.BillingService{Catalog: catalog, Enforced: cfg.PlansEnforced}
	fail := func(what string, err error) error {
		if cfg.Env == "production" {
			return errors.New(what + " is set but unusable: " + logscrub.Err(err))
		}
		slog.Error(what+" disabled", "reason", logscrub.Err(err))
		return nil
	}
	if cfg.GooglePlayConfigured() {
		account, err := billing.LoadGoogleAccount(cfg.GooglePlayServiceAccountFile)
		if err == nil {
			var g *billing.Google
			if g, err = billing.NewGoogle(cfg.GooglePlayPackageName, account, cfg.BillingAllowTestPurchases); err == nil {
				bs.Google, bs.RTDNToken = g, cfg.GooglePlayRTDNToken
				slog.Info("Google Play purchases: on", "package", cfg.GooglePlayPackageName, "rtdn", cfg.GooglePlayRTDNToken != "")
			}
		}
		if err != nil {
			if e := fail("Google Play purchases", err); e != nil {
				return nil, e
			}
		}
	}
	if cfg.AppStoreConfigured() {
		a, err := billing.NewApple(cfg.AppleIAPBundleID, cfg.AppleIAPIssuerID, cfg.AppleIAPKeyID, cfg.AppleIAPPrivateKeyFile, cfg.AppleIAPRootCertFile, cfg.BillingAllowTestPurchases)
		if err == nil {
			bs.Apple = a
			slog.Info("App Store purchases: on", "bundle", cfg.AppleIAPBundleID)
		} else if e := fail("App Store purchases", err); e != nil {
			return nil, e
		}
	}
	if cfg.AdsConfigured() {
		bs.AdMob = billing.NewAdMob(cfg.AdMobSSVAdUnitIDs)
		slog.Info("rewarded ads: on", "adUnits", len(cfg.AdMobSSVAdUnitIDs))
	}
	if !cfg.PlansEnforced {
		slog.Info("plans are not enforced (PLANS_ENFORCED=false): every adult member is unlocked and no shop is shown")
	} else if bs.Google == nil && bs.Apple == nil {
		slog.Warn("PLANS_ENFORCED=true but no store is configured: members cannot buy anything")
	}
	return bs, nil
}
