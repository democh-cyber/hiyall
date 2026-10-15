#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
cd "$task_root/apps/mobile"
# Firebase keys from scripts/firebase-setup.sh. The app has no development login:
# without them sign-in is reported as not set up. The API verifies Firebase tokens (see dev-api.sh).
defines=(--dart-define=API_BASE_URL=http://127.0.0.1:8080)
if [[ -f "$task_root/config/firebase.local.json" ]]; then
  defines+=(--dart-define-from-file="$task_root/config/firebase.local.json")
fi
# Served on localhost: Firebase allows sign-in from localhost without extra setup.
exec flutter run -d web-server --web-hostname localhost --web-port 49321 "${defines[@]}" "$@"
