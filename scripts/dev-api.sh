#!/usr/bin/env bash
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
export DATABASE_URL="postgresql://hiyall@/hiyall?host=$task_root/.runtime/pgsocket&port=55432&sslmode=disable"
export APP_ENV=development LISTEN_ADDR=127.0.0.1:8080
# Sign-in: the project from scripts/firebase-setup.sh when it has been run, otherwise the
# local fixture accounts. The API verifies one or the other, never both; set
# HIYALL_DEV_LOGIN=1 to use the fixture accounts even when Firebase is configured.
firebase_config="$task_root/config/firebase.local.json"
if [[ -z "${FIREBASE_PROJECT_ID:-}" && -z "${HIYALL_DEV_LOGIN:-}" && -f "$firebase_config" ]]; then
  FIREBASE_PROJECT_ID="$(node -p 'require(process.argv[1]).FIREBASE_PROJECT_ID' "$firebase_config")"
fi
if [[ -n "${FIREBASE_PROJECT_ID:-}" && -z "${HIYALL_DEV_LOGIN:-}" ]]; then
  export FIREBASE_PROJECT_ID
  # Browser requests are only accepted from this origin when dev auth is off (see dev-mobile.sh).
  export WEB_ORIGIN="${WEB_ORIGIN:-http://localhost:49321}"
  echo "Sign-in: Firebase project $FIREBASE_PROJECT_ID (HIYALL_DEV_LOGIN=1 for the fixture accounts)"
else
  unset FIREBASE_PROJECT_ID
  export ENABLE_DEV_AUTH=true
  echo "Sign-in: local fixture accounts"
fi
# Photos: config/media.local.env (Cloudflare R2, see config/media.example.env) wins;
# otherwise local storage from scripts/dev-storage.sh when it is listening.
media_env="$task_root/config/media.local.env"
if [[ -f "$media_env" ]]; then
  set -a
  source "$media_env"
  set +a
  if [[ -z "${MEDIA_ACCESS_KEY:-}" || -z "${MEDIA_SECRET_KEY:-}" ]]; then
    echo "Photos: off (fill MEDIA_ACCESS_KEY and MEDIA_SECRET_KEY in config/media.local.env)"
    unset MEDIA_ENDPOINT MEDIA_BUCKET MEDIA_ACCESS_KEY MEDIA_SECRET_KEY MEDIA_REGION MEDIA_SECURE
  else
    echo "Photos: bucket ${MEDIA_BUCKET:-?} at ${MEDIA_ENDPOINT:-?}"
  fi
elif [[ -f "$task_root/.runtime/storage/credentials" ]] && (exec 3<>/dev/tcp/127.0.0.1/8333) 2>/dev/null; then
  set -a
  source "$task_root/.runtime/storage/credentials"
  set +a
  export MEDIA_ENDPOINT=127.0.0.1:8333 MEDIA_BUCKET=hiyall-media
fi
# Encrypted chat photos: config/chat-media.local.env (a second R2 bucket with its own token, see
# config/chat-media.example.env). Without it sending photos in chats answers 503 CHAT_MEDIA_UNAVAILABLE.
chat_media_env="$task_root/config/chat-media.local.env"
if [[ -f "$chat_media_env" ]]; then
  set -a
  source "$chat_media_env"
  set +a
  if [[ -z "${CHAT_MEDIA_ACCESS_KEY:-}" || -z "${CHAT_MEDIA_SECRET_KEY:-}" ]]; then
    echo "Chat photos: off (fill CHAT_MEDIA_ACCESS_KEY and CHAT_MEDIA_SECRET_KEY in config/chat-media.local.env)"
    unset CHAT_MEDIA_ENDPOINT CHAT_MEDIA_BUCKET CHAT_MEDIA_ACCESS_KEY CHAT_MEDIA_SECRET_KEY CHAT_MEDIA_REGION CHAT_MEDIA_SECURE
  else
    echo "Chat photos: bucket ${CHAT_MEDIA_BUCKET:-?} at ${CHAT_MEDIA_ENDPOINT:-?}"
  fi
else
  echo "Chat photos: off (copy config/chat-media.example.env to config/chat-media.local.env)"
fi
cd "$task_root/services/api"
go run ./cmd/migrate
exec go run ./cmd/api
