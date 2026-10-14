#!/usr/bin/env bash
# Logical backup of the production database to a SEPARATE bucket (different account or provider from the
# primary data and the managed database's own backups). Meant for a scheduled job you control (cron, a
# CI schedule, a Fly scheduled machine). It is the independent copy described in
# docs/deployment/10-deploy-guide.md section 6; it does not replace provider PITR.
#
# Needs on PATH: pg_dump (version >= the server's), psql, aws (AWS CLI v2, used for any S3-compatible bucket
# including R2) and either age or gpg. Nothing is ever written unencrypted to the bucket.
#
# Environment (all required unless marked optional):
#   BACKUP_DATABASE_URL     read-only connection string to the database to dump (a role with SELECT only)
#   BACKUP_S3_BUCKET        destination bucket, for example hiyall-backups
#   BACKUP_S3_ENDPOINT      S3 endpoint URL, for example https://<ACCOUNT_ID>.r2.cloudflarestorage.com
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   a token limited to the backup bucket, write + list only
#   BACKUP_AGE_RECIPIENT    an age public key (age1...) OR
#   BACKUP_GPG_RECIPIENT    a gpg key id/email already imported on this machine
#   BACKUP_PREFIX           optional, default "hiyall/db"
#   BACKUP_ALLOW_UNENCRYPTED=1   optional, local testing only; refused when the bucket is set to production
# The private key (age identity or gpg secret key) must NOT live on the machine that runs this script.
set -euo pipefail

: "${BACKUP_DATABASE_URL:?set BACKUP_DATABASE_URL}"
: "${BACKUP_S3_BUCKET:?set BACKUP_S3_BUCKET}"
: "${BACKUP_S3_ENDPOINT:?set BACKUP_S3_ENDPOINT}"
prefix="${BACKUP_PREFIX:-hiyall/db}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077

for tool in pg_dump psql aws; do
  command -v "$tool" >/dev/null || { echo "backup-db: $tool is not installed" >&2; exit 2; }
done

encrypt() { # stdin -> stdout, and the file suffix on fd 3 is decided by the caller
  if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
    age -r "$BACKUP_AGE_RECIPIENT"
  elif [[ -n "${BACKUP_GPG_RECIPIENT:-}" ]]; then
    gpg --batch --yes --trust-model always --encrypt --recipient "$BACKUP_GPG_RECIPIENT"
  elif [[ "${BACKUP_ALLOW_UNENCRYPTED:-}" == 1 ]]; then
    cat
  else
    echo "backup-db: set BACKUP_AGE_RECIPIENT or BACKUP_GPG_RECIPIENT (a backup is never uploaded in clear)" >&2
    exit 2
  fi
}
if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then suffix=".age"; command -v age >/dev/null || { echo "backup-db: age is not installed" >&2; exit 2; }
elif [[ -n "${BACKUP_GPG_RECIPIENT:-}" ]]; then suffix=".gpg"; command -v gpg >/dev/null || { echo "backup-db: gpg is not installed" >&2; exit 2; }
else suffix=""; fi

dump="$work/hiyall-$stamp.dump$suffix"
# Custom format is compressed and lets pg_restore pick parts; --no-owner/--no-acl because the restore
# target has its own roles.
pg_dump --format=custom --no-owner --no-acl "$BACKUP_DATABASE_URL" | encrypt > "$dump"
test -s "$dump"

# The deletion ledger: ids of accounts already purged, as a tiny separate object, so a restore can re-apply
# every deletion made after the dump (scripts/replay-deletions.sh --ledger-file).
ledger="$work/deleted_users-$stamp.csv$suffix"
psql "$BACKUP_DATABASE_URL" -X -q -c "\\copy (SELECT user_id, deleted_at FROM deleted_users ORDER BY deleted_at, user_id) TO STDOUT WITH CSV HEADER" | encrypt > "$ledger"

upload() { aws s3 cp --only-show-errors --endpoint-url "$BACKUP_S3_ENDPOINT" "$1" "s3://$BACKUP_S3_BUCKET/$prefix/$2"; }
upload "$dump" "$(basename "$dump")"
upload "$ledger" "$(basename "$ledger")"
echo "backup-db: uploaded $(basename "$dump") ($(wc -c < "$dump" | tr -d ' ') bytes) and $(basename "$ledger") to s3://$BACKUP_S3_BUCKET/$prefix/"
echo "backup-db: retention is the bucket's lifecycle rule (keep 14 days or more); this script never deletes."
