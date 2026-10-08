#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
psql -h "$task_root/.runtime/pgsocket" -p 55432 -U kairova -d kairova -q -f "$task_root/scripts/demo-spaces.sql"
