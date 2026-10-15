#!/usr/bin/env bash
# Makes some demo_ people look online or recently active in the LOCAL development database, so Discover, Nearby
# and the Chats list show green dots and a conversation header can say "last seen ...".
#
#   ./scripts/seed-demo-presence.sh                    adult demo_ people only
#   ./scripts/seed-demo-presence.sh --also anjali,niko also those accounts (they get a tagged demo session row)
#   ./scripts/seed-demo-presence.sh --keep             repeat every 45 seconds until Ctrl-C, so "online" stays online
#
# "Online" is session activity within the last 2 minutes, so without --keep the dots fade after about two minutes;
# just run it again. Safe to re-run. Touches only the local `hiyall` database (set DEMO_DB=hiyall_test to dry-run
# against the test database). Run ./scripts/dev-api.sh and ./scripts/seed-demo-people.sh first.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"

extra=""
keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --also) extra="${2:-}"; shift 2 ;;
    --keep) keep=1; shift ;;
    *) echo "usage: $0 [--also USERNAME,USERNAME] [--keep]" >&2; exit 2 ;;
  esac
done
if ! [[ "$extra" =~ ^[a-z0-9_,]*$ ]]; then
  echo "--also takes comma separated usernames (letters, digits, underscore)" >&2
  exit 2
fi
database="${DEMO_DB:-hiyall}"
if [[ "$database" != "hiyall" && "$database" != "hiyall_test" ]]; then
  echo "DEMO_DB must be hiyall or hiyall_test" >&2
  exit 2
fi
db=(psql -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall -d "$database")
run() { "${db[@]}" -q -v extra="$extra" -f "$task_root/scripts/demo-presence.sql"; }
run
while [[ "$keep" == 1 ]]; do
  sleep 45
  run >/dev/null
done
