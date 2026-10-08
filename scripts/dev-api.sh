#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
mkdir -p "$task_root/.runtime/pgsocket"
chmod 700 "$task_root/.runtime/pgsocket"
if [[ ! -f "$task_root/.runtime/postgres/PG_VERSION" ]]; then
  initdb -D "$task_root/.runtime/postgres" -U kairova --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --locale=C.UTF-8
fi
if ! pg_ctl -D "$task_root/.runtime/postgres" status >/dev/null; then
  pg_ctl -D "$task_root/.runtime/postgres" -l "$task_root/.runtime/postgres.log" -o "-h 127.0.0.1 -p 55432 -k $task_root/.runtime/pgsocket" start
fi
if ! psql -h "$task_root/.runtime/pgsocket" -p 55432 -U kairova -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='kairova'" | grep -q '^1$'; then
  createdb -h "$task_root/.runtime/pgsocket" -p 55432 -U kairova kairova
fi
export DATABASE_URL="postgresql://kairova@/kairova?host=$task_root/.runtime/pgsocket&port=55432&sslmode=disable"
export APP_ENV=development ENABLE_DEV_AUTH=true LISTEN_ADDR=127.0.0.1:8080
# Photos: use local storage when scripts/dev-storage.sh has been started.
if [[ -f "$task_root/.runtime/storage/credentials" ]]; then
  set -a
  source "$task_root/.runtime/storage/credentials"
  set +a
  export MEDIA_ENDPOINT=127.0.0.1:8333 MEDIA_BUCKET=kairova-media
fi
cd "$task_root/services/api"
go run ./cmd/migrate
exec go run ./cmd/api
