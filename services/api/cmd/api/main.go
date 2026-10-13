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

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/identity"
	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/push"
	"hiyall/services/api/internal/ratelimit"
	"hiyall/services/api/internal/realtime"
	"hiyall/services/api/internal/store"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck(os.Args[2:], os.Stderr))
	}
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
	db, err := store.New(ctx, cfg.DatabaseURL, store.WithAgeBandIsolation(cfg.AgeBandIsolation))
	if err != nil {
		return errors.New("database connection failed; check configuration without logging credentials")
	}
	defer db.Pool.Close()
	if !cfg.AgeBandIsolation {
		slog.Warn("age-band isolation is OFF: minors and adults can see and reach each other (AGE_BAND_ISOLATION=false)")
	}
	var verify httpapi.Verify
	if cfg.DevAuth {
		if err = db.Seed(ctx); err != nil {
			return err
		}
		verify = db.VerifyDevSession
	} else if cfg.FirebaseProjectID != "" {
		// Firebase ID tokens: signing keys are fetched on first use, so startup needs no network.
		verify = identity.NewFirebase(ctx, cfg.FirebaseProjectID, db).Verify
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
	api.Migrations = expectedMigrations(cfg)
	if cfg.RateLimitBackend == "postgres" {
		// Per-account limits are shared by every node through the rate_limits table (migration 0030).
		api.UseSharedRateLimits(db.Pool)
	}
	// Per node: 10 sockets per account, 100k in total before clients fall back to polling.
	api.RT = realtime.NewHub(&realtime.PGBus{Pool: db.Pool, Config: db.Pool.Config().ConnConfig}, 10, 100_000)
	go api.RT.Run(background, backoff)
	api.Push = push.NewDispatcher(push.Config{
		Sender: pushSender(cfg), Online: api.RT.Connected, Queue: 4096,
		Targets: func(ctx context.Context, users []string) ([]push.Target, error) {
			rows, err := db.PushTargets(ctx, users)
			targets := make([]push.Target, len(rows))
			for i, t := range rows {
				targets[i] = push.Target(t)
			}
			return targets, err
		},
		Check: func(ctx context.Context, n push.Notice, category string) (push.Eligibility, error) {
			ok, name, err := db.PushAudience(ctx, n.Recipient, n.Actor, n.Conversation, category)
			return push.Eligibility{OK: ok, ActorName: name}, err
		},
		Forget: func(ctx context.Context, t push.Target) error {
			return db.ClearPushToken(ctx, t.DeviceID, t.Provider, t.Token)
		},
	})
	api.Push.Run(background, 4)
	if cfg.MediaEndpoint != "" {
		objects, err := media.NewS3(ctx, media.S3Config{Endpoint: cfg.MediaEndpoint, AccessKey: cfg.MediaAccessKey, SecretKey: cfg.MediaSecretKey, Bucket: cfg.MediaBucket, Region: cfg.MediaRegion, Secure: cfg.MediaSecure})
		if err != nil {
			return errors.New("media storage unavailable; check MEDIA_* configuration")
		}
		api.Media = objects
	} else {
		slog.Warn("media storage not configured; photo uploads are off")
	}
	if cfg.ChatMediaEndpoint != "" {
		// A token scoped to the one chat bucket cannot create buckets, so it is never asked to.
		objects, err := media.NewS3(ctx, media.S3Config{Endpoint: cfg.ChatMediaEndpoint, AccessKey: cfg.ChatMediaAccessKey, SecretKey: cfg.ChatMediaSecretKey, Bucket: cfg.ChatMediaBucket, Region: cfg.ChatMediaRegion, Secure: cfg.ChatMediaSecure, NoCreate: true})
		if err != nil {
			return errors.New("chat media storage unavailable; check CHAT_MEDIA_* configuration")
		}
		api.ChatMedia = objects
	} else {
		slog.Warn("chat media storage not configured; sending photos in chats is off (CHAT_MEDIA_UNAVAILABLE)")
	}
	// The last step of an account purge removes the Firebase user; without a service account it only logs.
	var identities store.IdentityDeleter = identity.LogDeleter{}
	if cfg.FirebaseServiceAccountFile != "" {
		deleter, err := identity.NewFirebaseDeleter(cfg.FirebaseProjectID, cfg.FirebaseServiceAccountFile)
		if err != nil {
			return err
		}
		identities = deleter
	}
	// Shutdown order: stop serving, then stop maintenance and wait (briefly) for it to give up the
	// leader lock, then close the pool.
	maintenanceDone := make(chan struct{})
	go func() {
		defer close(maintenanceDone)
		maintain(background, db, api.Media, api.ChatMedia, identities)
	}()
	defer func() {
		stopBackground()
		select {
		case <-maintenanceDone:
		case <-time.After(5 * time.Second):
		}
	}()
	stopMetrics := startMetrics(cfg)
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		stopMetrics(ctx)
	}()
	srv := &http.Server{Addr: cfg.Listen, Handler: api.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32768}
	srv.RegisterOnShutdown(api.RT.CloseAll)
	shutdown, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() {
		slog.Info("API listening", "address", cfg.Listen, "environment", cfg.Env, "developmentAuth", cfg.DevAuth, "firebaseAuth", !cfg.DevAuth && cfg.FirebaseProjectID != "")
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

// pushSender is FCM when FCM_SERVICE_ACCOUNT_FILE is set, otherwise the logging stand-in, so
// development and tests need no credentials. A broken file stops nothing: pushes fall back to
// logging and the reason is logged (never the key).
func pushSender(cfg config.Config) push.Sender {
	if cfg.FCMServiceAccountFile == "" {
		slog.Warn("push notifications not configured; pushes are only logged (FCM_SERVICE_ACCOUNT_FILE)")
		return push.LogSender{}
	}
	account, err := push.LoadServiceAccount(cfg.FCMServiceAccountFile)
	if err == nil {
		var sender *push.FCM
		if sender, err = push.NewFCM(cfg.FCMProjectID, account); err == nil {
			slog.Info("push notifications: FCM", "project", sender.ProjectID)
			return sender
		}
	}
	slog.Error("push notifications disabled; pushes are only logged", "reason", err.Error())
	return push.LogSender{}
}

// backoff waits 1s, 2s, 4s … up to 30s, with jitter, between bus reconnects.
func backoff(attempt int) time.Duration {
	delay := min(time.Second<<min(attempt, 5), 30*time.Second)
	return delay/2 + time.Duration(rand.Int64N(int64(delay/2)+1))
}

// maintain runs hourly cleanup in small batches so it never holds long locks:
// delivered envelope rows after 7 days, undelivered ciphertext after 30,
// sessions 30 days after they expired (revoked sign-ins from an identity provider
// are kept; see store.PurgeSessions), key claim records after a day, stories a
// day after they expire, and shared locations 7 days after their last update
// (they stop counting as shared after 24 hours). Encrypted chat attachments are removed from the chat
// bucket 30 days after their message (an hour when never sent), and when deleted or their chat was blocked;
// blobs held as report evidence are kept.
func maintain(ctx context.Context, db *store.Store, objects, chatObjects media.Store, identities store.IdentityDeleter) {
	jobs := []struct {
		name string
		run  func() (int64, error)
	}{
		{"ciphertext expiry", func() (int64, error) { return db.ExpireEnvelopes(ctx, 7*24*time.Hour, 30*24*time.Hour, 5000) }},
		{"session purge", func() (int64, error) { return db.PurgeSessions(ctx, 30*24*time.Hour, 5000) }},
		{"key claim purge", func() (int64, error) { return db.PurgeKeyClaims(ctx, 5000) }},
		{"story purge", func() (int64, error) { return db.PurgeStories(ctx, 5000) }},
		{"location purge", func() (int64, error) { return db.PurgeLocations(ctx, domain.LocationRetentionDays*24*time.Hour, 5000) }},
		{"media cleanup", func() (int64, error) {
			if objects == nil {
				return 0, nil
			}
			keys, rows, err := db.MediaGarbage(ctx, 5000)
			if err == nil {
				err = objects.Delete(ctx, keys...)
			}
			return rows, err
		}},
		{"chat blob cleanup", func() (int64, error) {
			if chatObjects == nil {
				return 0, nil
			}
			return db.PurgeChatBlobs(ctx, chatObjects, 5000)
		}},
		{"chat blob tombstone purge", func() (int64, error) { return db.PurgeChatBlobTombstones(ctx, 5000) }},
		// Accounts past their 30 day grace period (docs/api/22-account-deletion-and-export.md). After the
		// cleanups above, so a purge that marked files deleted last time finds them removed this time.
		{"account purge", func() (int64, error) { return db.PurgeDeletedAccounts(ctx, identities, 50) }},
		{"deleted identity purge", func() (int64, error) { return db.PurgeDeletedIdentities(ctx, 24*time.Hour, 5000) }},
		{"rate limit purge", func() (int64, error) { return ratelimit.Purge(ctx, db.Pool, 5000) }},
	}
	// Every instance runs this loop but only the one holding the advisory lock runs the jobs; the
	// lock is given up on shutdown so another instance takes over at its next tick.
	list := make([]maintenance.Job, len(jobs))
	for i, j := range jobs {
		list[i] = maintenance.Job{Name: j.name, Run: j.run}
	}
	maintenance.Run(ctx, db.NewLeader(store.MaintenanceLockKey), list, time.Hour, 5000)
}
