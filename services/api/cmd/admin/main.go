// Command admin is the Hiyall moderation console: a separate process, a separate listener and a separate
// authentication system from the public API (docs/security/15-admin-console.md).
//
//	admin [serve]                          run the console (JSON under /admin/v1, built UI at /)
//	admin operator-add -email E -role R [-name N]   create a staff account; prints the one-time authenticator enrolment
//	admin operator-reset -email E          new password and authenticator for an account; ends its sessions
//	admin operator-disable -email E -reason TEXT    disable an account at once, even the last administrator
//
// Staff accounts exist only because this command created them. The password is read from a terminal
// prompt, or from the first line of stdin when stdin is not a terminal; it is never taken from a flag,
// the environment or a log. The environment is the same as the other binaries (APP_ENV, DATABASE_URL)
// plus ADMIN_DATA_KEY, ADMIN_ADDR, ADMIN_STATIC_DIR, ADMIN_ALLOW_REMOTE, ADMIN_TRUST_PROXY,
// ADMIN_ALLOWED_HOSTS, ADMIN_TLS_CERT and ADMIN_TLS_KEY, ADMIN_DATABASE_URL (the hiyall_admin role; falls back to
// DATABASE_URL) and ADMIN_MEDIA_* (read-only photo storage token for the content preview).
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"os/user"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"hiyall/services/api/internal/admin"
	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr); err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			fmt.Fprintln(os.Stderr, string(usage))
			os.Exit(2)
		}
		slog.Error("admin failed", "reason", logscrub.Err(err))
		os.Exit(1)
	}
}

type usageError string

func (u usageError) Error() string { return string(u) }

const usageText = `usage:
  admin [serve]
  admin operator-add -email EMAIL -role viewer|moderator|admin [-name NAME]
  admin operator-reset -email EMAIL
  admin operator-disable -email EMAIL -reason TEXT`

func run(ctx context.Context, args []string, getenv func(string) string, stdin io.Reader, stdout, stderr io.Writer) error {
	command := "serve"
	if len(args) > 0 {
		command, args = args[0], args[1:]
	}
	switch command {
	case "serve":
		if len(args) > 0 {
			return usageError(usageText)
		}
		return serve(ctx, getenv)
	case "operator-add", "operator-reset", "operator-disable":
		return operatorCommand(ctx, command, args, getenv, stdin, stdout, stderr)
	}
	return usageError(usageText)
}

func serve(ctx context.Context, getenv func(string) string) error {
	cfg, err := admin.LoadConfig(getenv)
	if err != nil {
		return err
	}
	startup, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	db, err := store.New(startup, cfg.DatabaseURL)
	if err != nil {
		return errors.New("database connection failed; check configuration without logging credentials")
	}
	defer db.Pool.Close()
	svc, err := admin.NewService(db, cfg)
	if err != nil {
		return err
	}
	if cfg.MediaEndpoint != "" {
		// A read-only token for the media bucket. It never creates a bucket and the console never writes to it.
		objects, err := media.NewS3(startup, media.S3Config{Endpoint: cfg.MediaEndpoint, AccessKey: cfg.MediaAccessKey, SecretKey: cfg.MediaSecretKey, Bucket: cfg.MediaBucket, Region: cfg.MediaRegion, Secure: cfg.MediaSecure, NoCreate: true})
		if err != nil {
			return errors.New("media storage unavailable; check ADMIN_MEDIA_* configuration")
		}
		svc.Media = objects
	} else {
		slog.Warn("photo preview off: ADMIN_MEDIA_ENDPOINT is not set; the console shows reported text only")
	}
	if cfg.SharedDatabase {
		slog.Warn("the console runs on DATABASE_URL (the API's database role); set ADMIN_DATABASE_URL to the hiyall_admin role (database/roles/roles.sql)")
	}
	var operators int
	if err = db.Pool.QueryRow(startup, `SELECT count(*) FROM operators`).Scan(&operators); err != nil {
		return errors.New("operators table unavailable; run go run ./cmd/migrate first")
	}
	if operators == 0 {
		slog.Warn("no operators exist; create one with: admin operator-add -email EMAIL -role admin")
	}
	if _, err = os.Stat(cfg.StaticDir); err != nil {
		slog.Warn("console build not found; the API works but the UI answers 503", "dir", cfg.StaticDir)
	}
	srv := &http.Server{Addr: cfg.Addr, Handler: admin.NewServer(svc, cfg).Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	shutdown, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() {
		slog.Info("admin console listening", "address", cfg.Addr, "tls", cfg.TLSCert != "", "trustProxy", cfg.TrustProxy, "environment", cfg.Env)
		if cfg.TLSCert != "" {
			done <- srv.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
		} else {
			done <- srv.ListenAndServe()
		}
	}()
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-shutdown.Done():
		sctx, c := context.WithTimeout(context.Background(), 10*time.Second)
		defer c()
		return srv.Shutdown(sctx)
	}
}

