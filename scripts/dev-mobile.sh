#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
cd "$task_root/apps/mobile"
# Firebase keys from scripts/firebase-setup.sh, when it has been run. Then the API verifies
# Firebase tokens (see dev-api.sh) and the fixture accounts are hidden, unless
# HIYALL_DEV_LOGIN=1 is set for both scripts.
defines=(--dart-define=API_BASE_URL=http://127.0.0.1:8080)
if [[ -f "$task_root/config/firebase.local.json" && -z "${HIYALL_DEV_LOGIN:-}" ]]; then
  defines+=(--dart-define-from-file="$task_root/config/firebase.local.json")
else
  defines+=(--dart-define=ENABLE_DEV_LOGIN=true)
fi
# Served on localhost: Firebase allows sign-in from localhost without extra setup.
exec flutter run -d web-server --web-hostname localhost --web-port 49321 "${defines[@]}" "$@"
