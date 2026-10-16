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
#   BACKUP_ALLOW_UNENCRYPTED=1   optional, local testing only. REFUSED (exit 2) unless the database AND the bucket endpoint are
#                           on this machine (the URL's host is exactly localhost, 127.0.0.1 or [::1], or a unix-socket directory; the
#                           endpoint needs an http(s):// scheme) and BACKUP_S3_BUCKET and APP_ENV do not say "prod": anything else,
#                           including look-alikes such as localhost.example.com, is treated as production, where a backup is
#                           never written in clear. scripts/test-backup-db.sh covers the parsing with stub tools.
# Scheduling: see docs/deployment/10-deploy-guide.md section 6 and .github/workflows/backup-example.yml.disabled.
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

# Anything that is not clearly a local test setup counts as production. "Local" is decided by PARSING the URLs, never by
# looking for the word: the host must be exactly localhost, 127.0.0.1 or [::1] (a unix-socket directory is local too).
# So http://localhost.evil.com, http://localhost@evil.com and https://evil.com/localhost are all production.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
url_host() { # URL -> its host (brackets kept for IPv6; empty for an empty authority); fails when it is not a URL
  local authority
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*) ]] || return 1
  authority="${BASH_REMATCH[1]##*@}"
  if [[ "$authority" == \[* ]]; then
    [[ "$authority" =~ ^(\[[0-9A-Fa-f:.]*\])(:[0-9]*)?$ ]] || return 1
  else
    [[ "$authority" =~ ^([A-Za-z0-9._-]*)(:[0-9]*)?$ ]] || return 1
  fi
  printf '%s' "${BASH_REMATCH[1]}"
}
is_local_host() { case "$(lower "$1")" in localhost | 127.0.0.1 | "[::1]") return 0 ;; *) return 1 ;; esac; }
looks_like_production() {
  local host query param bucket_lc
  bucket_lc="$(lower "$BACKUP_S3_BUCKET")"
  if [[ "${APP_ENV:-}" == production || "$bucket_lc" == *prod* ]]; then return 0; fi
  # Database: a postgres URL whose host is local, or an empty host with a host=/socket/dir parameter. A host= or hostaddr=
  # query parameter overrides the authority in libpq, so it is judged too.
  [[ "$BACKUP_DATABASE_URL" =~ ^postgres(ql)?:// ]] || return 0
  host="$(url_host "$BACKUP_DATABASE_URL")" || return 0
  if [[ -n "$host" ]] && ! is_local_host "$host"; then return 0; fi
  query="${BACKUP_DATABASE_URL#*\?}"; [[ "$query" == "$BACKUP_DATABASE_URL" ]] && query=""
  if [[ "$query" =~ (^|&)hostaddr= ]]; then return 0; fi
  if [[ "$query" =~ (^|&)host=([^&]*) ]]; then
    param="${BASH_REMATCH[2]}"
    if [[ "$param" != /* ]] && ! is_local_host "$param"; then return 0; fi
  fi
  # Bucket endpoint: an http(s) URL whose host is local.
  [[ "$BACKUP_S3_ENDPOINT" =~ ^https?:// ]] || return 0
  host="$(url_host "$BACKUP_S3_ENDPOINT")" || return 0
  is_local_host "$host" || return 0
  return 1
}
if [[ "${BACKUP_ALLOW_UNENCRYPTED:-}" == 1 && -z "${BACKUP_AGE_RECIPIENT:-}" && -z "${BACKUP_GPG_RECIPIENT:-}" ]] && looks_like_production; then
  echo "backup-db: BACKUP_ALLOW_UNENCRYPTED=1 is refused here: the database or the bucket does not look like a local test setup (production backups are always encrypted). Set BACKUP_AGE_RECIPIENT or BACKUP_GPG_RECIPIENT." >&2
  exit 2
fi

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
