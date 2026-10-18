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
# AdMob (rewarded ads, docs/mobile/18-shop-and-ads.md): ADMOB_APP_ID_ANDROID (read by Gradle from the environment; a release
#            Android build fails without it) and ADMOB_APP_ID_IOS (written to the git-ignored ios/Flutter/Admob.xcconfig, which
#            Release.xcconfig includes) are the AdMob APP ids (ca-app-pub-<publisher>~<app>); ADMOB_REWARDED_ANDROID and
#            ADMOB_REWARDED_IOS are the rewarded AD UNIT ids (ca-app-pub-<publisher>/<unit>), passed as dart-defines: an app
#            without its unit id has no ads. Google's published TEST ids are refused by the preflight (gate s) when ads or
#            PLANS_ENFORCED are on, and warned about here.
#            WEB_CANONICAL_URL (web only: the public https address of the site, ending in "/"; written into
#            build/web/index.html for the canonical and Open Graph tags)
# Optional:  FIREBASE_API_KEY_ANDROID / _IOS / _WEB (per platform keys), FIREBASE_AUTH_DOMAIN,
#            FIREBASE_STORAGE_BUCKET, FIREBASE_IOS_BUNDLE_ID (default app.hiyall.hiyall), APP_ENV,
#            ENABLE_EVENTS, APPLE_SIGN_IN_WEB.
# iOS signing (ios only): by default `flutter build ipa` signs automatically with the Apple account signed in to Xcode
# (a Mac you use). In CI there is no account: when IOS_TEAM_ID and IOS_PROFILE_NAME are set (the release workflow reads
# both from the installed provisioning profile) the script signs MANUALLY: `flutter build ios --config-only`, then it
# writes the git-ignored ios/Flutter/Signing.xcconfig (CODE_SIGN_STYLE=Manual, team, profile, Apple Distribution), which
# ios/Flutter/Release.xcconfig includes, so ONLY the Runner target takes the settings (a command-line override would also
# hit the Swift package targets, which cannot take a profile). It proves that with `xcodebuild -showBuildSettings`
# (scripts/ios_signing_check.py), runs `xcodebuild archive`, then `xcodebuild -exportArchive` with
# apps/mobile/ios/ExportOptions.plist. The Xcode project file is never edited. That path refuses to run outside CI
# and has never run: rehearse the first archive on a Mac (docs/mobile/16-release-and-reliability.md).
# HIYALL_IOS_NO_CODESIGN=1 builds an unsigned `flutter build ios --no-codesign` (release-dryrun.yml uses it).
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
  # Only fill what the environment has not set. Values are trimmed and one pair of surrounding quotes is removed, exactly
  # as scripts/release_preflight.py reads the same file, so the two can never disagree about a value.
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) || ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
      value="${value:1:${#value}-2}"
    fi
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
if [[ "$platform" == web ]]; then
  need FIREBASE_AUTH_DOMAIN "the web app's <project>.firebaseapp.com"
  need WEB_CANONICAL_URL "the public https address of the web build, ending in /"
  canonical_re='^https://[^/<> ]+(/[^<> ]*)?/$'
  if [[ -n "${WEB_CANONICAL_URL:-}" && ! "$WEB_CANONICAL_URL" =~ $canonical_re ]]; then
    errors+=("WEB_CANONICAL_URL must be an https URL ending in / (got '${WEB_CANONICAL_URL}')")
  fi
fi
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

# AdMob ids: shape and Google's published test publisher (3940256099942544). Warnings only here: whether they are a hard failure
# depends on whether ads or PLANS_ENFORCED are on in production, which only the release preflight (gate s) knows.
admob_test_publisher="ca-app-pub-3940256099942544"
for name in ADMOB_APP_ID_ANDROID ADMOB_APP_ID_IOS ADMOB_REWARDED_ANDROID ADMOB_REWARDED_IOS; do
  value="${!name:-}"
  [[ -n "$value" ]] || continue
  [[ "$value" == "$admob_test_publisher"* ]] && warnings+=("$name is one of Google's published TEST ids: a release build must use the real AdMob id")
  case "$name" in
    ADMOB_APP_ID_*) [[ "$value" =~ ^ca-app-pub-[0-9]{16}~[0-9]{10}$ ]] || warnings+=("$name is not an AdMob app id (ca-app-pub-<publisher>~<app>)") ;;
    *) [[ "$value" =~ ^ca-app-pub-[0-9]{16}/[0-9]{10}$ ]] || warnings+=("$name is not an AdMob ad unit id (ca-app-pub-<publisher>/<unit>)") ;;
  esac
