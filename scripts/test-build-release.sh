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
  WEB_CANONICAL_URL=https://app.hiyall.example.com/ APP_VERSION=1.2.3 APP_BUILD_NUMBER=7 SENTRY_DSN=https://k@s.example/1 HIYALL_RELEASE_ENV=nonexistent
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
PLATFORM=ios expect "ios with team and profile signs manually" ok "manual signing, team ABCDE12345" IOS_TEAM_ID=ABCDE12345 IOS_PROFILE_NAME=Hiyall-AppStore
PLATFORM=ios expect "manual ios signing writes the Runner-only xcconfig, not the project file" ok "write ios/Flutter/Signing.xcconfig (Runner target only)" IOS_TEAM_ID=ABCDE12345 IOS_PROFILE_NAME=Hiyall-AppStore
PLATFORM=ios expect "bad team id refused" fail "10-character Apple team id" IOS_TEAM_ID=abc IOS_PROFILE_NAME=Hiyall-AppStore
PLATFORM=ios expect "profile name that an xcconfig cannot hold is refused" fail "cannot hold" IOS_TEAM_ID=ABCDE12345 'IOS_PROFILE_NAME=a//b'
PLATFORM=ios expect "ios no-codesign build for the dry run" ok "flutter build ios.*--no-codesign" HIYALL_IOS_NO_CODESIGN=1
PLATFORM=web expect "complete web config" ok "flutter build web"
PLATFORM=web expect "missing canonical URL refused for web" fail "WEB_CANONICAL_URL is not set" WEB_CANONICAL_URL=
PLATFORM=web expect "canonical URL without trailing slash refused" fail "must be an https URL ending in /" WEB_CANONICAL_URL=https://app.hiyall.example.com
expect "canonical URL not needed for android" ok "flutter build appbundle" WEB_CANONICAL_URL=
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

# Manual iOS signing refuses to run outside CI, and it refuses before anything is written. No --check here: this is the
# real path, which must stop at the guard (so nothing is built and no xcconfig appears).
signing="$root/apps/mobile/ios/Flutter/Signing.xcconfig"
rm -f "$signing"
out="$(env -i PATH="$PATH" HOME="$HOME" "${good[@]}" IOS_TEAM_ID=ABCDE12345 IOS_PROFILE_NAME=Hiyall-AppStore "$script" ios 2>&1)"; status=$?
if [[ $status -ne 0 ]] && grep -q "manual iOS signing runs only in CI" <<<"$out" && [[ ! -e "$signing" ]]; then echo "ok: manual ios signing refused outside CI, nothing written"
else echo "FAIL: manual ios signing outside CI (status $status)"; echo "$out" | sed 's/^/    /'; fail=1; fi

# The project file is never edited any more, and Release.xcconfig is what carries the CI-only signing settings.
if grep -q "CODE_SIGN_STYLE" "$script" && grep -q "sed.*CODE_SIGN_STYLE\|subn(.*CODE_SIGN_STYLE" "$script"; then echo "FAIL: build-release.sh edits CODE_SIGN_STYLE in the Xcode project"; fail=1; else echo "ok: build-release.sh does not patch the Xcode project"; fi
if grep -q '^#include? "Signing.xcconfig"$' "$root/apps/mobile/ios/Flutter/Release.xcconfig"; then echo "ok: Release.xcconfig includes the optional Signing.xcconfig"; else echo "FAIL: Release.xcconfig lacks #include? \"Signing.xcconfig\""; fail=1; fi
if git -C "$root" check-ignore -q apps/mobile/ios/Flutter/Signing.xcconfig; then echo "ok: Signing.xcconfig is git-ignored"; else echo "FAIL: Signing.xcconfig is not git-ignored"; fail=1; fi

# Values in a release env file are trimmed and unquoted exactly as scripts/release_preflight.py reads them.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/config" "$tmp/apps/mobile"
cp "$script" "$tmp/scripts/"; cp "$root/apps/mobile/pubspec.yaml" "$tmp/apps/mobile/"
cat > "$tmp/config/mobile-release.quoted.local.env" <<'ENVFILE'
API_BASE_URL="https://api.hiyall.example.com"
FIREBASE_PROJECT_ID='p'
FIREBASE_MESSAGING_SENDER_ID = 1  
FIREBASE_API_KEY=k
FIREBASE_ANDROID_APP_ID="1:1:android:a"
SUPPORT_EMAIL="help@hiyall.app"
SAFETY_EMAIL=safety@hiyall.app
PRIVACY_EMAIL=privacy@hiyall.app
ENVFILE
out="$(env -i PATH="$PATH" HOME="$HOME" HIYALL_RELEASE_ENV=quoted APP_VERSION=1.2.3 APP_BUILD_NUMBER=7 "$tmp/scripts/build-release.sh" android --check 2>&1)"; status=$?
# FIREBASE_MESSAGING_SENDER_ID has a space before "=": that line is not a valid assignment and must be refused, quotes elsewhere must not break the rest.
if [[ $status -ne 0 ]] && grep -q "FIREBASE_MESSAGING_SENDER_ID is not set" <<<"$out" && ! grep -q "API_BASE_URL" <<<"$out" && ! grep -q "FIREBASE_PROJECT_ID" <<<"$out" && ! grep -q "SUPPORT_EMAIL" <<<"$out"; then echo "ok: quoted values in the release env file are unquoted like the preflight does"
else echo "FAIL: quoted env file values (status $status)"; echo "$out" | sed 's/^/    /'; fail=1; fi
sed -i.bak 's/^FIREBASE_MESSAGING_SENDER_ID = 1  $/FIREBASE_MESSAGING_SENDER_ID="1"/' "$tmp/config/mobile-release.quoted.local.env"
out="$(env -i PATH="$PATH" HOME="$HOME" HIYALL_RELEASE_ENV=quoted APP_VERSION=1.2.3 APP_BUILD_NUMBER=7 "$tmp/scripts/build-release.sh" android --check 2>&1)"; status=$?
if [[ $status -eq 0 ]] && grep -q "flutter build appbundle" <<<"$out"; then echo "ok: a fully quoted release env file is accepted"
else echo "FAIL: fully quoted env file (status $status)"; echo "$out" | sed 's/^/    /'; fail=1; fi
exit $fail
