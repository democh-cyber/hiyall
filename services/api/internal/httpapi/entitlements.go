package httpapi

import (
	"context"

	"hiyall/services/api/internal/domain"
)

// entitlementsFor is the single place a member's limits are decided. Order: the API.Entitlements override (tests), then the billing
// service (plans, PLANS_ENFORCED, subscriptions: billing.go), then Free. Handlers pass the result to the store, which never reads limits
// from constants.
func (a *API) entitlementsFor(ctx context.Context, userID string) domain.Entitlements {
	if a.Entitlements != nil {
		return a.Entitlements(ctx, userID)
	}
	if a.Billing != nil {
		return a.Billing.resolve(ctx, a.Store, userID)
	}
	return domain.EntitlementsFor(domain.PlanFree)
}
