#!/usr/bin/env bash
# Builds a release Hiyall app for one platform:
#
#   scripts/build-release.sh android|ios|web [--check]
#
# It refuses to build when anything a shipped app needs is missing, so a release can never install and
# say "not configured". Inputs are environment variables, optionally loaded first from a git-ignored
# file (copy config/mobile-release.example.env to config/mobile-release.<env>.local.env and pass
# HIYALL_RELEASE_ENV=<env>; default "production"). Variables already set in the environment win.
#
# Required:  API_BASE_URL (https)  FIREBASE_PROJECT_ID  FIREBASE_MESSAGING_SENDER_ID  FIREBASE_API_KEY
#            FIREBASE_ANDROID_APP_ID | FIREBASE_IOS_APP_ID | FIREBASE_WEB_APP_ID (the one for the platform)
#            SUPPORT_EMAIL  SAFETY_EMAIL  PRIVACY_EMAIL  (Help & Safety; ALLOW_PLACEHOLDER_CONTACTS=1 overrides)
#            APP_VERSION (MAJOR.MINOR.PATCH; defaults to the v-tag in GITHUB_REF_NAME, then pubspec.yaml)
#            APP_BUILD_NUMBER (integer; defaults to GITHUB_RUN_NUMBER)
# Warned if missing: SENTRY_DSN (the build has no crash reporting without it), APP_STORE_URL, PLAY_STORE_URL.
# Optional:  FIREBASE_API_KEY_ANDROID / _IOS / _WEB (per platform keys), FIREBASE_AUTH_DOMAIN,
#            FIREBASE_STORAGE_BUCKET, FIREBASE_IOS_BUNDLE_ID (default app.hiyall.hiyall), APP_ENV,
#            ENABLE_EVENTS, APPLE_SIGN_IN_WEB.
#
# Dart defines go to a temporary --dart-define-from-file under apps/mobile/build (git-ignored, deleted on
# exit). Android and iOS builds are obfuscated, with symbols in apps/mobile/build/symbols: keep them (and
# upload them to Sentry) or crash reports cannot be read. --check validates and prints the plan only.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:-}"
check=0
[[ "${2:-}" == "--check" ]] && check=1
case "$platform" in android | ios | web) ;; *)
  echo "usage: scripts/build-release.sh android|ios|web [--check]" >&2
  exit 2
  ;;
esac

if [[ -z "${HIYALL_RELEASE_ENV:-}" ]]; then HIYALL_RELEASE_ENV=production; fi
env_file="$root/config/mobile-release.${HIYALL_RELEASE_ENV}.local.env"
if [[ -f "$env_file" ]]; then
  # Only fill what the environment has not set.
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    if [[ -z "${!key:-}" ]]; then export "$key=$value"; fi
  done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$env_file")
fi

errors=()
warnings=()
need() { [[ -n "${!1:-}" ]] || errors+=("$1 is not set${2:+ ($2)}"); }

need API_BASE_URL "the https address of the API"
if [[ -n "${API_BASE_URL:-}" ]]; then
  [[ "$API_BASE_URL" == https://* ]] || errors+=("API_BASE_URL must start with https://")
  [[ "$API_BASE_URL" =~ (localhost|127\.0\.0\.1|10\.0\.2\.2) ]] && errors+=("API_BASE_URL points at this machine")
  [[ "$API_BASE_URL" == *'<'* ]] && errors+=("API_BASE_URL still has a <placeholder>")
fi
need FIREBASE_PROJECT_ID
need FIREBASE_MESSAGING_SENDER_ID
case "$platform" in
  android) app_id="${FIREBASE_ANDROID_APP_ID:-${FIREBASE_APP_ID_ANDROID:-}}"; api_key="${FIREBASE_API_KEY_ANDROID:-${FIREBASE_API_KEY:-}}" ;;
  ios) app_id="${FIREBASE_IOS_APP_ID:-${FIREBASE_APP_ID_IOS:-}}"; api_key="${FIREBASE_API_KEY_IOS:-${FIREBASE_API_KEY:-}}" ;;
  web) app_id="${FIREBASE_WEB_APP_ID:-${FIREBASE_APP_ID_WEB:-}}"; api_key="${FIREBASE_API_KEY_WEB:-${FIREBASE_API_KEY:-}}" ;;
esac
[[ -n "$app_id" ]] || errors+=("the Firebase $platform app id is not set (FIREBASE_$(echo "$platform" | tr a-z A-Z)_APP_ID)")
[[ -n "$api_key" ]] || errors+=("the Firebase API key is not set (FIREBASE_API_KEY)")
if [[ "$platform" == web ]]; then need FIREBASE_AUTH_DOMAIN "the web app's <project>.firebaseapp.com"; fi
[[ "${ENABLE_DEV_LOGIN:-}" == true ]] && errors+=("ENABLE_DEV_LOGIN must not be set for a release")

