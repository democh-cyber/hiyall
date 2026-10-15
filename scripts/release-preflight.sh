#!/usr/bin/env bash
# The V1 release gate: lists EVERY unmet release requirement with a one-line fix and exits non-zero while any
# remains. It only gates (no builds, no deploys, no test suites; scripts/check.sh runs those).
#
#   scripts/release-preflight.sh            run all gates
#   PREFLIGHT_SKIP=d scripts/release-preflight.sh   skip gates on purpose (printed as SKIPPED)
#
# The gates and the environment variables that steer them are documented at the top of
# scripts/release_preflight.py and in docs/deployment/12-release-runbook.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "release-preflight: python3 is required" >&2
  exit 2
fi
cd "$root"
exec python3 -I "$root/scripts/release_preflight.py" "$@"