func operatorCommand(ctx context.Context, command string, args []string, getenv func(string) string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	email := flags.String("email", "", "operator e-mail address")
	role := flags.String("role", "", "viewer, moderator or admin")
	name := flags.String("name", "", "display name (default: the part of the address before @)")
	reason := flags.String("reason", "", "why (recorded in the audit log)")
	if err := flags.Parse(args); err != nil {
		return usageError(usageText)
	}
	if *email == "" || (command == "operator-add" && *role == "") || (command == "operator-disable" && *reason == "") {
		return usageError(usageText)
	}
	cfg, err := admin.LoadConfig(getenv)
	if err != nil {
		return err
	}
	timeout, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	db, err := store.New(timeout, cfg.DatabaseURL)
	if err != nil {
		return errors.New("database connection failed; check configuration without logging credentials")
	}
	defer db.Pool.Close()
	svc, err := admin.NewService(db, cfg)
	if err != nil {
		return err
	}
	actor := "cli:" + osUser()
	switch command {
	case "operator-disable":
		reasonText, err := admin.Reason(*reason)
		if err != nil {
			return err
		}
		norm, ok := admin.NormalizeEmail(*email)
		if !ok {
			return errors.New("not a valid address")
		}
		var id string
		if err = db.Pool.QueryRow(timeout, `SELECT operator_id::text FROM operators WHERE email=$1`, norm).Scan(&id); err != nil {
			return errors.New("no such operator")
		}
		// guards=false: when a stolen device belongs to the only administrator, they are still shut out.
		if _, err = svc.SetDisabled(timeout, admin.Actor{Label: actor}, id, true, reasonText, false); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "Disabled. Their sessions have ended.")
		return nil
	}
	password, err := readPassword(stdin, stderr)
	if err != nil {
		return err
	}
	var enrolment admin.Enrolment
	if command == "operator-add" {
		r, ok := admin.ParseRole(*role)
		if !ok {
			return usageError(usageText)
		}
		display := strings.TrimSpace(*name)
		if display == "" {
			display, _, _ = strings.Cut(strings.TrimSpace(*email), "@")
		}
		enrolment, err = svc.CreateOperator(timeout, *email, display, r, password, actor)
	} else {
		enrolment, err = svc.ResetOperator(timeout, *email, password, actor)
	}
	if err != nil {
		return err
	}
	// The seed is shown once, here. It is stored sealed and cannot be read back.
	fmt.Fprintf(stdout, "%s %s (%s)\n\nAuthenticator enrolment, shown once. Add it to an authenticator app now:\n  URI:    %s\n  Secret: %s\n\nThe password was not printed or logged.\n",
		map[string]string{"operator-add": "Created", "operator-reset": "Reset"}[command], enrolment.Operator.Email, enrolment.Operator.Role, enrolment.OTPAuth, enrolment.SeedText)
	return nil
}

func osUser() string {
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	return "unknown"
}

// readPassword prompts twice without echo on a terminal, or reads the first line of piped stdin.
func readPassword(stdin io.Reader, prompt io.Writer) (string, error) {
	if f, ok := stdin.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		ask := func(label string) (string, error) {
			fmt.Fprint(prompt, label)
			b, err := term.ReadPassword(int(f.Fd()))
			fmt.Fprintln(prompt)
			return string(b), err
		}
		first, err := ask("Password (at least 12 characters): ")
		if err != nil {
			return "", err
		}
		second, err := ask("Repeat password: ")
		if err != nil {
			return "", err
		}
		if first != second {
			return "", errors.New("passwords do not match")
		}
		return first, nil
	}
	line, err := bufio.NewReader(io.LimitReader(stdin, admin.MaxPasswordLength*2)).ReadString('\n')
	if err != nil && (!errors.Is(err, io.EOF) || line == "") {
		return "", errors.New("no password on stdin")
	}
	return strings.TrimRight(line, "\r\n"), nil
}
