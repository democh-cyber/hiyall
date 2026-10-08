package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata"

	"kairova/services/api/internal/config"
	"kairova/services/api/internal/httpapi"
	"kairova/services/api/internal/identity"
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
	srv := &http.Server{Addr: cfg.Listen, Handler: httpapi.New(db, verify, cfg.DevAuth, cfg.Origin).Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32768}
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
