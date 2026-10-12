// Command moderate is the trust-and-safety operator tool until the separate
// admin console exists. It reads DATABASE_URL and never touches chat
// ciphertext: the only message text it shows is what reporters chose to share. Encrypted images held
// as evidence are listed by blob id, size and SHA-256 only; nothing is fetched or decrypted.
//
//	moderate queue [-limit 20]
//	moderate resolve -report ID -action dismiss|warn|suspend -operator NAME [-note TEXT]
//	moderate restore -user ID -operator NAME [-note TEXT]
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"hiyall/services/api/internal/store"
)

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
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	limit := flags.Int("limit", 20, "reports to show")
	report := flags.String("report", "", "report id")
	user := flags.String("user", "", "user id")
	action := flags.String("action", "", "dismiss, warn or suspend")
	operator := flags.String("operator", "", "who is acting (recorded in the audit trail)")
	note := flags.String("note", "", "reason, recorded with the action")
	_ = flags.Parse(os.Args[2:])

	switch os.Args[1] {
	case "queue":
		items, err := db.ReportQueue(ctx, *limit)
		if err != nil {
			log.Fatal(err)
		}
		if len(items) == 0 {
			fmt.Println("No open reports.")
		}
		for _, q := range items {
			fmt.Printf("%s  [%s] %s  %s %s  about @%s (%s, %d earlier reports)\n",
				q.ReportID, strings.ToUpper(q.Severity), q.ReasonCode, q.TargetType, q.TargetID, q.SubjectName, q.Subject, q.PriorReports)
			fmt.Printf("    reported %s by %s\n", q.CreatedAt.Format(time.RFC3339), q.Reporter)
			if q.Description != "" {
				fmt.Printf("    %q\n", q.Description)
			}
			for _, e := range q.Evidence {
				who := "subject"
				if e.FromMe {
					who = "reporter"
				}
				fmt.Printf("    [%s %s] %q\n", e.SentAt.Format(time.RFC3339), who, e.Text)
			}
			// Encrypted images held for this report: identifiers and hashes only. The tool never fetches or
			// decrypts them; the reporter's descriptor stays in the database until a documented process needs it.
			for _, b := range q.Blobs {
				fmt.Printf("    held image %s  %s  %d bytes  sha256 %s  (%s)\n", b.BlobID, b.Role, b.SizeBytes, b.CtSha256, b.State)
			}
		}
	case "resolve":
		require(*report != "" && *action != "" && *operator != "")
		if err := db.ResolveReport(ctx, *report, *operator, *action, *note); err != nil {
			log.Fatal(err)
		}
		fmt.Println("Resolved.")
	case "restore":
		require(*user != "" && *operator != "")
		if err := db.RestoreUser(ctx, *user, *operator, *note); err != nil {
			log.Fatal(err)
		}
		fmt.Println("Restored.")
	default:
		usage()
	}
}

func require(ok bool) {
	if !ok {
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  moderate queue [-limit 20]
  moderate resolve -report ID -action dismiss|warn|suspend -operator NAME [-note TEXT]
  moderate restore -user ID -operator NAME [-note TEXT]`)
	os.Exit(2)
}