done
if [[ "$platform" == android && -z "${ADMOB_APP_ID_ANDROID:-}" ]]; then warnings+=("ADMOB_APP_ID_ANDROID is not set: the Android release build will fail in Gradle (google_mobile_ads needs an app id)"); fi
if [[ "$platform" == ios && -z "${ADMOB_APP_ID_IOS:-}" ]]; then warnings+=("ADMOB_APP_ID_IOS is not set: the iOS release has an empty GADApplicationIdentifier and must not start the ads SDK (it has no ads)"); fi
if [[ "$platform" == android && -n "${ADMOB_APP_ID_ANDROID:-}" && -z "${ADMOB_REWARDED_ANDROID:-}" ]] || [[ "$platform" == ios && -n "${ADMOB_APP_ID_IOS:-}" && -z "${ADMOB_REWARDED_IOS:-}" ]]; then
  warnings+=("the AdMob rewarded ad unit id (ADMOB_REWARDED_$(echo "$platform" | tr a-z A-Z)) is not set: this build has no ads")
fi

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

# Manual iOS signing happens only in CI (the settings file it writes would otherwise fight the Xcode account on a Mac).
# Decided here, before anything is written, so the guard cannot be reached after a file was changed.
manual_ios=0
if [[ "$platform" == ios && "${HIYALL_IOS_NO_CODESIGN:-}" != 1 && -n "${IOS_TEAM_ID:-}" && -n "${IOS_PROFILE_NAME:-}" ]]; then
  manual_ios=1
  if [[ ! "$IOS_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then errors+=("IOS_TEAM_ID must be the 10-character Apple team id"); fi
  if [[ "$IOS_PROFILE_NAME" == *$'\n'* || "$IOS_PROFILE_NAME" == *'//'* || "$IOS_PROFILE_NAME" == *'$'* ]]; then errors+=("IOS_PROFILE_NAME contains a newline, // or \$, which an .xcconfig file cannot hold"); fi
  if ((check == 0)) && [[ "${CI:-}" != true && "${GITHUB_ACTIONS:-}" != true ]]; then
    errors+=("manual iOS signing runs only in CI (it writes ios/Flutter/Signing.xcconfig). On a Mac, unset IOS_TEAM_ID and IOS_PROFILE_NAME and sign in to Xcode instead")
  fi
  if ((${#errors[@]})); then
    echo "Refusing to build a $platform release:" >&2
    for e in "${errors[@]}"; do echo "  - $e" >&2; done
    exit 1
  fi
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
signing_xcconfig="$root/apps/mobile/ios/Flutter/Signing.xcconfig"
admob_xcconfig="$root/apps/mobile/ios/Flutter/Admob.xcconfig"
wrote_signing=0
wrote_admob=0
cleanup() {
  rm -f "$defines" "$defines_dir/ExportOptions.plist" "$defines_dir/ios-build-settings.txt"
  if ((wrote_signing)); then rm -f "$signing_xcconfig"; fi
  if ((wrote_admob)); then rm -f "$admob_xcconfig"; fi
}
trap cleanup EXIT
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
# The rewarded ad unit id of the platform being built (lib/core/billing/ads_service.dart reads ADMOB_REWARDED_ANDROID / _IOS).
if p in ("android", "ios"):
    k = "ADMOB_REWARDED_" + p.upper()
    if e.get(k):
        d[k] = e[k]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

flags=(--release "--build-name=$version" "--build-number=$build" "--dart-define-from-file=build/release-defines.json")
case "$platform" in
  android) cmd=(flutter build appbundle "${flags[@]}" --obfuscate --split-debug-info=build/symbols) ;;
  ios)
    if [[ "${HIYALL_IOS_NO_CODESIGN:-}" == 1 ]]; then
      cmd=(flutter build ios "${flags[@]}" --obfuscate --split-debug-info=build/symbols --no-codesign)
    elif ((manual_ios)); then
      cmd=(flutter build ios --config-only "${flags[@]}" --obfuscate --split-debug-info=build/symbols)
    else
      cmd=(flutter build ipa "${flags[@]}" --obfuscate --split-debug-info=build/symbols --export-method=app-store)
    fi
    ;;
  web) cmd=(flutter build web "${flags[@]}") ;; # Flutter web has no Dart obfuscation
esac

# The iOS AdMob app id (GADApplicationIdentifier = $(ADMOB_APP_ID_IOS)): ios/Flutter/Release.xcconfig includes this git-ignored file.
# Written only when the id is set, deleted when the build ends. Without it the id is empty and the release has no ads.
if [[ "$platform" == ios && -n "${ADMOB_APP_ID_IOS:-}" && "$ADMOB_APP_ID_IOS" =~ ^ca-app-pub-[0-9]{16}~[0-9]{10}$ && ! -e "$admob_xcconfig" ]] && ((check == 0)); then
  printf '// Written by scripts/build-release.sh. Do not commit; deleted when the build ends.\nADMOB_APP_ID_IOS=%s\n' "$ADMOB_APP_ID_IOS" > "$admob_xcconfig"
  wrote_admob=1
fi

if ((check)); then
  echo "OK: would run in apps/mobile: ${cmd[*]}"
  if ((manual_ios)); then echo "then (manual signing, team ${IOS_TEAM_ID}): write ios/Flutter/Signing.xcconfig (Runner target only), xcodebuild -showBuildSettings check, xcodebuild archive, xcodebuild -exportArchive -exportOptionsPlist build/ExportOptions.plist"; fi
  echo "defines: $(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))))' "$defines")"
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1 && [[ -f "$root/scripts/env.sh" ]]; then source "$root/scripts/env.sh"; fi
cd "$root/apps/mobile"
mkdir -p build/symbols
"${cmd[@]}"
if ((manual_ios)); then
  # Signing settings for the Runner target only: Release.xcconfig (the Runner target's base configuration) includes this
  # git-ignored file when it exists. Nothing in the Xcode project is edited. It is deleted on exit.
  wrote_signing=1
  python3 - "$signing_xcconfig" "$IOS_TEAM_ID" "$IOS_PROFILE_NAME" "ios/ExportOptions.plist" "build/ExportOptions.plist" <<'PY'
import sys
xc, team, profile, template, out = sys.argv[1:6]
with open(xc, "w", encoding="utf-8") as f:
    f.write("// Written by scripts/build-release.sh in CI. Do not commit; deleted when the build ends.\n"
            "CODE_SIGN_STYLE = Manual\n"
            "DEVELOPMENT_TEAM = %s\n"
            "PROVISIONING_PROFILE_SPECIFIER = %s\n"
            "CODE_SIGN_IDENTITY = Apple Distribution\n"
            "CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Distribution\n" % (team, profile))
tpl = open(template, encoding="utf-8").read()
esc = lambda v: v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
open(out, "w", encoding="utf-8").write(tpl.replace("__IOS_TEAM_ID__", esc(team)).replace("__IOS_PROFILE_NAME__", esc(profile)))
PY
  # Prove the settings reached Runner and nothing else before spending an archive on it.
  (cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -showBuildSettings) > build/ios-build-settings.txt
  python3 -I "$root/scripts/ios_signing_check.py" build/ios-build-settings.txt "$IOS_TEAM_ID" "$IOS_PROFILE_NAME"
  (cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
      -destination 'generic/platform=iOS' -archivePath ../build/ios/archive/Runner.xcarchive archive)
  xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
      -exportOptionsPlist build/ExportOptions.plist -exportPath build/ios/ipa
fi
if [[ "$platform" == web ]]; then
  # Fill the canonical / Open Graph markers in web/index.html (Flutter only substitutes the base href).
  python3 - build/web/index.html "$WEB_CANONICAL_URL" <<'PY'
import sys
path, url = sys.argv[1], sys.argv[2]
html = open(path, encoding="utf-8").read().replace("%WEB_CANONICAL_URL%", url)
if "%WEB_" in html:
    sys.exit("build/web/index.html still has an unfilled %WEB_...% marker")
open(path, "w", encoding="utf-8").write(html)
PY
fi
echo "Built $platform $version ($build). Keep apps/mobile/build/symbols for crash reports."
