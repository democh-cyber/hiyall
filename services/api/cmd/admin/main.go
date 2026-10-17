// Command admin is the Hiyall moderation console: a separate process, a separate listener and a separate
// authentication system from the public API (docs/security/15-admin-console.md).
//
//	admin [serve]                          run the console (JSON under /admin/v1, built UI at /)
//	admin operator-add -email E -role R [-name N]   create a staff account; prints the one-time authenticator enrolment
//	admin operator-reset -email E          new password and authenticator for an account; ends its sessions
//	admin operator-disable -email E -reason TEXT    disable an account at once, even the last administrator
//	admin schedule-deletion -user ID -reason TEXT [-operator EMAIL]   schedule a member's account deletion (support-driven; audited under the
//	                                       operator's e-mail address: -operator or ADMIN_OPERATOR_EMAIL, an active administrator, never a shell user)
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
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/maintenance"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr); err != nil {
		var code exitCodeError
		if errors.As(err, &code) {
			os.Exit(int(code)) // `admin healthcheck` already said why on stderr
		}
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

// exitCodeError makes run return a process exit code without logging an error line (admin healthcheck).
type exitCodeError int

func (e exitCodeError) Error() string { return fmt.Sprintf("exit %d", int(e)) }

const usageText = `usage:
  admin [serve]
  admin operator-add -email EMAIL -role viewer|moderator|admin [-name NAME]
  admin operator-reset -email EMAIL
  admin operator-disable -email EMAIL -reason TEXT
  admin schedule-deletion -user MEMBER_ID -reason TEXT [-operator EMAIL]
  admin healthcheck
  admin purge-holds [-batch N]`

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
	case "healthcheck":
		if code := healthcheck(getenv, stderr); code != 0 {
			return exitCodeError(code)
		}
		return nil
	case "purge-holds":
		return purgeHoldsCommand(ctx, args, getenv, stdout)
	case "schedule-deletion":
		return scheduleDeletionCommand(ctx, args, getenv, stdout, stderr)
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
	// Staff-only, low traffic, and some operations are long (pruning a year of audit entries, a big case): the
	// maintenance limits (2 min statement, 10 s lock wait), not the 5 s a member's request gets.
	db, err := store.New(startup, cfg.DatabaseURL, store.WithTimeouts(store.MaintenanceTimeouts))
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
	// Quarantined originals live in the evidence bucket (ADMIN_EVIDENCE_*): a read-only token for the case
	// viewer, and a separate delete credential that only the hold purge timer below uses.
	evidenceReader, evidenceDeleter, err := admin.NewEvidenceStores(startup, cfg)
	if err != nil {
		return err
	}
	if evidenceReader != nil {
		svc.Evidence, svc.EvidenceDelete = evidenceReader, evidenceDeleter
		// Say it at start, loudly: with the wrong bucket the sweep and the purge do nothing (they check again every run).
		if perr := svc.EvidenceProbe(startup); perr != nil {
			slog.Error("ALERT: the evidence sweep and the hold purge will do nothing until this is fixed", "reason", perr.Error())
		}
	} else if cfg.MediaEndpoint != "" {
		slog.Warn("quarantined photos are read from the media bucket: set ADMIN_EVIDENCE_ENDPOINT (read-only token for the evidence bucket)")
	}
	if cfg.SharedDatabase {
		slog.Warn("the console runs on DATABASE_URL (the API's database role); set ADMIN_DATABASE_URL to the hiyall_admin role (database/roles/roles.sql)")
	}
	if err = checkAdminGrants(startup, db, cfg.Env); err != nil {
		return err
	}
	var operators int
	if err = db.Pool.QueryRow(startup, `SELECT count(*) FROM operators`).Scan(&operators); err != nil {
		return errors.New("operators table unavailable; run go run ./cmd/migrate first")
	}
	if operators == 0 {
		slog.Warn("no operators exist; create one with: admin operator-add -email EMAIL -role admin")
	}
	// Clearing a case, releasing or lifting a hold and promoting an administrator each need a second administrator.
	// With fewer than two active ones none of it can ever be completed.
	if admins, aerr := svc.ActiveAdmins(startup); aerr == nil && admins < 2 {
		slog.Warn("fewer than two active administrators: two-person actions (clearing a quarantine case, releasing or lifting an evidence hold, promoting an administrator) cannot be completed; create a second one with: admin operator-add -email EMAIL -role admin", "activeAdministrators", admins)
	}
	if _, err = os.Stat(cfg.StaticDir); err != nil {
		slog.Warn("console build not found; the API works but the UI answers 503", "dir", cfg.StaticDir)
	}
	srv := &http.Server{Addr: cfg.Addr, Handler: admin.NewServer(svc, cfg).Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	shutdown, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Hourly, by one console instance at a time: the evidence sweep (pending cases, objects without a case), expiry
	// of proposals past their 24 hours and, with the delete credential, released evidence holds whose window is over.
	jobs := svc.SweepJobs()
	if svc.EvidenceDelete != nil {
		jobs = append(jobs, svc.PurgeJobs()...)
	} else if svc.Evidence != nil {
		slog.Warn("held evidence is never removed: ADMIN_EVIDENCE_DELETE_* is not set (run `admin purge-holds` where it is)")
	}
	go maintenance.Run(shutdown, db.NewLeader(admin.PurgeLockKey), jobs, time.Hour, 50)
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
			return cliError(err)
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
		return cliError(err)
	}
	// The seed is shown once, here. It is stored sealed and cannot be read back.
	fmt.Fprintf(stdout, "%s %s (%s)\n\nAuthenticator enrolment, shown once. Add it to an authenticator app now:\n  URI:    %s\n  Secret: %s\n\nThe password was not printed or logged.\n",
		map[string]string{"operator-add": "Created", "operator-reset": "Reset"}[command], enrolment.Operator.Email, enrolment.Operator.Role, enrolment.OTPAuth, enrolment.SeedText)
	return nil
}

