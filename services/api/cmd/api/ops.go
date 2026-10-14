package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"time"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/metrics"
	"hiyall/services/api/internal/store"
)

// developmentMigrations is where the migrations sit relative to services/api in the repository, used
// when MIGRATIONS_DIR is not set (go run ./cmd/api from services/api).
const developmentMigrations = "../../database/migrations"

// expectedMigrations is the list /readyz checks the database against: the *.sql files in
// MIGRATIONS_DIR (set to /migrations in the container image) or, in a source checkout, the repository's
// database/migrations. When neither exists the check is off and says so.
func expectedMigrations(cfg config.Config) []string {
	dir := cfg.MigrationsDir
	if dir == "" {
		if info, err := os.Stat(developmentMigrations); err == nil && info.IsDir() {
			dir = developmentMigrations
		}
	}
	if dir == "" {
		slog.Warn("readiness will not check migrations: MIGRATIONS_DIR is not set")
		return nil
	}
	names, err := store.MigrationNames(dir)
	if err != nil || len(names) == 0 {
		slog.Warn("readiness will not check migrations: no migration files found", "dir", dir)
		return nil
	}
	return names
}

// startMetrics serves Prometheus metrics on their own listener, never the public one. It returns a
// function that stops it. With METRICS_ADDR empty nothing is started.
func startMetrics(cfg config.Config) func(context.Context) {
	if cfg.MetricsAddr == "" {
		slog.Info("metrics listener disabled (METRICS_ADDR is empty)")
		return func(context.Context) {}
	}
	srv := metrics.Server(cfg.MetricsAddr, metrics.Default, cfg.MetricsToken)
	ln, err := net.Listen("tcp", cfg.MetricsAddr)
	if err != nil {
		// Metrics are never worth refusing to serve users over.
		slog.Error("metrics listener failed to start; continuing without metrics", "address", cfg.MetricsAddr, "reason", logscrub.Err(err))
		return func(context.Context) {}
	}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("metrics listener stopped", "reason", logscrub.Err(err))
		}
	}()
	slog.Info("metrics listening", "address", cfg.MetricsAddr, "tokenRequired", cfg.MetricsToken != "")
	return func(ctx context.Context) { _ = srv.Shutdown(ctx) }
}

// healthcheck is `api healthcheck [-ready]`, the container HEALTHCHECK: a distroless image has no
// shell, curl or wget. It asks this process's own /healthz (liveness; with -ready, /readyz) and exits
// 0 only on HTTP 200. The port comes from LISTEN_ADDR, the same variable the server reads.
func healthcheck(args []string, stderr io.Writer) int {
	path := "/healthz"
	for _, a := range args {
		switch a {
		case "-ready", "--ready":
			path = "/readyz"
		default:
			fmt.Fprintln(stderr, "usage: api healthcheck [-ready]")
			return 2
		}
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintln(stderr, "invalid LISTEN_ADDR")
		return 2
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+net.JoinHostPort(host, port)+path, nil)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(stderr, "unhealthy:", err)
		return 1
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(stderr, "unhealthy: HTTP", resp.StatusCode)
		return 1
	}
	return 0
}
