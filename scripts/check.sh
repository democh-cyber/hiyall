#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
cd "$task_root"
python3 scripts/validate_architecture.py
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
cd "$task_root/apps/mobile/rust"
cargo test --quiet
cd "$task_root/apps/mobile"
flutter analyze
flutter test --dart-define=ENABLE_DEV_LOGIN=true --dart-define=API_BASE_URL=http://127.0.0.1:8080
