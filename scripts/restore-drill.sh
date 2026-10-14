#!/usr/bin/env bash
# Restore drill: restores a backup made by scripts/backup-db.sh into a SCRATCH database, checks it, times
# it and drops it. Never restores over anything that exists. Run monthly and once before launch
# (docs/deployment/10-deploy-guide.md section 6).
#
# Usage: scripts/restore-drill.sh <dump-file>      a local, already-decrypted .dump, or an .age/.gpg file
#        scripts/restore-drill.sh --latest         downloads the newest dump from the backup bucket
# Needs: pg_restore, psql, createdb/dropdb (or the admin URL), and for --latest aws plus the BACKUP_S3_* env
# of backup-db.sh. Encrypted files need AGE_IDENTITY_FILE (age) or a gpg secret key in the local keyring.
#
# Environment:
#   DRILL_ADMIN_URL   connection string to a scratch Postgres server (database "postgres"), with rights to
#                     create and drop databases. It must NOT be the production server.
#   DRILL_DB          optional, default restore_drill_<timestamp>; must start with "restore_drill"
set -euo pipefail
: "${DRILL_ADMIN_URL:?set DRILL_ADMIN_URL to a scratch Postgres server (never production)}"
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
start=$SECONDS
work="$(mktemp -d)"; umask 077
db="${DRILL_DB:-restore_drill_$(date -u +%Y%m%d%H%M%S)}"
[[ "$db" == restore_drill* ]] || { echo "restore-drill: DRILL_DB must start with restore_drill" >&2; exit 2; }
cleanup() { psql "$DRILL_ADMIN_URL" -X -q -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

[[ $# -eq 1 ]] || { sed -n 2,12p "$0"; exit 2; }
src="$1"
if [[ "$src" == --latest ]]; then
  : "${BACKUP_S3_BUCKET:?}" "${BACKUP_S3_ENDPOINT:?}"
  prefix="${BACKUP_PREFIX:-hiyall/db}"
  key="$(aws s3 ls --endpoint-url "$BACKUP_S3_ENDPOINT" "s3://$BACKUP_S3_BUCKET/$prefix/" | awk '{print $4}' | grep -E '^hiyall-.*\.dump(\.age|\.gpg)?$' | sort | tail -1)"
  [[ -n "$key" ]] || { echo "restore-drill: no dump found in the bucket" >&2; exit 1; }
  aws s3 cp --only-show-errors --endpoint-url "$BACKUP_S3_ENDPOINT" "s3://$BACKUP_S3_BUCKET/$prefix/$key" "$work/$key"
  src="$work/$key"; echo "restore-drill: downloaded $key"
fi

case "$src" in
  *.age) : "${AGE_IDENTITY_FILE:?set AGE_IDENTITY_FILE}"; age -d -i "$AGE_IDENTITY_FILE" -o "$work/db.dump" "$src" ;;
  *.gpg) gpg --batch --yes --decrypt --output "$work/db.dump" "$src" ;;
  *) cp "$src" "$work/db.dump" ;;
esac

psql "$DRILL_ADMIN_URL" -X -q -c "CREATE DATABASE \"$db\""
# The URL for the scratch database: swap the database name in the admin URL (works for URLs ending /postgres[?...]).
scratch_url="$(printf '%s' "$DRILL_ADMIN_URL" | sed -E "s#/postgres(\\?|\$)#/$db\\1#")"
[[ "$scratch_url" != "$DRILL_ADMIN_URL" ]] || { echo "restore-drill: DRILL_ADMIN_URL must end in /postgres" >&2; exit 2; }
t0=$SECONDS
pg_restore --no-owner --no-acl --exit-on-error --dbname "$scratch_url" "$work/db.dump"
echo "restore-drill: pg_restore took $((SECONDS - t0))s"

q() { psql "$scratch_url" -X -At -c "$1"; }
applied="$(q 'SELECT count(*) FROM schema_migrations')"
shipped="$(ls "$task_root"/database/migrations/*.sql | wc -l | tr -d ' ')"
echo "restore-drill: migrations applied $applied, shipped in this checkout $shipped"
for t in users messages conversations deleted_users; do echo "restore-drill: $t rows: $(q "SELECT count(*) FROM $t")"; done
echo "restore-drill: users not yet purged but listed in deleted_users (must be 0 after replay-deletions): $(q "SELECT count(*) FROM users u JOIN deleted_users d USING(user_id) WHERE u.status<>'deleted'")"
[[ "$applied" -le "$shipped" ]] || { echo "restore-drill: FAIL database is ahead of this checkout" >&2; exit 1; }
echo "restore-drill: OK in $((SECONDS - start))s. Compare the counts with production, record the time and date in your ops log."
