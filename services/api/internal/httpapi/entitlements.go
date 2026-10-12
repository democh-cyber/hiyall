package httpapi

import (
	"context"

	"hiyall/services/api/internal/domain"
)

// entitlementsFor is the single place a member's limits are decided. There are no paid plans yet, so
// every member gets the Free entitlements; a subscriptions lookup plugs in here (as API.Entitlements) and
// nothing else changes: handlers pass the result to the store, which never reads limits from constants.
func (a *API) entitlementsFor(ctx context.Context, userID string) domain.Entitlements {
	if a.Entitlements != nil {
		return a.Entitlements(ctx, userID)
	}
	return domain.EntitlementsFor(domain.PlanFree)
}
