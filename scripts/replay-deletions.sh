#!/usr/bin/env bash
# After restoring a backup, re-apply the account deletions that happened AFTER the backup was taken, so a
# restore never brings a deleted person back (docs/legal/data-retention.md promises this).
#
# Source of the list of purged accounts (the ledger), one of:
#   PROD_DATABASE_URL   the live production database, if it is still readable (read only: one SELECT)
#   --ledger-file FILE  a deleted_users CSV written by scripts/backup-db.sh (decrypt it first); this is
#                       the only source when production is gone, and it is as old as the last backup run
# Target: RESTORED_DATABASE_URL, the restored database BEFORE it serves traffic.
#
# What it does NOT do: it does not purge. It marks those accounts as due for deletion in the restored
# database (status pending_deletion, due now). The API's own purge job then does the real work (content,
# media objects, Firebase identity) when you start the API against the restored database; the same code
# path as a normal deletion, so nothing here duplicates the deletion rules. Do not let the restored API
# take user traffic until `--verify` reports zero outstanding.
#
# Usage: scripts/replay-deletions.sh                 apply (needs PROD_DATABASE_URL or --ledger-file)
#        scripts/replay-deletions.sh --verify        report accounts still not purged; exit 1 if any
set -euo pipefail
: "${RESTORED_DATABASE_URL:?set RESTORED_DATABASE_URL (the restored database)}"
mode=apply; ledger_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) mode=verify ;;
    --ledger-file) ledger_file="${2:?--ledger-file needs a path}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "${PROD_DATABASE_URL:-}" && "$PROD_DATABASE_URL" == "$RESTORED_DATABASE_URL" ]]; then
  echo "replay-deletions: PROD_DATABASE_URL and RESTORED_DATABASE_URL are the same" >&2; exit 2
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; umask 077
ids="$work/ids.txt"

if [[ -n "$ledger_file" ]]; then
  # CSV with header: user_id,deleted_at
  tail -n +2 "$ledger_file" | cut -d, -f1 | tr -d '"' | grep -E '^[0-9a-f-]{36}$' > "$ids" || true
else
  : "${PROD_DATABASE_URL:?set PROD_DATABASE_URL or pass --ledger-file}"
  psql "$PROD_DATABASE_URL" -X -At -c "SELECT user_id FROM deleted_users ORDER BY deleted_at" > "$ids"
fi
echo "replay-deletions: ledger has $(wc -l < "$ids" | tr -d ' ') purged accounts"

R() { psql "$RESTORED_DATABASE_URL" -X -v ON_ERROR_STOP=1 "$@"; }
R() { psql "$RESTORED_DATABASE_URL" -X -v ON_ERROR_STOP=1 "$@"; }

if [[ "$mode" == apply ]]; then
  R -At <<SQL | grep '^replay-deletions' || true
CREATE TEMP TABLE ledger(user_id uuid PRIMARY KEY);
\\copy ledger FROM '$ids'
WITH changed AS (
  UPDATE users u SET status='pending_deletion', deletion_scheduled_at=now(), deletion_due_at=now()
  FROM ledger l WHERE u.user_id=l.user_id AND u.status NOT IN ('deleted','deleting')
  RETURNING u.user_id)
SELECT 'replay-deletions: marked due for purge: ' || count(*) FROM changed;
-- ids the restored database already knows as purged are left alone; ids it never had need nothing.
INSERT INTO deleted_users(user_id) SELECT user_id FROM ledger WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.user_id=ledger.user_id) ON CONFLICT DO NOTHING;
SQL
  echo "replay-deletions: now start the API against the restored database (no user traffic), wait for the hourly purge job or restart it, then run: $0 --verify"
else
  out="$(R -At <<SQL
CREATE TEMP TABLE ledger(user_id uuid PRIMARY KEY);
\\copy ledger FROM '$ids'
SELECT count(*) FROM users u JOIN ledger l USING(user_id) WHERE u.status<>'deleted';
SQL
)"
  n="$(printf '%s\n' "$out" | tail -1)"
  echo "replay-deletions: accounts in the ledger not yet purged here: $n"
  [[ "$n" == 0 ]]
fi
