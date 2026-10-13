package config

import (
	"errors"
	"net"
	"os"
	"strings"
)

// DefaultMetricsAddr is where Prometheus metrics are served unless METRICS_ADDR says otherwise:
// loopback only, never the public listener.
const DefaultMetricsAddr = "127.0.0.1:9090"

// loadOps reads the operational settings: metrics listener, rate-limit backend, migrations directory.
func (c *Config) loadOps() error {
	// METRICS_ADDR unset means the default; set but empty means "no metrics listener".
	if v, set := os.LookupEnv("METRICS_ADDR"); set {
		c.MetricsAddr = strings.TrimSpace(v)
	} else {
		c.MetricsAddr = DefaultMetricsAddr
	}
	c.MetricsToken = os.Getenv("METRICS_TOKEN")
	if c.MetricsAddr != "" {
		host, _, err := net.SplitHostPort(c.MetricsAddr)
		if err != nil {
			return errors.New("invalid METRICS_ADDR")
		}
		if c.MetricsAddr == c.Listen {
			return errors.New("METRICS_ADDR must differ from LISTEN_ADDR: metrics are never served on the public listener")
		}
		ip := net.ParseIP(host)
		// An empty host ("0.0.0.0" or ":9090") and any non-loopback address is reachable by others.
		if (ip == nil || !ip.IsLoopback()) && len(c.MetricsToken) < 16 {
			return errors.New("METRICS_TOKEN (at least 16 characters) is required when METRICS_ADDR is not a loopback address")
		}
	}
	switch c.RateLimitBackend = os.Getenv("RATE_LIMIT_BACKEND"); c.RateLimitBackend {
	case "":
		c.RateLimitBackend = "memory"
	case "memory", "postgres":
	default:
		return errors.New("RATE_LIMIT_BACKEND must be memory or postgres")
	}
	c.MigrationsDir = os.Getenv("MIGRATIONS_DIR")
	return nil
}
