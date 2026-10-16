package httpapi

import (
	"strings"
	"testing"

	"hiyall/services/api/internal/metrics"
)

// The first event after a restart must be visible to increase(): every counter the alert rules read exists at zero.
func TestAlertCountersExistAtZeroFromStartup(t *testing.T) {
	var sb strings.Builder
	if _, err := metrics.Default.WriteTo(&sb); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`hiyall_quarantine_cases_total{result="flagged"}`, `hiyall_quarantine_cases_total{result="match"}`,
		`hiyall_db_contention_total{code="55P03"}`, `hiyall_db_contention_total{code="40P01"}`, "hiyall_media_busy_total ",
	} {
		if !strings.Contains(sb.String(), want) {
			t.Errorf("metric series %s is not present at startup", want)
		}
	}
}
