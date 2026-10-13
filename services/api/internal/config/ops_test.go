package config

import "testing"

func opsEnv(t *testing.T, kv map[string]string) {
	t.Helper()
	for k, v := range map[string]string{"APP_ENV": "development", "DATABASE_URL": "postgres://x/y", "ENABLE_DEV_AUTH": "true", "LISTEN_ADDR": "127.0.0.1:8080", "FIREBASE_PROJECT_ID": ""} {
		t.Setenv(k, v)
	}
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

func TestMetricsAddrDefaultsToLoopbackAndEmptyDisables(t *testing.T) {
	opsEnv(t, nil)
	c, err := Load()
	if err != nil || c.MetricsAddr != DefaultMetricsAddr {
		t.Fatalf("default: %q, %v", c.MetricsAddr, err)
	}
	opsEnv(t, map[string]string{"METRICS_ADDR": ""})
	if c, err = Load(); err != nil || c.MetricsAddr != "" {
		t.Fatalf("empty must disable the listener: %q, %v", c.MetricsAddr, err)
	}
}

func TestMetricsListenerNeverPublicWithoutToken(t *testing.T) {
	for name, tc := range map[string]struct {
		env  map[string]string
		fail bool
	}{
		"loopback v4 no token":      {map[string]string{"METRICS_ADDR": "127.0.0.1:9100"}, false},
		"loopback v6 no token":      {map[string]string{"METRICS_ADDR": "[::1]:9100"}, false},
		"all interfaces no token":   {map[string]string{"METRICS_ADDR": "0.0.0.0:9090"}, true},
		"bare port no token":        {map[string]string{"METRICS_ADDR": ":9090"}, true},
		"private address no token":  {map[string]string{"METRICS_ADDR": "10.0.0.5:9090"}, true},
		"all interfaces short":      {map[string]string{"METRICS_ADDR": "0.0.0.0:9090", "METRICS_TOKEN": "short"}, true},
		"all interfaces with token": {map[string]string{"METRICS_ADDR": "0.0.0.0:9090", "METRICS_TOKEN": "0123456789abcdef"}, false},
		"same as public listener":   {map[string]string{"METRICS_ADDR": "127.0.0.1:8080"}, true},
		"garbage":                   {map[string]string{"METRICS_ADDR": "nine-thousand"}, true},
	} {
		t.Run(name, func(t *testing.T) {
			opsEnv(t, tc.env)
			if _, err := Load(); (err != nil) != tc.fail {
				t.Fatalf("err = %v, want failure %v", err, tc.fail)
			}
		})
	}
}

func TestRateLimitBackend(t *testing.T) {
	for value, want := range map[string]string{"": "memory", "memory": "memory", "postgres": "postgres"} {
		opsEnv(t, map[string]string{"RATE_LIMIT_BACKEND": value})
		c, err := Load()
		if err != nil || c.RateLimitBackend != want {
			t.Fatalf("%q -> %q, %v", value, c.RateLimitBackend, err)
		}
	}
	opsEnv(t, map[string]string{"RATE_LIMIT_BACKEND": "redis"})
	if _, err := Load(); err == nil {
		t.Fatal("unknown backend accepted")
	}
}
