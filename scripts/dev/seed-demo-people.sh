#!/usr/bin/env bash
# Adds 16 demo people to the LOCAL development database so Discover has results.
# Safe to re-run. Run ./scripts/dev-api.sh once first so the database exists.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$task_root/scripts/env.sh"
psql -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall -d hiyall -q -f "$task_root/scripts/dev/demo-people.sql"
