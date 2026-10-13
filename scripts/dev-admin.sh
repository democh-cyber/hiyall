#!/usr/bin/env bash
# Starts the moderation console for development: migrates the dev database, builds apps/admin and runs
# services/api/cmd/admin on 127.0.0.1:8081 (loopback only; see docs/security/15-admin-console.md).
#
# Staff accounts are created separately, once, with a password prompt:
#   scripts/dev-admin.sh operator-add -email you@example.com -role admin
# (any arguments are passed to the admin binary instead of starting the server).
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
mkdir -p "$task_root/.runtime/pgsocket"
chmod 700 "$task_root/.runtime/pgsocket"
if [[ ! -f "$task_root/.runtime/postgres/PG_VERSION" ]]; then
  initdb -D "$task_root/.runtime/postgres" -U hiyall --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --locale=C.UTF-8
fi
if ! pg_ctl -D "$task_root/.runtime/postgres" status >/dev/null; then
  pg_ctl -D "$task_root/.runtime/postgres" -l "$task_root/.runtime/postgres.log" -o "-h 127.0.0.1 -p 55432 -k $task_root/.runtime/pgsocket" start
fi
if ! psql -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='hiyall'" | grep -q '^1$'; then
  createdb -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall hiyall
fi
export DATABASE_URL="${DATABASE_URL:-postgresql://hiyall@/hiyall?host=$task_root/.runtime/pgsocket&port=55432&sslmode=disable}"
export APP_ENV=development
export ADMIN_ADDR="${ADMIN_ADDR:-127.0.0.1:8081}"

# The data key seals the staff authenticator secrets in the database. It is generated once, kept outside
# git (.runtime/ is ignored) and readable only by you. Losing it means every operator must be re-enrolled
# with `admin operator-reset`.
key_file="$task_root/.runtime/admin-data.key"
if [[ -z "${ADMIN_DATA_KEY:-}" && -z "${ADMIN_DATA_KEY_FILE:-}" ]]; then
  if [[ ! -f "$key_file" ]]; then
    (umask 077 && openssl rand -base64 32 > "$key_file")
    echo "Created $key_file"
  fi
  export ADMIN_DATA_KEY_FILE="$key_file"
fi

cd "$task_root/services/api"
go run ./cmd/migrate

# Operator commands (operator-add and friends) do not need the console built or running.
if [[ $# -gt 0 ]]; then
  exec go run ./cmd/admin "$@"
fi

if [[ ! -d "$task_root/apps/admin/node_modules" ]]; then
  npm --prefix "$task_root/apps/admin" ci
fi
npm --prefix "$task_root/apps/admin" run build
export ADMIN_STATIC_DIR="${ADMIN_STATIC_DIR:-$task_root/apps/admin/dist}"
echo "Admin console: http://$ADMIN_ADDR  (staff sign-in with password and authenticator code)"
exec go run ./cmd/admin
