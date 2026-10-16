package push

// Created at zero at startup so an alert on increase() sees the first event after a restart (see httpapi/metrics_preset.go).
func init() { pushConfigErrors.Preset("fcm") }
