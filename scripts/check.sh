#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
cd "$task_root"
python3 scripts/validate_architecture.py
# Release tooling: the preflight's unit tests, the build script's refusals, env docs vs the Go code, the alert rules.
python3 scripts/test-release-preflight.py
scripts/test-build-release.sh
python3 scripts/check_env_docs.py
scripts/validate-alerts.sh
npm run contracts:lint
python3 scripts/build_foundation_contract.py
npm run contracts:build
# A dedicated, disposable database is required; silently skipped integration tests are not a full check.
export TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgresql://hiyall@/hiyall_test?host=$task_root/.runtime/pgsocket&port=55432&sslmode=disable}"
cd "$task_root/services/api"
export DATABASE_URL="$TEST_DATABASE_URL"
go run ./cmd/migrate
go vet ./...
go test -race ./...
if command -v govulncheck >/dev/null; then govulncheck ./...; fi
# Admin console (apps/admin): typecheck, tests and build, only when its dependencies are installed
# (run `npm --prefix apps/admin ci` once; this script stays runnable offline and never installs them).
if [[ -d "$task_root/apps/admin/node_modules" ]]; then
  npm --prefix "$task_root/apps/admin" run typecheck
  npm --prefix "$task_root/apps/admin" test
  npm --prefix "$task_root/apps/admin" run build
else
  echo "check.sh: apps/admin/node_modules missing, skipping the admin console checks (npm --prefix apps/admin ci)"
fi
cd "$task_root/apps/mobile/rust"
cargo test --quiet
# The real-Olm interop tests load the debug build of the Rust core; build it so they run, not skip.
cargo build --quiet
cd "$task_root/apps/mobile"
dart format --set-exit-if-changed lib test
flutter analyze
REQUIRE_RUST_CORE=1 flutter test --dart-define=API_BASE_URL=http://127.0.0.1:8080
