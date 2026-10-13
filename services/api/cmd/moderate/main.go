// Command moderate is the trust-and-safety operator command line. The admin console (cmd/admin) is the
// day-to-day tool; this stays as the break-glass path with direct database access and uses the same
// store methods (ResolveReport, RestoreUser), so both resolve a report identically. It reads
// DATABASE_URL and never touches chat
// ciphertext: the only message text it shows is what reporters chose to share. Encrypted images held
// as evidence are listed by blob id, size and SHA-256 only; nothing is fetched or decrypted.
//
//	moderate queue [-limit 20]
//	moderate resolve -report ID -action dismiss|warn|suspend -operator NAME [-note TEXT]
//	moderate restore -user ID -operator NAME [-note TEXT]
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

	"hiyall/services/api/internal/store"
)

var errUsage = errors.New(usageText)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := store.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Pool.Close()
	if err = run(ctx, db, os.Args[1:], os.Stdout); err != nil {
		if errors.Is(err, errUsage) {
			usage()
		}
		log.Fatal(err)
	}
}

// run executes one subcommand against db, writing its report to out.
func run(ctx context.Context, db *store.Store, args []string, out io.Writer) error {
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	limit := flags.Int("limit", 20, "reports to show")
	report := flags.String("report", "", "report id")
	user := flags.String("user", "", "user id")
	action := flags.String("action", "", "dismiss, warn or suspend")
	operator := flags.String("operator", "", "who is acting (recorded in the audit trail)")
	note := flags.String("note", "", "reason, recorded with the action")
	if err := flags.Parse(args[1:]); err != nil {
		return errUsage
	}

	switch args[0] {
	case "queue":
		items, err := db.ReportQueue(ctx, *limit)
		if err != nil {
			return err
		}
		if len(items) == 0 {
			fmt.Fprintln(out, "No open reports.")
		}
		for _, q := range items {
			fmt.Fprintf(out, "%s  [%s] %s  %s %s  about @%s (%s, %d earlier reports)\n",
				q.ReportID, strings.ToUpper(q.Severity), q.ReasonCode, q.TargetType, q.TargetID, q.SubjectName, q.Subject, q.PriorReports)
			fmt.Fprintf(out, "    reported %s by %s\n", q.CreatedAt.Format(time.RFC3339), q.Reporter)
			if q.Description != "" {
				fmt.Fprintf(out, "    %q\n", q.Description)
			}
			for _, e := range q.Evidence {
				who := "subject"
				if e.FromMe {
					who = "reporter"
				}
				fmt.Fprintf(out, "    [%s %s] %q\n", e.SentAt.Format(time.RFC3339), who, e.Text)
			}
			// Encrypted images held for this report: identifiers and hashes only. The tool never fetches or
			// decrypts them; the reporter's descriptor stays in the database until a documented process needs it.
			for _, b := range q.Blobs {
				fmt.Fprintf(out, "    held image %s  %s  %d bytes  sha256 %s  (%s)\n", b.BlobID, b.Role, b.SizeBytes, b.CtSha256, b.State)
			}
		}
	case "resolve":
		if *report == "" || *action == "" || *operator == "" {
			return errUsage
		}
		if err := db.ResolveReport(ctx, *report, *operator, *action, *note); err != nil {
			return err
		}
		fmt.Fprintln(out, "Resolved.")
	case "restore":
		if *user == "" || *operator == "" {
			return errUsage
		}
		if err := db.RestoreUser(ctx, *user, *operator, *note); err != nil {
			return err
		}
		fmt.Fprintln(out, "Restored.")
	default:
		return errUsage
	}
	return nil
}

const usageText = `usage:
  moderate queue [-limit 20]
  moderate resolve -report ID -action dismiss|warn|suspend -operator NAME [-note TEXT]
  moderate restore -user ID -operator NAME [-note TEXT]`

func usage() {
	fmt.Fprintln(os.Stderr, usageText)
	os.Exit(2)
}
