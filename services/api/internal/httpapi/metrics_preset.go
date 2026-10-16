package httpapi

// Counters an alert rule reads are created at zero when the process starts, for every label value known in advance.
// Without this a series appears only at its first increment, and Prometheus' increase() over a window that holds just
// that first sample reports nothing: the first event after every restart would never alert
// (infrastructure/alerts/hiyall.rules.yml; scripts/validate-alerts.sh checks the metric names exist).
func init() {
	for _, result := range []string{"flagged", "match"} {
		quarantineCases.Preset(result)
	}
	for _, code := range []string{"55P03", "57014", "40P01", "40001"} {
		dbContention.Preset(code)
	}
	mediaBusy.Preset()
}
