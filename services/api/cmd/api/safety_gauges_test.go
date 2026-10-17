package main

import (
	"context"
	"strings"
	"testing"

	"hiyall/services/api/internal/dbtest"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

func scrapeGauge(t *testing.T, name string) string {
	t.Helper()
	var sb strings.Builder
	if _, err := metrics.Default.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(sb.String(), "\n") {
		if strings.HasPrefix(line, name+" ") {
			return strings.TrimPrefix(line, name+" ")
		}
	}
	t.Fatalf("%s missing from the scrape", name)
	return ""
}

// A role that may not run safety_queue_stats reports NaN, never zero (round-4 audit N1): a zero is "no approval is
// waiting" to the alert that is the only watcher of a stuck two-person proposal. With the grant the real numbers come.
func TestSafetyGaugesReportNaNWhenTheQueryFails(t *testing.T) {
	dsn := dbtest.Scratch(t)
	ctx := context.Background()
	owner, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(owner.Pool.Close)
	dbtest.ApplyRoles(t, ctx, owner.Pool)
	api, err := store.New(ctx, dbtest.RoleDSN(t, dsn, "hiyall_api"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(api.Pool.Close)
	if _, err = owner.Pool.Exec(ctx, `REVOKE EXECUTE ON FUNCTION safety_queue_stats() FROM hiyall_api`); err != nil {
		t.Fatal(err)
	}
	registerSafetyGauges(api)
	for _, g := range []string{"hiyall_pending_approvals", "hiyall_oldest_pending_approval_seconds", "hiyall_apple_manual_revocations", "hiyall_pending_quarantine_cases"} {
		if got := scrapeGauge(t, g); got != "NaN" {
			t.Errorf("%s = %s without EXECUTE on safety_queue_stats, want NaN", g, got)
		}
	}
	if _, err = owner.Pool.Exec(ctx, `GRANT EXECUTE ON FUNCTION safety_queue_stats() TO hiyall_api`); err != nil {
		t.Fatal(err)
	}
	registerSafetyGauges(api) // a new reader: no cached failure
	if got := scrapeGauge(t, "hiyall_pending_approvals"); got != "0" {
		t.Errorf("hiyall_pending_approvals = %s with the grant on an empty queue, want 0", got)
	}
}
