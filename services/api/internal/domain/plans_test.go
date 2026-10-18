package domain

import (
	"errors"
	"testing"
)

func TestResolveNeverGatesSomeoneWhoCannotBuy(t *testing.T) {
	pol := DefaultPlanPolicy()
	for _, enforced := range []bool{false, true} {
		e := Resolve(PlanFree, enforced, false, pol)
		if e.Enforced || !e.Features.GenderFilter || !e.Features.VisitorsList || e.FreeNewChatsPerDay != 0 || e.ChatSlotCoinCost != 0 || e.ProfileDetailCoinCost != 0 {
			t.Errorf("enforced=%v: a member who cannot buy is gated: %+v", enforced, e)
		}
		// Their numbers are the Free ones, not Premium's: nothing about being unlocked raises a safety or storage limit.
		if e.PostsPerDay != Free().PostsPerDay || e.StorageBytes != Free().StorageBytes {
			t.Errorf("enforced=%v: numbers %+v", enforced, e)
		}
	}
}

func TestResolveBetaUnlocksEveryAdult(t *testing.T) {
	e := Resolve(PlanFree, false, true, DefaultPlanPolicy())
	if e.Enforced || !e.Allows(FeatureGenderFilter) || !e.Allows(FeatureDetailedProfile) || e.ChatSlotCost(1000) != 0 {
		t.Fatalf("%+v", e)
	}
	if e.PostsPerDay != EntitlementsFor(PlanPremium).PostsPerDay || e.PostsPerDay <= Free().PostsPerDay {
		t.Fatalf("the beta gives Premium numbers: %d", e.PostsPerDay)
	}
}

func TestResolveEnforcedFreeAndPremium(t *testing.T) {
	pol := DefaultPlanPolicy()
	free := Resolve(PlanFree, true, true, pol)
	if !free.Enforced || free.Features != (Features{}) || free.FreeNewChatsPerDay != 3 || free.ChatSlotCoinCost != 2 || free.ProfileDetailCoinCost != 1 {
		t.Fatalf("%+v", free)
	}
	for _, f := range AllFeatures {
		if free.Allows(f) {
			t.Errorf("Free has %s", f)
		}
	}
	if free.ChatSlotCost(2) != 0 || free.ChatSlotCost(3) != 2 || free.ChatSlotCost(50) != 2 {
		t.Fatal("chat slot cost around the allowance")
	}
	prem := Resolve(PlanPremium, true, true, pol)
	for _, f := range AllFeatures {
		if !prem.Allows(f) {
			t.Errorf("Premium lacks %s", f)
		}
	}
	if prem.ChatSlotCost(500) != 0 || prem.Plan != PlanPremium {
		t.Fatalf("%+v", prem)
	}
	// Safety limits never differ by plan.
	if prem.FollowsPerDay != free.FollowsPerDay || prem.SearchPagesPerDay != free.SearchPagesPerDay || prem.NewConversationsPerDay != free.NewConversationsPerDay ||
		prem.ChatMessagesPerConversationPerDay != free.ChatMessagesPerConversationPerDay || prem.LocationChangesPerDay != free.LocationChangesPerDay {
		t.Fatal("a safety limit differs by plan")
	}
	if prem.StorageBytes <= free.StorageBytes || prem.UploadsPerDay <= free.UploadsPerDay {
		t.Fatal("Premium raises nothing")
	}
}

func TestPolicyChoosesWhichFeaturesAreReserved(t *testing.T) {
	pol := DefaultPlanPolicy()
	pol.PremiumOnly = []Feature{FeatureGenderFilter}
	e := Resolve(PlanFree, true, true, pol)
	if e.Allows(FeatureGenderFilter) || !e.Allows(FeatureAutoTranslate) || !e.Allows(FeatureVisitorsList) {
		t.Fatalf("%+v", e.Features)
	}
}

func TestPlainFreeIsUnenforced(t *testing.T) {
	// EntitlementsFor / Free() (what tests and code without a billing service use) gate nothing.
	e := Free()
	if e.Enforced || !e.Allows(FeatureGenderFilter) || e.ChatSlotCost(100) != 0 {
		t.Fatalf("%+v", e)
	}
	if EntitlementsFor(Plan("bogus")).Plan != PlanFree {
		t.Fatal("an unknown plan must resolve to Free")
	}
}

func TestSpendErrors(t *testing.T) {
	err := ErrSpendConfirmation(SpendChatSlot, 2, 5)
	var s *SpendError
	var p *PolicyError
	if !errors.As(err, &s) || !errors.As(err, &p) || p.Status != 402 || p.Code != "SPEND_CONFIRMATION_REQUIRED" || s.Details["cost"] != 2 || s.Details["balance"] != int64(5) {
		t.Fatalf("%+v", err)
	}
	if ErrInsufficientCoins("x", 1, 0).(*SpendError).Code != "INSUFFICIENT_COINS" || ErrPremiumRequired(FeatureGroupChat).(*SpendError).Details["feature"] != "groupChat" {
		t.Fatal("codes")
	}
	if _, ok := ParseFeature("genderFilter"); !ok {
		t.Fatal("feature name")
	}
	if _, ok := ParseFeature("x"); ok {
		t.Fatal("bad feature name")
	}
}
