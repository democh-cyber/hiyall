#!/usr/bin/env bash
# Checks that scripts/build-release.sh refuses incomplete configurations and accepts a complete one.
# Uses --check, so nothing is built. Run: scripts/test-build-release.sh
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/build-release.sh"
fail=0
good=(
  API_BASE_URL=https://api.hiyall.example.com FIREBASE_PROJECT_ID=p FIREBASE_MESSAGING_SENDER_ID=1 FIREBASE_API_KEY=k
  FIREBASE_ANDROID_APP_ID=1:1:android:a FIREBASE_IOS_APP_ID=1:1:ios:a FIREBASE_WEB_APP_ID=1:1:web:a FIREBASE_AUTH_DOMAIN=p.firebaseapp.com
  SUPPORT_EMAIL=help@hiyall.app SAFETY_EMAIL=safety@hiyall.app PRIVACY_EMAIL=privacy@hiyall.app
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=7 SENTRY_DSN=https://k@s.example/1 HIYALL_RELEASE_ENV=nonexistent
)
run() { env -i PATH="$PATH" HOME="$HOME" "${good[@]}" "$@" "$script" "${PLATFORM:-android}" --check 2>&1; }
expect() { # name, want (ok|fail), grep pattern, then env overrides
  local name="$1" want="$2" pattern="$3"; shift 3
  local out status
  out="$(run "$@")"; status=$?
  if [[ "$want" == ok && $status -ne 0 ]] || [[ "$want" == fail && $status -eq 0 ]] || ! grep -q -- "$pattern" <<<"$out"; then
    echo "FAIL: $name (status $status)"; echo "$out" | sed 's/^/    /'; fail=1
  else echo "ok: $name"; fi
}
expect "complete android config" ok "flutter build appbundle.*--dart-define-from-file.*--obfuscate --split-debug-info=build/symbols"
PLATFORM=ios expect "complete ios config" ok "flutter build ipa.*--obfuscate"
PLATFORM=web expect "complete web config" ok "flutter build web"
expect "http API refused" fail "must start with https" API_BASE_URL=http://api.example.com
expect "localhost API refused" fail "points at this machine" API_BASE_URL=https://localhost
expect "missing API refused" fail "API_BASE_URL is not set" API_BASE_URL=
expect "missing Firebase project refused" fail "FIREBASE_PROJECT_ID is not set" FIREBASE_PROJECT_ID=
expect "missing platform app id refused" fail "Firebase android app id" FIREBASE_ANDROID_APP_ID=
expect "missing build number refused" fail "APP_BUILD_NUMBER" APP_BUILD_NUMBER=
expect "bad version refused" fail "MAJOR.MINOR.PATCH" APP_VERSION=1.2
expect "placeholder contact refused" fail "SUPPORT_EMAIL" SUPPORT_EMAIL=support@hiyall.example
expect "placeholder contact allowed by override" ok "placeholder" SUPPORT_EMAIL=support@hiyall.example ALLOW_PLACEHOLDER_CONTACTS=1
expect "missing Sentry only warns" ok "NO crash or error reporting" SENTRY_DSN=
expect "dev login refused" fail "ENABLE_DEV_LOGIN" ENABLE_DEV_LOGIN=true
exit $fail
