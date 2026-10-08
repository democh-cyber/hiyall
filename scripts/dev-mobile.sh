#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
cd "$task_root/apps/mobile"
exec flutter run -d web-server --web-hostname 127.0.0.1 --web-port 49321 \
  --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
