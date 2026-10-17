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

	"hiyall/services/api/internal/appcheck"
	"hiyall/services/api/internal/buildinfo"
	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/errreport"
	"hiyall/services/api/internal/httpapi"
	"hiyall/services/api/internal/identity"
	"hiyall/services/api/internal/logscrub"
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
	if len(os.Args) > 1 && os.Args[1] == "check-config" {
		// `api check-config [-release]`: validate the environment like a start would, without starting (checkconfig.go).
		os.Exit(checkConfig(os.Args[2:], os.Stdout, os.Stderr))
	}
	if err := run(); err != nil {
		slog.Error("startup failed", "reason", logscrub.Err(err))
		os.Exit(1)
	}
}
func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	setupLogging(cfg)
	slog.Info("starting", "version", buildinfo.Version, "commit", buildinfo.Commit, "environment", cfg.Env, "logFormat", cfg.LogFormat)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	db, err := store.New(ctx, cfg.DatabaseURL, store.WithAgeBandIsolation(cfg.AgeBandIsolation), store.WithMaxConns(cfg.DBMaxConns),
		store.WithTimeouts(store.Timeouts{Statement: cfg.DBStatementTimeout, Lock: cfg.DBLockTimeout, IdleInTransaction: cfg.DBIdleTimeout}))
	if err != nil {
		return errors.New("database connection failed; check configuration without logging credentials")
	}
	defer db.Pool.Close()
	if err = enforceDBRole(ctx, db, cfg.Env); err != nil {
		return err
	}
	grantsCheck, err := enforceGrants(ctx, db, cfg.Env)
	if err != nil {
		return err
	}
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
	api.GrantsCheck = grantsCheck
	api.SpacesEvents = cfg.SpacesEventsEnabled
	api.ClientIP = cfg.ClientIPResolver()
	logClientIPMode(cfg)
	if cfg.CursorKey != nil {
		api.SetCursorKeys(cfg.CursorKey, cfg.CursorKeyPrevious)
	} else {
		slog.Warn("CURSOR_KEY is not set: list cursors are signed with a random key that dies with this process (development only)")
	}
	api.SetMinClientVersions(cfg.MinClientVersion)
	switch {
	case cfg.AppCheckMode != appcheck.Off:
		// Firebase App Check: tokens are verified against Firebase's keys (fetched on first use). In log mode
		// missing and invalid tokens are only counted (hiyall_app_check_total); true refuses them.
		api.AppCheck, api.AppCheckMode = appcheck.New(ctx, cfg.FirebaseProjectNumber), cfg.AppCheckMode
		slog.Info("App Check is on", "mode", string(cfg.AppCheckMode))
	case cfg.Env == "production" && cfg.FirebaseProjectID != "":
		slog.Warn("App Check is off (APP_CHECK_ENFORCE=false); requests are not tied to the real app")
	}
	if cfg.SentryDSN != "" {
		// Panics and unexpected 500s go to Sentry with a scrubbed message, the route pattern and the request id;
		// never the URL, headers or body (internal/errreport). Unset SENTRY_DSN: errors are only logged.
		release := cfg.SentryRelease
		if release == "" && buildinfo.Version != "dev" {
			release = buildinfo.Version // stamped into the image by the release build (SENTRY_RELEASE overrides it)
		}
		reporter, err := errreport.New(errreport.Options{DSN: cfg.SentryDSN, Environment: cfg.SentryEnvironment, Release: release})
		if err != nil {
			return errors.New("SENTRY_DSN is not a valid DSN")
		}
		api.Reporter = reporter
		defer func() {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			reporter.Flush(ctx)
		}()
	} else if cfg.Env == "production" {
		slog.Warn("error reporting is off (SENTRY_DSN unset); panics and 500s are only logged")
	}
	if cfg.RateLimitBackend == "postgres" {
		// Per-account limits are shared by every node through the rate_limits table (migration 0030).
		api.UseSharedRateLimits(db.Pool)
	}
	// Per node: 10 sockets per account, 100k in total before clients fall back to polling.
	api.RT = realtime.NewHub(&realtime.PGBus{Pool: db.Pool, Config: db.Pool.Config().ConnConfig}, 10, 100_000)
	go api.RT.Run(background, backoff)
	sender, err := pushSender(cfg)
	if err != nil {
		return err
	}
	api.Push = push.NewDispatcher(push.Config{
		Sender: sender, Online: api.RT.Connected, Queue: 4096,
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
		if api.Scanner, err = uploadScanner(cfg); err != nil {
			return err
		}
	} else {
		slog.Warn("media storage not configured; photo uploads are off")
	}
	heldObjects, err := wireSafety(ctx, cfg, api)
	if err != nil {
		return err
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
	apple, err := appleRevoker(cfg)
	if err != nil {
		return err
	}
	if apple != nil {
		api.Apple = apple
	}
	identities = withApple(identities, apple, db)
	// The background jobs and their leader lock use a small pool of their own with longer timeouts.
	maintDB, err := db.NewMaintenance(ctx)
	if err != nil {
		return errors.New("database connection failed for maintenance")
	}
	defer maintDB.Pool.Close()
	// Shutdown order: stop serving, then stop maintenance and wait (briefly) for it to give up the
	// leader lock, then close the pool.
	maintenanceDone := make(chan struct{})
	go func() {
		defer close(maintenanceDone)
		maintain(background, maintDB, api.Media, heldObjects, api.ChatMedia, identities)
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

// pushSender is FCM when FCM_SERVICE_ACCOUNT_FILE is set, otherwise the logging stand-in, so development
// and tests need no credentials. A file that is set but unusable stops a production start (the operator
// believes pushes work); in development it falls back to logging and logs why (never the key).
func pushSender(cfg config.Config) (push.Sender, error) {
	if cfg.FCMServiceAccountFile == "" {
		slog.Warn("push notifications not configured; pushes are only logged (FCM_SERVICE_ACCOUNT_FILE)")
		return push.LogSender{}, nil
	}
	account, err := push.LoadServiceAccount(cfg.FCMServiceAccountFile)
	if err == nil {
		var sender *push.FCM
		if sender, err = push.NewFCM(cfg.FCMProjectID, account); err == nil {
			slog.Info("push notifications: FCM", "project", sender.ProjectID)
			return sender, nil
		}
	}
	if cfg.Env == "production" {
		return nil, errors.New("FCM_SERVICE_ACCOUNT_FILE is set but unusable: " + logscrub.Err(err))
	}
	slog.Error("push notifications disabled; pushes are only logged", "reason", logscrub.Err(err))
	return push.LogSender{}, nil
}

// setupLogging makes slog's default logger JSON (LOG_FORMAT, default json in production) or text, so
// every package's slog call and the startup log come out in one format.
func setupLogging(cfg config.Config) {
	var handler slog.Handler
	if cfg.LogFormat == "json" {
		handler = slog.NewJSONHandler(os.Stdout, nil)
	} else {
		handler = slog.NewTextHandler(os.Stdout, nil)
	}
	slog.SetDefault(slog.New(handler))
}

// logClientIPMode says how a request's address is decided, once, so a misconfigured proxy shows in the log.
func logClientIPMode(cfg config.Config) {
	switch {
	case cfg.ClientIPResolver().Enabled() && cfg.ClientIPHeader != "":
		slog.Info("client address: trusted proxies, header", "trustedProxies", len(cfg.TrustedProxies), "header", cfg.ClientIPHeader)
	case cfg.ClientIPResolver().Enabled():
		slog.Info("client address: trusted proxies, rightmost untrusted X-Forwarded-For hop", "trustedProxies", len(cfg.TrustedProxies))
	case cfg.DirectListener:
		slog.Info("client address: direct peer (DIRECT_LISTENER=true: no proxy in front, forwarding headers are ignored)")
	default:
		slog.Info("client address: direct peer (TRUSTED_PROXY_CIDRS unset; behind a proxy every client shares one rate-limit bucket)")
	}
	// A start cannot see the proxy: the peer is only known when traffic arrives. Say so, and where it will show.
	slog.Info("client address self-test: the observed peer is unknown until the first request; it is logged then (\"client address: first request\"), and a forwarding header from an untrusted peer warns once a minute and counts in hiyall_untrusted_forwarding_total",
		"debugLogPeer", cfg.DebugLogPeer, "hint", "set DEBUG_LOG_PEER=true temporarily to log the peer and forwarding headers of the first 20 requests")
}

// backoff waits 1s, 2s, 4s … up to 30s, with jitter, between bus reconnects.
func backoff(attempt int) time.Duration {
	delay := min(time.Second<<min(attempt, 5), 30*time.Second)
	return delay/2 + time.Duration(rand.Int64N(int64(delay/2)+1))
}

// jobOption changes how maintenanceJobs builds the list.
type jobOption struct{ held media.Store }

// onlyHeldObjects limits the released-hold cleanup to held (nil: the API never deletes held evidence).
func onlyHeldObjects(held media.Store) jobOption { return jobOption{held: held} }

// maintain runs hourly cleanup in small batches so it never holds long locks:
// delivered envelope rows after 7 days, undelivered ciphertext after 30,
// sessions 30 days after they expired (revoked sign-ins from an identity provider
// are kept; see store.PurgeSessions), key claim records after a day, stories a
// day after they expire, and shared locations 7 days after their last update
// (they stop counting as shared after 24 hours). Encrypted chat attachments are removed from the chat
// bucket 30 days after their message (an hour when never sent), and when deleted or their chat was blocked;
// blobs held as report evidence are kept.
func maintain(ctx context.Context, db *store.Store, objects, heldObjects, chatObjects media.Store, identities store.IdentityDeleter) {
	// Every instance runs this loop but only the one holding the advisory lock runs the jobs; the
	// lock is given up on shutdown so another instance takes over at its next tick.
	maintenance.Run(ctx, db.NewLeader(store.MaintenanceLockKey), maintenanceJobs(db, objects, chatObjects, identities, onlyHeldObjects(heldObjects)), time.Hour, 5000)
}

// maintenanceJobs is every hourly job (the list is also what the restricted role test runs).
//
// The hold cleanup deletes held evidence with objects (the media bucket) unless onlyHeldObjects says where it may
// delete: nil when evidence has its own bucket, whose delete credential only the console holds.
func maintenanceJobs(db *store.Store, objects, chatObjects media.Store, identities store.IdentityDeleter, opts ...jobOption) []maintenance.Job {
	heldObjects := objects
	for _, o := range opts {
		heldObjects = o.held
	}
	// Each job gets its own context, which ends at its timeout (maintenance.Job.Timeout; ten minutes
	// unless set), and runs on db: the maintenance pool, whose statement timeout is longer than a request's.
	type job struct {
		name    string
		run     func(ctx context.Context) (int64, error)
		timeout time.Duration
	}
	jobs := []job{
		{"ciphertext expiry", func(ctx context.Context) (int64, error) {
			return db.ExpireEnvelopes(ctx, 7*24*time.Hour, store.UndeliveredEnvelopeTTL, 5000)
		}, 0},
		{"stale chat devices", func(ctx context.Context) (int64, error) {
			return db.RevokeStaleDevices(ctx, store.StaleDeviceAfter, 500)
		}, 0},
		// A device idle for three days that holds more than half the undelivered-envelope cap is on its way to
		// refusing its owner's inbound chat (audit CHAT-N1); the send path revokes one that is over the cap.
		{"backlogged chat devices", func(ctx context.Context) (int64, error) {
			return db.RevokeBackloggedDevices(ctx, domain.Free().ChatBacklogPerDevice, store.BackloggedDeviceIdle, 500)
		}, 0},
		{"session purge", func(ctx context.Context) (int64, error) { return db.PurgeSessions(ctx, 30*24*time.Hour, 5000) }, 0},
		{"key claim purge", func(ctx context.Context) (int64, error) { return db.PurgeKeyClaims(ctx, 5000) }, 0},
		{"story purge", func(ctx context.Context) (int64, error) { return db.PurgeStories(ctx, 5000) }, 0},
		{"location purge", func(ctx context.Context) (int64, error) {
			return db.PurgeLocations(ctx, domain.LocationRetentionDays*24*time.Hour, 5000)
		}, 0},
		{"daily count purge", func(ctx context.Context) (int64, error) { return db.PurgeDailyCounts(ctx, 3, 5000) }, 0},
		{"age refusal purge", func(ctx context.Context) (int64, error) { return db.PurgeAgeRefusals(ctx, 30*24*time.Hour, 5000) }, 0},
		{"idempotency key purge", func(ctx context.Context) (int64, error) {
			return db.PurgeIdempotencyKeys(ctx, store.IdempotencyRetention, 5000)
		}, 0},
		// Objects first, rows after (store.PurgeMedia); a photo row is only finished once its objects are gone.
		{"media cleanup", func(ctx context.Context) (int64, error) {
			if objects == nil {
				return 0, nil
			}
			return db.PurgeMedia(ctx, objects, 5000)
		}, 20 * time.Minute},
		// The original of a quarantined photo that could not be removed from the upload prefix when it was quarantined
		// (round-4 N-7; recorded in quarantine_upload_leftovers).
		{"quarantine upload leftovers", func(ctx context.Context) (int64, error) {
			if objects == nil {
				return 0, nil
			}
			return db.PurgeUploadLeftovers(ctx, objects, 500)
		}, 0},
		// Held evidence (quarantined uploads) whose hold an administrator released and whose retention window is over.
		// Only with evidence kept in the media bucket (EVIDENCE_ALLOW_SHARED_BUCKET, development): the API's token
		// there can delete. With an evidence bucket the API cannot, and the console's `admin purge-holds` does it.
		{"released hold cleanup", func(ctx context.Context) (int64, error) {
			if heldObjects == nil {
				return 0, nil
			}
			return db.PurgeReleasedHolds(ctx, heldObjects, 50)
		}, 20 * time.Minute},
		{"nearby probe purge", func(ctx context.Context) (int64, error) { return db.PurgeNearbyProbes(ctx, 3, 5000) }, 0},
		{"chat blob cleanup", func(ctx context.Context) (int64, error) {
			if chatObjects == nil {
				return 0, nil
			}
			return db.PurgeChatBlobs(ctx, chatObjects, 5000)
		}, 20 * time.Minute},
		{"chat blob tombstone purge", func(ctx context.Context) (int64, error) { return db.PurgeChatBlobTombstones(ctx, 5000) }, 0},
		// Accounts past their 30 day grace period (docs/api/22-account-deletion-and-export.md). After the
		// cleanups above, so a purge that marked files deleted last time finds them removed this time.
		{"account purge", func(ctx context.Context) (int64, error) { return db.PurgeDeletedAccounts(ctx, identities, 50) }, 20 * time.Minute},
		{"deleted identity purge", func(ctx context.Context) (int64, error) { return db.PurgeDeletedIdentities(ctx, 24*time.Hour, 5000) }, 0},
		{"rate limit purge", func(ctx context.Context) (int64, error) { return ratelimit.Purge(ctx, db.Pool, 5000) }, 0},
	}
	list := make([]maintenance.Job, len(jobs))
	for i, j := range jobs {
		list[i] = maintenance.Job{Name: j.name, Run: j.run, Timeout: j.timeout}
	}
	return append(list, retentionJobs(db)...)
}
