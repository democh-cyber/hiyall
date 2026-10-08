package main

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata"

	"kairova/services/api/internal/config"
	"kairova/services/api/internal/httpapi"
	"kairova/services/api/internal/identity"
	"kairova/services/api/internal/push"
	"kairova/services/api/internal/realtime"
	"kairova/services/api/internal/store"
)

func main() {
	if err := run(); err != nil {
		slog.Error("startup failed", "reason", err.Error())
		os.Exit(1)
	}
}
func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	db, err := store.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return errors.New("database connection failed; check configuration without logging credentials")
	}
	defer db.Pool.Close()
	var verify httpapi.Verify
	if cfg.DevAuth {
		if err = db.Seed(ctx); err != nil {
			return err
		}
		verify = db.VerifyDevSession
	} else {
		v, err := identity.New(ctx, cfg.Issuer, cfg.Audience, db)
		if err != nil {
			return errors.New("OIDC discovery failed; check issuer configuration and connectivity")
		}
		verify = v.Verify
	}
	background, stopBackground := context.WithCancel(context.Background())
	defer stopBackground()
	api := httpapi.New(db, verify, cfg.DevAuth, cfg.Origin)
	// Per node: 10 sockets per account, 100k in total before clients fall back to polling.
	api.RT = realtime.NewHub(&realtime.PGBus{Pool: db.Pool, Config: db.Pool.Config().ConnConfig}, 10, 100_000)
	go api.RT.Run(background, backoff)
	api.Push = push.NewDispatcher(push.LogSender{}, func(ctx context.Context, users []string) ([]push.Target, error) {
		rows, err := db.PushTargets(ctx, users)
		targets := make([]push.Target, len(rows))
		for i, t := range rows {
			targets[i] = push.Target(t)
		}
		return targets, err
	}, api.RT.Connected, 4096)
	api.Push.Run(background, 4)
	go maintain(background, db)
	srv := &http.Server{Addr: cfg.Listen, Handler: api.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32768}
	srv.RegisterOnShutdown(api.RT.CloseAll)
	shutdown, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() {
		slog.Info("API listening", "address", cfg.Listen, "environment", cfg.Env, "developmentAuth", cfg.DevAuth)
		done <- srv.ListenAndServe()
	}()
	select {
	case err := <-done:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	case <-shutdown.Done():
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(ctx)
	}
}

// backoff waits 1s, 2s, 4s … up to 30s, with jitter, between bus reconnects.
func backoff(attempt int) time.Duration {
	delay := min(time.Second<<min(attempt, 5), 30*time.Second)
	return delay/2 + time.Duration(rand.Int64N(int64(delay/2)+1))
}

// maintain runs hourly cleanup in small batches so it never holds long locks:
// delivered envelope rows after 7 days, undelivered ciphertext after 30, and
// sessions 30 days after they expired.
func maintain(ctx context.Context, db *store.Store) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	jobs := []struct {
		name string
		run  func() (int64, error)
	}{
		{"ciphertext expiry", func() (int64, error) { return db.ExpireEnvelopes(ctx, 7*24*time.Hour, 30*24*time.Hour, 5000) }},
		{"session purge", func() (int64, error) { return db.PurgeSessions(ctx, 30*24*time.Hour, 5000) }},
	}
	for {
		for _, job := range jobs {
			for {
				n, err := job.run()
				if err != nil {
					if ctx.Err() == nil {
						slog.Warn(job.name+" failed", "reason", err.Error())
					}
					break
				}
				if n < 5000 {
					break
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