// cliError says what a policy refusal means: the error's text is its code, which tells a person at a terminal nothing.
func cliError(err error) error {
	var policy *domain.PolicyError
	if errors.As(err, &policy) {
		return errors.New(policy.Code + ": " + policy.Message)
	}
	return err
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

// purgeHoldsCommand is `admin purge-holds [-batch N]`: one pass of the released-hold purge, for a scheduler or by
// hand where ADMIN_EVIDENCE_DELETE_* is configured. It drains what is due, N cases at a time.
func purgeHoldsCommand(ctx context.Context, args []string, getenv func(string) string, stdout io.Writer) error {
	flags := flag.NewFlagSet("purge-holds", flag.ContinueOnError)
	batch := flags.Int("batch", 50, "cases per pass")
	if err := flags.Parse(args); err != nil || *batch < 1 || *batch > 500 {
		return usageError(usageText)
	}
	cfg, err := admin.LoadConfig(getenv)
	if err != nil {
		return err
	}
	timeout, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	db, err := store.New(timeout, cfg.DatabaseURL, store.WithTimeouts(store.MaintenanceTimeouts))
	if err != nil {
		return errors.New("database connection failed; check configuration without logging credentials")
	}
	defer db.Pool.Close()
	svc, err := admin.NewService(db, cfg)
	if err != nil {
		return err
	}
	// The reader too: the purge first proves it looks at the bucket the API writes to (admin.Service.EvidenceProbe).
	if svc.Evidence, svc.EvidenceDelete, err = admin.NewEvidenceStores(timeout, cfg); err != nil {
		return err
	}
	var total int64
	for {
		n, err := svc.PurgeHolds(timeout, *batch)
		total += n
		if err != nil {
			return err
		}
		if n < int64(*batch) {
			break
		}
	}
	fmt.Fprintf(stdout, "Removed the objects of %d released hold(s).\n", total)
	return nil
}

// scheduleDeletionCommand is `admin schedule-deletion -user ID -reason TEXT [-operator EMAIL]`: the support-driven way to
// delete a member's account (the same 30 day grace period as the member's own request: sessions end at once, the purge
// runs when it is due). It is for an operator at a terminal, never an HTTP route, and is audited under the operator's
// e-mail address and the reason: -operator, else ADMIN_OPERATOR_EMAIL, naming an active administrator (the database
// function refuses anything else, so a shell user such as cli:root is never recorded). It works for a member who is
// suspended, banned or deactivated (an erasure request); such a member cannot cancel it. A member who signs in with
// Apple gets a record in the console's Apple list: nobody at Hiyall can revoke the authorization, so an operator tells
// the member to remove Hiyall in Apple ID settings and acknowledges it. Nothing here needs the member's code or password.
func scheduleDeletionCommand(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("schedule-deletion", flag.ContinueOnError)
	flags.SetOutput(stderr)
	userID := flags.String("user", "", "the member's id")
	reason := flags.String("reason", "", "why (recorded in the audit log)")
	operator := flags.String("operator", "", "e-mail address of the administrator doing this (default: ADMIN_OPERATOR_EMAIL)")
	if err := flags.Parse(args); err != nil || *userID == "" || *reason == "" {
		return usageError(usageText)
	}
	if !domain.IsID(*userID) {
		return errors.New("-user must be a member id (a UUID)")
	}
	reasonText, err := admin.Reason(*reason)
	if err != nil {
		return err
	}
	who := strings.TrimSpace(*operator)
	if who == "" {
		who = strings.TrimSpace(getenv("ADMIN_OPERATOR_EMAIL"))
	}
	if who == "" {
		return errors.New("name the administrator doing this: -operator EMAIL or ADMIN_OPERATOR_EMAIL (the deletion is audited under that address, not under a shell user)")
	}
	who, ok := admin.NormalizeEmail(who)
	if !ok {
		return errors.New("-operator / ADMIN_OPERATOR_EMAIL must be an e-mail address")
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
	due, err := db.AdminScheduleDeletion(timeout, *userID, who, reasonText)
	if err != nil {
		if errors.Is(err, store.ErrNotAdmin) {
			return errors.New(who + " is not an active administrator: -operator / ADMIN_OPERATOR_EMAIL must name one")
		}
		return cliError(err)
	}
	fmt.Fprintf(stdout, "Deletion scheduled. Their sessions have ended. The account is removed on %s unless the member signs in and cancels before then (a member who was suspended or banned cannot cancel).\nIf they signed in with Apple, tell them to remove Hiyall in Apple ID settings (Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID): nobody at Hiyall can do that for them. Acknowledge it in the console (Apple list) once you have.\n", due.UTC().Format(time.RFC3339))
	return nil
}
