#!/usr/bin/env bash
# Tests scripts/backup-db.sh with stub pg_dump, psql and aws (nothing is dumped or uploaded). The point is the production
# test: BACKUP_ALLOW_UNENCRYPTED=1 must be refused (exit 2) for every database or endpoint that is not exactly local, and
# accepted for the real local forms. Run: scripts/test-backup-db.sh
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/backup-db.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho dump-bytes\n' > "$tmp/bin/pg_dump"
printf '#!/bin/sh\necho "user_id,deleted_at"\n' > "$tmp/bin/psql"
printf '#!/bin/sh\necho "$@" >> "%s/aws.log"\n' "$tmp" > "$tmp/bin/aws"
chmod +x "$tmp/bin/"*
fail=0
base=(BACKUP_S3_BUCKET=scratch BACKUP_ALLOW_UNENCRYPTED=1)
run() { env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$HOME" "${base[@]}" "$@" "$script" 2>&1; }
expect() { # name, want status, then env assignments
  local name="$1" want="$2"; shift 2
  local out status; rm -f "$tmp/aws.log"
  out="$(run "$@")"; status=$?
  if [[ $status -ne $want ]]; then echo "FAIL: $name (status $status, wanted $want)"; echo "$out" | sed 's/^/    /'; fail=1
  elif [[ $want -eq 2 && ! -f "$tmp/aws.log" && "$out" == *"refused here"* ]]; then echo "ok: $name"
  elif [[ $want -eq 0 && -f "$tmp/aws.log" ]]; then echo "ok: $name"
  else echo "FAIL: $name (status $status, unexpected effect)"; echo "$out" | sed 's/^/    /'; fail=1; fi
}
local_db=postgresql://backup@localhost:5432/hiyall
local_ep=http://127.0.0.1:9000

# Local forms are accepted (and the stub upload runs).
expect "localhost database and 127.0.0.1 endpoint" 0 BACKUP_DATABASE_URL=$local_db BACKUP_S3_ENDPOINT=$local_ep
expect "unix socket database" 0 "BACKUP_DATABASE_URL=postgresql:///hiyall?host=/tmp/pgsock" BACKUP_S3_ENDPOINT=http://localhost:9000/
expect "IPv6 loopback database and endpoint" 0 "BACKUP_DATABASE_URL=postgresql://[::1]:5432/hiyall" "BACKUP_S3_ENDPOINT=http://[::1]:9000"
expect "upper-case LOCALHOST" 0 BACKUP_DATABASE_URL=postgres://LOCALHOST/hiyall BACKUP_S3_ENDPOINT=http://LocalHost:9000

# Look-alike endpoints are production.
for ep in http://localhost.evil.com:9000 http://127.0.0.1.evil.com http://localhost@evil.com https://evil.com/localhost \
          'https://evil.com/?x=127.0.0.1' localhost:9000 127.0.0.1:9000 'http://[::1]@evil.com' ftp-less-localhost \
          https://acct.r2.cloudflarestorage.com 'http://localhost:9000@evil.com'; do
  expect "endpoint $ep is production" 2 BACKUP_DATABASE_URL=$local_db "BACKUP_S3_ENDPOINT=$ep"
done
# Look-alike databases are production.
for db in postgresql://u@evil.com/db postgresql://localhost@evil.com/db postgresql://u@localhost.evil.com/db \
          'postgresql:///db?host=evil.com' 'postgresql://localhost/db?host=evil.com' 'postgresql://localhost/db?hostaddr=10.0.0.5' \
          'postgresql://localhost,evil.com/db' 'host=localhost dbname=x' 'postgresql://u@db.internal:5432/x'; do
  expect "database $db is production" 2 "BACKUP_DATABASE_URL=$db" BACKUP_S3_ENDPOINT=$local_ep
done
# Naming alone makes it production.
expect "bucket named prod" 2 BACKUP_DATABASE_URL=$local_db BACKUP_S3_ENDPOINT=$local_ep BACKUP_S3_BUCKET=hiyall-prod-backups
expect "APP_ENV=production" 2 BACKUP_DATABASE_URL=$local_db BACKUP_S3_ENDPOINT=$local_ep APP_ENV=production
# Without the override a missing recipient is refused too.
out="$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$HOME" BACKUP_S3_BUCKET=scratch BACKUP_DATABASE_URL=$local_db BACKUP_S3_ENDPOINT=$local_ep "$script" 2>&1)"; status=$?
if [[ $status -eq 2 && "$out" == *"BACKUP_AGE_RECIPIENT"* ]]; then echo "ok: no recipient and no override is refused"; else echo "FAIL: no recipient (status $status)"; echo "$out" | sed 's/^/    /'; fail=1; fi
exit $fail