# Contacts shown in Help & Safety.
for name in SUPPORT_EMAIL SAFETY_EMAIL PRIVACY_EMAIL; do
  value="${!name:-}"
  if [[ -z "$value" || "$value" == *.example ]]; then
    if [[ "${ALLOW_PLACEHOLDER_CONTACTS:-}" == 1 ]]; then
      warnings+=("$name is a placeholder; Help & Safety will show a made-up address")
    else
      errors+=("$name is not a real address (Help & Safety shows it; Apple 1.2 needs working contact details)")
    fi
  fi
done

# Version and build number.
version="${APP_VERSION:-}"
if [[ -z "$version" && "${GITHUB_REF_NAME:-}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then version="${BASH_REMATCH[1]}"; fi
if [[ -z "$version" ]]; then
  version="$(sed -n 's/^version: *\([0-9][0-9.]*\)+.*/\1/p' "$root/apps/mobile/pubspec.yaml" | head -1)"
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || errors+=("APP_VERSION must be MAJOR.MINOR.PATCH, got '${version}'")
build="${APP_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || errors+=("APP_BUILD_NUMBER must be a positive integer (stores reject a repeated build number)")

if [[ -z "${SENTRY_DSN:-}" ]]; then
  warnings+=("SENTRY_DSN is not set: this build will have NO crash or error reporting")
fi
if [[ "$platform" == ios && -z "${APP_STORE_URL:-}" ]]; then warnings+=("APP_STORE_URL is not set: the Update screen will open a placeholder"); fi
if [[ "$platform" == android && -z "${PLAY_STORE_URL:-}" ]]; then warnings+=("PLAY_STORE_URL is not set: the Update screen will open a placeholder"); fi

for w in "${warnings[@]+"${warnings[@]}"}"; do echo "warning: $w" >&2; done
if ((${#errors[@]})); then
  echo "Refusing to build a $platform release:" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  exit 1
fi

# The Firebase URL scheme iOS needs for sign-in is the app id with ":" turned into "-", prefixed "app-".
if [[ "$platform" == ios ]]; then
  xcconfig="$root/apps/mobile/ios/Flutter/Firebase.xcconfig"
  if ((check == 0)) && [[ ! -s "$xcconfig" ]]; then
    printf '// Written by scripts/build-release.sh. Do not commit.\nFIREBASE_IOS_URL_SCHEME=app-%s\n' "${app_id//:/-}" > "$xcconfig"
  fi
fi

defines_dir="$root/apps/mobile/build"
mkdir -p "$defines_dir"
defines="$defines_dir/release-defines.json"
trap 'rm -f "$defines"' EXIT
umask 077
export RELEASE_PLATFORM="$platform" RELEASE_VERSION="$version" RELEASE_BUILD="$build" RELEASE_APP_ID="$app_id" RELEASE_API_KEY="$api_key"
python3 - "$defines" <<'PY'
import json, os, sys
e = os.environ
p = e["RELEASE_PLATFORM"]
d = {
    "API_BASE_URL": e["API_BASE_URL"],
    "FIREBASE_PROJECT_ID": e["FIREBASE_PROJECT_ID"],
    "FIREBASE_MESSAGING_SENDER_ID": e["FIREBASE_MESSAGING_SENDER_ID"],
    "FIREBASE_APP_ID_" + p.upper(): e["RELEASE_APP_ID"],
    "FIREBASE_API_KEY_" + p.upper(): e["RELEASE_API_KEY"],
    "FIREBASE_IOS_BUNDLE_ID": e.get("FIREBASE_IOS_BUNDLE_ID", "app.hiyall.hiyall"),
    "APP_VERSION": e["RELEASE_VERSION"],
    "APP_BUILD_NUMBER": e["RELEASE_BUILD"],
    "APP_ENV": e.get("APP_ENV", "production"),
}
for k in ("FIREBASE_AUTH_DOMAIN", "FIREBASE_STORAGE_BUCKET", "SENTRY_DSN", "SUPPORT_EMAIL", "SAFETY_EMAIL",
          "PRIVACY_EMAIL", "APP_STORE_URL", "PLAY_STORE_URL", "ENABLE_EVENTS", "APPLE_SIGN_IN_WEB"):
    if e.get(k):
        d[k] = e[k] if k not in ("ENABLE_EVENTS", "APPLE_SIGN_IN_WEB") else e[k] == "true"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

flags=(--release "--build-name=$version" "--build-number=$build" "--dart-define-from-file=build/release-defines.json")
case "$platform" in
  android) cmd=(flutter build appbundle "${flags[@]}" --obfuscate --split-debug-info=build/symbols) ;;
  ios) cmd=(flutter build ipa "${flags[@]}" --obfuscate --split-debug-info=build/symbols --export-method=app-store) ;;
  web) cmd=(flutter build web "${flags[@]}") ;; # Flutter web has no Dart obfuscation
esac

if ((check)); then
  echo "OK: would run in apps/mobile: ${cmd[*]}"
  echo "defines: $(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))))' "$defines")"
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1 && [[ -f "$root/scripts/env.sh" ]]; then source "$root/scripts/env.sh"; fi
cd "$root/apps/mobile"
mkdir -p build/symbols
"${cmd[@]}"
echo "Built $platform $version ($build). Keep apps/mobile/build/symbols for crash reports."
